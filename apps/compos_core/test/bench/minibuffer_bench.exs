# The minibuffer slice measurement: a prompt open, one key in it and a
# requery, each followed by the frame render the client asks for. Not part
# of the suite (no _test suffix); run it by name:
#   cd apps/compos_core && mix test test/bench/minibuffer_bench.exs
defmodule Compos.MinibufferBench do
  use Compos.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}

  @rows 3000

  defp ev!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    fun.()
    Editor.render_state()
    System.monotonic_time(:microsecond) - t0
  end

  defp stats(xs) do
    s = Enum.sort(xs)
    at = fn q -> Enum.at(s, min(length(s) - 1, round(q * (length(s) - 1)))) end
    %{n: length(s), p50: at.(0.5), p95: at.(0.95), max: List.last(s)}
  end

  @open ~S{(minibuffer-read* "Bench: " zz-mb-bench-rows (list (list 'confirm (lambda (v) v))))}

  test "a prompt open, a key in it and a requery, measured" do
    ev!(~s{(define zz-mb-bench-rows (map (lambda (i) (list (string-append "bench-command-" (number->string i)) "a command the bench offers")) (iota #{@rows})))})
    ev!("(when (minibuffer-state) (minibuffer-cancel!))")

    open =
      for _ <- 1..60 do
        t = timed(fn -> ev!(@open) end)
        ev!("(minibuffer-cancel!)")
        t
      end

    ev!(@open)

    keys =
      for _ <- 1..200 do
        a = timed(fn -> KeyDispatch.handle_key("1") end)
        b = timed(fn -> KeyDispatch.handle_key("DEL") end)
        [a, b]
      end

    requery = for _ <- 1..60, do: timed(fn -> ev!("(minibuffer-set-candidates! zz-mb-bench-rows)") end)
    ev!("(minibuffer-cancel!)")
    [open, keys, requery] = [Enum.drop(open, 10), Enum.drop(List.flatten(keys), 20), Enum.drop(requery, 10)]

    IO.puts("""
    BENCH rows=#{@rows} open #{inspect(stats(open))}
    BENCH rows=#{@rows} key #{inspect(stats(keys))}
    BENCH rows=#{@rows} requery #{inspect(stats(requery))}
    """)
  end
end
