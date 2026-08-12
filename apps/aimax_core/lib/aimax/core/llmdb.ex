defmodule Aimax.Core.LLMDb do
  @moduledoc """
  Model/pricing database + usage ledger.

  Pricing comes from models.dev (the same catalog req_llm's model sync uses):
  `~/.aimax/llmdb.json` is a cached copy of https://models.dev/api.json,
  refreshed in the background when older than a day and re-checked on a
  daily timer. `price/1` looks a model id up across providers; `cost/2`
  turns an Anthropic/OpenAI usage map into dollars.

  Every LLM request records `{ts, model, tokens, cost}` via `record/2`:
  appended to `~/.aimax/llm-usage.jsonl` (the durable ledger `report/0`
  aggregates) — per-chat attribution lives in chat buffer-locals, not here.
  """

  use GenServer
  require Logger

  @url "https://models.dev/api.json"
  @day_ms 24 * 60 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Pricing for a model id: %{input:, output:, cache_read:, cache_write:} $/1M tokens, or nil."
  def price(model) do
    model = model |> String.replace_prefix("openrouter:", "") |> String.replace_prefix("openai:", "")
    db = :persistent_term.get(:aimax_llmdb, %{})

    # prefer first-party providers; openrouter ids are "vendor/model"
    providers = ["anthropic", "openai", "openrouter"] ++ Map.keys(db)

    Enum.find_value(providers, fn p ->
      with %{"models" => models} <- db[p],
           %{"cost" => cost} <- models[model] || models[Path.basename(model)] do
        %{
          input: cost["input"],
          output: cost["output"],
          cache_read: cost["cache_read"] || 0,
          cache_write: cost["cache_write"] || 0
        }
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Dollars for a usage map (Anthropic or OpenAI field names), nil when the
  model is unpriced.

  A usage map that carries its own "cost" wins. That is req_llm's figure,
  priced against its model database, and it is the accurate one: only the
  provider adapter knows whether `input_tokens` already includes the
  cached tokens. OpenAI's does, Anthropic's does not — so the fallback
  below bills every cached OpenAI token twice.

  The fallback stays for the models req_llm prices at nothing: a model
  missing from its database, or a lane that reports usage without a cost.
  """
  def cost(_model, %{"cost" => c}) when is_number(c), do: c

  def cost(model, usage) do
    case price(model) do
      nil ->
        nil

      p ->
        %{input: i, output: o, cache_read: cr, cache_write: cw} = tokens(usage)
        (i * (p.input || 0) + o * (p.output || 0) + cr * p.cache_read + cw * p.cache_write) / 1_000_000
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

  @doc "Record one request in the durable ledger; returns the computed cost (or nil)."
  def record(model, usage) when is_map(usage) do
    t = tokens(usage)
    cost = cost(model, usage)

    row =
      t
      |> Map.merge(%{ts: DateTime.to_iso8601(DateTime.utc_now()), model: model, cost: cost})

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

  @doc "Aggregate the ledger by day and model: [%{day, model, requests, input, output, cost}]."
  def report do
    ledger()
    |> Enum.group_by(fn row -> {String.slice(row["ts"] || "", 0, 10), row["model"]} end)
    |> Enum.map(fn {{day, model}, rows} ->
      %{
        day: day,
        model: model,
        requests: length(rows),
        input: rows |> Enum.map(&(&1["input"] || 0)) |> Enum.sum(),
        output: rows |> Enum.map(&(&1["output"] || 0)) |> Enum.sum(),
        cost: rows |> Enum.map(&(&1["cost"] || 0)) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{&1.day, &1.model}, :desc)
  end

  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(nil) do
    load_db()

    if Application.get_env(:aimax_core, :llmdb_auto, true) do
      if stale?(), do: refresh()
      Process.send_after(self(), :tick, @day_ms)
    end

    {:ok, nil}
  end

  @impl true
  def handle_cast(:refresh, state) do
    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn -> do_refresh() end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    if stale?(), do: refresh()
    Process.send_after(self(), :tick, @day_ms)
    {:noreply, state}
  end

  defp db_path, do: Path.join(Aimax.Core.home(), "llmdb.json")
  defp ledger_path, do: Path.join(Aimax.Core.home(), "llm-usage.jsonl")

  defp stale? do
    case File.stat(db_path(), time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > div(@day_ms, 1000)
      _ -> true
    end
  end

  defp load_db do
    with {:ok, data} <- File.read(db_path()),
         {:ok, db} <- Jason.decode(data) do
      :persistent_term.put(:aimax_llmdb, db)
    else
      _ -> :ok
    end
  end

  defp do_refresh do
    case Req.get(@url, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: db}} when is_map(db) ->
        File.mkdir_p!(Aimax.Core.home())
        File.write!(db_path(), Jason.encode!(db))
        :persistent_term.put(:aimax_llmdb, db)
        Logger.info("llmdb refreshed: #{map_size(db)} providers")

      other ->
        Logger.warning("llmdb refresh failed: #{inspect(other)}")
    end
  end
end
