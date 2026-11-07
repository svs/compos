defmodule Compos.ModelRulesEqualityTest do
  @moduledoc """
  The catalog snapshot must answer what the Scheme rule computes from the raw
  entry, for every model the editor's catalog lookup reaches. Elixir owns no
  normalization any more; this test proves the snapshot Scheme built is the
  rule's answer, not a stale or partial copy.
  """

  use Compos.Case, async: false

  alias Compos.Core.{ModelCatalog, Session}

  setup_all do
    {:ok, _} = Session.call_named("model-rules-build!", [], nil, 120_000, {:system, :model_rules})
    :ok
  end

  test "the snapshot answers what the Scheme rule computes for every reachable model" do
    models = LLMDB.models()
    assert models != []

    mismatches =
      Enum.reduce(models, [], fn m, acc ->
        spec = Atom.to_string(m.provider) <> ":" <> m.id

        case ModelCatalog.lookup(spec) do
          {:ok, found} ->
            raw = Jason.encode!(%{"capabilities" => found.capabilities || %{}, "extra" => found.extra || %{}})
            {:ok, rule} = Session.call_named("model-reasoning-normalize", [raw])
            expected = if rule == false, do: false, else: Session.scheme_to_json(rule)
            actual = ModelCatalog.reasoning(spec)

            if actual == expected do
              acc
            else
              [{spec, actual, expected} | acc]
            end

          _ ->
            acc
        end
      end)

    assert mismatches == [], inspect(Enum.take(Enum.reverse(mismatches), 3), limit: :infinity)
  end

  test "the snapshot is complete: every reachable model has an answer" do
    missing =
      Enum.reduce(LLMDB.models(), [], fn m, acc ->
        spec = Atom.to_string(m.provider) <> ":" <> m.id

        case ModelCatalog.lookup(spec) do
          {:ok, _} -> if ModelCatalog.reasoning(spec) == nil, do: [spec | acc], else: acc
          _ -> acc
        end
      end)

    assert missing == [], "no snapshot answer for: " <> inspect(Enum.take(missing, 10))
  end

  test "the staleness rule matches DateTime arithmetic" do
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
end
