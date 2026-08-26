defmodule Aimax.Core.Endpoint.Conn do
  @moduledoc """
  One endpoint connection: a named, long-lived byte stream that Scheme
  addresses by name.

  Two transports, chosen by the spec:

    exec — %{"command" => c, "args" => [...], "env" => %{...}, "cd" => d}:
    a subprocess over a Port, talking to its stdin and stdout. Add
    %{"stderr" => "merge"} to read its stderr as frames too: a program
    that reports errors there (psql does) is otherwise silent about them.

    tcp — %{"host" => h, "port" => p}: an active TCP socket.

  Framing turns the byte stream into frames, and a frame is the unit
  Scheme sees. `line` splits on newlines, `delimiter` splits on a given
  string, `content-length` reads the LSP base protocol, `length` reads a
  binary length-prefixed protocol, and `raw` delivers each chunk as it
  arrives. The same rule applies on the way out, so `endpoint-send!`
  writes one frame; `length` and `raw` write the bytes they are given,
  because only the caller knows the header it built.

  `length` is where a binary protocol becomes usable from Scheme: Elixir
  does the byte math and Scheme receives whole messages instead of
  arbitrary chunks. `length-width` sizes the field, `length-prefix` skips
  a header before it (PostgreSQL puts a one-byte message tag there),
  `length-endian` picks the byte order, and `length-counts` says what the
  number measures — the payload after it, itself and the payload
  (PostgreSQL), or the whole message.

  This module holds no protocol. It does not know JSON-RPC, SQL, or a
  handshake. Correlation is a serial ask queue: an ask sends a frame and
  collects later frames until a sentinel frame arrives, and only one ask
  is in flight at a time. Frames that arrive with no ask in flight are
  unsolicited, and they go to the Scheme handler.

  Requests in flight live in `asks`; a dead transport fails them all
  instead of leaving callers hanging. Every frame in either direction,
  plus lifecycle notes, lands in a bounded `log`. The first note names the
  command or address that this connection resolved to, which is the only
  way to see that an endpoint started the wrong program.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Aimax.Core.{Endpoint, Session}

  @log_max 200
  @log_line 4_000
  @default_ask_timeout 30_000

  def start_link({name, spec}) do
    GenServer.start_link(__MODULE__, {name, spec},
      name: {:via, Registry, {Aimax.Core.EndpointRegistry, name}}
    )
  end

  def status(pid) do
    GenServer.call(pid, :status, 5_000)
  catch
    :exit, _ -> :busy
  end

  @doc "Everything the status view shows: status, transport, framing, queue depth."
  def detail(pid) do
    GenServer.call(pid, :detail, 5_000)
  catch
    :exit, _ -> nil
  end

  @doc "The frame log, oldest first: [%{at, dir, text}]."
  def log(pid) do
    GenServer.call(pid, :log, 5_000)
  catch
    :exit, _ -> []
  end

  @doc "Write one frame. Fire and forget."
  def send_frame(pid, text), do: GenServer.cast(pid, {:send, text})

  @doc """
  Send a frame, then collect frames until a sentinel arrives.

  UNTIL is the sentinel frame text, or nil to take the next single frame.
  CB receives {:ok, [frame]} | {:error, msg}. CB must be cheap.
  """
  def ask(pid, text, until, timeout, cb),
    do: GenServer.cast(pid, {:ask, text, until, timeout || @default_ask_timeout, cb})

  def stop_gracefully(pid), do: GenServer.cast(pid, :shutdown)

  @impl true
  def init({name, spec}) do
    Process.flag(:trap_exit, true)

    state = %{
      name: name,
      spec: spec,
      transport: nil,
      status: :connecting,
      stopping: false,
      buf: "",
      framing: framing_of(spec),
      asks: :queue.new(),
      collecting: nil,
      log: []
    }

    {:ok, state, {:continue, :connect}}
  end

  # --- connect --------------------------------------------------------------

  @impl true
  def handle_continue(:connect, %{spec: %{"command" => cmd} = spec} = state) do
    case System.find_executable(cmd) do
      nil ->
        {:noreply, fail_boot(state, "command not found: #{cmd}")}

      exe ->
        env =
          for {k, v} <- spec["env"] || %{} do
            {String.to_charlist(k), String.to_charlist(to_string(v))}
          end

        opts =
          [:binary, :exit_status, args: spec["args"] || [], env: env] ++
            if(spec["cd"], do: [cd: spec["cd"]], else: []) ++
            if(spec["stderr"] == "merge", do: [:stderr_to_stdout], else: [])

        port = Port.open({:spawn_executable, exe}, opts)
        args = Enum.join(spec["args"] || [], " ")

        {:noreply,
         %{state | transport: {:exec, port}}
         |> log(:note, "exec #{exe} #{args}")
         |> ready()}
    end
  end

  def handle_continue(:connect, %{spec: %{"host" => host, "port" => port_no}} = state) do
    opts = [:binary, active: true, packet: :raw]

    case tcp_port(port_no) do
      nil ->
        {:noreply, fail_boot(state, "tcp port must be 1-65535: #{inspect(port_no)}")}

      p ->
        state = log(state, :note, "tcp #{host}:#{p}")

        case :gen_tcp.connect(to_charlist(host), p, opts, 10_000) do
          {:ok, sock} ->
            {:noreply, ready(%{state | transport: {:tcp, sock}})}

          {:error, reason} ->
            {:noreply,
             fail_boot(state, "tcp connect #{host}:#{p}: #{:inet.format_error(reason)}")}
        end
    end
  end

  def handle_continue(:connect, state),
    do: {:noreply, fail_boot(state, ~s|spec needs "command" (exec) or "host" and "port" (tcp)|)}

  defp ready(state) do
    Endpoint.notify(state.name, :ready)
    log(%{state | status: :ready}, :note, "connected")
  end

  # --- calls ----------------------------------------------------------------

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:detail, _from, state) do
    {:reply,
     %{
       status: state.status,
       transport: transport_type(state),
       framing: framing_name(state.framing),
       queued: :queue.len(state.asks) + if(state.collecting, do: 1, else: 0)
     }, state}
  end

  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  @impl true
  def handle_cast({:send, text}, state), do: {:noreply, transmit(state, text)}

  def handle_cast({:ask, text, until, timeout, cb}, state) do
    ask = %{text: text, until: until, timeout: timeout, cb: cb, frames: [], timer: nil, ref: nil}
    {:noreply, pump(%{state | asks: :queue.in(ask, state.asks)})}
  end

  def handle_cast(:shutdown, state), do: {:stop, :normal, %{state | stopping: true}}

  # --- wire in --------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, chunk}}, %{transport: {:exec, port}} = state),
    do: {:noreply, feed(state, chunk)}

  def handle_info({:tcp, sock, chunk}, %{transport: {:tcp, sock}} = state),
    do: {:noreply, feed(state, chunk)}

  def handle_info({port, {:exit_status, code}}, %{transport: {:exec, port}} = state),
    do: {:stop, :normal, died(state, "process exited (#{code})", code == 0)}

  def handle_info({:tcp_closed, sock}, %{transport: {:tcp, sock}} = state),
    do: {:stop, :normal, died(state, "connection closed", true)}

  def handle_info({:tcp_error, sock, reason}, %{transport: {:tcp, sock}} = state),
    do: {:stop, :normal, died(state, "tcp error: #{inspect(reason)}", false)}

  # an ask that outlives its timeout fails, and the queue moves on — a
  # sentinel that never arrives must not wedge every later ask
  def handle_info({:ask_timeout, ref}, %{collecting: %{ref: ref} = ask} = state) do
    safe_cb(ask.cb, {:error, "endpoint: #{state.name} ask timed out"})
    {:noreply, pump(log(%{state | collecting: nil}, :note, "ask timed out"))}
  end

  def handle_info({:ask_timeout, _}, state), do: {:noreply, state}
  def handle_info(:stop_conn, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp died(state, note, clean) do
    unless state.stopping, do: Session.message("endpoint: #{state.name} #{note}")
    state = fail_all(state, note)
    status = if state.stopping or clean, do: :stopped, else: :error
    %{log(state, :note, note) | status: status, transport: nil}
  end

  @impl true
  def terminate(reason, state) do
    status = if state.status == :error, do: :error, else: :stopped

    Endpoint.remember(state.name, %{
      status: status,
      reason: reason_text(reason),
      log: Enum.reverse(state.log)
    })

    Endpoint.notify(state.name, status)
    close(state.transport)
    :ok
  end

  defp close({:exec, port}), do: if(Port.info(port) != nil, do: Port.close(port), else: :ok)
  defp close({:tcp, sock}), do: :gen_tcp.close(sock)
  defp close(_), do: :ok

  defp reason_text(:normal), do: ""
  defp reason_text(:shutdown), do: ""
  defp reason_text(reason), do: inspect(reason)

  # --- framing --------------------------------------------------------------

  defp feed(state, chunk) do
    {frames, buf} = unframe(state.framing, state.buf <> chunk)
    Enum.reduce(frames, %{state | buf: buf}, &route/2)
  end

  @doc false
  # Split a buffer into complete frames plus the unconsumed remainder.
  def unframe(:raw, buf), do: {[buf], ""}

  def unframe({:delimiter, d}, buf) do
    parts = String.split(buf, d)
    {frames, [rest]} = Enum.split(parts, -1)
    {Enum.reject(frames, &(&1 == "")), rest}
  end

  def unframe(:content_length, buf), do: content_length_frames(buf, [])

  def unframe({:length, o}, buf), do: length_frames(buf, o, [])

  # A length-prefixed binary protocol: the header says how many bytes the
  # message holds, so Elixir does the byte math and Scheme receives whole
  # messages. `prefix` is any header before the length field (PostgreSQL
  # puts a one-byte message tag there), and `counts` says what the number
  # measures, which every protocol decides differently.
  defp length_frames(buf, o, acc) do
    header = o.prefix + o.width

    if byte_size(buf) < header do
      {Enum.reverse(acc), buf}
    else
      <<_::binary-size(o.prefix), len_bin::binary-size(o.width), _::binary>> = buf
      len = decode_length(len_bin, o.endian)

      total =
        case o.counts do
          :payload -> header + len
          :self -> o.prefix + len
          :message -> len
        end

      cond do
        # a length that cannot name its own header is a desynchronized
        # stream; drop the buffer rather than loop on it forever
        total < header ->
          {Enum.reverse(acc), ""}

        byte_size(buf) < total ->
          {Enum.reverse(acc), buf}

        true ->
          <<frame::binary-size(total), rest::binary>> = buf
          length_frames(rest, o, [frame | acc])
      end
    end
  end

  defp decode_length(bin, :big), do: :binary.decode_unsigned(bin, :big)
  defp decode_length(bin, :little), do: :binary.decode_unsigned(bin, :little)

  defp content_length_frames(buf, acc) do
    case String.split(buf, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        case content_length(headers) do
          nil ->
            {Enum.reverse(acc), rest}

          len when byte_size(rest) >= len ->
            <<body::binary-size(len), tail::binary>> = rest
            content_length_frames(tail, [body | acc])

          _ ->
            {Enum.reverse(acc), buf}
        end

      _ ->
        {Enum.reverse(acc), buf}
    end
  end

  defp content_length(headers) do
    headers
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "content-length",
            do: String.trim(v) |> Integer.parse() |> then(fn {n, _} -> n; _ -> nil end)

        _ ->
          nil
      end
    end)
  end

  defp enframe(:raw, text), do: text

  # Only the caller knows the header layout of the message it built, so a
  # length endpoint writes the bytes it is given, unchanged.
  defp enframe({:length, _}, text), do: text
  defp enframe({:delimiter, d}, text), do: text <> d

  defp enframe(:content_length, text),
    do: "Content-Length: #{byte_size(text)}\r\n\r\n" <> text

  defp framing_of(spec) do
    case spec["framing"] do
      "raw" -> :raw
      "content-length" -> :content_length
      "delimiter" -> {:delimiter, spec["delimiter"] || "\n"}
      "length" -> {:length, length_opts(spec)}
      _ -> {:delimiter, "\n"}
    end
  end

  defp framing_name(:raw), do: "raw"
  defp framing_name({:length, _}), do: "length"

  defp length_opts(spec) do
    %{
      width: int_opt(spec["length-width"], 4),
      prefix: int_opt(spec["length-prefix"], 0),
      endian: if(spec["length-endian"] == "little", do: :little, else: :big),
      counts:
        case spec["length-counts"] do
          "self" -> :self
          "message" -> :message
          _ -> :payload
        end
    }
  end

  defp int_opt(n, _default) when is_integer(n) and n >= 0, do: n
  defp int_opt(_, default), do: default
  defp framing_name(:content_length), do: "content-length"
  defp framing_name({:delimiter, "\n"}), do: "line"
  defp framing_name({:delimiter, _}), do: "delimiter"

  # --- routing --------------------------------------------------------------

  # a frame belongs to the ask in flight, or to nobody — and a frame that
  # belongs to nobody is what the Scheme handler exists for
  defp route(frame, state) do
    state = log(state, :in, frame)

    case state.collecting do
      nil ->
        Endpoint.dispatch_frame(state.name, frame)
        state

      %{until: nil} = ask ->
        finish(state, ask, [frame])

      %{until: sentinel} = ask ->
        if String.trim(frame) == sentinel,
          do: finish(state, ask, Enum.reverse(ask.frames)),
          else: %{state | collecting: %{ask | frames: [frame | ask.frames]}}
    end
  end

  defp finish(state, ask, frames) do
    if ask.timer, do: Process.cancel_timer(ask.timer)
    safe_cb(ask.cb, {:ok, frames})
    pump(%{state | collecting: nil})
  end

  # start the next ask when the line is clear; asks stay strictly serial
  # because the endpoints that need a sentinel (a REPL, a shell, psql)
  # cannot interleave two answers on one stream
  defp pump(%{collecting: nil} = state) do
    case :queue.out(state.asks) do
      {{:value, ask}, rest} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:ask_timeout, ref}, ask.timeout)
        ask = %{ask | ref: ref, timer: timer}
        transmit(%{state | asks: rest, collecting: ask}, ask.text)

      {:empty, _} ->
        state
    end
  end

  defp pump(state), do: state

  defp fail_all(state, note) do
    if state.collecting, do: safe_cb(state.collecting.cb, {:error, note})
    for ask <- :queue.to_list(state.asks), do: safe_cb(ask.cb, {:error, note})
    %{state | collecting: nil, asks: :queue.new()}
  end

  # --- wire out -------------------------------------------------------------

  defp transmit(%{transport: nil} = state, _text), do: state

  defp transmit(state, text) do
    wire = enframe(state.framing, text)
    state = log(state, :out, text)

    case state.transport do
      {:exec, port} -> Port.command(port, wire)
      {:tcp, sock} -> :gen_tcp.send(sock, wire)
    end

    state
  end

  # --- misc -----------------------------------------------------------------

  # Scheme may hand over a port written as text; anything that is not a
  # usable port number is a spec error, not a crash
  defp tcp_port(n) when is_integer(n) and n > 0 and n < 65_536, do: n

  defp tcp_port(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> tcp_port(n)
      _ -> nil
    end
  end

  defp tcp_port(_), do: nil

  defp transport_type(%{transport: {:exec, _}}), do: :exec
  defp transport_type(%{transport: {:tcp, _}}), do: :tcp
  defp transport_type(_), do: :unknown

  # newest first while it lives here (cheap prepend), reversed on the way out
  defp log(state, dir, text) do
    entry = %{at: System.system_time(:millisecond), dir: dir, text: String.slice(text, 0, @log_line)}
    %{state | log: Enum.take([entry | state.log], @log_max)}
  end

  defp safe_cb(cb, result) when is_function(cb, 1) do
    cb.(result)
  rescue
    e -> Logger.error("endpoint callback: #{Exception.message(e)}")
  end

  defp safe_cb(_, _), do: :ok

  defp fail_boot(state, msg) do
    Session.message("endpoint: #{state.name} failed — #{msg}")
    state = fail_all(state, msg)
    send(self(), :stop_conn)
    %{log(state, :note, "failed — #{msg}") | status: :error}
  end
end
