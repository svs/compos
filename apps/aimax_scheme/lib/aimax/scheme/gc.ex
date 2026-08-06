defmodule Aimax.Scheme.GC do
  @moduledoc """
  Mark-and-sweep over the environment store. `Env.new_frame` allocates
  monotonically and nothing else ever frees — without a sweep, every
  closure call, `let`, and `let*` leaks its frame into the store for the
  life of the session.

  Roots are the global frame plus every closure found in the caller's root
  terms (last result, command tables, escaped-handler registries, buffer
  locals). Closure *bodies* are never scanned: they are reader output and
  cannot contain closure terms, and scanning them would make each sweep
  proportional to the loaded source.
  """

  alias Aimax.Scheme

  @doc "Drop every frame not reachable from the global frame or `roots`."
  def sweep(%Scheme{store: store, global: global} = interp, roots) do
    work = Enum.reduce(roots, [global], &closure_refs/2)
    live = mark(store.frames, work, MapSet.new())
    %{interp | store: %{store | frames: Map.take(store.frames, MapSet.to_list(live))}}
  end

  defp mark(_frames, [], seen), do: seen

  defp mark(frames, [ref | rest], seen) do
    if MapSet.member?(seen, ref) do
      mark(frames, rest, seen)
    else
      case Map.fetch(frames, ref) do
        # stale ref: possible only if a root outlived a frame a prior sweep
        # dropped — don't crash the editor over it
        :error ->
          mark(frames, rest, MapSet.put(seen, ref))

        {:ok, {vars, parent}} ->
          work = if parent == nil, do: rest, else: [parent | rest]
          work = Enum.reduce(vars, work, fn {_name, val}, acc -> closure_refs(val, acc) end)
          mark(frames, work, MapSet.put(seen, ref))
      end
    end
  end

  # deep-scan a term for closures, accumulating their captured frame refs
  defp closure_refs({:closure, _params, _body, ref}, acc), do: [ref | acc]

  defp closure_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &closure_refs/2)

  defp closure_refs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.reduce(acc, &closure_refs/2)

  # structs first: most aren't Enumerable, so go through a plain map
  defp closure_refs(%_{} = struct, acc),
    do: struct |> Map.from_struct() |> closure_refs(acc)

  defp closure_refs(map, acc) when is_map(map),
    do: Enum.reduce(map, acc, fn {k, v}, a -> closure_refs(v, closure_refs(k, a)) end)

  defp closure_refs(_other, acc), do: acc
end
