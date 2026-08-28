defmodule Aimax.Core.Lane do
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

  alias Aimax.Core.Buffer

  @registry Aimax.Core.LaneRegistry
  @supervisor Aimax.Core.LaneSupervisor
  @single_lane :scheme

  @doc "The configured Scheme scheduler: :lanes or :single_actor."
  def execution_mode do
    Application.get_env(:aimax_core, :scheme_execution, :lanes)
  end

  @doc "Resolve a logical owner to its execution lane."
  def route(key) do
    case execution_mode() do
      :lanes -> key
      :single_actor -> @single_lane
    end
  end

  @doc "The lane key of the running worker, or nil outside a lane."
  def current, do: Process.get(:aimax_scheme_lane)

  @doc """
  Run FUN in the lane named by KEY and return its reply. FUN receives the
  GenServer `from` of the lane call (or nil when run inline) and returns
  `{:reply, value}`, or `:noreply` after claiming the reply slot
  (eval-defer!). A call from inside the lane's own worker runs inline —
  re-entry must not deadlock.

  LABEL names the job in telemetry and the slow-job log. A caller that
  times out logs the worker's current stack under the label, so a stuck
  lane names the job that holds it.
  """
  def run(key, fun, timeout \\ 30_000, label \\ "") do
    logical_key = key
    key = route(key)
    pid = whereis(key)
    enqueued_at = System.monotonic_time(:millisecond)

    if pid == self() do
      {:reply, value} = fun.(nil)
      value
    else
      try do
        GenServer.call(pid, {:run, fun, label, logical_key, enqueued_at}, timeout)
      catch
        # the worker idled out between lookup and call: take a fresh one
        :exit, {:noproc, _} ->
          GenServer.call(
            whereis(key),
            {:run, fun, label, logical_key, enqueued_at},
            timeout
          )

        # the lane is held past the caller's deadline: say by what, and
        # where it is stuck — this line is the whole diagnosis of a
        # frozen lane, so it must fire in production, not in a debugger
        :exit, {:timeout, _} = reason ->
          {stack, running} = worker_state(pid)

          Logger.warning(
            "lane #{inspect(key)} owner #{inspect(logical_key)}: #{label} " <>
              "timed out after #{timeout}ms " <>
              "while the worker runs #{running}; worker at #{stack}"
          )

          exit(reason)
      end
    end
  end

  defp worker_state(pid) do
    stack =
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, frames} ->
          frames |> Enum.take(4) |> Enum.map_join(" < ", &Exception.format_stacktrace_entry/1)

        _ ->
          "dead worker"
      end

    running =
      case :ets.lookup(jobs_table(), pid) do
        [{^pid, label, t0}] ->
          "#{label} (#{System.monotonic_time(:millisecond) - t0}ms in)"

        [] ->
          "no job"
      end

    {stack, running}
  end

  @doc "The running job per worker pid: {pid, label, started_at_ms}."
  def jobs_table do
    case :ets.whereis(:aimax_lane_jobs) do
      :undefined ->
        :ets.new(:aimax_lane_jobs, [:named_table, :public, :set, read_concurrency: true])
      _tid -> :aimax_lane_jobs
    end
  end

  @doc "Run FUN in the lane without waiting; the reply is discarded."
  def cast(key, fun, label \\ "") do
    logical_key = key
    key = route(key)
    enqueued_at = System.monotonic_time(:millisecond)

    GenServer.cast(
      whereis(key),
      {:run, fun, label, logical_key, enqueued_at}
    )
  end

  @doc "Kill the lane's worker; queued work is lost, the store survives."
  def kill(key) do
    key = route(key)

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
    case Buffer.exists?(name) && Map.get(Buffer.locals(name), "group") do
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

    # an idle worker retires: per-connection and per-buffer lanes would
    # otherwise pile up one process each for the life of the daemon
    @idle 300_000

    def start_link(key) do
      GenServer.start_link(__MODULE__, key,
        name: {:via, Registry, {Aimax.Core.LaneRegistry, key}}
      )
    end

    @impl true
    def init(key) do
      Process.put(:aimax_scheme_lane, key)
      {:ok, key, @idle}
    end

    # one slow job is one frozen lane: report every job's duration as
    # telemetry, and put the slow ones in the log by name
    @slow_ms 250

    @impl true
    def handle_call({:run, fun, label, owner, enqueued_at}, from, key) do
      case timed(key, owner, label, enqueued_at, fn -> guarded(fun, from) end) do
        {:reply, value} -> {:reply, value, key, @idle}
        # the fun claimed the reply slot (eval-defer!): it answers later
        # through GenServer.reply — this worker moves on at once
        :noreply -> {:noreply, key, @idle}
      end
    end

    @impl true
    def handle_cast({:run, fun, label, owner, enqueued_at}, key) do
      timed(key, owner, label, enqueued_at, fn -> guarded(fun, nil) end)
      {:noreply, key, @idle}
    end

    # A job that raises outside the Session's own safe() wrapper must
    # fail its caller, never this worker: a dead worker takes every
    # queued job in the lane down with it.
    defp guarded(fun, from) do
      fun.(from)
    rescue
      e -> {:reply, {:error, Exception.message(e)}}
    catch
      :exit, reason -> {:reply, {:error, "exit: #{inspect(reason)}"}}
    end

    defp timed(key, owner, label, enqueued_at, fun) do
      t0 = System.monotonic_time(:millisecond)
      queue_time = max(t0 - enqueued_at, 0)
      {:message_queue_len, backlog} = Process.info(self(), :message_queue_len)
      :ets.insert(Aimax.Core.Lane.jobs_table(), {self(), label, t0})

      try do
        fun.()
      after
        ms = System.monotonic_time(:millisecond) - t0
        :ets.delete(Aimax.Core.Lane.jobs_table(), self())

        :telemetry.execute(
          [:aimax, :lane, :job],
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
    def handle_info(:timeout, key), do: {:stop, :normal, key}
    def handle_info(_msg, key), do: {:noreply, key, @idle}
  end
end
