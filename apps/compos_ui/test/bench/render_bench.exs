# Phase 3 step 4 measurement: what one key costs the render path, per kind
# of window. Not part of the suite (no _test suffix); run it by name:
#   cd apps/compos_ui && mix test test/bench/render_bench.exs
#
# Four columns per window kind:
#   state   - Editor.render_state/1, the core payload walk
#   decorate- EditorLive.decorate_tree/4 with a warm cache (a key after a key)
#   cold    - the same with an empty cache (a new window, a reload)
#   key     - one key end to end through the LiveView: dispatch, refresh,
#             render, diff, and the test client's patch
# and the rendered page size. Times are p50 microseconds over N keys.
defmodule Compos.Ui.RenderBench do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Buffer, Editor}
  alias Compos.Ui.EditorLive

  @endpoint Compos.Ui.Endpoint
  @n 60

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    :ok
  end

  defp us(fun) do
    t0 = System.monotonic_time(:microsecond)
    fun.()
    System.monotonic_time(:microsecond) - t0
  end

  defp p50(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))

  defp measure(label, keys) do
    {:ok, view, _} = live(build_conn(), "/")
    for k <- Enum.take(Stream.cycle(keys), 10), do: render_hook(element(view, "#editor"), "key", %{"k" => k})

    key =
      for k <- Enum.take(Stream.cycle(keys), @n) do
        us(fn -> render_hook(element(view, "#editor"), "key", %{"k" => k}) end)
      end

    state = Editor.render_state()
    faces = state.faces
    {_, warm} = EditorLive.decorate_tree(state.tree, %{}, faces, state.active)

    st = for _ <- 1..@n, do: us(fn -> Editor.render_state() end)
    dec = for _ <- 1..@n, do: us(fn -> EditorLive.decorate_tree(state.tree, warm, faces, state.active) end)
    cold = for _ <- 1..10, do: us(fn -> EditorLive.decorate_tree(state.tree, %{}, faces, state.active) end)
    bytes = byte_size(render(view))

    IO.puts(
      String.pad_trailing(label, 22) <>
        " state #{p50(st)}  decorate #{p50(dec)}  cold #{p50(cold)}  key #{p50(key)}  page #{bytes} B"
    )
  end

  test "render path, per window kind" do
    IO.puts("\nrender path, p50 microseconds (N=#{@n})")

    # a file buffer of 3,000 lines of Elixir, typing near the top
    # a copy outside any repository: a file inside a worktree provisions a
    # workspace daemon, and the language server stays off
    dir = Path.join(System.tmp_dir!(), "compos-render-bench")
    File.mkdir_p!(dir)
    path = Path.join(dir, "editor.ex")
    File.cp!(Path.expand("../../../compos_core/lib/compos/core/editor.ex", __DIR__), path)
    {:ok, _} = Compos.Core.Session.eval("(customize-set! 'lsp-auto-start #f)")
    {:ok, _} = Compos.Core.Session.eval(~s{(visit "#{path}")})
    buf = Editor.current_buffer()
    Buffer.goto(buf, 200)
    measure("file 3k lines C-f/C-b", ["C-f", "C-b"])
    Buffer.set_read_only(buf, false)
    measure("file 3k lines type", ["x", "DEL"])
    Compos.Core.kill_buffer(buf)

    # a chat transcript of 300 blocks in the rich view, typing at the input
    chat = "*agent: zz-render-bench*"
    {:ok, _} = Compos.Core.create_buffer(chat)
    blocks =
      Enum.flat_map(1..100, fn i ->
        u = Buffer.byte_size(chat)
        Buffer.append(chat, "\n>>> you: question #{i}\n\n", source: :editor)
        p = Buffer.byte_size(chat)
        Buffer.append(chat, "An answer with **bold** and `code`, paragraph #{i}.\n\n- one\n- two\n", source: :editor)
        t = Buffer.byte_size(chat)
        Buffer.append(chat, "\n▸ run · tool #{i}\n", source: :editor)
        b = Buffer.byte_size(chat)
        Buffer.append(chat, ~s({"content":"result #{i}"}) <> "\n", source: :editor)
        e = Buffer.byte_size(chat)
        [[t, e, "tool", "t#{i}", "tool #{i}", "run", "done", b], [p, t, "prose"], [u, p, "user", "question #{i}"]]
      end)
      |> Enum.reverse()
    Buffer.append(chat, "\n>>> you: ", source: :editor)
    mark = Buffer.byte_size(chat)
    Buffer.set_local(chat, "render-mode", "blocks")
    Buffer.set_local(chat, "agent-slug", "zz-render-bench")
    Buffer.set_local(chat, "agent-saved-mark", mark)
    Buffer.set_local(chat, "agent-marker-bytes", 0)
    Buffer.set_local(chat, "agent-blocks", blocks)
    # Scheme composes the rich view: a whole tree, then one pushed block
    # (the common streamed event), each timed alone
    sync = fn -> Compos.Core.Session.call_named("chat-view-sync!", [chat]) end
    full = us(sync)
    push =
      for i <- 1..@n do
        Buffer.set_local(chat, "agent-blocks", [[mark, mark, "meta"] | Enum.drop(blocks, 0)] |> then(&if(rem(i, 2) == 0, do: blocks, else: &1)))
        us(sync)
      end
    idle = for _ <- 1..@n, do: us(sync)
    IO.puts("chat tree (Scheme)     full #{full}  push #{p50(push)}  unchanged #{p50(idle)}")
    Buffer.set_local(chat, "agent-blocks", blocks)
    sync.()
    Editor.set_window_buffer(chat)
    Buffer.goto(chat, Buffer.byte_size(chat))
    measure("chat 300 blocks type", ["x", "DEL"])
    Compos.Core.kill_buffer(chat)

    # a block tree of 200 rows (the list shape), moving point by a line
    list = "*zz-render-bench-list*"
    {:ok, _} = Compos.Core.create_buffer(list)
    Buffer.append(list, Enum.map_join(1..200, "\n", &"row #{&1}") <> "\n", source: :editor)
    rows =
      for i <- 1..200 do
        [{:sym, "tag"}, "div", {:sym, "class"}, "row", {:sym, "lines"}, [i, i], {:sym, "mark"}, "hl",
         {:sym, "segs"}, [["f-name", "row #{i}"], ["f-dim", " detail"]]]
      end
    Buffer.set_local(list, "render-mode", "blocks")
    Buffer.set_local(list, "render-blocks", rows)
    Editor.set_window_buffer(list)
    Buffer.goto(list, 0)
    measure("blocks 200 rows C-n/C-p", ["C-n", "C-p"])
    Compos.Core.kill_buffer(list)

    # a Markdown page of 400 lines drawn by the page renderer
    md = "*zz-render-bench.md*"
    {:ok, _} = Compos.Core.create_buffer(md)
    Buffer.append(md, Enum.map_join(1..100, "\n", &"## Section #{&1}\n\nText with *em* and a [link](http://x.y/#{&1}).\n") , source: :editor)
    Buffer.set_local(md, "render-mode", "markdown")
    Editor.set_window_buffer(md)
    Buffer.goto(md, 0)
    measure("markdown 400 lines C-f", ["C-f", "C-b"])
    Compos.Core.kill_buffer(md)
  end
end
