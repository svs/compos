# What on_change registration costs while chats stream: four buffers take
# agent text every 5 ms, each with a parked rule and an on-screen-scope rule,
# the Editor is busy with 100 ms jobs back to back, and editor changes arrive every
# 5 ms. Not part of the suite (no _test suffix); run it by name:
#   cd apps/compos_core && mix test test/bench/reactor_load_bench.exs
defmodule Compos.Core.ReactorLoadBench do
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, Events, Reactor}

  @n 20

  defp ms(fun) do
    t0 = System.monotonic_time(:microsecond)
    fun.()
    (System.monotonic_time(:microsecond) - t0) / 1000
  end

  defp pct(xs, p), do: xs |> Enum.sort() |> Enum.at(min(length(xs) - 1, trunc(length(xs) * p)))

  defp loop(fun) do
    spawn_link(fn -> Stream.repeatedly(fun) |> Stream.run() end)
  end

  @tag timeout: 300_000
  test "on_change latency under four streaming buffers" do
    Editor.minibuffer_close()
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")

    names =
      for i <- 1..4 do
        name = "*zz-reactor-bench-#{i}*"
        {:ok, _} = Compos.Core.create_buffer(name)
        {:ok, _} = Reactor.on_change(name, :any, fn _ -> :ok end, debounce: 30, sources: :all)
        {:ok, _} = Reactor.on_change(name, :any, fn _ -> :ok end, debounce: 0, sources: :all)
        name
      end

    {:ok, _} = Compos.Core.create_buffer("*zz-reactor-bench-new*")

    load =
      Enum.map(names, fn name ->
        loop(fn ->
          Buffer.append(name, String.duplicate("x", 50) <> "\n", source: {:agent, "bench"})
          Process.sleep(5)
        end)
      end) ++
        [
          # a busy Editor: live telemetry shows 300-760 ms batches
          loop(fn -> :sys.replace_state(Editor, &(Process.sleep(100) && &1)) end),
          loop(fn ->
            Events.broadcast_editor(:bench)
            Process.sleep(5)
          end)
        ]

    Process.sleep(500)
    reactor = Process.whereis(Reactor)

    {lat, queues} =
      for _ <- 1..@n do
        t =
          ms(fn ->
            # a 5 s call timeout counts as 5000 ms, as execute* saw it
            try do
              {:ok, id} = Reactor.on_change("*zz-reactor-bench-new*", :any, fn _ -> :ok end)
              :ok = Reactor.remove(id)
            catch
              :exit, _ -> :timeout
            end
          end)

        {:message_queue_len, q} = Process.info(reactor, :message_queue_len)
        Process.sleep(20)
        {t, q}
      end
      |> Enum.unzip()

    Enum.each(load, &(Process.unlink(&1) && Process.exit(&1, :kill)))

    IO.puts(
      "\non_change+remove ms (N=#{@n}): p50 #{pct(lat, 0.5)}  p90 #{pct(lat, 0.9)}  max #{Enum.max(lat)}" <>
        "  reactor queue max #{Enum.max(queues)}"
    )
  end
end
