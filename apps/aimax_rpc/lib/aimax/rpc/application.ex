defmodule Aimax.Rpc.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Aimax.Rpc.ConnSupervisor},
      {Aimax.Rpc.Server, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Rpc.Supervisor)
  end
end
