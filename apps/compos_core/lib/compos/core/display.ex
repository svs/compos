defmodule Compos.Core.Display do
  @moduledoc """
  The text display model: the rows a window draws.

  A row is one source line of the window's viewport, cut into segments
  that each carry the classes of the faces over them (tree-sitter scopes,
  overlays, the region, the cursor) and the chrome attachments beside
  them. Every client draws the same rows: the LiveView and the handheld
  view call `window/3`, and neither splits, fontifies or segments text
  itself. Policy is not here: Scheme decides the faces, the overlays and
  the folds, and this module only lays them over the text.
  """

  alias Compos.Core.Rope
  alias Compos.Scheme.Text

  # A normal space collapses inside an empty line, so it cannot give the
  # cursor a visible width. Keep the placeholder a non-breaking space.
  @cursor_placeholder "\u00a0"

  @doc """
  The rows of a text window LEAF (a leaf of `Editor.render_state/1`),
  and the cache ENTRY to pass back on the next render of that window.

  The expensive half (the viewport's lines, their faces and segments) is
  memoized by the buffer version and every other input that changes it;
  the cheap half (point, mark, the region, the caret) is drawn on every
  call, and only on the lines it touches. OPTS: `caret_owner`, the window
  the browser's caret owns (nil while a prompt is up); `embed_generation`,
  a number that moves when an embed a line draws finishes loading.
  """
  def window(leaf, entry, opts \\ []) do
    rope = Map.get(leaf, :rope) || Rope.new(leaf.text)
    want = want(leaf)
    client_scroll? = leaf.total_lines <= want
    whitespace = whitespace?(leaf)

    raw_key =
      {leaf.buffer, leaf.version, leaf.ts_lang, leaf.overlay_gen, leaf.top, want,
       leaf.hidden_lines, leaf.narrow_lines, whitespace, opts[:embed_generation],
       Map.get(leaf, :fontification, [])}

    {visible, row_cache} =
      case entry do
        {^raw_key, visible, row_cache} ->
          {visible, row_cache}

        old ->
          previous =
            case old do
              {_, _, rows} -> rows
              _ -> %{}
            end

          source = viewport_lines(rope, leaf, want, client_scroll?)
          build_static(leaf, source, previous, whitespace)
      end

    lines =
      visible
      |> render_pass(
        leaf.text,
        leaf.point,
        leaf.mark,
        leaf.id == opts[:caret_owner] and not leaf.read_only,
        Map.get(leaf, :cursor_visible, true)
      )
      |> Enum.map(fn ln ->
        # a visible line whose successor is folded gets a fold marker
        if MapSet.member?(leaf.hidden_lines, ln.num),
          do: %{ln | segs: ln.segs ++ [{" …", "f-fold-marker"}]},
          else: ln
      end)

    leaf = leaf |> Map.put(:client_scroll?, client_scroll?) |> Map.put(:lines, lines)
    {leaf, {raw_key, visible, row_cache}}
  end

  # A window builds the rows it ships: its viewport and two more screens
  # for the client to scroll through. A peek card scrolls on its own and
  # takes more, up to a bound: a whole large file is never built.
  #
  # A window under the bound ships every line. The server windows a buffer
  # by SOURCE lines, and every line-content wraps (white-space: pre-wrap),
  # so one source line is many screen rows and a server top by source line
  # cannot keep point or the last line on screen. The last screenful the
  # server clamps to then stands below the window and the reader cannot
  # reach the end of the buffer. This is not a visual-line-mode matter:
  # code wraps too, by character instead of by word. The browser measures
  # the wrapped rows and scrolls them itself.
  @ship_all_max_lines 2_000

  defp want(leaf) do
    cond do
      String.contains?(leaf.window_class || "", "listing-peek") ->
        leaf.total_lines |> min(@ship_all_max_lines) |> max(1)

      leaf.total_lines <= @ship_all_max_lines ->
        max(leaf.total_lines, 1)

      # over the bound the windowed path stays, because a whole large file
      # is never built. Its bottom is reachable only while its lines do not
      # wrap: the server would need the screen rows to do better.
      true ->
        max(leaf.rows * 3 + 8, 1)
    end
  end

  defp viewport_lines(rope, leaf, want, client_scroll?) do
    size = Rope.line_count(rope)
    {first, last} = leaf.narrow_lines || {0, size - 1}
    top = if client_scroll?, do: 0, else: leaf.top
    hidden = leaf.hidden_lines

    indices =
      cond do
        last < first ->
          []

        MapSet.size(hidden) == 0 ->
          lo = min(first + top, last + 1)
          hi = min(lo + want - 1, last)
          if hi < lo, do: [], else: Enum.to_list(lo..hi)

        true ->
          first..last
          |> Stream.reject(&MapSet.member?(hidden, &1))
          |> Stream.drop(top)
          |> Enum.take(want)
      end

    Enum.map(indices, fn i ->
      start = Rope.line_to_byte(rope, i)
      stop = Rope.line_to_byte(rope, i + 1)
      part = Rope.slice(rope, start, stop - start)

      part =
        if String.ends_with?(part, "\n"),
          do: binary_part(part, 0, byte_size(part) - 1),
          else: part

      {{part, start}, i + 1}
    end)
  end

  # Prepare only selected source lines. Faces arrive asynchronously and
  # must match this snapshot. Text rendering never calls the parser.
  defp build_static(leaf, lines, previous, whitespace) do
    request_jit(leaf, lines)

    spans =
      display_spans(leaf, lines)
      |> Enum.with_index()
      |> Enum.map(fn {{s, e, scope}, i} -> {s, e, "ts-" <> scope, i} end)

    # A chrome attachment stands at one byte and holds zero bytes: text the
    # buffer does not hold, drawn beside the text it decorates. It rides the
    # overlay list as a zero-length range whose face starts with "chrome-".
    {chrome_raw, plain_ov} =
      Enum.split_with(leaf.overlays, fn {_s, _e, face} ->
        is_binary(face) and String.starts_with?(face, "chrome-")
      end)

    chrome = Enum.flat_map(chrome_raw, &chrome_item/1)

    ovs = Enum.map(plain_ov, fn {s, e, face} -> {s, e, "f-" <> face} end)

    # Whitespace decoration only scans the selected lines.
    ovs =
      if whitespace do
        ws =
          Enum.flat_map(lines, fn {{part, start}, _} ->
            Regex.scan(~r/ +|\t/, part, return: :index)
            |> Enum.map(fn [{s, len}] ->
              face = if binary_part(part, s, 1) == "\t", do: "f-ws-tab", else: "f-ws-space"
              {start + s, start + s + len, face}
            end)
          end)

        ovs ++ ws
      else
        ovs
      end

    ts_per_line = stab(spans, lines, fn {s, _, _, _} -> s end, fn {_, e, _, _} -> e end)
    ov_per_line = stab(ovs, lines, fn {s, _, _} -> s end, fn {_, e, _} -> e end)
    chrome_per_line = chrome_lines(chrome, lines, byte_size(leaf.text))

    {rows, {next, prepared}} =
      [lines, ts_per_line, ov_per_line, chrome_per_line]
      |> Enum.zip()
      |> Enum.map_reduce({%{}, 0}, fn {{{part, start}, num}, line_ts, line_ov, line_chrome},
                                      {next, prepared} ->
        # Absolute offsets change after an edit above this line. Segment
        # identity depends on relative ranges, not its document position.
        ts =
          line_ts
          |> Enum.sort_by(&elem(&1, 3))
          |> Enum.map(fn {s, e, cls, _} -> {s - start, e - start, cls} end)
        ov = Enum.map(line_ov, fn {s, e, cls} -> {s - start, e - start, cls} end)

        ch =
          Enum.map(line_chrome, fn {p, side, cls, text, click} ->
            {p - start, side, cls, text, click}
          end)

        key = {part, ts, ov, ch}

        {segs, prepared} =
          case Map.fetch(previous, key) do
            {:ok, segs} -> {segs, prepared}
            :error -> {line_segs(part, start, line_ts, line_ov, line_chrome), prepared + 1}
          end

        row = %{
          part: part,
          start: start,
          num: num,
          ts: line_ts,
          ov: line_ov,
          chrome: line_chrome,
          selected: Enum.any?(line_ov, fn {_, _, face} -> face == "f-select" end),
          row: row_class(line_ov, start),
          segs: segs
        }

        {row, {Map.put(next, key, segs), prepared}}
      end)

    :telemetry.execute(
      [:compos, :ui, :text_display],
      %{visible: length(rows), prepared: prepared, reused: length(rows) - prepared},
      %{buffer: leaf.buffer, version: leaf.version}
    )

    {rows, next}
  end

  # jit-lock: the lines this window builds, and only those, get faces
  # from fontification-functions. The buffer skips what it already did.
  defp request_jit(_leaf, []), do: :ok

  defp request_jit(leaf, lines) do
    if Compos.Core.JitLock.on?() do
      {{_, start}, _} = hd(lines)
      {{part, last}, _} = List.last(lines)
      Compos.Core.Buffer.request_jit(leaf.buffer, leaf.version, start, last + byte_size(part) + 1)
    end

    :ok
  end

  defp display_spans(%{ts_lang: lang}, _) when lang in [nil, false], do: []
  defp display_spans(_, []), do: []

  defp display_spans(leaf, lines) do
    {{_, start}, _} = hd(lines)
    {{part, last}, _} = List.last(lines)
    stop = last + byte_size(part)

    found =
      Enum.find(Map.get(leaf, :fontification, []), fn {v, s, e, _} ->
        v == leaf.version and s <= start and e >= stop
      end)

    case found do
      {_, _, _, spans} ->
        spans

      nil ->
        Compos.Core.Buffer.request_fontification(leaf.buffer, leaf.version, start, stop)

        # The buffer rebases provisional faces through every edit. Keep them
        # visible until fresh faces arrive, including when an edit exposes a
        # little more text than the previous viewport covered.
        provisional =
          leaf
          |> Map.get(:fontification, [])
          |> Enum.filter(fn {_, s, e, _} -> s <= stop and e >= start end)
          |> Enum.max_by(fn {v, s, e, _} -> {min(e, stop) - max(s, start), v} end, fn -> nil end)

        case provisional do
          {_, _, _, spans} -> spans
          nil -> []
        end
    end
  end

  # One chrome overlay -> {pos, side, class, text, click}. The face string
  # is "chrome-b:CLASS:ENCODED-TEXT[:CLICK]" (before the byte) or
  # "chrome-a:..." (after it); Scheme builds it with chrome-before /
  # chrome-after. The encoded text cannot hold a bare colon, so the split
  # is unambiguous; a click id keeps every colon it carries.
  defp chrome_item({pos, _e, "chrome-b:" <> rest}), do: [chrome_parts(pos, :before, rest)]
  defp chrome_item({pos, _e, "chrome-a:" <> rest}), do: [chrome_parts(pos, :after, rest)]
  defp chrome_item(_), do: []

  defp chrome_parts(pos, side, rest) do
    case String.split(rest, ":", parts: 3) do
      [cls, text, click] -> {pos, side, cls, URI.decode(text), click}
      [cls, text] -> {pos, side, cls, URI.decode(text), nil}
      [cls] -> {pos, side, cls, "", nil}
    end
  end

  # Which line a chrome attachment stands on. A boundary byte is shared:
  # a :before attachment belongs to what follows it, an :after attachment
  # to what precedes it; an empty line takes both, and the first and last
  # lines take what would otherwise fall off the ends.
  defp chrome_lines([], lines, _size), do: List.duplicate([], length(lines))

  defp chrome_lines(chrome, lines, size) do
    Enum.map(lines, fn {{part, start}, _num} ->
      le = start + byte_size(part)

      Enum.filter(chrome, fn {pos, side, _cls, _text, _click} ->
        pos >= start and pos <= le and
          case side do
            :before -> pos < le or le == size or start == le
            :after -> pos > start or start == 0 or start == le
          end
      end)
    end)
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

  @doc "Whether whitespace-mode draws the blanks of LEAF's buffer."
  def whitespace?(leaf),
    do: Compos.Core.Buffer.get_local(leaf.buffer, "whitespace-mode") == true

  defp line_segs(part, start, line_ts, line_ov, chrome \\ []) do
    segs =
      if byte_size(part) > @max_styled_line or
           length(line_ts) + length(line_ov) > @max_line_ranges do
        [{part, ""}]
      else
        seg_build(part, start, line_ts, line_ov)
      end

    splice_chrome(segs, part, start, chrome)
  end

  # A chrome attachment becomes a seg whose class starts with "chrome-seg".
  # The seg renderer draws it as a zero-length island (data-len 0), so the
  # caret walks over it and its text never counts as source bytes.
  defp splice_chrome(segs, _part, _start, []), do: segs

  defp splice_chrome(segs, part, start, chrome) do
    # at one byte, what precedes draws its :after chrome before what
    # follows draws its :before chrome
    ordered =
      Enum.sort_by(chrome, fn {pos, side, _, _, _} ->
        {pos, if(side == :after, do: 0, else: 1)}
      end)

    {done, rest, _off} =
      Enum.reduce(ordered, {[], segs, 0}, fn {pos, _side, cls, text, click}, {done, rest, off} ->
        at = Text.floor_utf8(part, min(max(pos - start, 0), byte_size(part)))
        {before, tail, off} = segs_split(rest, off, at)
        {done ++ before ++ [{text, chrome_class(cls, click)}], tail, off}
      end)

    done ++ rest
  end

  # the click id rides the class the way a link target does — a seg's class
  # is its only channel — and the seg renderer takes it back off
  defp chrome_class(cls, nil), do: "chrome-seg " <> cls

  defp chrome_class(cls, click),
    do: "chrome-seg #{cls} chrome-click:#{URI.encode(click, &URI.char_unreserved?/1)}"

  # split SEGS at in-line byte AT; OFF is the byte where SEGS begins
  defp segs_split(segs, off, at), do: segs_split(segs, off, at, [])

  defp segs_split([], off, _at, acc), do: {Enum.reverse(acc), [], off}

  defp segs_split([{txt, cls} = seg | rest], off, at, acc) do
    len = byte_size(txt)

    cond do
      off + len <= at ->
        segs_split(rest, off + len, at, [seg | acc])

      off >= at ->
        {Enum.reverse(acc), [seg | rest], off}

      true ->
        cut = at - off

        {Enum.reverse([{binary_part(txt, 0, cut), cls} | acc]),
         [{binary_part(txt, cut, len - cut), cls} | rest], at}
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

  # --- per-line display list: numbers, hl-line, font-lock + overlays ----------

  # The focused editable surface draws no cursor and no region of its own.
  # The browser owns the caret and selection there. An inactive editable
  # surface draws the server marker, so its window still shows point.
  defp render_pass(static, text, point, mark, native_caret?, show_cursor?) do
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
      # at_point says the same thing WITHOUT that gate: the completion card
      # anchors to the line point is on, and that line is exactly the one
      # the client owns the caret for, so keying the card off `current`
      # meant it could never draw in an editable buffer.
      at_point = point >= line.start and point <= le
      current = not native_caret? and at_point
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
              if(show_cursor? and point < cursor_end and is_nil(image_at_point),
                do: {point, cursor_end, "cursor"}
              )
            ]
            |> Enum.reject(&is_nil/1)

          # through line_segs, not seg_build: the cursor's own line takes the
          # same long-line guard as every other one, and on a one-line buffer
          # this is the only line there is
          segs =
            line_segs(
              line.part,
              line.start,
              line.ts,
              line.ov ++ overlays,
              Map.get(line, :chrome, [])
            )

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
          if show_cursor? and point >= line.start and point == le,
            do: segs ++ [{@cursor_placeholder, "cursor"}],
            else: segs
        else
          line.segs
        end

      %{
        num: line.num,
        current: current,
        at_point: at_point,
        selected: line.selected,
        start: line.start,
        row: Map.get(line, :row, ""),
        segs: segs
      }
    end)
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

end
