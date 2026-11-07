defmodule Compos.Ui.ZzChromeBenchTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint Compos.Ui.Endpoint

  defp key(view, k), do: view |> element("#editor") |> render_hook("key", %{"k" => k})

  defp avg_us(n, fun) do
    for _ <- 1..20, do: fun.()
    {t, _} = :timer.tc(fn -> for _ <- 1..n, do: fun.() end)
    Float.round(t / n, 1)
  end

  test "chrome cost per keystroke" do
    Compos.Core.Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Compos.Core.Editor.set_window_buffer("ui-bench-#{System.unique_integer([:positive])}")
    {:ok, view, _} = live(build_conn(), "/")
    off = avg_us(300, fn -> key(view, "a") end)
    {:ok, _} = Compos.Core.Session.eval("(customize-set! 'show-keys-modifiers-only #f)")
    {:ok, _} = Compos.Core.Session.eval("(run-command \"show-keys-mode\")")
    on = avg_us(300, fn -> key(view, "a") end)
    chord = avg_us(100, fn -> key(view, "C-x"); key(view, "C-g") end)
    key(view, "C-x")
    html = render(view)
    IO.puts("BENCH off=#{off}us on=#{on}us chord-pair=#{chord}us pending=#{html =~ "keycast-pending"} label=#{html =~ "⌃X"}")
    key(view, "C-g")
    {:ok, _} = Compos.Core.Session.eval("(run-command \"show-keys-mode\")")
  end
end
