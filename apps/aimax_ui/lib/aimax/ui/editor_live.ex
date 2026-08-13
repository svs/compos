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

  @impl true
  def mount(_params, _session, socket) do
    # each browser is a frame: the client sends its remembered frame id
    # (localStorage) in the connect params; unknown ids are honored so the
    # frame survives a wiped desktop.etf, absent ids get a fresh frame
    frame =
      if connected?(socket) do
        requested = get_connect_params(socket)["frame"]
        {:ok, fid} = Aimax.Core.Editor.attach_frame(requested)
        Events.subscribe_frame(fid)
        fid
      end

    socket =
      assign(socket,
        frame: frame,
        subscribed: MapSet.new(),
        line_cache: %{},
        boot_id: :persistent_term.get(:aimax_boot_id, "dev")
      )

    socket = if frame, do: push_event(socket, "frame", %{id: frame}), else: socket
    {:ok, refresh(socket)}
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

  # clicking a window's modeline-info segment runs that buffer's
  # modeline-info-command (policy lives in scheme; this is just dispatch)
  def handle_event("ml_info", %{"win" => win, "buf" => buf}, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Editor.set_active(id)

        case Aimax.Core.Buffer.get_local(buf, "modeline-info-command") do
          cmd when is_binary(cmd) -> Aimax.Core.Session.run_command(cmd)
          _ -> :ok
        end
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # transcript buttons (permission allow/deny etc.) — same shape as ml_info:
  # focus the window, run the command. agent-* commands only.
  def handle_event("agent_cmd", %{"win" => win, "cmd" => "agent-" <> _ = cmd}, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Aimax.Core.Editor.set_active(id)
        Aimax.Core.Session.run_command(cmd)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
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
  # for the client to put on the OS clipboard
  def handle_event("copy", _params, socket) do
    {:noreply,
     socket
     |> push_event("clipboard", %{text: Aimax.Core.Editor.copy_text(socket.assigns.frame)})
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

    subscribed =
      if connected?(socket) do
        visible = state.tree |> visible_buffers() |> MapSet.new()

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(&Events.subscribe/1)

        MapSet.union(socket.assigns.subscribed, visible)
      else
        socket.assigns.subscribed
      end

    assign(socket, state: state, subscribed: subscribed, line_cache: line_cache)
  end

  # two-level cache: the raw line split is keyed by buffer VERSION only, so
  # cursor motion never re-splits the buffer; span decoration (cursor/region/
  # hl-line) is recomputed per render but only for lines it actually touches
  defp decorate(%{type: :split} = split, cache, faces) do
    {children, cache} = Enum.map_reduce(split.children, cache, &decorate(&1, &2, faces))
    {%{split | children: children}, cache}
  end

  # preview buffers skip the line machinery entirely; the theme is baked into
  # the srcdoc (the sandboxed iframe can't see the parent's CSS vars)
  defp decorate(%{type: :leaf, render_mode: rm} = leaf, cache, faces)
       when rm in ["html", "markdown"] do
    key = {leaf.buffer, leaf.version, rm, leaf.preview_authored, :erlang.phash2(faces)}

    html =
      case cache[{:preview, leaf.id}] do
        {^key, html} -> html
        _ -> preview_html(rm, leaf.text, faces, leaf.preview_authored)
      end

    {Map.merge(leaf, %{lines: [], preview: html}),
     Map.put(cache, {:preview, leaf.id}, {key, html})}
  end

  # rich agent transcript: blocks (from agent.scm's block model) become
  # typed DOM — serif prose, tool cards, permission buttons. The buffer
  # text stays canonical; this is a pure view over byte ranges.
  defp decorate(%{type: :leaf, render_mode: "agent", agent: %{} = ag} = leaf, cache, _faces) do
    key = {leaf.buffer, leaf.version, :agent}

    blocks =
      case cache[{:agent, leaf.id}] do
        {^key, blocks} -> blocks
        _ -> ag.blocks |> Enum.reverse() |> Enum.map(&ag_block(&1, leaf.text)) |> Enum.reject(&is_nil/1)
      end

    {Map.merge(leaf, %{lines: [], ag_blocks: blocks, ag_input: ag_input(leaf, ag)}),
     Map.put(cache, {:agent, leaf.id}, {key, blocks})}
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
    leaf.text
    |> String.split("\n")
    |> Enum.map_reduce(0, fn part, start -> {{part, start}, start + byte_size(part) + 1} end)
    |> elem(0)
    |> Enum.with_index(1)
    |> Enum.map(fn {{part, start}, num} ->
      le = start + byte_size(part)
      line_ts = Enum.filter(spans, fn {s, e, _, _} -> s < le and e > start end)
      line_ov = Enum.filter(ovs, fn {s, e, _} -> s < le and e > start end)

      %{
        part: part,
        start: start,
        num: num,
        ts: line_ts,
        ov: line_ov,
        segs: seg_build(part, start, line_ts, line_ov)
      }
    end)
    |> List.to_tuple()
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
  def render(assigns) do
    ~H"""
    <div id="editor" class="editor-root" phx-hook="Keys" data-boot={@boot_id}>
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(face_css(@state.faces)) %></style>
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
          <div class="mb-input-row">
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

  defp count_text(%{total: total, sel: sel, completing: completing}) do
    cond do
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
        active?: assigns.node.id == assigns.active
      )

    ~H"""
    <div
      id={"win-#{@node.id}"}
      class={"window #{if @active?, do: "active", else: "inactive"} #{if !@node.line_numbers, do: "no-nums"} #{@node.window_class}"}
      data-win-id={@node.id}
    >
      <%= if @node.render_mode == "agent" and Map.has_key?(@node, :ag_blocks) do %>
        <div class="agent-view" id={"agent-#{@node.id}"} phx-hook="AgentScroll">
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
                  <details class="ag-tool" open={b.status == "running"}>
                    <summary>
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
                      phx-click="agent_cmd"
                      phx-value-win={@node.id}
                      phx-value-cmd="agent-permission-allow"
                    >Allow</button>
                    <button
                      class="ag-btn session"
                      phx-click="agent_cmd"
                      phx-value-win={@node.id}
                      phx-value-cmd="agent-permission-always"
                    >Always</button>
                    <button
                      class="ag-btn deny"
                      phx-click="agent_cmd"
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
      <%= if @node.render_mode in ["html", "markdown"] do %>
        <iframe class="html-preview" sandbox="" srcdoc={@node.preview} title={@node.buffer}></iframe>
      <% else %>
      <div class={"buf #{if @node.client_scroll?, do: "client-scroll"}"} style={@node.style}>
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
      <div class="modeline">
        <span class={"ml-dot #{if @node.modified, do: "modified"}"}></span>
        <span class="name">{@node.buffer}</span>
        <span :if={@node.group} class="ml-group">⊞ {@node.group}</span>
        <span class="ml-mode">{@node.mode}</span>
        <span
          :if={@node.modeline_info}
          class="ml-mode"
          style="cursor:pointer"
          phx-click="ml_info"
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

          segs = seg_build(line.part, line.start, line.ts, line.ov ++ overlays)

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

    ([0, plen] ++ cuts)
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

  defp safe_slice(text, s, e) do
    size = byte_size(text)
    s = s |> max(0) |> min(size) |> utf8_floor(text)
    e = e |> max(s) |> min(size) |> utf8_floor(text)
    binary_part(text, s, e - s)
  end

  # block offsets can go stale (they're laid down at insert time, and text
  # before them may be edited); a mid-codepoint slice is invalid UTF-8 and
  # kills the whole render (Earmark, HEEx). Snap down to a char boundary.
  defp utf8_floor(i, _text) when i <= 0, do: 0

  defp utf8_floor(i, text) do
    if i >= byte_size(text) do
      byte_size(text)
    else
      # UTF-8 continuation bytes are 0b10xxxxxx
      case :binary.at(text, i) do
        b when b >= 128 and b < 192 -> utf8_floor(i - 1, text)
        _ -> i
      end
    end
  end

  defp ag_block([s, e, "user" | meta], text) do
    text_of =
      case meta do
        [msg | _] when is_binary(msg) -> msg
        _ -> text |> safe_slice(s, e) |> String.trim() |> String.replace_prefix(">>> you: ", "")
      end

    %{kind: :user, text: text_of}
  end

  defp ag_block([s, e, "prose" | _], text) do
    md = safe_slice(text, s, e)

    html =
      case Earmark.as_html(md, compact_output: false) do
        {:ok, html, _} -> html
        {:error, html, _} -> html
      end

    %{kind: :prose, html: wrap_tables(html)}
  end

  defp ag_block([s, e, "thought" | _], text),
    do: %{kind: :thought, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, e, "tool", id, title, kind, status, body_start | _], text) do
    %{
      kind: :tool,
      id: id,
      title: title,
      verb: kind,
      status: status,
      body: String.trim_trailing(safe_slice(text, body_start, e))
    }
  end

  defp ag_block([s, e, "plan" | _], text),
    do: %{kind: :plan, text: String.trim(safe_slice(text, s, e))}

  defp ag_block([_s, _e, "permission", title | _], _text),
    do: %{kind: :permission, title: title}

  defp ag_block([_s, _e, "waiting" | _], _text), do: %{kind: :waiting}

  defp ag_block([s, e, "meta" | _], text),
    do: %{kind: :meta, text: String.trim(safe_slice(text, s, e))}

  defp ag_block(_, _), do: nil

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
        rel = (leaf.point - live_start) |> min(byte_size(live)) |> utf8_floor(live)
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
      case Earmark.as_html(text, compact_output: false) do
        {:ok, html, _} -> html
        {:error, html, _} -> html
      end

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
    </style></head><body>#{body}</body></html>
    """
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
    # define new faces and put them on overlay ranges with zero CSS edits
    classes =
      faces
      |> Enum.filter(fn {face, _} -> face =~ ~r/^[a-zA-Z0-9_-]+$/ end)
      |> Enum.map_join("", fn {face, _attrs} ->
        ".f-#{face}{color:var(--#{face}-fg,inherit);" <>
          "background:var(--#{face}-bg,transparent);" <>
          "font-weight:var(--#{face}-weight,inherit);" <>
          "font-style:var(--#{face}-style,inherit);" <>
          "font-family:var(--#{face}-family,inherit);" <>
          "font-size:var(--#{face}-size,inherit);" <>
          "text-decoration:var(--#{face}-decoration,none);}"
      end)

    ":root{#{vars}}#{classes}"
  end

end
