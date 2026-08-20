defmodule Aimax.Core.LSP.Conn do
  @moduledoc """
  One language-server connection: a subprocess speaking JSON-RPC over
  stdio with Content-Length framing (the LSP base protocol).

  The connection is keyed {name, root} — one server process per project
  root. The handshake (initialize -> initialized) runs async on connect;
  didOpen calls that arrive earlier queue and flush when the server is
  ready. Document sync lives here, not in Scheme: the conn subscribes to
  `Aimax.Core.Events` per open buffer and pushes a debounced full-text
  didChange, so the server's view can never drift from the rope.

  Position encoding is negotiated in initialize (utf-8 when the server
  offers it, else the mandatory utf-16). Positions convert to byte
  offsets at this boundary (`LSP.Pos`): Scheme sees `startByte`/`endByte`
  on every diagnostic and location for an open buffer, and never does
  encoding math.

  Server->client requests are always answered — a dropped request can
  wedge a server: workspace/configuration answers the spec's "settings",
  the registration and progress-create requests answer null, anything
  else earns -32601. Notifications forward to Scheme through
  `LSP.dispatch_event/3`, except the log/progress firehose, which lands
  only in the bounded frame log.

  Requests in flight live in `pending` (id -> tag); a dead subprocess
  fails them all. Every frame lands in the bounded `log` — the only way
  to see why a server that won't start won't start.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Aimax.Core.{Buffer, Events, Session}
  alias Aimax.Core.LSP
  alias Aimax.Core.LSP.Pos

  @log_max 200
  @log_line 4_000
  @flush_ms 150

  def start_link({key, spec}) do
    GenServer.start_link(__MODULE__, {key, spec},
      name: {:via, Registry, {Aimax.Core.LSPRegistry, key}}
    )
  end

  def status(pid) do
    GenServer.call(pid, :status, 5_000)
  catch
    :exit, _ -> :busy
  end

  @doc "Everything the status view shows: server_info, caps, docs."
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

  @doc "Send a request; CB receives {:ok, result} | {:error, msg}. CB must be cheap."
  def request(pid, method, params, cb), do: GenServer.cast(pid, {:request, method, params, cb})

  @doc """
  Send a textDocument request positioned at a byte offset of an open
  buffer. The conn builds textDocument/position params and enriches
  location results with byte offsets.
  """
  def buffer_request(pid, method, buffer, byte_pos, extra, cb),
    do: GenServer.cast(pid, {:buffer_request, method, buffer, byte_pos, extra, cb})

  def notify(pid, method, params), do: GenServer.cast(pid, {:notify, method, params})

  def open_doc(pid, buffer), do: GenServer.cast(pid, {:open_doc, buffer})
  def close_doc(pid, buffer), do: GenServer.cast(pid, {:close_doc, buffer})

  @doc "shutdown request -> exit notification -> port close, then stop."
  def stop_gracefully(pid), do: GenServer.cast(pid, :shutdown)

  @impl true
  def init({{name, root} = key, spec}) do
    Process.flag(:trap_exit, true)

    state = %{
      key: key,
      name: name,
      root: root,
      spec: spec,
      port: nil,
      status: :connecting,
      stopping: false,
      buf: "",
      pending: %{},
      next_id: 1,
      server_info: %{},
      caps: %{},
      encoding: :utf16,
      docs: %{},
      open_pending: [],
      dirty: MapSet.new(),
      log: []
    }

    {:ok, state, {:continue, :connect}}
  end

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

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            args: spec["args"] || [],
            env: env,
            cd: state.root
          ])

        state = %{state | port: port}
        {:noreply, send_req(state, "initialize", initialize_params(state), :initialize)}
    end
  end

  def handle_continue(:connect, state),
    do: {:noreply, fail_boot(state, "spec needs \"command\"")}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:detail, _from, state) do
    {:reply,
     %{
       status: state.status,
       root: state.root,
       server_info: state.server_info,
       caps: state.caps,
       encoding: state.encoding,
       docs: Map.keys(state.docs)
     }, state}
  end

  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  @impl true
  def handle_cast({:request, method, params, cb}, state) do
    if state.status == :ready do
      {:noreply, send_req(state, method, params, {:callback, cb})}
    else
      safe_cb(cb, {:error, "lsp: #{state.name} not ready"})
      {:noreply, state}
    end
  end

  def handle_cast({:buffer_request, method, buffer, byte_pos, extra, cb}, state) do
    cond do
      state.status != :ready ->
        safe_cb(cb, {:error, "lsp: #{state.name} not ready"})
        {:noreply, state}

      not Map.has_key?(state.docs, buffer) ->
        safe_cb(cb, {:error, "lsp: #{buffer} not open on #{state.name}"})
        {:noreply, state}

      true ->
        text = Buffer.text(buffer)
        starts = Pos.line_starts(text)

        params =
          Map.merge(extra || %{}, %{
            "textDocument" => %{"uri" => uri(buffer)},
            "position" => Pos.to_lsp(text, starts, byte_pos, state.encoding)
          })

        {:noreply, send_req(state, method, params, {:callback, cb})}
    end
  end

  def handle_cast({:notify, method, params}, state),
    do: {:noreply, send_notification(state, method, params)}

  def handle_cast({:open_doc, buffer}, state) do
    cond do
      Map.has_key?(state.docs, buffer) ->
        {:noreply, state}

      state.status == :ready ->
        {:noreply, do_open(state, buffer)}

      true ->
        {:noreply, %{state | open_pending: [buffer | state.open_pending]}}
    end
  end

  def handle_cast({:close_doc, buffer}, state) do
    {:noreply, do_close(state, buffer)}
  end

  def handle_cast(:shutdown, state) do
    Process.send_after(self(), :force_exit, 2_000)
    {:noreply, send_req(%{state | stopping: true}, "shutdown", nil, :shutdown)}
  end

  # --- wire in ---------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {frames, buf} = split_frames(state.buf <> chunk)
    state = Enum.reduce(frames, %{state | buf: buf}, &handle_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    unless state.stopping, do: Session.message("lsp: #{state.name} exited (#{code})")

    for {_, {:callback, cb}} <- state.pending,
        do: safe_cb(cb, {:error, "lsp server exited"})

    state = log(state, :note, "process exited (#{code})")
    status = if state.stopping or code == 0, do: state.status, else: :error
    {:stop, :normal, %{state | status: status, port: nil}}
  end

  def handle_info({:buffer_change, name, _change}, state) do
    if Map.has_key?(state.docs, name) and not MapSet.member?(state.dirty, name) do
      Process.send_after(self(), {:flush_doc, name}, @flush_ms)
      {:noreply, %{state | dirty: MapSet.put(state.dirty, name)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:flush_doc, name}, state) do
    state = %{state | dirty: MapSet.delete(state.dirty, name)}

    cond do
      not Map.has_key?(state.docs, name) ->
        {:noreply, state}

      not Buffer.exists?(name) ->
        {:noreply, do_close(state, name)}

      true ->
        {:noreply,
         send_notification(state, "textDocument/didChange", %{
           "textDocument" => %{"uri" => uri(name), "version" => Buffer.version(name)},
           "contentChanges" => [%{"text" => Buffer.text(name)}]
         })}
    end
  end

  def handle_info(:force_exit, state) do
    if state.port, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(:stop_conn, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    status = if state.status == :error, do: :error, else: :stopped

    LSP.remember(state.key, %{
      status: status,
      reason: reason_text(reason),
      log: Enum.reverse(state.log)
    })

    LSP.notify(state.key, status)

    if state.port && port_alive?(state.port) do
      os = Port.info(state.port, :os_pid)
      Port.close(state.port)

      case os do
        {:os_pid, pid} -> System.cmd("/bin/kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
        _ -> :ok
      end
    end

    :ok
  end

  defp reason_text(:normal), do: ""
  defp reason_text(:shutdown), do: ""
  defp reason_text(reason), do: inspect(reason)

  # --- protocol --------------------------------------------------------------

  defp initialize_params(state) do
    %{
      "processId" => String.to_integer(System.pid()),
      "rootUri" => "file://" <> state.root,
      "workspaceFolders" => [
        %{"uri" => "file://" <> state.root, "name" => Path.basename(state.root)}
      ],
      "clientInfo" => %{"name" => "ai-max", "version" => "0.1.0"},
      "capabilities" => %{
        "general" => %{"positionEncodings" => ["utf-8", "utf-16"]},
        "textDocument" => %{
          "synchronization" => %{"didSave" => true},
          "publishDiagnostics" => %{},
          "completion" => %{"completionItem" => %{"snippetSupport" => false}},
          "hover" => %{"contentFormat" => ["plaintext", "markdown"]},
          "definition" => %{},
          "references" => %{}
        },
        "workspace" => %{"configuration" => true, "workspaceFolders" => true}
      },
      "initializationOptions" => state.spec["init_options"] || %{}
    }
  end

  defp handle_message(msg, state), do: dispatch(msg, log(state, :in, msg))

  # responses to our requests
  defp dispatch(%{"id" => id} = msg, state) when not is_map_key(msg, "method") do
    {tag, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case {tag, msg} do
      {nil, _} ->
        state

      {{:callback, cb}, %{"error" => err}} ->
        safe_cb(cb, {:error, err["message"] || Jason.encode!(err)})
        state

      {{:callback, cb}, %{"result" => result}} ->
        safe_cb(cb, {:ok, enrich(result, state)})
        state

      {:initialize, %{"error" => err}} ->
        fail_boot(state, err["message"] || Jason.encode!(err))

      {:initialize, %{"result" => result}} ->
        caps = result["capabilities"] || %{}
        enc = if caps["positionEncoding"] == "utf-8", do: :utf8, else: :utf16

        state =
          %{state | server_info: result["serverInfo"] || %{}, caps: caps, encoding: enc}
          |> send_notification("initialized", %{})
          |> Map.put(:status, :ready)

        Session.message("lsp: #{state.name} ready")
        LSP.notify(state.key, :ready)

        state =
          Enum.reduce(Enum.reverse(state.open_pending), state, fn buf, acc ->
            if Map.has_key?(acc.docs, buf), do: acc, else: do_open(acc, buf)
          end)

        %{state | open_pending: []}

      {:shutdown, _} ->
        state = send_notification(state, "exit", nil)
        send(self(), :stop_conn)
        state

      _ ->
        state
    end
  end

  # server -> client requests: always answer
  defp dispatch(%{"id" => id, "method" => "workspace/configuration"} = msg, state) do
    items = get_in(msg, ["params", "items"]) || []
    settings = state.spec["settings"]
    send_msg(state, %{jsonrpc: "2.0", id: id, result: List.duplicate(settings, length(items))})
  end

  defp dispatch(%{"id" => id, "method" => method}, state)
       when method in [
              "client/registerCapability",
              "client/unregisterCapability",
              "window/workDoneProgress/create",
              "window/showMessageRequest"
            ],
       do: send_msg(state, %{jsonrpc: "2.0", id: id, result: nil})

  defp dispatch(%{"id" => id, "method" => method}, state) when is_binary(method) do
    send_msg(state, %{
      jsonrpc: "2.0",
      id: id,
      error: %{code: -32_601, message: "method not found: #{method}"}
    })
  end

  # server notifications
  defp dispatch(%{"method" => "textDocument/publishDiagnostics", "params" => params}, state) do
    case doc_for_uri(state, params["uri"]) do
      nil ->
        state

      buffer ->
        text = Buffer.text(buffer)
        starts = Pos.line_starts(text)

        diags =
          for d <- params["diagnostics"] || [] do
            {s, e} = Pos.range_to_bytes(text, starts, d["range"] || %{}, state.encoding)
            d |> Map.put("startByte", s) |> Map.put("endByte", e)
          end

        LSP.dispatch_event(
          state.key,
          "textDocument/publishDiagnostics",
          params |> Map.put("diagnostics", diags) |> Map.put("buffer", buffer)
        )

        state
    end
  end

  # the log/progress firehose stays in the frame log only
  defp dispatch(%{"method" => method}, state)
       when method in ["window/logMessage", "telemetry/event"] or
              binary_part(method, 0, 2) == "$/",
       do: state

  defp dispatch(%{"method" => method, "params" => params}, state) do
    LSP.dispatch_event(state.key, method, params || %{})
    state
  end

  defp dispatch(_msg, state), do: state

  # --- documents -------------------------------------------------------------

  defp do_open(state, buffer) do
    if Buffer.exists?(buffer) do
      Events.subscribe(buffer)

      state
      |> send_notification("textDocument/didOpen", %{
        "textDocument" => %{
          "uri" => uri(buffer),
          "languageId" => state.spec["language"] || "plaintext",
          "version" => Buffer.version(buffer) || 0,
          "text" => Buffer.text(buffer)
        }
      })
      |> put_in([:docs, buffer], %{uri: uri(buffer)})
    else
      log(state, :note, "didOpen skipped, no buffer: #{buffer}")
    end
  end

  defp do_close(state, buffer) do
    if Map.has_key?(state.docs, buffer) do
      Events.unsubscribe(buffer)

      state
      |> send_notification("textDocument/didClose", %{
        "textDocument" => %{"uri" => uri(buffer)}
      })
      |> Map.update!(:docs, &Map.delete(&1, buffer))
    else
      state
    end
  end

  defp uri(buffer), do: "file://" <> buffer

  defp doc_for_uri(state, uri) do
    Enum.find_value(state.docs, fn {buffer, %{uri: u}} ->
      if u == uri, do: buffer
    end)
  end

  # add byte offsets to Location / LocationLink results for open buffers
  defp enrich(result, state) when is_list(result), do: Enum.map(result, &enrich(&1, state))

  defp enrich(%{"uri" => uri, "range" => range} = loc, state),
    do: enrich_loc(loc, uri, range, state)

  defp enrich(%{"targetUri" => uri, "targetRange" => range} = loc, state),
    do: enrich_loc(loc, uri, range, state)

  defp enrich(result, _state), do: result

  defp enrich_loc(loc, uri, range, state) do
    case doc_for_uri(state, uri) do
      nil ->
        loc

      buffer ->
        text = Buffer.text(buffer)
        starts = Pos.line_starts(text)
        {s, e} = Pos.range_to_bytes(text, starts, range, state.encoding)
        loc |> Map.put("buffer", buffer) |> Map.put("startByte", s) |> Map.put("endByte", e)
    end
  end

  # --- wire out --------------------------------------------------------------

  defp send_req(state, method, params, tag) do
    id = state.next_id
    msg = %{jsonrpc: "2.0", id: id, method: method, params: params}

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}
    |> send_msg(msg)
  end

  defp send_notification(state, method, params),
    do: send_msg(state, %{jsonrpc: "2.0", method: method, params: params})

  defp send_msg(state, msg), do: state |> log(:out, msg) |> transmit(msg)

  defp transmit(%{port: port} = state, msg) when port != nil do
    json = Jason.encode!(msg)
    Port.command(port, "Content-Length: #{byte_size(json)}\r\n\r\n" <> json)
    state
  end

  defp transmit(state, _msg), do: state

  defp safe_cb(cb, result) do
    cb.(result)
  rescue
    e -> Logger.warning("lsp callback failed: #{Exception.message(e)}")
  end

  # --- framing ---------------------------------------------------------------

  @doc false
  # Content-Length framing; tolerates bare \n\n header separators.
  def split_frames(buf, acc \\ []) do
    case header_split(buf) do
      nil ->
        {Enum.reverse(acc), buf}

      {header, rest} ->
        case content_length(header) do
          nil ->
            split_frames(rest, acc)

          len when byte_size(rest) >= len ->
            body = binary_part(rest, 0, len)
            tail = binary_part(rest, len, byte_size(rest) - len)

            case Jason.decode(body) do
              {:ok, msg} -> split_frames(tail, [msg | acc])
              _ -> split_frames(tail, acc)
            end

          _ ->
            {Enum.reverse(acc), buf}
        end
    end
  end

  defp header_split(buf) do
    crlf = :binary.match(buf, "\r\n\r\n")
    lf = :binary.match(buf, "\n\n")

    case first_match(crlf, lf) do
      nil -> nil
      {pos, len} -> {binary_part(buf, 0, pos), binary_part(buf, pos + len, byte_size(buf) - pos - len)}
    end
  end

  defp first_match(:nomatch, :nomatch), do: nil
  defp first_match({p, l}, :nomatch), do: {p, l}
  defp first_match(:nomatch, {p, l}), do: {p, l}
  defp first_match({p1, l1}, {p2, _}) when p1 <= p2, do: {p1, l1}
  defp first_match(_, {p2, l2}), do: {p2, l2}

  defp content_length(header) do
    header
    |> String.split(~r/\r?\n/)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "content-length" do
            case Integer.parse(String.trim(v)) do
              {n, _} -> n
              _ -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end

  # --- misc ------------------------------------------------------------------

  defp log(state, dir, msg) do
    entry = %{at: System.system_time(:millisecond), dir: dir, text: log_text(msg)}
    %{state | log: Enum.take([entry | state.log], @log_max)}
  end

  defp log_text(msg) when is_binary(msg), do: String.slice(msg, 0, @log_line)
  defp log_text(msg), do: msg |> Jason.encode!() |> String.slice(0, @log_line)

  defp fail_boot(state, msg) do
    Session.message("lsp: #{state.name} failed — #{msg}")
    send(self(), :stop_conn)
    %{log(state, :note, "failed — #{msg}") | status: :error}
  end

  defp port_alive?(port), do: Port.info(port) != nil
end
