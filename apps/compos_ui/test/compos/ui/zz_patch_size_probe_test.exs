defmodule Compos.Ui.ZzPatchSizeProbeTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint Compos.Ui.Endpoint
  alias Compos.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  defp collect(acc) do
    receive do
      {:trace, _, :receive, msg} -> collect([msg | acc])
    after 300 -> Enum.reverse(acc)
    end
  end

  defp sizes(msgs) do
    for m <- msgs do
      payload =
        case m do
          %{payload: p} -> p
          {_, _, %{payload: p}} -> p
          other -> other
        end
      try do
        {inspect(elem_kind(m)), byte_size(Phoenix.json_library().encode!(payload)), payload |> inspect(printable_limit: 300) |> binary_part(0, 0)}
      rescue
        e -> {inspect(elem_kind(m)), :erlang.external_size(payload), Exception.message(e) |> String.slice(0, 200)}
      end
    end
  end

  defp elem_kind(m) when is_tuple(m), do: elem(m, 0)
  defp elem_kind(%{__struct__: s}), do: s
  defp elem_kind(m), do: m

  @scratch "/private/tmp/claude-501/-Users-svs-src-compos/180661b4-84b6-4505-b38d-180901ba7096/scratchpad"

  defp to_scheme(m) when is_map(m), do: Enum.flat_map(m, fn {k, v} -> [{:sym, k}, to_scheme(v)] end)
  defp to_scheme(l) when is_list(l), do: Enum.map(l, &to_scheme/1)
  defp to_scheme(v), do: v

  defp pget([{:sym, k}, v | _], k), do: v
  defp pget([_, _ | r], k), do: pget(r, k)
  defp pput([{:sym, k}, _ | r], k, v), do: [{:sym, k}, v | r]
  defp pput([a, b | r], k, v), do: [a, b | pput(r, k, v)]

  test "probe", %{conn: conn} do
    buf = "*agent: probe*"
    {:ok, _} = Compos.Core.create_buffer(buf)
    Buffer.append(buf, File.read!(Path.join(@scratch, "text.txt")), source: :editor)
    [tree, root, input, mark] = Path.join(@scratch, "tree.json") |> File.read!() |> Jason.decode!() |> to_scheme()
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "render-mode", "blocks")
    Buffer.set_local(buf, "render-blocks", tree)
    Buffer.set_local(buf, "render-root", root)
    Buffer.set_local(buf, "render-input", input)
    Editor.set_window_buffer(buf)
    {:ok, view, _html} = live(conn, "/")
    render_hook(view, "key", %{"k" => "M->"})
    Process.sleep(300)
    {_, _, proxy} = view.proxy
    :erlang.trace(proxy, true, [:receive])
    for k <- ["f", "t", "x"] do
      html = render_hook(view, "key", %{"k" => k})
      Process.sleep(500)
      msgs = collect([])
      IO.inspect(sizes(msgs), label: "key #{k}")
      IO.inspect(html =~ "draf", label: "typed")
    end
    # one new block at the tail of the transcript, as a streaming reply adds
    [t | rest] = tree
    kids = pget(t, "children")
    t2 = pput(t, "children", kids ++ [[{:sym, "tag"}, "c-group", {:sym, "class"}, "ag-prose", {:sym, "text"}, "new tail"]])
    Buffer.set_local(buf, "render-blocks", [t2 | rest])
    html = render_hook(view, "key", %{"k" => "y"})
    Process.sleep(500)
    tm = collect([])
    IO.inspect(sizes(tm), label: "tail block")
    for %Phoenix.Socket.Message{payload: pl} <- tm do
      File.write!(Path.join(@scratch, "diff.json"), Jason.encode!(pl))
    end
    IO.inspect(html =~ "new tail", label: "tail shown")
  end
end
