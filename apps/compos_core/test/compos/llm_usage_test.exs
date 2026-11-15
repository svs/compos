defmodule Compos.LLMUsageTest do
  @moduledoc "Model pricing from the catalog, cost math, and the usage ledger."

  use Compos.Case

  alias Compos.Core.{LLMUsage, ModelCatalog}

  setup do
    File.rm(Path.join(Compos.Core.state_dir(), "llm-usage.jsonl"))
    :ok
  end

  test "price answers per provider, and a bare id is Anthropic" do
    assert %{input: i, output: o} = ModelCatalog.price("anthropic:claude-sonnet-5")
    assert i > 0 and o > i
    assert ModelCatalog.price("claude-sonnet-5") == ModelCatalog.price("anthropic:claude-sonnet-5")
    # the same id through two providers is two prices: the prefix is not stripped
    assert ModelCatalog.price("deepseek:deepseek-chat") !=
             ModelCatalog.price("openrouter:deepseek/deepseek-chat")

    assert ModelCatalog.price("no-such-model") == nil
  end

  test "output and input limits come from the catalog, per provider" do
    assert ModelCatalog.max_tokens("deepseek:deepseek-chat") == 384_000
    assert ModelCatalog.context_limit("deepseek:deepseek-chat") == 1_000_000
    assert ModelCatalog.context_limit("anthropic:claude-sonnet-5") == 1_000_000
    assert ModelCatalog.max_tokens("no-such-model") == nil
  end

  test "Muse Spark output limit is Meta's documented 128K across the family" do
    assert ModelCatalog.max_tokens("openrouter:meta/muse-spark-1.1") == 131_072
    assert ModelCatalog.max_tokens("meta/muse-spark-1.3-contributor") == 131_072
  end

  test "cost sums the four token buckets per million at the catalog price" do
    p = ModelCatalog.price("anthropic:claude-sonnet-5")

    usage = %{
      "input_tokens" => 1000,
      "output_tokens" => 2000,
      "cache_read_input_tokens" => 500,
      "cache_creation_input_tokens" => 0
    }

    expected = (1000 * p.input + 2000 * p.output + 500 * p.cache_read) / 1_000_000
    assert_in_delta LLMUsage.cost("anthropic:claude-sonnet-5", usage), expected, 1.0e-9
    assert LLMUsage.cost("no-such-model", usage) == nil
    # openai-style field names normalize too
    openai = %{"prompt_tokens" => 1000, "completion_tokens" => 0}
    assert_in_delta LLMUsage.cost("anthropic:claude-sonnet-5", openai), 1000 * p.input / 1_000_000, 1.0e-9
  end

  # Only the provider adapter knows whether input_tokens already includes
  # the cached tokens. A usage map carrying its own cost wins.
  test "a usage map's own cost beats the catalog" do
    usage = %{"input_tokens" => 1000, "output_tokens" => 2000, "cost" => 0.0125}
    assert LLMUsage.cost("anthropic:claude-sonnet-5", usage) == 0.0125
    assert LLMUsage.cost("no-such-model", usage) == 0.0125
    assert LLMUsage.record("anthropic:claude-sonnet-5", usage) == 0.0125
    [row | _] = ledger_rows()
    assert row["cost"] == 0.0125
    assert row["input"] == 1000
    # a non-numeric cost falls back to the catalog
    assert LLMUsage.cost("anthropic:claude-sonnet-5", Map.put(usage, "cost", nil)) > 0
  end

  test "record appends to the ledger and report aggregates by day and model" do
    LLMUsage.record("anthropic:claude-sonnet-5", %{"input_tokens" => 100, "output_tokens" => 10})
    LLMUsage.record("anthropic:claude-sonnet-5", %{"input_tokens" => 300, "output_tokens" => 30})
    LLMUsage.record("mystery-model", %{"input_tokens" => 5, "output_tokens" => 5})
    rows = LLMUsage.report()
    sonnet = Enum.find(rows, &(&1.model == "anthropic:claude-sonnet-5"))
    assert sonnet.requests == 2 and sonnet.input == 400 and sonnet.output == 40
    assert sonnet.cost > 0
    mystery = Enum.find(rows, &(&1.model == "mystery-model"))
    assert mystery.requests == 1 and mystery.cost == 0
  end

  test "the scheme surface: format-usd, llm-cost-report, chat spend" do
    assert eval!("(format-usd 0.03315)") == ~s{"$0.0332"}
    LLMUsage.record("anthropic:claude-sonnet-5", %{"input_tokens" => 100, "output_tokens" => 10})
    assert eval!("(llm-cost-report)") =~ "claude-sonnet-5"

    on_exit(fn -> Compos.Core.kill_buffer("*zz-cost-chat*") end)
    eval!(~s{(buffer-create "*zz-cost-chat*")})
    eval!(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 100 'output 10 'cost 0.01))})
    eval!(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 200 'output 20 'cost 0.02))})
    assert eval!(~s{(format-usd (buffer-local "*zz-cost-chat*" 'chat-cost))}) == ~s{"$0.0300"}
    assert eval!(~s{(plist-get (chat-usage-total "*zz-cost-chat*") 'input)}) == "300"
    # an unpriced turn keeps the running total instead of poisoning it
    eval!(~s{(chat-usage-note! "*zz-cost-chat*" (list 'input 5 'output 5 'cost #f))})
    assert eval!(~s{(format-usd (buffer-local "*zz-cost-chat*" 'chat-cost))}) == ~s{"$0.0300"}
  end

  defp ledger_rows do
    Path.join(Compos.Core.state_dir(), "llm-usage.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
