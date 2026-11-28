defmodule Compos.Core.Agent.ACPHub do
  @moduledoc """
  One ACP adapter process shared by many chats. ACP routes everything by
  `sessionId`, so one adapter serves any number of sessions; a process per
  chat paid the adapter's whole footprint (a node runtime, ~100-200 MB) for
  every thread. A hub owns the adapter for one (command, environment):
  chats whose adapter would start identically share it, and a chat whose
  environment differs (another model pinned in env, a sanitized home) gets
  a hub of its own.

  Each `Backend.ACP` keeps talking JSON lines as if it owned the adapter;
  `Transport.Shared` hands its frames to the hub. The hub:

    * answers `initialize` once for the adapter and replays the cached
      answer to every later chat;
    * rewrites request ids so each chat keeps its own id space, and sends
      each answer back to the chat that asked;
    * routes the agent's notifications and requests by `params.sessionId`
      to the chat that opened that session (session/new answer, or the id a
      session/load names);
    * closes a leaving chat's sessions with `session/close` when the agent
      offers it, and closes the adapter a linger after the last chat left;
    * tells every chat `{:acp_exit, status}` when the adapter dies, so each
      can park and come back with session/load.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Compos.Core.JsonRpc

  # an idle adapter outlives its last chat this long, so a park followed by
  # a revive, or one chat closing as another opens, reuses the process
  @linger_ms 60_000
  # notifications for a session whose session/new answer has not landed yet
  @early_max 200

  # --- api --------------------------------------------------------------------

  @doc "The hub for CMD with OPTS (:env, :cd), started when none runs. Answers its pid."
  def checkout(cmd, opts) do
    key = key(cmd, opts)
    name = name(key)

    case Process.whereis(name) do
      nil ->
        case GenServer.start(__MODULE__, {key, cmd, opts}, name: name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          {:error, reason} -> raise "agent adapter #{cmd} did not start: #{inspect(reason)}"
        end

      pid ->
        pid
    end
  end

  @doc "Join OWNER to HUB: frames for its sessions go to OWNER as {:acp_data, line}."
  def join(hub, owner), do: GenServer.call(hub, {:join, owner})

  def leave(hub, owner), do: GenServer.cast(hub, {:leave, owner})

  def send_frame(hub, owner, data), do: GenServer.cast(hub, {:frame, owner, data})

  @doc "The running hubs: pid, command, chats, sessions."
  def list do
    for name <- Process.registered(),
        String.starts_with?(Atom.to_string(name), "Elixir.Compos.Core.Agent.ACPHub."),
        pid = Process.whereis(name),
        is_pid(pid) do
      GenServer.call(pid, :info)
    end
  end

  @doc "What makes two adapters interchangeable: the command and the environment it starts with."
  def key(cmd, opts) do
    env =
      (Keyword.get(opts, :env) || [])
      |> Enum.map(fn
        {k, v} -> {to_string(k), v && to_string(v)}
        [k, v] -> {to_string(k), v && to_string(v)}
      end)
      |> Enum.sort()

    {cmd, env}
  end

  defp name(key), do: :"#{__MODULE__}.#{:erlang.phash2(key, 4_294_967_296)}"

  # --- server -----------------------------------------------------------------

  @impl true
  def init({key, cmd, opts}) do
    transport = Compos.Core.Agent.Transport.impl()
    # the adapter serves sessions in many directories; each session names its
    # own cwd at session/new, so the process itself starts at home
    opts = Keyword.put(opts, :cd, System.user_home!())
    {:ok, tp} = transport.open(cmd, opts, self())

    {:ok,
     %{
       key: key,
       cmd: cmd,
       transport: transport,
       tp: tp,
       partial: "",
       next_id: 1,
       # hub id -> {owner, owner id, method, params}
       pending: %{},
       # owner pid -> monitor ref
       clients: %{},
       # session id -> owner
       sessions: %{},
       # initialize: nil (never sent), :sent, {:ok, result} or {:error, err}
       init: nil,
       init_waiters: [],
       early: %{},
       linger: nil
     }}
  end

  @impl true
  def handle_call({:join, owner}, _from, state) do
    state =
      if Map.has_key?(state.clients, owner),
        do: state,
        else: put_in(state.clients[owner], Process.monitor(owner))

    {:reply, :ok, cancel_linger(state)}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       pid: self(),
       cmd: state.cmd,
       chats: map_size(state.clients),
       sessions: map_size(state.sessions)
     }, state}
  end

  @impl true
  def handle_cast({:frame, owner, data}, state) do
    {frames, _} = JsonRpc.decode_lines(IO.iodata_to_binary(data))
    {:noreply, Enum.reduce(frames, state, &from_client(&2, owner, &1))}
  end

  def handle_cast({:leave, owner}, state), do: {:noreply, drop_client(state, owner)}

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _}, state),
    do: {:noreply, drop_client(state, owner)}

  def handle_info(:linger, %{clients: clients} = state) when map_size(clients) == 0 do
    state.transport.close(state.tp)
    {:stop, :normal, state}
  end

  def handle_info(:linger, state), do: {:noreply, %{state | linger: nil}}

  def handle_info({:acp_data, data}, state), do: {:noreply, ingest(state, data)}
  def handle_info({port, {:data, data}}, %{tp: port} = state), do: {:noreply, ingest(state, data)}
  def handle_info({:acp_exit, status}, state), do: adapter_exit(state, status)
  def handle_info({port, {:exit_status, status}}, %{tp: port} = state), do: adapter_exit(state, status)
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.tp)
    :ok
  end

  # --- chat -> adapter ----------------------------------------------------------

  defp from_client(state, owner, %{"method" => "initialize", "id" => id} = frame) do
    case state.init do
      nil ->
        state
        |> Map.put(:init, :sent)
        |> Map.update!(:init_waiters, &[{owner, id} | &1])
        |> forward_request(:init, nil, frame)

      :sent ->
        Map.update!(state, :init_waiters, &[{owner, id} | &1])

      {:ok, result} ->
        to_client(state, owner, JsonRpc.response(id, result, []))

      {:error, err} ->
        to_client(state, owner, %{"jsonrpc" => "2.0", "id" => id, "error" => err})
    end
  end

  # a request: the hub's own id on the wire, the chat's id on the way back
  defp from_client(state, owner, %{"method" => method, "id" => id} = frame) do
    state =
      case {method, frame} do
        # session/load replays the conversation before it answers, under
        # the id it names: route that id to this chat from now on
        {"session/load", %{"params" => %{"sessionId" => sid}}} when is_binary(sid) ->
          put_session(state, sid, owner)

        _ ->
          state
      end

    forward_request(state, owner, id, frame)
  end

  # a notification (session/cancel) or the chat's answer to an agent request:
  # both already carry the agent's own ids
  defp from_client(state, _owner, frame), do: send_adapter(state, frame)

  defp forward_request(state, owner, id, frame) do
    hub_id = state.next_id

    state
    |> Map.put(:next_id, hub_id + 1)
    |> put_in([:pending, hub_id], {owner, id, frame["method"]})
    |> send_adapter(Map.put(frame, "id", hub_id))
  end

  defp send_adapter(state, frame) do
    state.transport.send_frame(state.tp, JsonRpc.encode(frame))
    state
  end

  # --- adapter -> chat ----------------------------------------------------------

  defp ingest(state, data) do
    {frames, partial} = JsonRpc.decode_lines(state.partial <> data)
    Enum.reduce(frames, %{state | partial: partial}, &from_adapter(&2, &1))
  end

  # an answer to one of our requests
  defp from_adapter(state, %{"id" => hub_id} = frame) when not is_map_key(frame, "method") do
    {entry, pending} = Map.pop(state.pending, hub_id)
    state = %{state | pending: pending}

    case entry do
      {:init, nil, _} ->
        init =
          case frame do
            %{"result" => result} -> {:ok, result}
            %{"error" => err} -> {:error, err}
            _ -> {:error, %{"code" => -32603, "message" => "bad initialize answer"}}
          end

        # a failed initialize is not cached: the next chat tries again
        state = %{state | init: if(match?({:ok, _}, init), do: init, else: nil)}

        state.init_waiters
        |> Enum.reverse()
        |> Enum.reduce(%{state | init_waiters: []}, fn {owner, id}, st ->
          to_client(st, owner, Map.put(frame, "id", id))
        end)

      {:hub, _, _} ->
        state

      {owner, id, method} ->
        state =
          case {method, frame} do
            {"session/new", %{"result" => %{"sessionId" => sid}}} -> put_session(state, sid, owner)
            _ -> state
          end

        if Map.has_key?(state.clients, owner),
          do: to_client(state, owner, Map.put(frame, "id", id)),
          else: state

      nil ->
        state
    end
  end

  # the agent's requests and notifications belong to the session they name
  defp from_adapter(state, %{"method" => _} = frame) do
    sid = get_in(frame, ["params", "sessionId"])

    case Map.fetch(state.sessions, sid) do
      {:ok, owner} ->
        to_client(state, owner, frame)

      :error when is_binary(sid) and not is_map_key(frame, "id") ->
        # the agent may speak of a session before its session/new answer
        # lands; keep that until the answer names the owner
        if session_new_pending?(state),
          do: Map.update!(state, :early, fn e -> Map.update(e, sid, [frame], &Enum.take([frame | &1], @early_max)) end),
          else: state

      :error when is_map_key(frame, "id") ->
        send_adapter(state, JsonRpc.error(frame["id"], -32602, "unknown session: #{inspect(sid)}", []))

      :error ->
        state
    end
  end

  defp from_adapter(state, _frame), do: state

  defp session_new_pending?(state),
    do: Enum.any?(state.pending, fn {_, {_, _, m}} -> m == "session/new" end)

  defp put_session(state, sid, owner) do
    {early, rest} = Map.pop(state.early, sid, [])
    state = %{state | sessions: Map.put(state.sessions, sid, owner), early: rest}
    early |> Enum.reverse() |> Enum.reduce(state, &to_client(&2, owner, &1))
  end

  defp to_client(state, owner, frame) do
    send(owner, {:acp_data, IO.iodata_to_binary(JsonRpc.encode(frame))})
    state
  end

  # --- leaving ------------------------------------------------------------------

  defp drop_client(state, owner) do
    case Map.pop(state.clients, owner) do
      {nil, _} ->
        state

      {ref, clients} ->
        Process.demonitor(ref, [:flush])
        {mine, others} = Enum.split_with(state.sessions, fn {_, o} -> o == owner end)
        state = %{state | clients: clients, sessions: Map.new(others)}

        state =
          Enum.reduce(mine, state, fn {sid, _}, st -> close_session(st, sid) end)

        pending = Map.reject(state.pending, fn {_, {o, _, _}} -> o == owner end)
        waiters = Enum.reject(state.init_waiters, fn {o, _} -> o == owner end)
        maybe_linger(%{state | pending: pending, init_waiters: waiters})
    end
  end

  # the session leaves the adapter with its chat, when the agent can let it go
  defp close_session(state, sid) do
    if can_close?(state) do
      hub_id = state.next_id

      state
      |> Map.put(:next_id, hub_id + 1)
      |> put_in([:pending, hub_id], {:hub, nil, "session/close"})
      |> send_adapter(JsonRpc.request(hub_id, "session/close", %{"sessionId" => sid}, []))
    else
      state
    end
  end

  defp can_close?(%{init: {:ok, result}}),
    do: is_map(get_in(result, ["agentCapabilities", "sessionCapabilities", "close"]))

  defp can_close?(_), do: false

  defp maybe_linger(%{clients: clients, linger: nil} = state) when map_size(clients) == 0,
    do: %{state | linger: Process.send_after(self(), :linger, linger_ms())}

  defp maybe_linger(state), do: state

  defp cancel_linger(%{linger: nil} = state), do: state

  defp cancel_linger(state) do
    Process.cancel_timer(state.linger)
    %{state | linger: nil}
  end

  defp linger_ms, do: Application.get_env(:compos_core, :acp_hub_linger_ms, @linger_ms)

  # every chat learns its adapter is gone; the hub goes with it, and the next
  # chat to start opens a new one
  defp adapter_exit(state, status) do
    Logger.warning("shared ACP adapter #{state.cmd} exited (#{inspect(status)}), #{map_size(state.clients)} chats")
    for {owner, _} <- state.clients, do: send(owner, {:acp_exit, status})
    {:stop, :normal, state}
  end
end

defmodule Compos.Core.Agent.Transport.Shared do
  @moduledoc """
  The transport of a chat whose adapter is shared (`Compos.Core.Agent.ACPHub`).
  The chat's backend sees the same `{:acp_data, _}` / `{:acp_exit, _}`
  messages a private port gives it.
  """

  @behaviour Compos.Core.Agent.Transport

  alias Compos.Core.Agent.ACPHub

  @impl true
  def open(cmd, opts, owner), do: open(cmd, Keyword.delete(opts, :cd), owner, 2)

  # a hub whose linger fired between the lookup and the join is gone: the
  # next lookup starts a fresh one
  defp open(cmd, opts, owner, tries) do
    hub = ACPHub.checkout(cmd, opts)
    :ok = ACPHub.join(hub, owner)
    {:ok, {hub, owner}}
  catch
    :exit, _ when tries > 1 -> open(cmd, opts, owner, tries - 1)
  end

  @impl true
  def send_frame({hub, owner}, data) do
    ACPHub.send_frame(hub, owner, data)
    :ok
  end

  @impl true
  def close({hub, owner}) do
    ACPHub.leave(hub, owner)
    :ok
  end
end
