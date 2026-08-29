defmodule Compos.Core.Text do
  @moduledoc """
  Byte-offset text geometry over binaries — the shared hot-path helpers.
  Everything here is O(line) or O(pos) *time* with O(1) allocation; nothing
  materializes match lists or grapheme lists proportional to buffer size.
  """

  @doc "{beginning-of-line, end-of-line} byte offsets for the line containing pos."
  def line_bounds(text, pos) do
    total = byte_size(text)

    eol =
      case :binary.match(text, "\n", scope: {pos, total - pos}) do
        :nomatch -> total
        {off, _} -> off
      end

    {scan_bol(text, pos), eol}
  end

  # walk back to the byte after the previous newline
  defp scan_bol(_text, 0), do: 0

  defp scan_bol(text, pos) do
    if :binary.at(text, pos - 1) == ?\n, do: pos, else: scan_bol(text, pos - 1)
  end

  @doc "{1-based line, byte column} of pos. O(pos) time, no allocation."
  def line_col(text, pos) do
    {line, bol} = count_lines(text, 0, pos, 0, 0)
    {line + 1, pos - bol}
  end

  @doc "0-based line index of pos (newlines strictly before pos)."
  def line_index(text, pos), do: count_lines(text, 0, pos, 0, 0) |> elem(0)

  @doc "Number of newlines in text."
  def newline_count(text), do: count_lines(text, 0, byte_size(text), 0, 0) |> elem(0)

  defp count_lines(text, from, upto, line, bol) do
    case :binary.match(text, "\n", scope: {from, upto - from}) do
      :nomatch -> {line, bol}
      {i, _} -> count_lines(text, i + 1, upto, line + 1, i + 1)
    end
  end

  @doc """
  Byte offset n graphemes before pos. Scans a bounded window instead of
  materializing every grapheme before pos; the window doubles until it
  yields enough graphemes (cluster boundaries at a window's torn front
  edge are untrusted unless the window reaches offset 0).
  """
  def back_graphemes(_text, 0, _n), do: 0

  def back_graphemes(text, pos, n) do
    back_window(text, pos, n, min(pos, max(n * 8, 64)))
  end

  defp back_window(text, pos, n, window) do
    start = align_utf8(text, pos - window)
    chunk = binary_part(text, start, pos - start)
    sizes = grapheme_sizes(chunk, [])

    # the first grapheme after a torn front edge may be a partial cluster —
    # only trust it when the window starts at the buffer's beginning
    usable = if start == 0, do: sizes, else: tl_safe(sizes)

    cond do
      length(usable) >= n -> pos - (usable |> Enum.take(n) |> Enum.sum())
      start == 0 -> 0
      true -> back_window(text, pos, n, window * 4)
    end
  end

  # move forward off UTF-8 continuation bytes (0b10xxxxxx) to a codepoint start
  defp align_utf8(_text, i) when i <= 0, do: 0

  defp align_utf8(text, i) do
    import Bitwise
    if (:binary.at(text, i) &&& 0b1100_0000) == 0b1000_0000, do: align_utf8(text, i + 1), else: i
  end

  # grapheme byte sizes, last-first (so taking n from the head walks backward)
  defp grapheme_sizes(bin, acc) do
    case String.next_grapheme(bin) do
      nil -> acc
      {g, rest} -> grapheme_sizes(rest, [byte_size(g) | acc])
    end
  end

  # sizes are last-first, so the torn front-edge grapheme is the final element
  defp tl_safe(list), do: Enum.drop(list, -1)
end
