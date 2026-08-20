defmodule Aimax.Core.LSP.Pos do
  @moduledoc """
  Byte offsets <-> LSP positions (line + character).

  Buffers speak byte offsets; LSP speaks zero-based lines and a
  `character` counted in the negotiated position encoding — UTF-16 code
  units by default, bytes under utf-8. Every conversion clamps: servers
  send positions past line ends and past the last line, and a stale
  position must degrade to a nearby one, never crash the pipeline.

  `line_starts/1` is the shared index — compute it once per text
  snapshot and pass it to each conversion in a batch (a
  publishDiagnostics burst converts hundreds of positions).
  """

  @doc "Byte offsets of every line start, as a tuple: {0, ...}."
  def line_starts(text) do
    starts =
      :binary.matches(text, "\n")
      |> Enum.map(fn {pos, _} -> pos + 1 end)

    List.to_tuple([0 | starts])
  end

  @doc "Byte position -> %{line, character} in ENC (:utf16 | :utf8)."
  def to_lsp(text, starts, byte_pos, enc) do
    n = byte_size(text)
    pos = byte_pos |> max(0) |> min(n)
    line = line_of(starts, pos)
    bol = elem(starts, line)
    prefix = binary_part(text, bol, pos - bol)
    %{line: line, character: units(prefix, enc)}
  end

  @doc "%{\"line\", \"character\"} (or atom keys) -> clamped byte position."
  def from_lsp(text, starts, lsp_pos, enc) do
    line = pos_field(lsp_pos, :line)
    char = pos_field(lsp_pos, :character)
    last = tuple_size(starts) - 1
    line = line |> max(0) |> min(last)
    bol = elem(starts, line)
    eol = line_end(text, starts, line)
    advance(text, bol, eol, char, enc)
  end

  @doc "An LSP range -> {start_byte, end_byte}, clamped."
  def range_to_bytes(text, starts, range, enc) do
    s = from_lsp(text, starts, field(range, :start), enc)
    e = from_lsp(text, starts, field(range, :end), enc)
    {min(s, e), max(s, e)}
  end

  # --- internals --------------------------------------------------------------

  defp field(map, key), do: map[key] || map[to_string(key)] || %{}
  defp pos_field(map, key), do: map[key] || map[to_string(key)] || 0

  # last line whose start is <= pos (binary search over the tuple)
  defp line_of(starts, pos), do: line_of(starts, pos, 0, tuple_size(starts) - 1)

  defp line_of(_starts, _pos, lo, hi) when lo >= hi, do: lo

  defp line_of(starts, pos, lo, hi) do
    mid = div(lo + hi + 1, 2)

    if elem(starts, mid) <= pos,
      do: line_of(starts, pos, mid, hi),
      else: line_of(starts, pos, lo, mid - 1)
  end

  defp line_end(text, starts, line) do
    if line + 1 < tuple_size(starts),
      do: elem(starts, line + 1) - 1,
      else: byte_size(text)
  end

  defp units(bin, :utf8), do: byte_size(bin)

  defp units(bin, :utf16) do
    case :unicode.characters_to_binary(bin, :utf8, {:utf16, :big}) do
      b when is_binary(b) -> div(byte_size(b), 2)
      {:incomplete, b, _} -> div(byte_size(b), 2) + 1
      {:error, b, _} -> div(byte_size(b), 2) + 1
    end
  end

  defp advance(_text, bol, eol, char, :utf8), do: min(bol + max(char, 0), eol)

  defp advance(text, bol, eol, char, :utf16) do
    walk(binary_part(text, bol, eol - bol), max(char, 0), bol)
  end

  defp walk(_rest, units, at) when units <= 0, do: at

  defp walk(<<cp::utf8, rest::binary>>, units, at) do
    used = if cp > 0xFFFF, do: 2, else: 1
    bytes = byte_size(<<cp::utf8>>)
    walk(rest, units - used, at + bytes)
  end

  # invalid byte: count it as one unit so the walk still terminates
  defp walk(<<_, rest::binary>>, units, at), do: walk(rest, units - 1, at + 1)
  defp walk(<<>>, _units, at), do: at
end
