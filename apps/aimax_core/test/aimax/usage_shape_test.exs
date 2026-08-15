defmodule Aimax.UsageShapeTest do
  @moduledoc """
  One usage shape, whoever answered.

  Anthropic reports input_tokens WITHOUT the cached tokens. OpenAI, and
  every provider that copies its shape, reports them INSIDE it. The editor
  mixed the two, so a cache hit rate counted the cached tokens in both
  terms of its own fraction and read 47% where the truth was 92%.
  `input_tokens` means fresh input now, normalized at the wire.
  """

  use ExUnit.Case, async: true

  alias Aimax.Core.{LLM, LLMDb}

  # what an OpenAI-shaped provider sends back: 1000 in, 900 of them cached
  defp openai_usage,
    do: %{input_tokens: 1000, output_tokens: 50, cached_tokens: 900, cache_creation_tokens: 100}

  # Anthropic counts the same request as 100 fresh + 900 read
  defp anthropic_usage,
    do: %{input_tokens: 100, output_tokens: 50, cached_tokens: 900, cache_creation_tokens: 100}

  test "an OpenAI-shaped provider has its cached tokens taken out of input" do
    u = LLM.usage_strings(openai_usage(), "openai:gpt-5.6-luna")

    assert u["input_tokens"] == 100
    assert u["cache_read_input_tokens"] == 900
    assert u["output_tokens"] == 50
  end

  test "Anthropic's input is already fresh and stays as it is" do
    u = LLM.usage_strings(anthropic_usage(), "anthropic:claude-sonnet-5")

    assert u["input_tokens"] == 100
    assert u["cache_read_input_tokens"] == 900
  end

  test "openrouter speaks the OpenAI shape whatever model sits behind it" do
    u = LLM.usage_strings(openai_usage(), "openrouter:anthropic/claude-sonnet-5")
    assert u["input_tokens"] == 100
  end

  test "both shapes describe the same request identically" do
    assert LLM.usage_strings(openai_usage(), "openai:gpt-5.6-luna") ==
             LLM.usage_strings(anthropic_usage(), "anthropic:claude-sonnet-5")
  end

  test "a provider that reports no cache at all is untouched" do
    u = LLM.usage_strings(%{input_tokens: 700, output_tokens: 20}, "openai:gpt-5.6-luna")

    assert u["input_tokens"] == 700
    assert u["cache_read_input_tokens"] == 0
  end

  test "a cached count larger than the input never goes negative" do
    u = LLM.usage_strings(%{input_tokens: 10, cached_tokens: 900}, "openai:gpt-5.6-luna")
    assert u["input_tokens"] == 0
  end

  test "req_llm's own cost still wins over the fallback" do
    u = LLM.usage_strings(Map.put(openai_usage(), :total_cost, 0.0042), "openai:gpt-5.6-luna")

    assert u["cost"] == 0.0042
    assert LLMDb.cost("openai:gpt-5.6-luna", u) == 0.0042
  end

  test "the hit rate the editor reports is now the real one" do
    u = LLM.usage_strings(openai_usage(), "openai:gpt-5.6-luna")

    {:ok, rate} =
      Aimax.Core.Session.eval(~s{(chat-hit-rate (list 'cache-read #{u["cache_read_input_tokens"]}
                                                      'input #{u["input_tokens"]}))})

    # 900 read of 1000 billed input
    assert rate == ~s{"90%"}
  end
end
