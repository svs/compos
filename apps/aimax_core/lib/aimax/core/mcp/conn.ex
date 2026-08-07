defmodule Aimax.Core.MCP.Conn do
  @moduledoc """
  One MCP server connection. Transports:

    stdio — %{"command" => c, "args" => [...], "env" => %{...}}: subprocess
    via Port, newline-delimited JSON-RPC. Env values starting with "@" are
    key references resolved through Aimax.Core.Keys ("@GOOGLE_API_KEY").

    http — %{"url" => u, "headers" => [...]}: streamable HTTP; each request
    is a POST (run in a Task so a slow fetch never blocks status queries),
    responses may be plain JSON or a single-response SSE stream. The
    mcp-session-id from initialize is echoed on every later request.

  The handshake (initialize -> notifications/initialized -> tools/list) runs
  async on connect; when the tool list lands it is published via
  MCP.publish/2 and the editor gets a `mcp: <name> ready` message. Requests
  in flight live in `pending` (id -> from | internal tag); a died subprocess
  fails them all instead of leaving callers hanging.
  """

  use GenServer, restart: :temporary
  require Logger

  alias Aimax.Core.{Keys, MCP, Session}

  @protocol "2025-06-18"
  @call_timeout 120_000

  def start_link({name, spec}) do
    GenServer.start_link(__MODULE__, {name, spec},
      name: {:via, Registry, {Aimax.Core.MCPRegistry, name}}
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

  @impl true
  def init({name, spec}) do
    Process.flag(:trap_exit, true)
    {:ok, %{name: name, spec: spec, transport: nil, status: :connecting, buf: "", pending: %{}, next_id: 1}, {:continue, :connect}}
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
    :persistent_term.erase({:aimax_mcp, state.name})
    {:stop, :normal, state}
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

  @impl true
  def terminate(_reason, %{transport: {:stdio, port}}) do
    if port_alive?(port), do: Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- protocol -------------------------------------------------------------

  defp initialize_params do
    %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{name: "ai-max", version: "0.1.0"}
    }
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, msg} -> handle_message(msg, state)
      _ -> state
    end
  end

  # responses to our requests
  defp handle_message(%{"id" => id} = msg, state) when not is_map_key(msg, "method") do
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

      {_internal, %{"error" => err}} ->
        fail_boot(state, err["message"] || Jason.encode!(err))

      {:initialize, %{"result" => _}} ->
        state
        |> send_notification("notifications/initialized", %{})
        |> send_req("tools/list", %{}, :tools)

      {:tools, %{"result" => %{"tools" => tools}}} ->
        MCP.publish(state.name, tools)
        Session.message("mcp: #{state.name} ready (#{length(tools)} tools)")
        %{state | status: :ready}

      _ ->
        state
    end
  end

  # server-initiated: answer pings, ignore the rest (logging/progress)
  defp handle_message(%{"method" => "ping", "id" => id}, state),
    do: send_msg(state, %{jsonrpc: "2.0", id: id, result: %{}})

  defp handle_message(_msg, state), do: state

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

  defp send_msg(%{transport: {:stdio, port}} = state, msg) do
    Port.command(port, Jason.encode!(msg) <> "\n")
    state
  end

  defp send_msg(%{transport: {:http, url, headers, session_id}} = state, msg) do
    me = self()
    id = msg[:id]

    headers =
      if session_id, do: [{"mcp-session-id", session_id} | headers], else: headers

    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
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

  defp resolve_value("@" <> var), do: Keys.get(var) || ""
  defp resolve_value(v), do: to_string(v)

  # mark failed, tell the user, and stop on the next message — callable from
  # any context (handle_continue, the reduce over stdio lines, http tasks)
  defp fail_boot(state, msg) do
    Session.message("mcp: #{state.name} failed — #{msg}")
    send(self(), :stop_conn)
    %{state | status: :error}
  end

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    {Enum.reject(lines, &(&1 == "")), rest}
  end

  defp port_alive?(port), do: Port.info(port) != nil
end
