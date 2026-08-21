defmodule Aimax.Ui.EditorLive do
  @moduledoc """
  The window: renders the tiling window tree per line (numbers, hl-line,
  cursor/region spans), modelines, which-key, the vertico-style minibuffer and
  echo area; forwards every keystroke to `Aimax.Core.KeyDispatch`.

  Pure view — no editor logic here. Re-renders on editor-state events and on
  change events of any visible buffer (so RPC/agent edits appear live).
  """

  use Phoenix.LiveView

  alias Aimax.Core.{Events, Input}
  alias Aimax.Scheme.Text
  alias Aimax.Ui.AppServer

  @impl true
  def mount(params, _session, socket) do
    # each browser TAB is a frame (S5): the client sends its remembered
    # frame id (sessionStorage, per tab) in the connect params; unknown
    # ids are honored so the frame survives a wiped desktop.etf, absent
    # ids get a fresh frame. The id rides the payload as data-frame —
    # there is no separate frame event (S13).
    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Aimax.Core.Editor.attach_frame(requested)
      Events.subscribe_frame(fid)

      # a buffer link (/b/NAME?line=N) shows that buffer in this frame.
      # What "show" means — an open buffer, a file to visit, a line to go
      # to — is Scheme's open-buffer-link!, not this view's.
      if buffer = params["buffer"] do
        Input.run(fid, fn ->
          Aimax.Core.Session.call_named("open-buffer-link!", [buffer, line_param(params)])
        end)
      end

      if params["daemon-switch"] == "1" do
        Input.run(fid, fn ->
          Aimax.Core.Session.eval("(when (boundp 'daemon-arrived!) (daemon-arrived!))")
        end)
      end

      socket =
        assign(socket,
          frame: fid,
          subscribed: MapSet.new(),
          line_cache: %{},
          boot_id: :persistent_term.get(:aimax_boot_id, "dev")
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
         boot_id: :persistent_term.get(:aimax_boot_id, "dev")
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

  # one handler for every click that runs a command: a transcript button
  # sends a command name, the modeline-info segment sends its buffer.
  # The Scheme gate ui-command! holds the whitelist — no policy here.
  def handle_event("ui_cmd", %{"win" => win} = params, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Editor.set_active(id)

        Aimax.Core.Session.call_named("ui-command!", [
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
        Aimax.Core.Editor.set_active(wid)

        Aimax.Core.Session.call_named("agent-card-toggle!", [
          Aimax.Core.Editor.current_buffer(),
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
        Aimax.Core.Editor.set_active(wid)
        Aimax.Core.Session.call_named("agent-answer-question!", [slug, qid, answer])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the transcript follow flag and reader position (S7): runtime locals,
  # so a refresh keeps the reader's place and a restart resets to follow
  def handle_event("ag_stick", %{"buf" => buf, "stick" => stick, "top" => top}, socket)
      when is_boolean(stick) and is_integer(top) do
    if Aimax.Core.Buffer.exists?(buf) do
      # inverted on purpose: the cleared (#f) local must mean "follow"
      Aimax.Core.Buffer.set_local(buf, "agent-unstick", not stick)
      Aimax.Core.Buffer.set_local(buf, "agent-scroll-top", top)
    end

    {:noreply, socket}
  end

  # clicking a block that carries a click id. The id is the mode's own
  # word; the view hands it back and knows nothing else. diff-mode
  # registered the handler with block-on-click!.
  def handle_event("block_click", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Editor.set_active(wid)
        Aimax.Core.SchemeAPI.block_click(Aimax.Core.Editor.current_buffer(), id)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a client-scrolled window reporting its pixel offset (S1) — a passive
  # mirror into the leaf, so refresh and restart give the place back
  def handle_event("cscroll", %{"win" => win, "top" => top}, socket) when is_integer(top) do
    with id when is_integer(id) <- safe_int(win) do
      Aimax.Core.Editor.set_client_top(id, top, socket.assigns.frame)
    end

    {:noreply, socket}
  end

  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Aimax.Core.Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window row counts: line height varies per buffer (per-buffer styles),
  # so the client measures each window against its own lines
  def handle_event("win_rows", %{"rows" => rows}, socket) when is_map(rows) do
    parsed =
      for {id, n} <- rows, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    Aimax.Core.Editor.set_window_rows(parsed, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window column counts: the table views lay out in characters, so
  # the client measures its own font and says how many fit
  def handle_event("win_cols", %{"cols" => cols}, socket) when is_map(cols) do
    parsed =
      for {id, n} <- cols, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    if Aimax.Core.Editor.set_window_cols(parsed, socket.assigns.frame) do
      # a window that changed width is a window configuration change: the
      # editor says so, and Scheme decides what has to be drawn again
      Aimax.Core.Session.eval("(when (boundp 'window-config-changed!) (window-config-changed!))")

      {:noreply, socket |> drain() |> refresh()}
    else
      {:noreply, socket}
    end
  end

  # wheel scrolls the hovered window when the client identified one,
  # falling back to this frame's active window
  def handle_event("scroll", %{"lines" => lines} = params, socket) when is_integer(lines) do
    case safe_int(params["win"]) do
      win when is_integer(win) -> Aimax.Core.Editor.scroll_window(win, lines)
      _ -> Aimax.Core.Editor.scroll_active(lines, socket.assigns.frame)
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
            Aimax.Core.Session.eval("(begin (mouse-select-window! #{id}) (set-mark! #f))")
            Aimax.Core.Editor.mouse_goto(id, line, col)

          _ ->
            Aimax.Core.Session.eval("(mouse-select-window! #{id})")
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a click or a visual-line key inside a markdown preview's iframe: the
  # hook sends the text node split at the caret, how many times that text
  # comes before it on the page, and which way the key moves. Scheme finds
  # the spot in the source.
  def handle_event("preview_goto", %{"win" => win} = p, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        command = if p["extend"] == true, do: "preview-select!", else: "preview-goto!"

        Aimax.Core.Session.call_named(command, [
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

  defp count_arg(n) when is_integer(n) and n >= 0, do: n
  defp count_arg(_), do: 0

  defp dir_arg(d) when d in [-1, 0, 1], do: d
  defp dir_arg(_), do: 0

  def handle_event("preview_goto_pos", %{"win" => win, "pos" => pos} = p, socket)
      when is_integer(pos) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Session.call_named("preview-goto-pos!", [id, pos, p["extend"] == true])
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
        Aimax.Core.Session.eval("(mouse-select-window! #{id})")
        Aimax.Core.Editor.mouse_region(id, al, ac, fl, fc)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # system clipboard: Cmd-V arrives as a browser paste event
  def handle_event("paste", %{"text" => text}, socket) when is_binary(text) do
    Input.run(socket.assigns.frame, fn ->
      Aimax.Core.Session.eval("(clipboard-paste! #{scheme_string(text)})")
    end)

    {:noreply, socket |> drain() |> refresh()}
  end

  # Cmd-C with no native selection: reply with the region (or kill top)
  # for the client to put on the OS clipboard — what "copy" MEANS is
  # Scheme's (clipboard-copy), like paste (S12, dup #26)
  def handle_event("copy", _params, socket) do
    text =
      Input.run(socket.assigns.frame, fn ->
        case Aimax.Core.Session.call_named("clipboard-copy", []) do
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

  defp refresh(socket) do
    fid = socket.assigns[:frame]
    state = Aimax.Core.Editor.render_state(fid)

    # our frame was deleted out from under us (M-x delete-frame elsewhere,
    # RPC): render_state fell back to another frame — recreate ours fresh
    # under the same id so the client's stored id stays good
    state =
      if fid && state.frame != fid do
        {:ok, ^fid} = Aimax.Core.Editor.attach_frame(fid)
        Aimax.Core.Editor.render_state(fid)
      else
        state
      end

    {tree, line_cache} = decorate(state.tree, socket.assigns.line_cache, state.faces)
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
        visible = state.tree |> visible_buffers() |> MapSet.new()

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
      case fid && Aimax.Core.Editor.take_clipboard(fid) do
        text when is_binary(text) -> push_event(socket, "clipboard", %{text: text})
        _ -> socket
      end

    case fid && Aimax.Core.Editor.take_navigation(fid) do
      url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
      _ -> socket
    end
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

  # two-level cache: the raw line split is keyed by buffer VERSION only, so
  # cursor motion never re-splits the buffer; span decoration (cursor/region/
  # hl-line) is recomputed per render but only for lines it actually touches
  defp decorate(%{type: :split} = split, cache, faces) do
    {children, cache} = Enum.map_reduce(split.children, cache, &decorate(&1, &2, faces))
    {%{split | children: children}, cache}
  end

  # preview buffers skip the line machinery entirely; the theme is baked into
  # the srcdoc (the sandboxed iframe can't see the parent's CSS vars).
  # markdown keys on point too: the preview is editable, so the reader must
  # see where the next keystroke lands. html does not — an authored
  # document gets no marker injected into it.
  defp decorate(%{type: :leaf, render_mode: rm} = leaf, cache, faces)
       when rm in ["html", "markdown"] do
    pt = if rm == "markdown", do: leaf.point, else: 0
    mark = if rm == "markdown", do: leaf.mark, else: nil

    # the oembed generation moves when a tweet fetch lands, so the cached
    # placeholder misses and the card renders
    key =
      {leaf.buffer, leaf.version, rm, leaf.preview_authored, :erlang.phash2(faces), pt, mark,
       :erlang.phash2(leaf.overlays), Aimax.Ui.Oembed.generation()}

    html =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> html
        _ -> preview_doc(rm, leaf.text, pt, mark, faces, leaf.preview_authored, leaf.overlays)
      end

    {Map.merge(leaf, %{lines: [], preview: html}),
     Map.put(cache, {:preview, leaf.id}, {key, html})}
  end

  # an app is not rendered here at all: the app origin serves it, and the
  # window holds only the frame that points at it
  defp decorate(%{type: :leaf, render_mode: "app"} = leaf, cache, _faces) do
    {Map.merge(leaf, %{lines: [], app_url: AppServer.app_url(leaf.buffer, leaf.app_gen)}), cache}
  end

  # rich agent transcript: blocks (from agent.scm's block model) become
  # typed DOM — serif prose, tool cards, permission buttons. The buffer
  # text stays canonical; this is a pure view over byte ranges.
  defp decorate(%{type: :leaf, render_mode: "agent", agent: %{} = ag} = leaf, cache, _faces) do
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
       ag_activity: Map.get(ag, :activity)
     }), Map.put(cache, {:agent, leaf.id}, entry)}
  end

  # rich diff: the buffer text IS the unified diff, so the cards are parsed
  # out of the same bytes the plain view shows. Only the controlled state —
  # which cards are open, git's status letters — rides the payload.
  # a generic block tree the mode composed. This clause converts plists to
  # maps and finds the buffer line point is on; it does not know what any
  # block means.
  defp decorate(%{type: :leaf, render_mode: "blocks"} = leaf, cache, _faces) do
    raw = Map.get(leaf, :blocks) || []
    key = {leaf.buffer, leaf.version, :erlang.phash2(raw)}

    blocks =
      case cache[{:blocks, leaf.id}] do
        {^key, blocks} -> blocks
        _ -> Enum.map(raw, &block_view/1)
      end

    line = Aimax.Core.Text.line_index(leaf.text, leaf.point) + 1

    {Map.merge(leaf, %{lines: [], blk: blocks, blk_line: line}),
     Map.put(cache, {:blocks, leaf.id}, {key, blocks})}
  end

  # below this many lines, ship the whole buffer once and let the browser
  # own scroll position natively — build_static already computes every
  # line regardless of size, so this is purely a display decision, not
  # new server work. Above it, keep the windowed/virtualized path: DOM
  # node count and per-render diff cost both scale with what we ship.
  @ship_all_threshold 3000

  defp decorate(%{type: :leaf} = leaf, cache, _faces) do
    raw_key = {leaf.buffer, leaf.version, leaf.ts_lang, leaf.overlay_gen}

    static =
      case cache[leaf.id] do
        {^raw_key, static} -> static
        _ -> build_static(leaf)
      end

    # viewport: folded lines drop out, then (for large buffers) only the
    # visible slice (+overscan) becomes DOM. leaf.top is in visible-line
    # space.
    hidden = leaf.hidden_lines
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
          static |> Tuple.to_list() |> Enum.reject(&MapSet.member?(hidden, &1.num - 1))

        MapSet.size(hidden) == 0 ->
          # static is a tuple: elem/2 is O(1), so a deep scroll position
          # costs the same as line 1 — Enum.slice on a list re-walks from
          # element 0 every tick, so cost grows with leaf.top as you scroll
          first = min(leaf.top, size)
          last = min(first + want, size) - 1
          if last < first, do: [], else: for(i <- first..last, do: elem(static, i))

        true ->
          # a fold can drop any line, so which raw index is the leaf.top-th
          # VISIBLE one can't be found without walking the folded sequence —
          # correctness over micro-perf here; folds are the uncommon case
          static
          |> Tuple.to_list()
          |> Enum.reject(&MapSet.member?(hidden, &1.num - 1))
          |> Enum.slice(leaf.top, want)
      end

    lines =
      visible
      |> render_pass(leaf.text, leaf.point, leaf.mark)
      |> Enum.map(fn ln ->
        # a visible line whose successor is folded gets a fold marker
        if MapSet.member?(hidden, ln.num),
          do: %{ln | segs: ln.segs ++ [{" …", "f-fold-marker"}]},
          else: ln
      end)

    leaf = Map.put(leaf, :client_scroll?, client_scroll?)
    {Map.put(leaf, :lines, lines), Map.put(cache, leaf.id, {raw_key, static})}
  end

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
        nil ->
          []

        _lang ->
          leaf.buffer
          |> Aimax.Core.Buffer.ts_highlight()
          |> Enum.with_index()
          |> Enum.map(fn {{s, e, scope}, i} -> {s, e, "ts-" <> scope, i} end)
      end

    ovs = Enum.map(leaf.overlays, fn {s, e, face} -> {s, e, "f-" <> face} end)

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

  defp visible_buffers(%{type: :leaf, buffer: b}), do: [b]
  defp visible_buffers(%{type: :split, children: c}), do: Enum.flat_map(c, &visible_buffers/1)

  defp safe_int(v) when is_integer(v), do: v

  defp safe_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # --- rendering -------------------------------------------------------------

  @impl true
  # the disconnected mount is not a client: it attaches no frame and
  # renders a neutral splash — the connected mount replaces it (S14)
  def render(%{state: nil} = assigns) do
    ~H"""
    <div id="editor" class="editor-root splash" phx-hook="Keys" data-boot={@boot_id}>
      <div style="display:flex;align-items:center;justify-content:center;height:100vh;opacity:.5;font-family:monospace">
        ai-max — connecting…
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="editor" class="editor-root" phx-hook="Keys" data-boot={@boot_id} data-frame={@frame}>
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
      <div class="windows">
        <.tree node={@state.tree} active={@state.active} completion={@state.completion} />
      </div>
      <div :if={@state.which_key && @state.minibuffer == nil && @state.transient == nil} class="which-key">
        <div class="wk-title">{Enum.join(@state.pending, " ")} —  {length(@state.which_key)} bindings</div>
        <div class="wk-grid">
          <div :for={w <- @state.which_key} class="wk-item">
            <span class="wk-key">{w.key}</span>
            <span class="wk-arrow">→</span>
            <span class="wk-cmd">{w.command}</span>
          </div>
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
                    <span class="mb-label">{c.label}</span>
                    <span class="mb-hint">{c.hint}</span>
                  </div>
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
            <span class="mb-count">{count_text(@state.minibuffer)}</span>
          </div>
        </div>
        <div class="echo-bar">
          <span class="echo">{@state.echo}</span>
          <span class="mb-spacer"></span>
        </div>
      <% else %>
        <%= if @state.transient do %>
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
          <div class="echo-bar">
            <span class="echo">{@state.echo}</span>
            <span class="mb-spacer"></span>
          </div>
        <% else %>
          <div class="echo-bar">
            <span class="echo">{@state.echo}</span>
            <span class="mb-spacer"></span>
            <span :if={@state.modeline_extra != ""} class="ml-extra">{@state.modeline_extra}</span>
            <span class="echo-hint" :if={@state.echo == ""}>C-x C-f · C-x b · C-x d · C-c a n agent · M-x · C-g</span>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp workspace_port(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> "?"
    end
  end

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

  defp tree(%{node: %{type: :leaf}} = assigns) do
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
      class={"window #{if @active?, do: "active", else: "inactive"} #{if !@node.line_numbers, do: "no-nums"} #{@node.window_class}"}
      style={@node.window_style}
      data-win-id={@node.id}
      data-path={@path}
      data-read-only={to_string(@read_only)}
    >
      <div :if={@node.header_line} class="buffer-header">{@node.header_line}</div>
      <div :if={@node.dash} class="dash-top">
        <div class="dash-live">
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
                <div class="dash-big">{@node.mode}</div>
                <div :if={@node.minor_modes != []} class="dash-chips">
                  <span :for={m <- @node.minor_modes} class="dash-chip">{m}</span>
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
          phx-hook="AgentScroll"
          data-buf={@node.buffer}
          data-stick={to_string(@node.agent.stick)}
          data-scroll-top={@node.agent.scroll_top}
        >
          <%!-- the transcript is its own component so a keystroke in the
               input row diffs to a skip placeholder: the client must not
               walk one DOM node per block of the whole conversation per
               key. blocks comes from the decorate cache, so the list is
               reference-equal until the block model changes. --%>
          <.live_component
            module={Aimax.Ui.AgentTranscript}
            id={"agtx-#{@node.id}"}
            blocks={@node.ag_blocks}
            win={@node.id}
          />
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
          data-win={@node.id}
          data-ctop={@node.ctop}
          data-pt={@node.point}
          data-rm={@node.render_mode}
          data-visual-lines={to_string(@node.visual_line_mode)}
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
      >
        <div
          :for={ln <- @lines}
          id={"ln-#{@node.id}-#{ln.num}"}
          class={"line #{if ln.current, do: "hl-line"}"}
        >
          <span class="linenum">{ln.num}</span>
          <span class="line-content"><.seg :for={{txt, cls} <- ln.segs} txt={txt} cls={cls} /><span
              :if={@active? && @completion && ln.current}
              class="cap-pop"
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
          title="expand (C-x ?)"
          phx-click="ui_cmd"
          phx-value-win={@node.id}
          phx-value-cmd="modeline-expand"
        >{@node.buffer}</span>
        <span class="ml-mode">{@node.mode}<%= if ml_group(@node) do %> · {ml_group(@node)}<% end %><%= if @node.modified do %> · modified<% end %></span>
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
        <span class="ml-pos">{ml_bytes(@node.text)} · L{@line}:C{@col} · {pct(@node)}</span>
      </div>
    </div>
    """
  end

  # --- per-line display list: numbers, hl-line, font-lock + overlays ----------

  defp render_pass(static, text, point, mark) do
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
      current = point >= line.start and point <= le
      touched? = current or (rs != re and rs < le + 1 and re > line.start)

      segs =
        if touched? do
          overlays =
            [
              if(rs != re, do: {rs, re, "region"}),
              if(point < cursor_end, do: {point, cursor_end, "cursor"})
            ]
            |> Enum.reject(&is_nil/1)

          # through line_segs, not seg_build: the cursor's own line takes the
          # same long-line guard as every other one, and on a one-line buffer
          # this is the only line there is
          segs = line_segs(line.part, line.start, line.ts, line.ov ++ overlays)

          # cursor sitting on this line's newline (or at EOF on the last line)
          if point >= line.start and point == le,
            do: segs ++ [{" ", "cursor"}],
            else: segs
        else
          line.segs
        end

      %{num: line.num, current: current, start: line.start, segs: segs}
    end)
  end

  # cut the line at every range boundary; each segment takes the last-wins
  # ts class plus any active overlay classes
  # a seg whose overlay face says img-embed IS an image: the buffer text
  # stays the URL (the buffer is truth), the client draws the picture
  attr :txt, :string, required: true
  attr :cls, :string, required: true

  defp seg(%{cls: cls, txt: txt} = assigns)
       when is_binary(cls) and is_binary(txt) do
    if cls =~ "img-embed" and String.starts_with?(txt, "http") do
      avatar? = String.ends_with?(txt, "#aimax-avatar")

      assigns =
        assign(assigns,
          src: if(avatar?, do: String.trim_trailing(txt, "#aimax-avatar"), else: txt),
          image_class: if(avatar?, do: "img-embed img-avatar", else: "img-embed")
        )

      ~H|<img src={@src} class={@image_class} loading="lazy" />|
    else
      ~H|<span class={@cls}>{@txt}</span>|
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

    html =
      case Earmark.as_html(md, compact_output: false) do
        {:ok, html, _} -> html
        {:error, html, _} -> html
      end

    %{kind: :prose, html: wrap_tables(html)}
  end

  defp ag_block([s, e, "thought" | _], text, _open),
    do: %{kind: :thought, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, e, "tool", id, title, kind, status, body_start | _], text, open_cards) do
    body =
      text
      |> safe_slice(body_start, e)
      |> String.trim_trailing()
      |> tool_display_body()

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
      preview: tool_preview(body)
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

    {pre, cur, post} =
      if leaf.point >= live_start do
        rel =
          (leaf.point - live_start) |> min(byte_size(live)) |> then(&Text.floor_utf8(live, &1))

        rest = binary_part(live, rel, byte_size(live) - rel)

        case String.next_grapheme(rest) do
          nil -> {live, " ", ""}
          {g, more} -> {binary_part(live, 0, rel), g, more}
        end
      else
        {live, "", ""}
      end

    %{pre: pre, cur: cur, post: post}
  end

  # The cursor in a markdown preview: a private-use sentinel goes into the
  # source at POINT, rides through Earmark as plain text, and comes out as
  # the .pt span. If point sits inside markdown syntax the one construct
  # can render off for a moment; the sandbox runs no scripts, so a mangled
  # span is a display blemish and nothing more.
  @pt_sentinel "\uE000"
  @llm_start "\uE002"
  @llm_end "\uE003"
  @llm_meta_end "\uE004"

  @doc false
  def preview_doc(rm, text, point, faces, authored),
    do: preview_doc(rm, text, point, nil, faces, authored, [])

  def preview_doc(rm, text, point, mark, faces, authored),
    do: preview_doc(rm, text, point, mark, faces, authored, [])

  def preview_doc("markdown", text, point, mark, faces, authored, overlays) do
    p = point |> max(0) |> min(byte_size(text))
    m = if is_integer(mark), do: mark |> max(0) |> min(byte_size(text)), else: nil

    marked = mark_preview_positions(text, p, m, overlays)

    preview_html("markdown", marked, faces, authored)
  end

  def preview_doc(rm, text, _point, _mark, faces, authored, _overlays),
    do: preview_html(rm, text, faces, authored)

  defp mark_preview_positions(text, point, mark, overlays) do
    positions =
      [{cursor_spot(text, point), @pt_sentinel}, {mark && cursor_spot(text, mark), "\uE001"}] ++
        preview_overlay_positions(text, overlays)

    positions =
      positions
      |> Enum.reject(fn {at, _} -> is_nil(at) end)
      |> Enum.sort_by(fn {at, _} -> -at end)

    Enum.reduce(positions, text, fn {at, sentinel}, acc ->
      binary_part(acc, 0, at) <> sentinel <> binary_part(acc, at, byte_size(acc) - at)
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

  # Point often sits inside a line's BLOCK marker — byte 0 of "# Title" is
  # where a freshly opened file rests — and a sentinel inside the marker
  # un-headings the line. Snap the cursor to the marker's end. On a fence
  # line, show no cursor at all: a broken fence re-renders the whole
  # document below it.
  defp cursor_spot(text, p) do
    ls =
      case :binary.matches(binary_part(text, 0, p), "\n") do
        [] -> 0
        ms -> ms |> List.last() |> elem(0) |> Kernel.+(1)
      end

    line = text |> binary_part(ls, byte_size(text) - ls) |> String.split("\n", parts: 2) |> hd()

    if line |> String.trim_leading() |> String.starts_with?("```") do
      nil
    else
      case Regex.run(~r/^(?:\s{0,3}(?:\#{1,6}|[-*+]|\d+\.|>)\s+)+/, line, return: :index) do
        [{0, len}] when p < ls + len -> ls + len
        _ -> p
      end
    end
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

  defp preview_html("markdown", text, faces, _authored) do
    body =
      text
      |> Earmark.as_ast(compact_output: false)
      |> case do
        {:ok, ast, _} -> ast
        {:error, ast, _} -> ast
      end
      |> tag_llm_responses()
      |> embed_urls()
      |> Earmark.Transform.transform(compact_output: false)
      |> String.replace(@pt_sentinel, ~s(<span class="pt"></span>))
      |> String.replace("\uE001", ~s(<span class="mk"></span>))

    %{bg: bg, fg: fg, accent: accent, link: link, dim: dim, border: border, inset: inset} =
      preview_palette(faces)

    # typography is policy: the 'preview face carries it (appearance.scm
    # defcustoms; themes and init.scm may set it like any face)
    family = face(faces, "preview", "family", "Spectral,Georgia,serif")
    size = face(faces, "preview", "size", "16.5px")

    """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    body{margin:0 auto;padding:30px 34px 70px;max-width:44em;overflow-wrap:break-word;
         word-break:normal;font:#{size}/1.7 #{family};color:#{fg};background:#{bg}}
    p{margin:0 0 1em}
    h1,h2,h3,h4{font-family:#{family};line-height:1.25;margin:1.4em 0 0.4em}
    body>h1:first-child{margin-top:0}
    h1{font-size:29px}h2{font-size:22px;border-bottom:1px solid #{border};padding-bottom:4px}
    h3{font-size:18px;color:#{accent}}
    code,pre{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;font-size:13.5px}
    code{background:#{inset};padding:1px 4px;border-radius:2px}
    pre{background:#{inset};padding:10px 12px;border-left:3px solid #{accent};overflow-x:auto}
    pre code{background:none;padding:0}
    a,a:visited{color:#{link};text-decoration-thickness:1px;text-underline-offset:2px;
      text-decoration-color:color-mix(in srgb,currentColor 45%,transparent)}
    a:hover{text-decoration-color:currentColor}
    a:empty{display:none}
    blockquote{margin:12px 0;padding:2px 14px;border-left:3px solid #{border};color:#{dim}}
    blockquote.llm-response{margin:18px 0;padding:12px 16px;border:1px solid #{border};
         border-left:4px solid #{accent};border-radius:7px;background:#{inset};color:#{fg};user-select:text}
    blockquote.llm-response>:first-child{margin-top:0}
    blockquote.llm-response>:last-child{margin-bottom:0}
    table{border-collapse:collapse;font-size:14px;display:block;overflow-x:auto;max-width:100%}
    th,td{border:1px solid #{border};padding:5px 9px}
    th{background:#{inset};text-align:left}
    img{max-width:100%;height:auto;border-radius:3px}
    hr{border:0;border-top:1px solid #{border};margin:22px 0}
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
    ::highlight(region){background:color-mix(in srgb,#{accent} 32%,transparent)}
    .pt{display:inline-block;width:2px;height:1.05em;margin:0 -1px;vertical-align:-0.18em;
        background:#{accent};animation:ptb 1.1s step-end infinite}
    .mk{display:inline-block;width:0;height:0}
    @keyframes ptb{0%,49%{opacity:1}50%,100%{opacity:0}}
    </style></head><body>#{body}</body></html>
    """
  end

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
  # (Earmark pure links). The preview upgrades two kinds: an image URL
  # becomes an inline image, a tweet URL becomes a tweet card. A written
  # link — [text](url) — has text different from the href and stays a
  # link. The point sentinel can sit inside the pasted URL; the compare
  # ignores it and the embed re-emits it as a sibling.
  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  # the share sheet appends ?s=20 and friends; a query or fragment after
  # the status id still names the same tweet
  @tweet_re ~r{\Ahttps?://(?:mobile\.)?(?:twitter|x)\.com/[^/]+/status(?:es)?/\d+(?:[?#]\S*)?\z}

  defp embed_urls(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &embed_node/1)

  defp embed_node({"a", atts, [text], meta} = node) when is_binary(text) do
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

  defp embed_node({tag, atts, children, meta}) when is_list(children),
    do: [{tag, atts, embed_urls(children), meta}]

  defp embed_node(other), do: [other]

  defp image_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, path: p} when s in ["http", "https"] and is_binary(p) ->
        (p |> Path.extname() |> String.downcase()) in @image_exts

      _ ->
        false
    end
  end

  defp tweet_url?(url), do: Regex.match?(@tweet_re, url)

  defp tweet_card(url, meta) do
    case Aimax.Ui.Oembed.card(url) do
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

  # the group segment, shortened — and dropped entirely when the group
  # is just the buffer's own name (a self-founded group), which printed
  # the filename twice
  defp ml_group(%{group: g, buffer: b}) when is_binary(g) do
    label = Path.basename(g)
    if label == Path.basename(b), do: nil, else: label
  end

  defp ml_group(_), do: nil

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
