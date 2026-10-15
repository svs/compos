defmodule Compos.Scheme.Env do
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
    * Before a host primitive or shared write exposes a closure, its reachable
      frames move to ETS. The exit flush keeps returned closures and drops
      unreferenced local frames.
    * `define`/`set!` on a frame that is already shared (not in `local`)
      writes through to ETS at once — a global define is visible to
      every lane mid-eval.

  ETS rows: `{{:frame, ref}, parent}` and `{{:var, ref, name}, val}` —
  one binding per row, so two lanes writing different names in one frame
  never clobber each other. Closures capture a frame ref, not a
  snapshot; `set!` semantics hold, now across processes too.

  A stale reference can still be detected after invalid external input or a
  faulty root set, but ordinary closure publication is complete before the
  closure becomes visible to another process.
  """

  defstruct [:tid, local: %{}]

  defmodule UnboundError do
    defexception [:message]
  end

  def new(access \\ :public) when access in [:public, :protected, :private] do
    tid =
      :ets.new(:compos_scheme_env, [
        :ordered_set,
        access,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(tid, {:write_gen, :atomics.new(1, signed: false)})
    %__MODULE__{tid: tid}
  end

  @doc "Copyable shared rows without GC lock metadata."
  def export_shared(%__MODULE__{tid: tid}) do
    tid
    |> :ets.tab2list()
    |> Enum.filter(fn
      {{:frame, _ref}, _parent} -> true
      {{:var, _ref, _name}, _value} -> true
      _ -> false
    end)
  end

  @doc "Build an environment from rows exported by export_shared/1."
  def import_shared(rows, access \\ :private) do
    store = new(access)
    if rows != [], do: :ets.insert(store.tid, rows)
    store
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
        # writes at once (write-through updates the cache). A write from
        # another lane drops the cache (current_cache), so a
        # read-modify-write of a global never starts from a stale copy.
        cache = current_cache(store)

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

  @doc """
  Drop this process's cached shared reads.

  The cache exists because an ETS read copies the term, and it is cleared
  at each exec boundary — so within one eval, another lane's writes are
  invisible. A primitive that POLLS inside a single eval (wait-until) must
  clear it between polls, or it watches a snapshot and always times out.
  Frames in `local` are this eval's own and are untouched.
  """
  def forget_cached_reads, do: Process.put(:scheme_cache, %{})

  # The write generation counts shared writes from every lane. A cache
  # remembers the generation it saw. When another lane writes, the counts
  # differ and the cache starts empty again. Before this, one lane cached
  # a global for its whole exec: two chats that ran their mode setups in
  # parallel each wrote *keymaps* from their own old copy, and one chat
  # lost its keys.
  defp current_cache(%__MODULE__{tid: tid}) do
    cache = Process.get(:scheme_cache) || %{}

    case cache do
      %{:write_gen => {gen, seen}} ->
        if :atomics.get(gen, 1) == seen do
          cache
        else
          fresh = %{:write_gen => {gen, :atomics.get(gen, 1)}}
          Process.put(:scheme_cache, fresh)
          fresh
        end

      _ ->
        case write_gen(tid) do
          nil ->
            cache

          gen ->
            cache = Map.put(cache, :write_gen, {gen, :atomics.get(gen, 1)})
            Process.put(:scheme_cache, cache)
            cache
        end
    end
  end

  defp write_gen(tid) do
    :ets.lookup_element(tid, :write_gen, 2, nil)
  end

  # Count one shared write. The cache stays valid when this write is the
  # only one since the cache last looked; else another lane wrote too.
  defp note_write(tid) do
    case write_gen(tid) do
      nil ->
        :ok

      gen ->
        now = :atomics.add_get(gen, 1, 1)

        case Process.get(:scheme_cache) do
          %{:write_gen => {^gen, seen}} = cache when seen == now - 1 ->
            Process.put(:scheme_cache, Map.put(cache, :write_gen, {gen, now}))

          %{} ->
            Process.put(:scheme_cache, %{:write_gen => {gen, now}})

          nil ->
            :ok
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
  def define(store, ref, name, val) do
    old = own_value(store, ref, name)
    put_binding(store, ref, name, preserve_interposer(old, val))
  end

  # Read only this frame: a lexical shadow must not inherit a global wrapper.
  defp own_value(%__MODULE__{local: local, tid: tid}, ref, name) do
    case local do
      %{^ref => {vars, _}} ->
        Map.get(vars, name)

      _ ->
        # Copy the old value out of ETS only when it is interposed: that is
        # all define needs to know. A full lookup copied every global into
        # the heap on each define or set!, so a load that grew *tests* one
        # deftest at a time copied the whole list each time and passed the
        # 1024 MB heap limit (2026-10-15).
        case :ets.select_count(tid, [{{{:var, ref, name}, {:interposed, :_, :_}}, [], [true]}]) do
          0 ->
            nil

          _ ->
            case :ets.lookup(tid, {:var, ref, name}) do
              [{_, value}] -> value
              [] -> nil
            end
        end
    end
  end

  defp preserve_interposer(value, value), do: value

  defp preserve_interposer({:interposed, _, wrapper}, value),
    do: {:interposed, value, wrapper}

  defp preserve_interposer(_, value), do: value

  @doc "Install or remove one binding wrapper. Scheme owns composition and policy."
  def interpose(store, ref, name, wrapper) do
    current = lookup(store, ref, name)

    original =
      case current do
        {:interposed, original, _} -> original
        value -> value
      end

    unless callable?(original) and (wrapper == false or callable?(wrapper)) do
      raise ArgumentError, "function-interpose! expects callable target and wrapper"
    end

    value = if wrapper == false, do: original, else: {:interposed, original, wrapper}
    put_binding(store, ref, name, value)
  end

  defp callable?({:closure, _, _, _}), do: true
  defp callable?({:builtin, _, _}), do: true
  defp callable?({:interposed, _, _}), do: true
  defp callable?(_), do: false

  defp put_binding(%__MODULE__{tid: tid, local: local} = store, ref, name, val) do
    case local do
      %{^ref => {vars, parent}} ->
        %{store | local: Map.put(local, ref, {Map.put(vars, name, val), parent})}

      _ ->
        # shared frame: write through, visible to every lane at once.
        # Publish captured frames before the value becomes visible.
        store = promote(store, [val])
        shared_parent(tid, ref)
        :ets.insert(tid, {{:var, ref, name}, val})
        note_write(tid)
        cache_put(ref, name, val)
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
            define(store, ref, name, val)

          parent != nil ->
            set!(store, parent, name, val)

          true ->
            raise UnboundError, message: "set! of unbound variable: #{name}"
        end

      _ ->
        cond do
          :ets.member(tid, {:var, ref, name}) ->
            define(store, ref, name, val)

          (p = shared_parent(tid, ref)) != nil ->
            set!(store, p, name, val)

          true ->
            raise UnboundError, message: "set! of unbound variable: #{name}"
        end
    end
  end

  @doc "Remove one binding from a frame (the inverse of define)."
  def unbind(%__MODULE__{tid: tid, local: local} = store, ref, name) do
    case local do
      %{^ref => {vars, parent}} ->
        %{store | local: Map.put(local, ref, {Map.delete(vars, name), parent})}

      _ ->
        :ets.delete(tid, {:var, ref, name})
        note_write(tid)
        cache_delete(ref, name)
        store
    end
  end

  defp cache_delete(ref, name) do
    case Process.get(:scheme_cache) do
      nil -> :ok
      cache -> Process.put(:scheme_cache, Map.delete(cache, {ref, name}))
    end

    :ok
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
  the runner supplies the result as ROOTS. Primitive arguments and shared
  writes promote captured frames before they become visible. Everything
  else is a dead `let` or call frame: publishing it was the store leak
  (millions of dead frames), and the bulk ETS copy froze the lane for seconds.

  The runner calls this at eval exit, inside the in-flight section —
  never after it, or a sweep could run between the eval and its escape
  becoming visible.
  """
  def flush(%__MODULE__{tid: tid, local: local} = store, roots, seeds \\ []) do
    if map_size(local) == 0 do
      store
    else
      work = Enum.reduce(roots, seeds, &closure_refs/2)
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

  @doc """
  Publish the local frames reachable from ROOTS now.

  The promoted frames leave the local tier. Later reads and writes use ETS,
  so another process can invoke an escaped closure before this eval exits.
  Other local frames stay private and keep the hot path unchanged.
  """
  def promote(%__MODULE__{local: local} = store, roots) when is_list(roots) do
    if map_size(local) == 0 or Process.get(:scheme_unpublished) do
      store
    else
      work = Enum.reduce(roots, [], &closure_refs/2)
      seen = flush_mark(local, work, MapSet.new())
      publish_marked(store, seen)
    end
  end

  defp publish_marked(%__MODULE__{tid: tid, local: local} = store, seen) do
    rows =
      Enum.flat_map(seen, fn ref ->
        case local do
          %{^ref => {vars, parent}} ->
            [{{:frame, ref}, parent} | Enum.map(vars, fn {n, v} -> {{:var, ref, n}, v} end)]

          _ ->
            []
        end
      end)

    if rows != [], do: :ets.insert(tid, rows)

    %{store | local: Map.drop(local, MapSet.to_list(seen))}
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
  Run FUN with promotion off. One process owns the store while FUN runs,
  and no other process can evaluate against it, so nothing needs
  publishing before the flush that ends the load. Boot uses this: with
  the global frame still in the local tier, every promotion re-walked
  every global binding, and the corpus load spent most of its time there.
  """
  def unpublished(fun) do
    Process.put(:scheme_unpublished, true)

    try do
      fun.()
    after
      Process.delete(:scheme_unpublished)
    end
  end

  @doc "Deep-scan a term for closures, accumulating their captured frame refs."
  def closure_refs({:closure, _params, _body, ref}, acc), do: [ref | acc]

  # Walk a list cell by cell, not with Enum.reduce: a term the host keeps
  # can be an improper list ([a | b] with a non-list tail, iodata among
  # them), and Enum.reduce raises on one. A GC sweep that raised took the
  # Session down (2026-09-19). The tail is itself a term and walks the same.
  def closure_refs([head | tail], acc), do: closure_refs(tail, closure_refs(head, acc))
  def closure_refs([], acc), do: acc

  def closure_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &closure_refs/2)

  # structs first: most aren't Enumerable, so go through a plain map
  def closure_refs(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> closure_refs(acc)

  def closure_refs(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {k, v}, a -> closure_refs(v, closure_refs(k, a)) end)

  def closure_refs(_other, acc), do: acc

  @doc "Every name bound directly in one frame, both tiers, deduplicated."
  def frame_names(%__MODULE__{tid: tid, local: local}, ref) do
    shared = :ets.select(tid, [{{{:var, ref, :"$1"}, :_}, [], [:"$1"]}])

    case local do
      %{^ref => {vars, _parent}} -> Enum.uniq(Map.keys(vars) ++ shared)
      _ -> shared
    end
  end

  @doc "The number of live frames, both tiers."
  def frame_count(%__MODULE__{tid: tid, local: local}) do
    :ets.select_count(tid, [{{{:frame, :_}, :_}, [], [true]}]) + map_size(local)
  end

  @doc """
  The frame graph for the GC: `%{ref => [ref]}`, both tiers, each frame
  with its parent and the frames its values capture. The shared tier is
  read by match specs, so a closure's body never leaves ETS: a closure
  value yields only its captured frame ref. Only compound values that are
  not closures (lists, maps, other tuples) are copied out and scanned;
  scalars are skipped. Also answers the set of shared frame refs.
  """
  def edges(%__MODULE__{tid: tid, local: local}) do
    v = :"$2"

    parents = :ets.select(tid, [{{{:frame, :"$1"}, v}, [], [{{:"$1", v}}]}])
    var_refs = :ets.select(tid, [{{{:var, :"$1", :_}, :_}, [], [:"$1"]}])
    closures = :ets.select(tid, [{{{:var, :"$1", :_}, {:closure, :_, :_, v}}, [], [{{:"$1", v}}]}])

    not_closure_tuple =
      {:andalso, {:is_tuple, v},
       {:andalso, {:>, {:tuple_size, v}, 0}, {:"=/=", {:element, 1, v}, :closure}}}

    compound_guard = {:orelse, {:is_list, v}, {:orelse, {:is_map, v}, not_closure_tuple}}
    compound = :ets.select(tid, [{{{:var, :"$1", :_}, v}, [compound_guard], [{{:"$1", v}}]}])

    add = fn acc, ref, out -> Map.update(acc, ref, out, &(out ++ &1)) end

    graph =
      Enum.reduce(parents, %{}, fn {ref, parent}, acc ->
        add.(acc, ref, if(parent, do: [parent], else: []))
      end)

    graph = Enum.reduce(var_refs, graph, fn ref, acc -> Map.put_new(acc, ref, []) end)
    shared = graph |> Map.keys() |> MapSet.new()
    graph = Enum.reduce(closures, graph, fn {ref, c}, acc -> add.(acc, ref, [c]) end)
    graph = Enum.reduce(compound, graph, fn {ref, val}, acc -> add.(acc, ref, closure_refs(val, [])) end)

    # the local tier shadows the shared one
    graph =
      Enum.reduce(local, graph, fn {ref, {vars, parent}}, acc ->
        out = Enum.reduce(vars, if(parent, do: [parent], else: []), fn {_n, val}, a -> closure_refs(val, a) end)
        Map.put(acc, ref, out)
      end)

    {graph, shared}
  end

  @doc "Delete a shared frame and all its bindings (one key range)."
  def drop_frame(%__MODULE__{tid: tid}, ref) do
    :ets.delete(tid, {:frame, ref})
    :ets.match_delete(tid, {{:var, ref, :_}, :_})
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

    try do
      fun.()
    after
      if outer, do: Process.put(:scheme_cache, outer), else: Process.delete(:scheme_cache)

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

        # Poll at 1 ms: a sweep takes tens of ms, so a waiter starts at
        # most 1 ms after it ends. A message wake would leave a stray
        # message in a GenServer's mailbox when a waiter gives up.
        if is_pid(pid) and not Process.alive?(pid) do
          :ets.delete_object(tid, claim)
        else
          Process.sleep(1)
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
