defmodule Compos.Core.LLMUsage do
  @moduledoc """
  The usage ledger. Every LLM request records `{ts, model, tokens, cost}`
  through `record/3`, appended to `llm-usage.jsonl` in the state folder, and
  `report/0` aggregates it by day and model. Prices come from
  `Compos.Core.ModelCatalog`. Per-chat attribution lives in chat
  buffer-locals, not here.
  """

  @doc """
  Dollars for a usage map (Anthropic or OpenAI field names), nil when the
  model is unpriced.

  A usage map that carries its own "cost" wins. That is req_llm's figure,
  priced against its model database from the provider's raw numbers.

  The fallback stays for the models req_llm prices at nothing: a model
  missing from its database, or a lane that reports usage without a cost.
  It prices `input_tokens` at the input rate and the cached tokens at the
  cache rate, which is right because `LLM.usage_strings/2` normalizes
  every provider to one shape first: `input_tokens` means FRESH input.
  Before that, an OpenAI request billed each cached token twice — once
  inside the input count, once at the cache rate.
  """
  def cost(_model, %{"cost" => c}) when is_number(c), do: c

  def cost(model, usage) do
    case Compos.Core.ModelCatalog.price(model) do
      nil ->
        nil

      p ->
        %{input: i, output: o, cache_read: cr, cache_write: cw} = tokens(usage)

        (i * (p.input || 0) + o * (p.output || 0) + cr * p.cache_read + cw * p.cache_write) /
          1_000_000
    end
  end

  @doc "Normalize a usage map to %{input:, output:, cache_read:, cache_write:} token counts."
  def tokens(usage) do
    %{
      input: usage["input_tokens"] || usage["prompt_tokens"] || 0,
      output: usage["output_tokens"] || usage["completion_tokens"] || 0,
      cache_read: usage["cache_read_input_tokens"] || 0,
      cache_write: usage["cache_creation_input_tokens"] || 0
    }
  end

  @doc """
  Record one request in the durable ledger; returns the computed cost (or nil).

  `slug` names the chat that spent it. Without it the ledger could say what
  a day cost but never which conversation ran up the bill.
  """
  def record(model, usage, slug \\ nil) when is_map(usage) do
    t = tokens(usage)
    cost = cost(model, usage)

    row =
      t
      |> Map.merge(%{ts: DateTime.to_iso8601(DateTime.utc_now()), model: model, cost: cost})
      |> then(fn row -> if slug, do: Map.put(row, :slug, slug), else: row end)

    File.write(ledger_path(), Jason.encode!(row) <> "\n", [:append])
    cost
  end

  @doc "Ledger rows (maps), oldest first."
  def ledger do
    case File.read(ledger_path()) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, row} -> [row]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  @doc """
  Aggregate the ledger by day and model.

  The cache columns are the point of the report: `cache_read` against
  `input + cache_read` is the hit rate, and a hit rate near zero means the
  chat is paying full price for a prefix it resends every turn.
  """
  def report do
    ledger()
    |> Enum.group_by(fn row -> {String.slice(row["ts"] || "", 0, 10), row["model"]} end)
    |> Enum.map(fn {{day, model}, rows} ->
      sum = fn key -> rows |> Enum.map(&(&1[key] || 0)) |> Enum.sum() end

      %{
        day: day,
        model: model,
        requests: length(rows),
        input: sum.("input"),
        output: sum.("output"),
        cache_read: sum.("cache_read"),
        cache_write: sum.("cache_write"),
        cost: sum.("cost")
      }
    end)
    |> Enum.sort_by(&{&1.day, &1.model}, :desc)
  end

  @doc """
  The share of billed input that came from cache, 0.0..1.0, or nil when
  there was no input to bill.
  """
  def hit_rate(%{input: input, cache_read: read}) do
    total = input + read
    if total > 0, do: read / total, else: nil
  end

  defp ledger_path, do: Path.join(Compos.Core.state_dir(), "llm-usage.jsonl")
end
