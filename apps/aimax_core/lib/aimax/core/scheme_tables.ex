defmodule Aimax.Core.SchemeTables do
  @moduledoc """
  The owner of the Scheme world's ETS tables, and nothing else.

  An ETS table dies with the process that created it. `Aimax.Core.Session`
  created all three of the Scheme world's tables and also runs the riskiest
  code in the daemon: it loads the stdlib, reloads changed files, rebinds
  primitives and sweeps frames. One crash there took every registered
  command, every escaped closure and the whole environment with it, and
  every lane worker holding the published interpreter handle then raised on
  a dead table id.

  This process holds the tables and runs no Scheme. It cannot crash from
  anything Scheme does, so the tables outlive a Session restart:

  - the two named tables are created once, here. Session empties and
    refills them rather than creating them, so their identity is stable
    across a restart and no lane worker ever sees them vanish.
  - the environment table is created by `Scheme.new` inside Session, which
    is where it has to be. Session names this process its heir, so the
    table transfers here instead of dying. In-flight lane work finishes
    against it while the new Session builds its replacement.

  An inherited environment is a previous Session's world. Nothing reads it
  once the new Session publishes, so it is dropped after a grace period
  rather than kept: keeping it would leak a whole heap per crash.
  """

  use GenServer

  require Logger

  # how long an inherited environment stays alive. Long enough for a lane
  # worker mid-evaluation to finish against it, short enough that a crash
  # loop does not hold many heaps at once.
  @grace 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The named tables the Scheme world uses. Created here, emptied by Session.
  """
  def named_tables, do: [Aimax.Core.SchemeAPI.commands_table(), :aimax_escaped_closures]

  @doc """
  Make this process the heir of TID, so a Session crash hands the table over
  instead of destroying it. Answers :ok whether or not it worked: an
  environment with no heir is the behaviour this replaces, not a failure.
  """
  def adopt(tid) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> set_heir(tid, pid)
    end
  end

  defp set_heir(tid, pid) do
    :ets.setopts(tid, {:heir, pid, :scheme_env})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empty a named table without changing its identity."
  def reset(table) do
    :ets.delete_all_objects(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_) do
    for table <- named_tables() do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
        _ -> :ok
      end
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", tid, from, :scheme_env}, state) do
    Logger.info("scheme env inherited from #{inspect(from)}; dropping in #{@grace}ms")
    Process.send_after(self(), {:drop, tid}, @grace)
    {:noreply, Map.put(state, tid, from)}
  end

  def handle_info({:drop, tid}, state) do
    try do
      :ets.delete(tid)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, Map.delete(state, tid)}
  end

  def handle_info(_, state), do: {:noreply, state}
end
