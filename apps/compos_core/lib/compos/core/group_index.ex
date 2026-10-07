defmodule Compos.Core.GroupIndex do
  @moduledoc """
  Which buffers name which group, kept beside the buffer read model.

  Membership lives on the buffer: a chat holds one `group-id`, any other
  buffer a `group-ids` list. "Which buffers are in group G" so meant a read
  of every buffer. This index answers it from ETS instead. `BufferView`
  calls `update/2` for every row it publishes and `drop/1` for every row it
  forgets, so the index holds what the rows hold, live and dormant, and
  needs no hook of its own.

  The same rows file each buffer under `{:mode, MODE}` and under `{:has,
  LOCAL}` for the few locals in `@flags`, so "every chat" and "every buffer
  in mode M" are lookups too.

  It is ephemeral: the tables die with `BufferView` and refill as the
  buffers publish again. It files the raw values the locals hold, not
  resolved groups. Scheme still decides membership (aliases, stale ids),
  over the few candidates rather than every buffer. A row only the slow
  path can settle (several ids, a legacy `group` or `companion-of`) is
  filed under `:slow`, so every reader sees it.
  """

  @keys :compos_group_keys
  @members :compos_group_members

  # locals a list asks "who holds this" about: an agent is listed with the
  # chats even when its buffer is no chat
  @flags ["agent-slug"]

  @doc "Create the tables. `BufferView` owns them, so they live as long as the rows."
  def new_tables do
    if :ets.whereis(@keys) == :undefined,
      do: :ets.new(@keys, [:named_table, :public, :set, read_concurrency: true])

    if :ets.whereis(@members) == :undefined,
      do: :ets.new(@members, [:named_table, :public, :bag, read_concurrency: true])

    :ets.delete_all_objects(@keys)
    :ets.delete_all_objects(@members)
    :ok
  end

  @doc "Whether the index exists. A daemon started before it has none."
  def ready?, do: :ets.whereis(@members) != :undefined

  @doc """
  The keys a row files under, and whether it is context-only. The group
  rule is the one `group-members-of` applies: a chat by its `group-id`,
  any other buffer by its one `group-ids` entry.
  """
  def keys_of(%{} = locals) do
    mode = Map.get(locals, "mode-name")
    has = for f <- @flags, set?(Map.get(locals, f)), do: {:has, f}
    keys = group_keys(locals) ++ if(is_binary(mode), do: [{:mode, mode}], else: []) ++ has
    {keys, Map.get(locals, "context-only") == true}
  end

  def keys_of(_), do: {[], false}

  defp group_keys(locals) do
    gids = Map.get(locals, "group-ids")
    gid = Map.get(locals, "group-id")

    cond do
      set?(Map.get(locals, "group")) or set?(Map.get(locals, "companion-of")) -> [:slow]
      Map.get(locals, "mode-name") == "chat-mode" -> if is_binary(gid), do: [gid], else: []
      is_list(gids) and length(gids) > 1 -> [:slow]
      match?([id] when is_binary(id), gids) -> gids
      true -> []
    end
  end

  defp group_key?(k), do: is_binary(k) or k == :slow

  # a Scheme value is set unless it is #f: the empty list is set
  defp set?(v), do: v not in [nil, false]

  @doc "File NAME under the keys VIEW's locals give. A row that keeps its keys costs one lookup."
  def update(name, view) when is_binary(name) do
    {keys, ctx} = keys_of(Map.get(view, :locals))

    case :ets.lookup(@keys, name) do
      [{^name, ^keys, ^ctx}] ->
        :ok

      [] when keys == [] and not ctx ->
        :ok

      old ->
        unfile(name, old)

        if keys == [] and not ctx do
          :ets.delete(@keys, name)
        else
          :ets.insert(@keys, {name, keys, ctx})
          :ets.insert(@members, Enum.map(keys, &{&1, name}))
        end

        :ok
    end
  rescue
    # no tables (see `ready?/0`): the readers fall back to their scan
    ArgumentError -> :ok
  end

  def update(_, _), do: :ok

  @doc "Forget NAME. The rename path and a kill call this through `BufferView.forget/1`."
  def drop(name) when is_binary(name) do
    unfile(name, :ets.lookup(@keys, name))
    :ets.delete(@keys, name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def drop(_), do: :ok

  defp unfile(name, old) do
    for {_, keys, _} <- old, k <- keys, do: :ets.delete_object(@members, {k, name})
  end

  @doc """
  The NAMES, in their order, filed under any of KEYS or under `:slow`.
  `:error` when there is no index.
  """
  def select(names, keys), do: filed(names, [:slow | keys])

  @doc """
  The NAMES, in their order, filed under any of KEYS: a group key, `{:mode,
  MODE}` or `{:has, LOCAL}`. `:error` when there is no index.
  """
  def filed(names, keys) do
    if ready?() do
      hits =
        keys
        |> Enum.flat_map(fn k -> :ets.lookup(@members, k) end)
        |> MapSet.new(fn {_, name} -> name end)

      names |> Enum.uniq() |> Enum.filter(&MapSet.member?(hits, &1))
    else
      :error
    end
  end

  @doc "Every buffer name, most recently used first, as `buffer-list-mru` gives them."
  def mru, do: Compos.Core.Editor.buffer_mru()

  @doc "`mru/0` and then the live buffers it leaves out, the internal ones."
  def all, do: Enum.uniq(mru() ++ Compos.Core.list_buffers())

  @doc """
  The NAMES by their mode: `[{mode, [name ...]}]`, each in the order of
  NAMES, a repeated name once, the modes in the order of their first
  name. `:error` when there is no index.
  """
  def modes(names) do
    if ready?() do
      names
      |> Enum.uniq()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {name, i}, acc ->
        case :ets.lookup(@keys, name) do
          [{_, keys, _}] ->
            Enum.reduce(keys, acc, fn
              {:mode, m}, acc ->
                Map.update(acc, m, {i, [name]}, fn {f, ns} -> {f, [name | ns]} end)

              _, acc ->
                acc
            end)

          _ ->
            acc
        end
      end)
      |> Enum.sort_by(fn {_, {first, _}} -> first end)
      |> Enum.map(fn {m, {_, ns}} -> {m, Enum.reverse(ns)} end)
    else
      :error
    end
  end

  @doc "`[{mode, count}]` over every row, sorted by mode: what changes when a mode gains or loses a buffer."
  def mode_counts do
    if ready?() do
      fn {_, keys, _}, acc ->
        Enum.reduce(keys, acc, fn
          {:mode, m}, acc -> Map.update(acc, m, 1, &(&1 + 1))
          _, acc -> acc
        end)
      end
      |> :ets.foldl(%{}, @keys)
      |> Enum.sort()
    else
      :error
    end
  end

  @doc """
  The NAMES that are not context-only, bucketed by key: `[{key, [name ...]}]`,
  each bucket in the order of NAMES, a repeated name once. `:error` when
  there is no index.
  """
  def buckets(names) do
    if ready?() do
      names
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn name, acc ->
        case :ets.lookup(@keys, name) do
          [{_, keys, false}] ->
            keys
            |> Enum.filter(&group_key?/1)
            |> Enum.reduce(acc, &Map.update(&2, &1, [name], fn ns -> [name | ns] end))

          _ ->
            acc
        end
      end)
      |> Enum.map(fn {k, ns} -> {k, Enum.reverse(ns)} end)
    else
      :error
    end
  end
end
