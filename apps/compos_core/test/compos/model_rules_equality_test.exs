defmodule Compos.ModelRulesEqualityTest do
  @moduledoc """
  The Scheme catalog rules must answer what Elixir's normalization answered
  before the move: same controls for every model the editor's catalog lookup
  reaches, same picker row for a live backend's model, same age for a snapshot.

  Some published models (the amazon_bedrock family) have no entry the catalog
  lookup can reach, so `reasoning/1` answers nil for them today and the rule is
  never asked about them. They are counted, not compared: the rule only ever
  reads an entry the lookup returned.
  """

  use Compos.Case, async: false

  alias Compos.Core.{LLM, ModelCatalog, Session}

  test "the Scheme reasoning rule matches the Elixir rule for every reachable model" do
    models = LLMDB.models()
    assert models != []

    {reachable, skipped} =
      Enum.reduce(models, {[], 0}, fn m, {acc, skipped} ->
        spec = Atom.to_string(m.provider) <> ":" <> m.id

        case ModelCatalog.lookup(spec) do
          {:ok, found} -> {[{spec, found} | acc], skipped}
          _ -> {acc, skipped + 1}
        end
      end)

    assert reachable != []

    mismatches =
      Enum.reduce(reachable, [], fn {spec, found}, acc ->
        raw = Jason.encode!(%{"capabilities" => found.capabilities || %{}, "extra" => found.extra || %{}})
        expected = boundary(ModelCatalog.reasoning(spec))
        {:ok, actual} = Session.call_named("model-reasoning-normalize", [raw])

        if to_elixir(actual) == to_elixir(expected) do
          acc
        else
          [{spec, String.slice(raw, 0, 700), to_elixir(actual), to_elixir(expected)} | acc]
        end
      end)

    assert mismatches == [],
           inspect(Enum.take(Enum.reverse(mismatches), 3), limit: :infinity)

    assert length(reachable) + skipped == length(models)
  end

  test "the Scheme codex row matches picker_entry" do
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

    {:ok, actual} = Session.call_named("model-codex-entry", [Jason.encode!(model)])
    assert to_elixir(actual) == ModelCatalog.picker_entry(model)
  end

  test "the Scheme staleness rule matches DateTime arithmetic" do
    now = System.os_time(:second)

    for captured <- ["2026-11-07T00:00:00Z", "2000-01-01T05:30:00+05:30", "1999-12-31T23:59:59Z", "not a date"] do
      expected =
        case DateTime.from_iso8601(captured) do
          {:ok, dt, _} -> div(DateTime.diff(DateTime.from_unix!(now), dt, :second), 86_400)
          _ -> false
        end

      {:ok, actual} = Session.call_named("model-stale-days", [captured, now])
      assert actual == expected, "age differs for " <> captured
    end
  end

  # the primitive's boundary shape: a control map becomes a plist, nil #f
  defp boundary(nil), do: false
  defp boundary(controls), do: LLM.json_to_scheme(controls)

  defp to_elixir(v), do: Session.scheme_to_json(v)
end
