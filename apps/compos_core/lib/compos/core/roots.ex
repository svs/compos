defmodule Compos.Core.Roots do
  @moduledoc """
  The GC root table: every Scheme value that Elixir holds outside the
  interpreter store.

  A closure that leaves Scheme (a handler, a callback that waits for a
  reply, a timer's function, a task's result) is invisible to the frame
  GC, which sees only the store and the roots the Session hands it. An
  entry here is such a root: the GC keeps the frames the value captures
  for as long as the entry stays.

  The table belongs to `Compos.Core.SchemeTables`, which keeps it across
  a Session restart. A call before the table exists (a unit test with no
  Session) roots nothing: there is no GC to defend against, so `put/2`
  answers false and every read answers nil.

  Two kinds of entry:

    * a slot: a single handler under a fixed key such as `{:on_event, "lsp"}`,
      set by a Scheme primitive and read on every event. `put/2` stores
      the value, because the table is also where the reader finds it;
    * a hold: a callback under a fresh key such as `{:llm, ref}`, put
      before the value escapes and dropped once the callback fired. The
      owner keeps the value, and no code reads a hold back. `hold/2`
      stores only the frames the value captures.

  ETS copies a term on each write and each read. A hold that stored its
  value kept a second copy of each callback body and each task result:
  196 MB of task results on a dev daemon.
  """

  @table :compos_escaped_closures

  @doc "The table name, for the GC's root set and the Session's special cases."
  def table, do: @table

  defp table?, do: :ets.whereis(@table) != :undefined

  @doc "Root VALUE under KEY. Answers false when there is no table."
  def put(key, value) do
    if table?() do
      :ets.insert(@table, {key, value})
      true
    else
      false
    end
  end

  @doc """
  Root the frames that VALUE captures under KEY, and not VALUE itself.
  Use it for a value that its owner keeps and no code reads back from
  the table. The entry is one closure with no body for each frame, so
  the GC and every other reader of the table see a term they know.
  Answers false when there is no table.
  """
  def hold(key, value) do
    frames = value |> Compos.Scheme.Env.closure_refs([]) |> Enum.uniq()
    put(key, Enum.map(frames, &{:closure, [], [], &1}))
  end

  @doc "The value under KEY, or nil."
  def get(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{_, value}] -> value
        [] -> nil
      end
    end
  end

  @doc """
  Remove KEY and answer its value, or nil, in one step. Use it where the
  entry must be consumed once: two callers never both get the value.
  """
  def take(key) do
    if table?() do
      case :ets.take(@table, key) do
        [{_, value}] -> value
        [] -> nil
      end
    end
  end

  @doc "Remove KEY. Answers :ok whether or not it was there."
  def drop(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Every entry, for the GC's root set."
  def all, do: if(table?(), do: :ets.tab2list(@table), else: [])

  @doc """
  The entries grouped by the kind of their key, largest first: a list of
  `{kind, count, bytes, largest_key}`. It reads one entry at a time, so
  the caller never holds a copy of the whole table.
  """
  def summary do
    if table?() do
      word = :erlang.system_info(:wordsize)

      fn {key, value}, acc ->
        bytes = :erts_debug.flat_size(value) * word
        Map.update(acc, kind(key), {1, bytes, bytes, key}, &add(&1, bytes, key))
      end
      |> :ets.foldl(%{}, @table)
      |> Enum.map(fn {kind, {count, bytes, _max, key}} -> {kind, count, bytes, key} end)
      |> Enum.sort_by(&elem(&1, 2), :desc)
    else
      []
    end
  end

  defp add({count, bytes, max, _key}, more, key) when more > max, do: {count + 1, bytes + more, more, key}
  defp add({count, bytes, max, key}, more, _key), do: {count + 1, bytes + more, max, key}

  defp kind(key) when is_tuple(key) and tuple_size(key) > 0, do: kind(elem(key, 0))
  defp kind(key) when is_atom(key), do: Atom.to_string(key)
  defp kind(_key), do: "other"
end
