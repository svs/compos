defmodule Compos.Ui.EditorLive do
  @moduledoc """
  The window: renders the tiling window tree per line (numbers, hl-line,
  cursor/region spans), modelines, which-key, the vertico-style minibuffer and
  echo area; forwards every keystroke to `Compos.Core.KeyDispatch`.

  Pure view — no editor logic here. Re-renders on editor-state events and on
  change events of any visible buffer (so RPC/agent edits appear live).
  """

  use Phoenix.LiveView

  alias Compos.Core.{Events, Input}
  alias Compos.Scheme.Text
  alias Compos.Ui.{AppServer, LocalFile, LocalImage}

  # A normal space collapses inside an empty line, so it cannot give the
  # cursor a visible width. Keep the placeholder a non-breaking space.
  @cursor_placeholder "\u00a0"

  @impl true
  def mount(params, _session, socket) do
    identity = instance_identity()

    # each browser TAB is a frame (S5): the client sends its remembered
    # frame id (sessionStorage, per tab) in the connect params; unknown
    # ids are honored so the frame survives a wiped desktop.etf, absent
    # ids get a fresh frame. The id rides the payload as data-frame —
    # there is no separate frame event (S13).
    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Compos.Core.Editor.attach_frame(requested)
      Events.subscribe_frame(fid)

      # the frame is new to Elixir even when Scheme has known it all along
      # (a reattach after a restart): let Scheme push back whatever this
      # frame displays — the group it stands in, for one.
      Input.run(fid, fn -> Compos.Core.Session.call_named("frame-attached!", []) end)

      # a buffer link (/b/NAME?line=N) shows that buffer in this frame.
      # What "show" means — an open buffer, a file to visit, a line to go
      # to — is Scheme's open-buffer-link!, not this view's.
      if buffer = params["buffer"] do
        Input.run(fid, fn ->
          Compos.Core.Session.call_named("open-buffer-link!", [buffer, line_param(params)])
        end)
      end

      if params["daemon-switch"] == "1" do
        Input.run(fid, fn ->
          Compos.Core.Session.eval("(when (boundp 'daemon-arrived!) (daemon-arrived!))")
        end)
      end

      socket =
        assign(socket,
          frame: fid,
          subscribed: MapSet.new(),
          line_cache: %{},
          boot_id: :persistent_term.get(:compos_boot_id, "dev"),
          instance_name: identity.name,
          instance_accent: identity.accent
        )

      {:ok, refresh(socket)}
    else
      # no frame, no editor state: the static mount is a splash (S14)
      {:ok,
       assign(socket,
         frame: nil,
         state: nil,
         subscribed: MapSet.new(),
         line_cache: %{},
         boot_id: :persistent_term.get(:compos_boot_id, "dev"),
         instance_name: identity.name,
         instance_accent: identity.accent
       )}
    end
  end

  # drain before refresh: the dispatch above already broadcast its change
  # notifications to this process (Events sends before the GenServer replies),
  # so without the drain every keystroke rendered twice — once here, once in
  # handle_info
  @impl true
  def handle_event("key", %{"k" => spec}, socket) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  # an intent from the browser's text pipeline (beforeinput): what the user
  # meant, as an inputType, a byte range, and text. KeyDispatch decides
  # whether it is a key; Scheme decides what a range means.
  def handle_event("intent", %{"type" => type, "from" => from, "to" => to} = p, socket)
      when is_binary(type) and is_integer(from) and is_integer(to) do
    text = if is_binary(p["text"]), do: p["text"], else: ""

    Input.run(socket.assigns.frame, fn ->
      Compos.Core.KeyDispatch.handle_intent(type, from, to, text)
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # what the browser measured: round trips, patches, paints, long tasks.
  # The rows go to the collector and nothing renders: this is a report,
  # not an edit.
  def handle_event("telemetry", %{"rows" => rows}, socket) when is_list(rows) do
    Compos.Core.Telemetry.browser(rows, socket.assigns[:frame])
    {:noreply, socket}
  end

  # the native selection of an editable surface, as bytes: a click, a drag,
  # a double-click, or the answer to a select request. Point is the focus
  # end; the mark is the anchor when the selection is not collapsed.
  # A selection report is a caret motion in the selected window. A click
  # selects a window through "mouse" before its caret is reported, so a
  # report for any other window is stray: the browser's selection lives
  # in the last editable buffer, and a patch that nudges it - a popup
  # opening, a scroll beside it - reported a move nobody made, and the
  # server followed it there. Dropped.
  def handle_event("sel", %{"win" => win, "point" => point} = p, socket)
      when is_integer(point) and point >= 0 do
    with id when is_integer(id) <- safe_int(win),
         true <- id == Compos.Core.Editor.active_window(socket.assigns.frame) do
      Input.run(socket.assigns.frame, fn ->
        buf = Compos.Core.Editor.current_buffer()

        if Compos.Core.Buffer.exists?(buf) do
          mark = if is_integer(p["mark"]) and p["mark"] != point, do: p["mark"], else: nil
          # a keyboard motion keeps the mark (the region follows point, as
          # in Emacs); a click or a drag says what the mark is
          unless mark == nil and p["keep"] == true do
            Compos.Core.Buffer.set_mark(buf, mark)
          end

          Compos.Core.Buffer.goto(buf, point)

          # a client that reports its caret can be asked to move it: the
          # visual-line commands take the browser's layout from here on,
          # and a headless buffer keeps the server's own motion
          if Compos.Core.Buffer.get_local(buf, "client-caret") != true do
            Compos.Core.Buffer.set_local(buf, "client-caret", true)
          end
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # one handler for every click that runs a command: a transcript button
  # sends a command name, the modeline-info segment sends its buffer.
  # The Scheme gate ui-command! holds the whitelist — no policy here.
  def handle_event("ui_cmd", %{"win" => win} = params, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(id)

        Compos.Core.Session.call_named("ui-command!", [
          params["cmd"] || false,
          params["buf"] || false
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a tool card's summary: toggle its one open-state (S6) — the chat
  # local drives this view, the plain view's fold, and save/restore
  def handle_event("agent_card", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(wid)

        Compos.Core.Session.call_named("agent-card-toggle!", [
          Compos.Core.Editor.current_buffer(),
          id
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event(
        "agent_answer",
        %{"win" => win, "slug" => slug, "question" => question_id, "answer" => answer},
        socket
      ) do
    with {wid, ""} <- Integer.parse(to_string(win)),
         {qid, ""} <- Integer.parse(to_string(question_id)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(wid)
        Compos.Core.Session.call_named("agent-answer-question!", [slug, qid, answer])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the transcript follow flag and reader position (S7): runtime locals,
  # so a refresh keeps the reader's place and a restart resets to follow
  def handle_event("ag_stick", %{"buf" => buf, "stick" => stick, "top" => top}, socket)
      when is_boolean(stick) and is_integer(top) do
    if Compos.Core.Buffer.exists?(buf) do
      # inverted on purpose: the cleared (#f) local must mean "follow"
      Compos.Core.Buffer.set_local(buf, "agent-unstick", not stick)
      Compos.Core.Buffer.set_local(buf, "agent-scroll-top", top)
    end

    {:noreply, socket}
  end

  # clicking a block that carries a click id. The id is the mode's own
  # word; the view hands it back and knows nothing else. diff-mode
  # registered the handler with block-on-click!.
  def handle_event("block_click", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Editor.set_active(wid)
        Compos.Core.SchemeAPI.block_click(Compos.Core.Editor.current_buffer(), id)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a client-scrolled window reporting its pixel offset (S1) — a passive
  # mirror into the leaf, so refresh and restart give the place back
  def handle_event("cscroll", %{"win" => win, "top" => top}, socket) when is_integer(top) do
    with id when is_integer(id) <- safe_int(win) do
      Compos.Core.Editor.set_client_top(id, top, socket.assigns.frame)
    end

    {:noreply, socket}
  end

  # a client's JS failure, reported by the root hook: one line in *Messages*
  def handle_event("client_error", %{"m" => m}, socket) when is_binary(m) do
    Compos.Core.Session.call_named("message", ["browser: " <> String.slice(m, 0, 500)])
    {:noreply, socket}
  end

  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Compos.Core.Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window row counts: line height varies per buffer (per-buffer styles),
  # so the client measures each window against its own lines
  def handle_event("win_rows", %{"rows" => rows}, socket) when is_map(rows) do
    parsed =
      for {id, n} <- rows, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    Compos.Core.Editor.set_window_rows(parsed, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window column counts: the table views lay out in characters, so
  # the client measures its own font and says how many fit
  def handle_event("win_cols", %{"cols" => cols}, socket) when is_map(cols) do
    parsed =
      for {id, n} <- cols, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    if Compos.Core.Editor.set_window_cols(parsed, socket.assigns.frame) do
      # a window that changed width is a window configuration change: the
      # editor says so, and Scheme decides what has to be drawn again
      Compos.Core.Session.eval("(when (boundp 'window-config-changed!) (window-config-changed!))")

      {:noreply, socket |> drain() |> refresh()}
    else
      {:noreply, socket}
    end
  end

  # per-window wrap maps: where the client saw each visual row begin, as
  # source byte offsets, with the buffer version the page showed. Kept for
  # the next key; it draws nothing, so nothing is refreshed
  def handle_event("wrap_map", %{"maps" => maps}, socket) when is_map(maps) do
    parsed =
      for {id, %{"v" => v, "r" => rows}} <- maps,
          is_integer(v),
          is_list(rows),
          Enum.all?(rows, &is_integer/1),
          id_int = safe_int(id),
          is_integer(id_int),
          into: %{},
          do: {id_int, {v, rows}}

    Compos.Core.Editor.set_wrap_maps(parsed, socket.assigns.frame)
    {:noreply, socket}
  end

  # wheel scrolls the hovered window when the client identified one,
  # falling back to this frame's active window
  def handle_event("scroll", %{"lines" => lines} = params, socket) when is_integer(lines) do
    case safe_int(params["win"]) do
      win when is_integer(win) -> Compos.Core.Editor.scroll_window(win, lines)
      _ -> Compos.Core.Editor.scroll_active(lines, socket.assigns.frame)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # mouse click: select the window (policy in scheme — a chat snaps point to
  # its input region), then place point when the click hit a text line.
  # A win-only event is a window selection, not a click on text: the blur
  # relay sends one for ANY click in a preview iframe, right clicks
  # included, so it must keep the region.
  def handle_event("mouse", %{"win" => win} = params, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        case params do
          %{"line" => line, "col" => col} when is_integer(line) and is_integer(col) ->
            # A click and a visual-row move take this same path, and they
            # differ only in what becomes of the mark. Clearing it here
            # unconditionally made every move a click, so the visual-line
            # handler could not extend a selection at all and had to refuse
            # the key. Where the caret goes is geometry; whether the region
            # grows is the editor's business, so it rides as a parameter.
            #
            # Extending starts a region at point when there is none — the
            # same rule `preview-goto-src!` follows for the preview.
            mark =
              if params["extend"] == true,
                do: "(unless (mark) (set-mark! (point)))",
                else: "(set-mark! #f)"

            Compos.Core.Session.eval("(begin (mouse-select-window! #{id}) #{mark})")
            Compos.Core.Editor.mouse_goto(id, line, col)

          _ ->
            Compos.Core.Session.eval("(mouse-select-window! #{id})")
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # A click inside a rendered document can name a source fragment when the
  # renderer does not provide exact source offsets. HTML uses this path.
  def handle_event("preview_goto", %{"win" => win} = p, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        command = if p["extend"] == true, do: "preview-select!", else: "preview-goto!"

        Compos.Core.Session.call_named(command, [
          id,
          p["before"] || "",
          p["after"] || "",
          p["wb"] || "",
          p["wa"] || "",
          count_arg(p["nth"]),
          count_arg(p["wn"]),
          dir_arg(p["dir"])
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a click or a visual-line key inside a markdown preview's iframe: the
  # hook sends the text node split at the caret, how many times that text
  # comes before it on the page, and which way the key moves. Scheme finds
  # the spot in the source.
  # a click on a link in a rendered page. The frame never follows the link
  # itself: the href comes here and Scheme says what it means (a help page's
  # source link, a URL for the reader).
  def handle_event("preview_link", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("preview-follow-link!", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link_to_group", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("link-follow-to-group", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_goto_pos", %{"win" => win, "pos" => pos} = p, socket)
      when is_integer(pos) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("preview-goto-pos!", [id, pos, p["extend"] == true])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # drag: the native selection, mirrored into mark + point
  def handle_event(
        "mouse_sel",
        %{"win" => win, "al" => al, "ac" => ac, "fl" => fl, "fc" => fc},
        socket
      )
      when is_integer(al) and is_integer(ac) and is_integer(fl) and is_integer(fc) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.eval("(mouse-select-window! #{id})")
        Compos.Core.Editor.mouse_region(id, al, ac, fl, fc)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # system clipboard: Cmd-V arrives as a browser paste event
  def handle_event("paste", %{"text" => text}, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.eval("(clipboard-paste! #{scheme_string(text)})")
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # Browsers expose pasted files as clipboard items. Keep the bytes base64
  # encoded across the LiveView event; Scheme chooses the destination and
  # inserts the document markup.
  def handle_event("paste_image", %{"data" => data, "mime" => mime}, socket)
      when is_binary(data) and is_binary(mime) do
    result =
      Input.run(socket.assigns.frame, fn ->
        Compos.Core.Session.call_named("clipboard-image-paste!", [data, mime])
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("image paste failed: #{inspect(reason)}")
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # Cmd-C with no native selection: reply with the region (or kill top)
  # for the client to put on the OS clipboard — what "copy" MEANS is
  # Scheme's (clipboard-copy), like paste (S12, dup #26)
  def handle_event("copy", _params, socket) do
    text =
      Input.run(socket.assigns.frame, fn ->
        case Compos.Core.Session.call_named("clipboard-copy", []) do
          {:ok, text} when is_binary(text) -> text
          _ -> ""
        end
      end)

    {:noreply,
     socket
     |> push_event("clipboard", %{text: text})
     |> drain()
     |> refresh()}
  end

  defp scheme_string(text) do
    escaped =
      text
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    ~s{"#{escaped}"}
  end

  @impl true
  def handle_info({:frame_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}

  # coalesce bursts: drain all queued change notifications, render once
  defp drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  # timed as two halves: the editor state read (a call into the Editor
  # server, which waits when a command holds it) and the decoration of
  # the window tree (this process's own work)
  defp refresh(socket) do
    t0 = System.monotonic_time(:millisecond)
    {socket, state_ms} = refresh_state(socket)
    total = System.monotonic_time(:millisecond) - t0

    :telemetry.execute(
      [:compos, :ui, :refresh],
      %{duration: total, state: state_ms, decorate: total - state_ms},
      %{frame: socket.assigns[:frame]}
    )

    socket
  end

  defp refresh_state(socket) do
    fid = socket.assigns[:frame]
    t0 = System.monotonic_time(:millisecond)
    state = Compos.Core.Editor.render_state(fid)

    # our frame was deleted out from under us (M-x delete-frame elsewhere,
    # RPC): render_state fell back to another frame — recreate ours fresh
    # under the same id so the client's stored id stays good
    state =
      if fid && state.frame != fid do
        {:ok, ^fid} = Compos.Core.Editor.attach_frame(fid)
        Compos.Core.Editor.render_state(fid)
      else
        state
      end

    state_ms = System.monotonic_time(:millisecond) - t0

    {tree, line_cache} =
      decorate(state.tree, socket.assigns.line_cache, state.faces, state.active)

    state = %{state | tree: tree}

    # cache entries for windows that left the tree die with them (S15)
    ids = state.tree |> leaf_ids() |> MapSet.new()

    line_cache =
      Map.filter(line_cache, fn
        {{_kind, id}, _} -> MapSet.member?(ids, id)
        {id, _} -> MapSet.member?(ids, id)
      end)

    subscribed =
      if connected?(socket) do
        visible = state.tree |> event_buffers() |> MapSet.new()

        # a buffer that left the window set stops feeding this client (S15)
        socket.assigns.subscribed
        |> MapSet.difference(visible)
        |> Enum.each(&Events.unsubscribe/1)

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(&Events.subscribe/1)

        visible
      else
        socket.assigns.subscribed
      end

    socket = assign(socket, state: state, subscribed: subscribed, line_cache: line_cache)

    # a command left text for this client's OS clipboard (copy-buffer-link)
    socket =
      case fid && Compos.Core.Editor.take_clipboard(fid) do
        text when is_binary(text) -> push_event(socket, "clipboard", %{text: text})
        _ -> socket
      end

    socket =
      case fid && Compos.Core.Editor.take_navigation(fid) do
        url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
        _ -> socket
      end

    # a motion command asked the browser's layout to move the selection
    socket =
      case fid && Compos.Core.Editor.take_select(fid) do
        {alter, dir, gran} ->
          push_event(socket, "select", %{alter: alter, dir: dir, granularity: gran})

        _ ->
          socket
      end

    {socket, state_ms}
  end

  defp line_param(params) do
    case Integer.parse(to_string(params["line"] || "")) do
      {n, ""} when n > 0 -> n
      _ -> false
    end
  end

  defp leaf_ids(%{type: :leaf, id: id}), do: [id]
  defp leaf_ids(%{type: :split, children: children}), do: Enum.flat_map(children, &leaf_ids/1)
  defp leaf_ids(_), do: []

  defp frame_file_path(%{tree: tree, active: active}), do: active_file_path(tree, active)

  defp active_file_path(%{type: :leaf, id: id, path: path}, id)
       when is_binary(path) and path != "",
       do: path

  defp active_file_path(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &active_file_path(&1, id))

  defp active_file_path(_, _), do: nil

  # The raw PTY channel owns terminal painting. Its transcript still changes
  # as a normal buffer, but those changes must not refresh the LiveView tree.
  defp event_buffers(%{type: :leaf, render_mode: "terminal"}), do: []
  defp event_buffers(%{type: :leaf, buffer: buffer}), do: [buffer]

  defp event_buffers(%{type: :split, children: children}),
    do: Enum.flat_map(children, &event_buffers/1)

  defp event_buffers(_), do: []

  # two-level cache: the raw line split is keyed by buffer VERSION only, so
  # cursor motion never re-splits the buffer; span decoration (cursor/region/
  # hl-line) is recomputed per render but only for lines it actually touches
  defp decorate(%{type: :split} = split, cache, faces, active) do
    {children, cache} =
      Enum.map_reduce(split.children, cache, &decorate(&1, &2, faces, active))

    {%{split | children: children}, cache}
  end

  defp decorate(%{type: :leaf, render_mode: "terminal"} = leaf, cache, _faces, _active) do
    {Map.put(leaf, :lines, []), cache}
  end

  # preview buffers skip the line machinery entirely; the theme is baked into
  # the srcdoc (the sandboxed iframe can't see the parent's CSS vars).
  # markdown keys on point too: the preview is editable, so the reader must
  # see where the next keystroke lands. html does not — an authored
  # document gets no marker injected into it.
  defp decorate(%{type: :leaf, render_mode: rm} = leaf, cache, faces, _active)
       when rm in ["html", "markdown"] do
    pt = if rm == "markdown", do: leaf.point, else: 0
    mark = if rm == "markdown", do: leaf.mark, else: nil

    # the oembed generation moves when a tweet fetch lands, so the cached
    # placeholder misses and the card renders
    key =
      {leaf.buffer, leaf.version, rm, leaf.preview_authored, :erlang.phash2(faces), pt, mark,
       leaf.hidden_lines, :erlang.phash2(leaf.overlays), Compos.Ui.Oembed.generation(),
       preview_engine(leaf.buffer, rm),
       Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode"),
       csv_preview_file_key(leaf.buffer, leaf.text, rm)}

    {html, cache} =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> {html, cache}
        _ -> render_preview(preview_engine(leaf.buffer, rm), rm, leaf, pt, mark, faces, cache)
      end

    {Map.merge(leaf, %{lines: [], preview: html}),
     Map.put(cache, {:preview, leaf.id}, {key, html})}
  end

  # an app is not rendered here at all: the app origin serves it, and the
  # window holds only the frame that points at it
  defp decorate(%{type: :leaf, render_mode: "app"} = leaf, cache, _faces, _active) do
    {Map.merge(leaf, %{lines: [], app_url: AppServer.app_url(leaf.buffer, leaf.app_gen)}), cache}
  end

  # Scheme selects browser-file-mode. The view only signs its local path and
  # gives the browser an inert frame in which to use its native media viewer.
  defp decorate(%{type: :leaf, render_mode: "file", path: path} = leaf, cache, _faces, _active)
       when is_binary(path) do
    {Map.merge(leaf, %{lines: [], file_url: LocalFile.url(path)}), cache}
  end

  # rich agent transcript: blocks (from agent.scm's block model) become
  # typed DOM — serif prose, tool cards, permission buttons. The buffer
  # text stays canonical; this is a pure view over byte ranges.
  defp decorate(
         %{type: :leaf, render_mode: "agent", agent: %{} = ag} = leaf,
         cache,
         _faces,
         _active
       ) do
    # Input edits do not change the transcript mark or block model. Reuse the
    # complete block tree so typing and RET do not scan large tool results.
    old =
      case cache[{:agent, leaf.id}] do
        %{block_cache: block_cache} = entry -> {entry, block_cache}
        _ -> {%{}, %{}}
      end

    {old_entry, old_blocks} = old
    signature = {ag.blocks, ag.open_cards, ag.mark}

    {blocks, block_cache} =
      if old_entry[:signature] == signature do
        {old_entry.blocks, old_blocks}
      else
        {rendered, block_cache} =
          ag.blocks
          |> Enum.reverse()
          |> Enum.with_index()
          |> Enum.map_reduce(%{}, fn {b, i}, acc ->
            key = agent_block_cache_key(b, ag)

            view =
              case old_blocks[i] do
                {^key, view} -> view
                _ -> ag_block(b, leaf.text, ag.open_cards)
              end

            {view, Map.put(acc, i, {key, view})}
          end)

        {Enum.reject(rendered, &is_nil/1), block_cache}
      end

    entry = %{signature: signature, blocks: blocks, block_cache: block_cache}

    {Map.merge(leaf, %{
       lines: [],
       ag_blocks: blocks,
       ag_input: ag_input(leaf, ag),
       ag_activity: Map.get(ag, :activity),
       ag_queued: Map.get(ag, :queued) || []
     }), Map.put(cache, {:agent, leaf.id}, entry)}
  end

  # rich diff: the buffer text IS the unified diff, so the cards are parsed
  # out of the same bytes the plain view shows. Only the controlled state —
  # which cards are open, git's status letters — rides the payload.
  # a generic block tree the mode composed. This clause converts plists to
  # maps and finds the buffer line point is on; it does not know what any
  # block means.
  defp decorate(%{type: :leaf, render_mode: "blocks"} = leaf, cache, _faces, _active) do
    raw = Map.get(leaf, :blocks) || []
    key = {leaf.buffer, leaf.version, :erlang.phash2(raw)}

    blocks =
      case cache[{:blocks, leaf.id}] do
        {^key, blocks} -> blocks
        _ -> Enum.map(raw, &block_view/1)
      end

    line = Compos.Core.Text.line_index(leaf.text, leaf.point) + 1

    {Map.merge(leaf, %{lines: [], blk: blocks, blk_line: line}),
     Map.put(cache, {:blocks, leaf.id}, {key, blocks})}
  end

  # below this many lines, ship the whole buffer once and let the browser
  # own scroll position natively — build_static already computes every
  # line regardless of size, so this is purely a display decision, not
  # new server work. Above it, keep the windowed/virtualized path: DOM
  # node count and per-render diff cost both scale with what we ship.
  @ship_all_threshold 3000

  defp decorate(%{type: :leaf} = leaf, cache, _faces, active) do
    # the oembed generation moves when an X card lands: a line that drew
    # the pending URL must draw the card
    raw_key =
      {leaf.buffer, leaf.version, leaf.ts_lang, leaf.overlay_gen, Compos.Ui.Oembed.generation(),
       whitespace?(leaf)}

    static =
      case cache[leaf.id] do
        {^raw_key, static} -> static
        _ -> build_static(leaf)
      end

    # viewport: folded lines drop out, then (for large buffers) only the
    # visible slice (+overscan) becomes DOM. leaf.top is in visible-line
    # space.
    hidden = leaf.hidden_lines
    narrow_lines = Map.get(leaf, :narrow_lines)
    size = tuple_size(static)
    client_scroll? = size <= @ship_all_threshold
    # 3x overscan: leaf.rows is measured against WRAPPED line height (so
    # cursor-follow stays wrap-aware), but wrap factors vary per line —
    # under-slicing leaves blank space below. Excess DOM is cheap and
    # .buf{overflow:hidden} clips it. Only applies to the windowed path —
    # a client-scrolled buffer ships everything, no slice to overscan.
    want = leaf.rows * 3 + 8

    visible =
      cond do
        client_scroll? ->
          static
          |> Tuple.to_list()
          |> restrict_lines(narrow_lines)
          |> Enum.reject(&MapSet.member?(hidden, &1.num - 1))

        MapSet.size(hidden) == 0 ->
          # static is a tuple: elem/2 is O(1), so a deep scroll position
          # costs the same as line 1 — Enum.slice on a list re-walks from
          # element 0 every tick, so cost grows with leaf.top as you scroll
          {range_first, range_last} = narrow_lines || {0, size - 1}
          first = min(range_first + leaf.top, min(range_last + 1, size))
          last = min(first + want - 1, min(range_last, size - 1))
          if last < first, do: [], else: for(i <- first..last, do: elem(static, i))

        true ->
          # a fold can drop any line, so which raw index is the leaf.top-th
          # VISIBLE one can't be found without walking the folded sequence —
          # correctness over micro-perf here; folds are the uncommon case
          static
          |> Tuple.to_list()
          |> restrict_lines(narrow_lines)
          |> Enum.reject(&MapSet.member?(hidden, &1.num - 1))
          |> Enum.slice(leaf.top, want)
      end

    lines =
      visible
      |> render_pass(leaf.text, leaf.point, leaf.mark, leaf.id == active and not leaf.read_only)
      |> Enum.map(fn ln ->
        # a visible line whose successor is folded gets a fold marker
        if MapSet.member?(hidden, ln.num),
          do: %{ln | segs: ln.segs ++ [{" …", "f-fold-marker"}]},
          else: ln
      end)

    leaf = Map.put(leaf, :client_scroll?, client_scroll?)
    {Map.put(leaf, :lines, lines), Map.put(cache, leaf.id, {raw_key, static})}
  end

  defp csv_preview_file_key(_buffer, _text, rm) when rm != "markdown", do: nil

  defp csv_preview_file_key(buffer, text, "markdown") do
    Regex.scan(~r/^[ \t]*```[ \t]*csv[^\r\n]*:tangle[ \t]+([^ \t\r\n]+)/im, text,
      capture: :all_but_first
    )
    |> Enum.map(fn [target] ->
      path = csv_preview_path(buffer, target)

      case File.stat(path) do
        {:ok, stat} -> {path, stat.size, stat.mtime}
        _ -> {path, nil}
      end
    end)
  end

  defp restrict_lines(lines, nil), do: lines

  defp restrict_lines(lines, {first, last}),
    do: Enum.filter(lines, &(&1.num - 1 >= first and &1.num - 1 <= last))

  defp block_open?([_s, _e, "tool", id | _], open_cards), do: id in open_cards
  defp block_open?(_, _), do: false

  # A completed block is immutable in the rich chat model. Its range and
  # metadata identify its rendered value. A running tool can add body text
  # before its range closes, so the transcript mark also keys that block.
  defp agent_block_cache_key([_s, _e, "tool", _id, _title, _kind, "running" | _] = block, ag),
    do: {block, block_open?(block, ag.open_cards), ag.mark}

  defp agent_block_cache_key(block, ag),
    do: {block, block_open?(block, ag.open_cards)}

  # static per-version work: line split + font-lock spans + ts-only segs.
  # Overlapping captures resolve last-wins (tree-sitter highlight semantics).
  # Spans come from the buffer's incremental parser (cached per version,
  # shared across clients); a racing edit between snapshot and highlight can
  # skew one frame, which the edit's own broadcast then re-renders.
  defp build_static(leaf) do
    spans =
      case leaf.ts_lang do
        # nil: no mode ever named a grammar. false: a mode left and took it.
        lang when lang in [nil, false] ->
          []

        _lang ->
          leaf.buffer
          |> Compos.Core.Buffer.ts_highlight()
          |> Enum.with_index()
          |> Enum.map(fn {{s, e, scope}, i} -> {s, e, "ts-" <> scope, i} end)
      end

    ovs = Enum.map(leaf.overlays, fn {s, e, face} -> {s, e, "f-" <> face} end)

    # whitespace-mode: a run of spaces and each tab wear a face the page
    # marks; the newline mark is CSS on the row (see data-ws). The text
    # keeps its own bytes.
    ovs =
      if whitespace?(leaf) do
        ws =
          Regex.scan(~r/ +|\t/, leaf.text, return: :index)
          |> Enum.map(fn [{s, len}] ->
            face = if binary_part(leaf.text, s, 1) == "\t", do: "f-ws-tab", else: "f-ws-space"
            {s, s + len, face}
          end)

        ovs ++ ws
      else
        ovs
      end

    # a tuple, not a list: decorate/3 slices this by scroll position on
    # every render, and elem/2 is O(1) where Enum.slice on a list is
    # O(top) — this is the buffer's full line count, walked once here,
    # cached by {buffer, version, ts_lang, overlay_gen} until the next edit
    lines =
      leaf.text
      |> String.split("\n")
      |> Enum.map_reduce(0, fn part, start -> {{part, start}, start + byte_size(part) + 1} end)
      |> elem(0)
      |> Enum.with_index(1)

    ts_per_line = stab(spans, lines, fn {s, _, _, _} -> s end, fn {_, e, _, _} -> e end)
    ov_per_line = stab(ovs, lines, fn {s, _, _} -> s end, fn {_, e, _} -> e end)

    [lines, ts_per_line, ov_per_line]
    |> Enum.zip_with(fn [{{part, start}, num}, line_ts, line_ov] ->
      %{
        part: part,
        start: start,
        num: num,
        ts: line_ts,
        ov: line_ov,
        selected: Enum.any?(line_ov, fn {_, _, face} -> face == "f-select" end),
        # a row face (f-row-*) covering the line's start shapes the row:
        # a list item, a quote, a rule, a code line
        row: row_class(line_ov, start),
        segs: line_segs(part, start, line_ts, line_ov)
      }
    end)
    |> List.to_tuple()
  end

  # Emacs stops font-locking a line once the work outgrows the reading, and
  # so do we. seg_build compares every range against every cut, so a line
  # carrying thousands of ranges costs the square of them. One 3.8 MB line
  # of minified JSON pinned a LiveView on a core for good: the window never
  # painted, the process mailbox filled, and the editor read as frozen in
  # the browser while the daemon burned nine cores. Past these bounds the
  # line renders as plain text.
  @max_styled_line 20_000
  @max_line_ranges 400

  defp row_class(line_ov, start) do
    line_ov
    |> Enum.filter(fn {s, _e, cls} ->
      is_binary(cls) and s <= start and String.starts_with?(cls, "f-row-")
    end)
    |> Enum.map_join(" ", fn {_, _, cls} -> String.replace_prefix(cls, "f-", "") end)
  end

  defp whitespace?(leaf),
    do: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true

  defp line_segs(part, start, line_ts, line_ov) do
    if byte_size(part) > @max_styled_line or
         length(line_ts) + length(line_ov) > @max_line_ranges do
      [{part, ""}]
    else
      seg_build(part, start, line_ts, line_ov)
    end
  end

  # The ranges that touch each line, in one walk. Both the ranges and the
  # lines are in increasing start order, so a range enters when a line
  # reaches it and leaves when a line starts after it ends. Filtering the
  # whole range list per line was O(lines × ranges): a 5000-line file with
  # 20000 spans spent 100 million comparisons on every version.
  defp stab(items, lines, s_at, e_at) do
    sorted = Enum.sort_by(items, s_at)

    {per_line, _} =
      Enum.map_reduce(lines, {sorted, []}, fn {{part, start}, _num}, {pending, active} ->
        le = start + byte_size(part)
        {reached, pending} = Enum.split_while(pending, fn it -> s_at.(it) < le end)
        active = Enum.filter(active ++ reached, fn it -> e_at.(it) > start end)
        {active, {pending, active}}
      end)

    per_line
  end

  defp safe_int(v) when is_integer(v), do: v

  defp safe_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # a client that cannot name its window sends null: no window, no crash
  defp safe_int(_), do: nil

  defp count_arg(n) when is_integer(n) and n >= 0, do: n
  defp count_arg(_), do: 0
  defp dir_arg(d) when d in [-1, 0, 1], do: d
  defp dir_arg(_), do: 0

  # --- rendering -------------------------------------------------------------

  defp which_key_groups(bindings) do
    bindings
    |> Enum.chunk_by(& &1.modifiers)
    |> Enum.map(fn group ->
      first = hd(group)
      {first.modifier_label, first.modifiers, group}
    end)
  end

  @impl true
  # the disconnected mount is not a client: it attaches no frame and
  # renders a neutral splash — the connected mount replaces it (S14)
  def render(%{state: nil} = assigns) do
    ~H"""
    <div
      id="editor"
      class={instance_class("editor-root splash", @instance_accent)}
      style={instance_style(@instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-instance={@instance_name}
    >
      <div style="display:flex;align-items:center;justify-content:center;height:100vh;opacity:.5;font-family:monospace">
        compos — connecting…
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      id="editor"
      class={instance_class("editor-root", @instance_accent)}
      style={root_style(@state, @instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-frame={@frame}
      data-instance={@instance_name}
    >
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(face_css(@state.faces)) %></style>
    <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>
      <div :if={@state.workspace} class="workspace-bar">
        <span class="workspace-bar-kind">WORKTREE</span>
        <strong :if={@state.workspace.project && @state.workspace.name}>
          {@state.workspace.project} / {@state.workspace.name}
        </strong>
        <strong :if={!(@state.workspace.project && @state.workspace.name)}>
          {@state.workspace.daemon}
        </strong>
        <span class="workspace-bar-port">PORT {workspace_port(@state.workspace.url)}</span>
        <span class="workspace-bar-root">{@state.workspace.root}</span>
        <span class="workspace-bar-help">C-x w new tab · C-x d switch daemon</span>
      </div>
      <.frame_modeline state={@state} />
      <div class="windows">
        <.tree node={@state.tree} active={@state.active} completion={@state.completion} />
      </div>
      <div :if={@state.which_key && @state.minibuffer == nil && @state.transient == nil} class="which-key">
        <div class="wk-title">
          <span>
            {Enum.join(@state.pending, " ")} —
            <span class="wk-count" data-total={length(@state.which_key)}>
              {length(@state.which_key)} bindings
            </span>
          </span>
          <span class="wk-filter" aria-live="polite">Hold a modifier · / filters commands</span>
        </div>
        <div class="wk-groups">
          <%= for {label, modifiers, bindings} <- which_key_groups(@state.which_key) do %>
            <section class="wk-group" data-modifiers={Enum.join(modifiers, " ")}>
              <h3 class="wk-group-title">{label}<span>{length(bindings)}</span></h3>
              <div class="wk-grid">
                <div :for={w <- bindings} class="wk-item" data-command={String.downcase(w.command)}>
                  <span class="wk-key">{w.key}</span>
                  <span class="wk-cmd">{w.command}</span>
                </div>
              </div>
            </section>
          <% end %>
          <div class="wk-empty" hidden>No matching commands</div>
        </div>
      </div>
      <%= if @state.minibuffer do %>
        <div class={"mb-panel #{if Map.get(@state.minibuffer, :style) == "palette", do: "palette"}"}>
          <div class="mb-label-row">
            {label_row(@state.minibuffer)}
          </div>
          <div class="mb-body">
            <div class="mb-cands" style={"--mb-label-w: #{@state.minibuffer.label_width}ch"}>
              <%= for c <- @state.minibuffer.candidates do %>
                <%= if Map.get(c, :kind) == "separator" do %>
                  <div class="mb-sep"><span class="mb-sep-label">{c.label}</span></div>
                <% else %>
                  <%= if Map.get(c, :kind) == "container" do %>
                  <div class={"mb-container #{if c.selected, do: "selected"}"}>
                    <div class="mb-container-head">
                      <span class="mb-container-dot"></span>
                      <span class="mb-container-name">{c.label}</span>
                      <span class="mb-container-action">switch to group</span>
                      <span class="mb-container-meta">{c.hint}</span>
                    </div>
                    <div :if={Map.get(c, :chips, []) != []} class="mb-chips">
                      <span class="mb-chips-key">buffers</span>
                      <span :for={w <- Map.get(c, :chips, [])} class="mb-chip">{w}</span>
                    </div>
                  </div>
                <% else %>
                  <div class={"mb-cand #{if c.selected, do: "selected"}"}>
                    <span class={"mb-label #{candidate_face_class(c)}"}>{c.label}</span>
                    <span class="mb-hint">{c.hint}</span>
                  </div>
                  <% end %>
                <% end %>
              <% end %>
            </div>
            <div
              :if={Map.get(@state.minibuffer, :style) == "palette" && mb_preview(@state.minibuffer)}
              class="mb-preview"
            >
              <%= with p <- mb_preview(@state.minibuffer) do %>
                <div class="mb-preview-title">{p.title}</div>
                <div :for={{k, v} <- p.facts} class="mb-preview-fact">
                  <span class="mb-preview-k">{k}</span>
                  <span class="mb-preview-v">{v}</span>
                </div>
                <div class="mb-preview-note">{p.note}</div>
              <% end %>
            </div>
          </div>
          <div class={"mb-input-row #{if Map.get(@state.minibuffer, :prompt_sel), do: "selected"}"}>
            <span class="prompt">{@state.minibuffer.prompt}</span>
            <span class="mb-input"><%= with {pre, cur, post} <- mb_split(@state.minibuffer) do %>{pre}<span class="cursor">{cur}</span>{post}<% end %></span>
            <span class="mb-spacer"></span>
            <span :if={frame_file_path(@state)} class="ml-frame-path" title={frame_file_path(@state)}>{frame_file_path(@state)}</span>
            <span class="mb-count">{count_text(@state.minibuffer)}</span>
          </div>
        </div>
      <% else %>
        <%= if @state.transient && @state.transient[:groups] do %>
          <div class="mb-panel palette transient-panel">
            <div class="transient-title">{@state.transient.title}</div>
            <div class="transient-groups">
              <section :for={group <- @state.transient.groups} class="transient-group">
                <div class="transient-group-title">{group.title}</div>
                <div
                  :for={item <- group.items}
                  class={"transient-item #{if item.selected, do: "selected"} #{item.behavior}"}
                >
                  <span class="transient-key">{item.key}</span>
                  <span class="transient-description">{item.description}</span>
                  <span :if={item.value != ""} class="transient-value">{item.value}</span>
                </div>
              </section>
            </div>
            <div class="transient-help">RET invoke · C-g quit · C-q quit all · C-z suspend · ↑/↓ select · ? help</div>
          </div>
        <% else %>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp frame_modeline(assigns) do
    ~H"""
    <div
      :if={@state.minibuffer == nil || Map.get(@state.minibuffer, :style) == "palette"}
      class="echo-bar"
    >
      <span class="echo">{@state.echo}</span>
      <span :if={frame_file_path(@state)} class="ml-frame-path" title={frame_file_path(@state)}>{frame_file_path(@state)}</span>
      <span class="mb-spacer"></span>
      <span :if={@state.minibuffer == nil && @state.transient == nil && @state.frame_group} class="ml-frame-group">group {@state.frame_group}</span>
      <span :if={@state.minibuffer == nil && @state.transient == nil && @state.modeline_extra != ""} class="ml-extra">{@state.modeline_extra}</span>
      <span class="echo-hint" :if={@state.minibuffer == nil && @state.transient == nil && @state.echo == ""}>C-x C-f · C-x b · C-x d · C-c a n agent · M-x · C-g</span>
    </div>
    """
  end

  defp workspace_port(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> "?"
    end
  end

  defp frame_group_style(%{frame_group_color: color}) when is_binary(color) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color), do: "--frame-group-color: #{color}", else: nil
  end

  defp frame_group_style(_state), do: nil

  defp instance_identity do
    %{
      name: Application.get_env(:compos_core, :name, "compos"),
      accent: valid_accent(Application.get_env(:compos_core, :accent))
    }
  end

  defp valid_accent(color) when is_binary(color) do
    if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color), do: color, else: nil
  end

  defp valid_accent(_color), do: nil

  defp instance_style(nil), do: nil
  defp instance_style(color), do: "--instance-accent: #{color}"

  defp instance_class(base, nil), do: base
  defp instance_class(base, _color), do: base <> " instance-identified"

  defp root_style(state, accent) do
    [frame_group_style(state), instance_style(accent)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp window_style(node) do
    color = Map.get(node, :group_color)

    group_style =
      if is_binary(color) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color),
        do: "--buffer-group-color: #{color}",
        else: nil

    [Map.get(node, :window_style), group_style]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("; ")
  end

  defp candidate_face_class(%{face: face}) when is_binary(face) do
    if Regex.match?(~r/^[a-zA-Z0-9_-]+$/, face), do: "f-#{face}", else: ""
  end

  defp candidate_face_class(_candidate), do: ""

  # cursor sits at the minibuffer's point (it's a real buffer): split the
  # input into before-point, the grapheme under the cursor, and the rest
  defp mb_split(%{input: input, point: point}) do
    point = point |> min(byte_size(input)) |> max(0)
    rest = binary_part(input, point, byte_size(input) - point)

    case String.next_grapheme(rest) do
      nil -> {binary_part(input, 0, point), " ", ""}
      {g, post} -> {binary_part(input, 0, point), g, post}
    end
  end

  defp mb_split(mb), do: {mb.input, " ", ""}

  # A question is not a completion prompt. It takes one key, so it says
  # which keys answer it, and it counts nothing.
  defp label_row(%{style: "question"} = mb),
    do: "#{String.trim_trailing(mb.prompt, " ")} · y answers yes · n answers no · C-g quits"

  # a filter narrows the list behind it; the list itself shows the count,
  # so the prompt says what the keys do and nothing more
  defp label_row(%{style: "filter"} = mb),
    do:
      "#{String.trim_trailing(mb.prompt, ": ")} · type to narrow · DEL widens · " <>
        "empty removes it · RET keeps it · C-g drops it"

  defp label_row(mb),
    do:
      "#{String.trim_trailing(mb.prompt, ": ")} · TAB completes · RET accepts · " <>
        "C-n/C-p selects · C-c C-o collects · C-g quits"

  defp count_text(%{style: "question"}), do: ""
  defp count_text(%{style: "filter"}), do: ""

  defp count_text(%{total: total, sel: sel, completing: completing} = mb) do
    cond do
      # the prompt holds the selection: RET opens this directory
      total > 0 and Map.get(mb, :prompt_sel) -> "#{total} · RET opens dir"
      total > 0 -> "#{sel + 1}/#{total}"
      completing -> "TAB completes"
      true -> "no match"
    end
  end

  # the palette's right-hand panel: facts about the highlighted row,
  # read from the candidate's own columns — no extra state
  defp mb_preview(mb) do
    case Enum.find(mb.candidates, &Map.get(&1, :selected)) do
      nil ->
        nil

      %{kind: "container"} = c ->
        chips = Map.get(c, :chips, [])

        %{
          title: c.label,
          facts:
            [{"kind", "group"}, {"holds", c.hint |> String.split("·") |> hd() |> String.trim()}] ++
              if(chips == [], do: [], else: [{"members", Enum.join(chips, " · ")}]),
          note: "RET restores this group's layout exactly as you left it."
        }

      c ->
        fields = String.split(c.hint, ~r/\s{2,}/, trim: true)
        {paths, kinds} = Enum.split_with(fields, &String.starts_with?(&1, "/"))

        title =
          if String.starts_with?(c.label, "*"), do: c.label, else: Path.basename(c.label)

        %{
          title: title,
          facts:
            [{"mode", List.first(kinds) || "Fundamental"}] ++
              case Enum.drop(kinds, 1) do
                [] -> []
                rest -> [{"context", Enum.join(rest, " · ")}]
              end ++
              case paths do
                [] -> []
                [p | _] -> [{"path", p}]
              end,
          note: "RET switches; a buffer from another group brings that layout with it."
        }
    end
  end

  defp tree(%{node: %{type: :split}} = assigns) do
    assigns = assign(assigns, ratio: Map.get(assigns.node, :ratio, 0.5))

    ~H"""
    <div class={"split #{@node.dir}"}>
      <div class="split-child" style={"flex: #{@ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 0)} active={@active} completion={@completion} />
      </div>
      <div class="split-child" style={"flex: #{1.0 - @ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 1)} active={@active} completion={@completion} />
      </div>
    </div>
    """
  end

  # A window is a stateful component so that a window nobody touched
  # costs nothing: the component's assign skips a value equal to the one
  # it holds, and a component with no changed assign renders nothing and
  # ships a skip placeholder. Without this, one keystroke in one window
  # re-sent every line of every other window, because the parent handed
  # each window a new node map on every render. The component id is the
  # id of the window's own div.
  defp tree(%{node: %{type: :leaf}} = assigns) do
    ~H"""
    <.live_component
      module={Compos.Ui.Window}
      id={"win-#{@node.id}"}
      node={@node}
      active={@active}
      completion={@completion}
    />
    """
  end

  @doc """
  One window: its header, dashboard, body, and modeline.

  `Compos.Ui.Window` renders this. It stays here because the helpers it
  calls (`blk`, `seg`, the modeline pieces) live here.
  """
  def window(assigns) do
    assigns =
      assign(assigns,
        lines: assigns.node.lines,
        line: assigns.node.line,
        col: assigns.node.col,
        # the file the window shows, and whether it refuses typing. The
        # client renders neither yet; /raw previews and the modeline will.
        path: assigns.node.path,
        read_only: assigns.node.read_only,
        active?: assigns.node.id == assigns.active
      )

    ~H"""
    <div
      id={"win-#{@node.id}"}
      class={"window #{if @active?, do: "active", else: "inactive"} #{if @node.selected, do: "buffer-selected"} #{if !@node.line_numbers, do: "no-nums"} #{@node.window_class}"}
      style={window_style(@node)}
      data-win-id={@node.id}
      data-path={@path}
      data-read-only={to_string(@read_only)}
    >
      <div :if={@node.header_line} class="buffer-header">{@node.header_line}</div>
      <div :if={@node.dash || @node.dashboard_line_blocks} class="dash-top">
        <div
          :if={@node.dashboard_line_blocks}
          class="dash-persistent"
          title="open dashboard"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >
          <.blk :for={b <- @node.dashboard_line_blocks} b={block_view(b)} line={-1} win={@node.id} />
        </div>
        <div :if={@node.dash} class="dash-live">
          <span>L{@line}:C{@col}</span>
          <span>point {@node.point}</span>
          <span>{ml_bytes(@node.text)}</span>
          <span>{pct(@node)}</span>
          <span :if={@node.modified} class="dash-live-mod">modified</span>
        </div>
        <%= case @node.dash do %>
          <% [head | cards] -> %>
            <.blk b={block_view(head)} line={0} win={@node.id} />
            <div class="dash-grid">
              <div class="dash-cell">
                <div class="dash-title">modes</div>
                <div
                  class="dash-big dash-toggle"
                  title={"toggle #{@node.mode}"}
                  phx-click="ui_cmd"
                  phx-value-win={@node.id}
                  phx-value-cmd={"mode:" <> @node.mode}
                >{@node.mode}</div>
                <div :if={@node.minor_modes != []} class="dash-chips">
                  <span
                    :for={m <- @node.minor_modes}
                    class="dash-chip dash-chip-on"
                    title={"toggle #{m}"}
                    phx-click="ui_cmd"
                    phx-value-win={@node.id}
                    phx-value-cmd={"mode:" <> m}
                  >{m}</span>
                </div>
                <div class="dash-row">
                  <span class="dash-k">read-only</span><span class="dash-sp"></span><span class="dash-v">{if @node.read_only, do: "yes", else: "no"}</span>
                </div>
              </div>
              <.blk :for={b <- Enum.map(cards, &block_view/1)} b={b} line={0} win={@node.id} />
            </div>
          <% _ -> %>
        <% end %>
      </div>
      <%= if @node.render_mode == "terminal" do %>
        <div
          class="terminal-view"
          id={"terminal-#{@node.id}"}
          phx-hook="Terminal"
          phx-update="ignore"
          data-buffer={@node.buffer}
          data-win={@node.id}
        ></div>
      <% else %>
      <%= if @node.render_mode == "blocks" and Map.has_key?(@node, :blk) do %>
        <div class="blocks-view" id={"blocks-#{@node.id}"} phx-hook="BlockScroll">
          <div class="blocks-scroll">
            <.blk :for={b <- @node.blk} b={b} line={@node.blk_line} win={@node.id} />
          </div>
        </div>
      <% else %>
      <%= if @node.render_mode == "agent" and Map.has_key?(@node, :ag_blocks) do %>
        <div
          class="agent-view"
          id={"agent-#{@node.id}"}
          style={@node.style}
        >
          <%!-- the transcript is its own component so a keystroke in the
               input row diffs to a skip placeholder: the client must not
               walk one DOM node per block of the whole conversation per
               key. blocks comes from the decorate cache, so the list is
               reference-equal until the block model changes. --%>
          <.live_component
            module={Compos.Ui.AgentTranscript}
            id={"agtx-#{@node.id}"}
            blocks={@node.ag_blocks}
            win={@node.id}
            buf={@node.buffer}
            stick={@node.agent.stick}
            scroll_top={@node.agent.scroll_top}
          />
          <%!-- messages queued mid-turn: muted rows from 'chat-queued,
               not transcript text. Outside the component, so a streamed
               event never moves them and their churn never diffs the
               block list — excise + re-insert per event was the flicker.
               C-c C-d takes the newest one back into the input. --%>
          <div :for={q <- @node.ag_queued} class="ag-user ag-queued ag-queued-row">
            <span class="ag-label">YOU</span>
            <div class="ag-user-text">{q}</div>
          </div>
          <%!-- the turn pulse: the activity word agent.scm sets on every
               event, alive until turn-end clears it. The transcript alone
               cannot say working vs done once paragraphs stream. Outside
               the component and the scroll area, so it never moves and
               its churn never diffs the block list. "disconnected" is a
               dead chat, not motion — the [agent exited] line says it. --%>
          <div
            :if={@node.ag_activity && @node.ag_activity != "disconnected"}
            class="ag-wait ag-activity"
          >⋯ {@node.ag_activity}</div>
          <div class="ag-inputrow">
            <span class="ag-label">YOU</span>
            <span class="ag-input">{@node.ag_input.pre}<span
                :if={@node.ag_input.cur != ""}
                class="cursor"
              >{@node.ag_input.cur}</span>{@node.ag_input.post}</span>
            <span
              :if={@node.ag_input.pre == "" and @node.ag_input.post == ""}
              class="ag-hint"
            >RET sends · C-RET interrupts</span>
          </div>
        </div>
      <% else %>
      <%= if @node.render_mode == "file" and Map.has_key?(@node, :file_url) do %>
        <iframe
          class="file-preview"
          src={@node.file_url}
          sandbox=""
          title={@node.buffer}
        ></iframe>
      <% else %>
      <%= if @node.render_mode == "app" and Map.has_key?(@node, :app_url) do %>
        <%!-- An app runs its own scripts, so it must not share the editor's
             origin: it is served from 127.0.0.1:4005, and the parent is
             localhost:4004. allow-same-origin here grants the app its OWN
             origin, which buys it storage and relative URLs; the browser
             still refuses it every reach into this page. src, not srcdoc,
             for the same reason — a srcdoc document inherits us. --%>
        <iframe
          class="app-preview"
          id={"app-#{@node.id}-#{:erlang.phash2(@node.app_url)}"}
          phx-hook="AppFrame"
          data-win={@node.id}
          data-ctop={@node.ctop}
          sandbox="allow-scripts allow-same-origin allow-forms allow-modals allow-popups"
          src={@node.app_url}
          title={@node.buffer}
        >
        </iframe>
      <% else %>
      <%= if @node.render_mode in ["html", "markdown"] do %>
        <%!-- allow-same-origin, and nothing else. The parent must reach
             the frame's document to scroll it from a key; without it the
             page only answers the mouse. No allow-scripts, so the
             previewed document still runs nothing. --%>
        <iframe
          class="html-preview"
          id={"prev-#{@node.id}"}
          phx-hook="PreviewScroll"
          style={@node.style}
          data-win={@node.id}
          data-ctop={@node.ctop}
          data-pt={@node.point}
          data-rm={@node.render_mode}
          data-visual-lines={to_string(@node.visual_line_mode)}
          data-v={@node.version}
          data-doc={Base.encode64(@node.preview)}
          sandbox="allow-same-origin"
          title={@node.buffer}
        ></iframe>
      <% else %>
      <div
        class={"buf #{if @node.client_scroll?, do: "client-scroll"}"}
        style={@node.style}
        data-ctop={@node.ctop}
        data-manual={to_string(@node.manual)}
        data-visual-lines={to_string(@node.visual_line_mode)}
        data-ws={to_string(whitespace?(@node))}
        data-v={@node.version}
        data-pt={@node.point}
        data-mark={@node.mark}
        contenteditable={if @node.read_only, do: nil, else: "true"}
        spellcheck="true"
        autocorrect="off"
        autocapitalize="off"
      >
        <div
          :for={ln <- @lines}
          id={"ln-#{@node.id}-#{ln.num}"}
          class={"line #{ln.row} #{if ln.current, do: "hl-line"} #{if ln.selected, do: "selected-line"}"}
          data-s={ln.start}
        >
          <span class="linenum" contenteditable="false">{ln.num}</span>
          <span class="line-content"><.seg :for={{txt, cls} <- ln.segs} txt={txt} cls={cls} base={@node.buffer} /><br
              :if={ln.segs == []}
              class="empty-row"
            /><span
              :if={@active? && @completion && ln.current}
              class="cap-pop"
              contenteditable="false"
              style={"left: #{pop_col(@node.text, ln.start, @completion.start)}ch"}
            ><span class="cap-title">completion-at-point · {@completion.total}</span><span
              :for={c <- @completion.candidates}
              class={"cap-row #{if c.selected, do: "selected"}"}
            ><span class="cap-label">{c.label}</span><span class="cap-kind">{c.hint}</span></span></span></span>
        </div>
      </div>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <div :if={@node.footer_line} class="buffer-footer">{@node.footer_line}</div>
      <div class="modeline">
        <span
          class="ml-caret"
          title="expand (C-x ?)"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >{if @node.dash, do: "▾", else: "▸"}</span>
        <span class={"ml-dot #{if @node.modified, do: "modified"}"}></span>
        <span
          class="name"
          style="cursor:pointer"
          title={@node.buffer}
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >{ml_name(@node)}</span>
        <span :if={@node.modeline_project && @node.modeline_project != ""} class="ml-mode">
          · {@node.modeline_project}
        </span>
        <span :if={@node.group} class="ml-group">· {@node.group}</span>
        <span :if={@node.selected} class="ml-mode ml-selected">● selected</span>
        <span :if={@node.render_mode in ["html", "markdown"]} class="ml-mode">preview</span>
        <span
          :if={@node.modeline_info}
          class="ml-mode"
          style="cursor:pointer"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-buf={@node.buffer}
        >{@node.modeline_info}</span>
        <span class="mb-spacer"></span>
        <span class="ml-pos">
          <%= if @node.render_mode == "terminal" do %>
            <span class="ml-icon">▣</span> PTY · transcript {ml_bytes(@node.text)}
          <% else %>
            <span class="ml-icon">≡</span> {ml_bytes(@node.text)} · <span class="ml-icon">⌖</span> L{@line}:C{@col} · {pct(@node)}
          <% end %>
        </span>
      </div>
    </div>
    """
  end

  # --- per-line display list: numbers, hl-line, font-lock + overlays ----------

  # The focused editable surface draws no cursor and no region of its own.
  # The browser owns the caret and selection there. An inactive editable
  # surface draws the server marker, so its window still shows point.
  defp render_pass(static, text, point, mark, native_caret?) do
    {rs, re} =
      case mark do
        nil -> {point, point}
        m -> {min(m, point), max(m, point)}
      end

    len = byte_size(text)

    cursor_end =
      case String.next_grapheme(binary_part(text, point, len - point)) do
        nil -> point
        {g, _} -> point + byte_size(g)
      end

    Enum.map(static, fn line ->
      le = line.start + byte_size(line.part)
      # The native-caret surface marks its current row in the client.
      # Nothing in these lines depends on point, so caret motion sends no row.
      current = not native_caret? and point >= line.start and point <= le
      touched? = current or (rs != re and rs < le + 1 and re > line.start)

      segs =
        if touched? and not native_caret? do
          # Images are atomic display objects. Point may sit inside the URL
          # backing one, but the cursor must not split its scheme before the
          # image component sees it.
          image_at_point =
            Enum.find(line.ov, fn
              {s, e, cls} when is_binary(cls) ->
                cls =~ "img-embed" and point >= s and point < e

              _ ->
                false
            end)

          overlays =
            [
              if(rs != re, do: {rs, re, "region"}),
              if(point < cursor_end and is_nil(image_at_point),
                do: {point, cursor_end, "cursor"}
              )
            ]
            |> Enum.reject(&is_nil/1)

          # through line_segs, not seg_build: the cursor's own line takes the
          # same long-line guard as every other one, and on a one-line buffer
          # this is the only line there is
          segs = line_segs(line.part, line.start, line.ts, line.ov ++ overlays)

          segs =
            case image_at_point do
              {s, e, _} ->
                target = binary_part(text, s, e - s)

                {before, from_image} =
                  Enum.split_while(segs, fn
                    {^target, cls} when is_binary(cls) -> not (cls =~ "img-embed")
                    _ -> true
                  end)

                case from_image do
                  [image | after_image] when point == s ->
                    before ++ [{@cursor_placeholder, "cursor"}, image | after_image]

                  [image | after_image] ->
                    before ++ [image, {@cursor_placeholder, "cursor"} | after_image]

                  [] ->
                    segs
                end

              nil ->
                segs
            end

          # cursor sitting on this line's newline (or at EOF on the last line)
          if point >= line.start and point == le,
            do: segs ++ [{@cursor_placeholder, "cursor"}],
            else: segs
        else
          line.segs
        end

      %{
        num: line.num,
        current: current,
        selected: line.selected,
        start: line.start,
        row: Map.get(line, :row, ""),
        segs: segs
      }
    end)
  end

  # cut the line at every range boundary; each segment takes the last-wins
  # ts class plus any active overlay classes
  # a seg whose overlay face says img-embed IS an image: the buffer text
  # stays the URL (the buffer is truth), the client draws the picture
  # An island draws in the text's place and is one character to the caret
  # (contenteditable=false): an image, an X card, or a YouTube card.
  # data-len says how many source bytes it stands for, so the
  # client's byte mapping walks over it.
  attr(:txt, :string, required: true)
  attr(:cls, :string, required: true)
  attr(:base, :string, default: nil)

  defp seg(%{cls: cls, txt: txt} = assigns)
       when is_binary(cls) and is_binary(txt) do
    src = if cls =~ "img-embed", do: image_src(txt, assigns.base)

    cond do
      is_binary(src) ->
        avatar? = String.ends_with?(txt, "#compos-avatar")

        assigns =
          assign(assigns,
            src: src,
            len: byte_size(txt),
            image_class: if(avatar?, do: "img-embed img-avatar", else: "img-embed")
          )

        ~H|<img src={@src} class={@image_class} loading="lazy" contenteditable="false" data-len={@len} />|

      cls =~ "x-embed" ->
        assigns = assign(assigns, len: byte_size(txt), card: Compos.Ui.Oembed.card(txt))

        ~H"""
        <span class="x-card" contenteditable="false" data-len={@len}><%= case @card do %><% {:ok, html} -> %>{Phoenix.HTML.raw(html)}<% _ -> %><span class="x-pending">{@txt}</span><% end %></span>
        """

      cls =~ "youtube-embed" and youtube_id(txt) ->
        id = youtube_id(txt)

        assigns =
          assign(assigns,
            len: byte_size(txt),
            thumbnail: youtube_thumbnail(id)
          )

        ~H"""
        <a class="youtube-card youtube-island" href={@txt} target="_blank" rel="noopener noreferrer" contenteditable="false" data-len={@len} aria-label="Watch this video on YouTube"><img src={@thumbnail} alt="YouTube video thumbnail" loading="lazy" /><span class="youtube-play" aria-hidden="true">▶</span></a>
        """

      true ->
        ~H|<span class={@cls}>{@txt}</span>|
    end
  end

  # a URL draws as it is; a relative path resolves beside the buffer's
  # file and is served signed (LocalImage); a path with no file has no picture
  defp image_src(txt, base) do
    cond do
      String.starts_with?(txt, "http") ->
        String.trim_trailing(txt, "#compos-avatar")

      is_binary(base) and String.starts_with?(base, "/") ->
        LocalImage.url(Path.expand(txt, Path.dirname(base)))

      String.starts_with?(txt, "/") ->
        LocalImage.url(txt)

      true ->
        nil
    end
  end

  defp seg_build(part, ls, ts_ranges, overlays) do
    plen = byte_size(part)
    le = ls + plen
    rel = fn abs -> abs |> max(ls) |> min(le) |> Kernel.-(ls) end

    cuts =
      Enum.flat_map(ts_ranges, fn {s, e, _, _} -> [rel.(s), rel.(e)] end) ++
        Enum.flat_map(overlays, fn {s, e, _} -> [rel.(s), rel.(e)] end)

    # snap every cut down to a character boundary. A tree-sitter range or
    # an overlay can end inside a multi-byte character; the binary_part
    # below then builds a segment that is not valid UTF-8, and Jason kills
    # the LiveView socket when it encodes the reply. The window goes blank
    # and the client cannot reconnect. Snapping keeps the segments tiling
    # the line exactly, because floor_utf8 holds 0 and plen fixed.
    ([0, plen] ++ cuts)
    |> Enum.map(&Text.floor_utf8(part, &1))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      if b > a do
        a2 = ls + a
        b2 = ls + b

        ts_cls =
          ts_ranges
          |> Enum.filter(fn {s, e, _, _} -> s <= a2 and e >= b2 end)
          |> Enum.max_by(fn {_, _, _, i} -> i end, fn -> nil end)
          |> case do
            {_, _, cls, _} -> cls
            nil -> nil
          end

        ov_cls =
          overlays
          |> Enum.filter(fn {s, e, _} -> s <= a2 and e >= b2 end)
          |> Enum.map(fn {_, _, cls} -> cls end)

        cls = Enum.join(Enum.reject([ts_cls | ov_cls], &is_nil/1), " ")
        [{binary_part(part, a, b - a), cls}]
      else
        []
      end
    end)
  end

  # both previews follow the live theme; `(buffer-set-local! buf
  # 'preview-authored #t)` renders html exactly as authored instead
  # --- agent transcript blocks ------------------------------------------------

  # block offsets can go stale (they're laid down at insert time, and text
  # before them may be edited); a mid-codepoint slice is invalid UTF-8 and
  # kills the whole render (Earmark, HEEx).
  defp safe_slice(text, s, e), do: Text.slice(text, s, e)

  defp ag_block([s, e, "user" | meta], text, _open) do
    text_of =
      case meta do
        [msg | _] when is_binary(msg) -> msg
        _ -> text |> safe_slice(s, e) |> String.trim() |> String.replace_prefix(">>> you: ", "")
      end

    %{kind: :user, text: text_of}
  end

  # a message queued mid-turn: the user line, muted until the model reads it
  defp ag_block([s, e, "queued" | meta], text, _open) do
    text_of =
      case meta do
        [msg | _] when is_binary(msg) -> msg
        _ -> text |> safe_slice(s, e) |> String.trim() |> String.replace_prefix(">>> you: ", "")
      end

    %{kind: :queued, text: text_of}
  end

  defp ag_block([s, e, "prose" | _], text, _open) do
    md = safe_slice(text, s, e)

    # same raise as `earmark_ast/1`: one bad block must not kill the
    # transcript that holds it
    html =
      try do
        case Earmark.as_html(md, compact_output: false) do
          {:ok, html, _} -> html
          {:error, html, _} -> html
        end
      rescue
        _ -> "<pre>" <> html_escape(md) <> "</pre>"
      end

    %{kind: :prose, html: wrap_tables(html)}
  end

  defp ag_block([s, e, "thought" | _], text, _open),
    do: %{kind: :thought, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, e, "tool", id, title, kind, status, body_start | rest], text, open_cards) do
    raw_body = String.trim_trailing(safe_slice(text, body_start, e))
    body = tool_display_body(raw_body)

    # "name: arg" from agent-tool-title — the arg is the interesting part,
    # so the card styles it apart from the tool name
    {name, arg} =
      case String.split(title, ": ", parts: 2) do
        [n, a] -> {n, a}
        _ -> {title, ""}
      end

    %{
      kind: :tool,
      id: id,
      title: title,
      name: name,
      arg: arg,
      verb: kind,
      status: status,
      open: id in open_cards,
      body: body,
      preview: tool_preview(body),
      duration: tool_duration_label(List.first(rest)),
      # what the call added to the context: its arguments and its result
      tokens: token_estimate_label(byte_size(title) + byte_size(raw_body))
    }
  end

  defp ag_block([s, e, "plan" | _], text, _open),
    do: %{kind: :plan, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, _e, "permission", title | _], _text, _open),
    do: %{kind: :permission, title: title}

  defp ag_block([_s, _e, "question", id, slug, question, answers | _], _text, _open),
    do: %{kind: :question, id: id, slug: slug, question: question, answers: answers || []}

  # the waiting block anchors the "⋯ thinking" text for restore sweeps and
  # the plain view; the rich view shows the activity row instead — both at
  # once would pulse twice for one wait
  defp ag_block([_s, _e, "waiting" | _], _text, _open), do: nil

  defp ag_block([s, e, "meta" | _], text, _open),
    do: %{kind: :meta, text: String.trim(safe_slice(text, s, e))}

  defp ag_block(_, _, _), do: nil

  # "340ms", "1.4s", "2m 05s" — nil when the block predates the field
  defp tool_duration_label(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{String.pad_leading("#{rem(div(ms, 1000), 60)}", 2, "0")}s"
    end
  end

  defp tool_duration_label(_), do: nil

  # bytes/4 is the standard rough token estimate; no tokenizer ships here
  defp token_estimate_label(bytes) when bytes < 4, do: nil

  defp token_estimate_label(bytes) do
    tokens = div(bytes, 4)

    if tokens < 1000 do
      "~#{tokens} tok"
    else
      "~#{Float.round(tokens / 1000, 1)}k tok"
    end
  end

  # A folded call still says what it returned. New calls separate input and
  # output with a blank line. Older calls contain only their result.
  defp tool_preview(body) do
    candidate =
      case String.split(String.trim(body), ~r/\n\s*\n/, parts: 2) do
        [_input, output] when output != "" -> output
        [detail | _] -> detail
        _ -> ""
      end

    candidate
    |> tool_result_text()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 140)
  end

  # Keep the canonical transcript unchanged. The rich view unwraps only the
  # final MCP result envelope and leaves the tool input before it intact.
  defp tool_display_body(body) do
    parts = String.split(body, "\n\n")
    result = List.last(parts) || ""
    readable = tool_result_text(result)

    if readable == result do
      body
    else
      parts
      |> List.replace_at(-1, readable)
      |> Enum.join("\n\n")
    end
  end

  defp tool_result_text(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, %{"content" => content} = result} when is_list(content) ->
        case Enum.find_value(content, fn
               %{"text" => value} when is_binary(value) and value != "" -> value
               _ -> nil
             end) do
          nil -> Jason.encode!(result, pretty: true)
          value -> pretty_json(value)
        end

      {:ok, value} ->
        Jason.encode!(value, pretty: true)

      _ ->
        text
    end
  end

  defp pretty_json(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, value} -> Jason.encode!(value, pretty: true)
      _ -> text
    end
  end

  # The one renderer for block trees. Structure only: tags, classes, segs,
  # click ids and the point mark all come from the mode. The mark: a block
  # with a mark class and a line range gets that class while point's line is
  # inside the range — and, when it also has an anchor, a data-current
  # attribute the scroll hook follows.
  defp blk(%{b: %{tag: "pre"}} = assigns) do
    ~H|<pre class={blk_class(@b, @line)}>{@b.text}</pre>|
  end

  defp blk(%{b: %{tag: "span"}} = assigns) do
    ~H|<span class={blk_class(@b, @line)}><span :for={{c, t} <- @b.segs} class={c}>{t}</span><%= if @b.text do %>{@b.text}<% end %></span>|
  end

  defp blk(assigns) do
    ~H"""
    <div
      class={blk_class(@b, @line)}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
    ><span :for={{c, t} <- @b.segs} class={c}>{t}</span><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} /></div>
    """
  end

  defp blk_class(b, line),
    do: if(blk_current?(b, line), do: "#{b.class} #{b.mark}", else: b.class)

  defp blk_current?(%{lines: [a, b], mark: m}, line) when is_binary(m),
    do: line >= a and line <= b

  defp blk_current?(_, _), do: false

  defp block_view(pl) do
    %{
      tag: pget(pl, "tag") || "div",
      class: pget(pl, "class") || "",
      anchor: falsy(pget(pl, "anchor")),
      lines: falsy(pget(pl, "lines")),
      mark: falsy(pget(pl, "mark")),
      click: falsy(pget(pl, "click")),
      text: falsy(pget(pl, "text")),
      segs: for([c, t] <- pget(pl, "segs") || [], do: {c, t}),
      children: Enum.map(pget(pl, "children") || [], &block_view/1)
    }
  end

  defp pget([{:sym, k}, v | _], k), do: v
  defp pget([_, _ | rest], k), do: pget(rest, k)
  defp pget(_, _), do: nil

  defp falsy(false), do: nil
  defp falsy(v), do: v

  # A table always shrinks to the width it is given, and then clips what
  # does not fit. So the scrollbar must sit on an element OUTSIDE the
  # table. Earmark emits a bare <table>; give each one a box to scroll in.
  defp wrap_tables(html) do
    html
    |> String.replace("<table>", ~s(<div class="ag-table"><table>))
    |> String.replace("</table>", "</table></div>")
  end

  # the input region: [live text][cursor when point is home]
  defp ag_input(leaf, ag) do
    live_start = ag.input_start
    live = safe_slice(leaf.text, live_start, byte_size(leaf.text))

    # A restored window can carry an old transcript point. Rich chat hides
    # that position, so draw the caret at the input end until Scheme repairs it.
    rel =
      if leaf.point >= live_start do
        (leaf.point - live_start) |> min(byte_size(live)) |> then(&Text.floor_utf8(live, &1))
      else
        byte_size(live)
      end

    rest = binary_part(live, rel, byte_size(live) - rel)

    {pre, cur, post} =
      case String.next_grapheme(rest) do
        nil -> {live, " ", ""}
        {g, more} -> {binary_part(live, 0, rel), g, more}
      end

    %{pre: pre, cur: cur, post: post}
  end

  # The cursor in a markdown preview: a private-use sentinel goes into the
  # source at POINT, rides through Earmark as plain text, and comes out as
  # the .pt span. If point sits inside markdown syntax the one construct
  # can render off for a moment; the sandbox runs no scripts, so a mangled
  # span is a display blemish and nothing more.
  @pt_sentinel "\uE000"

  # A font face belongs to one document. The preview runs in its own
  # about:blank frame, so the root layout's link does not reach it: the
  # frame rendered Georgia and Menlo while the chrome rendered Spectral
  # and IBM Plex Mono. The frame must ask for the fonts itself.
  @preview_fonts """
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap">
  """
  # one marker per source line that draws text; it becomes a .ln span that
  # names the line's byte offset, so a key in the page can say which source
  # line the reader moved to
  @anchor "\uE005"
  @llm_start "\uE002"
  @llm_end "\uE003"
  @llm_meta_end "\uE004"
  @csv_preview_lines 5

  @doc false
  # Which renderer draws a Markdown page. The tree-sitter one asks the
  # document where a byte was drawn, so the caret stands on its own byte and
  # every line the author typed draws as a line. It is the default. Earmark
  # still carries the llm-response blockquotes, and the embeds that turn a
  # bare image URL into a picture and an x.com link into a card. A buffer
  # asks for it with the `preview-engine` local, and a page with no grammar
  # falls back to it on its own.
  # Preview folds keep source byte offsets stable. Hidden lines become spaces.
  # A closing fence stays present so the Markdown tree remains valid.
  defp preview_fold_source("markdown", text, point, mark, hidden) do
    folded =
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if MapSet.member?(hidden, index) and
             not Regex.match?(~r/^\s*(?:```|~~~)/, line) do
          String.duplicate(" ", byte_size(line))
        else
          line
        end
      end)

    visible_point = preview_fold_point(text, point, hidden)

    visible_mark =
      if is_integer(mark), do: preview_fold_point(text, mark, hidden), else: mark

    {folded, visible_point, visible_mark}
  end

  defp preview_fold_source(_mode, text, point, mark, _hidden),
    do: {text, point, mark}

  defp preview_fold_point(text, point, hidden) do
    line = Compos.Core.Text.line_index(text, point)

    if MapSet.member?(hidden, line) do
      first = preview_first_hidden_line(hidden, line)
      starts = [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
      max(Enum.at(starts, first) - 1, 0)
    else
      point
    end
  end

  defp preview_first_hidden_line(hidden, line) when line > 0 do
    if MapSet.member?(hidden, line - 1),
      do: preview_first_hidden_line(hidden, line - 1),
      else: line
  end

  defp preview_first_hidden_line(_hidden, 0), do: 0

  defp preview_engine(buffer, "markdown") do
    case Compos.Core.Buffer.get_local(buffer, "preview-engine") do
      "earmark" -> :earmark
      _ -> :tree_sitter
    end
  end

  defp preview_engine(_buffer, _rm), do: :earmark

  # Parsing a document costs a hundred times what drawing it does, and the
  # tree does not change when the caret moves. So the tree is cached against
  # the buffer's version: a keystroke that moves point redraws and nothing
  # more, and only an edit parses again.
  defp render_preview(:tree_sitter, rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} =
      preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)

    leaf = %{leaf | text: text}

    dir = preview_dir(leaf.buffer)

    opts = [
      whitespace: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true,
      hidden_lines: leaf.hidden_lines,
      # a pasted image is a path, not a URL, and a browser will not load one
      image_src: &local_image_src(&1, dir),
      url_embed: &youtube_embed_html/1,
      csv_source: csv_source_reader(leaf.buffer)
    ]

    tree_key = {leaf.buffer, leaf.version, leaf.hidden_lines}

    case md_tree(leaf, tree_key, cache) do
      {nil, cache} ->
        # no grammar installed: draw the page rather than nothing
        render_preview(:earmark, rm, leaf, pt, mark, faces, cache)

      {tree, cache} ->
        {:ok, html} = preview_doc_ts(tree, leaf.text, pt, mark, faces, leaf.overlays, opts)
        {html, cache}
    end
  end

  defp render_preview(:earmark, rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} =
      preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)

    leaf = %{leaf | text: text}

    html =
      preview_doc(rm, leaf.text, pt, mark, faces, leaf.preview_authored, leaf.overlays,
        csv_source: csv_source_reader(leaf.buffer),
        base_dir: preview_dir(leaf.buffer)
      )

    {html, cache}
  end

  defp csv_source_reader(buffer) do
    fn target ->
      case File.read(csv_preview_path(buffer, target)) do
        {:ok, text} -> text
        _ -> nil
      end
    end
  end

  defp csv_preview_path(buffer, target), do: Path.expand(target, preview_dir(buffer))

  # The document's own directory. A relative link is written relative to the
  # file it sits in, so that is what it resolves against.
  defp preview_dir(buffer) do
    case Compos.Core.Buffer.path(buffer) do
      path when is_binary(path) -> Path.dirname(path)
      _ -> Compos.Core.Buffer.get_local(buffer, "default-directory") || File.cwd!()
    end
  end

  defp md_tree(leaf, tree_key, cache) do
    case cache[{:md_tree, leaf.id}] do
      {^tree_key, tree} ->
        {tree, cache}

      _ ->
        case Compos.Core.Markdown.parse(ts_overlay_source(leaf.text, leaf.overlays)) do
          {:ok, tree} -> {tree, Map.put(cache, {:md_tree, leaf.id}, {tree_key, tree})}
          {:error, _} -> {nil, cache}
        end
    end
  end

  @doc """
  Render a Markdown preview through the tree-sitter renderer.

  Every node knows the source it came from, so the caret is cut in at its
  byte rather than placed by a rule about the construct it landed in.
  Answers `{:error, :no_grammar}` when the Markdown grammar is missing, and
  the caller falls back rather than drawing nothing.
  """
  def preview_doc_ts(tree, text, point, mark, faces, overlays, opts \\ []) do
    size = byte_size(text)
    p = point |> max(0) |> min(size)
    m = if is_integer(mark), do: mark |> max(0) |> min(size), else: nil

    marks =
      ts_line_marks(text) ++
        [{p, ~s(<span class="pt"></span>)}] ++
        if(m, do: [{m, ~s(<span class="mk"></span>)}], else: [])

    body =
      Compos.Core.Markdown.Html.render_tree(
        tree,
        ts_overlay_source(text, overlays),
        marks,
        opts
      )

    {:ok, markdown_page(body, faces)}
  end

  defp ts_line_marks(text) do
    [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
    |> Enum.reject(&(&1 > byte_size(text)))
    |> Enum.map(fn at -> {at, ~s(<span class="ln" data-p="#{at}"></span>)} end)
  end

  # An overlay only ever adds markup, which draws no character, so the marks
  # keep the source's own offsets and need no correction.
  defp ts_overlay_source(text, overlays) do
    text
    |> preview_overlay_positions(overlays)
    |> Enum.sort_by(fn {at, _} -> -at end)
    |> Enum.reduce(text, fn {at, insert}, acc ->
      at = acc |> Text.floor_utf8(at) |> max(0) |> min(byte_size(acc))
      binary_part(acc, 0, at) <> insert <> binary_part(acc, at, byte_size(acc) - at)
    end)
  end

  def preview_doc(rm, text, point, faces, authored),
    do: preview_doc(rm, text, point, nil, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored),
    do: preview_doc(rm, text, point, mark, faces, authored, [])

  def preview_doc("markdown", text, point, mark, faces, authored, overlays) do
    preview_doc("markdown", text, point, mark, faces, authored, overlays, [])
  end

  def preview_doc(rm, text, _point, _mark, faces, authored, _overlays),
    do: preview_html(rm, text, faces, authored)

  def preview_doc("markdown", text, point, mark, faces, authored, overlays, opts) do
    p = point |> max(0) |> min(byte_size(text))
    m = if is_integer(mark), do: mark |> max(0) |> min(byte_size(text)), else: nil

    blank = blank_point_line(text, p, overlays)
    anchors = line_anchors(text, blank)
    marked = mark_preview_positions(text, p, m, overlays, anchors, blank)

    "markdown"
    |> preview_html(marked, faces, authored, opts)
    |> place_anchors(anchors)
  end

  def preview_doc(rm, text, _point, _mark, faces, authored, _overlays, _opts),
    do: preview_html(rm, text, faces, authored)

  defp mark_preview_positions(text, point, mark, overlays, anchors, blank) do
    positions =
      point_position(text, point, blank) ++
        mark_position(text, mark) ++
        Enum.map(preview_overlay_positions(text, overlays), fn {at, s} -> {at, 2, s} end) ++
        (anchors |> Enum.reject(&(&1 == blank)) |> Enum.map(&{&1, 1, @anchor}))

    positions =
      positions
      |> Enum.reject(fn {at, _rank, _s} -> is_nil(at) end)
      # a sentinel inside a character makes the document invalid UTF-8, and
      # the Markdown parser then raises on the whole page
      |> Enum.map(fn {at, rank, s} -> {Text.floor_utf8(text, at), rank, s} end)
      # Later insertions at one offset land BEFORE earlier ones, so the rank
      # here is the reverse of the order in the page: a quote marker the
      # overlay adds keeps the start of its line, the line's anchor sits
      # after it, and the cursor stays innermost, right at point.
      |> Enum.sort_by(fn {at, rank, _s} -> {-at, rank} end)

    Enum.reduce(positions, text, fn {at, _rank, s}, acc ->
      binary_part(acc, 0, at) <> s <> binary_part(acc, at, byte_size(acc) - at)
    end)
  end

  # The point's own blank line draws an empty paragraph, and that paragraph
  # needs a blank line on each side or it joins the block above or below. The
  # anchor rides inside it, so the client still reads the source line the
  # caret stands on.
  defp point_position(_text, _point, ls) when is_integer(ls),
    do: [{ls, 0, "\n" <> @anchor <> @pt_sentinel <> "\n"}]

  defp point_position(text, point, nil), do: [{cursor_spot(text, point), 0, @pt_sentinel}]

  defp mark_position(_text, nil), do: []
  defp mark_position(text, mark), do: [{cursor_spot(text, mark), 0, "\uE001"}]

  # A blank line has no Markdown node, so a cursor on it has nowhere to draw.
  # The old answer moved the cursor to the next line that draws text. The
  # caret then stood in front of another block's words while every keystroke
  # went to the blank line: RET at the end of a document looked like it did
  # nothing, and RET above a table threw the caret into the first cell. Give
  # the line its own empty paragraph instead. An llm overlay quotes the lines
  # it covers, so leave those to it.
  defp blank_point_line(text, p, overlays) do
    ls = line_start(text, p)

    if blank_line?(text, ls) and not overlaid?(overlays, ls), do: ls, else: nil
  end

  # A blank line inside a fence is literal text. It draws, so it is not blank
  # for this purpose.
  defp blank_line?(text, ls),
    do: text |> line_at(ls) |> String.trim() == "" and not inside_fence?(text, ls)

  defp overlaid?(overlays, ls) do
    Enum.any?(overlays || [], fn
      {start, finish, _face} when is_integer(start) and is_integer(finish) ->
        ls >= start and ls <= finish

      _ ->
        false
    end)
  end

  # Preview formatting belongs to llm-mode, not to the Markdown document.
  # Render its response overlay through a temporary blockquote so Earmark can
  # still parse headings, lists, and emphasis inside the answer. The private
  # sentinels let us distinguish this from a blockquote the author typed.
  defp preview_overlay_positions(text, overlays) do
    Enum.flat_map(overlays || [], fn
      {start, finish, face}
      when is_integer(start) and is_integer(finish) and face in ["llm-response", :llm_response] ->
        start = start |> max(0) |> min(byte_size(text))
        finish = finish |> max(start) |> min(byte_size(text))

        continuation_prefixes =
          text
          |> binary_part(start, finish - start)
          |> :binary.matches("\n")
          |> Enum.map(fn {offset, _length} -> {start + offset + 1, "> "} end)

        metadata = "#{start}:#{finish}"

        [
          {start, "> " <> @llm_start <> metadata <> @llm_meta_end},
          {finish, @llm_end} | continuation_prefixes
        ]

      _ ->
        []
    end)
  end

  # A rendered row belongs to a source line, and the page is the only place
  # that knows which rows exist: a wrapped paragraph is many rows, a fence
  # line is none. So mark every source line that draws text, at the spot the
  # cursor would take on it. The client reads the nearest marker above the
  # row it moved to, and point follows the source.
  defp line_anchors(text, blank) do
    text
    |> line_starts()
    |> Enum.map(fn ls -> {ls, line_anchor_spot(text, ls, blank)} end)
    |> Enum.filter(fn {ls, spot} -> spot != nil and line_start(text, spot) == ls end)
    |> Enum.map(&elem(&1, 1))
  end

  # The point's blank line draws its own paragraph, so it anchors to itself.
  # Every other blank line draws nothing, and an anchor there would join the
  # line to the block above and end it.
  defp line_anchor_spot(_text, ls, ls), do: ls

  defp line_anchor_spot(text, ls, _blank) do
    if blank_line?(text, ls), do: nil, else: cursor_spot(text, ls)
  end

  defp line_starts(text) do
    [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
    |> Enum.reject(&(&1 > byte_size(text)))
  end

  # The markers come back in source order, so the Nth marker in the page is
  # the Nth anchored line. A parser that drops one would shift every offset
  # after it, so a count that does not match gives up and leaves the page
  # without anchors: the fragment mapping still works.
  defp place_anchors(html, anchors) do
    if length(:binary.matches(html, @anchor)) == length(anchors) do
      html |> String.split(@anchor) |> weave_anchors(anchors)
    else
      String.replace(html, @anchor, "")
    end
  end

  defp weave_anchors([head | parts], anchors) do
    Enum.zip(parts, anchors)
    |> Enum.reduce(head, fn {part, at}, acc ->
      acc <> ~s(<span class="ln" data-p="#{at}"></span>) <> part
    end)
  end

  # Point often sits inside a line's BLOCK marker — byte 0 of "# Title" is
  # where a freshly opened file rests — and a sentinel inside the marker
  # un-headings the line. Snap the cursor to the marker's end.
  #
  # Some lines draw no text of their own: a fence, a rule, a Setext
  # underline, a table's alignment row, an empty line. A sentinel there
  # breaks the block it belongs to, and hiding the cursor loses point. So
  # the cursor moves to the nearest line that DOES draw text — the code
  # inside the fence, the heading above the underline, the first row of the
  # table. The depth guard stops a run of such lines from looping.
  defp cursor_spot(text, p), do: cursor_spot(text, p, 0)

  defp cursor_spot(_text, _p, depth) when depth > 4, do: nil

  defp cursor_spot(text, p, depth) do
    ls = line_start(text, p)
    line = line_at(text, ls)
    trimmed = String.trim_leading(line)
    below = ls + byte_size(line) + 1
    above = ls - 1

    cond do
      # The opening fence draws the block's head, the closing fence draws
      # nothing: put the cursor at the near end of the code itself.
      String.starts_with?(trimmed, "```") ->
        if fence_opens?(text, ls),
          do: spot_below(text, below, p, depth),
          else: spot_above(text, above, p, depth)

      # Inside a fenced block every character is literal, so a sentinel is
      # safe wherever point stands.
      inside_fence?(text, ls) ->
        p

      # An empty line has no Markdown node of its own. Keep it attached to
      # the nearest rendered node so the sentinel cannot turn a blank line
      # into a paragraph and break tables or adjacent blocks.
      String.trim(trimmed) == "" ->
        spot_below(text, below, p, depth)

      # The underline belongs to the heading above it.
      setext_underline?(text, ls, trimmed) ->
        spot_above(text, above, p, depth)

      rule_line?(trimmed) ->
        spot_below(text, below, p, depth)

      # The alignment row makes the table a table, and it draws nothing.
      table_delimiter_row?(trimmed) ->
        spot_below(text, below, p, depth)

      table_row?(trimmed) ->
        line |> table_row_spot(ls, p) |> link_target_spot(line, ls)

      true ->
        p |> marker_spot(line, ls) |> link_target_spot(line, ls)
    end
  end

  defp spot_below(text, below, _p, depth) when below <= byte_size(text),
    do: cursor_spot(text, below, depth + 1)

  defp spot_below(_text, _below, p, _depth), do: p

  defp spot_above(text, above, _p, depth) when above >= 0,
    do: cursor_spot(text, above, depth + 1)

  defp spot_above(_text, _above, p, _depth), do: p

  defp line_start(text, p) do
    case :binary.matches(binary_part(text, 0, p), "\n") do
      [] -> 0
      ms -> ms |> List.last() |> elem(0) |> Kernel.+(1)
    end
  end

  defp line_at(text, ls),
    do: text |> binary_part(ls, byte_size(text) - ls) |> String.split("\n", parts: 2) |> hd()

  # A fence line opens a block when an even number of fences stands above it.
  defp fence_opens?(text, ls), do: rem(fences_above(text, ls), 2) == 0

  defp inside_fence?(text, ls), do: rem(fences_above(text, ls), 2) == 1

  defp fences_above(text, ls) do
    text
    |> binary_part(0, ls)
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(String.trim_leading(&1), "```"))
  end

  # `===` under text is a heading. The same run under a blank line is a rule.
  defp setext_underline?(text, ls, trimmed) do
    Regex.match?(~r/^[=-]+[ \t]*$/, trimmed) and ls > 0 and
      text |> line_at(line_start(text, ls - 1)) |> String.trim() != ""
  end

  defp rule_line?(trimmed),
    do: Regex.match?(~r/^([-*_])[ \t]*(\1[ \t]*){2,}$/, trimmed)

  defp marker_spot(p, line, ls) do
    case Regex.run(~r/^(?:\s{0,3}(?:\#{1,6}|[-*+]|\d+\.|>)\s+)+/, line, return: :index) do
      [{0, len}] when p < ls + len -> ls + len
      _ -> p
    end
  end

  # A link target renders as an attribute, not as text, so a cursor inside
  # it never draws. Keep it at the end of the label the reader can see.
  defp link_target_spot(nil, _line, _ls), do: nil

  defp link_target_spot(p, line, ls) do
    Regex.scan(~r/\]\([^)]*\)/, line, return: :index)
    |> List.flatten()
    |> Enum.reduce(p, fn {at, len}, acc ->
      if acc > ls + at and acc < ls + at + len, do: ls + at, else: acc
    end)
  end

  # A row stays a table row only while its pipes stand at the line edges.
  # Point rests at column 0 after every vertical move, and a sentinel there
  # ends the table at that row: everything below it falls back to raw text.
  # So keep the cursor inside the first and the last cell.
  defp table_row_spot(line, ls, p) do
    first =
      case Regex.run(~r/^\s*\|[ \t]*/, line, return: :index) do
        [{0, len}] -> len
        _ -> 0
      end

    last =
      case Regex.run(~r/[ \t]*\|[ \t]*$/, line, return: :index) do
        [{at, _}] -> at
        _ -> byte_size(line)
      end

    cond do
      first >= last -> nil
      p < ls + first -> ls + first
      p > ls + last -> ls + last
      true -> p
    end
  end

  defp table_row?(trimmed) do
    String.starts_with?(trimmed, "|") and length(:binary.matches(trimmed, "|")) >= 2
  end

  defp table_delimiter_row?(trimmed) do
    String.contains?(trimmed, "-") and Regex.match?(~r/^\|[\s:|-]*$/, trimmed)
  end

  defp preview_html("html", text, _faces, true), do: text

  # shr-style theming (Emacs eww): authored LAYOUT and typography survive,
  # authored COLORS don't — half-themed documents (authored light panel,
  # themed light text) are unreadable, so colors are all-or-nothing
  defp preview_html("html", text, faces, _authored) do
    p = preview_palette(faces)

    style = """
    <style>
    body{background:#{p.bg} !important;color:#{p.fg} !important}
    *,*::before,*::after{background-color:transparent !important;color:inherit !important;border-color:#{p.border} !important}
    a,a:visited{color:#{p.link} !important}
    code,pre,kbd{background-color:#{p.inset} !important}
    blockquote{color:#{p.dim} !important}
    th{background-color:#{p.inset} !important}
    ::highlight(region){background-color:color-mix(in srgb,#{p.link} 32%,transparent) !important}
    </style>
    """

    case String.split(text, ~r{</body>}i, parts: 2) do
      [before, rest] -> before <> style <> "</body>" <> rest
      [_] -> text <> style
    end
  end

  defp preview_html("markdown", text, faces, _authored),
    do: markdown_page(earmark_body(text), faces)

  defp preview_html("markdown", text, faces, _authored, opts),
    do: markdown_page(earmark_body(text, opts), faces)

  defp earmark_body(text, opts \\ []) do
    fence_labels = markdown_fence_labels(text)
    dir = Keyword.get(opts, :base_dir)

    case earmark_ast(markdown_preview_source(text)) do
      {:ok, ast} ->
        ast
        |> label_code_blocks(fence_labels)
        |> tag_llm_responses()
        |> embed_urls(dir)
        |> Earmark.Transform.transform(compact_output: false)
        |> String.replace(@pt_sentinel, ~s(<span class="pt"></span>))
        |> String.replace("\uE001", ~s(<span class="mk"></span>))

      {:error, why} ->
        unparsed_body(text, why)
    end
  end

  # Earmark raises on some documents instead of answering {:error, ast, _}.
  # An inline `{...}` reads as an attribute list, and one the parser cannot
  # make sense of is a FunctionClauseError deep inside it. The raise reaches
  # the LiveView, which dies, remounts, draws the same buffer and dies again:
  # one document takes the whole client down, and the page never comes back.
  #
  # A parser that cannot read a document must say so and draw the source.
  # The preview shows the document the author typed. A newline the author put
  # inside a paragraph is a line the reader must see, so a soft break draws as
  # a line break. Markdown joins those lines into one paragraph, which
  # reflowed the text and moved every line away from its source.
  defp earmark_ast(src) do
    case Earmark.as_ast(src, compact_output: false, breaks: true) do
      {:ok, ast, _} -> {:ok, ast}
      {:error, ast, _} -> {:ok, ast}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The document as it stands, plus what stopped the renderer. The reader
  # keeps their text and learns why it is not a page.
  defp unparsed_body(text, why) do
    ~s(<div class="preview-error"><strong>This page did not render.</strong> ) <>
      html_escape(why) <>
      ~s(</div><pre class="preview-raw">) <> html_escape(text) <> ~s(</pre>)
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # The page around a rendered body: the reader's typography and palette.
  # Both renderers draw into it, so the only difference between them is the
  # body itself.
  defp markdown_page(body, faces) do
    %{bg: bg, fg: fg, accent: accent, link: link, dim: dim, border: border, inset: inset} =
      preview_palette(faces)

    # typography is policy: the 'preview face carries it (appearance.scm
    # defcustoms; themes and init.scm may set it like any face)
    family = face(faces, "preview", "family", "Spectral,Georgia,serif")
    size = face(faces, "preview", "size", "16.5px")
    # the measure is the readability lever. 44em of Spectral ran to 94
    # characters a line; prose reads fastest between 65 and 75.
    measure = face(faces, "preview", "measure", "33em")

    """
    <!DOCTYPE html><html><head><meta charset="utf-8">#{@preview_fonts}<style>
    body{margin:0 auto;padding:30px 34px 70px;max-width:#{measure};overflow-wrap:break-word;
         word-break:normal;font:#{size}/1.7 #{family};color:#{fg};background:#{bg};
         -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    /* The renderer draws block gaps. CSS margins would count them twice. */
    p{margin:0}
    /* a heading must separate the sections, so its space above is much
       larger than the space below it */
    h1,h2,h3,h4{font-family:#{family};line-height:1.2;font-weight:700;letter-spacing:-0.012em}
    h1{font-size:30px;margin:0}
    /* one scale, no rules: a section heading is bigger and sits higher
       above its text than a paragraph; the renderer's gap does the rest */
    h2{font-size:23px;margin:0;padding-top:.45em}
    h3{font-size:18.5px;margin:0;padding-top:.3em;color:#{accent}}
    h4{font-size:15.5px;margin:0;padding-top:.2em;color:#{dim};font-weight:600;
       text-transform:uppercase;letter-spacing:.06em;font-size:12.5px}
    /* the browser default indents a list 40px and puts no space between
       the items: a list of requirements then reads as one block */
    ul,ol{margin:0;padding-left:1.35em}
    li{margin:0}
    li>ul,li>ol{margin:0}
    li::marker{color:#{dim}}
    code,pre{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;font-size:13.5px}
    code{background:#{inset};padding:1px 4px;border-radius:2px}
    /* a name in a heading is still the heading: the code span must not
       shrink it to body size, nor box it */
    h1 code,h2 code,h3 code,h4 code{background:none;padding:0;font-size:.92em}
    pre{background:#{inset};padding:10px 12px;border-left:3px solid #{accent};overflow-x:auto}
    pre code{background:none;padding:0}
    /* Plain-text blocks are prose-like payloads such as prompts and logs.
       Wrap them to the page measure; source-code fences keep horizontal scroll. */
    pre:has(> code.text){white-space:pre-wrap;overflow-wrap:anywhere;overflow-x:hidden}
    .code-block{margin:0;border:1px solid #{border};border-radius:6px;overflow:hidden;background:#{inset}}
    .code-block-head{display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:6px 10px;
      border-bottom:1px solid #{border};color:#{dim};font:12px/1.4 "IBM Plex Mono",ui-monospace,Menlo,monospace}
    .code-lang{margin-right:auto;color:#{accent};font-weight:700;text-transform:uppercase;letter-spacing:.06em}
    .code-action{white-space:nowrap}
    .code-action kbd{padding:1px 4px;border:1px solid #{border};border-radius:3px;color:#{fg};background:#{bg}}
    .code-action code{padding:0;color:#{fg};background:none}
    .code-block pre{margin:0;border:0;border-radius:0}
    a,a:visited{color:#{link};text-decoration-thickness:1px;text-underline-offset:2px;
      text-decoration-color:color-mix(in srgb,currentColor 45%,transparent)}
    a:hover{text-decoration-color:currentColor}
    a:empty{display:none}
    blockquote{margin:0;padding:2px 14px;border-left:3px solid #{border};color:#{dim}}
    blockquote.llm-response{margin:18px 0;padding:12px 16px;border:1px solid #{border};
         border-left:4px solid #{accent};border-radius:7px;background:#{inset};color:#{fg};user-select:text}
    blockquote.llm-response>:first-child{margin-top:0}
    blockquote.llm-response>:last-child{margin-bottom:0}
    table{border-collapse:collapse;font-size:14px;display:block;overflow-x:auto;
          max-width:100%;margin:0}
    /* rules between rows, none around them: a reference table reads as
       columns, not as a grid of boxes */
    th,td{border:0;border-bottom:1px solid #{border};padding:6px 14px 6px 0;
          vertical-align:top}
    th{background:none;text-align:left;color:#{dim};font:600 11px/1.7 "IBM Plex Mono",ui-monospace,Menlo,monospace;
       letter-spacing:.09em;text-transform:uppercase}
    tr:last-child td{border-bottom:0}
    img{max-width:100%;height:auto;border-radius:3px}
    figure{margin:1.4em 0}
    figure img{display:block;margin:0 auto}
    figcaption{margin-top:.55em;text-align:center;font-size:.9em;font-style:italic;color:var(--dim-fg,#8a857a)}
    hr{border:0;border-top:1px solid #{border};margin:0}
    .tweet{margin:12px 0;padding:12px 16px;border:1px solid #{border};border-radius:10px;
           max-width:32em;background:#{inset};font-size:14.5px}
    .tweet blockquote{margin:0;padding:0;border:0;color:#{fg}}
    .tweet blockquote p{margin:0 0 8px}
    .tweet-pending{color:#{dim}}
    .tw-head{display:flex;align-items:center;gap:10px;margin-bottom:8px}
    .tw-avatar{width:38px;height:38px;border-radius:50%}
    .tw-name{font-weight:600;display:block;line-height:1.2}
    .tw-handle{color:#{dim};text-decoration:none;font-size:13px}
    .tw-text{margin:0 0 10px}
    .tweet .tw-media{width:100%;border-radius:8px;margin:2px 0 8px}
    .tw-date{color:#{dim};font-size:13px;text-decoration:none}
    .youtube-card{position:relative;display:block;max-width:40em;margin:12px 0;
      color:white;text-decoration:none;border-radius:8px;overflow:hidden;background:#111}
    .youtube-card img{display:block;width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:0}
    .youtube-play{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);
      display:grid;place-items:center;width:64px;height:44px;border-radius:12px;
      background:#f00;color:white;font:24px/1 sans-serif;box-shadow:0 2px 10px #0008}
    ::highlight(region){background:color-mix(in srgb,#{accent} 32%,transparent)}
    /* The caret is an inline box with a painted left border and no content,
       so it is invisible to line breaking: an inline-block is an atomic
       inline, and the browser may wrap at it, even inside a word, and then
       measure rows the caret itself moved. The negative margin keeps the
       border from pushing the text along. */
    .pt{display:inline;border-left:2px solid #{accent};margin:0 -1px;
        animation:ptb 1.1s step-end infinite}
    /* a zero-width character gives the caret a line box of its own after a
       trailing break: RET at the end of a paragraph shows the new line */
    .pt::after{content:"\\200B"}
    /* The window does not own the keyboard, so the caret stops blinking.
       It still draws: a reader who looks at the page from another window
       must still see where point stands. Emacs draws a hollow box here. */
    .pt.idle{animation:none;opacity:0.45}
    /* whitespace-mode: the newline the author typed, drawn where it is.
       Muted enough to read past, present enough to aim at. */
    /* A blank line the author typed is one line tall, always: a separator
       that grew when point reached it moved every line below it. The
       source shows one blank line between paragraphs, and so does the page. */
    .gap{height:1.7em}
    .bl{height:1.7em}
    /* whitespace-mode. Every mark is a pseudo-element painted over the
       character the author typed, so the text keeps its own bytes and the
       page does not reflow when the marks come on. */
    .ws{position:relative}
    .ws.nl::before{content:"¶";color:#{dim};opacity:.5;font-size:.85em}
    /* a run of spaces, marked along its whole width rather than one span
       per space: the dots repeat, the text keeps its own bytes */
    .ws.sp{background-image:radial-gradient(circle,#{dim} 0.9px,transparent 1px);
           background-size:.32em 100%;background-position:center;
           background-repeat:repeat-x;opacity:.55}
    .ws.tab::before{content:"»";position:absolute;left:0;color:#{dim};opacity:.45;
                    pointer-events:none}
    .mk{display:inline-block;width:0;height:0}
    .ln{display:inline-block;width:0;height:0}
    @keyframes ptb{0%,49%{opacity:1}50%,100%{opacity:0}}
    </style></head><body>#{body}</body></html>
    """
  end

  # Morg adds Org-style header arguments after a fenced block's language.
  # Earmark accepts one language token only. It otherwise renders the whole
  # fence as inline code. Keep the arguments in the buffer, but hide them
  # from the preview parser so the body remains a real code block.
  defp markdown_preview_source(text) do
    text
    |> then(fn source ->
      Regex.replace(
        ~r/^([ \t]*```[ \t]*[A-Za-z0-9_+.-]+)[ \t]+(?=:[A-Za-z])[^\r\n]*$/m,
        source,
        "\\1"
      )
    end)
    |> recover_unmatched_inline_backticks()
  end

  # Earmark keeps an unmatched inline backtick open until the end of the
  # document. Escape an unmatched delimiter so later blocks still parse.
  # Fenced code blocks keep their backticks because they define structure.
  defp recover_unmatched_inline_backticks(text) do
    {parts, segment, _fenced?} =
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.reduce({[], "", false}, fn {raw_line, index}, {parts, segment, fenced?} ->
        line = if index == 0, do: raw_line, else: "\n" <> raw_line

        if Regex.match?(~r/^\s*```/, raw_line) do
          # parts is reversed at the end, so the fence line goes in FIRST and
          # the text it closes goes in after it. The other order rebuilt the
          # document with every fence line ahead of the text above it: the
          # first fence landed on the first heading, and the whole page
          # rendered as the code that fence opened.
          {[line, recover_inline_backticks(segment) | parts], "", not fenced?}
        else
          if fenced?,
            do: {[line | parts], segment, fenced?},
            else: {parts, segment <> line, fenced?}
        end
      end)

    Enum.reverse([recover_inline_backticks(segment) | parts]) |> IO.iodata_to_binary()
  end

  defp recover_inline_backticks(segment) do
    delimiters = Regex.scan(~r/(?<!`)`(?!`)/, segment)

    if rem(length(delimiters), 2) == 1 do
      Regex.replace(~r/(?<!`)`(?!`)/, segment, fn _ -> "\\`" end)
    else
      segment
    end
  end

  defp markdown_fence_labels(text) do
    Regex.scan(
      ~r/^[ \t]*```[ \t]*([A-Za-z0-9_+.-]+)([^\r\n]*)$/m,
      text,
      capture: :all_but_first
    )
    |> Enum.map(fn [language, arguments] ->
      tangle =
        case Regex.run(~r/:tangle[ \t]+([^ \t]+)/i, arguments, capture: :all_but_first) do
          [target] -> if(String.downcase(target) == "no", do: nil, else: target)
          _ -> nil
        end

      lines =
        case Regex.run(~r/:(?:lines|preview)[ \t]+([0-9]+)/i, arguments, capture: :all_but_first) do
          [count] ->
            case Integer.parse(count) do
              {value, ""} when value > 0 -> value
              _ -> @csv_preview_lines
            end

          _ ->
            @csv_preview_lines
        end

      %{
        language: language,
        morg?: Regex.match?(~r/(^|\s):[A-Za-z]/, arguments),
        tangle: tangle,
        lines: lines
      }
    end)
  end

  defp label_code_blocks(nodes, labels) when is_list(nodes) do
    {nodes, _labels} = Enum.map_reduce(nodes, labels, &label_code_block/2)
    nodes
  end

  defp label_code_block(
         {"pre", _, [{"code", code_attrs, _, _}], _} = pre,
         [%{language: language} = label | labels]
       ) do
    case List.keyfind(code_attrs, "class", 0) do
      {"class", ^language} -> {code_block(pre, label), labels}
      _ -> {pre, [label | labels]}
    end
  end

  defp label_code_block({tag, attrs, children, meta}, labels) when is_list(children) do
    {children, labels} = Enum.map_reduce(children, labels, &label_code_block/2)
    {{tag, attrs, children, meta}, labels}
  end

  defp label_code_block(other, labels), do: {other, labels}

  defp code_block(pre, label) do
    actions =
      if label.morg? do
        run =
          if String.downcase(label.language) in ~w(scheme sh bash zsh shell python py elixir exs js javascript node ruby) do
            [{"span", [{"class", "code-action"}], [{"kbd", [], ["C-c C-c"], %{}}, " run"], %{}}]
          else
            []
          end

        tangle =
          if label.tangle do
            [
              {"span", [{"class", "code-action"}],
               [
                 {"kbd", [], ["C-c C-x"], %{}},
                 " tangle → ",
                 {"code", [], [label.tangle], %{}}
               ], %{}}
            ]
          else
            []
          end

        run ++ tangle
      else
        []
      end

    header =
      {"div", [{"class", "code-block-head"}, {"data-chrome", "1"}],
       [{"span", [{"class", "code-lang"}], [label.language], %{}} | actions], %{}}

    content =
      if String.downcase(label.language) == "result-csv" do
        csv_preview(pre, label.lines, nil)
      else
        pre
      end

    {"div", [{"class", "code-block"}], [header, content], %{}}
  end

  defp csv_preview({"pre", _, [{"code", _, children, _}], _} = pre, limit, source) do
    rows =
      (source || code_text(children))
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.take(limit)
      |> Enum.map(&csv_row/1)

    case rows do
      [] when is_binary(source) ->
        {"table", [{"class", "csv-preview"}], [], %{}}

      [headers | body] ->
        head =
          {"thead", [], [{"tr", [], Enum.map(headers, &{"th", [], [&1], %{}}), %{}}], %{}}

        body =
          {"tbody", [],
           Enum.map(body, fn row ->
             {"tr", [], Enum.map(row, &{"td", [], [&1], %{}}), %{}}
           end), %{}}

        {"table", [{"class", "csv-preview"}], [head, body], %{}}

      _ ->
        pre
    end
  end

  defp code_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &code_text/1)
  defp code_text(text) when is_binary(text), do: text
  defp code_text({_tag, _attrs, children, _meta}), do: code_text(children)
  defp code_text(_), do: ""

  defp csv_row(line), do: csv_row(line, "", [], false)

  defp csv_row(<<>>, field, fields, _quoted), do: Enum.reverse([field | fields])

  defp csv_row(<<?", ?", rest::binary>>, field, fields, true),
    do: csv_row(rest, field <> "\"", fields, true)

  defp csv_row(<<?", rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field, fields, not quoted)

  defp csv_row(<<?,, rest::binary>>, field, fields, false),
    do: csv_row(rest, "", [field | fields], false)

  defp csv_row(<<char::utf8, rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field <> <<char::utf8>>, fields, quoted)

  defp tag_llm_responses(nodes) when is_list(nodes), do: Enum.map(nodes, &tag_llm_response/1)

  defp tag_llm_response({"blockquote", attrs, children, meta}) do
    case llm_range(children) do
      {start, finish} ->
        response_attrs = [
          {"class", "llm-response"},
          {"data-start", Integer.to_string(start)},
          {"data-end", Integer.to_string(finish)}
        ]

        {"blockquote", response_attrs ++ attrs, strip_llm_markers(children), meta}

      nil ->
        {"blockquote", attrs, tag_llm_responses(children), meta}
    end
  end

  defp tag_llm_response({tag, attrs, children, meta}) when is_list(children),
    do: {tag, attrs, tag_llm_responses(children), meta}

  defp tag_llm_response(other), do: other

  defp llm_range(nodes) do
    case Regex.run(
           ~r/#{@llm_start}(\d+):(\d+)#{@llm_meta_end}/u,
           llm_marker_text(nodes),
           capture: :all_but_first
         ) do
      [start, finish] -> {String.to_integer(start), String.to_integer(finish)}
      _ -> nil
    end
  end

  defp llm_marker_text(nodes) when is_list(nodes), do: Enum.map_join(nodes, &llm_marker_text/1)
  defp llm_marker_text(text) when is_binary(text), do: text
  defp llm_marker_text({_tag, _attrs, children, _meta}), do: llm_marker_text(children)
  defp llm_marker_text(_), do: ""

  defp strip_llm_markers(nodes) when is_list(nodes), do: Enum.map(nodes, &strip_llm_markers/1)

  defp strip_llm_markers(text) when is_binary(text),
    do:
      text
      |> String.replace(~r/#{@llm_start}\d+:\d+#{@llm_meta_end}/u, "")
      |> String.replace(@llm_end, "")

  defp strip_llm_markers({tag, attrs, children, meta}),
    do: {tag, attrs, strip_llm_markers(children), meta}

  defp strip_llm_markers(other), do: other

  # A bare URL in the source becomes a link whose text is the URL
  # (Earmark pure links). Images and X posts upgrade automatically. A bare
  # YouTube URL upgrades only as a complete paragraph. The #+embed directive
  # also upgrades it. A written
  # link — [text](url) — has text different from the href and stays a
  # link. The point sentinel can sit inside the pasted URL; the compare
  # ignores it and the embed re-emits it as a sibling.
  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  # the share sheet appends ?s=20 and friends; a query or fragment after
  # the status id still names the same tweet
  @tweet_re ~r{\Ahttps?://(?:mobile\.)?(?:twitter|x)\.com/[^/]+/status(?:es)?/\d+(?:[?#]\S*)?\z}

  defp embed_urls(nodes, dir) when is_list(nodes),
    do: Enum.flat_map(nodes, &embed_node(&1, dir))

  defp embed_node({"p", atts, children, meta}, dir) do
    source = llm_marker_text(children)

    clean =
      source
      |> String.replace(@pt_sentinel, "")
      |> String.replace("\uE001", "")
      |> String.replace(@anchor, "")

    url = embed_directive_url(clean) || String.trim(clean)

    case youtube_id(url) do
      nil -> [{"p", atts, embed_urls(children, dir), meta}]
      id -> [youtube_card_node(url, id, meta), preview_markers(source)]
    end
  end

  defp embed_node({"a", atts, [text], meta} = node, _dir) when is_binary(text) do
    url = String.replace(text, @pt_sentinel, "")

    # the href carries the sentinel percent-encoded; the text carries it raw
    href =
      case List.keyfind(atts, "href", 0) do
        {_, h} ->
          h
          |> String.replace(@pt_sentinel, "")
          |> String.replace(URI.encode(@pt_sentinel), "")

        nil ->
          nil
      end

    tail = if text == url, do: [], else: [@pt_sentinel]

    cond do
      href != url -> [node]
      image_url?(url) -> [{"img", [{"src", url}, {"alt", ""}], [], meta} | tail]
      tweet_url?(url) -> tweet_card(url, meta) ++ tail
      true -> [node]
    end
  end

  defp embed_node({"img", atts, children, meta}, dir) do
    atts =
      Enum.map(atts, fn
        {"src", src} when is_binary(src) -> {"src", local_image_src(src, dir)}
        attr -> attr
      end)

    [{"img", atts, children, meta}]
  end

  defp embed_node({tag, atts, children, meta}, dir) when is_list(children),
    do: [{tag, atts, embed_urls(children, dir), meta}]

  defp embed_node(other, _dir), do: [other]

  # A document's picture is a file path: absolute, or relative to the document
  # itself. A relative link is the one that survives another checkout, so the
  # preview resolves it against the document's directory. A URL is left alone.
  defp local_image_src(src, dir) do
    path =
      if String.starts_with?(src, "<") and String.ends_with?(src, ">") do
        binary_part(src, 1, byte_size(src) - 2)
      else
        src
      end

    cond do
      Path.type(path) == :absolute -> Compos.Ui.LocalImage.url(path)
      not is_nil(URI.parse(path).scheme) -> src
      is_binary(dir) -> Compos.Ui.LocalImage.url(Path.expand(path, dir))
      true -> src
    end
  end

  defp image_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, path: p} when s in ["http", "https"] and is_binary(p) ->
        (p |> Path.extname() |> String.downcase()) in @image_exts

      _ ->
        false
    end
  end

  defp tweet_url?(url), do: Regex.match?(@tweet_re, url)

  defp embed_directive_url(text) do
    case Regex.run(~r/\A#\+embed:[ \t]+(\S+)[ \t]*\z/i, text, capture: :all_but_first) do
      [url] -> url
      _ -> nil
    end
  end

  defp preview_markers(text) do
    text
    |> String.graphemes()
    |> Enum.filter(&(&1 in [@pt_sentinel, "\uE001", @anchor]))
    |> Enum.join()
  end

  defp youtube_id(url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    path = String.split(uri.path || "", "/", trim: true)

    id =
      cond do
        host in ["youtu.be", "www.youtu.be"] ->
          List.first(path)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and path == ["watch"] ->
          youtube_query_id(uri.query)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and
            List.first(path) in ["shorts", "live", "embed"] ->
          Enum.at(path, 1)

        true ->
          nil
      end

    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id), do: id
  end

  defp youtube_query_id(nil), do: nil

  defp youtube_query_id(query) do
    URI.decode_query(query)["v"]
  rescue
    ArgumentError -> nil
  end

  defp youtube_card_node(url, id, meta) do
    {"a",
     [
       {"class", "youtube-card"},
       {"href", url},
       {"target", "_blank"},
       {"rel", "noopener noreferrer"},
       {"aria-label", "Watch this video on YouTube"}
     ],
     [
       {"img", [{"src", youtube_thumbnail(id)}, {"alt", "YouTube video thumbnail"}], [], meta},
       {"span", [{"class", "youtube-play"}, {"aria-hidden", "true"}], ["▶"], meta}
     ], meta}
  end

  defp youtube_embed_html(source) do
    url = embed_directive_url(source) || String.trim(source)

    case url && youtube_id(url) do
      nil ->
        nil

      id ->
        safe_url = url |> html_escape() |> String.replace("\"", "&quot;")

        ~s(<a class="youtube-card" href="#{safe_url}" target="_blank" rel="noopener noreferrer" aria-label="Watch this video on YouTube"><img src="#{youtube_thumbnail(id)}" alt="YouTube video thumbnail"><span class="youtube-play" aria-hidden="true">▶</span></a>)
    end
  end

  defp youtube_thumbnail(id), do: "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"

  defp tweet_card(url, meta) do
    case Compos.Ui.Oembed.card(url) do
      {:ok, html} ->
        # the card html renders verbatim; Oembed strips script tags, and
        # the iframe sandbox runs no scripts either way
        [{"div", [{"class", "tweet"}], [html], Map.put(meta, :verbatim, true)}]

      :pending ->
        [
          {"div", [{"class", "tweet tweet-pending"}],
           ["Loading tweet — ", {"a", [{"href", url}], [url], meta}], meta}
        ]

      :error ->
        [{"a", [{"href", url}], [url], meta}]
    end
  end

  # the modeline names the buffer the short way; the tooltip keeps the
  # absolute path. Scheme decides what short means (project.scm).
  defp ml_name(%{modeline_name: name}) when is_binary(name) and name != "", do: name
  defp ml_name(%{buffer: buffer}), do: buffer

  defp ml_bytes(text) do
    b = Kernel.byte_size(text)

    cond do
      b >= 1_048_576 -> "#{Float.round(b / 1_048_576, 1)} MB"
      b >= 1024 -> "#{Float.round(b / 1024, 1)} kB"
      true -> "#{b} B"
    end
  end

  defp pct(%{top: 0, rows: rows, total_lines: total}) when total <= rows, do: "All"
  defp pct(%{top: 0}), do: "Top"
  defp pct(%{top: top, rows: rows, total_lines: total}) when top + rows >= total, do: "Bot"

  defp pct(%{top: top, total_lines: total}),
    do: "#{min(div(top * 100, max(total - 1, 1)), 99)}%"

  # popup anchor column in ch units (monospace): graphemes from line start
  # to the completion region start
  defp pop_col(text, line_start, comp_start) do
    len = comp_start |> max(line_start) |> min(byte_size(text))
    text |> binary_part(line_start, len - line_start) |> String.length()
  end

  defp face(faces, name, attr, fallback),
    do: get_in(faces, [name, attr]) || fallback

  defp preview_palette(faces) do
    %{
      bg: face(faces, "window", "bg", "#fdfcf8"),
      fg: face(faces, "default", "fg", "#1b1a17"),
      accent: face(faces, "accent", "fg", "#26356b"),
      link: face(faces, "link", "fg", face(faces, "accent", "fg", "#26356b")),
      dim: face(faces, "dim", "fg", "#8a857a"),
      border: face(faces, "border", "bg", "#cbc4b1"),
      inset: face(faces, "window-inactive", "bg", "#f4f0e6")
    }
  end

  defp face_css(faces) do
    vars =
      Enum.map_join(faces, "", fn {face, attrs} ->
        Enum.map_join(attrs, "", fn {k, v} -> "--#{face}-#{k}:#{v};" end)
      end)

    # every registered face is also a span class (.f-NAME) so Scheme can
    # define new faces and put them on overlay ranges with zero CSS edits.
    #
    # A face writes ONLY the attributes it declares. Writing them all put
    # `color:inherit` on a face that names no foreground, and a span
    # carries both classes — so a background-only overlay (the browse
    # scope tint) erased the syntax color under it. Emacs reads an
    # unspecified attribute as "leave it alone"; so does this.
    classes =
      faces
      |> Enum.filter(fn {face, _} -> face =~ ~r/^[a-zA-Z0-9_-]+$/ end)
      |> Enum.map_join("", fn {face, attrs} ->
        body =
          attrs
          |> Enum.map(fn {k, _} -> face_prop(face, to_string(k)) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("")

        if body == "", do: "", else: ".f-#{face}{#{body}}"
      end)

    ":root{#{vars}}#{classes}"
  end

  # one face attribute -> one CSS declaration, reading the face's own var.
  # An attribute with no CSS meaning (writing-mode's 'measure) stays a var.
  defp face_prop(face, attr) do
    case attr do
      "fg" -> "color:var(--#{face}-fg);"
      "bg" -> "background:var(--#{face}-bg);"
      "weight" -> "font-weight:var(--#{face}-weight);"
      "style" -> "font-style:var(--#{face}-style);"
      "family" -> "font-family:var(--#{face}-family);"
      "size" -> "font-size:var(--#{face}-size);"
      "decoration" -> "text-decoration:var(--#{face}-decoration);"
      _ -> nil
    end
  end
end
