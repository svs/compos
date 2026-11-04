defmodule Compos.Ui.TextDisplayTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Compos.Core.{Buffer, Editor, Input}
  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Editor.set_total_rows(20)
    name = "display-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    Buffer.append(name, Enum.map_join(1..5000, "\n", &"row #{&1} λ"), source: :editor)
    Buffer.goto(name, 0)
    id = "display-test-#{name}"

    :telemetry.attach(
      id,
      [:compos, :ui, :text_display],
      fn _, m, meta, pid ->
        send(pid, {:display_work, meta.buffer, m})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, name: name, conn: build_conn()}
  end

  defp frame(html), do: Regex.run(~r/data-frame="([^"]+)"/, html) |> Enum.at(1)

  test "prepares only the viewport, including after a deep scroll", %{conn: conn, name: name} do
    {:ok, view, html} = live(conn, "/")
    fid = frame(html)
    assert_receive {:display_work, ^name, %{visible: count, prepared: prepared}}
    assert count <= Editor.render_state(fid).tree.rows * 3 + 8
    assert prepared == count
    refute has_element?(view, ".buf.client-scroll")
    refute has_element?(view, ".line", "row 5000 λ")
    win = Editor.render_state(fid).tree.id
    view |> element("#editor") |> render_hook("scroll", %{"win" => win, "lines" => 4000})
    assert has_element?(view, ".line", "row 4001 λ")
    assert_receive {:display_work, ^name, %{visible: deep_count}}
    assert deep_count <= Editor.render_state(fid).tree.rows * 3 + 8
  end

  test "a key prepares one row and reuses the rest despite shifted offsets", %{
    conn: conn,
    name: name
  } do
    {:ok, view, html} = live(conn, "/")
    fid = frame(html)
    assert_receive {:display_work, ^name, %{visible: count}}
    Input.dispatch(fid, "x")
    assert has_element?(view, ".line", "xrow 1 λ")
    assert String.starts_with?(Buffer.text(name), "xrow 1 λ")
    assert_receive {:display_work, ^name, %{visible: ^count, prepared: 1, reused: reused}}
    assert reused == count - 1

    Editor.set_echo("unrelated frame display", fid)
    render(view)
    refute_receive {:display_work, ^name, _}, 50
  end

  test "faces change when an overlay changes without a text edit", %{conn: conn, name: name} do
    {:ok, view, _} = live(conn, "/")
    assert_receive {:display_work, ^name, _}
    Buffer.set_overlays(name, "display-test", [{0, 3, "error"}])
    assert has_element?(view, ".f-error", "row")
    assert_receive {:display_work, ^name, %{prepared: 1}}
  end

  test "line motion crosses a viewport boundary in both directions", %{conn: conn, name: name} do
    text = Buffer.text(name)
    {start, _} = :binary.match(text, "row 4001 λ")
    {above, _} = :binary.match(text, "row 4000 λ")
    Buffer.goto(name, start)
    {:ok, view, html} = live(conn, "/")
    fid = frame(html)
    win = Editor.render_state(fid).tree.id
    view |> element("#editor") |> render_hook("scroll", %{"win" => win, "lines" => 4000 - Editor.render_state(fid).tree.top})
    v = Buffer.version(name)
    view |> element("#editor") |> render_hook("edge_motion", %{
      "win" => win, "point" => start, "v" => v, "dir" => -1, "count" => 1
    })
    assert Buffer.point(name) == above
    assert has_element?(view, ".line", "row 4000 λ")
    tree = Editor.render_state(fid).tree
    assert tree.top == 3999 - div(tree.rows, 2)
    view |> element("#editor") |> render_hook("edge_motion", %{
      "win" => win, "point" => above, "v" => v, "dir" => 1, "count" => 1, "extend" => true
    })
    assert Buffer.point(name) == start
    assert Buffer.mark(name) == above
    view |> element("#editor") |> render_hook("edge_motion", %{
      "win" => win, "point" => above, "v" => v - 1, "dir" => -1, "count" => 1
    })
    assert Buffer.point(name) == start
  end

  test "typing preserves faces while fontification is pending, then corrects them", %{
    conn: conn,
    name: name
  } do
    Buffer.insert_at(name, 0, "value = 42\nother = 100\n")
    Buffer.goto(name, 0)
    Buffer.set_local(name, "ts-lang", "elixir")
    {:ok, view, html} = live(conn, "/")
    fid = frame(html)
    await_element(view, ".ts-number", "42")

    # Hold the worker's timer so the intermediate render is deterministic.
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    timer = Process.send_after(pid, :fontify, 60_000)
    :sys.replace_state(pid, fn state -> put_in(state.fontify.timer, timer) end)
    on_exit(fn -> Process.cancel_timer(timer) end)

    Input.dispatch(fid, "#")
    assert has_element?(view, ".line", "#value = 42")
    assert has_element?(view, ".ts-number", "42")
    assert has_element?(view, ".ts-number", "100")

    send(pid, :fontify)
    await_element(view, ".ts-comment", "#value = 42")
    refute view |> element(".line", "#value = 42") |> render() =~ "ts-number"
    assert has_element?(view, ".ts-number", "100")
  end

  defp await_element(view, selector, text, tries \\ 100)
  defp await_element(_, _, _, 0), do: flunk("highlight did not arrive")

  defp await_element(view, selector, text, tries) do
    unless has_element?(view, selector, text) do
      Process.sleep(20)
      await_element(view, selector, text, tries - 1)
    end
  end

  test "narrowing selects source lines before preparing them", %{conn: conn, name: name} do
    text = Buffer.text(name)
    {start, _} = :binary.match(text, "row 4200 λ")
    {stop, _} = :binary.match(text, "row 4203 λ")
    Buffer.narrow(name, start, stop)
    Buffer.goto(name, start)
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, ".line", "row 4200 λ")
    assert has_element?(view, ".line", "row 4202 λ")
    refute has_element?(view, ".line", "row 4203 λ")
    assert_receive {:display_work, ^name, %{visible: 3, prepared: 3}}
  end
end
