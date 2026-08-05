defmodule Aimax.Core.Rope do
  @moduledoc """
  Immutable rope over binaries. **Byte offsets** throughout — matches
  tree-sitter's edit API; callers own grapheme/codepoint concerns.

  Persistence makes undo free: old versions share structure.

  TODO: rebalancing (currently trees can skew under pathological edit
  patterns) and line-index caching for O(log n) line->byte lookup.
  """

  @max_leaf 512

  defstruct root: {:leaf, ""}

  def new(text \\ ""), do: %__MODULE__{root: build(text)}

  def to_binary(%__MODULE__{root: root}), do: IO.iodata_to_binary(collect(root))

  def byte_size(%__MODULE__{root: root}), do: size(root)

  def insert(%__MODULE__{root: root} = rope, pos, text) when pos >= 0 do
    if pos > size(root), do: raise(ArgumentError, "insert out of bounds")
    {l, r} = split(root, pos)
    %{rope | root: concat(concat(l, build(text)), r)}
  end

  def delete(%__MODULE__{root: root} = rope, pos, len) when pos >= 0 and len >= 0 do
    if pos + len > size(root), do: raise(ArgumentError, "delete out of bounds")
    {l, rest} = split(root, pos)
    {_mid, r} = split(rest, len)
    %{rope | root: concat(l, r)}
  end

  def slice(%__MODULE__{root: root}, pos, len) do
    {_, rest} = split(root, pos)
    {mid, _} = split(rest, len)
    IO.iodata_to_binary(collect(mid))
  end

  # --- internals -------------------------------------------------------------

  defp size({:leaf, bin}), do: Kernel.byte_size(bin)
  defp size({:node, _, _, total}), do: total

  defp build(text) when Kernel.byte_size(text) <= @max_leaf, do: {:leaf, text}

  defp build(text) do
    half = div(Kernel.byte_size(text), 2)
    <<l::binary-size(half), r::binary>> = text
    concat(build(l), build(r))
  end

  defp concat({:leaf, ""}, b), do: b
  defp concat(a, {:leaf, ""}), do: a

  defp concat({:leaf, a}, {:leaf, b}) when Kernel.byte_size(a) + Kernel.byte_size(b) <= @max_leaf,
    do: {:leaf, a <> b}

  defp concat(a, b), do: {:node, a, b, size(a) + size(b)}

  defp split({:leaf, bin}, pos) do
    <<l::binary-size(pos), r::binary>> = bin
    {{:leaf, l}, {:leaf, r}}
  end

  defp split({:node, l, r, _}, pos) do
    ls = size(l)

    cond do
      pos < ls ->
        {ll, lr} = split(l, pos)
        {ll, concat(lr, r)}

      pos > ls ->
        {rl, rr} = split(r, pos - ls)
        {concat(l, rl), rr}

      true ->
        {l, r}
    end
  end

  defp collect({:leaf, bin}), do: [bin]
  defp collect({:node, l, r, _}), do: [collect(l) | collect(r)]
end
