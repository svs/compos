defmodule Compos.Rpc.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Compos.Rpc.ConnSupervisor},
      {Compos.Rpc.Server, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Compos.Rpc.Supervisor)
  end
end
