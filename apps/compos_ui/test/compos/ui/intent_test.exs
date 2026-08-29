defmodule Compos.Ui.IntentTest do
  @moduledoc """
  Input intents: the browser's text pipeline reports what the user meant
  (beforeinput), the client sends a type, a byte range, and text. A
  collapsed intent at point is the key it stands for; a ranged intent is
  Scheme policy.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, KeyDispatch}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  defp fresh_buffer(text) do
    name = "intent-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    Buffer.goto(name, byte_size(text))
    name
  end

  defp intent(view, type, from, to, text) do
    view
    |> element("#editor")
    |> render_hook("intent", %{"type" => type, "from" => from, "to" => to, "text" => text})
  end

  test "a collapsed insertText at point is the key", %{conn: conn} do
    buf = fresh_buffer("ab")
    {:ok, view, _} = live(conn, "/")
    intent(view, "insertText", 2, 2, "c")
    assert Buffer.text(buf) == "abc"
    assert Buffer.point(buf) == 3
  end

  test "a collapsed intent acts at point, whatever byte the client named", %{conn: conn} do
    buf = fresh_buffer("ab")
    Buffer.goto(buf, 1)
    {:ok, view, _} = live(conn, "/")
    intent(view, "insertText", -1, -1, "X")
    assert Buffer.text(buf) == "aXb"
    # the DOM caret lags the server by one patch: a stale byte is not a range
    intent(view, "insertText", 0, 0, "Y")
    assert Buffer.text(buf) == "aXYb"
  end

  test "insertParagraph is RET and deleteContentBackward is DEL", %{conn: conn} do
    buf = fresh_buffer("ab")
    {:ok, view, _} = live(conn, "/")
    intent(view, "insertParagraph", 2, 2, "")
    assert Buffer.text(buf) == "ab\n"
    intent(view, "deleteContentBackward", 3, 3, "")
    intent(view, "deleteContentBackward", 2, 2, "")
    assert Buffer.text(buf) == "a"
  end

  test "a ranged insertText replaces the range", %{conn: conn} do
    buf = fresh_buffer("hello world")
    {:ok, view, _} = live(conn, "/")
    intent(view, "insertReplacementText", 6, 11, "there")
    assert Buffer.text(buf) == "hello there"
    assert Buffer.point(buf) == 11
  end

  test "a ranged delete removes the range and leaves no mark", %{conn: conn} do
    buf = fresh_buffer("hello world")
    {:ok, view, _} = live(conn, "/")
    intent(view, "deleteContentBackward", 5, 11, "")
    assert Buffer.text(buf) == "hello"
    assert Buffer.mark(buf) == nil
  end

  test "a committed composition inserts its text at point", %{conn: conn} do
    buf = fresh_buffer("x")
    {:ok, view, _} = live(conn, "/")
    intent(view, "insertCompositionText", -1, -1, "日本")
    assert Buffer.text(buf) == "x日本"
    assert Buffer.point(buf) == byte_size("x日本")
  end

  test "with the minibuffer open, text reaches the prompt as keys", %{conn: conn} do
    buf = fresh_buffer("ab")
    {:ok, view, _} = live(conn, "/")
    # the prompt belongs to this view's frame, so it opens through the view
    view |> element("#editor") |> render_hook("key", %{"k" => "M-x"})
    intent(view, "insertText", 2, 2, "f")
    intent(view, "insertCompositionText", -1, -1, "oo")
    html = render(view)
    assert html =~ "mb-input"
    assert html =~ "foo"
    assert Buffer.text(buf) == "ab"
    view |> element("#editor") |> render_hook("key", %{"k" => "C-g"})
  end

  test "an unknown intent leaves the buffer alone and says so", %{conn: conn} do
    buf = fresh_buffer("ab")
    {:ok, view, _} = live(conn, "/")
    intent(view, "formatBold", 0, 2, "")
    assert Buffer.text(buf) == "ab"
    assert Editor.render_state().echo =~ "Unhandled input intent"
  end
end
