defmodule Compos.Scheme.Profile do
  @moduledoc """
  Time per Scheme call stack, for a flamegraph.

  While armed, every call the evaluator makes by name, `(name args ...)`,
  is timed. Each process keeps its own stack of open calls; when a call
  returns, its self time (its time minus its callees') is added to its
  folded path, `"outer;inner;name"`, in the table the profiler handed
  over. Those folded stacks are what a flamegraph draws.

  A call to the name already on top of the stack joins that frame, so a
  loop written as recursion reads as one bar, not a tower of them.

  Disarmed, a call costs one `:persistent_term` read. Armed, the evaluator
  gives up the tail call at each call it times: a profile of a deep loop
  uses more stack than the loop itself.
  """

  @key {__MODULE__, :table}
  @stack {__MODULE__, :stack}

  @doc "Arm: record into TABLE, a public ETS table."
  def start(table), do: :persistent_term.put(@key, table)

  @doc "Disarm. The calls still open record nothing more."
  def stop, do: :persistent_term.erase(@key)

  @doc "The table while armed, else nil."
  def table, do: :persistent_term.get(@key, nil)

  @doc """
  Every folded stack TABLE holds: `[{path, self_us, calls}]`.
  """
  def stacks(table) do
    table
    |> :ets.match_object({{:stack, :_}, :_, :_})
    |> Enum.map(fn {{:stack, path}, native, calls} ->
      {path, System.convert_time_unit(native, :native, :microsecond), calls}
    end)
  end

  @doc "Run FUN as a call to NAME, timed into TABLE."
  def call(table, name, fun) do
    case Process.get(@stack, []) do
      # recursion: the frame on top is this name already
      [{^name, _, _, _} | _] ->
        fun.()

      stack ->
        path =
          case stack do
            [{_, _, _, parent} | _] -> parent <> ";" <> name
            [] -> name
          end

        t0 = :erlang.monotonic_time()
        Process.put(@stack, [{name, t0, 0, path} | stack])

        try do
          fun.()
        after
          record(table, t0)
        end
    end
  end

  defp record(table, t0) do
    case Process.get(@stack) do
      [{_, ^t0, child, path} | rest] ->
        dt = :erlang.monotonic_time() - t0

        rest =
          case rest do
            [{n, t, c, p} | more] -> [{n, t, c + dt, p} | more]
            [] -> []
          end

        Process.put(@stack, rest)

        try do
          :ets.update_counter(
            table,
            {:stack, path},
            [{2, dt - child}, {3, 1}],
            {{:stack, path}, 0, 0}
          )
        rescue
          # the profile was read and its table cleared while this call ran
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
