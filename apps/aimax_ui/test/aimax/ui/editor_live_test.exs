defmodule Aimax.Ui.EditorLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  defp type(view, str), do: keys(view, String.graphemes(str))

  setup do
    Aimax.Core.Editor.minibuffer_close()
    Aimax.Core.Editor.completion_dismiss()
    Aimax.Core.Editor.set_pending([])
    Aimax.Core.Editor.set_total_rows(40)
    Aimax.Core.Editor.delete_other_windows()
    Aimax.Core.Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts and shows the window with modeline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "modeline"
    assert html =~ "ui-test-"
  end

  test "typing renders into the buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "hello")
    assert html =~ "hello"
    assert html =~ "L1:C5"
  end

  test "minibuffer shows on M-x with selectable candidates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["M-x"])
    assert html =~ "M-x "
    assert html =~ "mb-cand selected"

    # candidate order is recency-first, so filter before asserting a name
    html = type(view, "backwardchar")
    assert html =~ "backward-char"
    keys(view, ["C-g"])
  end

  test "which-key renders on C-x", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x"])
    assert html =~ "which-key"
    assert html =~ "switch-to-buffer"
    keys(view, ["C-g"])
  end

  test "window splits render as a tree", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x", "3"])
    assert html =~ ~s(class="split h")
    html = keys(view, ["C-x", "1"])
    refute html =~ ~s(class="split h")
  end

  test "undo works through the window", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "xy")
    assert html =~ "xy"
    html = keys(view, ["C-/"])
    refute html =~ "xy"
  end

  test "rpc/agent edits to a visible buffer appear live", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render(view)
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "pushed from outside", source: {:agent, "test"})
    # event-driven re-render
    assert render(view) =~ "pushed from outside"
  end
end
