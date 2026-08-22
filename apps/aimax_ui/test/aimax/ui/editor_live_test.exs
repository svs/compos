defmodule Aimax.Ui.EditorLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  defp type(view, str), do: keys(view, String.graphemes(str))

  setup do
    Aimax.Core.Editor.minibuffer_close()
    Aimax.Core.Editor.completion_dismiss()
    Aimax.Core.Editor.set_pending([])
    Aimax.Core.Editor.set_total_rows(40)
    Aimax.Core.Editor.delete_other_windows()
    Aimax.Core.Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts and shows the window with modeline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "modeline"
    assert html =~ "ui-test-"
  end

  # Any click in a preview iframe moves focus into the iframe, and the blur
  # relay answers with a win-only mouse event — for a right click too. A
  # window selection is not a click on text, so it must keep the region.
  test "a win-only mouse event keeps the region, a text click clears it", %{conn: conn} do
    buf = Aimax.Core.Editor.current_buffer()

    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(begin (switch-to-buffer! "#{buf}") (insert! "alpha beta") (set-mark! 2) (goto-char! 7))}
      )

    win = Aimax.Core.Editor.render_state() |> Map.get(:tree) |> Map.get(:id)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("mouse", %{"win" => win})
    assert {:ok, "2"} = Aimax.Core.Session.eval("(mark)")

    view |> element("#editor") |> render_hook("mouse", %{"win" => win, "line" => 0, "col" => 1})
    assert {:ok, cleared} = Aimax.Core.Session.eval("(mark)")
    assert cleared in [false, "#f"]
  end

  test "a worktree buffer renders its persistent header and attention frame", %{conn: conn} do
    buf = Aimax.Core.Editor.current_buffer()

    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(begin (buffer-set-local! "#{buf}" 'header-line "WORKTREE a1 · UNMERGED") (buffer-set-local! "#{buf}" 'window-class "workspace-pending"))}
      )

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "buffer-header"
    assert html =~ "WORKTREE a1 · UNMERGED"
    assert html =~ "workspace-pending"
  end

  test "a workspace daemon renders one frame-wide worktree bar", %{conn: conn} do
    old_root = Application.get_env(:aimax_core, :workspace_root)
    old_name = Application.get_env(:aimax_core, :name)
    old_project = Application.get_env(:aimax_core, :workspace_project)
    old_workspace_name = Application.get_env(:aimax_core, :workspace_name)
    Application.put_env(:aimax_core, :workspace_root, "/tmp/ai-max-worktrees/a1")
    Application.put_env(:aimax_core, :name, "worktree-a1")
    Application.put_env(:aimax_core, :workspace_project, "ai-max")
    Application.put_env(:aimax_core, :workspace_name, "workspace prompts")

    on_exit(fn ->
      if old_root,
        do: Application.put_env(:aimax_core, :workspace_root, old_root),
        else: Application.delete_env(:aimax_core, :workspace_root)

      if old_name,
        do: Application.put_env(:aimax_core, :name, old_name),
        else: Application.delete_env(:aimax_core, :name)

      if old_project,
        do: Application.put_env(:aimax_core, :workspace_project, old_project),
        else: Application.delete_env(:aimax_core, :workspace_project)

      if old_workspace_name,
        do: Application.put_env(:aimax_core, :workspace_name, old_workspace_name),
        else: Application.delete_env(:aimax_core, :workspace_name)
    end)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "workspace-bar"
    assert html =~ "WORKTREE"
    assert html =~ "ai-max / workspace prompts"
    assert html =~ "PORT 4046"
    assert html =~ "/tmp/ai-max-worktrees/a1"
  end

  test "a raw buffer publishes visual-line mode to the client", %{conn: conn} do
    buf = Aimax.Core.Editor.current_buffer()

    {:ok, _} =
      Aimax.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'visual-line-mode #t)})

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-visual-lines="true")
    assert html =~ ~s(class="buf)
  end

  test "typing renders into the buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "hello")
    assert html =~ "hello"
    assert html =~ "L1:C5"
  end

  test "markdown preview updates a stable iframe without navigating srcdoc", %{conn: conn} do
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "# Stable preview\n", source: :editor)
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'render-mode "markdown")})

    {:ok, view, _} = live(conn, "/")
    html = render(view)

    assert html =~ ~s(id="prev-)
    assert html =~ ~s(data-doc=")
    refute html =~ "srcdoc="

    [_, encoded] = Regex.run(~r/data-doc="([^"]+)"/, html)
    assert Base.decode64!(encoded) =~ "Stable preview"
  end

  test "minibuffer shows on M-x with selectable candidates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["M-x"])
    assert html =~ "M-x "
    assert html =~ "mb-cand selected"

    # candidate order is recency-first, so filter before asserting a name
    html = type(view, "backwardchar")
    assert html =~ "backward-char"
    keys(view, ["C-g"])
  end

  test "which-key renders on C-x", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x"])
    assert html =~ "which-key"
    assert html =~ "switch-to-buffer"
    keys(view, ["C-g"])
  end

  test "window splits render as a tree", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x", "3"])
    assert html =~ ~s(class="split h")
    html = keys(view, ["C-x", "1"])
    refute html =~ ~s(class="split h")
  end

  test "undo works through the window", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "xy")
    assert html =~ "xy"
    html = keys(view, ["C-/"])
    refute html =~ "xy"
  end

  # An overlay range is bytes. A range that ends inside a multi-byte
  # character used to cut the segment mid-character, and Jason killed the
  # socket on the reply: the window went blank and no client could
  # reconnect. The segments now snap to character boundaries.
  test "an overlay that ends inside a multi-byte character still renders",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "    —     — a command", source: {:agent, "test"})

    # the em dash occupies bytes 4..6; end the overlay on byte 5, inside it
    {:ok, _} =
      Aimax.Core.Session.eval(~s{(overlay-set! "#{buf}" 'zz-utf8 (list (list 0 5 "region")))})

    html = render(view)
    assert html =~ "a command"
    assert String.valid?(html)
  end

  test "an avatar image keeps its layout class and clean source", %{conn: conn} do
    buf = Aimax.Core.Editor.current_buffer()
    url = "https://images.example/avatar.jpeg"

    Aimax.Core.Buffer.append(
      buf,
      url <> "#aimax-avatar Alice · Aug 3",
      source: {:agent, "test"}
    )

    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(overlay-set! "#{buf}" 'zz-avatar (list (list 0 #{byte_size(url <> "#aimax-avatar")} "img-embed")))}
      )

    # Point at byte zero used to split the image URL into a cursor-wrapped
    # "h" and visible "ttps://...", so the image component never ran.
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-goto! "#{buf}" 0)})

    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(<img src="#{url}" class="img-embed img-avatar")
    assert html =~ "align-items: flex-end"
    refute html =~ "#aimax-avatar"
    assert html =~ "Alice · Aug 3"
  end

  # Every dired test read the buffer text, so all of them passed while the
  # window showed nothing. The buffer kept 'render-mode "blocks" from the
  # mode before it, and a leaf that says "blocks" draws cards, not lines.
  # This test reads the window, which is where the listing went missing.
  test "a dired window renders its listing, stale render-mode or not", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "ui-dired-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "gamma.txt"), "G")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, view, _} = live(conn, "/")
    {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
    assert render(view) =~ "gamma.txt"

    # the local a previous mode left behind must not empty the window
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-local! "#{root}" 'render-mode "blocks")})
    html = render(view)
    assert html =~ "gamma.txt"
    # the card view draws one div per window; the stylesheet names the
    # class too, so match the div's id rather than the class
    refute html =~ ~s(id="blocks-)
  end

  test "rpc/agent edits to a visible buffer appear live", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render(view)
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "pushed from outside", source: {:agent, "test"})
    # event-driven re-render
    assert render(view) =~ "pushed from outside"
  end

  test "a completed rich chat accepts the next input through the UI", %{conn: conn} do
    before = MapSet.new(Aimax.Core.Agent.list())

    # the script rides a CONNECTOR, not one call's opts: the second turn
    # re-attaches, and a chat that only remembers a connector name would
    # come back on the default backend and hang
    {:ok, _} =
      Aimax.Core.Session.eval("""
      (define-connector! "zz-ui-stub" '(backend "stub" script
        (((type tool-call id "tc1" title "Large completed edit" kind "other" status "pending")
          (type tool-update id "tc1" status "completed" text "#{String.duplicate("changed line", 2_000)}"))
         ((type chunk text "Accepted next input.")))))
      """)

    {:ok, _} = Aimax.Core.Session.eval(~s{(execute* "first" '(connector "zz-ui-stub"))})

    [slug] = MapSet.difference(MapSet.new(Aimax.Core.Agent.list()), before) |> MapSet.to_list()
    on_exit(fn -> Aimax.Core.Agent.kill(slug) end)

    assert eventually(fn -> Aimax.Core.Agent.info(slug).status == :idle end)
    buf = Aimax.Core.Agent.info(slug).buffer

    {:ok, view, _} = live(conn, "/b/" <> URI.encode_www_form(buf))
    keys(view, String.graphemes("done?") ++ ["RET"])

    assert eventually(fn -> render(view) =~ "Accepted next input." end)
  end

  test "the activity row shows work in progress and clears at turn end", %{conn: conn} do
    before = MapSet.new(Aimax.Core.Agent.list())

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (execute* "first" '(backend "stub" script (((type chunk text "done.")))))
      """)

    [slug] = MapSet.difference(MapSet.new(Aimax.Core.Agent.list()), before) |> MapSet.to_list()
    on_exit(fn -> Aimax.Core.Agent.kill(slug) end)

    assert eventually(fn -> Aimax.Core.Agent.info(slug).status == :idle end)
    buf = Aimax.Core.Agent.info(slug).buffer

    {:ok, view, _} = live(conn, "/b/" <> URI.encode_www_form(buf))
    refute render(view) =~ "ag-activity"

    # the real event path sets the activity word; a chunk mid-turn says so
    {:ok, _} =
      Aimax.Core.Session.eval("(agent-handle-event \"#{slug}\" '(type chunk text \"more \"))")

    assert eventually(fn -> render(view) =~ "streaming" end)
    assert render(view) =~ "ag-activity"

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(agent-handle-event \"#{slug}\" '(type turn-end stop-reason \"end_turn\"))"
      )

    assert eventually(fn -> not (render(view) =~ "ag-activity") end)
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end
end
