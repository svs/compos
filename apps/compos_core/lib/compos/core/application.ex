defmodule Compos.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Compos.Core.BufferRegistry},
      {Registry, keys: :duplicate, name: Compos.Core.EventRegistry},
      {Registry, keys: :unique, name: Compos.Core.ProcRegistry},
      {Registry, keys: :unique, name: Compos.Core.TerminalRegistry},
      {Registry, keys: :unique, name: Compos.Core.AgentRegistry},
      {Registry, keys: :unique, name: Compos.Core.MCPRegistry},
      {Registry, keys: :unique, name: Compos.Core.LSPRegistry},
      {Registry, keys: :unique, name: Compos.Core.EndpointRegistry},
      {Registry, keys: :unique, name: Compos.Core.DBRegistry},
      {Registry, keys: :unique, name: Compos.Core.WebServerRegistry},
      {Registry, keys: :unique, name: Compos.Core.SchemeActorRegistry},
      {Registry, keys: :unique, name: Compos.Core.SchemeTaskRegistry},
      {DynamicSupervisor, name: Compos.Core.BufferSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.ProcSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.TerminalSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.MCPSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.LSPSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.EndpointSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.DBSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.WebServerSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Compos.Core.SchemeActorSupervisor, strategy: :one_for_one},
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
      Compos.Core.Session,
      Compos.Core.Desktop,
      # dev: a saved source file reaches this daemon without a restart
      Compos.Core.Hotload,
      %{
        id: Compos.Core.SchemeWarmup,
        start: {Compos.Core.SchemeWarmup, :start_link, [[]]},
        restart: :temporary
      },
      Compos.Core.LLMDb,
      # one-shot: register user-installed grammars with the NIF
      %{
        id: :grammar_boot,
        start: {Task, :start_link, [&Compos.Core.TreeSitter.load_installed/0]},
        restart: :temporary
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Compos.Core.Supervisor)
  end
end
