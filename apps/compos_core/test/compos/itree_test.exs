defmodule Compos.ItreeTest do
  @moduledoc """
  The interval tree against the plain list it replaced: the same edits
  must leave the same ranges. The list model below is the old
  `Buffer.adjust_ranges/3`, and the property model is a map from position
  to value, which is what a text property means.
  """
  use ExUnit.Case, async: true

  alias Compos.Core.{Buffer, Itree, TextProps}

  defmodule ListModel do
    # the old rules: a begin at or after POS moves, an end after POS moves,
    # a delete pulls positions into the gap to POS and drops closed ranges.
    # A range of zero length is a point and moves like a begin.
    def insert_gap(list, pos, len) do
      Enum.map(list, fn {s, e, d} ->
        s2 = if s >= pos, do: s + len, else: s
        e2 = if e > pos or (e == pos and s == pos), do: e + len, else: e
        {s2, e2, d}
      end)
    end

    def delete_gap(list, pos, len) do
      list
      |> Enum.map(fn {s, e, d} -> {adj(s, pos, len), adj(e, pos, len), d, s == e} end)
      |> Enum.reject(fn {s, e, _, point?} -> s >= e and not point? end)
      |> Enum.map(fn {s, e, d, _} -> {s, e, d} end)
    end

    defp adj(p, pos, len) do
      cond do
        p <= pos -> p
        p >= pos + len -> p - len
        true -> pos
      end
    end

    def query(list, a, z),
      do: Enum.filter(list, fn {s, e, _} -> s < z and (e > a or (s == e and s >= a)) end)

    def sorted(list), do: Enum.sort_by(list, fn {s, _, d} -> {s, d} end)
  end

  defmodule PropModel do
    def put(m, s, e, prop, v) do
      Enum.reduce(s..(e - 1)//1, m, fn p, m ->
        if v in [nil, false], do: Map.delete(m, {p, prop}), else: Map.put(m, {p, prop}, v)
      end)
    end

    def remove(m, s, e, props) do
      Enum.reduce(props, m, fn prop, m ->
        Enum.reduce(s..(e - 1)//1, m, fn p, m -> Map.delete(m, {p, prop}) end)
      end)
    end

    # the new text takes the value of the character before it, when the
    # property is sticky; a property is never front-sticky
    def insert_gap(m, pos, len, nonsticky) do
      shifted = Map.new(m, fn {{p, prop}, v} -> {{if(p >= pos, do: p + len, else: p), prop}, v} end)

      before =
        m
        |> Enum.filter(fn {{p, prop}, _} -> p == pos - 1 and prop not in nonsticky end)
        |> Enum.flat_map(fn {{_, prop}, v} -> Enum.map(pos..(pos + len - 1), &{{&1, prop}, v}) end)
        |> Map.new()

      Map.merge(shifted, before)
    end

    def delete_gap(m, pos, len) do
      m
      |> Enum.reject(fn {{p, _}, _} -> p >= pos and p < pos + len end)
      |> Map.new(fn {{p, prop}, v} -> {{if(p >= pos + len, do: p - len, else: p), prop}, v} end)
    end

    def get(m, pos, prop), do: Map.get(m, {pos, prop})
  end

  describe "edit rules" do
    test "an insert before a range moves it, inside it grows it, at its end stays outside" do
      t = Itree.from_list([{2, 4, "f"}])
      assert Itree.to_list(Itree.insert_gap(t, 0, 2)) == [{4, 6, "f"}]
      assert Itree.to_list(Itree.insert_gap(t, 3, 1)) == [{2, 5, "f"}]
      assert Itree.to_list(Itree.insert_gap(t, 4, 1)) == [{2, 4, "f"}]
      # at the start: the range moves and the text stays outside
      assert Itree.to_list(Itree.insert_gap(t, 2, 1)) == [{3, 5, "f"}]
      # rear-advance, for a sticky text property
      assert Itree.to_list(Itree.insert_gap(t, 4, 1, true)) == [{2, 5, "f"}]
    end

    test "a delete pulls positions into the gap and drops a closed range" do
      t = Itree.from_list([{2, 4, "f"}, {6, 9, "g"}])
      assert Itree.to_list(Itree.delete_gap(t, 0, 1)) == [{1, 3, "f"}, {5, 8, "g"}]
      assert Itree.to_list(Itree.delete_gap(t, 3, 4)) == [{2, 3, "f"}, {3, 5, "g"}]
      assert Itree.to_list(Itree.delete_gap(t, 1, 4)) == [{2, 5, "g"}]
    end

    test "a point moves like a begin and survives a delete" do
      t = Itree.from_list([{5, 5, "chrome"}])
      assert Itree.to_list(Itree.insert_gap(t, 5, 3)) == [{8, 8, "chrome"}]
      assert Itree.to_list(Itree.insert_gap(t, 6, 3)) == [{5, 5, "chrome"}]
      assert Itree.to_list(Itree.delete_gap(t, 3, 4)) == [{3, 3, "chrome"}]
    end

    test "a query answers the ranges that touch a span, in order" do
      t = Itree.from_list([{0, 5, "a"}, {3, 8, "b"}, {8, 9, "c"}, {20, 30, "d"}])
      assert Itree.query(t, 4, 8) == [{0, 5, "a"}, {3, 8, "b"}]
      assert Itree.query(t, 8, 21) == [{8, 9, "c"}, {20, 30, "d"}]
      assert Itree.at(t, 4) == [{0, 5, "a"}, {3, 8, "b"}]
      assert Itree.at(t, 5) == [{3, 8, "b"}]
    end

    test "remove_between takes out the ranges that begin in a span" do
      t = Itree.from_list([{0, 5, "a"}, {3, 8, "b"}, {8, 9, "c"}])
      {removed, rest} = Itree.remove_between(t, 3, 8)
      assert removed == [{3, 8, "b"}]
      assert Itree.to_list(rest) == [{0, 5, "a"}, {8, 9, "c"}]
    end
  end

  describe "against the list model" do
    test "10k random inserts, deletes and range writes leave the same ranges" do
      :rand.seed(:exsss, {11, 22, 33})
      size = 3000

      {tree, model, _} =
        Enum.reduce(1..10_000, {nil, [], 0}, fn i, {tree, model, n} ->
          {tree, model, n} =
            case :rand.uniform(5) do
              1 ->
                s = :rand.uniform(size) - 1
                e = min(size, s + :rand.uniform(40) - 1)
                {Itree.insert(tree, s, e, i), model ++ [{s, e, i}], n + 1}

              2 ->
                pos = :rand.uniform(size) - 1
                len = :rand.uniform(12)
                {Itree.insert_gap(tree, pos, len), ListModel.insert_gap(model, pos, len), n}

              3 ->
                pos = :rand.uniform(size) - 1
                len = :rand.uniform(12)
                {Itree.delete_gap(tree, pos, len), ListModel.delete_gap(model, pos, len), n}

              4 ->
                # a range write: the overlays that begin in a span go, new ones come
                a = :rand.uniform(size) - 1
                z = a + :rand.uniform(60)
                {_, t} = Itree.remove_between(tree, a, z)
                fresh = for j <- 1..:rand.uniform(3), s = min(a + j, z - 1), do: {s, min(z, s + 5), {i, j}}
                t = Enum.reduce(fresh, t, fn {s, e, d}, t -> Itree.insert(t, s, e, d) end)
                {t, Enum.reject(model, fn {s, _, _} -> s >= a and s < z end) ++ fresh, n}

              _ ->
                {tree, model, n}
            end

          assert Itree.valid?(tree), "invalid tree at step #{i}"
          assert ListModel.sorted(Itree.to_list(tree)) == ListModel.sorted(model), "step #{i}"

          a = :rand.uniform(size) - 1
          z = a + :rand.uniform(100)

          assert ListModel.sorted(Itree.query(tree, a, z)) ==
                   ListModel.sorted(ListModel.query(model, a, z)),
                 "query #{a}..#{z} at step #{i}"

          {tree, model, n}
        end)

      assert Itree.size(tree) == length(model)
    end

    test "text properties agree with a map from position to value" do
      :rand.seed(:exsss, {4, 5, 6})
      TextProps.set_default_nonsticky("zz-nonsticky", true)
      names = ["zz-face", "zz-nonsticky", "zz-other"]

      {props, model, tlen} =
        Enum.reduce(1..4000, {TextProps.new(), %{}, 400}, fn i, {props, model, tlen} ->
          {props, model, tlen} =
            case :rand.uniform(5) do
              1 ->
                s = :rand.uniform(tlen) - 1
                e = min(tlen, s + :rand.uniform(20))
                prop = Enum.random(names)
                v = Enum.random([1, 2, 3, nil])
                {TextProps.put(props, s, e, prop, v), PropModel.put(model, s, e, prop, v), tlen}

              2 ->
                s = :rand.uniform(tlen) - 1
                e = min(tlen, s + :rand.uniform(20))
                {TextProps.remove(props, s, e, ["zz-face"]), PropModel.remove(model, s, e, ["zz-face"]), tlen}

              3 ->
                pos = :rand.uniform(tlen + 1) - 1
                len = :rand.uniform(5)

                {TextProps.insert_gap(props, pos, len), PropModel.insert_gap(model, pos, len, ["zz-nonsticky"]),
                 tlen + len}

              4 ->
                pos = :rand.uniform(tlen) - 1
                len = min(tlen - pos, :rand.uniform(5))
                {TextProps.delete_gap(props, pos, len), PropModel.delete_gap(model, pos, len), tlen - len}

              _ ->
                {props, model, tlen}
            end

          for {prop, tree} <- props do
            assert Itree.valid?(tree), "invalid #{prop} tree at step #{i}"

            tree
            |> Itree.to_list()
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.each(fn [{_, e1, v1}, {s2, _, v2}] ->
              assert e1 <= s2, "#{prop} spans overlap at step #{i}"
              refute e1 == s2 and v1 === v2, "#{prop} has two spans where one would do, at step #{i}"
            end)
          end

          for p <- 0..(tlen - 1), prop <- names do
            assert TextProps.get(props, p, prop) == PropModel.get(model, p, prop),
                   "#{prop} at #{p} differs at step #{i}"
          end

          p = :rand.uniform(tlen) - 1
          prop = Enum.random(names)
          v = PropModel.get(model, p, prop)
          scan = Enum.find((p + 1)..(tlen - 1)//1, fn q -> PropModel.get(model, q, prop) != v end)
          got = TextProps.next_change(props, p, prop)
          got = if got != nil and got >= tlen, do: nil, else: got
          assert got == scan, "next change of #{prop} after #{p} differs at step #{i}"

          {props, model, tlen}
        end)

      assert map_size(model) > 0
      assert tlen > 0
      assert Enum.all?(props, fn {_, t} -> Itree.valid?(t) end)
    after
      TextProps.set_default_nonsticky("zz-nonsticky", false)
    end
  end

  describe "through a buffer" do
    test "overlays, folds and a text property move with real edits as the list did" do
      name = "zz-itree-#{System.unique_integer([:positive])}"
      text = String.duplicate("the quick brown fox jumps over the lazy dog\n", 40)
      {:ok, _} = Compos.Core.create_buffer(name, text: text)
      on_exit(fn -> Compos.Core.kill_buffer(name) end)
      :rand.seed(:exsss, {9, 9, 9})

      overlays = for i <- 0..199, do: {i * 8, i * 8 + 5, "f#{rem(i, 3)}"}
      folds = for i <- 0..19, do: {i * 80 + 10, i * 80 + 30}
      :ok = Buffer.set_overlays(name, "t", overlays)
      :ok = Buffer.set_hidden(name, "org", folds)
      :ok = Buffer.put_text_property(name, 100, 300, "zz-mark", 1)

      model = %{
        overlays: overlays,
        folds: Enum.map(folds, fn {s, e} -> {s, e, nil} end),
        props: [{100, 300, 1}]
      }

      Enum.reduce(1..300, model, fn _, model ->
        size = Buffer.byte_size(name)

        model =
          if :rand.uniform(2) == 1 do
            pos = :rand.uniform(size + 1) - 1
            :ok = Buffer.insert_at(name, pos, "ab")
            # a text property is rear-sticky: the list rule with rear-advance
            %{
              overlays: ListModel.insert_gap(model.overlays, pos, 2),
              folds: ListModel.insert_gap(model.folds, pos, 2),
              props: Enum.map(model.props, fn {s, e, v} ->
                {if(s >= pos, do: s + 2, else: s), if(e >= pos, do: e + 2, else: e), v}
              end)
            }
          else
            pos = :rand.uniform(max(size, 1)) - 1
            len = min(size - pos, :rand.uniform(3))
            :ok = Buffer.delete_range(name, pos, len)

            %{
              overlays: ListModel.delete_gap(model.overlays, pos, len),
              folds: ListModel.delete_gap(model.folds, pos, len),
              props: ListModel.delete_gap(model.props, pos, len)
            }
          end

        assert ListModel.sorted(Buffer.overlays(name, "t")) == ListModel.sorted(model.overlays)
        assert Buffer.hidden(name, "org") == Enum.map(ListModel.sorted(model.folds), fn {s, e, _} -> {s, e} end)
        assert Buffer.text_property_spans(name, "zz-mark") == model.props
        model
      end)
    end
  end
end
