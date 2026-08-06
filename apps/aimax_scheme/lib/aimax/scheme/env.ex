defmodule Aimax.Scheme.Env do
  @moduledoc """
  Environment store: a map of frame-refs -> {vars, parent_ref}.

  Environments must be mutable (for `define`/`set!` and shared closure state)
  while the interpreter itself stays a pure Elixir data structure, so frames
  live in a store that is threaded through evaluation. Closures capture a
  frame ref, not a snapshot — `set!` semantics are correct.
  """

  defstruct frames: %{}, next: 0

  defmodule UnboundError do
    defexception [:message]
  end

  def new, do: %__MODULE__{}

  @doc "Create a frame; returns {ref, store}."
  def new_frame(%__MODULE__{} = store, parent, vars \\ %{}) do
    ref = store.next
    {ref, %{store | next: ref + 1, frames: Map.put(store.frames, ref, {vars, parent})}}
  end

  def lookup(store, ref, name) do
    {vars, parent} = Map.fetch!(store.frames, ref)

    case vars do
      %{^name => val} -> val
      _ when parent != nil -> lookup(store, parent, name)
      _ -> raise UnboundError, message: "unbound variable: #{name}"
    end
  end

  @doc "Like lookup but returns {:ok, val} | :error instead of raising."
  def fetch(store, ref, name) do
    {vars, parent} = Map.fetch!(store.frames, ref)

    case vars do
      %{^name => val} -> {:ok, val}
      _ when parent != nil -> fetch(store, parent, name)
      _ -> :error
    end
  end

  @doc "Bind name in the given frame (define)."
  def define(store, ref, name, val) do
    {vars, parent} = Map.fetch!(store.frames, ref)
    %{store | frames: Map.put(store.frames, ref, {Map.put(vars, name, val), parent})}
  end

  @doc "Assign to nearest frame where name is bound (set!)."
  def set!(store, ref, name, val) do
    {vars, parent} = Map.fetch!(store.frames, ref)

    cond do
      Map.has_key?(vars, name) ->
        %{store | frames: Map.put(store.frames, ref, {Map.put(vars, name, val), parent})}

      parent != nil ->
        set!(store, parent, name, val)

      true ->
        raise UnboundError, message: "set! of unbound variable: #{name}"
    end
  end
end
