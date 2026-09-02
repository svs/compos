defmodule Compos.Ui.PerfViewTest do
  @moduledoc """
  The *perf* monitor renders as one block tree: the grid of panels, SVG
  charts with real paths, and a process table whose current row follows
  point.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Editor, Session}

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    buf = "*perf-view-#{System.unique_integer([:positive])}*"

    {:ok, _} =
      Session.eval(~s[
        (begin
          (buffer-create "#{buf}")
          (with-current-buffer "#{buf}" (lambda () (set-mode! "perf-mode")))
          (with-current-buffer "#{buf}"
            (lambda () (goto-char! (line-start-position (+ perf--first-row-line 1)))))
          (perf--refresh! "#{buf}"))
      ])

    on_exit(fn -> if Compos.Core.Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf) end)
    {:ok, conn: build_conn(), buf: buf}
  end

  test "the monitor draws its panels, charts, and the current process row", %{conn: conn, buf: buf} do
    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~r/<div[^>]*class="perf-grid"/
    assert html =~ "Fig. 1"
    assert html =~ "Fig. 7"
    assert html =~ ~r/<svg[^>]*class="perf-svg[^"]*"[^>]*viewBox="0 0 \d+ 100"/
    assert html =~ ~r/<path[^>]*class="perf-user"[^>]*d="M0,\d+/
    assert html =~ ~r/<circle[^>]*stroke-dasharray="\d+ 100.5"/
    assert html =~ ~r/class="perf-seg perf-sw-user"[^>]*style="width:\d+%"/

    # point sits on the second table row: that row, and only that row, is current
    assert length(Regex.scan(~r/class="perf-prow current"/, html)) == 1
    assert html =~ ~s(<style id="style-perf">) or html =~ ".perf-grid {"
  end
end
