defmodule Compos.Core.SchemeReadLimiter do
  @moduledoc """
  Global admission control for concurrent shared-world Scheme reads.

  A turn may fan out four reads, but many simultaneous agents must not turn
  that local policy into an unbounded evaluator stampede. Waiting callers are
  monitored, so cancellation removes them without leaking a slot.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run FUN while holding one global Scheme read slot."
  def run(fun) when is_function(fun, 0) do
    token = GenServer.call(__MODULE__, :acquire, :infinity)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, token})
    end
  end

  @doc "The configured maximum number of concurrently evaluating read tasks."
  def limit, do: GenServer.call(__MODULE__, :limit)

  @impl true
  def init(_opts) do
    default = System.schedulers_online() |> max(4) |> min(16)
    limit = Application.get_env(:compos_core, :scheme_read_global_concurrency, default)
    {:ok, %{limit: max(1, limit), active: %{}, monitors: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_call(:limit, _from, state), do: {:reply, state.limit, state}

  def handle_call(:acquire, from, state) when map_size(state.active) < state.limit do
    {token, state} = admit(from, state)
    {:reply, token, state}
  end

  def handle_call(:acquire, from, state) do
    pid = elem(from, 0)
    id = make_ref()
    monitor = Process.monitor(pid)
    queue = :queue.in({id, from, pid, monitor}, state.queue)
    monitors = Map.put(state.monitors, monitor, {:queued, id})
    {:noreply, %{state | queue: queue, monitors: monitors}}
  end

  @impl true
  def handle_cast({:release, token}, state) do
    {:noreply, state |> release(token) |> admit_waiters()}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      case Map.pop(state.monitors, monitor) do
        {{:active, token}, monitors} ->
          %{state | active: Map.delete(state.active, token), monitors: monitors}

        {{:queued, id}, monitors} ->
          queue = :queue.filter(fn {queued_id, _, _, _} -> queued_id != id end, state.queue)
          %{state | queue: queue, monitors: monitors}

        {nil, _monitors} ->
          state
      end

    {:noreply, admit_waiters(state)}
  end

  defp admit(from, state) do
    pid = elem(from, 0)
    token = make_ref()
    monitor = Process.monitor(pid)

    state = %{
      state
      | active: Map.put(state.active, token, {pid, monitor}),
        monitors: Map.put(state.monitors, monitor, {:active, token})
    }

    {token, state}
  end

  defp admit_queued({from, pid, monitor}, state) do
    token = make_ref()

    state = %{
      state
      | active: Map.put(state.active, token, {pid, monitor}),
        monitors: Map.put(state.monitors, monitor, {:active, token})
    }

    GenServer.reply(from, token)
    state
  end

  defp release(state, token) do
    case Map.pop(state.active, token) do
      {{_pid, monitor}, active} ->
        Process.demonitor(monitor, [:flush])
        %{state | active: active, monitors: Map.delete(state.monitors, monitor)}

      {nil, _active} ->
        state
    end
  end

  defp admit_waiters(state) when map_size(state.active) >= state.limit, do: state

  defp admit_waiters(state) do
    case :queue.out(state.queue) do
      {{:value, {_id, from, pid, monitor}}, queue} ->
        state = %{state | queue: queue}

        if Process.alive?(pid) do
          {from, pid, monitor} |> admit_queued(state) |> admit_waiters()
        else
          Process.demonitor(monitor, [:flush])
          state = %{state | monitors: Map.delete(state.monitors, monitor)}
          admit_waiters(state)
        end

      {:empty, _queue} ->
        state
    end
  end
end
