defmodule Aimax.Core.Agent.Backend do
  @moduledoc """
  The seam between the thread GenServer (`Aimax.Core.Agent` — status machine,
  prompt queue, event pipeline, output mark) and whatever executes turns
  (an ACP adapter subprocess, the in-process ReqLLM lane, a test stub).

  A backend is started per thread and sends its owner pid
  `{:backend_event, plist}` messages — the same flat Scheme plists the event
  pipeline delivers to the renderer. The event vocabulary IS the contract:
  `chunk thought tool-call tool-update plan permission user-msg turn-end
  error model-state status dead` (plus `usage` and `mode-state` when they
  land). Two control events never reach Scheme — the Agent consumes them:

    * `ready` — session established; the thread goes idle and pops its queue
    * `turn-failed` — the turn died with no result; idle without a turn-end

  `prompt/3`'s context map carries what a backend may need to execute a turn
  against the transcript truth: `turns`, `system`, `tools`, `dispatcher`.
  ACP ignores most of it (the adapter holds server-side state).
  """

  @callback start(config :: map, owner :: pid) :: {:ok, handle :: term} | {:error, term}
  @callback prompt(handle :: term, text :: String.t(), context :: map) :: :ok
  @callback cancel(handle :: term) :: :ok
  @callback close(handle :: term) :: :ok
  @callback set_model(handle :: term, model_id :: String.t()) :: :ok | {:error, term}
  @callback respond_permission(handle :: term, id :: term, option :: String.t() | nil) :: :ok
  @callback capabilities() :: [:models | :streaming | :session_modes | :resume]

  @doc "Pick the backend module a resolved connector config names (default acp)."
  def module(config) do
    case Map.get(config, "backend", "acp") do
      "stub" -> __MODULE__.Stub
      _ -> __MODULE__.ACP
    end
  end

  # --- event plist helpers (shared by Agent and every backend) ---------------

  @doc "Build a Scheme event plist: (type chunk text \"...\") — flat, symbol keys."
  def plist(kvs) do
    Enum.flat_map(kvs, fn {k, v} -> [{:sym, to_string(k)}, plist_val(v)] end)
  end

  defp plist_val(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: {:sym, to_string(v)}

  defp plist_val(v), do: v

  @doc "Read a value out of an event plist by key name."
  def plist_get([{:sym, key}, v | _], key), do: v
  def plist_get([_, _ | rest], key), do: plist_get(rest, key)
  def plist_get(_, _key), do: nil

  @doc "The event's type as a string, whatever term shape carried it."
  def event_type(event) do
    case plist_get(event, "type") do
      {:sym, t} -> t
      t when is_binary(t) -> t
      _ -> nil
    end
  end
end
