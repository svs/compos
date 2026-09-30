defmodule Compos.Core.TextProps do
  @moduledoc """
  Text properties: values attached to the text, as Emacs `src/intervals.c`
  attaches them.

  One `Compos.Core.Itree` per property holds the spans that carry a value.
  Spans of one property never overlap, and two adjacent spans never hold
  the same value: `put/5` joins them. A position with no span has no
  value, and `nil` or `false` as a value removes the span, because the
  Emacs API cannot tell the two apart.

  Inserted text takes properties by the Emacs stickiness rules: a
  property is rear-sticky by default, so text typed at the end of a span
  joins the span. A property named in the default nonsticky list, or in
  the `rear-nonsticky` property of the character before the insert, does
  not grow. No property is front-sticky: text typed at the start of a
  span stays outside it.

  The map is a plain value: the buffer holds it, edits return a new one,
  and a reader that holds the old one sees the old positions.
  """

  alias Compos.Core.Itree

  @type t :: %{optional(String.t()) => Itree.t()}

  @nonsticky_key {__MODULE__, :nonsticky}

  @doc "No properties."
  def new, do: %{}

  @doc "The property names that do not grow over text typed at their end."
  def default_nonsticky, do: :persistent_term.get(@nonsticky_key, [])

  @doc "Add PROP to the default nonsticky list, or take it out."
  def set_default_nonsticky(prop, on?) when is_binary(prop) do
    list = List.delete(default_nonsticky(), prop)
    :persistent_term.put(@nonsticky_key, if(on?, do: [prop | list], else: list))
    :ok
  end

  @doc "Give START..STOP the property PROP with VALUE. `nil` or `false` removes it."
  def put(props, start, stop, prop, value) when value in [nil, false],
    do: remove(props, start, stop, [prop])

  def put(props, start, stop, _prop, _value) when start >= stop, do: props

  def put(props, start, stop, prop, value) do
    tree = props |> Map.get(prop) |> cut(start, stop)

    # join a neighbour that holds the same value
    {start, tree} =
      case Itree.at(tree, start - 1) do
        [{b, ^start, v}] when v === value ->
          {_, tree} = Itree.remove_between(tree, b, b + 1)
          {b, tree}

        _ ->
          {start, tree}
      end

    {stop, tree} =
      case Itree.at(tree, stop) do
        [{^stop, e, v}] when v === value ->
          {_, tree} = Itree.remove_between(tree, stop, stop + 1)
          {e, tree}

        _ ->
          {stop, tree}
      end

    Map.put(props, prop, Itree.insert(tree, start, stop, value))
  end

  @doc "Take the properties PROPS off START..STOP."
  def remove(props, start, stop, _names) when start >= stop, do: props

  def remove(props, start, stop, names) do
    Enum.reduce(names, props, fn prop, props ->
      case Map.fetch(props, prop) do
        {:ok, tree} ->
          case cut(tree, start, stop) do
            nil -> Map.delete(props, prop)
            tree -> Map.put(props, prop, tree)
          end

        :error ->
          props
      end
    end)
  end

  # TREE without any coverage of START..STOP. A span that reaches past the
  # cut on either side keeps its outer part.
  defp cut(tree, start, stop) do
    {removed, tree} = Itree.remove_between(tree, start, stop)

    tree =
      Enum.reduce(removed, tree, fn
        {_b, e, v}, t when e > stop -> Itree.insert(t, stop, e, v)
        _, t -> t
      end)

    case Itree.at(tree, start) do
      [{b, e, v}] ->
        {_, tree} = Itree.remove_between(tree, b, b + 1)
        tree = Itree.insert(tree, b, start, v)
        if e > stop, do: Itree.insert(tree, stop, e, v), else: tree

      [] ->
        tree
    end
  end

  @doc "The value of PROP at POS, or nil."
  def get(props, pos, prop) do
    case Map.get(props, prop) do
      nil -> nil
      tree -> value_at(tree, pos)
    end
  end

  defp value_at(tree, pos) do
    case Itree.at(tree, pos) do
      [{_, _, v}] -> v
      [] -> nil
    end
  end

  @doc "Every property at POS, as `{prop, value}` pairs."
  def at(props, pos) do
    Enum.flat_map(props, fn {prop, tree} ->
      case value_at(tree, pos) do
        nil -> []
        v -> [{prop, v}]
      end
    end)
  end

  @doc "The first position after POS where PROP changes, or nil."
  def next_change(props, pos, prop) do
    case Map.get(props, prop) do
      nil ->
        nil

      tree ->
        case Itree.at(tree, pos) do
          [{_, e, _}] -> e
          [] -> Itree.next_begin(tree, pos + 1)
        end
    end
  end

  @doc "The last position before POS where PROP changes, or nil."
  def previous_change(props, pos, prop) do
    case Map.get(props, prop) do
      nil ->
        nil

      tree ->
        case Itree.at(tree, pos - 1) do
          [{b, _, _}] ->
            b

          [] ->
            # the span before POS ends before POS: its end is the change
            case Itree.prev_begin(tree, pos) do
              nil -> nil
              b -> tree |> Itree.at(b) |> hd() |> elem(1)
            end
        end
    end
  end

  @doc "The first position in START..STOP where PROP is VALUE, or nil."
  def any(props, start, stop, prop, value) when value in [nil, false] do
    spans = Itree.query(Map.get(props, prop), start, stop)

    Enum.reduce_while(spans, start, fn {b, e, _}, cur ->
      if b > cur, do: {:halt, {:found, cur}}, else: {:cont, max(cur, e)}
    end)
    |> case do
      {:found, pos} -> pos
      cur when cur < stop -> cur
      _ -> nil
    end
  end

  def any(props, start, stop, prop, value) do
    Map.get(props, prop)
    |> Itree.query(start, stop)
    |> Enum.find_value(fn {b, _, v} -> if v === value, do: max(b, start) end)
  end

  @doc "LEN bytes went in at POS. Sticky properties grow over them."
  def insert_gap(props, _pos, 0), do: props

  def insert_gap(props, pos, len) when map_size(props) == 0 and is_integer(pos) and is_integer(len),
    do: props

  def insert_gap(props, pos, len) do
    nonsticky = default_nonsticky()

    rear =
      case Map.get(props, "rear-nonsticky") do
        nil ->
          nil

        tree ->
          case Itree.at(tree, pos - 1) do
            [{_, ^pos, v}] -> v
            _ -> nil
          end
      end

    Map.new(props, fn {prop, tree} ->
      if sticky?(prop, nonsticky, rear) do
        {prop, Itree.insert_gap(tree, pos, len, true)}
      else
        # Emacs splits the interval around the insert, so the new text
        # takes no value from a span it went into
        {prop, tree |> split_at(pos) |> Itree.insert_gap(pos, len, false)}
      end
    end)
  end

  defp split_at(tree, pos) do
    case Itree.at(tree, pos) do
      [{b, e, v}] when b < pos ->
        {_, tree} = Itree.remove_between(tree, b, b + 1)
        tree |> Itree.insert(b, pos, v) |> Itree.insert(pos, e, v)

      _ ->
        tree
    end
  end

  defp sticky?(prop, nonsticky, rear) do
    prop not in nonsticky and not rear_nonsticky?(rear, prop)
  end

  defp rear_nonsticky?(nil, _prop), do: false
  defp rear_nonsticky?(true, _prop), do: true
  defp rear_nonsticky?({:sym, "t"}, _prop), do: true
  defp rear_nonsticky?(list, prop) when is_list(list), do: Enum.any?(list, &(name(&1) == prop))
  defp rear_nonsticky?(_, _prop), do: false

  defp name({:sym, s}), do: s
  defp name(s), do: s

  @doc "LEN bytes went out at POS."
  def delete_gap(props, _pos, 0), do: props

  def delete_gap(props, pos, len) do
    props
    |> Enum.flat_map(fn {prop, tree} ->
      case tree |> Itree.delete_gap(pos, len) |> join_at(pos) do
        nil -> []
        tree -> [{prop, tree}]
      end
    end)
    |> Map.new()
  end

  # Two spans that the delete made neighbours, with one value, become one.
  defp join_at(nil, _pos), do: nil

  defp join_at(tree, pos) do
    with [{b, ^pos, v}] <- Itree.at(tree, pos - 1),
         [{^pos, e, v2}] <- Itree.at(tree, pos),
         true <- v === v2 do
      {_, tree} = Itree.remove_between(tree, b, pos + 1)
      Itree.insert(tree, b, e, v)
    else
      _ -> tree
    end
  end

  @doc "The spans of PROP as `{start, stop, value}`, in order."
  def spans(props, prop), do: props |> Map.get(prop) |> Itree.to_list()
end
