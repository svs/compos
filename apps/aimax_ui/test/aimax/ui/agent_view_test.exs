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

    result =
      ~s({"_meta":null,"content":[{"text":"p95 9.4ms","type":"text"}],"structuredContent":null})

    Buffer.append(buf, result <> "\n", source: :editor)
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
    {:ok, view, html} = live(conn, "/")

    assert html =~ "agent-view"
    assert html =~ "ag-user"
    assert html =~ "profile redisplay"
    # markdown became HTML in the prose block
    assert html =~ "<strong>0.6ms</strong>"
    # tool card with verb, title, status; body present
    assert html =~ "ag-verb"
    assert html =~ "ag-chevron"
    assert html =~ "ag-tool done"
    assert html =~ "ag-shimmer"
    assert html =~ "run M-x profile, done. Toggle call details"
    assert html =~ "M-x profile"
    refute html =~ "structuredContent"
    assert has_element?(view, ".ag-preview", "p95 9.4ms")
    refute has_element?(view, "details.ag-tool[open]")

    view |> element(~s(summary[phx-click="agent_card"])) |> render_click()
    assert has_element?(view, "details.ag-tool[open] pre.ag-body", "p95 9.4ms")
    refute has_element?(view, "details.ag-tool[open] pre.ag-body", result)
    refute has_element?(view, ".ag-preview")
    # input row carries the typed tail; the hint yields its space while typing
    assert html =~ "half-typed"
    refute html =~ "RET sends"
    # no raw marker rendered in rich mode
    refute html =~ ">>> you: profile"
  end

  # the transcript lives in its own LiveComponent so a keystroke diffs to a
  # skip placeholder — typing must leave the blocks intact and reach the input
  test "typing updates the input row and keeps the transcript blocks", %{conn: conn} do
    buf = "*agent: type-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    Buffer.append(buf, "hello\n", source: :editor)
    t_start = Buffer.byte_size(buf)
    Buffer.append(buf, "\n▸ run · M-x probe\n", source: :editor)
    b_start = Buffer.byte_size(buf)
    Buffer.append(buf, "result line\n", source: :editor)
    mark = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: dra", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "type-test")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))

    Buffer.set_local(buf, "agent-blocks", [
      [t_start, mark, "tool", "t1", "M-x probe", "run", "done", b_start]
    ])

    Editor.set_window_buffer(buf)
    {:ok, view, html} = live(conn, "/")
    assert html =~ "ag-tool done"
    assert html =~ "dra"

    render_hook(view, "key", %{"k" => "M->"})
    render_hook(view, "key", %{"k" => "f"})
    html = render_hook(view, "key", %{"k" => "t"})

    # the char landed in the input row, and the transcript component kept
    # its blocks through the input-only renders
    assert html =~ "draft"
    assert html =~ "ag-tool done"
    assert html =~ "M-x probe"
  end

  test "agent tool cards pretty-print JSON without changing transcript bytes", %{conn: conn} do
    buf = "*agent: json-view-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    Buffer.append(buf, "\n▸ read · inspect result\n", source: :editor)
    body_start = Buffer.byte_size(buf)
    raw = ~s({"count":2,"items":["a","b"]})
    Buffer.append(buf, raw <> "\n", source: :editor)
    mark = Buffer.byte_size(buf)
    Buffer.append(buf, "\n>>> you: ", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))
    Buffer.set_local(buf, "agent-open-cards", ["json-1"])

    Buffer.set_local(buf, "agent-blocks", [
      [0, mark, "tool", "json-1", "inspect result", "read", "done", body_start]
    ])

    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "\n  &quot;"
    refute html =~ ~s({&quot;count&quot;:2)
    assert Buffer.text(buf) =~ raw
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

  test "question block renders every answer independently from permission", %{conn: conn} do
    buf = "*agent: question-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)
    Buffer.append(buf, "\n── question: Open a workspace? ──\n>>> you: ", source: :editor)

    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "question-test")
    Buffer.set_local(buf, "agent-saved-mark", 39)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size("\n>>> you: "))

    Buffer.set_local(buf, "agent-blocks", [
      [0, 39, "question", 42, "question-test", "Open a workspace?", ["Yes", "No", "Diff first"]]
    ])

    Editor.set_window_buffer(buf)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Open a workspace?"
    assert has_element?(view, ~s(button[phx-click="agent_answer"]), "Yes")
    assert has_element?(view, ~s(button[phx-click="agent_answer"]), "No")
    assert has_element?(view, ~s(button[phx-click="agent_answer"]), "Diff first")
    assert html =~ "type another reply below"
    refute html =~ "Always"
  end

  # the other branch of the one ui_cmd gate: the modeline-info segment
  # sends its buffer, and ui-command! runs that buffer's own command local
  test "modeline-info click runs the buffer's modeline-info-command", %{conn: conn} do
    buf = "*agent: ml-test*"
    {:ok, _} = Aimax.Core.create_buffer(buf)
    Buffer.append(buf, "x\n", source: :editor)
    Buffer.set_local(buf, "modeline-info", "api · test-model")
    Buffer.set_local(buf, "modeline-info-command", "split-window-below")

    Editor.set_window_buffer(buf)
    {:ok, view, html} = live(conn, "/")

    assert html =~ "api · test-model"
    # the name span carries click attributes now (modeline-expand)
    assert count(html, ~s(>*agent: ml-test*</span>)) == 1

    view |> element(~s(span[phx-click="ui_cmd"][phx-value-buf])) |> render_click()
    # the command ran: the buffer now shows in two windows
    assert count(render(view), ~s(>*agent: ml-test*</span>)) == 2
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
