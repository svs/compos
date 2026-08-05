defmodule Aimax.FoldingTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor}

  defp fresh_buffer(text) do
    name = "fold-#{System.unique_integer([:positive])}"
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  defp leaf_for(buf) do
    %{tree: tree} = Editor.render_state()
    find_leaf(tree, buf)
  end

  defp find_leaf(%{type: :leaf, buffer: b} = leaf, b), do: leaf
  defp find_leaf(%{type: :leaf}, _), do: nil

  defp find_leaf(%{type: :split, children: c}, b),
    do: Enum.find_value(c, &find_leaf(&1, b))

  # "* a\nbody1\nbody2\n* b\ntail" — fold covers a's body (the newline
  # after "* a" through the end of body2's line)
  test "render geometry: hidden lines drop from totals, cursor uses visible index" do
    buf = fresh_buffer("* a\nbody1\nbody2\n* b\ntail")

    leaf = leaf_for(buf)
    assert leaf.total_lines == 5
    assert leaf.hidden_lines == MapSet.new()

    :ok = Buffer.set_hidden(buf, [{3, 15}])
    :ok = Buffer.goto(buf, 16)

    leaf = leaf_for(buf)
    assert leaf.hidden_lines == MapSet.new([1, 2])
    assert leaf.total_lines == 3

    # point is on "* b" (logical line 3) — visible index 1
    {_, rendered} = {nil, leaf}
    assert rendered.point == 16
  end

  test "next/previous line skip folded bodies", %{} do
    buf = fresh_buffer("* a\nbody1\nbody2\n* b\ntail")
    :ok = Buffer.set_hidden(buf, [{3, 15}])

    :ok = Buffer.goto(buf, 0)
    p = Buffer.next_line(buf)
    # lands on "* b", not body1
    assert p == 16

    p = Buffer.previous_line(buf)
    assert p == 0
  end

  test "fold to end of buffer: next-line stays put" do
    buf = fresh_buffer("* a\nbody1\nbody2")
    :ok = Buffer.set_hidden(buf, [{3, 15}])
    :ok = Buffer.goto(buf, 0)
    assert Buffer.next_line(buf) == 0
  end

  test "stale over-long ranges are clamped, not fatal" do
    buf = fresh_buffer("* a\nbody\n")
    :ok = Buffer.set_hidden(buf, [{3, 999}])
    leaf = leaf_for(buf)
    assert leaf.total_lines == 1
    assert leaf.hidden_lines == MapSet.new([1, 2])
  end
end
