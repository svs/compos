defmodule Aimax.Core.DiffView do
  @moduledoc """
  The unified diff, shaped into cards a side-by-side view can draw.

  `Aimax.Core.Git` parses the text; this turns hunks into rows. A row pairs
  one deleted line with the added line that replaced it, so the reader sees
  old and new beside each other, and the intra-line diff says which part of
  the line actually changed.

  This is a projection, not state. It reads the buffer text — the unified
  diff itself — plus which cards the reader opened. The card view and the
  plain view therefore read the same bytes and can never disagree.
  """

  # a hunk with more than this many context rows in a run collapses the
  # middle: the reader came for the changes
  @diff_context_run 6

  def cards(text, open, status) do
    text
    |> Aimax.Core.Git.parse()
    |> Enum.with_index(1)
    |> Enum.map(fn {f, i} ->
      name = diff_name(f)

      %{
        id: i,
        file: name,
        old_file: if(f.file_a in [nil, "/dev/null"], do: nil, else: f.file_a),
        status: diff_status(f, Map.get(status, name)),
        binary?: f.binary?,
        open: MapSet.member?(open, name),
        start_line: nil,
        hunks: Enum.map(f.hunks, &diff_hunk/1)
      }
    end)
    |> diff_anchor(text)
  end

  defp diff_name(%{file_b: b}) when is_binary(b) and b != "/dev/null", do: b
  defp diff_name(%{file_a: a}) when is_binary(a), do: a
  defp diff_name(_), do: "?"

  # git's XY columns say more than the diff does: untracked, staged, both
  defp diff_status(f, xy) do
    cond do
      xy in ["??", "?"] -> "untracked"
      f.file_a in [nil, "/dev/null"] -> "added"
      f.file_b in [nil, "/dev/null"] -> "deleted"
      f.file_a != f.file_b -> "renamed"
      f.binary? -> "binary"
      true -> "modified"
    end
  end

  # which buffer line each card starts on, so point can select one
  defp diff_anchor(cards, text) do
    starts =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {l, _} -> String.starts_with?(l, "diff --git a/") end)
      |> Enum.map(&elem(&1, 1))

    cards
    |> Enum.zip(starts ++ List.duplicate(nil, max(length(cards) - length(starts), 0)))
    |> Enum.map(fn {card, line} -> %{card | start_line: line} end)
  end

  @doc "The file whose card contains this 1-based buffer line, or nil."
  def current_file([], _line), do: nil

  def current_file(cards, line) do
    cards
    |> Enum.filter(&(&1.start_line != nil and &1.start_line <= line))
    |> List.last()
    |> case do
      nil -> nil
      card -> card.file
    end
  end

  defp diff_hunk(h) do
    %{
      header: h.header,
      old_start: h.old_start,
      new_start: h.new_start,
      rows: h.lines |> diff_rows(h.old_start, h.new_start) |> collapse_context()
    }
  end

  # pair each run of deletions with the run of additions that follows it, so
  # a changed line shows old on the left and new on the right
  defp diff_rows(lines, old_no, new_no), do: diff_rows(lines, old_no, new_no, [])

  defp diff_rows([], _o, _n, acc), do: Enum.reverse(acc)

  defp diff_rows([{:ctx, t} | rest], o, n, acc),
    do: diff_rows(rest, o + 1, n + 1, [row(:ctx, o, n, t, t, nil, nil) | acc])

  defp diff_rows([{:del, _} | _] = lines, o, n, acc) do
    {dels, rest} = Enum.split_while(lines, &(elem(&1, 0) == :del))
    {adds, rest} = Enum.split_while(rest, &(elem(&1, 0) == :add))
    {rows, o, n} = pair_runs(Enum.map(dels, &elem(&1, 1)), Enum.map(adds, &elem(&1, 1)), o, n)
    diff_rows(rest, o, n, Enum.reverse(rows) ++ acc)
  end

  defp diff_rows([{:add, t} | rest], o, n, acc),
    do: diff_rows(rest, o, n + 1, [row(:add, nil, n, nil, t, nil, nil) | acc])

  defp pair_runs(dels, adds, o, n) do
    count = max(length(dels), length(adds))

    Enum.reduce(0..(count - 1)//1, {[], o, n}, fn i, {rows, o, n} ->
      del = Enum.at(dels, i)
      add = Enum.at(adds, i)

      case {del, add} do
        {nil, add} -> {[row(:add, nil, n, nil, add, nil, nil) | rows], o, n + 1}
        {del, nil} -> {[row(:del, o, nil, del, nil, nil, nil) | rows], o + 1, n}
        {del, add} ->
          {dr, ar} = word_ranges(del, add)
          {[row(:mod, o, n, del, add, dr, ar) | rows], o + 1, n + 1}
      end
    end)
    |> then(fn {rows, o, n} -> {Enum.reverse(rows), o, n} end)
  end

  defp row(kind, old_no, new_no, old_text, new_text, old_words, new_words) do
    {oa, ob, oc} = split(old_text, old_words)
    {na, nb, nc} = split(new_text, new_words)

    %{
      kind: kind,
      old_no: old_no,
      new_no: new_no,
      old: old_text,
      new: new_text,
      old_words: old_words,
      new_words: new_words,
      # the three parts the view prints as text·emphasis·text. Split here,
      # because the cell renders with pre-wrap and a template that computed
      # them inline would leak its own indentation into the line.
      old_parts: {oa, ob, oc},
      new_parts: {na, nb, nc}
    }
  end

  @doc "One line as (before, changed, after) for the word-diff emphasis."
  def split(nil, _), do: {"", "", ""}
  def split(text, nil), do: {text, "", ""}

  def split(text, {s, e}) do
    s = min(s, byte_size(text))
    e = min(e, byte_size(text))

    {binary_part(text, 0, s), binary_part(text, s, e - s),
     binary_part(text, e, byte_size(text) - e)}
  end

  # intra-line diff, v1: strip the common prefix and the common suffix and
  # emphasise what is left. It is exact when one span changed, which is what
  # most edited lines are, and it never lies about the ends.
  defp word_ranges(del, add) do
    p = common_prefix_len(del, add)
    s = common_suffix_len(binary_part(del, p, byte_size(del) - p), binary_part(add, p, byte_size(add) - p))

    dmid = byte_size(del) - p - s
    amid = byte_size(add) - p - s

    if dmid <= 0 and amid <= 0,
      do: {nil, nil},
      else: {{p, p + dmid}, {p, p + amid}}
  end

  defp common_prefix_len(a, b), do: common_prefix_len(a, b, 0)

  defp common_prefix_len(a, b, i) do
    if i < byte_size(a) and i < byte_size(b) and :binary.at(a, i) == :binary.at(b, i),
      do: common_prefix_len(a, b, i + 1),
      else: utf8_boundary_down(a, i)
  end

  defp common_suffix_len(a, b), do: common_suffix_len(a, b, 0)

  defp common_suffix_len(a, b, i) do
    sa = byte_size(a) - 1 - i
    sb = byte_size(b) - 1 - i

    if sa >= 0 and sb >= 0 and :binary.at(a, sa) == :binary.at(b, sb),
      do: common_suffix_len(a, b, i + 1),
      else: i
  end

  # never split a multi-byte character: walk back off a continuation byte
  defp utf8_boundary_down(_bin, 0), do: 0

  defp utf8_boundary_down(bin, i) do
    if i < byte_size(bin) and Bitwise.band(:binary.at(bin, i), 0xC0) == 0x80,
      do: utf8_boundary_down(bin, i - 1),
      else: i
  end

  # a long run of unchanged rows becomes one separator
  defp collapse_context(rows) do
    rows
    |> Enum.chunk_by(&(&1.kind == :ctx))
    |> Enum.flat_map(fn chunk ->
      if hd(chunk).kind == :ctx and length(chunk) > @diff_context_run do
        keep = div(@diff_context_run, 2)
        head = Enum.take(chunk, keep)
        tail = Enum.take(chunk, -keep)
        head ++ [%{kind: :gap, count: length(chunk) - 2 * keep}] ++ tail
      else
        chunk
      end
    end)
  end
end
