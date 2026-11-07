defmodule Compos.Core.WindowSpec do
  @moduledoc """
  The saved shape of a frame's windows: what the desktop writes and what
  `Editor.restore_tree/3` lays back. One window is its leaf; more are a
  row, left to right.

      %{type: :leaf, buffer: name, top: line, manual: bool, ctop: px, id: id | nil, share: n, dock: bool}
      %{type: :row, children: [leaf, ...]}

  `id` is the window id the leaf had. It is a wish, not a claim: a restore
  keeps it when no other window holds it. `share` is the leaf's part of the
  row's width; a `dock` spans the frame under the row, and its share is its
  part of the height.

  `read/1` is the one reader. It takes a spec, or any shape an older
  desktop file holds, and answers a spec. An older file's split tree reads
  as its leaves, at equal shares.
  """

  @doc "The spec of a frame's windows: a leaf, or a row."
  def from_tree(%{children: c}), do: %{type: :row, children: Enum.flat_map(c, &leaves(from_tree(&1)))}

  def from_tree(%{type: :leaf, buffer: b} = leaf) do
    %{
      type: :leaf,
      buffer: b,
      top: Map.get(leaf, :top, 0),
      manual: Map.get(leaf, :manual, false),
      ctop: Map.get(leaf, :ctop, 0),
      id: Map.get(leaf, :id),
      share: Map.get(leaf, :share, 1),
      dock: Map.get(leaf, :dock, false)
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
      id: want(Map.get(spec, :id)),
      share: Map.get(spec, :share) || 1,
      dock: Map.get(spec, :dock) == true
    }
  end

  def read(%{children: c}), do: %{type: :row, children: Enum.flat_map(c, &leaves/1)}

  # The tuples of older desktop files, read by position:
  #   {:leaf, buffer, top, point, manual, ctop, history, restore, owner, id}
  # each shape a prefix of the next. Point, history, restore and owner are
  # dropped: a restore never writes point, and Scheme keeps the rest.
  def read({:split, _dir, a, b}), do: read(%{children: [a, b]})
  def read({:split, _dir, _ratio, a, b}), do: read(%{children: [a, b]})

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

  @doc "The leaves of a spec, left to right."
  def leaves(spec) do
    case read(spec) do
      %{type: :row, children: c} -> c
      leaf -> [leaf]
    end
  end

  @doc "Every buffer a spec names, in leaf order."
  def buffers(%{type: :leaf, buffer: b}) when is_binary(b), do: [b]
  def buffers(%{children: c}), do: Enum.flat_map(c, &buffers/1)
  def buffers(_), do: []

  defp want(id) when is_integer(id), do: id
  defp want(_), do: nil
end
