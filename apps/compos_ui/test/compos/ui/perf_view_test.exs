defmodule Compos.Ui.PerfViewTest do
  @moduledoc """
  The *perf* monitor renders as one block tree: the lanes panel, one row
  per lane.
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
          (perf--refresh! "#{buf}"))
      ])

    on_exit(fn -> if Compos.Core.Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf) end)
    {:ok, conn: build_conn(), buf: buf}
  end

  test "the monitor draws the lanes panel", %{conn: conn, buf: buf} do
    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~r/<c-group[^>]*class="perf-panel"/
    assert html =~ "Lanes · contention"
    assert html =~ ~r/class="perf-lrow perf-phead"/
    assert html =~ ~s(<style id="style-perf">) or html =~ ".perf-lrow {"
  end
end
