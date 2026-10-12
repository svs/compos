defmodule Compos.StripSlideTest do
  @moduledoc """
  A focus move past the frame edge scrolls the window ring, and the scroll asks
  the frame's client to slide the panes. The client then shows which
  buffer went out and which buffer came in.

  The test presses its own keys, never the real chord: a binding is a
  preference. The scenes come from scheme/packages/layout-policy-test.scm.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @scenes Path.expand("../../../../scheme/packages/layout-policy-test.scm", __DIR__)

  test "a focus move past the edge scrolls the window ring and asks for a slide in its direction" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} = Session.eval(~s|(load "#{@scenes}")|, frame)

      assert {:ok, _} =
               Session.eval(
                 """
                 (remove-hook! 'window-configuration-change-hook 'layout-target-on-change!)
                 (lp-start!)
                 (lp-buffer! "b") (lp-buffer! "c")
                 (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
                 (layout-target-set! 'two-pane)
                 (window-new-hidden! "zz-lp-c")
                 (select-window! (window-showing "zz-lp-b"))
                 (global-set-key "<f9>" "next-pane")
                 (global-set-key "<f10>" "previous-pane")
                 """,
                 frame
               )

      Editor.take_slide(frame)

      # a move between two panes scrolls nothing and asks for no slide
      KeyDispatch.handle_key(frame, "<f10>")
      assert Editor.take_slide(frame) == nil
      KeyDispatch.handle_key(frame, "<f9>")
      assert Editor.take_slide(frame) == nil

      # past the right edge: the ring scrolls forward
      KeyDispatch.handle_key(frame, "<f9>")

      assert {:ok, ~s|("zz-lp-b" "zz-lp-c")|} =
               Session.eval("(layout-target-visible-buffers)", frame)

      assert Editor.take_slide(frame) == "forward"
      assert Editor.take_slide(frame) == nil, "the take clears the request"

      # past the left edge: the ring scrolls backward
      assert {:ok, _} = Session.eval(~s|(select-window! (window-showing "zz-lp-b"))|, frame)
      KeyDispatch.handle_key(frame, "<f10>")

      assert {:ok, ~s|("zz-lp-a" "zz-lp-b")|} =
               Session.eval("(layout-target-visible-buffers)", frame)

      assert Editor.take_slide(frame) == "backward"
    after
      Session.eval(
        """
        (global-unset-key "<f9>")
        (global-unset-key "<f10>")
        (layout-target-set! #f)
        (lp-clean!)
        (add-hook! 'window-configuration-change-hook 'layout-target-on-change!)
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
