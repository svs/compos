defmodule Compos.Ui.SelGuardTest do
  @moduledoc "A selection report for a window that is not the selected one is stray, and dropped."
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  test "a sel for another window moves nothing; a sel for the selected window moves point", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    a = "*zz-sel-a*"
    b = "*zz-sel-b*"
    {:ok, _} = Session.eval(~s{(begin
      (buffer-create "#{a}") (buffer-create "#{b}")
      (buffer-append! "#{b}" "one two three")
      (buffer-append! "#{a}" "alpha beta")
      (switch-to-buffer! "#{a}")
      (split-window! 'h 0.5) (other-window!) (switch-to-buffer! "#{b}")
      (other-window!) #t)})

    active = Editor.active_window()
    other = Enum.find(Enum.map(Editor.list_windows_all(), &elem(&1, 0)), &(&1 != active))
    assert Editor.current_buffer() == a
    b_point = Buffer.point(b)

    view |> element("#editor") |> render_hook("sel", %{"win" => other, "point" => b_point - 5})
    assert Editor.active_window() == active, "a stray sel selected the other window"
    assert Buffer.point(b) == b_point, "a stray sel moved the other buffer's point"

    view |> element("#editor") |> render_hook("sel", %{"win" => active, "point" => 6})
    assert Buffer.point(a) == 6, "a sel for the selected window moves its point"

    Compos.Core.kill_buffer(a)
    Compos.Core.kill_buffer(b)
  end
end
