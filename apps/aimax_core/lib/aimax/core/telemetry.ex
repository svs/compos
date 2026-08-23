defmodule Aimax.Core.Telemetry do
  @moduledoc """
  A bounded collector for Scheme scheduler telemetry.

  The telemetry handler only sends a message. It never calls Scheme or blocks
  the process that emitted the event. Scheme owns presentation and policy in
  `priv/packages/telemetry.scm`.
  """

  use GenServer

  @events [[:aimax, :lane, :job], [:aimax, :scheme, :task]]
  @handler {__MODULE__, :collector}
  @max_events 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return at most LIMIT events, newest first."
  def events(limit \\ 200) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:events, min(limit, @max_events)})
  end

  @doc "Discard all retained events."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc false
  def handle_event(event, measurements, metadata, collector) do
    send(
      collector,
      {:telemetry_event, event, measurements, metadata, System.system_time(:millisecond)}
    )
  end

  @impl true
  def init(_opts) do
    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, self())
    {:ok, %{events: :queue.new(), size: 0}}
  end

  @impl true
  def handle_call({:events, limit}, _from, state) do
    events = state.events |> :queue.to_list() |> Enum.reverse() |> Enum.take(limit)
    {:reply, events, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{events: :queue.new(), size: 0}}
  end

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata, time}, state) do
    row = normalize(event, measurements, metadata, time)
    events = :queue.in(row, state.events)
    size = state.size + 1

    {events, size} =
      if size > @max_events do
        {{:value, _oldest}, events} = :queue.out(events)
        {events, @max_events}
      else
        {events, size}
      end

    {:noreply, %{state | events: events, size: size}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler)
    :ok
  end

  defp normalize([:aimax, :lane, :job], measurements, metadata, time) do
    %{
      kind: "lane",
      time_ms: time,
      duration_ms: measurements.duration,
      queue_ms: measurements.queue_time,
      backlog: measurements.backlog,
      owner: inspect(Map.get(metadata, :owner, metadata.lane)),
      label: metadata.label,
      status: "ok"
    }
  end

  defp normalize([:aimax, :scheme, :task], measurements, metadata, time) do
    %{
      kind: "task",
      time_ms: time,
      duration_ms: measurements.duration,
      queue_ms: 0,
      backlog: 0,
      owner: Integer.to_string(metadata.task),
      label: Map.get(metadata, :label, "Scheme task"),
      status: Atom.to_string(metadata.status)
    }
  end
end
