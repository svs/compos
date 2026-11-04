defmodule Compos.Ui.BlockKindsTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Buffer, Editor}
  alias Compos.Ui.EditorLive

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")

    on_exit(fn ->
      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*block-kinds"), do: Compos.Core.kill_buffer(name)
      end)

      {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    end)

    {:ok, conn: build_conn()}
  end

  defp pl(pairs), do: Enum.flat_map(pairs, fn {k, v} -> [{:sym, to_string(k)}, v] end)

  # a tree with every kind the renderer gains for the chat: a range drawn
  # as Markdown and as trimmed text, a controlled disclosure, a button, an
  # isolated list that follows its tail, and the caret input
  defp tree(p, s, bs, e) do
    [
      pl(tag: "c-transcript", class: "kinds-list", isolate: true, follow: true, anchor: "t",
        children: [
          pl(tag: "c-agent", class: "k-prose", range: [0, p], format: "markdown"),
          pl(tag: "c-info", class: "k-text", range: [p, s]),
          pl(tag: "details", class: "k-card", open: false,
            children: [
              pl(tag: "summary", click: "card:1", attrs: [["aria-label", "toggle"]], text: "card"),
              pl(tag: "pre", class: "k-body", range: [bs, e], format: "mcp-result")
            ]),
          pl(tag: "c-info", class: "k-empty", range: [s, s])
        ]),
      pl(tag: "button", class: "k-btn", click: "go", text: "Go"),
      pl(tag: "c-prompt", children: [pl(tag: "c-input", class: "k-input", input: true, hint: "type here")])
    ]
  end

  defp make_buffer do
    buf = "*block-kinds*"
    {:ok, _} = Compos.Core.create_buffer(buf)
    Buffer.append(buf, "Paint is **fast**.\n", source: :editor)
    p = Buffer.byte_size(buf)
    Buffer.append(buf, "  a status line  \n", source: :editor)
    s = Buffer.byte_size(buf)
    bs = s
    Buffer.append(buf, ~s({"content":[{"text":"p95 9.4ms","type":"text"}]}) <> "\n", source: :editor)
    e = Buffer.byte_size(buf)
    Buffer.append(buf, "typed", source: :editor)
    Buffer.set_local(buf, "input-start", e)
    Buffer.set_local(buf, "render-input", "input-start")
    Buffer.set_local(buf, "render-root", pl(tag: "c-buffer", class: "kinds-view"))
    Buffer.set_local(buf, "render-mode", "blocks")
    Buffer.set_local(buf, "render-blocks", tree(p, s, bs, e))
    Editor.set_window_buffer(buf)
    buf
  end

  test "the chat's block kinds draw from the buffer's own bytes", %{conn: conn} do
    buf = make_buffer()
    Buffer.goto(buf, Buffer.byte_size(buf))
    {:ok, view, html} = live(conn, "/")

    assert has_element?(view, ".blocks-view.kinds-view")
    assert has_element?(view, ~s(c-transcript.kinds-list[phx-hook="BlockFollow"][data-stick="true"]))
    assert html =~ ~r/<strong[^>]*>(<span[^>]*>)?fast/
    assert has_element?(view, "c-info.k-text", "a status line")
    refute has_element?(view, "c-info.k-empty")
    assert has_element?(view, ~s(c-agent.k-prose[data-index="0"]))
    refute has_element?(view, "details.k-card[open]")
    assert has_element?(view, ~s(summary[phx-click="block_click"][phx-value-id="card:1"][aria-label="toggle"]))
    assert has_element?(view, "details.k-card pre.k-body", "p95 9.4ms")
    refute html =~ "\"content\""
    assert has_element?(view, ~s(button.k-btn[type="button"][phx-value-id="go"]), "Go")
    assert has_element?(view, "c-input.k-input", "typed")
    assert has_element?(view, "c-input.k-input .cursor")
    refute has_element?(view, ".input-hint")
  end

  test "an empty input shows its hint", %{conn: conn} do
    buf = make_buffer()
    size = Buffer.byte_size(buf)
    Buffer.delete_range(buf, size - 5, 5)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, ".input-hint", "type here")
  end

  test "a key after the last range keeps every list child the same term" do
    buf = make_buffer()
    Buffer.goto(buf, Buffer.byte_size(buf))
    state = Editor.render_state()
    {tree1, cache} = EditorLive.decorate_tree(state.tree, %{}, state.faces, state.active)
    Buffer.insert(buf, "x")
    state = Editor.render_state()
    {tree2, cache2} = EditorLive.decorate_tree(state.tree, cache, state.faces, state.active)
    [list1 | _] = leaf(tree1).blk
    [list2 | _] = leaf(tree2).blk
    assert :erts_debug.same(list1.children, list2.children)
    assert leaf(tree2).blk_input.pre == "typedx"

    # a changed tree rebuilds, and the unchanged children stay the same terms
    blocks = Buffer.get_local(buf, "render-blocks")
    Buffer.set_local(buf, "render-blocks", blocks ++ [pl(tag: "c-info", text: "new")])
    state = Editor.render_state()
    {tree3, _} = EditorLive.decorate_tree(state.tree, cache2, state.faces, state.active)
    [list3 | _] = leaf(tree3).blk
    refute :erts_debug.same(list2, list3)
    for {a, b} <- Enum.zip(list2.children, list3.children), do: assert(:erts_debug.same(a, b))
  end

  # The chat transcript window draws only the tail. Its first child names
  # its place in the whole list, so a moving window keeps every index, and
  # with it the memo entry of every block that stays drawn.
  test "an isolated list with an index base keeps each child's place" do
    buf = make_buffer()
    state = Editor.render_state()
    {_, cache} = EditorLive.decorate_tree(state.tree, %{}, state.faces, state.active)
    [list | rest] = Buffer.get_local(buf, "render-blocks")
    [_first | kept] = pl_children(list)
    windowed = list ++ [{:sym, "index-base"}, 1]
    Buffer.set_local(buf, "render-blocks", [put_children(windowed, kept) | rest])
    state = Editor.render_state()
    {tree, _} = EditorLive.decorate_tree(state.tree, cache, state.faces, state.active)
    [list2 | _] = leaf(tree).blk
    assert Enum.map(list2.children, &List.keyfind(&1.attrs, "data-index", 0)) ==
             [{"data-index", "1"}, {"data-index", "2"}]
  end

  defp pl_children([{:sym, "children"}, v | _]), do: v
  defp pl_children([_, _ | rest]), do: pl_children(rest)

  defp put_children([{:sym, "children"}, _ | rest], v), do: [{:sym, "children"}, v | rest]
  defp put_children([k, x | rest], v), do: [k, x | put_children(rest, v)]

  test "the reader's place mirrors into follow-place", %{conn: conn} do
    buf = make_buffer()
    {:ok, view, _} = live(conn, "/")
    render_hook(view, "follow_place", %{"buf" => buf, "stick" => false, "top" => 120, "anchor" => 2, "offset" => 7})
    assert Buffer.get_local(buf, "follow-place") == [true, 120, 2, 7]
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, ~s(c-transcript[data-stick="false"][data-scroll-anchor="2"][data-scroll-offset="7"]))
  end

  defp leaf(%{type: :leaf} = l), do: l
  defp leaf(%{children: cs}), do: Enum.find_value(cs, &(leaf_or_nil(&1)))
  defp leaf_or_nil(%{type: :leaf, render_mode: "blocks"} = l), do: l
  defp leaf_or_nil(%{children: _} = n), do: leaf(n)
  defp leaf_or_nil(_), do: nil
end
