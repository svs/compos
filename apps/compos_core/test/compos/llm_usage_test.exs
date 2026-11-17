defmodule Compos.LLMUsageTest do
  @moduledoc "Model pricing from the catalog, cost math, and the usage report."

  use Compos.Case

  alias Compos.Core.{LLMUsage, ModelCatalog}

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

  test "an adapter's provider/model id prices as provider:model" do
    assert ModelCatalog.price("opencode/claude-sonnet-5") ==
             ModelCatalog.price("opencode:claude-sonnet-5")

    assert ModelCatalog.price("opencode/claude-sonnet-5") != nil
    assert ModelCatalog.price("no-such-provider/no-such-model") == nil
  end

  # Only the provider adapter knows whether input_tokens already includes
  # the cached tokens. A usage map carrying its own cost wins.
  test "a usage map's own cost beats the catalog" do
    usage = %{"input_tokens" => 1000, "output_tokens" => 2000, "cost" => 0.0125}
    assert LLMUsage.cost("anthropic:claude-sonnet-5", usage) == 0.0125
    assert LLMUsage.cost("no-such-model", usage) == 0.0125
    # a non-numeric cost falls back to the catalog
    assert LLMUsage.cost("anthropic:claude-sonnet-5", Map.put(usage, "cost", nil)) > 0
  end

  test "a usage report goes on the event log as the backend gave it" do
    usage = %{"inputTokens" => 1200, "cachedReadTokens" => 40_000, "anything" => "as is"}

    assert :ok =
             Compos.Core.LLM.report_usage(%{
               usage: usage,
               slug: "zz-report-1",
               connector: "claude-code",
               backend: "acp",
               model: "claude-sonnet-5",
               end: "cancelled"
             })

    assert [r] = Enum.filter(usage_reports(), &(&1["slug"] == "zz-report-1"))
    assert r["kind"] == "turn"
    assert r["usage"] == usage
    assert {r["connector"], r["backend"], r["model"], r["end"]} ==
             {"claude-code", "acp", "claude-sonnet-5", "cancelled"}

    # a field the caller leaves out is still there, as false
    assert r["cost"] == false

    # a one-off call reports as a call, and a turn with no usage reports too
    Compos.Core.LLM.report_usage(%{slug: "zz-report-2", backend: "llm"}, :call)
    assert [c] = Enum.filter(usage_reports(), &(&1["slug"] == "zz-report-2"))
    assert {c["kind"], c["usage"], c["end"]} == {"call", false, "done"}
  end

  test "the scheme surface: format-usd, chat spend" do
    assert eval!("(format-usd 0.03315)") == ~s{"$0.0332"}

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
end
