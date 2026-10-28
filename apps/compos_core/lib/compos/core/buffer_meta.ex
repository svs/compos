defmodule Compos.Core.BufferMeta do
  @moduledoc """
  The one Scheme seam for buffer metadata.

  Every buffer sends `{:buffer_meta, name, diff}` from the one place it
  publishes its row, when a fact a listing reads changes
  (`Events.broadcast_meta/2`). This process takes them all, folds what
  has queued into one diff per buffer, and hands the batch to the Scheme
  closure `buffer-meta-handler!` set: one call per batch, on the ui
  lane. A burst of changes is one Scheme call, and nothing waits on a
  timer. With no handler set, the events are dropped.

  The handler gets `((NAME DIFF) ...)`, oldest first. DIFF is a plist of
  the new values: `name`, `was` (the old name, on a rename), `path`,
  `read-only`, `modified`, `locals` (a plist of the small locals that
  changed; #f for one that went).
  """

  use GenServer

  require Logger

  alias Compos.Core.{Events, Session}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Set the Scheme closure that gets each batch; #f clears it."
  def set_handler(closure) do
    # Scheme calls this from the lane, and this process calls the lane:
    # a cast, so neither ever waits on the other.
    unless Process.whereis(__MODULE__), do: GenServer.start(__MODULE__, nil, name: __MODULE__)
    GenServer.cast(__MODULE__, {:handler, closure})
  end

  @impl true
  def init(_) do
    Events.subscribe_meta()
    {:ok, %{handler: nil}}
  end

  @impl true
  def handle_cast({:handler, h}, state),
    do: {:noreply, %{state | handler: if(h in [nil, false], do: nil, else: h)}}

  @impl true
  def handle_info({:buffer_meta, _name, _diff}, %{handler: nil} = state), do: {:noreply, state}

  def handle_info({:buffer_meta, name, diff}, state) do
    {order, diffs} = drain([name], %{name => diff})
    rows = Enum.map(order, fn n -> [n, Events.scheme(diffs[n])] end)

    try do
      Session.call_fn(state.handler, [rows], nil, nil, "buffer-meta")
    catch
      kind, reason ->
        Logger.warning("buffer-meta handler: #{inspect(kind)} #{inspect(reason, limit: 5)}")
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Everything already queued joins the batch: one diff per buffer, the
  # newer value winning, the locals merged key by key.
  defp drain(order, diffs) do
    receive do
      {:buffer_meta, name, diff} ->
        order = if Map.has_key?(diffs, name), do: order, else: [name | order]
        drain(order, Map.update(diffs, name, diff, &merge(&1, diff)))
    after
      0 -> {Enum.reverse(order), diffs}
    end
  end

  defp merge(old, new) do
    Map.merge(old, new, fn
      :locals, a, b -> Map.merge(a, b)
      _k, _a, b -> b
    end)
  end
end
