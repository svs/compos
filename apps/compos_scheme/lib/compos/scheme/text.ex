defmodule Compos.Scheme.Text do
  @moduledoc """
  Byte offsets, snapped to character boundaries.

  Points in this editor are byte offsets, and they travel: through stored
  marker state, through a display payload, through a tool result on its way
  to a JSON encoder. Any of them can land mid-codepoint after an edit the
  offset did not see. A mid-codepoint slice is invalid UTF-8, which the
  rope NIF rejects hard enough to kill a buffer process and which the JSON
  encoder refuses outright — so every cut snaps to a boundary first.

  This lived four times: in the Scheme builtins, in the display renderer,
  and in the agent backend's card truncation. Lowest layer in the umbrella,
  so all three can reach it.

  A UTF-8 continuation byte is `0b10xxxxxx` — 128..191. Every other byte
  starts a character.
  """

  @doc "The largest boundary offset at or below `at`."
  @spec floor_utf8(binary, integer) :: non_neg_integer
  def floor_utf8(_bin, at) when at <= 0, do: 0
  def floor_utf8(bin, at) when at >= byte_size(bin), do: byte_size(bin)

  def floor_utf8(bin, at) do
    case :binary.at(bin, at) do
      b when b >= 128 and b < 192 -> floor_utf8(bin, at - 1)
      _ -> at
    end
  end

  @doc "The smallest boundary offset at or above `at`."
  @spec ceil_utf8(binary, integer) :: non_neg_integer
  def ceil_utf8(_bin, at) when at <= 0, do: 0
  def ceil_utf8(bin, at) when at >= byte_size(bin), do: byte_size(bin)

  def ceil_utf8(bin, at) do
    case :binary.at(bin, at) do
      b when b >= 128 and b < 192 -> ceil_utf8(bin, at + 1)
      _ -> at
    end
  end

  @doc """
  `bin` cut to at most `max` bytes on a character boundary, with `ellipsis`
  appended when anything was dropped.
  """
  @spec truncate(binary, non_neg_integer, binary) :: binary
  def truncate(bin, max, ellipsis \\ "…") do
    if byte_size(bin) > max do
      binary_part(bin, 0, floor_utf8(bin, max)) <> ellipsis
    else
      bin
    end
  end

  @doc "The `from..to` byte slice of `bin`, both ends snapped inward to boundaries."
  @spec slice(binary, integer, integer) :: binary
  def slice(bin, from, to) do
    from = from |> max(0) |> min(byte_size(bin)) |> then(&floor_utf8(bin, &1))
    to = to |> max(from) |> min(byte_size(bin)) |> then(&floor_utf8(bin, &1))
    binary_part(bin, from, to - from)
  end
end
