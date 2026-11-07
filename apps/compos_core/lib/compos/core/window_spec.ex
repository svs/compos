defmodule Compos.Core.WindowSpec do
  @moduledoc """
  The saved shape of a window tree: what the desktop writes and what
  `Editor.restore_tree/3` lays back.

      %{type: :leaf, buffer: name, top: line, manual: bool, ctop: px, id: id | nil}
      %{type: :split, dir: :h | :v, ratio: float, children: [spec, spec]}

  `id` is the window id the leaf had. It is a wish, not a claim: a restore
  keeps it when no other window holds it.

  `read/1` is the one reader. It takes a spec, or any tuple shape an older
  desktop file holds, and answers a spec.
  """

  @doc "The spec of a live window tree."
  def from_tree(%{type: :leaf, buffer: b} = leaf) do
    %{
      type: :leaf,
      buffer: b,
      top: Map.get(leaf, :top, 0),
      manual: Map.get(leaf, :manual, false),
      ctop: Map.get(leaf, :ctop, 0),
      id: Map.get(leaf, :id)
    }
  end

  def from_tree(%{type: :split, dir: dir, children: [a, b]} = split) do
    %{
      type: :split,
      dir: dir,
      ratio: Map.get(split, :ratio, 0.5),
      children: [from_tree(a), from_tree(b)]
    }
  end

  @doc "A spec from a spec or from any older saved shape; missing keys take their defaults."
  def read(%{type: :leaf, buffer: b} = spec) do
    ctop = Map.get(spec, :ctop) || 0

    %{
      type: :leaf,
      buffer: b,
      top: Map.get(spec, :top) || 0,
      # a saved offset is itself the pin (S1)
      manual: Map.get(spec, :manual) == true or ctop > 0,
      ctop: ctop,
      id: want(Map.get(spec, :id))
    }
  end

  def read(%{type: :split, dir: dir, children: [a, b]} = spec),
    do: %{
      type: :split,
      dir: dir,
      ratio: Map.get(spec, :ratio) || 0.5,
      children: [read(a), read(b)]
    }

  # A desktop saved by the flat-row Editor of 2026-11-07: a row of leaves,
  # each with its share of the width; a :col stacks leaves by vshare. It
  # reads as a chain of splits that keeps each share. A dock leaf held the
  # prompt, which a restore does not bring back.
  def read(%{type: :row, children: c}), do: chain(:h, c, :share)
  def read(%{type: :col, children: c}), do: chain(:v, c, :vshare)

  # The tuples of older desktop files, read by position:
  #   {:leaf, buffer, top, point, manual, ctop, history, restore, owner, id}
  # each shape a prefix of the next. Point, history, restore and owner are
  # dropped: a restore never writes point, and Scheme keeps the rest.
  def read({:split, dir, a, b}), do: read({:split, dir, 0.5, a, b})

  def read({:split, dir, ratio, a, b}),
    do: read(%{type: :split, dir: dir, ratio: ratio, children: [a, b]})

  def read(leaf) when is_tuple(leaf) and tuple_size(leaf) >= 2 and elem(leaf, 0) == :leaf do
    at = fn i -> if tuple_size(leaf) > i, do: elem(leaf, i) end

    read(%{
      type: :leaf,
      buffer: elem(leaf, 1),
      top: at.(2),
      manual: at.(4),
      ctop: at.(5),
      id: at.(9)
    })
  end

  @doc "Every buffer a spec names, in leaf order."
  def buffers(%{type: :leaf, buffer: b}) when is_binary(b), do: [b]
  def buffers(%{type: :split, children: c}), do: Enum.flat_map(c, &buffers/1)
  def buffers(_), do: []

  defp chain(dir, children, key) do
    items =
      for c <- children, Map.get(c, :dock) != true do
        {read(c), share(Map.get(c, key))}
      end

    case items do
      [] -> read(%{type: :leaf, buffer: nil})
      _ -> link(dir, items)
    end
  end

  defp link(_dir, [{spec, _}]), do: spec

  defp link(dir, [{spec, s} | rest]) do
    total = s + Enum.reduce(rest, 0, fn {_, r}, acc -> acc + r end)
    %{type: :split, dir: dir, ratio: s / total, children: [spec, link(dir, rest)]}
  end

  defp share(n) when is_number(n) and n > 0, do: n
  defp share(_), do: 1

  defp want(id) when is_integer(id), do: id
  defp want(_), do: nil
end
