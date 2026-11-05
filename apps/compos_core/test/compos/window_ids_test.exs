defmodule Compos.WindowIdsTest do
  @moduledoc """
  A window id is immutable. A layout saved with its ids comes back with
  the same windows, so every record keyed by window id stays true across
  a restore. An id another frame holds is not taken.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, Session, WindowSpec}

  @a "*zz-wid-a*"
  @b "*zz-wid-b*"
  @c "*zz-wid-c*"

  defp leaf(buffer, id), do: %{type: :leaf, buffer: buffer, top: 0, manual: false, ctop: 0, id: id}

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
                 (switch-to-buffer-here! \"#{@a}\")
                 """,
                 frame
               )

      fun.(frame)
    after
      Session.eval(
        """
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                  '(\"#{@a}\" \"#{@b}\" \"#{@c}\"))
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  test "a layout comes back with the window ids it was saved with" do
    with_frame(fn frame ->
      [{pane, @a}] = Editor.list_windows(frame)
      tree = %{type: :split, dir: :h, ratio: 0.5, children: [leaf(@a, pane), leaf(@b, pane + 1000)]}

      assert :ok = Editor.restore_tree(tree, @a, frame)
      assert [{^pane, @a}, {second, @b}] = Editor.list_windows(frame)
      assert second == pane + 1000

      # the same layout again changes nothing
      assert :ok = Editor.restore_tree(tree, @a, frame)
      assert [{^pane, @a}, {^second, @b}] = Editor.list_windows(frame)

      # fresh ids start above every kept one
      assert Editor.new_window_id() > second
    end)
  end

  test "an id another frame holds is not taken" do
    with_frame(fn frame ->
      {:ok, other} = Editor.attach_frame(nil)

      try do
        [{foreign, _}] = Editor.list_windows(other)
        assert :ok = Editor.restore_tree(leaf(@b, foreign), @b, frame)
        assert [{id, @b}] = Editor.list_windows(frame)
        refute id == foreign
        assert [{^foreign, _}] = Editor.list_windows(other)
      after
        Editor.delete_frame(other)
      end
    end)
  end

  test "a saved layout without ids still matches its panes by buffer" do
    with_frame(fn frame ->
      [{pane, @a}] = Editor.list_windows(frame)
      old = {:leaf, @a, 0, 0, false, 0, [], nil, nil}
      spec = WindowSpec.read({:split, :h, 0.5, old, {:leaf, @b}})
      assert :ok = Editor.restore_tree(spec, @a, frame)
      assert [{^pane, @a}, {_, @b}] = Editor.list_windows(frame)
    end)
  end
end
