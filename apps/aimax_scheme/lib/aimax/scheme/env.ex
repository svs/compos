defmodule Aimax.Scheme.Env do
  @moduledoc """
  Two-tier environment store: a process-local frame map over a shared,
  public ETS overlay.

  Environments must be mutable (for `define`/`set!` and shared closure
  state), and many processes must evaluate against the same world — a
  long eval in one lane must not block another. But frame churn is the
  interpreter's hottest path, and an ETS write copies its term: putting
  every `let` and closure call in ETS made boot two orders slower. So:

    * During an eval, new frames live in `local` — a plain map threaded
      through evaluation, exactly the old single-process store.
    * At eval exit the runner flushes `local` to the ETS table in one
      bulk insert (`flush/1`): closures that escaped into command tables,
      handlers, and buffer locals now resolve from any process.
    * `define`/`set!` on a frame that is already shared (not in `local`)
      writes through to ETS at once — a global define is visible to
      every lane mid-eval.

  ETS rows: `{{:frame, ref}, parent}` and `{{:var, ref, name}, val}` —
  one binding per row, so two lanes writing different names in one frame
  never clobber each other. Closures capture a frame ref, not a
  snapshot; `set!` semantics hold, now across processes too.

  A closure can escape mid-eval (define-command, then a long tail) — a
  cross-lane call in that window sees a frame not yet flushed and gets a
  "stale environment frame" Scheme error, not a crash; the ref heals at
  flush. Serial use per lane never observes this.
  """

  defstruct [:tid, local: %{}]

  defmodule UnboundError do
    defexception [:message]
  end

  def new do
    %__MODULE__{
      tid:
        :ets.new(:aimax_scheme_env, [
          :ordered_set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])
    }
  end

  @doc "Create a frame; returns {ref, store}."
  def new_frame(%__MODULE__{} = store, parent, vars \\ %{}) do
    ref = :erlang.unique_integer([:positive])
    {ref, %{store | local: Map.put(store.local, ref, {vars, parent})}}
  end

  def lookup(store, ref, name) do
    case fetch(store, ref, name) do
      {:ok, val} -> val
      :error -> raise UnboundError, message: "unbound variable: #{name}"
    end
  end

  @doc "Like lookup but returns {:ok, val} | :error instead of raising."
  def fetch(%__MODULE__{tid: tid, local: local} = store, ref, name) do
    case local do
      %{^ref => {vars, parent}} ->
        case vars do
          %{^name => val} -> {:ok, val}
          _ when parent != nil -> fetch(store, parent, name)
          _ -> :error
        end

      _ ->
        # an ETS read copies the term, and hot values are closures whose
        # bodies are whole source trees — cache shared reads per process,
        # cleared at each exec boundary (with_eval). One lane sees its own
        # writes at once (write-through updates the cache); another lane's
        # mid-eval writes land at the next exec.
        cache = Process.get(:scheme_cache) || %{}

        case cache do
          %{{^ref, ^name} => val} ->
            {:ok, val}

          _ ->
            case :ets.lookup(tid, {:var, ref, name}) do
              [{_, val}] ->
                Process.put(:scheme_cache, Map.put(cache, {ref, name}, val))
                {:ok, val}

              [] ->
                case cached_parent(tid, cache, ref) do
                  nil -> :error
                  parent -> fetch(store, parent, name)
                end
            end
        end
    end
  end

  defp cached_parent(tid, cache, ref) do
    case cache do
      %{{:parent, ^ref} => parent} ->
        parent

      _ ->
        parent = shared_parent(tid, ref)
        Process.put(:scheme_cache, Map.put(cache, {:parent, ref}, parent))
        parent
    end
  end

  @doc "Bind name in the given frame (define)."
  def define(%__MODULE__{tid: tid, local: local} = store, ref, name, val) do
    case local do
      %{^ref => {vars, parent}} ->
        %{store | local: Map.put(local, ref, {Map.put(vars, name, val), parent})}

      _ ->
        # shared frame: write through, visible to every lane at once.
        # The value escapes this exec's local tier by definition.
        shared_parent(tid, ref)
        :ets.insert(tid, {{:var, ref, name}, val})
        cache_put(ref, name, val)
        note_escape(val)
        store
    end
  end

  defp cache_put(ref, name, val) do
    case Process.get(:scheme_cache) do
      nil -> :ok
      cache -> Process.put(:scheme_cache, Map.put(cache, {ref, name}, val))
    end

    :ok
  end

  @doc "Assign to nearest frame where name is bound (set!)."
  def set!(%__MODULE__{tid: tid, local: local} = store, ref, name, val) do
    case local do
      %{^ref => {vars, parent}} ->
        cond do
          Map.has_key?(vars, name) ->
            %{store | local: Map.put(local, ref, {Map.put(vars, name, val), parent})}

          parent != nil ->
            set!(store, parent, name, val)

          true ->
            raise UnboundError, message: "set! of unbound variable: #{name}"
        end

      _ ->
        cond do
          :ets.member(tid, {:var, ref, name}) ->
            :ets.insert(tid, {{:var, ref, name}, val})
            cache_put(ref, name, val)
            note_escape(val)
            store

          (p = shared_parent(tid, ref)) != nil ->
            set!(store, p, name, val)

          true ->
            raise UnboundError, message: "set! of unbound variable: #{name}"
        end
    end
  end

  @doc """
  Publish every local frame to the shared table in one bulk insert and
  return the store with an empty local tier. Boot uses this: the stdlib
  loads at single-process speed and publishes once.
  """
  def flush(%__MODULE__{tid: tid, local: local} = store) do
    rows =
      Enum.flat_map(local, fn {ref, {vars, parent}} ->
        [{{:frame, ref}, parent} | Enum.map(vars, fn {name, val} -> {{:var, ref, name}, val} end)]
      end)

    if rows != [], do: :ets.insert(tid, rows)
    %{store | local: %{}}
  end

  @doc """
  Publish only the local frames that escaped this exec, and drop the
  rest. A frame escapes when a closure that captures it leaves Scheme:
  in the result (ROOTS), as an argument to a primitive, or written
  through to a shared frame — the last two are noted per-process by
  `note_escape/1` while the exec runs. Everything else is a dead `let`
  or call frame: publishing it was the store leak (millions of dead
  frames), and the bulk ETS copy froze the lane for seconds.

  The runner calls this at eval exit, inside the in-flight section —
  never after it, or a sweep could run between the eval and its escape
  becoming visible.
  """
  def flush(%__MODULE__{tid: tid, local: local} = store, roots) do
    if map_size(local) == 0 do
      store
    else
      work = Enum.reduce(roots, Process.get(:scheme_escapes) || [], &closure_refs/2)
      seen = flush_mark(local, work, MapSet.new())

      rows =
        Enum.flat_map(local, fn {ref, {vars, parent}} ->
          if MapSet.member?(seen, ref) do
            [{{:frame, ref}, parent} | Enum.map(vars, fn {n, v} -> {{:var, ref, n}, v} end)]
          else
            []
          end
        end)

      if rows != [], do: :ets.insert(tid, rows)
      %{store | local: %{}}
    end
  end

  # mark restricted to the local tier: a ref not in `local` is shared
  # (already published) or stale, and needs no walk
  defp flush_mark(_local, [], seen), do: seen

  defp flush_mark(local, [ref | rest], seen) do
    cond do
      MapSet.member?(seen, ref) ->
        flush_mark(local, rest, seen)

      not is_map_key(local, ref) ->
        flush_mark(local, rest, MapSet.put(seen, ref))

      true ->
        {vars, parent} = Map.fetch!(local, ref)
        work = if parent == nil, do: rest, else: [parent | rest]
        work = Enum.reduce(vars, work, fn {_n, v}, a -> closure_refs(v, a) end)
        flush_mark(local, work, MapSet.put(seen, ref))
    end
  end

  @doc """
  Record a value's closure refs as escaped from the running exec, so the
  selective flush publishes their frames. A no-op outside an exec.
  """
  def note_escape(val) do
    case Process.get(:scheme_escapes) do
      nil -> :ok
      acc -> Process.put(:scheme_escapes, closure_refs(val, acc))
    end

    :ok
  end

  @doc "Deep-scan a term for closures, accumulating their captured frame refs."
  def closure_refs({:closure, _params, _body, ref}, acc), do: [ref | acc]

  def closure_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &closure_refs/2)

  def closure_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &closure_refs/2)

  # structs first: most aren't Enumerable, so go through a plain map
  def closure_refs(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> closure_refs(acc)

  def closure_refs(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {k, v}, a -> closure_refs(v, closure_refs(k, a)) end)

  def closure_refs(_other, acc), do: acc

  @doc "The number of live frames, both tiers."
  def frame_count(%__MODULE__{tid: tid, local: local}) do
    :ets.select_count(tid, [{{{:frame, :_}, :_}, [], [true]}]) + map_size(local)
  end

  @doc """
  Both tiers as `%{ref => {vars, parent, :ets | :local}}` — the GC's
  working copy. The local tier shadows the shared one.
  """
  def snapshot(%__MODULE__{tid: tid, local: local}) do
    shared =
      :ets.tab2list(tid)
      |> Enum.reduce(%{}, fn
        {{:frame, ref}, parent}, acc ->
          Map.update(acc, ref, {%{}, parent}, fn {vars, _} -> {vars, parent} end)

        {{:var, ref, name}, val}, acc ->
          Map.update(acc, ref, {%{name => val}, :unknown}, fn {vars, parent} ->
            {Map.put(vars, name, val), parent}
          end)

        _lock_row, acc ->
          acc
      end)
      |> Map.new(fn {ref, {vars, parent}} -> {ref, {vars, parent, :ets}} end)

    Enum.reduce(local, shared, fn {ref, {vars, parent}}, acc ->
      Map.put(acc, ref, {vars, parent, :local})
    end)
  end

  @doc "Delete a shared frame and all its bindings."
  def delete_frame(%__MODULE__{tid: tid}, ref, vars) do
    :ets.delete(tid, {:frame, ref})
    Enum.each(vars, fn {name, _} -> :ets.delete(tid, {:var, ref, name}) end)
    :ok
  end

  # --- the eval/GC lock -------------------------------------------------------
  #
  # A sweep must not run while any process evaluates: an eval's frames are
  # reachable only from its Elixir stack and local tier, which the marker
  # cannot see. In-flight evals register per pid, not in one shared
  # counter: a lane killed mid-eval (C-g) never runs its exit path, and a
  # dead pid's row is droppable where a leaked counter would wedge the GC
  # forever. Readers count in; the writer (GC) runs only when none are
  # live, and gives up instead of waiting — a busy editor sweeps later.

  @doc "Run FUN registered as an eval in flight; the GC will not sweep under it."
  def with_eval(%__MODULE__{tid: tid}, fun) do
    enter(tid)
    # a fresh read cache per exec: another lane's writes land here, and a
    # sweep between execs cannot leave a stale cached frame behind
    outer = Process.put(:scheme_cache, %{})
    # the escape log the selective flush reads; nested execs get their own
    outer_esc = Process.put(:scheme_escapes, [])

    try do
      fun.()
    after
      if outer, do: Process.put(:scheme_cache, outer), else: Process.delete(:scheme_cache)

      if outer_esc,
        do: Process.put(:scheme_escapes, outer_esc),
        else: Process.delete(:scheme_escapes)

      case :ets.update_counter(tid, {:eval, self()}, -1, {{:eval, self()}, 0}) do
        n when n <= 0 -> :ets.delete(tid, {:eval, self()})
        _ -> :ok
      end
    end
  end

  defp enter(tid) do
    :ets.update_counter(tid, {:eval, self()}, 1, {{:eval, self()}, 0})

    case :ets.lookup(tid, :gc) do
      [] ->
        :ok

      [{:gc, pid} = claim] ->
        # a sweep is running: back out, let it finish, come back. A claim
        # whose sweeper died (killed mid-sweep — its cleanup never ran)
        # would spin every eval forever: reap it instead of waiting.
        :ets.update_counter(tid, {:eval, self()}, -1, {{:eval, self()}, 0})

        if is_pid(pid) and not Process.alive?(pid) do
          :ets.delete_object(tid, claim)
        else
          Process.sleep(5)
        end

        enter(tid)
    end
  end

  @doc """
  Claim the store for a sweep. Returns `:ok` (caller must `end_gc/1`) or
  `:busy` when an eval is in flight. The claim row carries the sweeper's
  pid, so a claim orphaned by a killed sweeper is reapable.
  """
  def begin_gc(%__MODULE__{tid: tid}) do
    if :ets.insert_new(tid, {:gc, self()}) do
      live =
        :ets.select(tid, [{{{:eval, :"$1"}, :"$2"}, [{:>, :"$2", 0}], [:"$1"]}])
        |> Enum.filter(fn pid ->
          Process.alive?(pid) || (:ets.delete(tid, {:eval, pid}) && false)
        end)

      if live == [] do
        :ok
      else
        :ets.delete(tid, :gc)
        :busy
      end
    else
      case :ets.lookup(tid, :gc) do
        [{:gc, pid} = claim] when is_pid(pid) ->
          unless Process.alive?(pid), do: :ets.delete_object(tid, claim)

        _ ->
          :ok
      end

      :busy
    end
  end

  def end_gc(%__MODULE__{tid: tid}), do: :ets.delete(tid, :gc)

  defp shared_parent(tid, ref) do
    case :ets.lookup(tid, {:frame, ref}) do
      [{_, parent}] -> parent
      # the frame was swept while a closure still pointed at it, or has
      # not flushed yet: surface a Scheme error, never a raw crash
      [] -> raise UnboundError, message: "stale environment frame"
    end
  end
end
