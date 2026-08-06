defmodule Aimax.Ui.EditorLive do
  @moduledoc """
  The window: renders the tiling window tree per line (numbers, hl-line,
  cursor/region spans), modelines, which-key, the vertico-style minibuffer and
  echo area; forwards every keystroke to `Aimax.Core.KeyDispatch`.

  Pure view — no editor logic here. Re-renders on editor-state events and on
  change events of any visible buffer (so RPC/agent edits appear live).
  """

  use Phoenix.LiveView

  alias Aimax.Core.{Events, KeyDispatch}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe_editor()

    socket =
      assign(socket,
        subscribed: MapSet.new(),
        line_cache: %{},
        boot_id: :persistent_term.get(:aimax_boot_id, "dev")
      )

    {:ok, refresh(socket)}
  end

  # drain before refresh: the dispatch above already broadcast its change
  # notifications to this process (Events sends before the GenServer replies),
  # so without the drain every keystroke rendered twice — once here, once in
  # handle_info
  @impl true
  def handle_event("key", %{"k" => spec}, socket) do
    KeyDispatch.handle_key(spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Aimax.Core.Editor.set_total_rows(rows)
    {:noreply, socket |> drain() |> refresh()}
  end

  # per-window row counts: line height varies per buffer (per-buffer styles),
  # so the client measures each window against its own lines
  def handle_event("win_rows", %{"rows" => rows}, socket) when is_map(rows) do
    parsed =
      for {id, n} <- rows, is_integer(n), id_int = safe_int(id), into: %{}, do: {id_int, n}

    Aimax.Core.Editor.set_window_rows(parsed)
    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("scroll", %{"lines" => lines}, socket) when is_integer(lines) do
    Aimax.Core.Editor.scroll_active(lines)
    {:noreply, socket |> drain() |> refresh()}
  end

  @impl true
  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}

  # coalesce bursts: drain all queued change notifications, render once
  defp drain(socket) do
    receive do
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  defp refresh(socket) do
    state = Aimax.Core.Editor.render_state()
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

  defp decorate(%{type: :leaf} = leaf, cache, _faces) do
    raw_key = {leaf.buffer, leaf.version, leaf.ts_lang, leaf.overlay_gen}

    static =
      case cache[leaf.id] do
        {^raw_key, static} -> static
        _ -> build_static(leaf)
      end

    # viewport: folded lines drop out, then only the visible slice
    # (+overscan) becomes DOM. leaf.top is in visible-line space.
    hidden = leaf.hidden_lines

    visible =
      static
      |> then(fn lines ->
        if MapSet.size(hidden) == 0,
          do: lines,
          else: Enum.reject(lines, &MapSet.member?(hidden, &1.num - 1))
      end)
      |> Enum.slice(leaf.top, leaf.rows + 4)

    lines =
      visible
      |> render_pass(leaf.text, leaf.point, leaf.mark)
      |> Enum.map(fn ln ->
        # a visible line whose successor is folded gets a fold marker
        if MapSet.member?(hidden, ln.num),
          do: %{ln | segs: ln.segs ++ [{" …", "f-fold-marker"}]},
          else: ln
      end)

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
            {String.trim_trailing(@state.minibuffer.prompt, ": ")} · TAB completes · RET accepts · C-n/C-p selects · C-g quits
          </div>
          <div class="mb-cands">
            <div
              :for={c <- @state.minibuffer.candidates}
              class={"mb-cand #{if c.selected, do: "selected"}"}
            >
              <span class="mb-label">{c.label}</span>
              <span class="mb-spacer"></span>
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
          <span class="echo-hint" :if={@state.echo == ""}>C-x C-f · C-x b · C-x d · M-x · M-| · C-g</span>
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
      class={"window #{if @active?, do: "active", else: "inactive"} #{if !@node.line_numbers, do: "no-nums"}"}
      data-win-id={@node.id}
    >
      <%= if @node.render_mode in ["html", "markdown"] do %>
        <iframe class="html-preview" sandbox="" srcdoc={@node.preview} title={@node.buffer}></iframe>
      <% else %>
      <div class="buf" style={@node.style}>
        <div :for={ln <- @lines} class={"line #{if ln.current, do: "hl-line"}"}>
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
      <div class="modeline">
        <span class={"ml-dot #{if @node.modified, do: "modified"}"}></span>
        <span class="name">{@node.buffer}</span>
        <span class="ml-mode">{@node.mode}</span>
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
          "text-decoration:var(--#{face}-decoration,none);}"
      end)

    ":root{#{vars}}#{classes}"
  end

end
