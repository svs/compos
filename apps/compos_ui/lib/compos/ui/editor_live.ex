defmodule Compos.Ui.EditorLive do
  @moduledoc """
  The window: renders the tiling window tree per line (numbers, hl-line,
  cursor/region spans), modelines, which-key, the vertico-style minibuffer and
  echo area; forwards every keystroke to `Compos.Core.KeyDispatch`.

  Pure view — no editor logic here. Re-renders on editor-state events and on
  change events of any visible buffer (so RPC/agent edits appear live).
  """

  use Phoenix.LiveView
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  alias Compos.Core.{Events, Input}
  alias Compos.Scheme.Text
  alias Compos.Ui.{AppServer, LocalFile, LocalImage}

  # the frame tab rail before Scheme has answered, and when it cannot
  @no_tabs %{tabs: [], more: 0}

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
          tabs: @no_tabs,
          tabs_key: nil,
          wk_timer: nil,
          wk_shown: false,
          wk_pending: [],
          wk_token: 0,
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
         tabs: @no_tabs,
         tabs_key: nil,
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
  def handle_event("key", %{"k" => spec} = p, socket) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> ack(p) |> drain() |> refresh()}
  end

  # an intent from the browser's text pipeline (beforeinput): what the user
  # meant, as an inputType, a byte range, and text. KeyDispatch decides
  # whether it is a key; Scheme decides what a range means.
  def handle_event("intent", %{"type" => type, "from" => from, "to" => to} = p, socket)
      when is_binary(type) and is_integer(from) and is_integer(to) do
    text = if is_binary(p["text"]), do: p["text"], else: ""
    # The caret's own byte, and the buffer version it was measured against.
    # Both are only about the window the reader is in: a caret measured in
    # some other window names a byte in some other buffer, and the edit
    # lands in the active one. Anything else keeps the old rule.
    own? = safe_int(p["win"]) == Compos.Core.Editor.active_window(socket.assigns.frame)
    at = if own? and is_integer(p["at"]), do: p["at"], else: -1
    v = if own? and is_integer(p["v"]), do: p["v"], else: -1

    Input.run(socket.assigns.frame, fn ->
      Compos.Core.KeyDispatch.handle_intent(type, from, to, text, at, v)
    end)

    {:noreply, socket |> ack(p) |> drain() |> refresh()}
  end

  # Cross the DOM slice boundary against the versioned buffer, then recenter.
  def handle_event("edge_motion", %{"win" => win, "point" => point, "v" => version,
                                    "dir" => dir, "count" => count} = p, socket)
      when is_integer(point) and point >= 0 and dir in [-1, 1] and
             is_integer(count) and count > 0 and count <= 1000 do
    Input.run(socket.assigns.frame, fn ->
      buf = Compos.Core.Editor.current_buffer()
      if safe_int(win) == Compos.Core.Editor.active_window() and
           version == Compos.Core.Buffer.version(buf) do
        Compos.Core.Buffer.goto(buf, point)
        if p["extend"] == true and is_integer(p["mark"]) and p["mark"] >= 0 do
          Compos.Core.Buffer.set_mark(buf, p["mark"])
        end
        Compos.Core.Session.call_named("visual-edge-move!", [dir, p["extend"] == true, count])
      end
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

        if Compos.Core.Buffer.exists?(buf) and
             (not Map.has_key?(p, "v") or p["v"] == Compos.Core.Buffer.version(buf)) do
          mark = if is_integer(p["mark"]) and p["mark"] != point, do: p["mark"], else: nil
          # a keyboard motion keeps the mark (the region follows point, as
          # in Emacs); a click or a drag says what the mark is
          unless mark == nil and p["keep"] == true do
            Compos.Core.Buffer.set_mark(buf, mark)
          end

          Compos.Core.Buffer.goto(buf, point)

          # the caret moved with no command: point-motion-hook (editor.scm)
          # lets a package follow point here as post-command-hook does
          Compos.Core.Session.call_named("client-point-moved!", [buf])

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

  # a click on the frame tab rail: stand in that group. The chip that
  # counts the groups the rail left out opens the board instead.
  def handle_event("frame_tab", %{"id" => id}, socket) when is_binary(id) and id != "" do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.call_named("frame-tab!", [id])
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("frame_tab", _params, socket) do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.call_named("run-command", ["groups"])
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # the reader's place in a followed block list: a runtime mirror, so a
  # page refresh keeps the place. Stored inverted: a cleared local follows.
  def handle_event("follow_place", %{"buf" => buf, "stick" => stick, "top" => top} = params, socket)
      when is_boolean(stick) and is_integer(top) do
    if Compos.Core.Buffer.exists?(buf) do
      anchor = if is_integer(params["anchor"]), do: params["anchor"], else: false
      offset = if is_integer(params["offset"]), do: params["offset"], else: 0
      Compos.Core.Buffer.set_local(buf, "follow-place", [not stick, top, anchor, offset])
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
  def handle_event("paste", %{"text" => text} = p, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn ->
      Compos.Core.Session.eval("(clipboard-paste! #{scheme_string(text)})")
    end)

    {:noreply, socket |> ack(p) |> drain() |> refresh()}
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

  # A token travels with the timer message, because the message carries no
  # other identity: a chord that finished and a new one that started
  # between arming the timer and it firing both look like "some refresh
  # happened" to this process. A stale timer -- one `arm_which_key` already
  # tried to cancel, but the message had already queued -- sets wk_shown for
  # whatever chord is pending NOW, not the one the delay was timed for, and
  # wk_shown then never comes back down: every later prefix key skips the
  # debounce and shows the panel at once.
  #
  # The token is not the pending keys. The keys repeat: C-x, a command, then
  # C-x again is the most common chord pair there is, and the stale timer of
  # the first C-x carries the same keys as the second one. Every arm takes a
  # number of its own, so no message can ever answer for a later timer.
  def handle_info({:which_key_show, token}, socket) do
    if token == socket.assigns[:wk_token] do
      {:noreply, socket |> assign(wk_timer: nil, wk_shown: true) |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_display, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}

  # coalesce bursts: drain all queued change notifications, render once
  defp drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
      {:buffer_display, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  # timed as two halves: the editor state read (a call into the Editor
  # server, which waits when a command holds it) and the decoration of
  # the window tree (this process's own work)
  defp refresh(socket) do
    t0 = System.monotonic_time(:millisecond)
    # the boot id rides every render: a hot-swapped page module bumps it,
    # and the client's boot check reloads the page when it moves
    socket = assign(socket, boot_id: :persistent_term.get(:compos_boot_id, "dev"))
    {socket, state_ms} = refresh_state(socket)
    total = System.monotonic_time(:millisecond) - t0

    :telemetry.execute(
      [:compos, :ui, :refresh],
      %{duration: total, state: state_ms, decorate: total - state_ms},
      %{frame: socket.assigns[:frame]}
    )

    socket
  end

  # A real debounce. The CSS animation only made the panel INVISIBLE for the
  # idle delay; the browser still built its 219 nodes on the first key of
  # every chord, so C-x b rendered the whole C-x panel and threw it away.
  # Holding the render back means a fast chord costs nothing and draws
  # nothing. The delay is Scheme's which-key-idle-delay, which appearance.scm
  # publishes as the 'ui face's which-key-delay.
  defp hold_which_key(%{which_key: nil} = state, socket),
    do: {state, cancel_which_key(socket)}

  defp hold_which_key(state, socket) do
    pending = Map.get(state, :pending, [])

    cond do
      # up already: it follows the pending keys without flickering. The
      # rows come from Scheme now, not with every key: a fast chord never
      # pays for them (which-key-rows walks the buffer's whole ladder)
      socket.assigns[:wk_shown] ->
        {%{state | which_key: which_key_rows(pending, socket.assigns[:frame])}, socket}

      # the delay is idle time, not time since the chord began: while the
      # panel is still held back, every further prefix key restarts it. A
      # chord typed steadily but not fast — C-x, then r — used to spend the
      # first key's leftover delay and pop the panel a breath after the
      # second key, which reads as the key having summoned it.
      socket.assigns[:wk_pending] == pending and socket.assigns[:wk_timer] ->
        {%{state | which_key: nil}, socket}

      true ->
        {%{state | which_key: nil}, arm_which_key(state, socket, pending)}
    end
  end

  # (KEY COMMAND MODIFIERS LABEL) rows from Scheme, as the panel draws them
  defp which_key_rows(pending, fid) do
    case Compos.Core.Session.call_named("which-key-rows", [pending], fid, 5_000, :ui) do
      {:ok, rows} when is_list(rows) ->
        Enum.map(rows, fn [key, command, modifiers, label] ->
          %{key: key, command: command, modifiers: modifiers, modifier_label: label}
        end)

      _ ->
        []
    end
  end

  defp arm_which_key(state, socket, pending) do
    if t = socket.assigns[:wk_timer], do: Process.cancel_timer(t)
    token = socket.assigns[:wk_token] + 1
    timer = Process.send_after(self(), {:which_key_show, token}, which_key_delay_ms(state))
    assign(socket, wk_timer: timer, wk_shown: false, wk_pending: pending, wk_token: token)
  end

  # The token moves here too: a chord that ends retires its timer, so the
  # message that timer already queued answers for nothing.
  defp cancel_which_key(socket) do
    token = socket.assigns[:wk_token]

    token =
      case socket.assigns[:wk_timer] do
        nil ->
          token

        t ->
          Process.cancel_timer(t)
          token + 1
      end

    assign(socket, wk_timer: nil, wk_shown: false, wk_pending: [], wk_token: token)
  end

  @which_key_default_ms 500

  defp which_key_delay_ms(state) do
    with %{} = faces <- state.faces,
         %{} = ui <- Map.get(faces, "ui"),
         value when is_binary(value) <- Map.get(ui, "which-key-delay"),
         {seconds, _} <- Float.parse(value) do
      seconds |> Kernel.*(1000) |> round() |> max(0)
    else
      _ -> @which_key_default_ms
    end
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

    # While a prompt owns the keyboard the browser stops syncing the caret
    # (layouts.ex syncEditable), so a preview that moves point — imenu,
    # ripgrep, load-theme — would land invisibly in the window it came
    # from. Nothing is the native-caret surface while a prompt is up: the
    # server draws the cursor and marks the current row again, and the
    # client scrolls that row into view.
    caret_owner = if state.minibuffer, do: nil, else: state.active
    socket = sync_ropes(socket, state, caret_owner)

    {tree, line_cache} =
      decorate_display(
        state.tree,
        previous_leaves(socket.assigns[:state] && socket.assigns.state.tree),
        socket.assigns.line_cache,
        state.faces,
        caret_owner
      )

    state = %{state | tree: with_mode_line(tree, chrome(state, "mode-line-format"))}

    {state, socket} = hold_which_key(state, socket)

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
        |> Enum.each(fn name ->
          Events.unsubscribe(name)
          Events.unsubscribe_display(name)
        end)

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(fn name ->
          Events.subscribe(name)
          Events.subscribe_display(name)
        end)

        visible
      else
        socket.assigns.subscribed
      end

    {tabs, tabs_key} = frame_tabs(socket, state)

    socket =
      assign(socket,
        state: state,
        subscribed: subscribed,
        line_cache: line_cache,
        tabs: tabs,
        tabs_key: tabs_key
      )

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

    # a strip scroll asked the client to slide the panes. The token
    # changes on each request, so the client sees a new one on the
    # element before the patch replaces the panes (strip-slide.js).
    socket =
      case fid && Compos.Core.Editor.take_slide(fid) do
        dir when is_binary(dir) ->
          assign(socket, slide: "#{dir}:#{System.unique_integer([:positive])}")

        _ ->
          socket
      end

    # a motion command asked the browser's layout to move the selection
    socket =
      case fid && Compos.Core.Editor.take_select(fid) do
        {alter, dir, gran, count} ->
          push_event(socket, "select", %{
            alter: alter,
            dir: dir,
            granularity: gran,
            count: count
          })

        {alter, dir, gran} ->
          push_event(socket, "select", %{alter: alter, dir: dir, granularity: gran, count: 1})

        _ ->
          socket
      end

    {socket, state_ms}
  end

  # Input runs an event before it returns, so the next render holds the
  # effect of the input numbered SEQ. The client's rope drops its
  # prediction up to that number (Compos.Ui.RopeSync).
  defp ack(socket, %{"seq" => seq}) when is_integer(seq), do: assign(socket, intent_ack: seq)
  defp ack(socket, _params), do: socket

  # The client holds a rope of the text in the window that owns the caret,
  # when Scheme turns predict-mode on there (Compos.Ui.RopeSync). Only that
  # window takes typed text, so only that window keeps an entry.
  defp sync_ropes(socket, state, owner) do
    sent = socket.assigns[:rope_sent] || %{}
    ack = socket.assigns[:intent_ack] || 0

    leaf =
      state.tree
      |> leaves()
      |> Enum.find(&(&1.id == owner and Compos.Ui.RopeSync.predict?(&1)))

    case leaf do
      nil ->
        assign(socket, rope_sent: %{})

      leaf ->
        registry = Map.get(state.chrome || %{}, "predict-skip")
        skip = Compos.Ui.RopeSync.skip_keys(leaf, registry)
        {payload, entry} = Compos.Ui.RopeSync.payload(leaf, Map.get(sent, leaf.id), ack, skip)
        socket = assign(socket, rope_sent: %{leaf.id => entry})
        if payload, do: push_event(socket, "rope", payload), else: socket
    end
  end

  defp leaves(%{type: :leaf} = leaf), do: [leaf]
  defp leaves(%{type: :split, children: children}), do: Enum.flat_map(children, &leaves/1)
  defp leaves(_), do: []

  # A window draws its buffer's mode-line format, else the frame default.
  defp with_mode_line(%{type: :split, children: children} = split, default),
    do: %{split | children: Enum.map(children, &with_mode_line(&1, default))}

  defp with_mode_line(%{type: :leaf} = leaf, default),
    do: Map.put(leaf, :mode_line_format, Map.get(leaf, :mode_line_format) || default)

  defp with_mode_line(node, _default), do: node

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

  @doc """
  The display list for a window tree, for another client of the same
  payload (the handheld view). ACTIVE is the window that owns the caret,
  nil while a prompt is up. Returns the decorated tree and the cache.
  """
  def decorate_tree(tree, cache, faces, active), do: decorate(tree, cache, faces, active)

  # two-level cache: the raw line split is keyed by buffer VERSION only, so
  # cursor motion never re-splits the buffer; span decoration (cursor/region/
  # hl-line) is recomputed per render but only for lines it actually touches
  defp previous_leaves(%{type: :leaf, id: id} = leaf), do: %{id => leaf}

  defp previous_leaves(%{type: :split, children: children}) do
    Enum.reduce(children, %{}, fn child, leaves -> Map.merge(leaves, previous_leaves(child)) end)
  end

  defp previous_leaves(_), do: %{}

  defp decorate_display(%{type: :split} = split, previous, cache, faces, active) do
    {children, cache} =
      Enum.map_reduce(split.children, cache, &decorate_display(&1, previous, &2, faces, active))

    {%{split | children: children}, cache}
  end

  defp decorate_display(%{type: :leaf} = leaf, previous, cache, faces, active) do
    old = previous[leaf.id]

    if old && old.buffer == leaf.buffer &&
         (Map.get(leaf, :display_updating, false) || Events.display_updating?(leaf.buffer)) do
      {old, cache}
    else
      decorate(leaf, cache, faces, active)
    end
  end

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
       Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode"),
       csv_preview_file_key(leaf.buffer, leaf.text, rm)}

    {html, cache} =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> {html, cache}
        _ -> render_preview(rm, leaf, pt, mark, faces, cache)
      end

    shown_html =
      if Map.get(leaf, :cursor_visible, true),
        do: html,
        else: html <> "<style>.pt{visibility:hidden!important}</style>"

    {Map.merge(leaf, %{lines: [], preview: shown_html}),
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

  # rich diff: the buffer text IS the unified diff, so the cards are parsed
  # out of the same bytes the plain view shows. Only the controlled state —
  # which cards are open, git's status letters — rides the payload.
  # a generic block tree the mode composed. This clause converts plists to
  # maps and finds the buffer line point is on; it does not know what any
  # block means.
  #
  # The tree can hold byte ranges of the buffer (`range`), so the key is the
  # tree and the text up to the last range end: a key typed after that end
  # reuses the whole converted tree. The children of an isolated list keep
  # their views by their own plist and bytes, so a changed tree gives each
  # unchanged child the same term, and the list component skips it.
  defp decorate(%{type: :leaf, render_mode: "blocks"} = leaf, cache, _faces, _active) do
    # a large tree arrives as the read model's stand-in: equal stand-ins
    # name the same tree, so a hit costs no copy and no deep compare
    ref = Map.get(leaf, :blocks) || []
    text = leaf.text
    entry = cache[{:blocks, leaf.id}]

    entry =
      case entry do
        %{raw: ^ref, span: span, bytes: bytes} = e
        when span <= byte_size(text) and binary_part(text, 0, span) == bytes ->
          e

        _ ->
          raw = Compos.Core.BufferView.big_value(ref) || []
          memo = if is_map(entry), do: Map.get(entry, :memo, %{}), else: %{}
          {blocks, {span, memo}} = blocks_build(raw, text, memo, leaf.id)
          %{raw: ref, span: span, bytes: binary_part(text, 0, min(span, byte_size(text))),
            blocks: blocks, memo: memo, marks: Enum.any?(blocks, &block_marks?/1),
            inputs: Enum.map(blocks, &block_input?/1)}
      end

    # only a tree with point marks needs point's line; a chat has none
    line = if entry.marks, do: Compos.Core.Text.line_index(text, leaf.point) + 1, else: 0

    {Map.merge(leaf, %{
       lines: [],
       blk: entry.blocks,
       blk_inputs: entry.inputs,
       blk_line: line,
       blk_root: block_root(Map.get(leaf, :blocks_root)),
       blk_input: caret_input(leaf, Map.get(leaf, :blocks_input))
     }), Map.put(cache, {:blocks, leaf.id}, entry)}
  end

  # A text window: the rows of its viewport, from the core display model.
  defp decorate(%{type: :leaf} = leaf, cache, _faces, active) do
    {leaf, entry} =
      Compos.Core.Display.window(leaf, cache[leaf.id],
        caret_owner: active,
        embed_generation: Compos.Ui.Oembed.generation()
      )

    {leaf, Map.put(cache, leaf.id, entry)}
  end


  defp csv_preview_file_key(_buffer, _text, rm) when rm != "markdown", do: nil

  defp csv_preview_file_key(buffer, text, "markdown") do
    text
    |> csv_tangle_targets()
    |> Enum.map(fn target ->
      path = csv_preview_path(buffer, target)

      case File.stat(path) do
        {:ok, stat} -> {path, stat.size, stat.mtime}
        _ -> {path, nil}
      end
    end)
  end

  # The :tangle target of every csv fence. The Markdown grammar finds the
  # fences, so a fence line quoted inside another block is not one. The key
  # runs on every draw, so a text with no "csv" in it is not parsed.
  defp csv_tangle_targets(text) do
    if :binary.match(text, "csv") == :nomatch do
      []
    else
      "markdown"
      |> Compos.Core.TS.ts_query_nif(text, "(info_string) @info")
      |> Enum.map(fn {_, s, e} -> binary_part(text, s, e - s) end)
      |> Enum.filter(
        &(&1 |> String.split() |> List.first() |> to_string() |> String.downcase() == "csv")
      )
      |> Enum.flat_map(fn info ->
        case Regex.run(~r/:tangle[ \t]+(\S+)/, info) do
          [_, target] -> [target]
          _ -> []
        end
      end)
    end
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

  # the disconnected mount is not a client: it attaches no frame and
  # renders a neutral splash — the connected mount replaces it (S14)
  def composml(%{state: nil} = assigns) do
    ~M"""
    <c-frame
      id="editor"
      class={instance_class("editor-root splash", @instance_accent)}
      style={instance_style(@instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-instance={@instance_name}
    >
      <c-group style="display:flex;align-items:center;justify-content:center;height:100vh;opacity:.5;font-family:monospace">
        compos — connecting…
      </c-group>
    </c-frame>
    """
  end

  def composml(assigns) do
    ~M"""
    <c-frame
      id="editor"
      role="application"
      aria-label="compos editor"
      class={instance_class("editor-root", @instance_accent)}
      style={root_style(@state, @instance_accent)}
      phx-hook="Keys"
      data-boot={@boot_id}
      data-frame={@frame}
      data-instance={@instance_name}
    >
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(Compos.Ui.FaceCSS.css(@state.faces)) %></style>
    <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>
      <c-group :if={@state.workspace} class="workspace-bar" role="banner">
        <c-text class="workspace-bar-kind">WORKTREE</c-text>
        <strong :if={@state.workspace.project && @state.workspace.name}>
          {@state.workspace.project} / {@state.workspace.name}
        </strong>
        <strong :if={!(@state.workspace.project && @state.workspace.name)}>
          {@state.workspace.daemon}
        </strong>
        <c-text class="workspace-bar-port">PORT {workspace_port(@state.workspace.url)}</c-text>
        <c-text class="workspace-bar-root">{@state.workspace.root}</c-text>
        <c-text class="workspace-bar-help">{chrome(@state, "workspace-help", "")}</c-text>
      </c-group>
      <.frame_header_line state={@state} tabs={@tabs} />
      <.frame_echo state={@state} />
      <.frame_notices state={@state} />
      <c-windows class="windows" role="main" data-slide={assigns[:slide]}>
        <.tree node={@state.tree} active={@state.active} completion={@state.completion} />
      </c-windows>
      <c-which-key :if={@state.which_key && @state.minibuffer == nil && @state.transient == nil}
        id="which-key" phx-hook="WhichKey" data-pending={Enum.join(@state.pending, " ")}
        class="which-key mb-geom-panel">
        <c-group class="wk-title">
          <c-text>
            {Enum.join(@state.pending, " ")} —
            <c-text class="wk-count" data-total={length(@state.which_key)}>
              {length(@state.which_key)} bindings
            </c-text>
          </c-text>
          <c-text class="wk-filter" aria-live="polite">Hold a modifier · / filters commands</c-text>
        </c-group>
        <c-group class="wk-groups">
          <%= for {label, modifiers, bindings} <- which_key_groups(@state.which_key) do %>
            <section class="wk-group" data-modifiers={Enum.join(modifiers, " ")}>
              <h3 class="wk-group-title">{label}<c-text>{length(bindings)}</c-text></h3>
              <c-group class="wk-grid">
                <c-group :for={w <- bindings} class="wk-item" data-command={String.downcase(w.command)}>
                  <c-action-key class="wk-key">{w.key}</c-action-key>
                  <c-text class="wk-cmd">{w.command}</c-text>
                </c-group>
              </c-group>
            </section>
          <% end %>
          <c-group class="wk-empty" hidden>No matching commands</c-group>
        </c-group>
      </c-which-key>
      <%= if @state.minibuffer do %>
        <c-group class="mb-modal-layer">
          <c-group
            class={mb_panel_class(@state.minibuffer)}
            role="dialog"
            aria-modal="true"
            aria-label={String.trim_trailing(@state.minibuffer.prompt, ": ")}
          >
          <%= if mb_geom(@state.minibuffer) == "modal" do %>
            <c-group class="mb-head">
              <c-text class="mb-head-title">{String.trim_trailing(@state.minibuffer.prompt, ": ")}</c-text>
              <c-text class="mb-head-spacer"></c-text>
              <c-text class="mb-head-legend">
                <c-text :for={row <- palette_legend(@state.minibuffer)} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
              </c-text>
            </c-group>
          <% else %>
            <c-group class="mb-label-row">
              <%= case Map.get(@state.minibuffer, :legend, []) do %>
                <% [_ | _] = legend -> %>
                  <c-text :for={row <- legend} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
                <% _ -> %>
                  {label_row(@state.minibuffer)}
              <% end %>
            </c-group>
          <% end %>
          <c-group class={"mb-body #{if mb_rail_focused?(@state.minibuffer), do: "rail-focus"}"}>
            <.dynamic_tag tag_name={if Enum.any?(@state.minibuffer.candidates, &(Map.get(&1, :kind) == "symbol")), do: "symbol-list", else: "c-completions"} aria-label={@state.minibuffer.prompt} id="mb-cands" class="mb-cands" phx-hook="SelectionScroll" style={"--mb-label-w: #{@state.minibuffer.label_width}ch"}>
              <%= for c <- @state.minibuffer.candidates do %>
                <%= if Map.get(c, :kind) == "separator" do %>
                  <c-group class="mb-sep"><c-text class="mb-sep-label">{c.label}</c-text></c-group>
                <% else %>
                  <.dynamic_tag tag_name={if Map.get(c, :kind) == "symbol", do: "symbol-entry", else: "c-completion"}
                    selected={to_string(c.selected)} class={"mb-cand #{if c.selected, do: "selected"}"}
                    {if Map.get(c, :kind) == "symbol", do: symbol_attrs(c), else: []}>
                    <%= if Map.get(c, :kind) == "symbol" do %>
                      <symbol-name class={"mb-label #{candidate_face_class(c)}"}>{c.label}</symbol-name>
                      <c-text class="mb-hint"><symbol-kind>{symbol_fact(c, "kind")}</symbol-kind> · <symbol-location source={symbol_fact(c, "source")} line={symbol_fact(c, "line")}>L{symbol_fact(c, "line")}</symbol-location><%= if symbol_fact(c, "doc") != "" do %> — {symbol_fact(c, "doc")}<% end %></c-text>
                    <% else %>
                      <c-text class={"mb-label #{candidate_face_class(c)}"}>{c.label}</c-text>
                      <c-text class="mb-hint">{c.hint}</c-text>
                    <% end %>
                  </.dynamic_tag>
                <% end %>
              <% end %>
            </.dynamic_tag>
            <c-group
              :if={mb_geom(@state.minibuffer) == "modal" && mb_rail(@state.minibuffer)}
              id="mb-rail"
              class={"mb-preview mb-rail #{if mb_rail_focused?(@state.minibuffer), do: "focused"}"}
              phx-hook="SelectionScroll"
            >
              <%= with rail <- mb_rail(@state.minibuffer) do %>
                <c-group class="mb-preview-title">buffers</c-group>
                <c-group :for={row <- rail.rows} class={"mb-rail-row #{if row.selected, do: "selected"}"}>
                  <c-text class="mb-rail-name">{row.label}</c-text>
                  <c-text class="mb-rail-hint">{row.hint}</c-text>
                </c-group>
              <% end %>
            </c-group>
            <c-group
              :if={
                mb_geom(@state.minibuffer) == "modal" && !mb_rail(@state.minibuffer) &&
                  mb_preview(@state.minibuffer)
              }
              class="mb-preview"
            >
              <%= with p <- mb_preview(@state.minibuffer) do %>
                <c-group class="mb-preview-title">{p.title}</c-group>
                <c-group :for={{k, v} <- p.facts} class="mb-preview-fact">
                  <c-text class="mb-preview-k">{k}</c-text>
                  <c-text class="mb-preview-v">{v}</c-text>
                </c-group>
                <c-group :if={p.note != ""} class="mb-preview-note">{p.note}</c-group>
              <% end %>
            </c-group>
          </c-group>
          <c-group class={"mb-input-row #{if Map.get(@state.minibuffer, :prompt_sel), do: "selected"}"}>
            <c-text class="prompt">{@state.minibuffer.prompt}</c-text>
            <c-text class="mb-input"><%= with {pre, cur, post} <- mb_split(@state.minibuffer) do %>{pre}<c-cursor class="cursor">{cur}</c-cursor>{post}<% end %></c-text>
            <c-text class="mb-spacer"></c-text>
            <c-text :if={frame_file_path(@state)} class="ml-frame-path" title={frame_file_path(@state)}>{frame_file_path(@state)}</c-text>
            <c-text class="mb-count">{count_text(@state.minibuffer)}</c-text>
          </c-group>
        </c-group>
      </c-group>
      <% else %>
        <%= if @state.transient && @state.transient[:groups] do %>
          <c-minibuffer class={"mb-panel palette mb-geom-modal transient-panel #{if @state.transient[:detail], do: "with-rail"} #{if @state.transient[:layout] not in [nil, ""], do: "transient-layout-#{@state.transient.layout}"}"}>
            <c-group class="transient-head">
              <c-text class="transient-title">{@state.transient.title}</c-text>
              <c-text :if={@state.transient[:subtitle] not in [nil, ""]} class="transient-subtitle">{@state.transient.subtitle}</c-text>
              <c-text class="transient-head-spacer"></c-text>
              <c-text :if={@state.transient[:chips] not in [nil, []]} class="transient-chips">
                <c-text :for={chip <- @state.transient.chips} class={"transient-chip #{if chip.active, do: "active"}"}>{chip.label}</c-text>
              </c-text>
              <c-text :if={@state.transient[:context] not in [nil, ""]} class="transient-context">{@state.transient.context}</c-text>
            </c-group>
            <c-group class="transient-body">
              <c-group id="transient-groups" class="transient-groups" phx-hook="SelectionScroll">
                <c-group :for={column <- transient_columns(@state.transient)} class="transient-column">
                  <section :for={group <- Enum.filter(@state.transient.groups, &(&1.title in column))} class="transient-group">
                    <c-group class="transient-group-title">{group.title}</c-group>
                    <c-group
                      :for={item <- group.items}
                      class={"transient-item #{if item.selected, do: "selected"} #{item.behavior}"}
                    >
                      <c-action-key class="transient-key">{item.key}</c-action-key>
                      <c-text class="transient-description">{item.description}</c-text>
                      <c-text :if={item.value != ""} class="transient-value">{item.value}</c-text>
                    </c-group>
                  </section>
                </c-group>
              </c-group>
              <aside :if={@state.transient[:detail]} class="transient-rail">
                <c-group class="transient-rail-title">{@state.transient.detail.title}</c-group>
                <c-group :for={row <- @state.transient.detail.rows} class={"transient-rail-row #{row.tone}"}>
                  <c-text class="transient-rail-k">{row.k}</c-text>
                  <c-text class="transient-rail-v">{row.v}</c-text>
                </c-group>
                <c-group :if={@state.transient.detail.note != ""} class="transient-rail-note">{@state.transient.detail.note}</c-group>
              </aside>
            </c-group>
            <c-group class="transient-help">
              <c-text :for={row <- @state.transient[:legend] || []} class="transient-legend"><c-action-key class="transient-legend-key">{row.key}</c-action-key> {row.label}</c-text>
            </c-group>
          </c-minibuffer>
        <% else %>
        <% end %>
      <% end %>
    </c-frame>
    """
  end

  # The frame's header line. It carries only what stays: the wordmark, the
  # groups as tabs, and the frame's facts (global-mode-string). The frame
  # names its current group here, once; a window in that group does not
  # repeat it. A hairline holds the two halves apart. The message and the
  # key hints live in the echo area, so a message never moves a tab.
  defp frame_header_line(assigns) do
    ~M"""
    <c-statusbar class="echo-bar">
      <c-text class="ml-wordmark" title="compos">
        <img src="/images/compos-logo.png" width="15" height="15" alt="" />compos
      </c-text>
      <c-text class="ml-divider"></c-text>
      <c-tabs :if={@tabs.tabs != []} class="ml-tabs">
        <c-tab
          :for={t <- @tabs.tabs}
          class={"ml-tab #{if t.current, do: "ml-tab-on"}"}
          title={"switch to #{t.label}"}
          phx-click="frame_tab"
          phx-value-id={t.id}
        ><%= if t.segs != [] do %><c-text :for={{c, x} <- t.segs} class={c}>{x}</c-text><% else %>{t.label}<% end %></c-tab>
        <c-tab
          :if={@tabs.more > 0}
          class="ml-tab ml-tab-more"
          title={chrome(@state, "tabs-more-title", "")}
          phx-click="frame_tab"
        >{@tabs.more} more</c-tab>
      </c-tabs>
      <c-text class="ml-rule"></c-text>
      <c-text :if={@state.modeline_extra not in ["", []]} class="ml-extra"><%= if is_binary(@state.modeline_extra) do %><c-text class="ml-attention">{@state.modeline_extra}</c-text><% else %><c-text :for={{c, t} <- @state.modeline_extra} class={c}>{t}</c-text><% end %></c-text>
    </c-statusbar>
    """
  end

  # The echo area is the frame's own bar and holds only what passes: the
  # message, a rule, then the keys that matter where you are standing. It
  # sits under every window unless echo-area-position says top.
  defp frame_echo(assigns) do
    ~M"""
    <c-statusbar class="echo-area" role="status">
      <c-echo class="echo">{@state.echo}</c-echo>
      <c-text class="ml-rule"></c-text>
      <c-key-hints class="echo-hint">
        <c-text :for={{k, v} <- echo_hints(@state)} class="ml-hint"><c-action-key>{k}</c-action-key><%= if v != "" do %><c-text class="ml-do">{v}</c-text><% end %></c-text>
      </c-key-hints>
    </c-statusbar>
    """
  end

  # The notices that pass in the corner, newest on top, as Scheme publishes
  # them (notifications.scm): (SEQ SOURCE TITLE BODY). They take no focus
  # and no click; M-x notifications keeps the history.
  defp frame_notices(assigns) do
    ~M"""
    <c-group :if={notices(@state) != []} class="notices" role="status" aria-live="polite">
      <c-group :for={{seq, source, title, body} <- notices(@state)} id={"notice-" <> seq} class="notice">
        <c-text class="notice-source">{source}</c-text>
        <c-text class="notice-title">{title}</c-text>
        <c-text :if={body != ""} class="notice-body">{body}</c-text>
      </c-group>
    </c-group>
    """
  end

  defp notices(state) do
    for [seq, source, title, body] <- chrome(state, "notifications"),
        Enum.all?([seq, source, title, body], &is_binary/1),
        do: {seq, source, title, body}
  end

  # The echo area's key hints, as Scheme publishes them (echo-key-hints in
  # appearance.scm): (KEY VERB) pairs. An empty verb draws the key alone.
  defp echo_hints(state) do
    for [k, v] <- chrome(state, "echo-hints"), is_binary(k), is_binary(v), do: {k, v}
  end

  defp chrome(state, key, default \\ []),
    do: Map.get(Map.get(state, :chrome) || %{}, key, default)

  # The groups the frame modeline offers as tabs. Scheme decides which
  # ones and how many, and this asks again only when the frame's group or
  # the buffer order moved: nothing per keystroke.
  defp frame_tabs(socket, state) do
    key = {state.frame_group, Compos.Core.Editor.buffer_mru()}

    if key == socket.assigns[:tabs_key] do
      {socket.assigns[:tabs] || @no_tabs, key}
    else
      {fetch_tabs(socket.assigns[:frame]), key}
    end
  end

  defp fetch_tabs(nil), do: @no_tabs

  defp fetch_tabs(fid) do
    case Input.run(fid, fn -> Compos.Core.Session.call_named("frame-tabs", []) end) do
      {:ok, [rows, more]} when is_list(rows) ->
        %{
          tabs:
            for [id, label, current | rest] <- rows do
              %{
                id: to_string(id),
                label: to_string(label),
                current: current == true,
                # the rendered name, from the same grammar the modeline uses
                segs: ml_segs(%{modeline_name_segments: List.first(rest)})
              }
            end,
          more: if(is_number(more), do: trunc(more), else: 0)
        }

      _ ->
        @no_tabs
    end
  rescue
    _ -> @no_tabs
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

  defp symbol_fact(candidate, key), do: Map.get(Map.new(Map.get(candidate, :facts, [])), key, "")

  defp symbol_attrs(candidate), do: Enum.filter(Map.get(candidate, :facts, []), fn {key, _} -> key in ~w(name kind source line) end)

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

  # Keep the DOM geometry in lockstep with Editor.render_minibuffer/2.  The
  # renderer includes `geometry` so a LiveView patch does not have to infer a
  # panel shape from a presentation style; the style fallback keeps an older
  # daemon and a freshly recompiled UI compatible during development.
  # The three shapes are minibuffer, panel and modal. "popup" is the name
  # panel used to wear; it is still accepted here so an older daemon and a
  # freshly recompiled UI agree during development. A popup buffer
  # (popper.scm) is an ordinary window and shares no name with it.
  defp mb_geom(%{geometry: geometry}) when geometry in ["minibuffer", "panel", "modal"],
    do: geometry

  defp mb_geom(%{geometry: "popup"}), do: "panel"

  defp mb_geom(mb) do
    case Map.get(mb, :style) do
      style when style in ["palette", "modal"] -> "modal"
      style when style in ["panel", "popup"] -> "panel"
      _ -> "minibuffer"
    end
  end

  defp mb_panel_class(mb) do
    case mb_geom(mb) do
      # `palette` remains the visual vocabulary for the existing large
      # completion panel; `mb-geom-modal` names its layout role.
      "modal" -> "mb-panel palette mb-geom-modal"
      "panel" -> "mb-panel mb-geom-panel"
      "minibuffer" -> "mb-panel mb-geom-minibuffer"
    end
  end

  # A question is not a completion prompt. It takes one key, so it says
  # which keys answer it, and it counts nothing.
  defp label_row(%{style: "question"} = mb),
    do: "#{String.trim_trailing(mb.prompt, " ")} · y answers yes · n answers no · C-g quits"

  # a filter narrows the list behind it; the list itself shows the count,
  # so the prompt says what the keys do and nothing more. A prompt that
  # wrote its own legend says that instead — see the label row.
  defp label_row(%{style: "filter"} = mb),
    do:
      "#{String.trim_trailing(mb.prompt, ": ")} · type to narrow · DEL widens · " <>
        "empty removes it · RET / C-g close · \\ removes filter"

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

  # the columns Scheme decided for a transient; an older menu has none, so
  # every group stands alone
  defp transient_columns(%{columns: [_ | _] = cols}), do: cols
  defp transient_columns(%{groups: groups}), do: Enum.map(groups, &[&1.title])

  # the palette's head row legend: the prompt's own, else the completion keys
  defp palette_legend(%{legend: [_ | _] = rows}), do: rows

  defp palette_legend(_mb) do
    [
      %{key: "TAB", label: "complete"},
      %{key: "RET", label: "accept"},
      %{key: "C-n C-p", label: "select"},
      %{key: "C-c C-o", label: "collect"},
      %{key: "C-g", label: "quit"}
    ]
  end

  # The rail as a list: the prompt wrote the rows, so the view only says
  # which one is on. A prompt without a rail gets the facts panel instead.
  defp mb_rail(mb), do: Map.get(mb, :rail)

  defp mb_rail_focused?(mb) do
    case Map.get(mb, :rail) do
      %{focused: true} -> true
      _ -> false
    end
  end

  # The palette's right-hand rail: facts about the highlighted row. A row
  # brings its own facts (the prompt wrote them); a row without any shows
  # its hint. The note under the facts is the prompt's, or nothing.
  defp mb_preview(mb) do
    note = Map.get(mb, :note) || ""

    case Enum.find(mb.candidates, &Map.get(&1, :selected)) do
      nil ->
        nil

      # a row that wrote its own facts says them as they are: a group
      # card writes the whole group, and the rail is where it fits
      %{facts: [_ | _] = facts} = c ->
        %{title: c.label, facts: facts, note: note}

      %{kind: "container"} = c ->
        chips = Map.get(c, :chips, [])

        %{
          title: c.label,
          facts:
            [{"kind", "group"}, {"holds", c.hint |> String.split("·") |> hd() |> String.trim()}] ++
              if(chips == [], do: [], else: [{"members", Enum.join(chips, " · ")}]),
          note: note
        }

      %{facts: [_ | _] = facts} = c ->
        %{title: c.label, facts: facts, note: note}

      c ->
        fields = String.split(c.hint, ~r/\s{2,}/, trim: true)

        %{
          title: c.label,
          facts:
            case fields do
              [] -> []
              [one] -> [{"about", one}]
              many -> Enum.with_index(many, fn f, i -> {if(i == 0, do: "about", else: ""), f} end)
            end,
          note: note
        }
    end
  end

  defp tree(%{node: %{type: :split}} = assigns) do
    assigns = assign(assigns, ratio: Map.get(assigns.node, :ratio, 0.5))

    ~M"""
    <c-split class={"split #{@node.dir}"}>
      <c-group class="split-child" style={"flex: #{@ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 0)} active={@active} completion={@completion} />
      </c-group>
      <c-group class="split-child" style={"flex: #{1.0 - @ratio} 1 0%"}>
        <.tree node={Enum.at(@node.children, 1)} active={@active} completion={@completion} />
      </c-group>
    </c-split>
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
    ~M"""
    <.live_component
      module={Compos.Ui.Window}
      id={"win-#{@node.id}"}
      node={@node}
      active={@active}
      completion={@completion}
    />
    """
  end

  # A card takes an id of its own. The popup is split first and shows the
  # list's buffer for one render, then the card's copy: under one id the
  # client patched the phx-hook onto that element, and LiveView mounts a
  # hook only when its element is inserted, so the card never placed
  # itself and stayed hidden. A new id makes the client insert the card.
  def window_dom_id(id, true), do: "peek-#{id}"
  def window_dom_id(id, _), do: "win-#{id}"

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
        dismissible?: Map.get(assigns.node, :dismissible, false),
        peek?: String.contains?(assigns.node.window_class || "", "listing-peek"),
        # the state the mode line draws, normalised: (KEY VALUE TONE RANK)
        facts: ml_facts(assigns.node),
        active?: assigns.node.id == assigns.active
      )

    ~M"""
    <c-window
      id={window_dom_id(@node.id, @peek?)}
      class={"window #{if Map.get(@node, :highlighted, false), do: "preview-highlight"} #{if @active?, do: "active", else: "inactive"} #{if @dismissible?, do: "dismissible"} #{if @node.selected, do: "buffer-selected"} #{if !@node.line_numbers, do: "no-nums"} #{@node.window_class}"}
      style={window_style(@node)}
      active={to_string(@active?)}
      buffer={@node.buffer}
      data-win-id={@node.id}
      data-buffer={@node.buffer}
      data-path={@path}
      data-read-only={to_string(@read_only)}
      data-editing={to_string(Map.get(@node, :editing, false))}
      phx-hook={if @peek?, do: "PeekCard"}
      role={if @peek?, do: "note"}
      aria-label={if @peek?, do: "Preview"}
    >
      <%= if @peek? do %>
        <c-group class="peek-card-header">
          <c-text class="peek-card-label">Preview</c-text>
          <c-text class="peek-card-title">{@node.header_line || @node.buffer}</c-text>
          <button type="button" tabindex="-1" class="peek-card-dismiss" aria-label="Dismiss preview (q)"><kbd>q</kbd></button>
        </c-group>
        <c-group class="peek-card-body">
          <c-group inert>
            <%= cond do %>
              <% @node.render_mode in ["html", "markdown"] and Map.has_key?(@node, :preview) -> %>
                <iframe class="peek-document" srcdoc={@node.preview}
                  sandbox="allow-same-origin" tabindex="-1" title={@node.header_line || @node.buffer}></iframe>
              <% @node.render_mode == "blocks" and Map.has_key?(@node, :blk) -> %>
                <.dynamic_tag tag_name={@node.blk_root.tag} {@node.blk_root.attrs}
                  class={"blocks-view #{@node.blk_root.class}"} style={@node.style}>
                  <.blk :for={b <- @node.blk} b={b} line={@node.blk_line} win={@node.id} />
                </.dynamic_tag>
              <% Map.get(@node, :semantic_records) not in [nil, false, []] -> %>
                <.peek_text node={@node} />
              <% true -> %>
                <pre class="peek-plain">{@node.text}</pre>
            <% end %>
          </c-group>
        </c-group>
      <% else %>
      <%!-- Dismissal is one key and it costs no row. The q rides the top
             right corner of the window, on the empty end of whatever headline
             the buffer draws for itself. Nobody needs the word Back. --%>
      <button :if={@dismissible?} type="button" class="dismiss-action" phx-click="ui_cmd"
        phx-value-win={@node.id} phx-value-cmd="dismiss-buffer"
        aria-label="Dismiss child or go back (q)"><kbd>q</kbd></button>
      <c-headerline :if={@node.header_line} class="buffer-header">{@node.header_line}</c-headerline>
      <c-group :if={@node.dash || @node.dashboard_line_blocks} class="dash-top">
        <%!-- The window's header line: identity. Scheme builds every block
               (dashboard-line-blocks): the group pin, the title, the open
               change, the cua/focus tag and the one switcher. data-pin marks
               a window whose buffer is in a group other than the frame's;
               only then does the pin show. --%>
        <c-headerline
          :if={@node.dashboard_line_blocks}
          class="dash-persistent"
          title="open dashboard"
          data-pin={Map.get(@node, :pin)}
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >
          <.blk :for={b <- @node.dashboard_line_blocks || []} b={block_view(b)} line={-1} win={@node.id} />
        </c-headerline>
        <c-group :if={@node.dash} class="dash-live">
          <c-text>L{@line}:C{@col}</c-text>
          <c-text>point {@node.point}</c-text>
          <c-text>{ml_bytes(@node.text)}</c-text>
          <c-text>{pct(@node)}</c-text>
          <c-text :if={@node.modified} class="dash-live-mod">modified</c-text>
        </c-group>
        <%!-- The modes card is the dashboard's own, built in Scheme beside
               the group, tools and llm cards. A second one drawn here said
               the same thing twice. --%>
        <%= case @node.dash do %>
          <% [head | cards] -> %>
            <.blk b={block_view(head)} line={0} win={@node.id} />
            <c-group class="dash-grid">
              <.blk :for={b <- Enum.map(cards, &block_view/1)} b={b} line={0} win={@node.id} />
            </c-group>
          <% _ -> %>
        <% end %>
      </c-group>
      <%= if @node.render_mode == "terminal" do %>
        <c-group
          class="terminal-view"
          id={"terminal-#{@node.id}"}
          phx-hook="Terminal"
          phx-update="ignore"
          data-buffer={@node.buffer}
          data-win={@node.id}
        ></c-group>
      <% else %>
      <%= if @node.render_mode == "blocks" and Map.has_key?(@node, :blk) do %>
        <%!-- a c-buffer root is a static tag: a dynamic tag re-sends its
             own markup on every render --%>
        <c-buffer :if={@node.blk_root.tag == "c-buffer"} class={"blocks-view #{@node.blk_root.class}"} style={@node.style} id={"blocks-#{@node.id}"} phx-hook="BlockScroll" {@node.blk_root.attrs}>
          <.blocks_body node={@node} active?={@active?} completion={@completion} />
        </c-buffer>
        <.dynamic_tag :if={@node.blk_root.tag != "c-buffer"} tag_name={@node.blk_root.tag} class={"blocks-view #{@node.blk_root.class}"} style={@node.style} id={"blocks-#{@node.id}"} phx-hook="BlockScroll" {@node.blk_root.attrs}>
          <.blocks_body node={@node} active?={@active?} completion={@completion} />
        </.dynamic_tag>
      <% else %>
      <%= if @node.render_mode == "file" and Map.has_key?(@node, :file_url) do %>
        <c-preview kind="file" source={@node.file_url} buffer={@node.buffer} style="display: contents">
        <iframe
          class="file-preview"
          src={@node.file_url}
          sandbox=""
          title={@node.buffer}
        ></iframe>
        </c-preview>
      <% else %>
      <%= if @node.render_mode == "app" and Map.has_key?(@node, :app_url) do %>
        <%!-- An app runs its own scripts, so it must not share the editor's
             origin: it is served from 127.0.0.1:4005, and the parent is
             localhost:4004. allow-same-origin here grants the app its OWN
             origin, which buys it storage and relative URLs; the browser
             still refuses it every reach into this page. src, not srcdoc,
             for the same reason — a srcdoc document inherits us. --%>
        <c-preview kind="app" source={@node.app_url} buffer={@node.buffer} style="display: contents">
        <iframe
          class="app-preview"
          id={"app-#{@node.id}-#{:erlang.phash2(@node.app_url)}"}
          phx-hook="AppFrame"
          data-win={@node.id}
          data-ctop={@node.ctop}
          data-app-message={@node.app_message}
          sandbox="allow-scripts allow-same-origin allow-forms allow-modals allow-popups"
          src={@node.app_url}
          title={@node.buffer}
        >
        </iframe>
        </c-preview>
      <% else %>
      <%= if @node.render_mode in ["html", "markdown"] do %>
        <%!-- allow-same-origin, and nothing else. The parent must reach
             the frame's document to scroll it from a key; without it the
             page only answers the mouse. No allow-scripts, so the
             previewed document still runs nothing. --%>
        <c-preview kind="document" format={@node.render_mode} source={@node.buffer} buffer={@node.buffer} style="display: contents">
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
        </c-preview>
      <% else %>
      <.dynamic_tag tag_name={block_root(Map.get(@node, :text_root)).tag}
        {block_root(Map.get(@node, :text_root)).attrs}
        class={"buf #{if @node.client_scroll?, do: "client-scroll"}"}
        style={@node.style}
        data-ctop={@node.ctop}
        data-manual={to_string(@node.manual)}
        data-scroll={scroll_request(@node)}
        data-visual-lines={to_string(@node.visual_line_mode)}
        data-hl-line={to_string(Map.get(@node, :hl_line, true))}
        data-ws={to_string(Compos.Core.Display.whitespace?(@node))}
        data-v={@node.version}
        data-pt={@node.point}
        data-mark={@node.mark}
        contenteditable={if @node.read_only, do: nil, else: "true"}
        spellcheck="true"
        autocorrect="off"
        autocapitalize="off"
      >
        <%= for group <- semantic_line_groups(@lines, Map.get(@node, :semantic_records)) do %>
        <%= if group.direct do %>
          <.dynamic_tag :for={ln <- group.lines} tag_name={group.tag} {group.attrs}
            id={"ln-#{@node.id}-#{ln.num}"}
            class={"line line-content semantic-direct #{ln.row} #{if ln.current, do: "hl-line"} #{if ln.selected, do: "selected-line"}"}
            data-s={ln.start} data-line={ln.num} selected={to_string(ln.current)}><.semantic_line id_prefix={"sg-#{@node.id}-#{ln.num}"} segs={ln.segs} start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} direct={true} /></.dynamic_tag>
        <% else %>
        <.dynamic_tag tag_name={group.tag} class="semantic-record" style="display: contents" {group.attrs}>
        <c-line
          :for={ln <- group.lines}
          id={"ln-#{@node.id}-#{ln.num}"}
          class={"line #{ln.row} #{if ln.current, do: "hl-line"} #{if ln.selected, do: "selected-line"}"}
          data-s={ln.start}
        >
          <c-text class="linenum" contenteditable="false">{ln.num}</c-text>
          <c-text class="line-content"><.semantic_line id_prefix={"sg-#{@node.id}-#{ln.num}"} segs={ln.segs} start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} /><br
              :if={ln.segs == []}
              class="empty-row"
            /><%= if @active? && @completion && ln.at_point do %><c-text
              class="cap-pop"
              contenteditable="false"
              style={"left: #{pop_col(@node.text, ln.start, @completion.start)}ch"}
            ><c-text class="cap-title">completion-at-point · {@completion.total}</c-text><c-text
              :for={c <- @completion.candidates}
              class={"cap-row #{if c.selected, do: "selected"}"}
            ><c-text class="cap-label">{c.label}</c-text><c-text class="cap-kind">{c.hint}</c-text></c-text><c-text
              :for={c <- @completion.candidates}
              :if={c.selected}
              class="cap-doc"
              popover="manual"
              role="note"
              aria-label="Completion documentation"
            ><c-text class="cap-doc-name">{c.label}</c-text><c-text class="cap-doc-body">{completion_doc(c)}</c-text></c-text></c-text><% end %></c-text>
        </c-line>
        </.dynamic_tag>
        <% end %>
        <% end %>
      </.dynamic_tag>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <% end %>
      <c-group :if={@node.footer_line || Map.get(@node, :footer_line_blocks)} class="buffer-footer">
        <.blk :for={b <- Map.get(@node, :footer_line_blocks) || []} b={block_view(b)} line={-1} win={@node.id} />
        {@node.footer_line}
      </c-group>
      <%!-- The mode line is Scheme's mode-line-format (appearance.scm): a list
             of constructs in order. The view draws each construct and fills
             the %-constructs only it can know: %I the size, %l the line,
             %c the column, %p the scroll position. --%>
      <c-modeline class="modeline"><%= for {name, args} <- ml_format(@node) do %><%= case name do %>
        <% "dot" -> %><c-text
          class={"ml-dot #{if @node.modified, do: "modified"}"}
          title={@node.buffer}
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        ></c-text>
        <% "project" -> %><c-field name="project" :if={@node.modeline_project && @node.modeline_project != ""} class="ml-project">{@node.modeline_project}</c-field>
        <% "selected" -> %><c-status state="selected" :if={@node.selected} class="ml-mode ml-selected">{ml_arg(args)}</c-status>
        <% "preview" -> %><c-mode :if={@node.render_mode in ["html", "markdown"]} class="ml-mode">{ml_arg(args)}</c-mode>
        <% "info" -> %><c-field name="info"
          :if={@node.modeline_info}
          class="ml-mode"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-buf={@node.buffer}
        >{@node.modeline_info}</c-field>
        <% "facts" -> %><c-group :if={@facts != []} class="ml-facts">
          <c-field :for={{k, v, tone, rank} <- @facts} name={k} class="ml-fact" tone={tone} rank={rank}><c-label class="ml-fact-k">{k}</c-label><c-value class={"ml-fact-v #{tone}"}>{v}</c-value></c-field>
        </c-group>
        <% "spacer" -> %><c-text class="mb-spacer"></c-text>
        <% "text" -> %><c-text class={Enum.at(args, 0)}>{ml_fill(Enum.at(args, 1), @node)}</c-text>
        <% "position" -> %><c-position class="ml-pos" line={@line} column={@col}><%= for {cls, txt} <- ml_position(args, @node) do %><%= if cls == "" do %>{txt}<% else %><c-text class={cls}>{txt}</c-text><% end %><% end %></c-position>
        <% _ -> %>
      <% end %><% end %></c-modeline>
      <% end %>
    </c-window>
    """
  end

  # cut the line at every range boundary; each segment takes the last-wins
  # ts class plus any active overlay classes
  # a seg whose overlay face says img-embed IS an image: the buffer text
  # stays the URL (the buffer is truth), the client draws the picture
  # An island draws in the text's place and is one character to the caret
  # (contenteditable=false): an image, an X card, or a YouTube card.
  # data-len says how many source bytes it stands for, so the
  # client's byte mapping walks over it.
  # the id keys the node for the DOM patcher: without one, LiveView
  # stamps a fresh magic id on every render of this comprehension and
  # morphdom tears the span down and builds it again instead of writing
  # the new text into it
  attr(:id, :string, required: true)
  attr(:txt, :string, required: true)
  attr(:cls, :string, required: true)
  attr(:base, :string, default: nil)
  attr(:win, :any, default: nil)

  defp seg(%{cls: cls, txt: txt} = assigns)
       when is_binary(cls) and is_binary(txt) do
    src = if cls =~ "img-embed", do: image_src(txt, assigns.base)
    assigns = assign(assigns, href: link_href(cls))

    cond do
      # chrome: text the buffer does not hold, standing at one byte and
      # holding zero bytes; the byte walker skips it by its data-len.
      # A click id routes through the block-click registry like a block
      # tree's click.
      String.starts_with?(cls, "chrome-seg") ->
        {shown, click} = chrome_click_off(cls)
        assigns = assign(assigns, cls: shown, click: click)

        ~M"""
        <c-text
          id={@id}
          class={@cls}
          contenteditable="false"
          data-len="0"
          phx-click={@click && "block_click"}
          phx-value-win={@click && @win}
          phx-value-id={@click}
        >{@txt}</c-text>
        """

      is_binary(src) ->
        avatar? = String.ends_with?(txt, "#compos-avatar")

        assigns =
          assign(assigns,
            src: src,
            len: byte_size(txt),
            image_class: if(avatar?, do: "img-embed img-avatar", else: "img-embed")
          )

        ~M|<img id={@id} src={@src} class={@image_class} loading="lazy" contenteditable="false" data-len={@len} />|

      cls =~ "x-embed" ->
        assigns = assign(assigns, len: byte_size(txt), card: Compos.Ui.Oembed.card(txt))

        ~M"""
        <c-text id={@id} class="x-card" contenteditable="false" data-len={@len}><%= case @card do %><% {:ok, html} -> %>{Phoenix.HTML.raw(html)}<% _ -> %><c-text class="x-pending">{@txt}</c-text><% end %></c-text>
        """

      cls =~ "youtube-embed" and Compos.Core.Markdown.Html.youtube_id(txt) ->
        id = Compos.Core.Markdown.Html.youtube_id(txt)

        assigns =
          assign(assigns,
            len: byte_size(txt),
            thumbnail: Compos.Core.Markdown.Html.youtube_thumbnail(id)
          )

        ~M"""
        <a id={@id} class="youtube-card youtube-island" href={@txt} target="_blank" rel="noopener noreferrer" contenteditable="false" data-len={@len} aria-label="Watch this video on YouTube"><img src={@thumbnail} alt="YouTube video thumbnail" loading="lazy" /><c-text class="youtube-play" aria-hidden="true">▶</c-text></a>
        """

      true ->
        ~M|<c-text id={@id} class={@cls} data-href={@href}>{@txt}</c-text>|
    end
  end

  # a URL draws as it is; a relative path resolves beside the buffer's
  # file and is served signed (LocalImage); a path with no file has no picture
  defp image_src(txt, base) do
    cond do
      # a base64 picture is its own source: the bytes stand in the text,
      # the browser decodes them, and nothing is fetched
      String.starts_with?(txt, "data:image/") ->
        String.trim_trailing(txt, "#compos-avatar")

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

  # take the click id back off a chrome seg's class; the shown class keeps
  # only the styling tokens
  defp chrome_click_off(cls) do
    {clicks, rest} =
      cls |> String.split(" ") |> Enum.split_with(&String.starts_with?(&1, "chrome-click:"))

    click =
      case clicks do
        ["chrome-click:" <> id | _] -> URI.decode(id)
        [] -> nil
      end

    {Enum.join(rest, " "), click}
  end

  # A drawn Markdown link carries its target in its class, because a class
  # is the only channel a span has. The reader clicks the text; the client
  # reads the target back off the element.
  defp link_href(cls) do
    cls
    |> String.split(" ")
    |> Enum.find_value(fn
      "link-to:" <> encoded -> URI.decode(encoded)
      _ -> nil
    end)
  end

  # both previews follow the live theme; `(buffer-set-local! buf
  # 'preview-authored #t)` renders html exactly as authored instead
  # The transcript is markdown; the page renderer draws it (core).
  defp prose_html(md), do: Compos.Core.Markdown.Html.prose(md, local_url: &LocalImage.url/1)

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

  # A tool body whose last part is a JSON object or array: {HEAD, JSON}.
  # The JSON draws in the json grammar's faces.
  defp json_tail(body) do
    parts = String.split(body, "\n\n")
    json = List.last(parts) || ""

    case Jason.decode(json) do
      {:ok, value} when is_map(value) or is_list(value) ->
        {binary_part(body, 0, byte_size(body) - byte_size(json)), json}

      _ ->
        nil
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
  # The top blocks of a window. Only a block that holds the caret input
  # sees the input in its context, so a key that types re-renders that
  # block alone, and every other block's assigns are unchanged.
  defp blocks_body(assigns) do
    ~M"""
    <c-buffer class="blocks-scroll"><.blk
        :for={{b, input?} <- Enum.zip(@node.blk, @node.blk_inputs)}
        b={b}
        line={@node.blk_line}
        win={@node.id}
        ctx={if input?, do: blk_ctx(@node, @active?, @completion), else: blk_ctx(@node, false, nil) |> Map.delete(:input)}
      /></c-buffer>
    """
  end

  def blk(assigns), do: assigns |> assign_new(:ctx, fn -> %{} end) |> blk_node()

  defp blk_node(%{b: %{empty: true}} = assigns), do: ~M||

  # An isolated list: its children draw inside the list component, so a
  # render that does not change them diffs to a skip placeholder. A peek
  # or a header has no component, and draws the list in place.
  defp blk_node(%{b: %{isolate: true}, ctx: %{live: true}} = assigns) do
    ~M"""
    <.live_component module={Compos.Ui.BlockList} id={"blist-#{@win}-#{@b.anchor || "list"}"}
      b={Map.delete(@b, :children)} children={@b.children} win={@win} buf={@ctx[:buf]}
      follow={@b.follow && @ctx[:follow]} />
    """
  end

  defp blk_node(%{b: %{isolate: true}} = assigns) do
    ~M"""
    <.dynamic_tag tag_name={@b.tag} class={@b.class} {@b.attrs}><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></.dynamic_tag>
    """
  end

  # The caret input: the text past the window's input start, with the
  # caret at point. The hint shows while the input is empty. The
  # completion card opens upward, because the input sits at the foot.
  defp blk_node(%{b: %{input: true}} = assigns) do
    ~M"""
    <c-input class={@b.class}><%= if @ctx[:input] do %>{@ctx.input.pre}<c-cursor
        :if={@ctx.input.cur != "" && Map.get(@ctx, :cursor, true)}
        class="cursor"
      >{@ctx.input.cur}</c-cursor>{@ctx.input.post}<% end %></c-input><%= if @ctx[:completion] do %><c-text
      class="cap-pop cap-pop-up"
      contenteditable="false"
    ><c-text class="cap-title">completion-at-point · {@ctx.completion.total}</c-text><c-text
      :for={c <- @ctx.completion.candidates}
      class={"cap-row #{if c.selected, do: "selected"}"}
    ><c-text class="cap-label">{c.label}</c-text><c-text class="cap-kind">{c.hint}</c-text></c-text><c-text
      :for={c <- @ctx.completion.candidates}
      :if={c.selected}
      class="cap-doc"
      popover="manual"
      role="note"
      aria-label="Completion documentation"
    ><c-text class="cap-doc-name">{c.label}</c-text><c-text class="cap-doc-body">{completion_doc(c)}</c-text></c-text></c-text><% end %><c-key-hints
      :if={@b.hint && (@ctx[:input] == nil or (@ctx.input.pre == "" and @ctx.input.post == ""))}
      class="input-hint"
    >{@b.hint}</c-key-hints>
    """
  end

  # A disclosure. `open` is the mode's state; a summary with a click is
  # controlled, so the browser must not toggle it on its own.
  defp blk_node(%{b: %{tag: "details"}} = assigns) do
    ~M"""
    <details class={blk_class(@b, @line)} open={@b.open} {@b.attrs}><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></details>
    """
  end

  defp blk_node(%{b: %{tag: "summary"}} = assigns) do
    ~M"""
    <summary
      class={if @b.class != "", do: @b.class}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      onclick={@b.click && "event.preventDefault()"}
      {@b.attrs}
    ><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></summary>
    """
  end

  defp blk_node(%{b: %{tag: "button"}} = assigns) do
    ~M"""
    <button
      type="button"
      class={@b.class}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></button>
    """
  end

  # a range drawn as Markdown: the prose HTML goes in as it is
  defp blk_node(%{b: %{html: html}} = assigns) when is_binary(html) do
    ~M"""
    <.dynamic_tag tag_name={@b.tag} class={blk_class(@b, @line)} {@b.attrs}>{Phoenix.HTML.raw(@b.html)}</.dynamic_tag>
    """
  end

  # The one renderer for block trees. Structure only: tags, classes, segs,
  # click ids and the point mark all come from the mode. The mark: a block
  # with a mark class and a line range gets that class while point's line is
  # inside the range — and, when it also has an anchor, a data-current
  # attribute the scroll hook follows.
  defp blk_node(%{b: %{tag: "pre"}} = assigns) do
    ~M|<pre class={blk_class(@b, @line)}>{@b.text}</pre>|
  end

  defp blk_node(%{b: %{tag: "span"}} = assigns) do
    ~M|<c-text class={blk_class(@b, @line)}><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %></c-text>|
  end

  defp blk_node(%{b: %{tag: "div"}} = assigns) do
    ~M"""
    <c-group
      class={blk_class(@b, @line)}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></c-group>
    """
  end

  # a product photo or an embedded picture, drawn from its src attr
  defp blk_node(%{b: %{tag: "img"}} = assigns) do
    ~M|<img class={blk_class(@b, @line)} {@b.attrs} loading="lazy" />|
  end

  # A ComposML element draws with a static tag: a dynamic tag re-sends its
  # own markup on every render of its block, and the blocks around a caret
  # input render on every key. One clause per element, compiled here.
  for tag <- Compos.Ui.ComposML.elements() do
    source = """
    <#{tag}
      class={blk_class(@b, @line)}
      id={@b.anchor && "block-\#{@win}-\#{@b.anchor}"}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      {if @b.anchor, do: [{"selected", to_string(blk_current?(@b, @line))}], else: []}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><c-text :if={{"marked", "true"} in @b.attrs} class="list-mark" aria-label="Marked">✱</c-text><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} {[{"face", block_faces(c)}]}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></#{tag}>
    """

    defp blk_node(%{b: %{tag: unquote(tag)}} = var!(assigns)) do
      unquote(
        Phoenix.LiveView.TagEngine.compile(source,
          file: __ENV__.file,
          line: __ENV__.line,
          caller: __ENV__,
          indentation: 0,
          tag_handler: Compos.Ui.ComposML
        )
      )
    end
  end

  # any other tag: an SVG chart, a table, a label. The attributes are the
  # mode's, filtered by the allowlist below; a click still routes by id.
  defp blk_node(assigns) do
    ~M"""
    <.dynamic_tag
      tag_name={@b.tag}
      class={blk_class(@b, @line)}
      id={@b.anchor && "block-#{@win}-#{@b.anchor}"}
      data-anchor={@b.anchor}
      data-current={if @b.anchor && blk_current?(@b, @line), do: "1"}
      {if @b.anchor, do: [{"selected", to_string(blk_current?(@b, @line))}], else: []}
      phx-click={@b.click && "block_click"}
      phx-value-win={@b.click && @win}
      phx-value-id={@b.click}
      {@b.attrs}
    ><c-text :if={{"marked", "true"} in @b.attrs} class="list-mark" aria-label="Marked">✱</c-text><.dynamic_tag :for={{c, t, tag} <- @b.semantic_segs} tag_name={tag} class={c} face={block_faces(c)}>{t}</.dynamic_tag><%= if @b.text do %>{@b.text}<% end %><.blk :for={c <- @b.children} b={c} line={@line} win={@win} ctx={@ctx} /></.dynamic_tag>
    """
  end

  # the server's last scroll of a client-scrolled window: "GEN:LINES". The
  # client applies a request once, when the generation is new to it.
  defp scroll_request(%{scroll_gen: gen, scroll_lines: lines}) when is_integer(gen),
    do: "#{gen}:#{lines}"

  defp scroll_request(_node), do: nil

  defp blk_class(b, line),
    do: if(blk_current?(b, line), do: "#{b.class} #{b.mark}", else: b.class)

  defp block_faces(classes) do
    classes |> String.split() |> Enum.filter(&String.starts_with?(&1, "f-"))
    |> Enum.map(&String.replace_prefix(&1, "f-", "")) |> Enum.join(" ")
  end

  defp blk_current?(%{lines: [a, b], mark: m}, line) when is_binary(m),
    do: line >= a and line <= b

  defp blk_current?(_, _), do: false

  # The tags and attributes a block may carry beyond the structural keys.
  # Presentation only: style, and the SVG geometry and paint attributes.
  # Nothing that loads a resource, runs a script, or submits a form. A tag
  # outside the list draws as a div, an attribute outside it is dropped.
  @block_tags Compos.Ui.ComposML.domain_elements() ++ Compos.Ui.ComposML.elements() ++ ~w(div span pre kbd p h1 h2 h3 h4 table thead tbody tr th td ul ol li details summary button
                 svg g path rect circle ellipse line polyline polygon text tspan title img)
  @block_attrs ~w(path bytes mtime permissions mark mode source profile field record-id query unread marked message-id content-type part-id name face state level role aria-level modified folded value max unit kind target glyph style d viewBox preserveAspectRatio fill stroke stroke-width
                  stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin
                  stroke-opacity fill-opacity fill-rule opacity x y x1 y1 x2 y2 cx cy r rx ry
                  width height points transform vector-effect text-anchor font-size
                  dominant-baseline shape-rendering title colspan rowspan src alt
                  author call verbosity aria-label aria-hidden)

  defp semantic_line(%{fields: []} = assigns) do
    ~M"""
    <.seg :for={{{txt, cls}, sx} <- Enum.with_index(@segs)} id={"#{@id_prefix}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} />
    """
  end

  defp semantic_line(assigns) do
    {segments, _} =
      Enum.map_reduce(assigns.segs, assigns.start, fn {txt, cls}, at ->
        {{at, at + byte_size(txt), txt, cls}, at + byte_size(txt)}
      end)

    stop =
      case List.last(segments) do
        nil -> assigns.start
        {_, b, _, _} -> b
      end

    fields = Enum.filter(assigns.fields, fn {a, b, _} -> a < stop and b > assigns.start end)
    # A field range is bytes, and it can end inside a multi-byte character:
    # a list row draws box characters, and the column the block declares
    # lands on the second byte of one. The binary_part below then cuts a
    # segment that is not valid UTF-8, and Jason kills the LiveView socket
    # when it encodes the reply. Snap every boundary down to a character
    # boundary first. The tiling holds, because floor_utf8 keeps
    # assigns.start and stop fixed.
    line = Enum.map_join(segments, &elem(&1, 2))
    snap = fn at -> assigns.start + Text.floor_utf8(line, at - assigns.start) end
    boundaries = ([assigns.start, stop] ++ Enum.flat_map(fields, fn {a, b, _} -> [max(a, assigns.start), min(b, stop)] end)) |> Enum.map(snap) |> Enum.uniq() |> Enum.sort()
    pieces = for [a, b] <- Enum.chunk_every(boundaries, 2, 1, :discard), a < b do
      field = Enum.find_value(fields, fn {x, y, field} -> if x <= a and b <= y, do: field end)
      segs = for {x, y, txt, cls} <- segments, x < b and y > a, do: {binary_part(txt, max(x, a) - x, min(y, b) - max(x, a)), cls}
      prefix = for {x, y, txt, _} <- segments, x < a, do: binary_part(txt, 0, min(y, a) - x)
      %{field: field, segs: segs, col: String.length(Enum.join(prefix)), width: max(1, String.length(Enum.map_join(segs, &elem(&1, 0))))}
    end
    assigns = assigns |> assign(:pieces, pieces) |> assign(:direct, Map.get(assigns, :direct, false))
    ~M"""
    <%= for {piece, px} <- Enum.with_index(@pieces) do %><%= if piece.field do %><%= if @direct do %><.direct_field id_prefix={"#{@id_prefix}-#{px}"} field={piece.field} segs={piece.segs} col={piece.col} width={piece.width} base={@base} win={@win} /><% else %><.dynamic_tag tag_name={piece.field.tag} {piece.field.attrs} class={piece.field.class}><.seg :for={{{txt, cls}, sx} <- Enum.with_index(piece.segs)} id={"#{@id_prefix}-#{px}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /></.dynamic_tag><% end %><% else %><%= unless @direct do %><.seg :for={{{txt, cls}, sx} <- Enum.with_index(piece.segs)} id={"#{@id_prefix}-#{px}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /><% end %><% end %><% end %>
    """
  end

  # Uniform field styling belongs on the domain element itself. Only mixed
  # cursor/face runs need inner spans.
  defp direct_field(assigns) do
    classes = assigns.segs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assigns = assign(assigns, uniform: length(classes) == 1, face_class: List.first(classes) || "",
      text: Enum.map_join(assigns.segs, &elem(&1, 0)))
    ~M"""
    <.dynamic_tag tag_name={@field.tag} {@field.attrs} data-col={@col} style={"--field-column: #{@col + 1}; --field-width: #{@width}"} class={Enum.join(Enum.reject([@field.class, if(@uniform, do: @face_class)], &(&1 in [nil, ""])), " ")}><%= if @uniform do %>{@text}<% else %><.seg :for={{{txt, cls}, sx} <- Enum.with_index(@segs)} id={"#{@id_prefix}-#{sx}"} txt={txt} cls={cls} base={@base} win={@win} /><% end %></.dynamic_tag>
    """
  end

  # Wrap existing lines without introducing layout boxes or replacing text nodes.
  defp peek_text(assigns) do
    ~M"""
    <.dynamic_tag tag_name={block_root(Map.get(@node, :text_root)).tag}
      {block_root(Map.get(@node, :text_root)).attrs} class="peek-text">
      <%= for group <- semantic_line_groups(@node.lines, @node.semantic_records) do %>
        <.dynamic_tag tag_name={group.tag} {group.attrs} class="semantic-record">
          <c-text :for={ln <- group.lines}
            class={"line line-content #{if group.direct, do: "semantic-direct"}"}>
            <.semantic_line id_prefix={"peek-#{@node.id}-#{ln.num}"} segs={ln.segs}
              start={ln.start} fields={group.fields} base={@node.buffer} win={@node.id} direct={group.direct} />
          </c-text>
        </.dynamic_tag>
      <% end %>
    </.dynamic_tag>
    """
  end

  defp semantic_line_groups(lines, records) do
    records = for [start, stop, pl] <- records || [], is_integer(start) and is_integer(stop), do: {start, stop, block_view(pl)}
    {tagged, _} = Enum.map_reduce(lines, records, fn line, remaining ->
      remaining = Enum.drop_while(remaining, fn {_, stop, _} -> stop <= line.start end)
      block = case remaining do
        [{start, _, block} | _] when start <= line.start -> Map.put(block, :record_start, start)
        _ -> %{tag: "c-group", attrs: [], fields: [], direct: false}
      end
      {{block, line}, remaining}
    end)
    tagged
    |> Enum.chunk_by(fn {block, _} -> {block.tag, block.attrs, Map.get(block, :record_start)} end)
    |> Enum.map(fn [{block, _} | _] = chunk ->
      %{tag: block.tag, attrs: block.attrs, fields: block.fields, direct: block.direct, lines: Enum.map(chunk, &elem(&1, 1))}
    end)
  end

  defp block_root(pl) do
    block = block_view(pl || [])
    %{tag: if(block.tag == "div", do: "c-buffer", else: block.tag), attrs: block.attrs, class: block.class}
  end

  defp block_view(pl) do
    %{block_node(pl) | children: Enum.map(pget(pl, "children") || [], &block_view/1)}
  end

  # One block without its children. The keys past `attrs` are the kinds
  # a mode may use: `range` draws the buffer's own bytes in a `format`,
  # `open` is a disclosure's state, `isolate` draws the children in their
  # own component, `follow` keeps that list at its tail, `input` is the
  # caret input and `hint` the words it shows while empty, `file` is a
  # local picture.
  defp block_node(pl) do
    tag = pget(pl, "tag") || "div"

    %{
      tag: if(tag in @block_tags, do: tag, else: "div"),
      direct: pget(pl, "layout") == "columns",
      fields: for([a, b, field] <- pget(pl, "fields") || [], is_integer(a) and is_integer(b) and a < b, do: {a, b, block_view(field)}),
      class: pget(pl, "class") || "",
      anchor: falsy(pget(pl, "anchor")),
      lines: falsy(pget(pl, "lines")),
      mark: falsy(pget(pl, "mark")),
      click: falsy(pget(pl, "click")),
      text: falsy(pget(pl, "text")),
      segs: for([c, t | _] <- pget(pl, "segs") || [], do: {c, t}),
      semantic_segs: for([c, t | tags] <- pget(pl, "segs") || [], do: {c, t, if(List.first(tags) in @block_tags, do: List.first(tags), else: "c-text")}),
      attrs: block_attrs(pget(pl, "attrs") || []),
      children: [],
      range: block_range(pget(pl, "range")),
      format: pget(pl, "format"),
      html: nil,
      empty: false,
      open: pget(pl, "open") == true,
      isolate: pget(pl, "isolate") == true,
      follow: pget(pl, "follow") == true,
      input: pget(pl, "input") == true,
      hint: falsy(pget(pl, "hint")),
      file: falsy(pget(pl, "file"))
    }
  end

  defp block_input?(%{input: true}), do: true
  defp block_input?(%{children: cs}), do: Enum.any?(cs, &block_input?/1)

  defp block_marks?(%{mark: m, lines: l}) when is_binary(m) and is_list(l), do: true
  defp block_marks?(%{children: cs}), do: Enum.any?(cs, &block_marks?/1)

  defp block_range([a, b]) when is_integer(a) and is_integer(b) and a <= b, do: {a, b}
  defp block_range(_), do: nil

  # A tree as the window draws it: every range filled from TEXT, every
  # isolated list's children kept in MEMO by position, plist and bytes.
  # The accumulator is {last range end, the memo for the next build}.
  defp blocks_build(raw, text, memo, win) do
    Enum.map_reduce(raw, {0, %{}}, &block_build(&1, text, {memo, win}, &2))
  end

  defp block_build(pl, text, memo, acc) when not is_tuple(memo),
    do: block_build(pl, text, {memo, nil}, acc)

  defp block_build(pl, text, {memo, win}, acc) do
    view = block_node(pl)
    {span, fresh} = acc
    span = if view.range, do: max(span, elem(view.range, 1)), else: span
    raw_children = pget(pl, "children") || []

    {children, acc} =
      if view.isolate,
        do:
          isolated_children(
            raw_children,
            pget(pl, "index-base") || 0,
            text,
            {memo, win},
            {span, fresh}
          ),
        else: Enum.map_reduce(raw_children, {span, fresh}, &block_build(&1, text, {memo, win}, &2))

    {block_fill(%{view | children: Enum.reject(children, & &1.empty)}, text), acc}
  end

  # BASE is the first child's place in the whole list. A mode that draws
  # only the tail of a long list (the chat transcript window) passes it,
  # so an index names the same block while the window moves: the memo key
  # holds, and the reader's saved place still finds its block.
  defp isolated_children(raw_children, base, text, {memo, win}, acc) do
    raw_children
    |> Enum.with_index(base)
    |> Enum.map_reduce(acc, fn {c, i}, {span, fresh} ->
      ranges = block_ranges(c, [])
      key = {i, c, Enum.map(ranges, fn {a, b} -> Text.slice(text, a, b) end)}

      view =
        case Map.get(memo, key) do
          nil ->
            {v, _} = block_build(c, text, {%{}, win}, {0, %{}})
            v = %{v | attrs: v.attrs ++ [{"data-index", Integer.to_string(i)}]}
            Map.put(v, :frozen, frozen_html(v, win))

          v ->
            v
        end

      span = Enum.reduce(ranges, span, fn {_, b}, m -> max(m, b) end)
      {view, {span, Map.put(fresh, key, view)}}
    end)
  end

  # A list child drawn once, as HTML: the list component then holds one
  # string per child, and a changed list re-sends only strings it has.
  defp frozen_html(%{empty: true}, _win), do: ""

  defp frozen_html(view, win) do
    %{b: view, line: -1, win: win, ctx: %{}, __changed__: nil}
    |> blk_node()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp block_ranges(pl, acc) do
    acc =
      case block_range(pget(pl, "range")) do
        nil -> acc
        r -> [r | acc]
      end

    Enum.reduce(pget(pl, "children") || [], acc, &block_ranges/2)
  end

  # Fill a block's range and file. A range that draws nothing and has no
  # children is empty, and the renderer skips it.
  defp block_fill(%{range: {a, b}} = view, text) do
    view =
      case range_content(Text.slice(text, a, b), view.format) do
        {:html, html} -> %{view | html: html}
        {:text, t} -> %{view | text: t}
      end

    %{view | empty: (view.html || view.text || "") == "" and view.children == []}
    |> block_file()
  end

  defp block_fill(view, _text), do: block_file(view)

  defp block_file(%{file: path} = view) when is_binary(path),
    do: %{view | attrs: view.attrs ++ [{"src", LocalImage.url(path)}]}

  defp block_file(view), do: view

  # The formats a range draws in. "text" trims the bytes; "markdown" is
  # prose HTML; the two "mcp-result" formats unwrap a tool result envelope,
  # whole or as its first line.
  defp range_content(t, "markdown"), do: {:html, t |> prose_html() |> wrap_tables()}
  defp range_content(t, "raw"), do: {:text, t}

  defp range_content(t, "mcp-result") do
    body = t |> String.trim_trailing() |> tool_display_body()

    case json_tail(body) do
      nil ->
        {:text, body}

      {head, json} ->
        {:html,
         Compos.Core.Markdown.Html.html_escape(head) <>
           Compos.Core.Markdown.Html.highlight("json", json)}
    end
  end

  defp range_content(t, "mcp-result-line"),
    do: {:text, t |> String.trim_trailing() |> tool_display_body() |> tool_preview()}

  defp range_content(t, _), do: {:text, String.trim(t)}

  # The caret input: the window's text from START to the end, split at
  # point. A point before START draws the caret at the end.
  defp caret_input(_leaf, nil), do: nil

  defp caret_input(leaf, start) do
    start = start |> min(byte_size(leaf.text)) |> max(0)
    live = binary_part(leaf.text, start, byte_size(leaf.text) - start)

    rel =
      if leaf.point >= start do
        (leaf.point - start) |> min(byte_size(live)) |> then(&Text.floor_utf8(live, &1))
      else
        byte_size(live)
      end

    rest = binary_part(live, rel, byte_size(live) - rel)

    case String.next_grapheme(rest) do
      nil -> %{pre: live, cur: " ", post: ""}
      {g, more} -> %{pre: binary_part(live, 0, rel), cur: g, post: more}
    end
  end

  # What the top of a block tree hands down: the list component's buffer
  # and reader place, the caret input, and the completion at point.
  defp blk_ctx(node, active?, completion) do
    %{
      live: true,
      buf: node.buffer,
      follow: Map.get(node, :blocks_follow),
      input: Map.get(node, :blk_input),
      cursor: Map.get(node, :cursor_visible, true),
      completion: active? && completion
    }
  end

  defp block_attrs(attrs) when is_list(attrs) do
    for [name, value] <- attrs,
        is_binary(name) and name in @block_attrs,
        is_binary(value) or is_number(value),
        do: {name, to_string(value)}
  end

  defp block_attrs(_), do: []

  defp pget([{:sym, k}, v | _], k), do: v
  defp pget([_, _ | rest], k), do: pget(rest, k)
  defp pget(_, _), do: nil

  defp falsy(false), do: nil
  defp falsy(v), do: v

  # A table always shrinks to the width it is given, and then clips what
  # does not fit. So the scrollbar must sit on an element OUTSIDE the
  # table. The renderer emits a bare <table>; give each one a box to scroll in.
  defp wrap_tables(html) do
    html
    |> String.replace(~r/<table(?=[\s>])/, ~s(<div class="ag-table"><table))
    |> String.replace("</table>", "</table></div>")
  end

  @doc false
  # Preview folds keep source byte offsets stable. Hidden lines become spaces.
  # A closing fence stays present so the Markdown tree remains valid.
  defp preview_fold_source("markdown", text, point, mark, hidden) do
    fences = if MapSet.size(hidden) == 0, do: MapSet.new(), else: fence_lines(text)

    folded =
      text
      |> String.split("\n", trim: false)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, index} ->
        if MapSet.member?(hidden, index) and not MapSet.member?(fences, index) do
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

  # the line index of every fence delimiter the Markdown grammar finds
  defp fence_lines(text) do
    for {_, s, _} <-
          Compos.Core.TS.ts_query_nif("markdown", text, "(fenced_code_block_delimiter) @d"),
        into: MapSet.new(),
        do: Compos.Core.Text.line_index(text, s)
  end

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

  # The page is Markdown.Html's; the LiveView keeps the parse cache.
  # Parsing a document costs a hundred times what drawing it does, and the
  # tree does not change when the caret moves. So the tree is cached against
  # the buffer's version: a keystroke that moves point redraws and nothing
  # more, and only an edit parses again.
  defp render_preview("markdown" = rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} =
      preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)

    leaf = %{leaf | text: text}
    key = {leaf.buffer, leaf.version, leaf.hidden_lines, leaf.overlays}
    {tree, cache} = md_tree(leaf, key, cache)

    html =
      Compos.Core.Markdown.Html.document(
        leaf.text,
        pt,
        mark,
        faces,
        preview_opts(leaf.buffer) ++
          [
            tree: tree,
            overlays: leaf.overlays,
            whitespace: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true,
            hidden_lines: leaf.hidden_lines
          ]
      )

    {html, cache}
  end

  defp render_preview(rm, leaf, pt, mark, faces, cache) do
    {text, pt, mark} = preview_fold_source(rm, leaf.text, pt, mark, leaf.hidden_lines)
    {preview_doc(rm, text, pt, mark, faces, leaf.preview_authored, leaf.overlays), cache}
  end

  # What only the web client knows: how a local path becomes a URL the
  # page can load, and how an X post becomes a card.
  defp preview_opts(buffer) do
    [
      base_dir: preview_dir(buffer),
      csv_source: csv_source_reader(buffer),
      local_url: &Compos.Ui.LocalImage.url/1,
      tweet_card: &Compos.Ui.Oembed.card/1
    ]
  end

  @doc """
  A preview page with this client's image and card hooks. Markdown draws
  through `Compos.Core.Markdown.Html.document/5`; an html buffer through
  `Compos.Core.Markdown.Html.html_document/3`.
  """
  def preview_doc(rm, text, point, faces, authored),
    do: preview_doc(rm, text, point, nil, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored),
    do: preview_doc(rm, text, point, mark, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored, overlays),
    do: preview_doc(rm, text, point, mark, faces, authored, overlays, [])

  def preview_doc("markdown", text, point, mark, faces, _authored, overlays, opts) do
    ui = [local_url: &Compos.Ui.LocalImage.url/1, tweet_card: &Compos.Ui.Oembed.card/1]
    opts = Keyword.merge(ui, opts) ++ [overlays: overlays]
    Compos.Core.Markdown.Html.document(text, point, mark, faces, opts)
  end

  def preview_doc(_rm, text, _point, _mark, faces, authored, _overlays, _opts),
    do: Compos.Core.Markdown.Html.html_document(text, faces, authored)

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
        case Compos.Core.Markdown.Html.parse(leaf.text, leaf.overlays) do
          {:ok, tree} -> {tree, Map.put(cache, {:md_tree, leaf.id}, {tree_key, tree})}
          {:error, _} -> {nil, cache}
        end
    end
  end

  # The mode line's facts, as Scheme built them: a list of (KEY VALUE TONE
  # RANK). A row of another shape is skipped, never a crash in the render.
  defp ml_facts(%{modeline_facts: facts}) when is_list(facts) do
    for [k, v, tone, rank] <- facts,
        do: {to_string(k), to_string(v), to_string(tone), to_string(rank)}
  end

  defp ml_facts(_node), do: []

  # the modeline names the buffer the short way; the tooltip keeps the
  # absolute path. Scheme decides what short means (project.scm).
  # The buffer-name grammar (editor.scm) draws the name: Scheme names the
  # classes and the client draws one span each. A buffer whose dashboard
  # has not synced yet carries no segments, and shows the plain name.
  defp ml_segs(%{modeline_name_segments: segs}) when is_list(segs) do
    for [c, t] <- segs, is_binary(c), is_binary(t), do: {c, t}
  end

  defp ml_segs(_), do: []

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

  # The mode-line format: the buffer's own, else the frame default the
  # chrome carries. Each construct is (NAME ARG ...).
  defp ml_format(node) do
    case Map.get(node, :mode_line_format) do
      [_ | _] = format -> for [name | args] <- format, is_binary(name), do: {name, args}
      _ -> []
    end
  end

  defp ml_arg([text | _]) when is_binary(text), do: text
  defp ml_arg(_), do: ""

  # (position SEGS PTY-SEGS): a terminal draws no lines, so it has its own
  # segments. A segment is (CLASS TEXT); an empty class is a bare text node.
  defp ml_position(args, node) do
    segs = if node.render_mode == "terminal", do: Enum.at(args, 1), else: Enum.at(args, 0)

    for [cls, txt] <- List.wrap(segs), is_binary(cls), is_binary(txt),
        do: {cls, ml_fill(txt, node)}
  end

  # the %-constructs of Emacs's mode-line-format that the view alone knows
  defp ml_fill(text, node) when is_binary(text) do
    Regex.replace(~r/%[Ilcp%]/, text, fn
      "%I" -> ml_bytes(node.text)
      "%l" -> to_string(node.line)
      "%c" -> to_string(node.col)
      "%p" -> pct(node)
      "%%" -> "%"
    end)
  end

  defp ml_fill(_text, _node), do: ""

  # popup anchor column in ch units (monospace): graphemes from line start
  # to the completion region start
  defp completion_doc(candidate) do
    case List.keyfind(Map.get(candidate, :facts, []), "Documentation", 0) do
      {_, doc} -> doc
      nil -> "No documentation available."
    end
  end

  defp pop_col(text, line_start, comp_start) do
    len = comp_start |> max(line_start) |> min(byte_size(text))
    text |> binary_part(line_start, len - line_start) |> String.length()
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)

end
