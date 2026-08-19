defmodule Aimax.Scheme.GC do
  @moduledoc """
  Mark-and-sweep over the environment store. `Env.new_frame` allocates
  and nothing else ever frees — without a sweep, every closure call,
  `let`, and `let*` leaks its frame for the life of the session.

  The store is two-tier (a local map over a shared ETS table), so the
  sweep marks across both tiers, prunes the local map in the returned
  interpreter, and deletes dead shared rows. Many processes evaluate
  against the shared tier, so the sweep first claims the store
  (`Env.begin_gc/1`) and runs only when no eval is in flight: a running
  eval's frames are reachable only from its Elixir stack, which the
  marker cannot see. `sweep/2` returns the interpreter unchanged when
  the store is busy — the caller just sweeps later.

  Roots are the global frame plus every closure found in the caller's
  root terms (recent results, command tables, escaped-handler
  registries, buffer locals). Closure *bodies* are never scanned: they
  are reader output and cannot contain closure terms, and scanning them
  would make each sweep proportional to the loaded source.
  """

  require Logger

  alias Aimax.Scheme
  alias Aimax.Scheme.Env

  @doc "Drop every frame not reachable from the global frame or `roots`."
  def sweep(%Scheme{store: store, global: global} = interp, roots) do
    case Env.begin_gc(store) do
      :busy ->
        interp

      :ok ->
        # the sweep pauses every eval (they spin on the claim), so its
        # duration is an editor freeze: report it, always
        t0 = System.monotonic_time(:millisecond)

        try do
          frames = Env.snapshot(store)
          work = Enum.reduce(roots, [global], &closure_refs/2)
          live = mark(frames, work, MapSet.new())

          for {ref, {vars, _parent, :ets}} <- frames, not MapSet.member?(live, ref) do
            Env.delete_frame(store, ref, vars)
          end

          ms = System.monotonic_time(:millisecond) - t0

          # the interpreter has no deps: telemetry fires only when the
          # host application brings it
          if Code.ensure_loaded?(:telemetry) do
            :telemetry.execute(
              [:aimax, :scheme, :gc],
              %{duration: ms, frames: map_size(frames), live: MapSet.size(live)},
              %{}
            )
          end

          Logger.info("scheme gc: #{map_size(frames)} frames, #{MapSet.size(live)} live, #{ms}ms")

          local = store.local |> Map.filter(fn {ref, _} -> MapSet.member?(live, ref) end)
          %{interp | store: %{store | local: local}}
        after
          Env.end_gc(store)
        end
    end
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

        {:ok, {vars, parent, _tier}} ->
          work = if parent in [nil, :unknown], do: rest, else: [parent | rest]
          work = Enum.reduce(vars, work, fn {_name, val}, acc -> closure_refs(val, acc) end)
          mark(frames, work, MapSet.put(seen, ref))
      end
    end
  end

  defp closure_refs(val, acc), do: Env.closure_refs(val, acc)
end
