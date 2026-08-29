defmodule Compos.Core.MCP.Conn do
  @moduledoc """
  One MCP server connection. Transports:

    stdio — %{"command" => c, "args" => [...], "env" => %{...}}: subprocess
    via Port, newline-delimited JSON-RPC.

    http — %{"url" => u, "headers" => [...]}: streamable HTTP; each request
    is a POST (run in a Task so a slow fetch never blocks status queries),
    responses may be plain JSON or a single-response SSE stream. The
    mcp-session-id from initialize is echoed on every later request.

  The handshake (initialize -> notifications/initialized -> tools/list) runs
  async on connect; when the tool list lands it is published via
  MCP.publish/2 and the editor gets a `mcp: <name> ready` message. Resources
  and prompts are asked for afterwards, and only when `initialize` advertised
  the capability — an unsolicited `resources/list` earns a -32601 from
  servers that have none, and a failed handshake request kills the
  connection. They are cold data (the hub's detail view), so they stay in
  this process rather than in the persistent_term the tool loop reads.

  Env and header values arrive literal. A spec written with "@VAR" key
  references resolves in Scheme (packages/keys.scm, called from
  packages/mcp.scm) before it reaches this process: where a secret lives
  is policy, and this module holds none.

  Requests in flight live in `pending` (id -> from | internal tag); a died
  subprocess fails them all instead of leaving callers hanging. Every frame
  in either direction, plus lifecycle notes, lands in a bounded `log` —
  what `l` shows in the hub, and the only way to see why a server that
  won't start won't start.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Compos.Core.{MCP, Session}

  @protocol "2025-06-18"
  @call_timeout 120_000
  @log_max 200
  @log_line 4_000

  def start_link({name, spec}) do
    GenServer.start_link(__MODULE__, {name, spec},
      name: {:via, Registry, {Compos.Core.MCPRegistry, name}}
    )
  end

  def status(pid) do
    GenServer.call(pid, :status, 5_000)
  catch
    :exit, _ -> :busy
  end

  @doc "Call a tool; returns {:ok, text} | {:error, msg}."
  def call_tool(pid, tool, args) do
    GenServer.call(pid, {:call_tool, tool, args}, @call_timeout)
  catch
    :exit, _ -> {:error, "mcp call timed out or connection died"}
  end

  @doc "Status plus the counts the hub lists: %{status, type, resources, prompts}."
  def summary(pid) do
    GenServer.call(pid, :summary, 5_000)
  catch
    :exit, _ -> %{status: :busy, type: :unknown, resources: 0, prompts: 0}
  end

  @doc "Everything the hub's detail view shows: server_info, resources, prompts."
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

  @impl true
  def init({name, spec}) do
    Process.flag(:trap_exit, true)

    state = %{
      name: name,
      spec: spec,
      transport: nil,
      status: :connecting,
      buf: "",
      pending: %{},
      next_id: 1,
      server_info: %{},
      caps: %{},
      resources: [],
      prompts: [],
      log: []
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{spec: %{"url" => url} = spec} = state) do
    headers =
      [{"accept", "application/json, text/event-stream"} | resolve_headers(spec["headers"] || %{})]

    state = %{state | transport: {:http, url, headers, nil}}
    {:noreply, send_req(state, "initialize", initialize_params(), :initialize)}
  end

  def handle_continue(:connect, %{spec: %{"command" => cmd} = spec} = state) do
    case System.find_executable(cmd) do
      nil ->
        {:noreply, fail_boot(state, "command not found: #{cmd}")}

      exe ->
        env =
          for {k, v} <- spec["env"] || %{} do
            {String.to_charlist(k), String.to_charlist(resolve_value(v))}
          end

        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            args: spec["args"] || [],
            env: env
          ])

        state = %{state | transport: {:stdio, port}}
        {:noreply, send_req(state, "initialize", initialize_params(), :initialize)}
    end
  end

  def handle_continue(:connect, state),
    do: {:noreply, fail_boot(state, "spec needs \"command\" (stdio) or \"url\" (http)")}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:summary, _from, state) do
    {:reply,
     %{
       status: state.status,
       type: transport_type(state),
       resources: length(state.resources),
       prompts: length(state.prompts)
     }, state}
  end

  def handle_call(:detail, _from, state) do
    {:reply,
     %{
       status: state.status,
       type: transport_type(state),
       server_info: state.server_info,
       resources: state.resources,
       prompts: state.prompts
     }, state}
  end

  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  def handle_call({:call_tool, tool, args}, from, state) do
    {:noreply, send_req(state, "tools/call", %{name: tool, arguments: args}, {:reply, from})}
  end

  # --- wire in (stdio) ------------------------------------------------------

  @impl true
  def handle_info({port, {:data, chunk}}, %{transport: {:stdio, port}} = state) do
    {lines, buf} = split_lines(state.buf <> chunk)
    state = Enum.reduce(lines, %{state | buf: buf}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{transport: {:stdio, port}} = state) do
    Session.message("mcp: #{state.name} exited (#{code})")
    for {_, {:reply, from}} <- state.pending, do: GenServer.reply(from, {:error, "mcp server exited"})
    :persistent_term.erase({:compos_mcp, state.name})
    state = log(state, :note, "process exited (#{code})")
    {:stop, :normal, if(code == 0, do: state, else: %{state | status: :error})}
  end

  # a Task doing an HTTP round-trip delivers the decoded response here
  def handle_info({:http_response, id, result}, state) do
    case result do
      {:ok, msg, session_id} ->
        state = store_session(state, session_id)
        {:noreply, handle_message(msg, state)}

      {:error, reason} ->
        {tag, pending} = Map.pop(state.pending, id)
        state = %{state | pending: pending}

        case tag do
          {:reply, from} ->
            GenServer.reply(from, {:error, reason})
            {:noreply, state}

          nil ->
            {:noreply, state}

          _internal ->
            {:noreply, fail_boot(state, reason)}
        end
    end
  end

  def handle_info(:stop_conn, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  # a connection that fails takes its log with it, and the hub would have
  # nothing to show for the row that just went red — leave the last words
  # (status, reason, frames) behind for MCP.last/1
  @impl true
  def terminate(reason, state) do
    status = if state.status == :error, do: :error, else: :stopped

    MCP.remember(state.name, %{
      status: status,
      reason: reason_text(reason),
      log: Enum.reverse(state.log)
    })

    MCP.notify(state.name, status)

    case state.transport do
      {:stdio, port} -> if port_alive?(port), do: Port.close(port)
      _ -> :ok
    end

    :ok
  end

  defp reason_text(:normal), do: ""
  defp reason_text(:shutdown), do: ""
  defp reason_text(reason), do: inspect(reason)

  # --- protocol -------------------------------------------------------------

  defp initialize_params do
    %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{name: "compos", version: "0.1.0"}
    }
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, msg} -> handle_message(msg, state)
      _ -> state
    end
  end

  # every frame is logged before it is acted on, so the hub's log reads as
  # the conversation actually happened
  defp handle_message(msg, state), do: dispatch(msg, log(state, :in, msg))

  # responses to our requests
  defp dispatch(%{"id" => id} = msg, state) when not is_map_key(msg, "method") do
    {tag, pending} = Map.pop(state.pending, id)
    state = %{state | pending: pending}

    case {tag, msg} do
      {nil, _} ->
        state

      {{:reply, from}, %{"result" => result}} ->
        GenServer.reply(from, result_text(result))
        state

      {{:reply, from}, %{"error" => err}} ->
        GenServer.reply(from, {:error, err["message"] || Jason.encode!(err)})
        state

      # only the handshake is fatal: a server that declines to list its
      # resources still serves tools perfectly well
      {handshake, %{"error" => err}} when handshake in [:initialize, :tools] ->
        fail_boot(state, err["message"] || Jason.encode!(err))

      {_optional, %{"error" => _}} ->
        state

      {:initialize, %{"result" => result}} ->
        %{state | server_info: result["serverInfo"] || %{}, caps: result["capabilities"] || %{}}
        |> send_notification("notifications/initialized", %{})
        |> send_req("tools/list", %{}, :tools)

      {:tools, %{"result" => %{"tools" => tools}}} ->
        MCP.publish(state.name, tools, state.spec)
        Session.message("mcp: #{state.name} ready (#{length(tools)} tools)")
        MCP.notify(state.name, :ready)
        discover(%{state | status: :ready})

      {:resources, %{"result" => %{"resources" => rs}}} ->
        MCP.notify(state.name, :ready)
        %{state | resources: rs}

      {:prompts, %{"result" => %{"prompts" => ps}}} ->
        MCP.notify(state.name, :ready)
        %{state | prompts: ps}

      _ ->
        state
    end
  end

  # server-initiated: answer pings, ignore the rest (logging/progress)
  defp dispatch(%{"method" => "ping", "id" => id}, state),
    do: send_msg(state, %{jsonrpc: "2.0", id: id, result: %{}})

  defp dispatch(_msg, state), do: state

  # the optional halves of the protocol, asked for only where advertised
  defp discover(state) do
    Enum.reduce([{"resources", :resources}, {"prompts", :prompts}], state, fn {cap, tag}, acc ->
      if is_map(state.caps[cap]),
        do: send_req(acc, "#{cap}/list", %{}, tag),
        else: acc
    end)
  end

  defp result_text(%{"isError" => true} = result), do: {:error, content_text(result)}
  defp result_text(result), do: {:ok, content_text(result)}

  defp content_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => other} -> "[#{other} content]"
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp content_text(result), do: Jason.encode!(result)

  # --- wire out -------------------------------------------------------------

  defp send_req(state, method, params, tag) do
    id = state.next_id
    msg = %{jsonrpc: "2.0", id: id, method: method, params: params}

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}
    |> send_msg(msg)
  end

  defp send_notification(state, method, params),
    do: send_msg(state, %{jsonrpc: "2.0", method: method, params: params})

  defp send_msg(state, msg), do: state |> log(:out, msg) |> transmit(msg)

  defp transmit(%{transport: {:stdio, port}} = state, msg) do
    Port.command(port, Jason.encode!(msg) <> "\n")
    state
  end

  defp transmit(%{transport: {:http, url, headers, session_id}} = state, msg) do
    me = self()
    id = msg[:id]

    headers =
      if session_id, do: [{"mcp-session-id", session_id} | headers], else: headers

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      case Req.post(url, json: msg, headers: headers, receive_timeout: @call_timeout) do
        {:ok, %{status: status, body: body, headers: rh}} when status in 200..299 ->
          sid = rh |> Map.get("mcp-session-id", []) |> List.first()

          if id do
            case decode_http_body(body, id) do
              nil -> send(me, {:http_response, id, {:error, "empty mcp response"}})
              decoded -> send(me, {:http_response, id, {:ok, decoded, sid}})
            end
          end

        {:ok, %{status: status}} ->
          if id, do: send(me, {:http_response, id, {:error, "mcp http #{status}"}})

        {:error, e} ->
          if id, do: send(me, {:http_response, id, {:error, Exception.message(e)}})
      end
    end)

    state
  end

  @doc false
  # streamable HTTP responses: plain JSON map, or an SSE stream whose data
  # lines each carry a JSON-RPC message — pick the response matching id.
  def decode_http_body(body, id) when is_binary(body) do
    if String.contains?(body, "data:") do
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.flat_map(fn "data:" <> data ->
        case Jason.decode(String.trim(data)) do
          {:ok, msg} -> [msg]
          _ -> []
        end
      end)
      |> Enum.find(&(&1["id"] == id))
    else
      case Jason.decode(body) do
        {:ok, msg} -> msg
        _ -> nil
      end
    end
  end

  def decode_http_body(body, _id) when is_map(body), do: body
  def decode_http_body(_, _), do: nil

  # --- misc -----------------------------------------------------------------

  defp store_session(%{transport: {:http, url, headers, nil}} = state, sid) when is_binary(sid),
    do: %{state | transport: {:http, url, headers, sid}}

  defp store_session(state, _), do: state

  defp resolve_headers(headers),
    do: for({k, v} <- headers, do: {k, resolve_value(v)})

  defp transport_type(%{transport: {:stdio, _}}), do: :stdio
  defp transport_type(%{transport: {:http, _, _, _}}), do: :http
  defp transport_type(_), do: :unknown

  # newest first while it lives here (cheap prepend), reversed on the way out
  defp log(state, dir, msg) do
    entry = %{at: System.system_time(:millisecond), dir: dir, text: log_text(msg)}
    %{state | log: Enum.take([entry | state.log], @log_max)}
  end

  defp log_text(msg) when is_binary(msg), do: String.slice(msg, 0, @log_line)
  defp log_text(msg), do: msg |> Jason.encode!() |> String.slice(0, @log_line)

  defp resolve_value(v), do: to_string(v)

  # mark failed, tell the user, and stop on the next message — callable from
  # any context (handle_continue, the reduce over stdio lines, http tasks)
  defp fail_boot(state, msg) do
    Session.message("mcp: #{state.name} failed — #{msg}")
    send(self(), :stop_conn)
    %{log(state, :note, "failed — #{msg}") | status: :error}
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp port_alive?(port), do: Port.info(port) != nil
end
