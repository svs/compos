defmodule Compos.Core.Recent do
  @moduledoc """
  The recent order: buffer names and `{:group, name}` marks, the most
  recent first. C-x b, the tab row and meta.db read it.

  The order has one owner and no mailbox in front of it. Each entry is
  one row of a public ETS table with a sequence number, so a bump is one
  insert, atomic from any process: the Editor, a Scheme lane, a browser
  click. A read sorts the rows in the reader's own process. The Editor
  writes its bumps in its own process and never waits on another one.

  The first 500 entries are the history the switcher reads. A group mark
  that falls out of them stays, 50 at most, so buffer visits never
  make the editor forget which group came last. A bury gives the buffer a
  number below every other, so it goes last.
  """

  use GenServer

  @table :compos_recent
  @window 500
  @group_tail 50
  @buried_max 200
  # rows above window + tail before a prune: a prune sorts the table
  @slack 64
  @scratch "*scratch*"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    seed(Enum.uniq([@scratch | Compos.Core.BufferStore.history()]))
    {:ok, nil}
  end

  @doc "Start the store when a daemon loaded this module by hot reload."
  def ready do
    if :ets.whereis(@table) == :undefined,
      do: Supervisor.start_child(Compos.Core.Supervisor, __MODULE__)

    :ok
  end

  @doc "Make ENTRY the most recent."
  def bump(entry) do
    seq = :ets.update_counter(@table, :"$seq", 1, {:"$seq", 0})
    :ets.insert(@table, {entry, seq})
    prune()
  rescue
    ArgumentError -> :ok
  end

  @doc "Put BUFFER last, as Emacs bury-buffer does. Nothing else moves."
  def bury(buffer) do
    low = :ets.update_counter(@table, :"$low", -1, {:"$low", 0})
    :ets.insert(@table, {buffer, low})
    Compos.Core.MetaDb.bury(buffer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drop BUFFER from the order: it died."
  def forget(buffer) do
    :ets.delete(@table, buffer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Carry OLD's place to NEW. Of two places, the more recent stays."
  def rename(old, new) do
    case :ets.lookup(@table, old) do
      [{^old, seq}] ->
        :ets.delete(@table, old)

        case :ets.lookup(@table, new) do
          [{^new, had}] when had > seq -> :ok
          _ -> :ets.insert(@table, {new, seq})
        end

      [] ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Every entry, the most recent first, buried ones last."
  def order, do: Enum.map(rows(), &elem(&1, 0))

  @doc "The first buffer name in the order that FUN accepts, or nil."
  def find_buffer(fun), do: Enum.find(order(), &(is_binary(&1) and fun.(&1)))

  @doc """
  The buffer names: the recent ones in order, every other known buffer
  sorted, the buried last. Space-prefixed names are internal and hidden.
  """
  def buffers do
    ready()
    known = MapSet.new(Compos.Core.buffer_names())
    {window, buried} = split_buried(rows())
    live = for {b, _} <- Enum.take(window, @window), is_binary(b), MapSet.member?(known, b), do: b
    buried = for {b, _} <- buried, is_binary(b), MapSet.member?(known, b), do: b
    rest = MapSet.to_list(known) -- (live ++ buried)

    Enum.reject(live ++ Enum.sort(rest) ++ buried, &String.starts_with?(&1, " "))
  end

  @doc """
  The switcher history: `[\"buffer\", name]` and `[\"group\", name]` rows,
  the most recent first. A name no buffer has any more is left out.
  """
  def all do
    ready()
    # one read of the names: each read walks the registry and the store
    known = MapSet.new(Compos.Core.buffer_names())
    {window, buried} = split_buried(rows())

    Enum.flat_map(Enum.take(window, @window) ++ buried, fn
      {{:group, g}, _} -> [["group", g]]
      {b, _} when is_binary(b) -> if MapSet.member?(known, b), do: [["buffer", b]], else: []
      # anything else is not a place the user went: drop it, never raise
      _ -> []
    end)
  end

  @doc "The group names, the most recent first."
  def groups do
    ready()
    for {{:group, g}, seq} <- rows(), seq > 0, do: g
  end

  @doc "Replace the order with ENTRIES, the most recent first. Tests use it."
  def reset(entries) do
    ready()
    :ets.delete_all_objects(@table)
    seed(entries)
  end

  defp seed(entries) do
    n = length(entries)
    :ets.insert(@table, [{:"$seq", n}, {:"$low", 0}])
    entries |> Enum.with_index() |> Enum.each(fn {e, i} -> :ets.insert(@table, {e, n - i}) end)
    :ok
  end

  defp rows do
    @table
    |> :ets.tab2list()
    |> Enum.reject(&is_atom(elem(&1, 0)))
    |> Enum.sort_by(&elem(&1, 1), :desc)
  rescue
    ArgumentError -> []
  end

  defp split_buried(rows), do: Enum.split_with(rows, fn {_, seq} -> seq > 0 end)

  # A bump only inserts, so the table grows. Past the slack, drop what no
  # read shows: buffers out of the window, group marks past the tail, the
  # oldest buried. delete_object removes a row only while it still holds
  # the number read here, so a bump that raced the prune keeps its row.
  defp prune do
    if :ets.info(@table, :size) > @window + @group_tail + @slack do
      {window, buried} = split_buried(rows())
      {_kept, out} = Enum.split(window, @window)
      {marks, others} = Enum.split_with(out, &match?({{:group, _}, _}, &1))
      gone = others ++ Enum.drop(marks, @group_tail) ++ Enum.drop(buried, @buried_max)
      Enum.each(gone, &:ets.delete_object(@table, &1))
    end

    :ok
  end
end
