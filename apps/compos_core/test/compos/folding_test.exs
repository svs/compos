defmodule Compos.FoldingTest do
  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor}

  defp fresh_buffer(text) do
    name = "fold-#{System.unique_integer([:positive])}"
    Compos.TestHelpers.one_window!()
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

  test "repeated renders keep fold geometry current across edits and narrowing" do
    buf = fresh_buffer("* a\nbody1\nbody2\n* b\ntail")
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)
    Buffer.set_hidden(buf, [{3, 15}])
    first = leaf_for(buf)
    Buffer.set_local(buf, "modeline-info", "changed elsewhere")
    assert leaf_for(buf).hidden_lines == first.hidden_lines
    assert leaf_for(buf).total_lines == 3

    Buffer.set_hidden(buf, [{3, 9}])
    assert leaf_for(buf).hidden_lines == MapSet.new([1])
    assert leaf_for(buf).total_lines == 4
    Buffer.narrow(buf, 10, 24)
    assert leaf_for(buf).total_lines == 3
    Buffer.widen(buf)
    Buffer.append(buf, "\nmore", source: :editor)
    assert leaf_for(buf).total_lines == 5
    Buffer.set_hidden(buf, [])
    assert leaf_for(buf).total_lines == 6
    assert leaf_for(buf).hidden_lines == MapSet.new()
  end

  test "an unchanged folded window does not rescan geometry on another redraw" do
    buf = fresh_buffer(String.duplicate("line\n", 1000))
    Buffer.set_hidden(buf, [{4, 499}])
    mfa = {Editor, :visible_geometry, 4}
    :erlang.trace_pattern(mfa, true, [:local, :call_count])

    try do
      leaf_for(buf)
      assert :erlang.trace_info(mfa, :call_count) == {:call_count, 1}
      Buffer.set_local(buf, "modeline-info", "updated")
      leaf_for(buf)
      leaf_for(buf)
      assert :erlang.trace_info(mfa, :call_count) == {:call_count, 1}
      Buffer.goto(buf, 500)
      leaf_for(buf)
      assert :erlang.trace_info(mfa, :call_count) == {:call_count, 2}
    after
      :erlang.trace_pattern(mfa, false, [:local, :call_count])
      Compos.Core.kill_buffer(buf)
    end
  end
end
