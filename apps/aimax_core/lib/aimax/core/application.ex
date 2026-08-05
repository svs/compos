defmodule Aimax.Core.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Aimax.Core.BufferRegistry},
      {Registry, keys: :duplicate, name: Aimax.Core.EventRegistry},
      {Registry, keys: :unique, name: Aimax.Core.ProcRegistry},
      {DynamicSupervisor, name: Aimax.Core.BufferSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Aimax.Core.ProcSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Aimax.Core.TaskSupervisor},
      Aimax.Core.Reactor,
      Aimax.Core.Editor,
      Aimax.Core.Session
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Core.Supervisor)
  end
end
