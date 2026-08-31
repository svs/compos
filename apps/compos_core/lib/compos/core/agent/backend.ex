defmodule Compos.Core.Agent.Backend do
  @moduledoc """
  The seam between the thread GenServer (`Compos.Core.Agent` — status machine,
  prompt queue, event pipeline, output mark) and whatever executes turns
  (an ACP adapter subprocess, the in-process ReqLLM lane, a test stub).

  There is no `:resume`. ACP defines `session/load`, but resuming needs a
  session id that outlives the daemon, and nothing persists one — so a
  revived thread seeds a fresh session with the transcript instead, and
  SAYS so in the transcript rather than letting a pasted conversation pass
  for a continued one. Declaring a capability no backend can honour is
  worse than not having it.

  A backend is started per thread and sends its owner pid
  `{:backend_event, plist}` messages — the same flat Scheme plists the event
  pipeline delivers to the renderer. The event vocabulary IS the contract:
  `chunk thought tool-call tool-update plan permission user-msg turn-end
  error model-state status dead` (plus `usage` and `mode-state` when they
  land). Two control events never reach Scheme — the Agent consumes them:

    * `ready` — session established; the thread goes idle and pops its queue
    * `turn-failed` — the turn died with no result; idle without a turn-end

  Steering negotiation and acknowledgements are control events too:
  `steering-ready`, `steering-disabled`, `steering-accepted`, and
  `steering-fallback` are consumed by the Agent rather than rendered.

  `prompt/3`'s context map carries what a backend may need to execute a turn
  against the transcript truth: `turns`, `system`, `tools`, `dispatcher`,
  `display`. The Agent assembles it at turn start and hands it over — a
  backend does not go looking for its own conversation. ACP ignores most of
  it (the adapter holds server-side state).
  """

  @callback start(config :: map, owner :: pid) :: {:ok, handle :: term} | {:error, term}
  @callback prompt(handle :: term, text :: String.t(), context :: map) :: :ok
  @callback steer(
              handle :: term,
              token :: non_neg_integer,
              text :: String.t(),
              display :: String.t() | nil,
              epoch :: non_neg_integer
            ) :: :ok | {:error, term}
  @callback cancel(handle :: term) :: :ok
  @callback close(handle :: term) :: :ok
  @callback set_model(handle :: term, model_id :: String.t()) :: :ok | {:error, term}
  @callback set_effort(handle :: term, effort :: String.t()) :: :ok | {:error, term}
  @callback respond_permission(handle :: term, id :: term, option :: String.t() | nil) :: :ok
  @callback respond_question(handle :: term, id :: term, answer :: String.t() | nil) :: :ok
  @callback capabilities() :: [
              :models
              | :streaming
              | :session_modes
              | :reasoning_effort
              # The backend can push input into a running turn. Stateful
              # protocols acknowledge delivery through steering control events.
              | :push_steering
              # The backend's model loop pulls queued input at safe request
              # boundaries. It does not need a transport callback.
              | :boundary_steering
              # no server-side session: the whole conversation of record is
              # replayed on every turn. Three things follow, and Scheme reads
              # this rather than asking which connector it is — a new lane
              # declares itself instead of being special-cased.
              #   * a switched model needs no new session
              #   * a fresh runtime needs no seed transcript
              #   * the backend writes the record, because it replays it
              | :stateless
              # turns are billed and report usage, rather than riding a
              # subscription
              | :metered
            ]

  @doc """
  Switch the backend's permission/session mode. Optional: only backends
  advertising `:session_modes` implement it, so the caller checks
  capabilities rather than rescuing UndefinedFunctionError.
  """
  @callback set_mode(handle :: term, mode_id :: String.t()) :: :ok | {:error, term}

  @optional_callbacks set_mode: 2, set_effort: 2, respond_question: 3, steer: 5

  @escaped :compos_escaped_closures

  @doc """
  The context one turn runs against. Inline frontends register a callback
  scoped to their LLM session; chats use the default registered through
  `llm-session-context-fn!`.

  Called by the Agent, in a task, at turn start. The closure stays rooted
  in ETS because it escapes into long-lived processes, but ONE caller
  looks it up: a backend is handed its context, it does not fetch it.
  """
  def context(slug, display) do
    fun =
      Compos.Core.LLMSession.callback(slug, :context) ||
        case :ets.lookup(@escaped, {:agent_context}) do
          [{_, callback}] -> callback
          [] -> nil
        end

    case fun do
      nil ->
        {:error, "no llm-session-context-fn! registered"}

      fun ->
        case call_context(fun, slug, display, 40) do
          {:ok, plist} ->
            {:ok,
             %{
               turns: plist_get(plist, "turns") || [],
               system: plist_str(plist_get(plist, "system")),
               tools: plist_get(plist, "tools") || [],
               dispatcher: plist_get(plist, "dispatcher")
             }}

          {:error, msg} ->
            {:error, "the chat could not say what this turn should send: #{msg}"}
        end
    end
  end

  # Closure frames publish before cross-lane exposure. Retain a bounded retry
  # for persisted references from an older or faulty root set; reading context
  # is idempotent, so retrying is safer than dropping the turn.
  defp call_context(fun, slug, display, retries) do
    result =
      Compos.Core.Session.call_fn(
        fun,
        [slug, display],
        nil,
        Compos.Core.Agent.lane(slug),
        "context #{slug}"
      )

    case result do
      {:error, msg} when retries > 0 ->
        if is_binary(msg) and msg =~ "stale environment frame" do
          Process.sleep(50)
          call_context(fun, slug, display, retries - 1)
        else
          result
        end

      _ ->
        result
    end
  end

  defp plist_str(v) when is_binary(v), do: v
  defp plist_str(_), do: nil

  @doc "Pick the backend module a resolved connector config names (default acp)."
  def module(config) do
    case Map.get(config, "backend", "acp") do
      "stub" -> __MODULE__.Stub
      "req-llm" -> __MODULE__.ReqLLM
      "chrome-gemini-nano" -> __MODULE__.ChromeGeminiNano
      "codex-app-server" -> __MODULE__.CodexAppServer
      _ -> __MODULE__.ACP
    end
  end

  @doc "What the named backend can do, for Scheme (`connector-capabilities`)."
  def capabilities_of(name), do: module(%{"backend" => name}).capabilities()

  @doc """
  A crash reason as a sentence, not a term dump.

  `inspect/1` output in a transcript is noise the reader cannot act on and
  the model cannot parse. Anything that reaches a chat says what happened.
  """
  def error_text(%{__exception__: true} = e), do: Exception.message(e)
  def error_text({:exit, reason}), do: error_text(reason)
  def error_text({e, stack}) when is_list(stack), do: error_text(e)
  def error_text(:killed), do: "the turn was stopped"
  def error_text(:normal), do: "the turn ended early"
  def error_text(:timeout), do: "the turn timed out"
  def error_text(reason) when is_binary(reason), do: reason

  def error_text(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  def error_text(reason), do: inspect(reason, limit: 5, printable_limit: 200)

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

  @doc """
  Stamp tool durations onto the event stream. A backend passes every
  outgoing event through here with its `tool_started` map: a `tool-call`
  records its start time, and the `tool-update` that ends the call
  (status "completed" or "failed") gains a `duration-ms` field. Every
  other event passes through unchanged. Returns `{kvs, map}`.
  """
  def time_tool(kvs, started) do
    id = Keyword.get(kvs, :id)

    case {Keyword.get(kvs, :type), Keyword.get(kvs, :status)} do
      {:"tool-call", _} when not is_nil(id) ->
        {kvs, Map.put(started, id, System.monotonic_time(:millisecond))}

      {:"tool-update", status} when status in ["completed", "failed"] ->
        case Map.pop(started, id) do
          {nil, started} ->
            {kvs, started}

          {t0, started} ->
            {kvs ++ ["duration-ms": System.monotonic_time(:millisecond) - t0], started}
        end

      _ ->
        {kvs, started}
    end
  end
end
