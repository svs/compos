defmodule Compos.Ui.BlockListStreamTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Buffer, BufferView, Editor}
  alias Compos.Ui.EditorLive

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")

    on_exit(fn ->
      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*blist-stream-"), do: Compos.Core.kill_buffer(name)
      end)

      {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    end)

    {:ok, conn: build_conn()}
  end

  defp pl(pairs), do: Enum.flat_map(pairs, fn {k, v} -> [{:sym, to_string(k)}, v] end)

  defp make_list_buf(name, initial \\ "First block\n") do
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, initial, source: :editor)
    p1 = Buffer.byte_size(name)
    Buffer.set_local(name, "render-root", pl(tag: "c-buffer", class: "agent-view"))
    Buffer.set_local(name, "render-mode", "blocks")
    Buffer.set_local(name, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown")
        ])
    ])
    Editor.set_window_buffer(name)
    {name, p1}
  end

  test "stream appends, updates in place, deletes, and resets on buffer switch", %{conn: conn} do
    {buf, p1} = make_list_buf("*blist-stream-1*")
    {:ok, view, html} = live(conn, "/b/" <> URI.encode_www_form(buf))
    assert html =~ "First block"
    assert has_element?(view, ~s(c-transcript[phx-update="stream"]))

    # Append a second block
    Buffer.append(buf, "Second block\n", source: :editor)
    p2 = Buffer.byte_size(buf)
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown"),
          pl(tag: "c-agent", class: "ag-prose", range: [p1, p2], format: "markdown")
        ])
    ])
    html2 = render(view)
    assert html2 =~ "First block"
    assert html2 =~ "Second block"

    # Stream-extend the second block in place
    Buffer.append(buf, "more words\n", source: :editor)
    p3 = Buffer.byte_size(buf)
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown"),
          pl(tag: "c-agent", class: "ag-prose", range: [p1, p3], format: "markdown")
        ])
    ])
    html3 = render(view)
    assert html3 =~ "First block"
    assert html3 =~ "more words"

    # Delete the second block
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown")
        ])
    ])
    html4 = render(view)
    assert html4 =~ "First block"
    refute html4 =~ "more words"

    # Switch buffer in the same window: stream resets cleanly
    {buf2, _} = make_list_buf("*blist-stream-other*", "Other chat\n")
    Editor.set_window_buffer(buf2)
    html5 = render(view)
    assert html5 =~ "Other chat"
    refute html5 =~ "First block"
  end

  # A rejoin makes a new list component whose stream has a new ref, and a
  # stream reset removes only the items of its own ref: the old items stayed
  # in the reused element as empty boxes. A new instance draws a new element.
  test "a new mount draws the list in a new element; updates keep it", %{conn: conn} do
    {buf, p1} = make_list_buf("*blist-stream-4*")
    list_id = fn html ->
      [_, id] = Regex.run(~r/<c-transcript[^>]*\sid="([^"]+)"/, html)
      id
    end

    {:ok, view1, html1} = live(conn, "/b/" <> URI.encode_www_form(buf))
    id1 = list_id.(html1)

    Buffer.append(buf, "Second block\n", source: :editor)
    p2 = Buffer.byte_size(buf)
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown"),
          pl(tag: "c-agent", class: "ag-prose", range: [p1, p2], format: "markdown")
        ])
    ])
    assert list_id.(render(view1)) == id1

    {:ok, _view2, html2} = live(build_conn(), "/b/" <> URI.encode_www_form(buf))
    assert html2 =~ "Second block"
    refute list_id.(html2) == id1
  end

  test "blocks mode snapshot skips full rope flattening and overlays" do
    {buf, _p1} = make_list_buf("*blist-stream-2*")
    Buffer.insert(buf, "tail")
    snap = BufferView.snapshot(buf)
    assert snap.size == Buffer.byte_size(buf)
    assert snap.text == ""
    assert snap.overlays == []
    assert snap.hidden == []
    assert snap.edit_positions != []
  end

  test "decorate_tree rebuilds only dirty isolated children after an append" do
    {buf, p1} = make_list_buf("*blist-stream-3*")
    Buffer.append(buf, "Second\n", source: :editor)
    p2 = Buffer.byte_size(buf)
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown"),
          pl(tag: "c-agent", class: "ag-prose", range: [p1, p2], format: "markdown")
        ])
    ])

    state1 = Editor.render_state()
    {tree1, cache1} = EditorLive.decorate_tree(state1.tree, %{}, state1.faces, state1.active)
    [c0_1, c1_1] = hd(leaf(tree1).blk).children

    # Append text to the second block only
    Buffer.append(buf, "extra\n", source: :editor)
    p3 = Buffer.byte_size(buf)
    Buffer.set_local(buf, "render-blocks", [
      pl(tag: "c-transcript", class: "ag-scroll", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "ag-prose", range: [0, p1], format: "markdown"),
          pl(tag: "c-agent", class: "ag-prose", range: [p1, p3], format: "markdown")
        ])
    ])

    state2 = Editor.render_state()
    {tree2, _} = EditorLive.decorate_tree(state2.tree, cache1, state2.faces, state2.active)
    [c0_2, c1_2] = hd(leaf(tree2).blk).children

    assert :erts_debug.same(c0_1, c0_2)
    refute :erts_debug.same(c1_1, c1_2)
    assert c0_2.stream_key == "i-0"
    assert c1_2.stream_key == "i-1"
    assert c1_2.frozen_parts.inner =~ "extra"
  end

  defp leaf(%{type: :leaf} = l), do: l
  defp leaf(%{children: cs}), do: Enum.find_value(cs, &leaf_or_nil/1)
  defp leaf_or_nil(%{type: :leaf, render_mode: "blocks"} = l), do: l
  defp leaf_or_nil(%{children: _} = n), do: leaf(n)
  defp leaf_or_nil(_), do: nil
end
