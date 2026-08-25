defmodule Aimax.Core.Terminal do
  @moduledoc """
  A raw PTY for full-screen programs and high-volume app servers.

  Raw output goes directly to subscribed terminal clients. A cleaned,
  bounded transcript enters the normal editor buffer four times per second.
  This keeps the terminal readable through editor APIs without putting its
  render traffic through the editor document view.
  """

  use GenServer, restart: :temporary

  alias Aimax.Core.Buffer
  alias Aimax.Core.Terminal.Transcript

  @registry Aimax.Core.TerminalRegistry
  @raw_flush_ms 16
  @transcript_flush_ms 250
  @history_limit 512 * 1024
  @transcript_limit 512 * 1024
  @tty_prefix "AIMAX_TTY="

  def start(buffer, command) do
    DynamicSupervisor.start_child(
      Aimax.Core.TerminalSupervisor,
      {__MODULE__, buffer: buffer, command: command}
    )
  end

  def start_link(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    command = Keyword.fetch!(opts, :command)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, buffer, command}})
  end

  def running?(buffer), do: Registry.lookup(@registry, buffer) != []

  def list do
    Registry.select(@registry, [{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  def restart(buffer) do
    case Registry.lookup(@registry, buffer) do
      [{pid, command}] ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end

        await_unregistered(buffer, 100)
        start(buffer, command)

      [] ->
        {:error, :no_terminal}
    end
  end

  def send_text(buffer, text), do: call(buffer, {:send, text})

  def resize(buffer, cols, rows)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0,
      do: call(buffer, {:resize, cols, rows})

  def subscribe(buffer, subscriber \\ self()),
    do: call(buffer, {:subscribe, subscriber})

  def kill(buffer) do
    case Registry.lookup(@registry, buffer) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :no_terminal}
    end
  end

  defp call(buffer, message) do
    case Registry.lookup(@registry, buffer) do
      [{pid, _}] -> GenServer.call(pid, message)
      [] -> {:error, :no_terminal}
    end
  end

  defp await_unregistered(_buffer, 0), do: :ok

  defp await_unregistered(buffer, tries) do
    if running?(buffer) do
      Process.sleep(10)
      await_unregistered(buffer, tries - 1)
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    buffer = Keyword.fetch!(opts, :buffer)
    command = Keyword.fetch!(opts, :command)
    Aimax.Core.create_buffer(buffer)
    sanitize_existing_transcript(buffer)

    wrapper =
      "tty_path=$(tty); printf '#{@tty_prefix}%s\\n' \"$tty_path\"; " <>
        "stty rows 24 cols 80; " <> command

    port =
      Port.open({:spawn_executable, "/usr/bin/script"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-q", "/dev/null", "/bin/sh", "-c", wrapper],
        env: [
          {~c"TERM", ~c"xterm-256color"},
          {~c"COLORTERM", ~c"truecolor"},
          {~c"NO_COLOR", false},
          {~c"CLICOLOR", ~c"1"},
          {~c"PROMPT_EOL_MARK", ~c""}
        ]
      ])

    {:ok,
     %{
       buffer: buffer,
       port: port,
       tty: :pending,
       handshake: "",
       subscribers: %{},
       raw_pending: [],
       raw_timer: nil,
       history: :queue.new(),
       history_bytes: 0,
       transcript: Transcript.new(),
       transcript_pending: "",
       transcript_timer: nil
     }}
  end

  @impl true
  def handle_call({:send, text}, _from, state) do
    Port.command(state.port, text)
    {:reply, :ok, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    {:reply, resize_tty(state.tty, cols, rows), state}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    state = monitor_subscriber(state, subscriber)
    history = state.history |> :queue.to_list() |> IO.iodata_to_binary()
    {:reply, {:ok, history}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {data, state} = consume_tty_handshake(data, state)

    state =
      if data == "" do
        state
      else
        state
        |> Map.update!(:raw_pending, &[data | &1])
        |> schedule_raw_flush()
      end

    {:noreply, state}
  end

  def handle_info(:flush_raw, state) do
    raw = state.raw_pending |> Enum.reverse() |> IO.iodata_to_binary()

    if raw != "" do
      Enum.each(Map.keys(state.subscribers), &send(&1, {:terminal_data, state.buffer, raw}))
    end

    {history, history_bytes} = history_push(state.history, state.history_bytes, raw)

    state = %{
      state
      | raw_pending: [],
        raw_timer: nil,
        history: history,
        history_bytes: history_bytes
    }

    {text, transcript} = Transcript.feed(state.transcript, raw)
    {:noreply, state |> Map.put(:transcript, transcript) |> queue_transcript(text)}
  end

  def handle_info(:flush_transcript, state) do
    {:noreply, state |> Map.put(:transcript_timer, nil) |> flush_transcript()}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = flush_terminal(state)
    Buffer.append(state.buffer, "\n[process exited: #{status}]\n", source: :process)

    Enum.each(Map.keys(state.subscribers), fn subscriber ->
      send(subscriber, {:terminal_exit, state.buffer, status})
    end)

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case state.subscribers do
        %{^pid => ^ref} -> Map.delete(state.subscribers, pid)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  # System.cmd/3 also uses a port. With trap_exit enabled, resize's stty port
  # sends this process an EXIT after the call returns.
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    with {:os_pid, os_pid} <- Port.info(state.port, :os_pid) do
      System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)])
    end

    :ok
  end

  defp consume_tty_handshake(data, %{tty: :pending} = state) do
    bytes = state.handshake <> data

    case :binary.match(bytes, "\n") do
      {at, 1} ->
        line = bytes |> binary_part(0, at) |> String.trim()
        rest = binary_part(bytes, at + 1, byte_size(bytes) - at - 1)

        case line do
          <<@tty_prefix, tty::binary>> -> {rest, %{state | tty: tty, handshake: ""}}
          _ -> {bytes, %{state | tty: nil, handshake: ""}}
        end

      :nomatch ->
        {"", %{state | handshake: bytes}}
    end
  end

  defp consume_tty_handshake(data, state), do: {data, state}

  defp schedule_raw_flush(%{raw_timer: nil} = state) do
    %{state | raw_timer: Process.send_after(self(), :flush_raw, @raw_flush_ms)}
  end

  defp schedule_raw_flush(state), do: state

  defp queue_transcript(state, ""), do: state

  defp queue_transcript(state, text) do
    pending = bounded_tail(state.transcript_pending <> text, @transcript_limit)
    state = %{state | transcript_pending: pending}

    if state.transcript_timer do
      state
    else
      %{
        state
        | transcript_timer: Process.send_after(self(), :flush_transcript, @transcript_flush_ms)
      }
    end
  end

  defp flush_terminal(state) do
    raw = state.raw_pending |> Enum.reverse() |> IO.iodata_to_binary()

    if raw != "" do
      Enum.each(Map.keys(state.subscribers), &send(&1, {:terminal_data, state.buffer, raw}))
    end

    {text, transcript} = Transcript.feed(state.transcript, raw)
    {tail, transcript} = Transcript.finish(transcript)

    state
    |> Map.put(:raw_pending, [])
    |> Map.put(:transcript, transcript)
    |> queue_transcript(text <> tail)
    |> flush_transcript()
  end

  defp flush_transcript(%{transcript_pending: ""} = state), do: state

  defp flush_transcript(state) do
    Buffer.append(state.buffer, state.transcript_pending, source: :process)
    trim_transcript(state.buffer)
    %{state | transcript_pending: ""}
  end

  defp trim_transcript(buffer) do
    size = Buffer.byte_size(buffer)

    if size > @transcript_limit do
      text = Buffer.text(buffer)
      excess = size - @transcript_limit
      tail = binary_part(text, excess, size - excess)

      cut =
        case :binary.match(tail, "\n") do
          {at, 1} -> excess + at + 1
          :nomatch -> utf8_cut(text, excess)
        end

      Buffer.delete_range(buffer, 0, cut, source: :process)
    end
  end

  defp monitor_subscriber(state, subscriber) do
    case state.subscribers do
      %{^subscriber => _} ->
        state

      subscribers ->
        %{state | subscribers: Map.put(subscribers, subscriber, Process.monitor(subscriber))}
    end
  end

  defp resize_tty(tty, cols, rows) when is_binary(tty) do
    case System.cmd(
           "/bin/stty",
           ["-f", tty, "rows", Integer.to_string(rows), "cols", Integer.to_string(cols)],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp resize_tty(_, _, _), do: {:error, :tty_not_ready}

  defp history_push(history, bytes, ""), do: {history, bytes}

  defp history_push(history, bytes, raw) do
    history = :queue.in(raw, history)
    history_trim(history, bytes + byte_size(raw))
  end

  defp history_trim(history, bytes) when bytes <= @history_limit, do: {history, bytes}

  defp history_trim(history, bytes) do
    {{:value, dropped}, history} = :queue.out(history)
    history_trim(history, bytes - byte_size(dropped))
  end

  defp bounded_tail(text, limit) when byte_size(text) <= limit, do: text

  defp bounded_tail(text, limit) do
    start = utf8_cut(text, byte_size(text) - limit)
    binary_part(text, start, byte_size(text) - start)
  end

  defp utf8_cut(text, start) do
    tail = binary_part(text, start, byte_size(text) - start)
    if String.valid?(tail), do: start, else: utf8_cut(text, start + 1)
  end

  defp sanitize_existing_transcript(buffer) do
    text = Buffer.text(buffer)
    clean = Transcript.sanitize(text)

    if clean != text do
      Buffer.delete_range(buffer, 0, byte_size(text), source: :process)
      Buffer.append(buffer, clean, source: :process)
    end
  end
end
