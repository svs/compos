defmodule Compos.Ui.BlockListStreamTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Buffer, BufferView, Editor}

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

  defp make_list_buf(name) do
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, "First block\n", source: :editor)
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

  test "stream appends, updates in place, and deletes without losing existing items", %{conn: conn} do
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
end
