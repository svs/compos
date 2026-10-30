defmodule Compos.DisplayTest do
  @moduledoc """
  The display model answers the rows of a window from the render payload,
  with no client: every client draws the same rows.
  """
  use ExUnit.Case

  alias Compos.Core.{Buffer, Display, Editor}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_total_rows(20)
    name = "zz-display-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    Buffer.append(name, Enum.map_join(1..5000, "\n", &"row #{&1}"), source: :editor)
    Buffer.goto(name, 0)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    {:ok, name: name}
  end

  test "a window over the bound builds the rows of its viewport, not the buffer" do
    leaf = Editor.render_state().tree
    {drawn, _entry} = Display.window(leaf, nil)

    assert length(drawn.lines) <= leaf.rows * 3 + 8
    refute drawn.client_scroll?
  end

  # The browser owns the caret of the window it edits; any other window
  # shows point as a server-drawn cursor.
  test "only a window the caret does not own draws the cursor" do
    leaf = Editor.render_state().tree
    {served, _} = Display.window(leaf, nil)
    {native, _} = Display.window(leaf, nil, caret_owner: leaf.id)

    assert hd(served.lines).segs == [{"r", "cursor"}, {"ow 1", ""}]
    assert hd(native.lines).segs == [{"row 1", ""}]
  end

  test "a render with the same inputs reuses the rows it built" do
    leaf = Editor.render_state().tree
    {_, {key, visible, _} = entry} = Display.window(leaf, nil)
    {_, {^key, again, _}} = Display.window(leaf, entry)

    assert :erts_debug.same(visible, again)
  end

  test "plain source suppresses syntax and overlay faces" do
    name = "zz-plain-source"
    Editor.set_window_buffer(name)
    Buffer.append(name, "*plain*", source: :editor)
    Buffer.goto(name, 0)
    Buffer.set_overlays(name, "test", [{0, 6, "italic"}])
    Buffer.set_local(name, "plain-source", true)

    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    leaf = Editor.render_state().tree
    {drawn, _} = Display.window(leaf, nil, caret_owner: leaf.id)
    segments = Enum.flat_map(drawn.lines, & &1.segs)

    assert segments == [{"*plain*", ""}]
  end

  test "a preview card takes more rows, up to a bound" do
    leaf = %{Editor.render_state().tree | window_class: "listing-preview"}
    {drawn, _} = Display.window(leaf, nil)

    assert length(drawn.lines) == 2_000
  end

  # A wrapped line is many screen rows, so a server top by source line
  # cannot reach the end of the buffer. The browser scrolls it instead.
  test "a window under the bound ships every line, whatever its mode" do
    leaf = Editor.render_state().tree

    for mode <- [true, false] do
      small = %{leaf | total_lines: 300} |> Map.put(:visual_line_mode, mode)
      {drawn, _} = Display.window(small, nil)
      assert drawn.client_scroll?
      assert length(drawn.lines) == 300
    end

    big = Map.put(leaf, :visual_line_mode, true)
    {drawn, _} = Display.window(big, nil)
    refute drawn.client_scroll?
  end

  # Code wraps by character rather than by word, so it strands its bottom
  # the same way. It is under the bound, so the browser scrolls it.
  test "a code window reaches its last line" do
    leaf = %{Editor.render_state().tree | total_lines: 1_100}
    {drawn, _} = Display.window(leaf, nil)

    assert drawn.client_scroll?
    assert List.last(drawn.lines).num == 1_100
  end
end
