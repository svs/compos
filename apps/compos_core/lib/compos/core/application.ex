defmodule Compos.Core.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # One daemon per home, and the socket is the lock. A second daemon used
    # to remove the live socket and bind its own (Compos.Rpc.Server.init), so
    # two daemons served one home. Both then saved the desktop, and the one
    # that never installed the restored globals wrote its empty set over the
    # good file: on 2026-09-09 that lost every group, every graveyard entry
    # and every LLM bundle. The probe runs before the supervision tree, so a
    # second daemon dies before it can restore or save anything.
    case live_daemon(daemon_socket_path()) do
      nil ->
        start_tree()

      path ->
        message =
          "another compos daemon already serves #{Compos.Core.home()} " <>
            "(it answers on #{path}). Stop that one first, or point this one " <>
            "at another home with COMPOS_HOME."

        Logger.error(message)
        {:error, message}
    end
  end

  defp start_tree do
    # Before anything can ask for structure. A bundled grammar is part
    # of the editor the way the compiled-in four are, and a mode that
    # reads one must not race its arrival — an empty answer from the
    # parser reads exactly like an empty buffer. Already built, this is
    # a stat and a dlopen; the compile happens once, when a source moves.
    Compos.Core.TreeSitter.load_bundled()

    children = [
      {Registry, keys: :unique, name: Compos.Core.BufferRegistry},
      {Registry, keys: :duplicate, name: Compos.Core.EventRegistry},
      {Registry, keys: :unique, name: Compos.Core.TerminalRegistry},
      {Registry, keys: :unique, name: Compos.Core.AgentRegistry},
      {Registry, keys: :unique, name: Compos.Core.MCPRegistry},
      {Registry, keys: :unique, name: Compos.Core.LSPRegistry},
      {Registry, keys: :unique, name: Compos.Core.EndpointRegistry},
      {Registry, keys: :unique, name: Compos.Core.DBRegistry},
      {Registry, keys: :unique, name: Compos.Core.WebServerRegistry},
      {Registry, keys: :unique, name: Compos.Core.SchemeTaskRegistry},
      {DynamicSupervisor, name: Compos.Core.BufferSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.TerminalSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.MCPSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.LSPSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.EndpointSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.DBSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.WebServerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.SchemeTaskSupervisor, strategy: :one_for_one},
      Compos.Core.SchemeReadLimiter,
      # before Session: it owns the Scheme world's ETS tables so a Session
      # crash cannot destroy them, and Session empties them during init
      Compos.Core.SchemeTables,
      # Scheme execution lanes: serial workers, one per group/agent/conn,
      # started lazily — must be up before Session so callbacks fired
      # during the stdlib load have somewhere to run
      {Registry, keys: :unique, name: Compos.Core.LaneRegistry},
      {DynamicSupervisor, name: Compos.Core.LaneSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Compos.Core.TaskSupervisor},
      Compos.Core.Telemetry,
      # the durable event log; Session tells it nothing, it tells Session
      Compos.Core.Events.Log,
      # before BufferStore and every buffer: a buffer publishes its row from
      # init, so the table must already exist when the first one starts
      Compos.Core.BufferView,
      Compos.Core.BufferStore,
      Compos.Core.Reactor,
      Compos.Core.Watch,
      Compos.Core.Editor,
      Compos.Core.Input,
      # before Session: chrome.scm registers its request handler while the
      # stdlib loads, and a cast to a process that isn't up yet is silently
      # dropped — the browser would then be told this daemon serves nothing
      Compos.Core.Browser,
      Compos.Core.Google,
      # before Session: Scheme calls define-workflow! while the packages load,
      # and a define that finds no tree starts one under the lane supervisor.
      # The application would then find its own child already started and
      # fail to boot. A workflow waits for Session.ready? before it runs.
      Compos.Core.Workflows,
      Compos.Core.Session,
      Compos.Core.Desktop,
      # dev: a saved source file reaches this daemon without a restart
      Compos.Core.Hotload,
      %{
        id: Compos.Core.SchemeWarmup,
        start: {Compos.Core.SchemeWarmup, :start_link, [[]]},
        restart: :temporary
      },
      # one-shot: register the grammars the user installed. These are
      # the reader's own, so they can arrive after the frame does.
      %{
        id: :grammar_boot,
        start: {Task, :start_link, [&Compos.Core.TreeSitter.load_installed/0]},
        restart: :temporary
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Compos.Core.Supervisor)
  end

  # --- one daemon per home ----------------------------------------------------

  defp daemon_socket_path do
    Application.get_env(:compos_rpc, :socket_path) ||
      Path.join(Compos.Core.home(), "sock")
  end

  @probe ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{}}\n)

  # The socket PATH when a daemon answers on it, else nil. A socket file with
  # nothing behind it refuses the connection, which is the stale case, and the
  # RPC server removes it on the way up as it always did.
  defp live_daemon(path) do
    if Application.get_env(:compos_core, :single_daemon_guard, true) and File.exists?(path) do
      case :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false], 1_000) do
        {:ok, sock} ->
          :gen_tcp.send(sock, @probe)
          answer = :gen_tcp.recv(sock, 0, 2_000)
          :gen_tcp.close(sock)

          case answer do
            {:ok, line} -> if String.contains?(to_string(line), "pong"), do: path
            _ -> nil
          end

        _ ->
          nil
      end
    end
  end
end
