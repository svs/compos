# What the frame layout costs: Editor.arrange/2 of a row of three windows,
# Editor.render_state/1 of that frame, and Editor.window_rects/1. Not part of
# the suite (no _test suffix); run it by name:
#   cd apps/compos_core && mix test test/bench/window_row_bench.exs
# Times are p50 microseconds over N calls.
defmodule Compos.Core.WindowRowBench do
  use ExUnit.Case, async: false

  alias Compos.Core.Editor

  @n 200

  defp us(fun) do
    t0 = System.monotonic_time(:microsecond)
    fun.()
    System.monotonic_time(:microsecond) - t0
  end

  defp p50(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  test "arrange and render of a row of three windows" do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")

    items =
      for i <- 1..3 do
        name = "*zz-row-bench-#{i}*"
        {:ok, _} = Compos.Core.create_buffer(name)
        Compos.Core.Buffer.append(name, Enum.map_join(1..200, "\n", &"line #{&1}"), source: :editor)
        [GenServer.call(Editor, :new_window_id), name]
      end

    :ok = Editor.arrange({:h, [1, 1, 1], items})
    ids = Enum.map(items, &hd/1)
    arrange = for _ <- 1..@n, do: us(fn -> :ok = Editor.arrange({:h, [2, 1, 1], ids}) end)
    render = for _ <- 1..@n, do: us(fn -> Editor.render_state() end)
    rects = for _ <- 1..@n, do: us(fn -> Editor.window_rects() end)

    IO.puts("\nrow of 3, p50 us (N=#{@n}): arrange #{p50(arrange)}  render_state #{p50(render)}  window_rects #{p50(rects)}")
    IO.inspect(Editor.window_rects(), label: "rects")
  end
end
