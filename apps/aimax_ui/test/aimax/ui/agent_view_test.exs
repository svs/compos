defmodule Aimax.Ui.AgentViewTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  alias Aimax.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()

    on_exit(fn ->
      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent"), do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    {:ok, conn: build_conn()}
  end

  # build a rich thread without any runtime: buffer + locals only —
  # the renderer is a pure view over text + block model
  test "agent render-mode draws blocks, tool card, input row", %{conn: conn} do
    buf = "*agent: view-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    Buffer.append(buf, ";; agent thread\n", source: :editor)
    u_start = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: profile redisplay\n\n", source: :editor)
    p_start = Buffer.byte_size(buf)
    Buffer.append(buf, "Paint is **0.6ms** now.\n", source: :editor)
    t_start = Buffer.byte_size(buf)
    Buffer.append(buf, "\n▸ run · M-x profile\n", source: :editor)
    b_start = Buffer.byte_size(buf)
    Buffer.append(buf, "p95 9.4ms\n", source: :editor)
    mark = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: ", source: :editor)
    Buffer.append(buf, "half-typed", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "view-test")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))
    Buffer.set_local(buf, "agent-queued", [])

    Buffer.set_local(buf, "agent-blocks", [
      [t_start, mark, "tool", "t1", "M-x profile", "run", "done", b_start],
      [p_start, t_start, "prose"],
      [u_start, p_start, "user", "profile redisplay"]
    ])

    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "agent-view"
    assert html =~ "ag-user"
    assert html =~ "profile redisplay"
    # markdown became HTML in the prose block
    assert html =~ "<strong>0.6ms</strong>"
    # tool card with verb, title, status; body present
    assert html =~ "ag-verb"
    assert html =~ "M-x profile"
    assert html =~ "p95 9.4ms"
    # input row carries the typed tail; the hint yields its space while typing
    assert html =~ "half-typed"
    refute html =~ "RET sends"
    # no raw marker rendered in rich mode
    refute html =~ ">>> you: profile"
  end

  test "permission block renders buttons that dispatch agent commands", %{conn: conn} do
    buf = "*agent: perm-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)
    Buffer.append(buf, "x\n── needs permission: Write foo.ex ──\n>>> you: ", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "perm-test")
    Buffer.set_local(buf, "agent-saved-mark", 37)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))
    Buffer.set_local(buf, "agent-blocks", [[1, 37, "permission", "Write foo.ex"]])

    Editor.set_window_buffer(buf)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "needs permission — Write foo.ex"
    assert html =~ "Allow"

    # clicking runs the scheme command path (no pending permission -> message)
    view |> element("button.ag-btn.allow", "Allow") |> render_click()
    assert render(view) =~ "no pending permission"
  end

  # block offsets go stale when text before them is edited; a boundary that
  # lands mid-codepoint must not take down the whole render (Earmark badarg)
  test "stale block offsets mid-multibyte char still render", %{conn: conn} do
    buf = "*agent: utf8-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    p_start = 0
    Buffer.append(buf, "site — dash\n", source: :editor)
    mark = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: ", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "utf8-test")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))
    # "site — dash\n": the em dash starts at byte 5; end offset 6 is inside it
    Buffer.set_local(buf, "agent-blocks", [[p_start, 6, "prose"]])

    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "agent-view"
    assert html =~ "site"
    # empty input row shows the keybinding hint
    assert html =~ "RET sends"
  end

  # A table shrinks to the width it is given and clips the rest, so the
  # scrollbar must sit on a box OUTSIDE it. Earmark emits a bare <table>;
  # the renderer wraps each one. Lose the wrapper and a wide table clips.
  test "a markdown table renders inside its own scroll box", %{conn: conn} do
    buf = "*agent: table-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    md = """
    | Name | Rating |
    |------|--------|
    | Amandeep Yadav | 3/5 |
    """

    Buffer.append(buf, md, source: :editor)
    mark = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: ", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "table-test")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))
    Buffer.set_local(buf, "agent-blocks", [[0, mark, "prose"]])

    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(<div class="ag-table"><table>)
    assert html =~ "</table></div>"
    assert html =~ "Amandeep Yadav"
    # every wrapper opens and closes: an unbalanced replace breaks the layout
    assert count(html, ~s(<div class="ag-table">)) == count(html, "</table></div>")
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
