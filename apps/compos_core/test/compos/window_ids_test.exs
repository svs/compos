defmodule Compos.WindowIdsTest do
  @moduledoc """
  A window id is immutable. A layout saved with its ids comes back with
  the same windows, on screen and hidden, so every record keyed by window
  id stays true across a restore. An id another frame holds is not taken.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session}

  @a "*zz-wid-a*"
  @b "*zz-wid-b*"
  @c "*zz-wid-c*"

  defp leaf(buffer, id), do: {:leaf, buffer, 0, 0, false, 0, [], nil, nil, id}

  defp with_frame(fun) do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} =
               Session.eval(
                 """
                 (test-buffer! \"#{@a}\" \"\")
                 (test-buffer! \"#{@b}\" \"\")
                 (test-buffer! \"#{@c}\" \"\")
                 (delete-other-windows!)
                 (window-hidden-clear!)
                 (switch-to-buffer-here! \"#{@a}\")
                 """,
                 frame
               )

      fun.(frame)
    after
      Session.eval(
        """
        (window-hidden-clear!)
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                  '(\"#{@a}\" \"#{@b}\" \"#{@c}\"))
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
