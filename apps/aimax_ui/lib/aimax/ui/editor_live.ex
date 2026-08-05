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

  @impl true
  def handle_event("key", %{"k" => spec}, socket) do
    KeyDispatch.handle_key(spec)
    {:noreply, refresh(socket)}
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
    {tree, line_cache} = decorate(state.tree, socket.assigns.line_cache)
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
  defp decorate(%{type: :split} = split, cache) do
    {children, cache} = Enum.map_reduce(split.children, cache, &decorate/2)
    {%{split | children: children}, cache}
  end

  defp decorate(%{type: :leaf} = leaf, cache) do
    raw_key = {leaf.buffer, leaf.version, leaf.ts_lang}

    static =
      case cache[leaf.id] do
        {^raw_key, static} -> static
        _ -> build_static(leaf)
      end

    lines = render_pass(static, leaf.text, leaf.point, leaf.mark)
    {Map.put(leaf, :lines, lines), Map.put(cache, leaf.id, {raw_key, static})}
  end

  # static per-version work: line split + font-lock spans + ts-only segs.
  # Overlapping captures resolve last-wins (tree-sitter highlight semantics).
  defp build_static(leaf) do
    spans =
      case leaf.ts_lang do
        nil ->
          []

        lang ->
          lang
          |> Aimax.Core.TS.ts_highlight(leaf.text)
          |> Enum.with_index()
          |> Enum.map(fn {{s, e, scope}, i} -> {s, e, "ts-" <> scope, i} end)
      end

    leaf.text
    |> String.split("\n")
    |> Enum.map_reduce(0, fn part, start -> {{part, start}, start + byte_size(part) + 1} end)
    |> elem(0)
    |> Enum.with_index(1)
    |> Enum.map(fn {{part, start}, num} ->
      le = start + byte_size(part)
      line_ts = Enum.filter(spans, fn {s, e, _, _} -> s < le and e > start end)

      %{
        part: part,
        start: start,
        num: num,
        ts: line_ts,
        segs: seg_build(part, start, line_ts, [])
      }
    end)
  end

  defp visible_buffers(%{type: :leaf, buffer: b}), do: [b]
  defp visible_buffers(%{type: :split, children: c}), do: Enum.flat_map(c, &visible_buffers/1)

  # --- rendering -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="editor" class="editor-root" phx-hook="Keys" data-boot={@boot_id}>
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(face_css(@state.faces)) %></style>
      <div class="windows">
        <.tree node={@state.tree} active={@state.active} />
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
            <span class="mb-input">{@state.minibuffer.input}<span class="cursor">&nbsp;</span></span>
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

  defp count_text(%{total: total, sel: sel, completing: completing}) do
    cond do
      total > 0 -> "#{sel + 1}/#{total}"
      completing -> "TAB completes"
      true -> "no match"
    end
  end

  defp tree(%{node: %{type: :split}} = assigns) do
    ~H"""
    <div class={"split #{@node.dir}"}>
      <.tree :for={child <- @node.children} node={child} active={@active} />
    </div>
    """
  end

  defp tree(%{node: %{type: :leaf}} = assigns) do
    {line, col} = line_col(assigns.node.text, assigns.node.point)

    assigns =
      assign(assigns,
        lines: assigns.node.lines,
        line: line,
        col: col,
        active?: assigns.node.id == assigns.active
      )

    ~H"""
    <div class={"window #{if @active?, do: "active", else: "inactive"}"}>
      <div class="buf">
        <div :for={ln <- @lines} class={"line #{if ln.current, do: "hl-line"}"}>
          <span class="linenum">{ln.num}</span>
          <span class="line-content"><span :for={{txt, cls} <- ln.segs} class={cls}>{txt}</span></span>
        </div>
      </div>
      <div class="modeline">
        <span class={"ml-dot #{if @node.modified, do: "modified"}"}></span>
        <span class="name">{@node.buffer}</span>
        <span class="ml-mode">{@node.mode}</span>
        <span class="mb-spacer"></span>
        <span class="ml-pos">L{@line}:C{@col}</span>
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

          segs = seg_build(line.part, line.start, line.ts, overlays)

          # cursor sitting on this line's newline (or at EOF on the last line)
          if point >= line.start and point == le,
            do: segs ++ [{" ", "cursor"}],
            else: segs
        else
          line.segs
        end

      %{num: line.num, current: current, segs: segs}
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

  defp face_css(faces) do
    vars =
      Enum.map_join(faces, "", fn {face, attrs} ->
        Enum.map_join(attrs, "", fn {k, v} -> "--#{face}-#{k}:#{v};" end)
      end)

    ":root{#{vars}}"
  end

  defp line_col(text, point) do
    before_c = binary_part(text, 0, point)
    newlines = :binary.matches(before_c, "\n")

    bol =
      case newlines do
        [] -> 0
        list -> list |> List.last() |> elem(0) |> Kernel.+(1)
      end

    {length(newlines) + 1, point - bol}
  end
end
