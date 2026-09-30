defmodule Compos.Core.Workflow do
  @moduledoc """
  One workflow: a named, supervised consumer of the durable event log
  (`Compos.Core.Events.Log`) whose handler is Scheme.

  A workflow listens to topic patterns. The log tells it of every append
  by message; a matching one arms a quiet gap (capped by a longest wait, so
  a steady stream cannot starve it), and then the workflow reads the events
  after its position and hands them to Scheme as one batch:
  `(workflow--run NAME EVENTS)` on the lane `{:workflow, NAME}`, never on
  `:ui`, inside a supervised task with a timeout.

  Exactly once. While the batch runs, `emit!` and `once!` in Scheme do not
  write: they collect in the lane process (`:compos_workflow_txn`). When
  the handler returns, `Log.commit/5` writes the collected events, the once
  keys, an `obs:workflow:NAME` run event and the new position in one
  transaction, fenced on the position the batch was read from. A crash, a
  timeout or a rewind before the commit leaves nothing behind, and the
  batch runs again. What a handler does outside the log (a model call, an
  HTTP request) is at least once; an action that must not repeat is an
  event another workflow sends, keyed by once!.

  A failed batch waits out a backoff (doubling, with jitter, to a ceiling)
  and runs again; after `max_attempts` it is parked: a `parked` event on
  `workflow:NAME` records the range and the error, and the position moves
  past it in the same transaction.

  The state is the log. A workflow that crashes restarts under
  `Compos.Core.Workflows` and reads its position again; a daemon restart is
  the same, once Scheme defines the workflow again.

  Control is by message: pause, resume, step (one batch, then pause),
  rewind to a seq, and status.
  """

  use GenServer, restart: :permanent

  require Logger

  alias Compos.Core.{Lane, Session}
  alias Compos.Core.Events.Log

  @registry Compos.Core.WorkflowRegistry

  @defaults %{
    quiet_ms: 300,
    max_wait_ms: 2_000,
    batch: 200,
    max_attempts: 5,
    backoff_ms: 1_000,
    max_backoff_ms: 60_000,
    timeout_ms: 120_000
  }

  # --- api -------------------------------------------------------------------

  def start_link(spec), do: GenServer.start_link(__MODULE__, spec, name: via(spec.name))

  def child_spec(spec), do: %{id: {__MODULE__, spec.name}, start: {__MODULE__, :start_link, [spec]}}

  def via(name), do: {:via, Registry, {@registry, name}}

  def whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def position_name(name), do: "workflow:" <> name

  def status(name), do: call(name, :status)
  def pause(name), do: call(name, :pause)
  def resume(name), do: call(name, :resume)
  def step(name), do: call(name, :step)
  def rewind(name, seq), do: call(name, {:rewind, seq})
  def configure(name, spec), do: call(name, {:configure, spec})

  defp call(name, msg) do
    case whereis(name) do
      nil -> {:error, :no_workflow}
      pid -> GenServer.call(pid, msg)
    end
  end

  @doc "The spec with every option filled in."
  def normalize(spec), do: Map.merge(@defaults, spec)

  @doc "Whether TOPIC matches one of PATTERNS: a pattern ending in * is a prefix."
  def matches?(patterns, topic) do
    Enum.any?(patterns, fn p ->
      if String.ends_with?(p, "*"),
        do: String.starts_with?(topic, String.trim_trailing(p, "*")),
        else: p == topic
    end)
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(spec) do
    spec = normalize(spec)
    {:ok, _} = Registry.register(Compos.Core.EventRegistry, :event_log, nil)
    pos = position_name(spec.name)
    if Log.position(pos) == nil, do: Log.set_position(pos, Map.get(spec, :from) || Log.seq())
    send(self(), :wake)

    {:ok,
     %{
       spec: spec,
       status: :idle,
       stepping: false,
       timer: nil,
       first_pending: nil,
       run: nil,
       dirty: false,
       attempts: 0,
       last_error: nil,
       stats: %{runs: 0, handled: 0, parked: 0, failed: 0}
     }}
  end

  @impl true
  def handle_info({:event_appended, _seq, topic}, state) do
    if matches?(state.spec.listen, topic), do: {:noreply, wake(state)}, else: {:noreply, state}
  end

  def handle_info(:wake, state), do: {:noreply, wake(state)}

  def handle_info(:run, %{status: status} = state) when status in [:armed, :backoff],
    do: {:noreply, start_run(%{state | timer: nil})}

  def handle_info(:run, state), do: {:noreply, state}

  def handle_info({ref, {{tag, _} = result, txn}}, %{run: %{task: %Task{ref: ref}}} = state)
      when tag in [:ok, :error] do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.run.tref)

    case result do
      {:ok, _} -> {:noreply, finish_ok(state, txn || %{emits: [], onces: []})}
      {:error, msg} -> {:noreply, finish_fail(state, text(msg))}
    end
  end

  # a lane that answered something else: the batch did not run to the end
  def handle_info({ref, other}, %{run: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(state.run.tref)
    {:noreply, finish_fail(state, "the lane answered " <> inspect(other))}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{task: %Task{ref: ref}}} = state) do
    Process.cancel_timer(state.run.tref)
    {:noreply, finish_fail(state, "the handler died: " <> inspect(reason))}
  end

  def handle_info({:run_timeout, ref}, %{run: %{task: %Task{ref: ref} = task}} = state) do
    Task.shutdown(task, :brutal_kill)
    Lane.kill({:workflow, state.spec.name})
    {:noreply, finish_fail(state, "timed out after #{state.spec.timeout_ms}ms")}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    pos = Log.position(position_name(state.spec.name))

    {:reply,
     Map.merge(state.stats, %{
       name: state.spec.name,
       listen: state.spec.listen,
       status: if(state.stepping and state.status != :paused, do: :stepping, else: state.status),
       position: pos,
       head: Log.seq(),
       behind: length(Log.read_any(pos || 0, state.spec.listen, 1_000)),
       attempts: state.attempts,
       last_error: state.last_error,
       running_ms: state.run && System.monotonic_time(:millisecond) - state.run.started
     }), state}
  end

  def handle_call(:pause, _from, %{run: nil} = state), do: {:reply, :ok, paused(state)}
  def handle_call(:pause, _from, state), do: {:reply, :ok, %{state | stepping: true}}

  def handle_call(:resume, _from, state) do
    state = %{state | stepping: false}
    if state.status == :paused, do: send(self(), :wake)
    {:reply, :ok, if(state.status == :paused, do: %{state | status: :idle}, else: state)}
  end

  def handle_call(:step, _from, %{run: nil} = state) do
    state = cancel(%{state | stepping: true})
    send(self(), :run)
    {:reply, :ok, %{state | status: :armed}}
  end

  def handle_call(:step, _from, state), do: {:reply, :ok, %{state | stepping: true}}

  # the running batch, if any, is fenced off by the commit: it finds the
  # position moved and commits nothing
  def handle_call({:rewind, seq}, _from, state) do
    Log.set_position(position_name(state.spec.name), seq)
    if state.run == nil and state.status != :paused, do: send(self(), :wake)
    {:reply, :ok, state}
  end

  def handle_call({:configure, spec}, _from, state) do
    send(self(), :wake)
    {:reply, :ok, %{state | spec: normalize(spec)}}
  end

  # --- the run ---------------------------------------------------------------

  # a matching append: wait out the quiet gap, but never past the longest wait
  defp wake(%{status: :idle} = state) do
    now = System.monotonic_time(:millisecond)
    %{state | status: :armed, first_pending: now, timer: Process.send_after(self(), :run, state.spec.quiet_ms)}
  end

  defp wake(%{status: :armed} = state) do
    now = System.monotonic_time(:millisecond)
    left = state.spec.max_wait_ms - (now - (state.first_pending || now))
    state = cancel(state)
    %{state | status: :armed, timer: Process.send_after(self(), :run, max(0, min(state.spec.quiet_ms, left)))}
  end

  defp wake(%{status: :running} = state), do: %{state | dirty: true}
  defp wake(state), do: state

  defp start_run(state) do
    if not Session.ready?() do
      %{state | status: :armed, timer: Process.send_after(self(), :run, 1_000)}
    else
      spec = state.spec
      from = Log.position(position_name(spec.name)) || 0

      case Log.read_any(from, spec.listen, spec.batch) do
        [] ->
          settle(%{state | first_pending: nil})

        events ->
          name = spec.name
          timeout = spec.timeout_ms
          task = Task.Supervisor.async_nolink(Compos.Core.TaskSupervisor, fn -> run_batch(name, events, timeout) end)

          run = %{
            task: task,
            from: from,
            first: hd(events).seq,
            upto: List.last(events).seq,
            n: length(events),
            started: System.monotonic_time(:millisecond),
            tref: Process.send_after(self(), {:run_timeout, task.ref}, timeout)
          }

          %{state | status: :running, run: run, dirty: false, first_pending: nil}
      end
    end
  end

  # In the task: the batch runs on the workflow's own lane. emit! and once!
  # collect in that lane process's dictionary; what they collected comes
  # back with the result, and nothing of it is written yet.
  defp run_batch(name, events, timeout) do
    Lane.run(
      {:workflow, name},
      fn _from ->
        Process.put(:compos_workflow_txn, %{emits: [], onces: []})

        try do
          {:reply, result} = Session.exec_call_named("workflow--run", [name, Enum.map(events, &plist/1)], nil)
          {:reply, {result, Process.get(:compos_workflow_txn)}}
        after
          Process.delete(:compos_workflow_txn)
        end
      end,
      timeout + 5_000,
      "workflow " <> name
    )
  end

  defp finish_ok(state, txn) do
    run = state.run
    name = state.spec.name
    ms = System.monotonic_time(:millisecond) - run.started
    obs = {"obs:workflow:" <> name, {:sym, "run"}, obs(state, ms, true, nil)}
    emits = Enum.reverse(txn.emits) ++ [obs]

    case Log.commit(position_name(name), run.from, run.upto, emits, Enum.reverse(txn.onces)) do
      {:ok, _} ->
        :telemetry.execute([:compos, :workflow, :run], %{duration: ms, events: run.n}, %{workflow: name, ok: true})
        stats = %{state.stats | runs: state.stats.runs + 1, handled: state.stats.handled + run.n}
        after_run(%{state | stats: stats, attempts: 0, last_error: nil}, run.n == state.spec.batch)

      # rewound during the run: the batch is void, and the new range runs
      {:error, :moved} ->
        after_run(state, true)

      {:error, msg} ->
        finish_fail(state, text(msg))
    end
  end

  defp finish_fail(state, msg) do
    run = state.run
    name = state.spec.name
    attempts = state.attempts + 1
    ms = System.monotonic_time(:millisecond) - run.started
    Log.append("obs:workflow:" <> name, {:sym, "failed"}, obs(%{state | attempts: attempts}, ms, false, msg))
    :telemetry.execute([:compos, :workflow, :run], %{duration: ms, events: run.n}, %{workflow: name, ok: false})
    stats = %{state.stats | failed: state.stats.failed + 1}

    if attempts >= state.spec.max_attempts do
      parked =
        {"workflow:" <> name, {:sym, "parked"},
         Compos.Core.Events.scheme(%{from: run.first, upto: run.upto, error: msg, attempts: attempts})}

      Log.commit(position_name(name), run.from, run.upto, [parked], [])
      Logger.warning("workflow #{name} parked #{run.first}..#{run.upto}: #{msg}")
      stats = %{stats | parked: stats.parked + run.n}
      after_run(%{state | stats: stats, attempts: 0, last_error: msg}, true)
    else
      delay = backoff(state.spec, attempts)

      %{state
        | run: nil,
          stats: stats,
          attempts: attempts,
          last_error: msg,
          status: :backoff,
          timer: Process.send_after(self(), :run, delay)}
    end
  end

  # after a batch: pause when stepping, run again at once when more waits
  defp after_run(%{stepping: true} = state, _more), do: paused(%{state | run: nil, stepping: false})

  defp after_run(state, more) do
    state = %{state | run: nil}

    if more or state.dirty do
      send(self(), :run)
      %{state | status: :armed, dirty: false}
    else
      settle(state)
    end
  end

  defp settle(%{stepping: true} = state), do: paused(%{state | stepping: false})
  defp settle(state), do: %{state | status: :idle}

  defp paused(state), do: %{cancel(state) | status: :paused}

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  # doubling from backoff_ms to max_backoff_ms, plus up to half of it again
  defp backoff(spec, attempts) do
    base = min(spec.max_backoff_ms, spec.backoff_ms * Integer.pow(2, attempts - 1))
    base + :rand.uniform(max(1, div(base, 2)))
  end

  defp obs(state, ms, ok, error) do
    run = state.run

    Compos.Core.Events.scheme(%{
      workflow: state.spec.name,
      events: run.n,
      from: run.first,
      upto: run.upto,
      ms: ms,
      ok: ok,
      attempt: state.attempts,
      error: error
    })
  end

  defp plist(e) do
    [{:sym, "seq"}, e.seq, {:sym, "topic"}, e.topic, {:sym, "kind"}, e.kind, {:sym, "data"}, e.data,
     {:sym, "at"}, e.at]
  end

  defp text(msg) when is_binary(msg), do: msg
  defp text(msg), do: inspect(msg)
end
