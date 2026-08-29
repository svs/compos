defmodule Aimax.LaneTest do
  @moduledoc """
  Aimax.Core.Lane.Worker: the serial worker behind a lane.

  A caller that times out dies with its message still in the worker's
  mailbox. The worker must skip that job: nobody can take the reply, and a
  burst of such jobs would hold the lane for minutes after every caller
  gave up.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.Lane

  test "a job whose caller died before its turn is skipped, and a live caller still runs" do
    lane = {:lane_test, System.unique_integer([:positive])}
    me = self()

    handler = "lane-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:aimax, :lane, :skipped],
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
end
