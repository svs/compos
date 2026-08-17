defmodule Aimax.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Aimax.Core.ModelCatalog

  test "normalizes legacy LLMDB effort options for OpenAI models" do
    reasoning = ModelCatalog.reasoning("openai:gpt-5.6-luna")

    assert reasoning["source"] == "llmdb"
    assert reasoning["effort"]["values"] == ["none", "low", "medium", "high", "xhigh", "max"]
  end

  test "preserves independent effort, thinking, and token-budget controls" do
    opus = ModelCatalog.reasoning("claude-opus-5")

    assert opus["effort"]["values"] == ["low", "medium", "high", "xhigh", "max"]
    assert "adaptive" in opus["thinking"]["types"]

    haiku = ModelCatalog.reasoning("claude-haiku-4-5-20251001")
    assert haiku["effort"] == nil
    assert haiku["token_budget"]["min"] == 1024
  end

  test "live Codex metadata produces an authoritative picker entry" do
    model = %{
      "model" => "gpt-5.6-sol",
      "displayName" => "GPT-5.6 Sol",
      "supportedReasoningEfforts" => [
        %{"reasoningEffort" => "low"},
        %{"reasoningEffort" => "ultra"}
      ],
      "defaultReasoningEffort" => "low"
    }

    assert ModelCatalog.picker_entry(model) == [
             "gpt-5.6-sol",
             "GPT-5.6 Sol",
             ["low", "ultra"],
             "low"
           ]
  end

  test "unknown models do not receive invented reasoning choices" do
    assert ModelCatalog.reasoning("not-a-real-model") == nil
  end
end
