defmodule Compos.ModelCatalogTest do
  use Compos.Case, async: false

  alias Compos.Core.{ModelCatalog, Session}

  # Scheme owns the normalization; the snapshot it builds is what a lookup reads.
  setup_all do
    {:ok, _} = Session.call_named("model-rules-build!", [], nil, 120_000, {:system, :model_rules})
    :ok
  end

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
    refute haiku["effort"]
    assert haiku["token_budget"]["min"] == 1024
  end

  test "a live Codex model list produces picker rows through the Scheme rule" do
    model = %{
      "model" => "gpt-5.6-sol",
      "displayName" => "GPT-5.6 Sol",
      "supportedReasoningEfforts" => [
        %{"reasoningEffort" => "low"},
        %{"effort" => "ultra"},
        %{"reasoningEffort" => "low"}
      ],
      "defaultReasoningEffort" => "low"
    }

    {:ok, rows} = Session.call_named("model-codex-entries", [Jason.encode!([model])])

    assert Session.scheme_to_json(rows) == [
             ["gpt-5.6-sol", "GPT-5.6 Sol", ["low", "ultra"], "low"]
           ]
  end

  test "unknown models do not receive invented reasoning choices" do
    assert ModelCatalog.reasoning("not-a-real-model") == nil
  end
end
