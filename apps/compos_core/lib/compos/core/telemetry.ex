defmodule Compos.Core.Telemetry do
  @moduledoc """
  A bounded collector for the editor's telemetry, every layer in one stream.

  Each row names its layer:

    * `scheme`  - a lane job or a shared task (the Scheme scheduler)
    * `live`    - a LiveView event, the EditorLive refresh, and the render
    * `browser` - what the client measured: the round trip of one push, the
                  DOM patch, the paint (Event Timing), and long tasks

  A push from the browser carries a trace id (`tid`). The browser row, the
  LiveView event row, the refresh row, and the render row of one keystroke
  share it, so one filter shows the keystroke end to end.

  The telemetry handler only sends a message. It never calls Scheme or blocks
  the process that emitted the event. Scheme owns presentation and policy in
  `priv/packages/telemetry.scm`.
  """

  use GenServer

  alias Compos.Core.Session

  @events [
    [:compos, :lane, :job],
    [:compos, :scheme, :task],
    [:compos, :ui, :refresh],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :render, :stop]
  ]
  @handler {__MODULE__, :collector}
  @max_events 2_000
  # rows arrive in bursts; Scheme hears about them at most this often
  @notify_ms 1_000
  @notify_fn "telemetry-arrived!"

  # the process-dictionary key that carries a trace id from the LiveView
  # event that set it to the refresh and the render that follow it, in the
  # same LiveView process
  @tid_key :compos_tid

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return at most LIMIT events, newest first."
  def events(limit \\ 200) when is_integer(limit) and limit >= 0 do
    GenServer.call(__MODULE__, {:events, min(limit, @max_events)})
  end

  @doc "Discard all retained events."
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc """
  Detach and attach the handler again.

  A hot reload that changes the event list must call this: the running
  collector attached the old list when it started.
  """
  def reattach, do: GenServer.call(__MODULE__, :reattach)

  @doc """
  Record rows the browser measured.

  Each row is a map with the keys the client sends: `k` (kind), `l` (label),
  `ms` (duration), `wait` (the server round trip, or the input delay),
  `t` (epoch milliseconds), `tid`, and `d` (detail).
  """
  def browser(rows, frame) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.each(fn row ->
      send(__MODULE__, {:row, browser_row(row, frame)})
    end)

    :ok
  end

  @doc "The trace id of the LiveView event this process is handling, or nil."
  def current_tid do
    case Process.get(@tid_key) do
      tid when is_binary(tid) -> tid
      _ -> nil
    end
  end

  @doc false
  def handle_event([:phoenix, :live_view, :handle_event, :start], _m, metadata, _collector) do
    # "telemetry" is the browser's own report: it is not a user event, and
    # the render after it must not be recorded as one
    tid =
      case metadata do
        %{event: "telemetry"} -> :skip
        %{params: %{"tid" => tid}} when is_binary(tid) -> tid
        _ -> nil
      end

    Process.put(@tid_key, tid)
  end

  def handle_event([:phoenix, :live_view, :handle_event, :stop], measurements, metadata, collector) do
    case metadata do
      %{event: "telemetry"} ->
        :ok

      _ ->
        emit(collector, [:phoenix, :live_view, :handle_event, :stop], measurements, metadata)
    end
  end

  def handle_event([:phoenix, :live_view, :render, :stop], measurements, metadata, collector) do
    # the render is the last step of the event that set the trace id, so
    # the id leaves with it: a render a change notification starts later
    # carries no id
    tid = Process.get(@tid_key)
    Process.delete(@tid_key)

    unless tid == :skip do
      metadata = Map.put(metadata, :tid, if(is_binary(tid), do: tid, else: nil))
      emit(collector, [:phoenix, :live_view, :render, :stop], measurements, metadata)
    end
  end

  def handle_event(event, measurements, metadata, collector) do
    emit(collector, event, measurements, metadata)
  end

  defp emit(collector, event, measurements, metadata) do
    send(
      collector,
      {:telemetry_event, event, measurements, Map.put_new(metadata, :tid, current_tid()),
       System.system_time(:millisecond)}
    )
  end

  @impl true
  def init(_opts) do
    :ok = attach()
    {:ok, %{events: :queue.new(), size: 0, notify: nil}}
  end

  defp attach do
    :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, self())
  end

  defp ensure_attached do
    attached =
      @events
      |> Enum.flat_map(&:telemetry.list_handlers/1)
      |> Enum.filter(&(&1.id == @handler))
      |> Enum.map(& &1.event_name)
      |> Enum.uniq()

    if Enum.sort(attached) != Enum.sort(@events) do
      :telemetry.detach(@handler)
      attach()
    end
  end

  @impl true
  def handle_call({:events, limit}, _from, state) do
    # a hot reload that grew the event list left the old attachment in
    # place: the first read after it attaches the new list
    ensure_attached()
    events = state.events |> :queue.to_list() |> Enum.reverse() |> Enum.take(limit)
    {:reply, events, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | events: :queue.new(), size: 0}}
  end

  def handle_call(:reattach, _from, state) do
    :telemetry.detach(@handler)
    {:reply, attach(), state}
  end

  @impl true
  def handle_info({:telemetry_event, event, measurements, metadata, time}, state) do
    {:noreply, put(state, normalize(event, measurements, metadata, time))}
  end

  def handle_info({:row, row}, state), do: {:noreply, put(state, row)}

  # One notice per burst. The Scheme side decides what to do with it
  # (packages/telemetry.scm telemetry-arrived!); this process only says
  # that rows arrived, and never waits for the answer.
  def handle_info(:notify, state) do
    if Session.ready?() do
      Task.start(fn ->
        try do
          Session.call_named(@notify_fn, [], nil, 5_000)
        catch
          _, _ -> :ok
        end
      end)
    end

    {:noreply, Map.put(state, :notify, nil)}
  end

  # Map.get and Map.put: a hot swap keeps the state of the running
  # process, and a state from before this key has none
  defp arm(state) do
    case Map.get(state, :notify) do
      nil -> Map.put(state, :notify, Process.send_after(self(), :notify, @notify_ms))
      _ -> state
    end
  end

  defp put(state, row) do
    state = arm(state)
    events = :queue.in(row, state.events)
    size = state.size + 1

    {events, size} =
      if size > @max_events do
        {{:value, _oldest}, events} = :queue.out(events)
        {events, @max_events}
      else
        {events, size}
      end

    %{state | events: events, size: size}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler)
    :ok
  end

  defp row(fields) do
    Map.merge(
      %{
        kind: "lane",
        layer: "scheme",
        time_ms: 0,
        duration_ms: 0,
        queue_ms: 0,
        backlog: 0,
        owner: "",
        label: "",
        status: "ok",
        tid: nil,
        detail: ""
      },
      fields
    )
  end

  defp normalize([:compos, :lane, :job], measurements, metadata, time) do
    row(%{
      kind: "lane",
      layer: "scheme",
      time_ms: time,
      duration_ms: measurements.duration,
      queue_ms: measurements.queue_time,
      backlog: measurements.backlog,
      owner: inspect(Map.get(metadata, :owner, metadata.lane)),
      label: metadata.label
    })
  end

  defp normalize([:compos, :scheme, :task], measurements, metadata, time) do
    row(%{
      kind: "task",
      layer: "scheme",
      time_ms: time,
      duration_ms: measurements.duration,
      owner: Integer.to_string(metadata.task),
      label: Map.get(metadata, :label, "Scheme task"),
      status: Atom.to_string(metadata.status)
    })
  end

  # EditorLive.refresh: the editor state read and the decoration of the
  # window tree, the two halves of one number
  defp normalize([:compos, :ui, :refresh], measurements, metadata, time) do
    row(%{
      kind: "refresh",
      layer: "live",
      time_ms: time,
      duration_ms: measurements.duration,
      owner: frame_owner(metadata[:frame]),
      label: "refresh",
      tid: metadata[:tid],
      detail: "state #{measurements[:state] || 0}ms decorate #{measurements[:decorate] || 0}ms"
    })
  end

  defp normalize([:phoenix, :live_view, :handle_event, :stop], measurements, metadata, time) do
    row(%{
      kind: "event",
      layer: "live",
      time_ms: time,
      duration_ms: native_ms(measurements.duration),
      owner: frame_owner(socket_frame(metadata[:socket])),
      label: event_label(metadata[:event], metadata[:params]),
      tid: metadata[:tid],
      detail: event_detail(metadata[:event], metadata[:params])
    })
  end

  defp normalize([:phoenix, :live_view, :render, :stop], measurements, metadata, time) do
    label =
      case metadata[:component] do
        nil -> "render"
        component -> "render #{inspect(component)}"
      end

    row(%{
      kind: "render",
      layer: "live",
      time_ms: time,
      duration_ms: native_ms(measurements.duration),
      owner: frame_owner(socket_frame(metadata[:socket])),
      label: label,
      tid: metadata[:tid],
      detail: if(metadata[:changed?] == false, do: "unchanged", else: "")
    })
  end

  defp browser_row(fields, frame) do
    row(%{
      kind: text(fields["k"], "browser"),
      layer: "browser",
      time_ms: int(fields["t"], System.system_time(:millisecond)),
      duration_ms: int(fields["ms"], 0),
      queue_ms: int(fields["wait"], 0),
      owner: frame_owner(frame),
      label: text(fields["l"], "browser"),
      tid: if(is_binary(fields["tid"]), do: fields["tid"], else: nil),
      detail: text(fields["d"], "")
    })
  end

  # the intent's text rides along, short: a stray character that reaches
  # a prompt is then visible as the intent that carried it
  defp event_label(event, %{"type" => type} = params) when event == "intent" and is_binary(type) do
    case params["text"] do
      text when is_binary(text) and text != "" -> "event intent #{type} #{inspect(String.slice(text, 0, 12))}"
      _ -> "event intent #{type}"
    end
  end

  defp event_label(event, %{"k" => key}) when event == "key" and is_binary(key),
    do: "event key #{key}"

  defp event_label(event, _params), do: "event #{event}"

  # a measurement the client sent: the row shows the numbers, so a
  # measurement that repeats after every key is visible as one
  defp event_detail(event, %{"rows" => rows}) when event == "win_rows", do: inspect(rows)
  defp event_detail(event, %{"cols" => cols}) when event == "win_cols", do: inspect(cols)
  defp event_detail(event, %{"rows" => rows}) when event == "viewport", do: "rows #{rows}"
  defp event_detail(_event, _params), do: ""

  defp socket_frame(%{assigns: %{frame: frame}}), do: frame
  defp socket_frame(_), do: nil

  defp frame_owner(frame) when is_binary(frame), do: "frame #{frame}"
  defp frame_owner(_), do: "frame"

  defp native_ms(duration) when is_integer(duration),
    do: System.convert_time_unit(duration, :native, :millisecond)

  defp native_ms(_), do: 0

  defp int(value, _default) when is_integer(value), do: value
  defp int(value, _default) when is_float(value), do: round(value)
  defp int(_value, default), do: default

  defp text(value, _default) when is_binary(value), do: value
  defp text(_value, default), do: default
end
