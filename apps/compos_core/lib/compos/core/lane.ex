defmodule Compos.Core.Lane do
  @moduledoc """
  Group-local execution lanes for Scheme.

  A lane is a serial worker process. Scheme executions in one lane run in
  order; executions in different lanes run concurrently — the BEAM
  preempts them. The `:ui` lane is the Emacs main thread: keystrokes and
  minibuffer callbacks. Agent, LLM, and RPC work runs in its own lane, so
  a long tool call or MCP wait never delays a keystroke.

  Lane keys: `:ui`, `{:group, g}`, `{:buffer, name}`, `{:rpc, pid}`,
  `{:agent, slug}` — any term. `for_buffer/1` resolves a buffer to its
  group lane, so every buffer of one project shares one lane and
  cross-buffer invariants inside the group hold.

  Workers start lazily and are `:temporary`: `kill/1` (C-g on a runaway
  eval) just discards the process — the Scheme world lives in the shared
  ETS store and the buffers, so nothing is lost — and the next run gets a
  fresh worker.
  """

  require Logger

  alias Compos.Core.{Buffer, SchemeHeap}

  @registry Compos.Core.LaneRegistry
  @supervisor Compos.Core.LaneSupervisor
  @jobs_table :compos_lane_jobs

  @doc "The lane key of the running worker, or nil outside a lane."
  def current, do: Process.get(:compos_scheme_lane)

  @doc """
  Run FUN in the lane named by KEY and return its reply. FUN receives the
  GenServer `from` of the lane call (or nil when run inline) and returns
  `{:reply, value}`, or `:noreply` after claiming the reply slot
  (eval-defer!). A call from inside the lane's current job runs inline, so
  re-entry cannot deadlock.

  LABEL names the job in telemetry and the slow-job log. A caller that
  times out logs the worker's current stack under the label, so a stuck
  lane names the job that holds it.
  """
  def run(key, fun, timeout \\ 30_000, label \\ "") do
    logical_key = key

    if current() == key do
      {:reply, value} = fun.(nil)
      value
    else
      call_worker(
        whereis(key),
        key,
        logical_key,
        make_ref(),
        fun,
        label,
        System.monotonic_time(:millisecond),
        timeout,
        20
      )
    end
  end

  defp call_worker(pid, key, owner, job_id, fun, label, enqueued_at, timeout, retries) do
    try do
      GenServer.call(pid, {:run, job_id, fun, label, owner, enqueued_at}, timeout)
    catch
      # The worker idled out between lookup and call: take a fresh one. The
      # replacement call keeps the same job identity and cancellation path.
      # A worker that retires on its idle timeout as the call arrives exits
      # :normal before it took the job, so a fresh worker runs it once.
      :exit, {reason, _} when reason in [:noproc, :normal] and retries > 0 ->
        Process.sleep(1)

        call_worker(
          whereis(key),
          key,
          owner,
          job_id,
          fun,
          label,
          enqueued_at,
          timeout,
          retries - 1
        )

      # The caller deadline owns the work. Tell the serial worker to kill this
      # exact active job; a queued or already-finished job cannot match it.
      :exit, {:timeout, _} = reason ->
        {stack, running} = worker_state(pid)
        send(pid, {:cancel_job, job_id, self()})

        Logger.warning(
          "lane #{inspect(key)} owner #{inspect(owner)}: #{label} " <>
            "timed out after #{timeout}ms " <>
            "while the worker runs #{running}; worker at #{stack}"
        )

        exit(reason)
    end
  end

  defp worker_state(pid) do
    case :ets.lookup(jobs_table(), pid) do
      [{^pid, job_pid, label, t0}] ->
        {process_stack(job_pid), "#{label} (#{System.monotonic_time(:millisecond) - t0}ms in)"}

      [] ->
        {process_stack(pid), "no job"}
    end
  end

  defp process_stack(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, frames} ->
        frames |> Enum.take(4) |> Enum.map_join(" < ", &Exception.format_stacktrace_entry/1)

      _ ->
        "dead worker"
    end
  end

  @doc "The running job per worker pid: {worker, job, label, started_at_ms}."
  def jobs_table do
    Compos.Core.SchemeTables.ensure_table(@jobs_table)
    @jobs_table
  end

  @doc "Run FUN in the lane without waiting; the reply is discarded."
  def cast(key, fun, label \\ "") do
    logical_key = key
    enqueued_at = System.monotonic_time(:millisecond)

    GenServer.cast(
      whereis(key),
      {:run, fun, label, logical_key, enqueued_at}
    )
  end

  @doc "Kill the lane's worker; queued work is lost, the store survives."
  def kill(key) do

    case Registry.lookup(@registry, key) do
      [{pid, _}] -> Process.exit(pid, :kill)
      [] -> :ok
    end

    :ok
  end

  @doc """
  The lane a buffer's Scheme belongs to: the buffer's group when it has
  one, else the buffer itself.
  """
  def for_buffer(name) do
    # one local, not the whole map: a large local copies with the map
    case Buffer.exists?(name) && Buffer.get_local(name, "group") do
      g when is_binary(g) -> {:group, g}
      _ -> {:buffer, name}
    end
  rescue
    _ -> {:buffer, name}
  catch
    :exit, _ -> {:buffer, name}
  end

  defp whereis(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] ->
        pid

      [] ->
        spec = %{
          id: __MODULE__.Worker,
          start: {__MODULE__.Worker, :start_link, [key]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defmodule Worker do
    @moduledoc false
    use GenServer

    require Logger

    alias Compos.Core.SchemeHeap

    # an idle worker retires: per-connection and per-buffer lanes would
    # otherwise pile up one process each for the life of the daemon
    @idle 300_000

    def start_link(key) do
      GenServer.start_link(__MODULE__, key,
        name: {:via, Registry, {Compos.Core.LaneRegistry, key}}
      )
    end

    @impl true
    def init(key) do
      Process.flag(:trap_exit, true)
      SchemeHeap.apply_to_self()
      Process.put(:compos_scheme_lane, key)
      {:ok, key, @idle}
    end

    # one slow job is one frozen lane: report every job's duration as
    # telemetry, and put the slow ones in the log by name
    @slow_ms 250

    # A queued job whose caller is already gone is skipped. A running job lives
    # in its own process so this serial worker can observe caller death or a
    # timeout cancellation and kill only that job, preserving later callers.
    @impl true
    def handle_call(
          {:run, job_id, fun, label, owner, enqueued_at},
          {caller, _} = from,
          key
        ) do
      if Process.alive?(caller) do
        case run_call_job(key, job_id, caller, from, fun, label, owner, enqueued_at) do
          {:done, {:reply, value}} -> {:reply, value, key, @idle}
          # The fun claimed the reply slot (eval-defer!): it answers later
          # through GenServer.reply — this worker moves on at once.
          {:done, :noreply} ->
            Process.put(:compos_lane_deferred, [from | Enum.filter(deferred(), &pending?/1)])
            {:noreply, key, @idle}
          :cancelled -> {:noreply, key, @idle}
        end
      else
        :telemetry.execute(
          [:compos, :lane, :skipped],
          %{queue_time: max(System.monotonic_time(:millisecond) - enqueued_at, 0)},
          %{lane: key, owner: owner, label: label}
        )

        {:noreply, key, @idle}
      end
    end

    @impl true
    def handle_cast({:run, fun, label, owner, enqueued_at}, key) do
      {:message_queue_len, backlog} = Process.info(self(), :message_queue_len)
      timed(self(), key, owner, label, enqueued_at, backlog, fn -> guarded(fun, nil) end)
      {:noreply, key, @idle}
    end

    defp run_call_job(key, job_id, caller, from, fun, label, owner, enqueued_at) do
      worker = self()
      caller_monitor = Process.monitor(caller)
      {:message_queue_len, backlog} = Process.info(worker, :message_queue_len)

      {job, job_monitor} =
        :erlang.spawn_opt(
          fn ->
            Process.put(:compos_scheme_lane, key)

            result =
              timed(worker, key, owner, label, enqueued_at, backlog, fn ->
                guarded(fun, from)
              end)

            send(worker, {:lane_job_result, job_id, result})
          end,
          [:link, :monitor | SchemeHeap.spawn_opts()]
        )

      await_call_job(job_id, caller, caller_monitor, job, job_monitor, key, owner, label)
    end

    defp await_call_job(job_id, caller, caller_monitor, job, job_monitor, key, owner, label) do
      receive do
        {:lane_job_result, ^job_id, result} ->
          Process.demonitor(caller_monitor, [:flush])
          Process.demonitor(job_monitor, [:flush])
          {:done, result}

        {:cancel_job, ^job_id, ^caller} ->
          cancel_call_job(job_id, caller_monitor, job, job_monitor, key, owner, label)

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          cancel_call_job(job_id, caller_monitor, job, job_monitor, key, owner, label)

        {:DOWN, ^job_monitor, :process, ^job, reason} ->
          Process.demonitor(caller_monitor, [:flush])
          :ets.delete(Compos.Core.Lane.jobs_table(), self())
          {:done, {:reply, {:error, job_exit_message(key, owner, label, reason)}}}
      end
    end

    # The heap bound kills the job process outright, so the reason is bare
    # `:killed`. Name the limit: a caller that reads "lane job exited" cannot
    # tell a runaway from a crash. This worker cancels its own job through
    # cancel_call_job/6, so a kill that arrives here came from the bound.
    defp job_exit_message(key, owner, label, :killed) do
      message = SchemeHeap.exceeded_message(label)
      Logger.warning("lane #{inspect(key)} owner #{inspect(owner)}: #{message}")
      message
    end

    defp job_exit_message(_key, _owner, _label, reason),
      do: "lane job exited: #{inspect(reason)}"

    defp cancel_call_job(job_id, caller_monitor, job, job_monitor, key, owner, label) do
      Process.exit(job, :kill)

      receive do
        {:DOWN, ^job_monitor, :process, ^job, _reason} -> :ok
      end

      Process.demonitor(caller_monitor, [:flush])
      :ets.delete(Compos.Core.Lane.jobs_table(), self())

      receive do
        {:lane_job_result, ^job_id, _result} -> :ok
      after
        0 -> :ok
      end

      :telemetry.execute(
        [:compos, :lane, :cancelled],
        %{},
        %{lane: key, owner: owner, label: label}
      )

      :cancelled
    end

    # A job that raises outside the Session's own safe() wrapper must fail its
    # caller, never this worker or later queued jobs.
    defp guarded(fun, from) do
      fun.(from)
    rescue
      e -> {:reply, {:error, Exception.message(e)}}
    catch
      :exit, reason -> {:reply, {:error, "exit: #{inspect(reason)}"}}
    end

    defp timed(worker, key, owner, label, enqueued_at, backlog, fun) do
      t0 = System.monotonic_time(:millisecond)
      queue_time = max(t0 - enqueued_at, 0)
      :ets.insert(Compos.Core.Lane.jobs_table(), {worker, self(), label, t0})

      try do
        fun.()
      after
        ms = System.monotonic_time(:millisecond) - t0
        :ets.delete(Compos.Core.Lane.jobs_table(), worker)

        :telemetry.execute(
          [:compos, :lane, :job],
          %{duration: ms, queue_time: queue_time, backlog: backlog},
          %{lane: key, owner: owner, label: label}
        )

        if ms > @slow_ms do
          require Logger

          Logger.warning(
            "lane #{inspect(key)} owner #{inspect(owner)}: slow job #{label} #{ms}ms"
          )
        end
      end
    end

    @impl true
    # A deferred caller still waits in GenServer.call, which monitors this
    # worker: retiring now would fail it with :normal. Stay while any reply
    # this worker handed to eval-resolve! is pending and its caller lives.
    def handle_info(:timeout, key) do
      case Enum.filter(deferred(), &pending?/1) do
        [] ->
          {:stop, :normal, key}

        waiting ->
          Process.put(:compos_lane_deferred, waiting)
          {:noreply, key, @idle}
      end
    end

    def handle_info(_msg, key), do: {:noreply, key, @idle}

    defp deferred, do: Process.get(:compos_lane_deferred, [])

    defp pending?({caller, _} = from) do
      table = Compos.Core.Roots.table()

      Process.alive?(caller) and :ets.whereis(table) != :undefined and
        :ets.match_object(table, {{:eval_pending, :_}, from}) != []
    end
  end
end
