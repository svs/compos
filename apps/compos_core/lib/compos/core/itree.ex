defmodule Compos.Core.Itree do
  @moduledoc """
  A persistent interval tree: the position structure under overlays,
  folds, and text properties.

  The edit rules and the gap walks are a port of Emacs `src/itree.c`
  (`itree_insert_gap`, `itree_delete_gap`, the `limit` augmentation, and
  the lazy `offset`). The balancing is a weight-balanced tree in the
  style of Haskell's `Data.Map`, because a functional tree is persistent
  with no extra work: every edit returns a new root and the old root
  stays valid, so a reader that holds a snapshot never sees a half-done
  edit.

  Copyright (C) 2022-2024 Free Software Foundation, Inc.
  This file is part of GNU Emacs derived work, under the GNU General
  Public License version 3 or later.

  ## Shape

  A node is the tuple `{begin, end, data, offset, limit, size, left, right}`
  and the empty tree is `nil`. The true position of a node adds `offset`
  and the `offset` of every ancestor to `begin` and `end`. `limit` is the
  largest `end` in the subtree, in the same frame as `begin`. `size` is
  the node count. Nodes sort by `begin`; equal begins keep insertion
  order.

  ## Cost

  `insert/4`, `insert_gap/3` and `delete_gap/3` cost O(log n + k), where
  k is the number of ranges that touch the edit point. `query/3` costs
  O(log n + k) for k results. `remove_between/3` costs O(log n) plus the
  removed nodes. `from_list/1` costs O(n) on a sorted list.

  ## Edit rules

  These are the rules `Compos.Core.Buffer` applied to a plain list:

  - an insert at POS moves a `begin` at or after POS, and an `end` after
    POS (Emacs front-advance, no rear-advance). A caller can ask for
    rear-advance, which also moves an `end` at POS: a rear-sticky text
    property grows over text typed at its end.
  - a delete of POS..POS+LEN pulls a position inside the gap to POS and
    a position after the gap back by LEN. A range that closes to nothing
    is dropped.
  - a range of zero length is a point: it moves like a `begin`.
  """

  @type t :: nil | tuple()
  @type range :: {non_neg_integer(), non_neg_integer(), term()}

  # Data.Map's balance parameters.
  @delta 3
  @ratio 2

  @doc "The empty tree."
  def new, do: nil

  @doc "Node count."
  def size(nil), do: 0
  def size({_, _, _, _, _, sz, _, _}), do: sz

  def empty?(nil), do: true
  def empty?(_), do: false

  @doc "Add the range BEGIN..END with DATA. BEGIN must not exceed END."
  def insert(t, b, e, d) when is_integer(b) and is_integer(e) and b <= e, do: ins(t, b, e, d)

  defp ins(nil, b, e, d), do: node(b, e, d, nil, nil)

  defp ins(t, b, e, d) do
    {nb, ne, nd, 0, _, _, l, r} = norm(t)

    if b < nb,
      do: balance(nb, ne, nd, ins(l, b, e, d), r),
      else: balance(nb, ne, nd, l, ins(r, b, e, d))
  end

  @doc "A balanced tree from a list of `{begin, end, data}`, in any order."
  def from_list([]), do: nil

  def from_list(list) do
    sorted = Enum.sort_by(list, fn {b, _, _} -> b end)
    {t, []} = build(sorted, length(sorted))
    t
  end

  defp build(rest, 0), do: {nil, rest}

  defp build(rest, n) do
    nl = div(n - 1, 2)
    {l, [{b, e, d} | rest]} = build(rest, nl)
    {r, rest} = build(rest, n - 1 - nl)
    {node(b, e, d, l, r), rest}
  end

  @doc "Every range in begin order, at its true position."
  def to_list(t), do: t |> walk(0, []) |> Enum.reverse()

  defp walk(nil, _, acc), do: acc

  defp walk({b, e, d, off, _, _, l, r}, k, acc) do
    k = k + off
    acc = walk(l, k, acc)
    walk(r, k, [{b + k, e + k, d} | acc])
  end

  @doc """
  The ranges that touch START..STOP, in begin order: `begin < STOP` and
  `end > START`. A point at START counts. A point at STOP does not.
  """
  def query(t, start, stop), do: t |> q(start, stop, 0, []) |> Enum.reverse()

  defp q(nil, _, _, _, acc), do: acc

  defp q({b, e, d, off, lim, _, l, r}, start, stop, k, acc) do
    k = k + off

    cond do
      lim + k < start ->
        acc

      true ->
        acc = q(l, start, stop, k, acc)
        tb = b + k
        te = e + k

        cond do
          tb >= stop -> acc
          te > start or (tb == te and tb >= start) -> q(r, start, stop, k, [{tb, te, d} | acc])
          true -> q(r, start, stop, k, acc)
        end
    end
  end

  @doc "The ranges that hold POS: `begin <= POS < end`."
  def at(t, pos), do: t |> at(pos, 0, []) |> Enum.reverse()

  defp at(nil, _, _, acc), do: acc

  defp at({b, e, d, off, lim, _, l, r}, pos, k, acc) do
    k = k + off

    if lim + k <= pos do
      acc
    else
      acc = at(l, pos, k, acc)
      tb = b + k

      cond do
        tb > pos -> acc
        e + k > pos -> at(r, pos, k, [{tb, e + k, d} | acc])
        true -> at(r, pos, k, acc)
      end
    end
  end

  @doc "The smallest `begin` at or after POS, or nil."
  def next_begin(t, pos), do: nb(t, pos, 0, nil)

  defp nb(nil, _, _, best), do: best

  defp nb({b, _, _, off, _, _, l, r}, pos, k, best) do
    k = k + off
    tb = b + k

    if tb >= pos,
      do: nb(l, pos, k, tb),
      else: nb(r, pos, k, best)
  end

  @doc "The largest `begin` before POS, or nil."
  def prev_begin(t, pos), do: pb(t, pos, 0, nil)

  defp pb(nil, _, _, best), do: best

  defp pb({b, _, _, off, _, _, l, r}, pos, k, best) do
    k = k + off
    tb = b + k

    if tb < pos,
      do: pb(r, pos, k, tb),
      else: pb(l, pos, k, best)
  end

  @doc """
  Remove every range whose `begin` is in START..STOP. Returns the removed
  ranges in begin order and the tree without them.
  """
  def remove_between(t, start, stop) when start <= stop do
    {lt, rest} = split(t, start)
    {mid, gt} = split(rest, stop)
    {to_list(mid), merge(lt, gt)}
  end

  @doc "Drop the ranges for which FUN returns true. O(n)."
  def reject(t, fun), do: t |> to_list() |> Enum.reject(fn {b, e, d} -> fun.({b, e, d}) end) |> from_list()

  @doc "Keep the ranges for which FUN returns true. O(n)."
  def filter(t, fun), do: t |> to_list() |> Enum.filter(fn {b, e, d} -> fun.({b, e, d}) end) |> from_list()

  @doc """
  Text of LEN bytes went in at POS. A `begin` at or after POS moves by
  LEN, and so does an `end` after POS. With REAR_ADVANCE an `end` at POS
  moves too. A point at POS moves.
  """
  def insert_gap(t, pos, len, rear_advance \\ false)
  def insert_gap(t, _pos, 0, _), do: t
  def insert_gap(t, pos, len, rear_advance), do: ig(t, pos, len, rear_advance)

  defp ig(nil, _, _, _), do: nil

  defp ig({_, _, _, off, lim, _, _, _} = t, pos, len, ra) do
    # Nothing here ends at or after POS, so nothing here begins at POS
    # either: the subtree stays as it is.
    if lim + off < pos do
      t
    else
      {b, e, d, 0, _, _, l, r} = norm(t)
      l = ig(l, pos, len, ra)
      # Every begin to the right is at least B. When B is at or past
      # POS, the whole right subtree moves by one offset write.
      r = if b >= pos, do: shift(r, len), else: ig(r, pos, len, ra)
      b2 = if b >= pos, do: b + len, else: b
      e2 = if e > pos or (e == pos and (ra or b == pos)), do: e + len, else: e
      node(b2, e2, d, l, r)
    end
  end

  @doc """
  LEN bytes went out at POS. A position inside the gap moves to POS. A
  position after the gap moves back by LEN. A range that closes is
  dropped.
  """
  def delete_gap(t, _pos, 0), do: t
  def delete_gap(t, pos, len), do: dg(t, pos, len)

  defp dg(nil, _, _), do: nil

  defp dg({_, _, _, off, lim, _, _, _} = t, pos, len) do
    if lim + off < pos do
      t
    else
      {b, e, d, 0, _, _, l, r} = norm(t)
      l = dg(l, pos, len)
      r = if b >= pos + len, do: shift(r, -len), else: dg(r, pos, len)
      b2 = if b > pos, do: max(pos, b - len), else: b
      e2 = if e > pos, do: max(pos, e - len), else: e

      cond do
        # a point stays a point; a range that closed goes
        b == e -> link(b2, e2, d, l, r)
        b2 >= e2 -> merge(l, r)
        true -> link(b2, e2, d, l, r)
      end
    end
  end

  @doc "True when the tree keeps its invariants. For tests."
  def valid?(t), do: check(t, 0) != :error

  defp check(nil, _), do: {nil, nil, -1, 0}

  defp check({b, e, d, off, lim, sz, l, r}, k) do
    k = k + off

    with {lmin, lmax, llim, lsz} <- check(l, k),
         {rmin, rmax, rlim, rsz} <- check(r, k),
         true <- b <= e or {:error, :order, d},
         true <- sz == lsz + rsz + 1 or {:error, :size},
         true <- lim + k == Enum.max([e + k, llim, rlim]) or {:error, :limit},
         true <- is_nil(lmax) or lmax <= b + k or {:error, :left_key},
         true <- is_nil(rmin) or rmin >= b + k or {:error, :right_key},
         true <- lsz + rsz <= 1 or (lsz <= @delta * rsz and rsz <= @delta * lsz) or {:error, :balance} do
      {lmin || b + k, rmax || b + k, lim + k, sz}
    else
      _ -> :error
    end
  end

  # --- nodes -------------------------------------------------------------

  defp lim_of(nil), do: -1
  defp lim_of({_, _, _, off, lim, _, _, _}), do: lim + off

  defp node(b, e, d, l, r) do
    {b, e, d, 0, max(e, max(lim_of(l), lim_of(r))), size(l) + size(r) + 1, l, r}
  end

  # Push the offset down, so begin, end and limit are in the parent's frame.
  defp norm({_, _, _, 0, _, _, _, _} = n), do: n

  defp norm({b, e, d, off, lim, sz, l, r}),
    do: {b + off, e + off, d, 0, lim + off, sz, shift(l, off), shift(r, off)}

  defp shift(nil, _), do: nil
  defp shift(n, 0), do: n
  defp shift({b, e, d, off, lim, sz, l, r}, k), do: {b, e, d, off + k, lim, sz, l, r}

  # --- balance (Data.Map) --------------------------------------------------

  defp balance(b, e, d, l, r) do
    sl = size(l)
    sr = size(r)

    cond do
      sl + sr <= 1 -> node(b, e, d, l, r)
      sr > @delta * sl -> rotate_l(b, e, d, l, norm(r))
      sl > @delta * sr -> rotate_r(b, e, d, norm(l), r)
      true -> node(b, e, d, l, r)
    end
  end

  defp rotate_l(b, e, d, l, {rb, re, rd, 0, _, _, rl, rr}) do
    if size(rl) < @ratio * size(rr) do
      node(rb, re, rd, node(b, e, d, l, rl), rr)
    else
      {mb, me, md, 0, _, _, ml, mr} = norm(rl)
      node(mb, me, md, node(b, e, d, l, ml), node(rb, re, rd, mr, rr))
    end
  end

  defp rotate_r(b, e, d, {lb, le, ld, 0, _, _, ll, lr}, r) do
    if size(lr) < @ratio * size(ll) do
      node(lb, le, ld, ll, node(b, e, d, lr, r))
    else
      {mb, me, md, 0, _, _, ml, mr} = norm(lr)
      node(mb, me, md, node(lb, le, ld, ll, ml), node(b, e, d, mr, r))
    end
  end

  # Join L and R around one node. Every begin in L is at most B, and every
  # begin in R is at least B. L and R are balanced; their sizes are free.
  defp link(b, e, d, nil, r), do: insert_min(b, e, d, r)
  defp link(b, e, d, l, nil), do: insert_max(b, e, d, l)

  defp link(b, e, d, l, r) do
    sl = size(l)
    sr = size(r)

    cond do
      @delta * sl < sr ->
        {rb, re, rd, 0, _, _, rl, rr} = norm(r)
        balance(rb, re, rd, link(b, e, d, l, rl), rr)

      @delta * sr < sl ->
        {lb, le, ld, 0, _, _, ll, lr} = norm(l)
        balance(lb, le, ld, ll, link(b, e, d, lr, r))

      true ->
        node(b, e, d, l, r)
    end
  end

  defp insert_min(b, e, d, nil), do: node(b, e, d, nil, nil)

  defp insert_min(b, e, d, t) do
    {tb, te, td, 0, _, _, l, r} = norm(t)
    balance(tb, te, td, insert_min(b, e, d, l), r)
  end

  defp insert_max(b, e, d, nil), do: node(b, e, d, nil, nil)

  defp insert_max(b, e, d, t) do
    {tb, te, td, 0, _, _, l, r} = norm(t)
    balance(tb, te, td, l, insert_max(b, e, d, r))
  end

  # Join L and R with nothing between them.
  defp merge(nil, r), do: r
  defp merge(l, nil), do: l

  defp merge(l, r) do
    sl = size(l)
    sr = size(r)

    cond do
      @delta * sl < sr ->
        {rb, re, rd, 0, _, _, rl, rr} = norm(r)
        balance(rb, re, rd, merge(l, rl), rr)

      @delta * sr < sl ->
        {lb, le, ld, 0, _, _, ll, lr} = norm(l)
        balance(lb, le, ld, ll, merge(lr, r))

      true ->
        glue(l, r)
    end
  end

  defp glue(nil, r), do: r
  defp glue(l, nil), do: l

  defp glue(l, r) do
    if size(l) > size(r) do
      {{b, e, d}, l} = delete_max(l)
      balance(b, e, d, l, r)
    else
      {{b, e, d}, r} = delete_min(r)
      balance(b, e, d, l, r)
    end
  end

  defp delete_min(t) do
    case norm(t) do
      {b, e, d, 0, _, _, nil, r} ->
        {{b, e, d}, r}

      {b, e, d, 0, _, _, l, r} ->
        {m, l} = delete_min(l)
        {m, balance(b, e, d, l, r)}
    end
  end

  defp delete_max(t) do
    case norm(t) do
      {b, e, d, 0, _, _, l, nil} ->
        {{b, e, d}, l}

      {b, e, d, 0, _, _, l, r} ->
        {m, r} = delete_max(r)
        {m, balance(b, e, d, l, r)}
    end
  end

  # Nodes with begin before K, and nodes with begin at or after K.
  defp split(nil, _), do: {nil, nil}

  defp split(t, k) do
    {b, e, d, 0, _, _, l, r} = norm(t)

    if b < k do
      {ll, lg} = split(r, k)
      {link(b, e, d, l, ll), lg}
    else
      {ll, lg} = split(l, k)
      {ll, link(b, e, d, lg, r)}
    end
  end
end
