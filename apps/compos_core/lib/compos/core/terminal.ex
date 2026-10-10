defmodule Compos.Core.Terminal do
  @moduledoc """
  The one PTY runner. Every buffer process runs under `/usr/bin/script`.

  A raw terminal (`raw: true`, the default) serves full-screen programs
  and high-volume app servers. Raw output goes directly to subscribed
  terminal clients. A cleaned, bounded transcript enters the editor
  buffer four times per second.

  A comint process (`raw: false`) is a line-oriented process, as in Emacs
  comint. It runs with TERM=dumb and pty echo off. Each output chunk
  enters the buffer at once without escape sequences, and the process
  mark moves to the end of that output.

  Both kinds accept input, resize, restart, and kill through the same
  functions. Scheme decides which kind a buffer gets.
  """

  use GenServer, restart: :temporary

  alias Compos.Core.Buffer
  alias Compos.Core.Terminal.Transcript

  @registry Compos.Core.TerminalRegistry
  @raw_flush_ms 16
  @transcript_flush_ms 250
  @history_limit 512 * 1024
  @transcript_limit 512 * 1024
  @tty_prefix "COMPOS_TTY="

  @doc "Start COMMAND in a PTY attached to BUFFER. `raw: false` makes a comint process."
  def start(buffer, command, opts \\ []) do
    DynamicSupervisor.start_child(
      Compos.Core.TerminalSupervisor,
      {__MODULE__, buffer: buffer, command: command, raw: Keyword.get(opts, :raw, true)}
    )
  end

  def start_link(opts) do
    buffer = Keyword.fetch!(opts, :buffer)
    command = Keyword.fetch!(opts, :command)
    raw = Keyword.get(opts, :raw, true)

    # the command and the kind ride as the registry value: a restart needs
    # them, and the GenServer state is not reachable once the process is gone
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {@registry, buffer, {command, raw}}}
    )
  end

  def running?(buffer), do: Registry.lookup(@registry, buffer) != []

  @doc "Every running buffer process as {buffer, command}, sorted by buffer."
  def list do
    Registry.select(@registry, [{{:"$1", :_, {:"$2", :_}}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  @doc "Kill the buffer's process and run the same command again."
  def restart(buffer) do
    case Registry.lookup(@registry, buffer) do
      [{pid, {command, raw}}] ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end

        # the registry drops the name a moment after the process dies;
        # starting into a still-registered name returns already_started
        await_unregistered(buffer, 100)
        start(buffer, command, raw: raw)

      [] ->
        {:error, :no_terminal}
    end
  end

  def send_text(buffer, text), do: call(buffer, {:send, text})

  def resize(buffer, cols, rows)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0,
      do: call(buffer, {:resize, cols, rows})

  @doc """
  The size the PTY has now, `{cols, rows}`.

  The transcript is raw bytes, wrapped at the width that wrote them. A client
  that replays it must wear this size first, or every long line re-wraps and
  leaves blank rows above the prompt.
  """
  def size(buffer), do: call(buffer, :size)

  def subscribe(buffer, subscriber \\ self()),
    do: call(buffer, {:subscribe, subscriber})

  @doc "Byte position just after the last process output. User input starts here."
  def mark(buffer) do
    case call(buffer, :mark) do
      {:error, :no_terminal} -> 0
      mark -> mark
    end
  end

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
    # trap exits so terminate/2 runs and can kill the OS process; a closed
    # port only closes stdin, which `script` and its child ignore
    Process.flag(:trap_exit, true)
    buffer = Keyword.fetch!(opts, :buffer)
    command = Keyword.fetch!(opts, :command)
    raw = Keyword.get(opts, :raw, true)
    Compos.Core.create_buffer(buffer)
    if raw, do: sanitize_existing_transcript(buffer)

    wrapper =
      "tty_path=$(tty); printf '#{@tty_prefix}%s\\n' \"$tty_path\"; " <>
        "stty rows 24 cols 80; " <> echo_setting(raw) <> command

    port =
      Port.open({:spawn_executable, "/usr/bin/script"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: script_args(wrapper),
        env: pty_env(raw)
      ])

    {:ok,
     %{
       buffer: buffer,
       raw: raw,
       mark: 0,
       port: port,
       tty: :pending,
       handshake: "",
       # the wrapper above pins the PTY here until a client says otherwise
       cols: 80,
       rows: 24,
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
    {:reply, resize_tty(state.tty, cols, rows), %{state | cols: cols, rows: rows}}
  end

  def handle_call(:size, _from, state), do: {:reply, {state.cols, state.rows}, state}

  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  def handle_call({:subscribe, subscriber}, _from, state) do
    state = monitor_subscriber(state, subscriber)
    history = state.history |> :queue.to_list() |> IO.iodata_to_binary()
    {:reply, {:ok, history}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {data, state} = consume_tty_handshake(data, state)

    state =
      cond do
        data == "" ->
          state

        state.raw ->
          state
          |> Map.update!(:raw_pending, &[data | &1])
          |> schedule_raw_flush()

        true ->
          append(state, strip_ansi(data))
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
    state = state |> flush_terminal() |> append("\n[process exited: #{status}]\n")

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
    state = append(state, state.transcript_pending)
    trim_transcript(state.buffer)
    %{state | transcript_pending: "", mark: Buffer.byte_size(state.buffer)}
  end

  defp append(state, ""), do: state

  defp append(state, text) do
    Buffer.append(state.buffer, text, source: :process)
    %{state | mark: Buffer.byte_size(state.buffer)}
  end

  # -echo: a comint buffer keeps the typed input; the pty must not echo it
  # back, or comint shows it twice
  defp echo_setting(true), do: ""
  defp echo_setting(false), do: "stty -echo 2>/dev/null; "

  # BSD script (macOS) takes the command after the file. util-linux
  # script (Linux) takes one -c string, which it runs with $SHELL, so the
  # wrapper goes to /bin/sh inside single quotes.
  @doc false
  def script_args(wrapper), do: script_args(:os.type(), wrapper)

  @doc false
  def script_args({:unix, :darwin}, wrapper),
    do: ["-q", "/dev/null", "/bin/sh", "-c", wrapper]

  def script_args(_os, wrapper),
    do: ["-q", "-e", "-c", "exec /bin/sh -c " <> sh_quote(wrapper), "/dev/null"]

  defp sh_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp pty_env(true) do
    [
      {~c"TERM", ~c"xterm-256color"},
      {~c"COLORTERM", ~c"truecolor"},
      {~c"NO_COLOR", false},
      {~c"CLICOLOR", ~c"1"},
      {~c"PROMPT_EOL_MARK", ~c""}
    ] ++ host_terminal_unset()
  end

  defp pty_env(false),
    do:
      [{~c"TERM", ~c"dumb"}, {~c"PS1", ~c"$ "}, {~c"PROMPT_EOL_MARK", ~c""}] ++
        host_terminal_unset()

  # The daemon can start inside tmux or screen. The PTY is the editor's
  # terminal, not the host's: a child that sees TMUX wraps its escape
  # sequences for tmux, and the browser terminal draws them as text.
  defp host_terminal_unset do
    for name <- ~w(TMUX TMUX_PANE TMUX_PLUGIN_MANAGER_PATH STY TERM_PROGRAM TERM_PROGRAM_VERSION),
        do: {String.to_charlist(name), false}
  end

  # CSI/OSC sequences and stray carriage returns from a comint pty.
  # " +\r" is the partial-line padding (zsh PROMPT_SP): drop the padding
  # with the CR, not only the CR, or prompts show mid-window.
  defp strip_ansi(data) do
    data
    |> String.replace(~r/\e\[[0-9;?]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\][^\a]*(\a|\e\\)/, "")
    |> String.replace(~r/ +\r(\n?)/, "\\1")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "")
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
           [stty_device_flag(), tty, "rows", Integer.to_string(rows), "cols", Integer.to_string(cols)],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, String.trim(output)}
    end
  end

  defp resize_tty(_, _, _), do: {:error, :tty_not_ready}

  # BSD stty names the device with -f; GNU stty uses -F
  defp stty_device_flag do
    if :os.type() == {:unix, :darwin}, do: "-f", else: "-F"
  end

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
