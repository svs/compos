defmodule Compos.Ui.ModelineExtraTest do
  @moduledoc """
  The frame modeline's extra text is the global-mode-string: one span per
  segment, each with the class its owner chose.
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
    Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.set_modeline_extra("") end)
    {:ok, conn: build_conn()}
  end

  test "segments render as classed spans, and an empty list hides the extra", %{conn: conn} do
    {:ok, _} =
      Session.eval(~s[(set-modeline-extra! (list (list "ml-segment" "1.2 GiB vm") (list "ml-attention" "! agent")))])

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, ".echo-bar .ml-extra .ml-segment", "1.2 GiB vm")
    assert has_element?(view, ".echo-bar .ml-extra .ml-attention", "! agent")

    {:ok, _} = Session.eval(~s[(set-modeline-extra! (list))])
    refute has_element?(view, ".echo-bar .ml-extra")

    {:ok, _} = Session.eval(~s[(set-modeline-extra! "plain")])
    assert has_element?(view, ".echo-bar .ml-extra .ml-attention", "plain")
  end
end
