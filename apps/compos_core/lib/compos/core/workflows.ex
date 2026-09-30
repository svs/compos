defmodule Compos.Core.Workflows do
  @moduledoc """
  The workflows: a registry by name and a supervisor that restarts each
  `Compos.Core.Workflow` on its own. A workflow crashing takes nothing else
  with it, and comes back reading its position from the log.

  Scheme defines workflows (`define-workflow!` in workflows.scm) when its
  package loads, so after a daemon restart they come back as the packages
  load. `define/1` is idempotent: defining a running workflow again
  reconfigures it in place, and its position is untouched.
  """

  use Supervisor

  alias Compos.Core.Workflow

  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: Compos.Core.WorkflowRegistry},
        {DynamicSupervisor, name: Compos.Core.WorkflowSupervisor, strategy: :one_for_one}
      ],
      strategy: :rest_for_one
    )
  end

  @doc """
  Start the tree if the application did not: a daemon that booted before
  this module existed gets it under the lane supervisor, and the next boot
  starts it from the application.
  """
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        spec = %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, type: :supervisor}

        case DynamicSupervisor.start_child(Compos.Core.LaneSupervisor, spec) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> other
        end

      _ ->
        :ok
    end
  end

  @doc "Start the workflow SPEC names, or reconfigure it when it runs. SPEC needs :name and :listen."
  def define(%{name: name, listen: listen} = spec) when is_binary(name) and is_list(listen) do
    :ok = ensure_started()

    case Workflow.whereis(name) do
      nil ->
        case DynamicSupervisor.start_child(Compos.Core.WorkflowSupervisor, Workflow.child_spec(spec)) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> Workflow.configure(name, spec)
          {:error, reason} -> {:error, inspect(reason)}
        end

      _pid ->
        Workflow.configure(name, spec)
    end
  end

  @doc "Stop the workflow NAME. Its position stays in the log, so defining it again resumes."
  def stop(name) do
    case Workflow.whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Compos.Core.WorkflowSupervisor, pid)
    end
  end

  @doc "The names of the running workflows."
  def names do
    if Process.whereis(Compos.Core.WorkflowRegistry),
      do: Registry.select(Compos.Core.WorkflowRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort(),
      else: []
  end
end
