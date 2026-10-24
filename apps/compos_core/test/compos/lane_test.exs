defmodule Compos.LaneTest do
  @moduledoc """
  Compos.Core.Lane.Worker: the serial worker behind a lane.

  A queued call is skipped once its caller is gone. An active call runs in a
  linked job process: caller death or timeout kills that job immediately while
  leaving the serial lane available for the next caller.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Compos.Core.{Lane, Session}

  test "a job whose caller died before its turn is skipped, and a live caller still runs" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    handler = "lane-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:compos, :lane, :skipped],
      fn _event, _measure, meta, _ -> send(me, {:skipped, meta.label}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # hold the lane for longer than the next caller waits
    spawn(fn ->
      Lane.run(lane, fn _ -> Process.sleep(600) && {:reply, :held} end, 5_000, "hold")
    end)

    Process.sleep(50)

    # this caller waits 100 ms, then dies with its job still queued
    spawn(fn ->
      try do
        Lane.run(lane, fn _ -> send(me, :ran_for_a_dead_caller) && {:reply, :x} end, 100, "dead")
      catch
        :exit, _ -> :ok
      end
    end)

    assert_receive {:skipped, "dead"}, 2_000
    refute_received :ran_for_a_dead_caller

    assert Lane.run(lane, fn _ -> {:reply, :alive} end, 5_000, "alive") == :alive
    refute_received :ran_for_a_dead_caller
  end

  test "a running job dies with its caller and the lane immediately recovers" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    caller =
      spawn(fn ->
        Lane.run(
          lane,
          fn _ ->
            send(me, {:active_job, self()})
            receive do: (:never -> {:reply, :impossible})
          end,
          5_000,
          "caller death"
        )
      end)

    assert_receive {:active_job, job}, 1_000
    caller_monitor = Process.monitor(caller)
    job_monitor = Process.monitor(job)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^job_monitor, :process, ^job, :killed}, 1_000
    assert Lane.run(lane, fn _ -> {:reply, :recovered} end, 1_000, "recovery") == :recovered
  end

  test "a timeout cancels the active job even when the caller catches the exit" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    caller =
      spawn(fn ->
        try do
          Lane.run(
            lane,
            fn _ ->
              send(me, {:timed_job, self()})
              receive do: (:never -> {:reply, :impossible})
            end,
            200,
            "timeout"
          )
        catch
          :exit, reason ->
            send(me, {:caught_timeout, self(), reason})
            receive do: (:stop -> :ok)
        end
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive {:timed_job, job}, 1_000
    job_monitor = Process.monitor(job)
    assert_receive {:caught_timeout, ^caller, _reason}, 1_000
    assert Process.alive?(caller)
    assert_receive {:DOWN, ^job_monitor, :process, ^job, :killed}, 1_000
    assert Lane.run(lane, fn _ -> {:reply, :recovered} end, 1_000, "recovery") == :recovered
    send(caller, :stop)
  end

  test "a timed-out recursive Scheme eval is killed, logged in full, and recovers" do
    lane = {:lane_test, System.unique_integer([:positive])}
    marker = "timeout-source-tail-marker"
    source = ~s[(begin "#{String.duplicate("padding-", 20)}" (let loop () (loop)) "#{marker}")]

    log =
      capture_log(fn ->
        assert catch_exit(Session.eval(source, nil, 100, lane))
      end)

    assert log =~ marker
    assert {:ok, "42"} = Session.eval("(+ 40 2)", nil, 1_000, lane)
  end

  test "a lane job can re-enter its own lane without deadlocking" do
    lane = {:lane_test, System.unique_integer([:positive])}

    assert Lane.run(
             lane,
             fn _ ->
               nested = Lane.run(lane, fn _ -> {:reply, {:nested, Lane.current()}} end)
               {:reply, nested}
             end,
             1_000,
             "reentrant"
           ) == {:nested, lane}
  end

  test "killing a lane also kills its linked active job" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    spawn(fn ->
      Lane.run(
        lane,
        fn _ ->
          send(me, {:kill_job, self()})
          receive do: (:never -> {:reply, :impossible})
        end,
        5_000,
        "explicit kill"
      )
    end)

    assert_receive {:kill_job, job}, 1_000
    job_monitor = Process.monitor(job)
    assert :ok = Lane.kill(lane)
    assert_receive {:DOWN, ^job_monitor, :process, ^job, :killed}, 1_000
    assert Lane.run(lane, fn _ -> {:reply, :fresh} end, 1_000, "fresh") == :fresh
  end

  # The heap bound kills a runaway job outright. A cast job that ran inline
  # took the worker with it, and every caller queued on the lane exited
  # :killed - a key lookup on :ui crashed the LiveView.
  test "a killed cast job leaves the worker and its queued callers alive" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    Lane.cast(
      lane,
      fn _ ->
        send(me, {:cast_job, self()})
        Process.sleep(100)
        Process.exit(self(), :kill)
      end,
      "runaway"
    )

    assert_receive {:cast_job, job}, 1_000
    [{worker, _}] = wait_registered(lane)
    refute job == worker

    capture_log(fn ->
      assert Lane.run(lane, fn _ -> {:reply, :after} end, 2_000, "after") == :after
    end)

    assert Process.alive?(worker)
  end

  # A deferred eval answers through eval-resolve! long after the worker moved
  # on. Its caller still monitors the worker, so an idle retirement in between
  # failed the call with :normal.
  test "an idle worker stays while a deferred reply is pending" do
    lane = {:lane_test, System.unique_integer([:positive])}
    token = make_ref()
    me = self()

    caller =
      spawn(fn ->
        reply =
          Lane.run(
            lane,
            fn from ->
              Compos.Core.Roots.put({:eval_pending, token}, from)
              :noreply
            end,
            5_000,
            "deferred"
          )

        send(me, {:answered, reply})
      end)

    on_exit(fn -> Compos.Core.Roots.drop({:eval_pending, token}) end)

    [{worker, _}] = wait_registered(lane)
    ref = Process.monitor(worker)
    wait_pending(token)

    send(worker, :timeout)
    refute_receive {:DOWN, ^ref, :process, ^worker, _}, 100
    assert Process.alive?(caller)

    GenServer.reply(Compos.Core.Roots.take({:eval_pending, token}), :resolved)
    assert_receive {:answered, :resolved}, 1_000

    send(worker, :timeout)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 1_000
  end

  defp wait_registered(lane) do
    case Registry.lookup(Compos.Core.LaneRegistry, lane) do
      [] -> Process.sleep(5) && wait_registered(lane)
      found -> found
    end
  end

  defp wait_pending(token) do
    if Compos.Core.Roots.get({:eval_pending, token}),
      do: :ok,
      else: Process.sleep(5) && wait_pending(token)
  end
end
