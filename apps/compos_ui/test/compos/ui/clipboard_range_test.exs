defmodule Compos.Ui.ClipboardRangeTest do
  @moduledoc """
  Copy, cut and paste on an editable surface. The browser sends its
  selection as bytes of the text version it shows, and the daemon works
  out the text: the rows the browser draws are not the source.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, Session}

  # The first page that connects in a test run does not get the events of
  # its window (rope_sync_test fails the same way when one of its page
  # tests runs first). One connection before the tests takes that place.
  setup_all do
    {:ok, _view, _html} = live(build_conn(), "/")
    :ok
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    {:ok, _} = Session.eval("(test-one-window!)")
    {:ok, conn: build_conn()}
  end

  defp buffer!(text) do
    name = "clipboard-range-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    Buffer.goto(name, 0)
    name
  end

  defp hook(view, event, params), do: view |> element("#editor") |> render_hook(event, params)

  defp range(buf, from, to),
    do: %{"win" => Editor.active_window(), "v" => Buffer.version(buf), "from" => from, "to" => to}

  test "copy answers the text of the byte range and changes nothing", %{conn: conn} do
    buf = buffer!("one\ntwo\nthree\n")
    {:ok, view, _} = live(conn, "/")
    hook(view, "copy", range(buf, 4, 7))
    assert_push_event(view, "clipboard", %{text: "two"})
    assert Buffer.text(buf) == "one\ntwo\nthree\n"
  end

  test "cut removes the byte range and answers its text", %{conn: conn} do
    buf = buffer!("one\ntwo\nthree\n")
    {:ok, view, _} = live(conn, "/")
    hook(view, "cut", range(buf, 4, 8))
    assert_push_event(view, "clipboard", %{text: "two\n"})
    assert Buffer.text(buf) == "one\nthree\n"
    assert Buffer.point(buf) == 4
  end

  test "a range that reaches a folded line's end takes the hidden text", %{conn: conn} do
    buf = buffer!("head\nbody one\nbody two\ntail\n")
    # the fold hides from the end of 'head' to the end of 'body two'
    Buffer.set_hidden(buf, [{4, 22}])
    {:ok, view, _} = live(conn, "/")
    hook(view, "cut", range(buf, 0, 4))
    assert_push_event(view, "clipboard", %{text: "head\nbody one\nbody two"})
    assert Buffer.text(buf) == "\ntail\n"
  end

  test "a range from a text version the daemon has left is not trusted", %{conn: conn} do
    buf = buffer!("one\ntwo\n")
    {:ok, view, _} = live(conn, "/")
    stale = %{range(buf, 0, 3) | "v" => Buffer.version(buf) - 1}
    hook(view, "cut", stale)
    assert Buffer.text(buf) == "one\ntwo\n"
  end

  test "paste goes over the browser's selection", %{conn: conn} do
    buf = buffer!("one\ntwo\nthree\n")
    {:ok, view, _} = live(conn, "/")
    hook(view, "paste", Map.put(range(buf, 4, 7), "text", "TWO"))
    assert Buffer.text(buf) == "one\nTWO\nthree\n"
  end

  test "paste at a caret ignores a mark the daemon still holds", %{conn: conn} do
    buf = buffer!("one\ntwo\n")
    Buffer.goto(buf, 4)
    Buffer.set_mark(buf, 0)
    {:ok, view, _} = live(conn, "/")
    hook(view, "paste", Map.put(range(buf, 4, 4), "text", "X"))
    assert Buffer.text(buf) == "one\nXtwo\n"
  end
end
