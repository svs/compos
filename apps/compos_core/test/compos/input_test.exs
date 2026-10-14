defmodule Compos.InputTest do
  @moduledoc "Input serializes whole input events across concurrent clients."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, Input}

  test "concurrent input events run mutually excluded, not interleaved" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # read-sleep-write: interleaved executions lose increments
    1..8
    |> Enum.map(fn _ ->
      Task.async(fn ->
        Input.run(fn ->
          n = Agent.get(counter, & &1)
          Process.sleep(5)
          Agent.update(counter, fn _ -> n + 1 end)
        end)
      end)
    end)
    |> Task.await_many()

    assert Agent.get(counter, & &1) == 8
  end

  test "dispatch routes a key through KeyDispatch" do
    name = "input-test-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)

    Input.dispatch("h")
    Input.dispatch("i")

    assert Buffer.text(name) == "hi"
  end

  test "an event that exits fails its caller only, not Input or the events behind it" do
    pid = Process.whereis(Input)

    assert catch_exit(Input.run(fn -> exit({:timeout, :lane}) end)) == {:timeout, :lane}
    assert_raise RuntimeError, fn -> Input.run(fn -> raise "boom" end) end

    assert Input.run(fn -> :next end) == :next
    assert Process.whereis(Input) == pid
  end
end
