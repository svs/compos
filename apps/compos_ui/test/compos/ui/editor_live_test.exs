defmodule Compos.Ui.EditorLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  defp type(view, str), do: keys(view, String.graphemes(str))

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.completion_dismiss()
    Compos.Core.Editor.set_pending([])
    Compos.Core.Editor.set_total_rows(40)
    Compos.Core.Editor.delete_other_windows()
    Compos.Core.Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts the frame modeline above and the buffer modeline below", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert has_element?(view, "#editor > .echo-bar + .windows")
    assert has_element?(view, ".window > .modeline:last-child")
    refute has_element?(view, ".window > .modeline:not(:last-child)")
    assert html =~ "ui-test-"
  end

  test "the bottom frame modeline keeps the active file's full path", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "compos-frame-path-#{System.unique_integer([:positive])}")
    path = Path.join(root, "notes.txt")
    File.mkdir_p!(root)
    File.write!(path, "notes\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, _} = Compos.Core.Session.eval(~s{(visit "#{path}")})
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, ".echo-bar .ml-frame-path", path)

    Compos.Core.Editor.set_echo("saved")
    assert has_element?(view, ".echo-bar .ml-frame-path", path)

    keys(view, ["C-x", "C-f"])
    assert has_element?(view, ".mb-input-row .ml-frame-path", path)
  end

  test "an instance accent renders a named frame indicator", %{conn: conn} do
    old_name = Application.get_env(:compos_core, :name)
    old_accent = Application.get_env(:compos_core, :accent)
    Application.put_env(:compos_core, :name, "code")
    Application.put_env(:compos_core, :accent, "#3f7cac")

    on_exit(fn ->
      restore_env(:name, old_name)
      restore_env(:accent, old_accent)
    end)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(data-instance="code")
    assert html =~ "instance-identified"
    assert html =~ "--instance-accent: #3f7cac"
  end

  test "an invalid instance accent does not enter CSS", %{conn: conn} do
    old_accent = Application.get_env(:compos_core, :accent)
    Application.put_env(:compos_core, :accent, "red; display: none")
    on_exit(fn -> restore_env(:accent, old_accent) end)

    {:ok, _view, html} = live(conn, "/")

    refute html =~ ~s(class="editor-root instance-identified")
    refute html =~ ~s(style="--instance-accent)
  end

  test "a window applies its buffer group color", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.set_local(buf, "modeline-group-color", "#9b6ab3")

    html = render(view)

    assert html =~ "--buffer-group-color: #9b6ab3"
  end

  test "a pinned group name appears in the window modeline", %{conn: conn} do
    {:ok, view, mounted} = live(conn, "/")
    [_, frame] = Regex.run(~r/data-frame="([^"]+)"/, mounted)
    buf = Compos.Core.Editor.render_state(frame).tree.buffer
    Compos.Core.Buffer.set_local(buf, "modeline-groups", ["pinned-group"])
    Compos.Core.Editor.set_frame_group_style("pinned-group ", "#9b6ab3", frame)
    html = render(view)

    assert html =~ ~s(class="ml-group")
    assert html =~ "· pinned-group "
  end

  defp restore_env(key, nil), do: Application.delete_env(:compos_core, key)
  defp restore_env(key, value), do: Application.put_env(:compos_core, key, value)

  test "keeps the cursor visible on a blank line", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.insert(buf, "\ntext")

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(<span class="cursor"> </span>)
  end

  test "narrowing clips both boundaries without fold ellipses", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    text =
      "# morg-boundary-parent-9x\nmorg-prefix-only-9x\n## morg-chosen-9x\nmorg-inside-only-9x\n## morg-boundary-next-9x\nmorg-after-only-9x\n"

    :ok = Compos.Core.Buffer.insert(buf, text, source: :editor)
    {start, _} = :binary.match(text, "## morg-chosen-9x")
    {stop, _} = :binary.match(text, "## morg-boundary-next-9x")
    :ok = Compos.Core.Buffer.narrow(buf, start, stop)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "morg-chosen-9x"
    assert html =~ "morg-inside-only-9x"
    refute html =~ "morg-boundary-parent-9x"
    refute html =~ "morg-prefix-only-9x"
    refute html =~ "morg-boundary-next-9x"
    refute html =~ "morg-after-only-9x"
    refute html =~ ~s(class="f-fold-marker")
  end

  test "a terminal renders a direct PTY surface instead of transcript lines", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.set_local(buf, "render-mode", "terminal")
    Compos.Core.Buffer.insert(buf, "rails transcript stays readable", source: :process)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ ~s(phx-hook="Terminal")
    assert html =~ ~s(data-buffer="#{buf}")
    refute html =~ "rails transcript stays readable"
    assert Compos.Core.Buffer.text(buf) == "rails transcript stays readable"
  end

  test "an editor chord from a terminal completes through the minibuffer", %{conn: conn} do
    terminal = Compos.Core.Editor.current_buffer()
    target = "terminal-switch-target-#{System.unique_integer([:positive])}"
    Compos.Core.Buffer.set_local(terminal, "render-mode", "terminal")
    Compos.Core.create_buffer(target)

    on_exit(fn -> Compos.Core.kill_buffer(target) end)

    {:ok, view, _html} = live(conn, "/")
    html = keys(view, ["C-x", "b"])
    assert html =~ "mb-panel"

    html = type(view, target)
    assert html =~ target

    html = keys(view, ["RET"])
    refute html =~ "mb-panel"
    assert Compos.Core.Editor.current_buffer() == target
  end

  # Any click in a preview iframe moves focus into the iframe, and the blur
  # relay answers with a win-only mouse event — for a right click too. A
  # window selection is not a click on text, so it must keep the region.
  test "a win-only mouse event keeps the region, a text click clears it", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (switch-to-buffer! "#{buf}") (insert! "alpha beta") (set-mark! 2) (goto-char! 7))}
      )

    win = Compos.Core.Editor.render_state() |> Map.get(:tree) |> Map.get(:id)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("mouse", %{"win" => win})
    assert {:ok, "2"} = Compos.Core.Session.eval("(mark)")

    view |> element("#editor") |> render_hook("mouse", %{"win" => win, "line" => 0, "col" => 1})
    assert {:ok, cleared} = Compos.Core.Session.eval("(mark)")
    assert cleared in [false, "#f"]
  end

  # the client measures where the visual rows begin and sends the map;
  # the editor keeps it for Scheme and draws nothing for it
  test "a wrap map is kept for the window it names", %{conn: conn} do
    win = Compos.Core.Editor.render_state() |> Map.get(:tree) |> Map.get(:id)
    {:ok, view, html} = live(conn, "/")
    # the page names what the map measures: the buffer version and the
    # start byte of every line
    assert html =~ ~s(data-v=")
    assert html =~ ~s(data-s="0")

    view
    |> element("#editor")
    |> render_hook("wrap_map", %{"maps" => %{"#{win}" => %{"v" => 7, "r" => [0, 5, 10]}}})

    assert {:ok, "7"} = Compos.Core.Session.eval("(car (window-wrap-map #{win}))")
    assert {:ok, "(0 5 10)"} = Compos.Core.Session.eval("(cadr (window-wrap-map #{win}))")

    # a window nobody measured has no map
    assert {:ok, "#f"} = Compos.Core.Session.eval("(window-wrap-map 999999)")
  end

  test "a worktree buffer renders its persistent header and attention frame", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (buffer-set-local! "#{buf}" 'header-line "WORKTREE a1 · UNMERGED") (buffer-set-local! "#{buf}" 'window-class "workspace-pending"))}
      )

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "buffer-header"
    assert html =~ "WORKTREE a1 · UNMERGED"
    assert html =~ "workspace-pending"
  end

  test "a workspace daemon renders one frame-wide worktree bar", %{conn: conn} do
    old_root = Application.get_env(:compos_core, :workspace_root)
    old_name = Application.get_env(:compos_core, :name)
    old_project = Application.get_env(:compos_core, :workspace_project)
    old_workspace_name = Application.get_env(:compos_core, :workspace_name)
    Application.put_env(:compos_core, :workspace_root, "/tmp/compos-worktrees/a1")
    Application.put_env(:compos_core, :name, "worktree-a1")
    Application.put_env(:compos_core, :workspace_project, "compos")
    Application.put_env(:compos_core, :workspace_name, "workspace prompts")

    on_exit(fn ->
      if old_root,
        do: Application.put_env(:compos_core, :workspace_root, old_root),
        else: Application.delete_env(:compos_core, :workspace_root)

      if old_name,
        do: Application.put_env(:compos_core, :name, old_name),
        else: Application.delete_env(:compos_core, :name)

      if old_project,
        do: Application.put_env(:compos_core, :workspace_project, old_project),
        else: Application.delete_env(:compos_core, :workspace_project)

      if old_workspace_name,
        do: Application.put_env(:compos_core, :workspace_name, old_workspace_name),
        else: Application.delete_env(:compos_core, :workspace_name)
    end)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "workspace-bar"
    assert html =~ "WORKTREE"
    assert html =~ "compos / workspace prompts"
    assert html =~ "PORT 4046"
    assert html =~ "/tmp/compos-worktrees/a1"
  end

  test "a raw buffer publishes visual-line mode to the client", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    {:ok, _} =
      Compos.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'visual-line-mode #t)})

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
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.append(buf, "# Stable preview\n", source: :editor)
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'render-mode "markdown")})

    {:ok, view, _} = live(conn, "/")
    html = render(view)

    assert html =~ ~s(id="prev-)
    assert html =~ ~s(data-doc=")
    refute html =~ "srcdoc="

    [_, encoded] = Regex.run(~r/data-doc="([^"]+)"/, html)
    assert Base.decode64!(encoded) =~ "Stable preview"
  end

  test "TAB folds a Morg block in preview mode", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    text = "before\n\n```scheme\nsecret body\n```\n\nafter\n"
    Compos.Core.Buffer.append(buf, text, source: :editor)

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (set-mode! "morg-mode") (buffer-set-local! "#{buf}" 'preview-renderer "markdown") (enable-minor-mode! "#{buf}" "preview-mode"))}
      )

    :ok = Compos.Core.Buffer.goto(buf, :binary.match(text, "secret body") |> elem(0))
    {:ok, view, html} = live(conn, "/")
    [_, frame] = Regex.run(~r/data-frame="([^"]+)"/, html)

    decode = fn page ->
      [_, encoded] = Regex.run(~r/data-doc="([^"]+)"/, page)
      Base.decode64!(encoded)
    end

    assert decode.(html) =~ "secret body"

    keys(view, ["TAB"])
    assert Compos.Core.Buffer.hidden(buf) != []
    leaf = Compos.Core.Editor.render_state(frame).tree
    assert leaf.hidden_lines != MapSet.new()
    html = render(view)
    refute decode.(html) =~ "secret body"
    refute decode.(html) =~ "<pre data-src="
    assert decode.(html) =~ "after"

    keys(view, ["TAB"])
    assert Compos.Core.Buffer.hidden(buf) == []
    html = render(view)
    assert decode.(html) =~ "secret body"
  end

  test "an HTML preview click maps to source and the normal key path edits it", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.insert(buf, "<p>alpha beta</p>", source: :editor)
    Compos.Core.Buffer.set_local(buf, "render-mode", "html")

    {:ok, view, html} = live(conn, "/")
    [_, frame] = Regex.run(~r/data-frame="([^"]+)"/, html)
    win = Compos.Core.Editor.render_state(frame) |> Map.get(:tree) |> Map.get(:id)

    view
    |> element("#editor")
    |> render_hook("preview_goto", %{
      "win" => win,
      "before" => "alpha ",
      "after" => "beta",
      "wb" => "",
      "wa" => "beta",
      "nth" => 0,
      "wn" => 0,
      "dir" => 0
    })

    assert Compos.Core.Buffer.point(buf) == 9
    keys(view, ["X"])
    assert Compos.Core.Buffer.text(buf) == "<p>alpha Xbeta</p>"

    Compos.Core.Buffer.set_read_only(buf, true)
    keys(view, ["Y"])
    assert Compos.Core.Buffer.text(buf) == "<p>alpha Xbeta</p>"
    assert Compos.Core.Buffer.get_local(buf, "render-mode") == "html"
  end

  test "a Morg CSV source preview does not read its tangle file", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "compos-csv-preview-#{System.unique_integer([:positive])}")
    document = Path.join(dir, "notes.md")
    csv = Path.join(dir, "data.csv")
    File.mkdir_p!(dir)
    File.write!(document, "```csv :tangle data.csv\nstale_header,value\nstale_row,1\n```\n")
    File.write!(csv, "fresh_header,value\nfresh_row,2\n")
    {:ok, ^document} = Compos.Core.open_file(document)

    on_exit(fn ->
      Compos.Core.kill_buffer(document)
      File.rm_rf!(dir)
    end)

    Compos.Core.Editor.set_window_buffer(document)
    Compos.Core.Buffer.set_local(document, "render-mode", "markdown")
    Compos.Core.Buffer.set_local(document, "preview-engine", "earmark")

    {:ok, view, _} = live(conn, "/")
    [_, encoded] = Regex.run(~r/data-doc="([^"]+)"/, render(view))
    preview = Base.decode64!(encoded)

    assert preview =~ "stale_header"
    assert preview =~ "stale_row"
    refute preview =~ "fresh_header"
    refute preview =~ "fresh_row"
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
    assert html =~ "group-switch-buffer"
    keys(view, ["C-g"])
  end

  test "which-key renders ordered modifier groups with filter metadata", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin
        (local-set-key* "#{buf}" "<f9> z" "forward-char")
        (local-set-key* "#{buf}" "<f9> a" "backward-char")
        (local-set-key* "#{buf}" "<f9> C-z" "forward-char")
        (local-set-key* "#{buf}" "<f9> C-a" "backward-char")
        (local-set-key* "#{buf}" "<f9> M-a" "backward-char"))
      """)

    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["<f9>"])

    assert html =~ "Hold a modifier · / filters commands"
    assert html =~ ~s(data-modifiers="")
    assert html =~ ~s(data-modifiers="C")
    assert html =~ ~s(data-modifiers="M")
    assert html =~ ~s(data-command="forward-char")
    assert html =~ ~s(data-command="backward-char")
    assert html =~ ~s(class="wk-empty" hidden)
    assert html =~ ~r/class="wk-count" data-total="\d+"/

    {unmodified, _} = :binary.match(html, ">Unmodified<")
    {control, _} = :binary.match(html, ">Control<")
    {meta, _} = :binary.match(html, ">Meta<")
    {plain_a, _} = :binary.match(html, ">a</span>")
    {plain_z, _} = :binary.match(html, ">z</span>")
    {control_a, _} = :binary.match(html, ">C-a</span>")
    {control_z, _} = :binary.match(html, ">C-z</span>")

    assert unmodified < control and control < meta
    assert plain_a < plain_z and control_a < control_z
    keys(view, ["C-g"])
  end

  test "window splits render as a tree", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x", "3"])
    assert html =~ ~s(class="split h")
    html = keys(view, ["C-x", "1"])
    refute html =~ ~s(class="split h")
  end

  test "a side popup renders at the frame edge outside the work layout", %{conn: conn} do
    base = Compos.Core.Editor.current_buffer()
    other = "ui-popup-other-#{System.unique_integer([:positive])}"
    popup = "ui-popup-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(other)
    Compos.Core.create_buffer(popup)

    on_exit(fn ->
      Compos.Core.Editor.delete_other_windows()

      for name <- [other, popup] do
        if Compos.Core.Buffer.exists?(name), do: Compos.Core.kill_buffer(name)
      end
    end)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin
        (tile-windows! 'columns (list "#{base}" "#{other}"))
        (select-window! (window-showing "#{base}"))
        (display-buffer-popup! "#{popup}" 'right (/ 1 3)))
      """)

    assert {:ok, "#f"} =
             Compos.Core.Session.eval(~s{(if (member "#{popup}" (layout-visible-buffers)) #t #f)})

    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~r/class="window [^"]*popup popup-right"/
    assert html =~ "--popup-size:33.33333333333333%"
    assert html =~ ".split-child:has(> .window.popup)"
    assert html =~ ".window.popup-right { right: 0; }"
    assert html =~ "width: var(--popup-size, 33.333%);"
    assert html =~ ".window.popup-bottom { bottom: 0; }"
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
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.append(buf, "    —     — a command", source: {:agent, "test"})

    # the em dash occupies bytes 4..6; end the overlay on byte 5, inside it
    {:ok, _} =
      Compos.Core.Session.eval(~s{(overlay-set! "#{buf}" 'zz-utf8 (list (list 0 5 "region")))})

    html = render(view)
    assert html =~ "a command"
    assert String.valid?(html)
  end

  test "a select overlay paints every touched line as one full-width row",
       %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.append(buf, "subject\nauthor\nnext", source: {:agent, "test"})
    selected_end = byte_size("subject\nauthor\n")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(overlay-set! "#{buf}" 'zz-row (list (list 0 #{selected_end} "select")))}
      )

    {:ok, view, _} = live(conn, "/")
    html = render(view)

    assert length(Regex.scan(~r/class="line [^"]*selected-line[^"]*"/, html)) == 2
  end

  test "an avatar image keeps its layout class and clean source", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    url = "https://images.example/avatar.jpeg"

    Compos.Core.Buffer.append(
      buf,
      url <> "#compos-avatar Alice · Aug 3",
      source: {:agent, "test"}
    )

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(overlay-set! "#{buf}" 'zz-avatar (list (list 0 #{byte_size(url <> "#compos-avatar")} "img-embed")))}
      )

    # Point at byte zero used to split the image URL into a cursor-wrapped
    # "h" and visible "ttps://...", so the image component never ran.
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-goto! "#{buf}" 0)})

    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(<img src="#{url}" class="img-embed img-avatar")
    assert html =~ "align-items: flex-end"
    refute html =~ "#compos-avatar"
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
    {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
    assert render(view) =~ "gamma.txt"

    # the local a previous mode left behind must not empty the window
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-local! "#{root}" 'render-mode "blocks")})
    html = render(view)
    assert html =~ "gamma.txt"
    # the card view draws one div per window; the stylesheet names the
    # class too, so match the div's id rather than the class
    refute html =~ ~s(id="blocks-)
  end

  test "rpc/agent edits to a visible buffer appear live", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render(view)
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.append(buf, "pushed from outside", source: {:agent, "test"})
    # event-driven re-render
    assert render(view) =~ "pushed from outside"
  end

  test "a completed rich chat accepts the next input through the UI", %{conn: conn} do
    before = MapSet.new(Compos.Core.Agent.list())

    # the script rides a CONNECTOR, not one call's opts: the second turn
    # re-attaches, and a chat that only remembers a connector name would
    # come back on the default backend and hang
    {:ok, _} =
      Compos.Core.Session.eval("""
      (define-connector! "zz-ui-stub" '(backend "stub" script
        (((type tool-call id "tc1" title "Large completed edit" kind "other" status "pending")
          (type tool-update id "tc1" status "completed" text "#{String.duplicate("changed line", 2_000)}"))
         ((type chunk text "Accepted next input.")))))
      """)

    {:ok, _} = Compos.Core.Session.eval(~s{(execute* "first" '(connector "zz-ui-stub"))})

    [slug] = MapSet.difference(MapSet.new(Compos.Core.Agent.list()), before) |> MapSet.to_list()
    on_exit(fn -> Compos.Core.Agent.kill(slug) end)

    assert eventually(fn -> Compos.Core.Agent.info(slug).status == :idle end)
    buf = Compos.Core.Agent.info(slug).buffer

    {:ok, view, _} = live(conn, "/b/" <> URI.encode_www_form(buf))
    keys(view, String.graphemes("done?") ++ ["RET"])

    assert eventually(fn -> render(view) =~ "Accepted next input." end)
  end

  test "the activity row shows work in progress and clears at turn end", %{conn: conn} do
    before = MapSet.new(Compos.Core.Agent.list())

    {:ok, _} =
      Compos.Core.Session.eval("""
      (execute* "first" '(backend "stub" script (((type chunk text "done.")))))
      """)

    [slug] = MapSet.difference(MapSet.new(Compos.Core.Agent.list()), before) |> MapSet.to_list()
    on_exit(fn -> Compos.Core.Agent.kill(slug) end)

    assert eventually(fn -> Compos.Core.Agent.info(slug).status == :idle end)
    buf = Compos.Core.Agent.info(slug).buffer

    {:ok, view, _} = live(conn, "/b/" <> URI.encode_www_form(buf))
    refute render(view) =~ "ag-activity"

    # the real event path sets the activity word; a chunk mid-turn says so
    {:ok, _} =
      Compos.Core.Session.eval("(agent-handle-event \"#{slug}\" '(type chunk text \"more \"))")

    assert eventually(fn -> render(view) =~ "streaming" end)
    assert render(view) =~ "ag-activity"

    {:ok, _} =
      Compos.Core.Session.eval(
        "(agent-handle-event \"#{slug}\" '(type turn-end stop-reason \"end_turn\"))"
      )

    assert eventually(fn -> not (render(view) =~ "ag-activity") end)
  end

  # a minor mode is visible where it runs: the modeline names it, a click on
  # the name toggles it, and the echo area states the new state
  # the modeline names the major mode alone; the expanded modeline (C-x ?)
  # names the minor modes, and a click on one toggles it
  test "the expanded modeline names a minor mode and a click toggles it", %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()
    {:ok, _} = Compos.Core.Session.eval(~s{(run-command "visual-line-mode")})

    {:ok, _view, html} = live(conn, "/")
    refute html =~ "mode:visual-line-mode"

    {:ok, _} = Compos.Core.Session.eval(~s{(run-command "modeline-expand")})
    {:ok, view, html} = live(conn, "/")
    assert html =~ ~s(phx-value-cmd="mode:visual-line-mode")

    html =
      view |> element(~s(span[phx-value-cmd="mode:visual-line-mode"])) |> render_click()

    refute html =~ "mode:visual-line-mode"
    assert html =~ "visual-line-mode disabled"
    assert {:ok, off} = Compos.Core.Session.eval(~s{(minor-mode-on? "#{buf}" "visual-line-mode")})
    assert off in [false, "#f"]

    # the same toggle from a command reaches the running view too
    {:ok, _} = Compos.Core.Session.eval(~s{(run-command "visual-line-mode")})
    assert eventually(fn -> render(view) =~ "mode:visual-line-mode" end)
    {:ok, _} = Compos.Core.Session.eval(~s{(run-command "visual-line-mode")})
    {:ok, _} = Compos.Core.Session.eval(~s{(run-command "modeline-expand")})
  end

  # the major mode toggles from the modeline too: a view mode (a rendered
  # help page) leaves the buffer as plain text, and the next click restores it
  test "a click on the major mode name leaves it for Fundamental",
       %{conn: conn} do
    buf = Compos.Core.Editor.current_buffer()

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(with-current-buffer "#{buf}" (lambda () (begin (buffer-set-local! "#{buf}" 'render-mode "markdown") (set-mode! "html-mode") (run-command "modeline-expand"))))}
      )

    # the mode name is a control in the expanded modeline panel; the
    # compact modeline shows the name without offering the toggle
    {:ok, view, html} = live(conn, "/")
    assert html =~ ~s(phx-value-cmd="mode:html-mode")

    # the major mode is the panel's headline control, the minor modes are
    # chips beside it, so match the attribute rather than the tag
    html = view |> element(~s([phx-value-cmd="mode:html-mode"])) |> render_click()
    assert html =~ "html-mode off"
    # no mode at all: the modeline names that Fundamental
    assert html =~ ~s(phx-value-cmd="mode:Fundamental")
    assert {:ok, off} = Compos.Core.Session.eval(~s{(buffer-local "#{buf}" 'mode-name)})
    assert off in [false, "#f"]
    assert {:ok, render} = Compos.Core.Session.eval(~s{(buffer-local "#{buf}" 'render-mode)})
    assert render in [false, "#f"]
    # the grammar belongs to the mode: no mode, no highlighting
    assert {:ok, lang} = Compos.Core.Session.eval(~s{(buffer-local "#{buf}" 'ts-lang)})
    assert lang in [false, "#f"]

    # this buffer visits no file, so there is no mode to read back
    html = view |> element(~s([phx-value-cmd="mode:Fundamental"])) |> render_click()
    assert html =~ "no mode for this buffer"
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
