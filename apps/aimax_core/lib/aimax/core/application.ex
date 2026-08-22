defmodule Aimax.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Aimax.Core.BufferRegistry},
      {Registry, keys: :duplicate, name: Aimax.Core.EventRegistry},
      {Registry, keys: :unique, name: Aimax.Core.ProcRegistry},
      {Registry, keys: :unique, name: Aimax.Core.AgentRegistry},
      {Registry, keys: :unique, name: Aimax.Core.MCPRegistry},
      {Registry, keys: :unique, name: Aimax.Core.LSPRegistry},
      {DynamicSupervisor, name: Aimax.Core.BufferSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Aimax.Core.ProcSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Aimax.Core.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Aimax.Core.MCPSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Aimax.Core.LSPSupervisor, strategy: :one_for_one},
      # Scheme execution lanes: serial workers, one per group/agent/conn,
      # started lazily — must be up before Session so callbacks fired
      # during the stdlib load have somewhere to run
      {Registry, keys: :unique, name: Aimax.Core.LaneRegistry},
      {DynamicSupervisor, name: Aimax.Core.LaneSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Aimax.Core.TaskSupervisor},
      Aimax.Core.BufferStore,
      Aimax.Core.ProvenanceStore,
      Aimax.Core.Reactor,
      Aimax.Core.Watch,
      Aimax.Core.Editor,
      Aimax.Core.Input,
      # before Session: chrome.scm registers its request handler while the
      # stdlib loads, and a cast to a process that isn't up yet is silently
      # dropped — the browser would then be told this daemon serves nothing
      Aimax.Core.Browser,
      Aimax.Core.Session,
      Aimax.Core.Desktop,
      Aimax.Core.LLMDb,
      # one-shot: register user-installed grammars with the NIF
      %{
        id: :grammar_boot,
        start: {Task, :start_link, [&Aimax.Core.TreeSitter.load_installed/0]},
        restart: :temporary
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Core.Supervisor)
  end
end
