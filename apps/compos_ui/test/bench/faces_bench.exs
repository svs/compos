# The faces slice measurement: one face change, one theme switch and one
# frame render (render_state and its face CSS), each followed by the frame
# render the client asks for. It also writes the rendered face CSS of the
# global faces and of a frame with its own theme to FACES_CSS_OUT, so two
# builds compare byte for byte. Not part of the suite (no _test suffix):
#   cd apps/compos_ui && FACES_CSS_OUT=/tmp/x.css mix test test/bench/faces_bench.exs
defmodule Compos.Ui.FacesBench do
  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}
  alias Compos.Ui.FaceCSS

  @n 60

  defp ev!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp us(fun) do
    t0 = System.monotonic_time(:microsecond)
    fun.()
    System.monotonic_time(:microsecond) - t0
  end

  defp stats(xs) do
    s = Enum.sort(xs)
    at = fn q -> Enum.at(s, min(length(s) - 1, round(q * (length(s) - 1)))) end
    %{n: length(s), p50: at.(0.5), p95: at.(0.95)}
  end

  defp page_css(fid) do
    s = Editor.render_state(fid)
    FaceCSS.css(s.faces) <> "\n" <> Enum.join(Map.values(s.styles), "\n")
  end

  defp render(fid \\ nil) do
    s = Editor.render_state(fid)
    FaceCSS.css(s.faces)
  end

  test "a face change, a theme switch and a frame render, measured" do
    ev!("(test-one-window!)")
    ev!(~s{(theme-apply! "paper-night")})
    for _ <- 1..10, do: render()

    face =
      for i <- 1..@n do
        us(fn ->
          ev!(~s{(set-face-attribute! 'zz-faces-bench 'fg "##{100_000 + i}")})
          render()
        end)
      end

    theme =
      for t <- Enum.take(Stream.cycle(["zenburn", "paperized"]), 24) do
        us(fn ->
          ev!(~s{(theme-apply! "#{t}")})
          render()
        end)
      end

    ev!(~s{(theme-apply! "paper-night")})
    frame = for _ <- 1..@n, do: us(fn -> render() end)

    # a frame with its own theme, and global faces that move under it
    # a printed value: the id comes back quoted
    fid = ev!("(make-frame!)")
    ev!(~s{(set-frame-local-in! #{fid} 'isolated #t)})
    ev!(~s{(frame-theme-apply! "crt" #{fid})})
    ev!(~s{(set-face-attribute! 'modeline 'weight "700" 'fg "#123456")})
    ev!(~s{(set-face-attribute! 'zz-faces-bench 'bg "#654321")})
    ev!(~s{(face-clear! 'dim)})
    own = for _ <- 1..@n, do: us(fn -> render(String.trim(fid, ~s{"})) end)

    out = System.get_env("FACES_CSS_OUT") || Path.join(System.tmp_dir!(), "faces-bench.css")

    File.write!(
      out,
      "/* global */\n" <> page_css(nil) <> "\n/* frame */\n" <> page_css(String.trim(fid, ~s{"}))
    )

    ev!(~s{(delete-frame! #{fid})})
    ev!(~s{(theme-apply! "paper-night")})

    IO.puts("""
    BENCH face-change #{inspect(stats(Enum.drop(face, 10)))}
    BENCH theme-switch #{inspect(stats(Enum.drop(theme, 4)))}
    BENCH frame-render #{inspect(stats(Enum.drop(frame, 10)))}
    BENCH own-frame-render #{inspect(stats(Enum.drop(own, 10)))}
    BENCH css #{out} #{File.stat!(out).size} B
    """)
  end
end
