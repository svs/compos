defmodule Compos.HiddenWindowsTest do
  @moduledoc """
  A hidden window keeps its id, buffer and history without a pane. The
  desktop saves the hidden windows of each frame, and a restore makes
  them again.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}

  test "the desktop view carries the hidden windows, and a restore makes them again" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} =
               Session.eval(
                 """
                 (test-buffer! "*zz-hw-a*" "")
                 (test-buffer! "*zz-hw-b*" "")
                 (delete-other-windows!)
                 (window-hidden-clear!)
                 (switch-to-buffer-here! "*zz-hw-a*")
                 (window-new-hidden! "*zz-hw-b*")
                 """,
                 frame
               )

      view = Editor.desktop_view(frame)
      assert [%{buffer: "*zz-hw-b*"}] = view.hidden

      # the desktop file holds a hidden window as a 7-tuple leaf spec
      spec = {:leaf, "*zz-hw-b*", 0, 0, false, 0, ["*zz-hw-a*"]}
      assert :ok = Editor.set_hidden_windows([spec], frame)
      assert [{_id, "*zz-hw-b*"}] = Editor.hidden_windows(frame)
      assert [%{buffer: "*zz-hw-b*", history: ["*zz-hw-a*"]}] = Editor.desktop_view(frame).hidden

      # a restore from an older desktop, with no hidden windows, clears them
      assert :ok = Editor.set_hidden_windows([], frame)
      assert [] = Editor.hidden_windows(frame)
    after
      Session.eval(
        """
        (window-hidden-clear!)
        (buffer-kill! "*zz-hw-a*")
        (buffer-kill! "*zz-hw-b*")
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
