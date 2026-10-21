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

  test "a layout comes back with the window ids it was saved with" do
    with_frame(fn frame ->
      [{pane, @a}] = Editor.list_windows(frame)
      hidden = Editor.new_hidden_window(@c, frame)
      tree = {:split, :h, 0.5, leaf(@a, pane), leaf(@b, pane + 1000)}

      assert :ok = Editor.restore_layout(tree, [leaf(@c, hidden)], @a, frame)
      assert [{^pane, @a}, {second, @b}] = Editor.list_windows(frame)
      assert second == pane + 1000
      assert [{^hidden, @c}] = Editor.hidden_windows(frame)

      # the same layout again changes nothing
      assert :ok = Editor.restore_layout(tree, [leaf(@c, hidden)], @a, frame)
      assert [{^pane, @a}, {^second, @b}] = Editor.list_windows(frame)
      assert [{^hidden, @c}] = Editor.hidden_windows(frame)

      # fresh ids start above every kept one
      assert Editor.new_hidden_window(@a, frame) > second
    end)
  end

  test "an id another frame holds is not taken" do
    with_frame(fn frame ->
      {:ok, other} = Editor.attach_frame(nil)

      try do
        [{foreign, _}] = Editor.list_windows(other)
        assert :ok = Editor.restore_layout(leaf(@b, foreign), [], @b, frame)
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
      assert :ok = Editor.restore_tree({:split, :h, 0.5, old, {:leaf, @b}}, @a, frame)
      assert [{^pane, @a}, {_, @b}] = Editor.list_windows(frame)
    end)
  end

  test "window-tree and window-tree-set! round-trip the ids" do
    with_frame(fn frame ->
      {:ok, _} =
        Session.eval(
          ~s|(begin (split-window! 'h 0.5) (switch-to-buffer-here! "#{@b}") (window-new-hidden! "#{@c}"))|,
          frame
        )

      before = {Editor.list_windows(frame), Editor.hidden_windows(frame)}
      assert {[_, _], [_]} = before

      {:ok, _} =
        Session.eval(
          ~s|(let ((l (window-tree))) (delete-other-windows!) (window-hidden-clear!) (window-tree-set! l))|,
          frame
        )

      assert before == {Editor.list_windows(frame), Editor.hidden_windows(frame)}
    end)
  end

  test "the desktop view names each window's id" do
    with_frame(fn frame ->
      [{pane, @a}] = Editor.list_windows(frame)
      assert %{tree: %{type: :leaf, id: ^pane}} = Editor.desktop_view(frame)
    end)
  end
end
