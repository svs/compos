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
  def mount(_params, _session, socket) do
    # each browser TAB is a frame (S5): the client sends its remembered
    # frame id (sessionStorage, per tab) in the connect params; unknown
    # ids are honored so the frame survives a wiped desktop.etf, absent
    # ids get a fresh frame. The id rides the payload as data-frame —
    # there is no separate frame event (S13).
    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Aimax.Core.Editor.attach_frame(requested)
      Events.subscribe_frame(fid)

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
  # its input region), then place point when the click hit a text line
  def handle_event("mouse", %{"win" => win} = params, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Session.eval("(mouse-select-window! #{id})")

        case params do
          %{"line" => line, "col" => col} when is_integer(line) and is_integer(col) ->
            Aimax.Core.Editor.mouse_goto(id, line, col)

          _ ->
            :ok
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a click inside a markdown preview's iframe: the hook sends the clicked
  # text node split at the caret, and Scheme finds the spot in the source
  def handle_event("preview_goto", %{"win" => win} = p, socket) do
    with id when is_integer(id) <- safe_int(win) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Session.call_named("preview-goto!", [
          id,
          p["before"] || "",
          p["after"] || "",
          p["wb"] || "",
          p["wa"] || ""
        ])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # drag: the native selection, mirrored into mark + point
  def handle_event("mouse_sel", %{"win" => win, "al" => al, "ac" => ac, "fl" => fl, "fc" => fc}, socket)
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

    assign(socket, state: state, subscribed: subscribed, line_cache: line_cache)
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

    # the oembed generation moves when a tweet fetch lands, so the cached
    # placeholder misses and the card renders
    key =
      {leaf.buffer, leaf.version, rm, leaf.preview_authored, :erlang.phash2(faces), pt,
       Aimax.Ui.Oembed.generation()}

    html =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> html
        _ -> preview_doc(rm, leaf.text, pt, faces, leaf.preview_authored)
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
    # per-BLOCK cache (A13): a streaming append re-renders the one block
    # that grew, not the whole transcript. A block's key is its raw entry,
    # the bytes it covers, and its open flag.
    old =
      case cache[{:agent, leaf.id}] do
        map when is_map(map) -> map
        _ -> %{}
      end

    {rendered, block_cache} =
      ag.blocks
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {b, i}, acc ->
        key = :erlang.phash2({b, block_slice(b, leaf.text), block_open?(b, ag.open_cards)})

        view =
          case old[i] do
            {^key, view} -> view
            _ -> ag_block(b, leaf.text, ag.open_cards)
          end

        {view, Map.put(acc, i, {key, view})}
      end)

    blocks = Enum.reject(rendered, &is_nil/1)

    {Map.merge(leaf, %{lines: [], ag_blocks: blocks, ag_input: ag_input(leaf, ag)}),
     Map.put(cache, {:agent, leaf.id}, block_cache)}
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

  defp block_slice([s, e | _], text) when is_integer(s) and is_integer(e),
    do: safe_slice(text, s, e)

  defp block_slice(_, _), do: nil

  defp block_open?([_s, _e, "tool", id | _], open_cards), do: id in open_cards
  defp block_open?(_, _), do: false

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
      <div class="windows">
        <.tree node={@state.tree} active={@state.active} completion={@state.completion} />
      </div>
      <div :if={@state.which_key && @state.minibuffer == nil} class="which-key">
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
        <div class="mb-panel">
          <div class="mb-label-row">
            {String.trim_trailing(@state.minibuffer.prompt, ": ")} · TAB completes · RET accepts · C-n/C-p selects · C-c C-o collects · C-g quits
          </div>
          <div class="mb-cands" style={"--mb-label-w: #{@state.minibuffer.label_width}ch"}>
            <div
              :for={c <- @state.minibuffer.candidates}
              class={"mb-cand #{if c.selected, do: "selected"}"}
            >
              <span class="mb-label">{c.label}</span>
              <span class="mb-hint">{c.hint}</span>
            </div>
          </div>
          <div class={"mb-input-row #{if Map.get(@state.minibuffer, :prompt_sel), do: "selected"}"}>
            <span class="prompt">{@state.minibuffer.prompt}</span>
            <span class="mb-input"><%= with {pre, cur, post} <- mb_split(@state.minibuffer) do %>{pre}<span class="cursor">{cur}</span>{post}<% end %></span>
            <span class="mb-spacer"></span>
            <span class="mb-count">{count_text(@state.minibuffer)}</span>
          </div>
        </div>
      <% else %>
        <div class="echo-bar">
          <span class="echo">{@state.echo}</span>
          <span class="mb-spacer"></span>
          <span :if={@state.modeline_extra != ""} class="ml-extra">{@state.modeline_extra}</span>
          <span class="echo-hint" :if={@state.echo == ""}>C-x C-f · C-x b · C-x d · C-c a n agent · M-x · C-g</span>
        </div>
      <% end %>
    </div>
    """
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

  defp count_text(%{total: total, sel: sel, completing: completing} = mb) do
    cond do
      # the prompt holds the selection: RET opens this directory
      total > 0 and Map.get(mb, :prompt_sel) -> "#{total} · RET opens dir"
      total > 0 -> "#{sel + 1}/#{total}"
      completing -> "TAB completes"
      true -> "no match"
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
          <div class="ag-scroll">
            <%= for b <- @node.ag_blocks do %>
              <%= case b.kind do %>
                <% :user -> %>
                  <div class="ag-user"><span class="ag-label">YOU</span><div class="ag-user-text">{b.text}</div></div>
                <% :prose -> %>
                  <div class="ag-prose">{Phoenix.HTML.raw(b.html)}</div>
                <% :thought -> %>
                  <details class="ag-thought"><summary>thought</summary><div class="ag-thought-text">{b.text}</div></details>
                <% :tool -> %>
                  <details class="ag-tool" open={b.open}>
                    <summary
                      phx-click="agent_card"
                      phx-value-win={@node.id}
                      phx-value-id={b.id}
                      onclick="event.preventDefault()"
                    >
                      <span class={"ag-dot #{b.status}"}></span><span class="ag-verb">{b.verb}</span>
                      <span class="ag-title">{b.title}</span>
                      <span class="ag-tstatus">{b.status}</span>
                    </summary>
                    <pre :if={b.body != ""} class="ag-body">{b.body}</pre>
                  </details>
                <% :plan -> %>
                  <pre class="ag-plan">{b.text}</pre>
                <% :permission -> %>
                  <div class="ag-perm">
                    <span class="ag-perm-title">needs permission — {b.title}</span>
                    <button
                      class="ag-btn allow"
                      phx-click="ui_cmd"
                      phx-value-win={@node.id}
                      phx-value-cmd="agent-permission-allow"
                    >Allow</button>
                    <button
                      class="ag-btn session"
                      phx-click="ui_cmd"
                      phx-value-win={@node.id}
                      phx-value-cmd="agent-permission-always"
                    >Always</button>
                    <button
                      class="ag-btn deny"
                      phx-click="ui_cmd"
                      phx-value-win={@node.id}
                      phx-value-cmd="agent-permission-deny"
                    >Deny</button>
                  </div>
                <% :waiting -> %>
                  <div class="ag-wait">⋯ thinking</div>
                <% :meta -> %>
                  <div class="ag-meta">{b.text}</div>
              <% end %>
            <% end %>
          </div>
          <div class="ag-inputrow">
            <span class="ag-label">YOU</span>
            <span class="ag-input"><span class="ag-queued">{@node.ag_input.queued}</span>{@node.ag_input.pre}<span
                :if={@node.ag_input.cur != ""}
                class="cursor"
              >{@node.ag_input.cur}</span>{@node.ag_input.post}</span>
            <span
              :if={@node.ag_input.pre == "" and @node.ag_input.post == "" and @node.ag_input.queued == ""}
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
          sandbox="allow-same-origin"
          srcdoc={@node.preview}
          title={@node.buffer}
        ></iframe>
      <% else %>
      <div
        class={"buf #{if @node.client_scroll?, do: "client-scroll"}"}
        style={@node.style}
        data-ctop={@node.ctop}
        data-manual={to_string(@node.manual)}
      >
        <div
          :for={ln <- @lines}
          id={"ln-#{@node.id}-#{ln.num}"}
          class={"line #{if ln.current, do: "hl-line"}"}
        >
          <span class="linenum">{ln.num}</span>
          <span class="line-content"><span :for={{txt, cls} <- ln.segs} class={cls}>{txt}</span><span
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
      <div class="modeline">
        <span class={"ml-dot #{if @node.modified, do: "modified"}"}></span>
        <span class="name">{@node.buffer}</span>
        <span :if={@node.group} class="ml-group">⊞ {@node.group}</span>
        <span class="ml-mode">{@node.mode}</span>
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
        <span class="ml-pos">{pct(@node)} · L{@line}:C{@col}</span>
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
    %{
      kind: :tool,
      id: id,
      title: title,
      verb: kind,
      status: status,
      open: id in open_cards,
      body: String.trim_trailing(safe_slice(text, body_start, e))
    }
  end

  defp ag_block([s, e, "plan" | _], text, _open),
    do: %{kind: :plan, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, _e, "permission", title | _], _text, _open),
    do: %{kind: :permission, title: title}

  defp ag_block([_s, _e, "waiting" | _], _text, _open), do: %{kind: :waiting}

  defp ag_block([s, e, "meta" | _], text, _open),
    do: %{kind: :meta, text: String.trim(safe_slice(text, s, e))}

  defp ag_block(_, _, _), do: nil

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

  # the input region: [queued (muted)][live text][cursor when point is home]
  defp ag_input(leaf, ag) do
    start = ag.input_start
    queued_len = ag.queued |> Enum.filter(&is_integer/1) |> Enum.sum()
    queued = safe_slice(leaf.text, start, start + queued_len)
    live_start = start + queued_len
    live = safe_slice(leaf.text, live_start, byte_size(leaf.text))

    {pre, cur, post} =
      if leaf.point >= live_start do
        rel = (leaf.point - live_start) |> min(byte_size(live)) |> then(&Text.floor_utf8(live, &1))
        rest = binary_part(live, rel, byte_size(live) - rel)

        case String.next_grapheme(rest) do
          nil -> {live, " ", ""}
          {g, more} -> {binary_part(live, 0, rel), g, more}
        end
      else
        {live, "", ""}
      end

    %{queued: queued, pre: pre, cur: cur, post: post}
  end

  # The cursor in a markdown preview: a private-use sentinel goes into the
  # source at POINT, rides through Earmark as plain text, and comes out as
  # the .pt span. If point sits inside markdown syntax the one construct
  # can render off for a moment; the sandbox runs no scripts, so a mangled
  # span is a display blemish and nothing more.
  @pt_sentinel "\uE000"

  @doc false
  def preview_doc("markdown", text, point, faces, authored) do
    p = point |> max(0) |> min(byte_size(text))

    marked =
      case cursor_spot(text, p) do
        nil ->
          text

        at ->
          binary_part(text, 0, at) <> @pt_sentinel <> binary_part(text, at, byte_size(text) - at)
      end

    preview_html("markdown", marked, faces, authored)
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

  def preview_doc(rm, text, _point, faces, authored), do: preview_html(rm, text, faces, authored)

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
    a{color:#{p.accent} !important}
    code,pre,kbd{background-color:#{p.inset} !important}
    blockquote{color:#{p.dim} !important}
    th{background-color:#{p.inset} !important}
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
      |> embed_urls()
      |> Earmark.Transform.transform(compact_output: false)
      |> String.replace(@pt_sentinel, ~s(<span class="pt"></span>))

    %{bg: bg, fg: fg, accent: accent, dim: dim, border: border, inset: inset} =
      preview_palette(faces)

    """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    body{margin:0;padding:26px 34px 60px;max-width:62em;
         font:16px/1.65 Spectral,Georgia,serif;color:#{fg};background:#{bg}}
    h1,h2,h3,h4{font-family:Spectral,Georgia,serif;line-height:1.25;margin:26px 0 8px}
    h1{font-size:28px}h2{font-size:22px;border-bottom:1px solid #{border};padding-bottom:4px}
    h3{font-size:18px;color:#{accent}}
    code,pre{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;font-size:13.5px}
    code{background:#{inset};padding:1px 4px;border-radius:2px}
    pre{background:#{inset};padding:10px 12px;border-left:3px solid #{accent};overflow-x:auto}
    pre code{background:none;padding:0}
    a{color:#{accent}}blockquote{margin:12px 0;padding:2px 14px;border-left:3px solid #{border};color:#{dim}}
    table{border-collapse:collapse;font-size:14px}th,td{border:1px solid #{border};padding:5px 9px}
    th{background:#{inset};text-align:left}
    img{max-width:100%}hr{border:0;border-top:1px solid #{border};margin:22px 0}
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
    .pt{display:inline-block;width:2px;height:1.05em;margin:0 -1px;vertical-align:-0.18em;
        background:#{accent};animation:ptb 1.1s step-end infinite}
    @keyframes ptb{0%,49%{opacity:1}50%,100%{opacity:0}}
    </style></head><body>#{body}</body></html>
    """
  end

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
