defmodule Aimax.LLMDbTest do
  @moduledoc "Model pricing lookup, cost math, and the usage ledger."

  use ExUnit.Case

  alias Aimax.Core.{LLMDb, Session}

  @db %{
    "anthropic" => %{
      "models" => %{
        "claude-sonnet-5" => %{
          "cost" => %{"input" => 3.0, "output" => 15.0, "cache_read" => 0.3, "cache_write" => 3.75}
        }
      }
    },
    "openrouter" => %{
      "models" => %{
        "deepseek/deepseek-chat" => %{"cost" => %{"input" => 0.2, "output" => 0.4}}
      }
    },
    "deepseek" => %{
      "models" => %{
        "deepseek-chat" => %{
          "cost" => %{"input" => 0.27, "output" => 1.1},
          "limit" => %{"input" => 64_000, "output" => 8_000}
        }
      }
    }
  }

  setup do
    :persistent_term.put(:aimax_llmdb, @db)
    File.rm(Path.join(Aimax.Core.home(), "llm-usage.jsonl"))
    on_exit(fn -> :persistent_term.erase(:aimax_llmdb) end)
    :ok
  end

  test "price finds models across providers, stripping routing prefixes" do
    assert %{input: 3.0, output: 15.0} = LLMDb.price("claude-sonnet-5")
    assert %{input: 0.2} = LLMDb.price("openrouter:deepseek/deepseek-chat")
    assert %{input: 0.27, output: 1.1} = LLMDb.price("deepseek:deepseek-chat")
    assert LLMDb.price("no-such-model") == nil
  end

  test "the deepseek prefix strips to the first-party catalog" do
    assert LLMDb.max_tokens("deepseek:deepseek-chat") == 8_000
    assert LLMDb.context_limit("deepseek:deepseek-chat") == 64_000
  end

  test "cost sums all four token buckets per million" do
    usage = %{
      "input_tokens" => 1000,
      "output_tokens" => 2000,
      "cache_read_input_tokens" => 500,
      "cache_creation_input_tokens" => 0
    }

    assert_in_delta LLMDb.cost("claude-sonnet-5", usage), 0.03315, 1.0e-9
    assert LLMDb.cost("no-such-model", usage) == nil

    # openai-style field names normalize too
    assert_in_delta LLMDb.cost("claude-sonnet-5", %{"prompt_tokens" => 1000, "completion_tokens" => 0}),
                    0.003,
                    1.0e-9
  end

  # Only the provider adapter knows whether input_tokens already includes
  # the cached tokens — OpenAI's does, Anthropic's does not. req_llm prices
  # the request knowing that; our table cannot, so it bills every cached
  # OpenAI token twice. A usage map carrying its own cost wins.
  test "a usage map's own cost beats the local table" do
    usage = %{
      "input_tokens" => 1000,
      "output_tokens" => 2000,
      "cache_read_input_tokens" => 500,
      "cache_creation_input_tokens" => 0,
      "cost" => 0.0125
    }

    assert LLMDb.cost("claude-sonnet-5", usage) == 0.0125

    # ...even for a model the local table prices at nothing
    assert LLMDb.cost("no-such-model", usage) == 0.0125

    # the ledger records the supplied figure, not the recomputed one
    assert LLMDb.record("claude-sonnet-5", usage) == 0.0125
    [row | _] = ledger_rows()
    assert row["cost"] == 0.0125
    assert row["input"] == 1000
  end

  test "a non-numeric or absent cost falls back to the table" do
    usage = %{"input_tokens" => 1000, "output_tokens" => 2000}
    assert_in_delta LLMDb.cost("claude-sonnet-5", usage), 0.033, 1.0e-9
    assert_in_delta LLMDb.cost("claude-sonnet-5", Map.put(usage, "cost", nil)), 0.033, 1.0e-9
  end

  defp ledger_rows do
    Path.join(Aimax.Core.home(), "llm-usage.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  test "record appends to the ledger and report aggregates by day+model" do
    LLMDb.record("claude-sonnet-5", %{"input_tokens" => 100, "output_tokens" => 10})
    LLMDb.record("claude-sonnet-5", %{"input_tokens" => 300, "output_tokens" => 30})
    LLMDb.record("mystery-model", %{"input_tokens" => 5, "output_tokens" => 5})

    rows = LLMDb.report()
    sonnet = Enum.find(rows, &(&1.model == "claude-sonnet-5"))

    assert sonnet.requests == 2
    assert sonnet.input == 400
    assert sonnet.output == 40
    assert_in_delta sonnet.cost, (400 * 3.0 + 40 * 15.0) / 1_000_000, 1.0e-9

    # unpriced models still count requests/tokens, cost stays zero
    mystery = Enum.find(rows, &(&1.model == "mystery-model"))
    assert mystery.requests == 1
    assert mystery.cost == 0
  end

  test "the scheme surface: llm-price, format-usd, llm-cost-report" do
    {:ok, price} = Session.eval(~s{(custom--plist-get (llm-price "claude-sonnet-5") 'output)})
    assert price == "15.0"

    {:ok, usd} = Session.eval("(format-usd 0.03315)")
    assert usd == ~s{"$0.0332"}

    LLMDb.record("claude-sonnet-5", %{"input_tokens" => 100, "output_tokens" => 10})
    {:ok, report} = Session.eval("(llm-cost-report)")
    assert report =~ "claude-sonnet-5"
  end

  test "chats accumulate spend in buffer-locals" do
    on_exit(fn -> Aimax.Core.kill_buffer("*zz-cost-chat*") end)

    eval = fn src ->
      {:ok, printed} = Session.eval(src)
      printed
    end

    eval.(~s{(buffer-create "*zz-cost-chat*")})
    eval.(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 100 'output 10 'cost 0.01))})
    eval.(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 200 'output 20 'cost 0.02))})

    assert eval.(~s{(format-usd (buffer-local "*zz-cost-chat*" 'chat-cost))}) == ~s{"$0.0300"}
    # the running totals travel with the cost, so C-c $ can state a hit rate
    assert eval.(~s{(plist-get (chat-usage-total "*zz-cost-chat*") 'input)}) == "300"

    # an unpriced turn keeps the running total instead of poisoning it
    eval.(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 5 'output 5 'cost #f))})
    assert eval.(~s{(format-usd (buffer-local "*zz-cost-chat*" 'chat-cost))}) == ~s{"$0.0300"}
  end
end
