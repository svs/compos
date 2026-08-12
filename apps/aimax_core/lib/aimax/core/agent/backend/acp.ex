defmodule Aimax.Core.Agent.Backend.ACP do
  @moduledoc """
  The ACP backend: owns the adapter subprocess (JSON-RPC 2.0 over stdio,
  newline-framed) via `Agent.Transport`, runs the initialize → session/new
  handshake, translates `session/update` notifications into event plists,
  and forwards everything to the owning `Aimax.Core.Agent` as
  `{:backend_event, plist}`. Wire mechanics only — status, queueing, and
  rendering live above the seam.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend

  # --- behaviour --------------------------------------------------------------

  @impl Backend
  def start(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl Backend
  def prompt(pid, text, _context), do: GenServer.call(pid, {:prompt, text})

  @impl Backend
  def cancel(pid), do: GenServer.call(pid, :cancel)

  @impl Backend
  def close(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl Backend
  def set_model(pid, model_id), do: GenServer.call(pid, {:set_model, model_id})

  @impl Backend
  def set_mode(pid, mode_id), do: GenServer.call(pid, {:set_mode, mode_id})

  @impl Backend
  def respond_permission(pid, rpc_id, option_id),
    do: GenServer.call(pid, {:respond_permission, rpc_id, option_id})

  @impl Backend
  def capabilities, do: [:models, :streaming, :session_modes]

  # --- server -----------------------------------------------------------------

  @impl GenServer
  def init({config, owner}) do
    transport = Aimax.Core.Agent.Transport.impl()
    cmd = Map.get(config, "cmd", "claude-code-acp")

    {:ok, tp} =
      transport.open(cmd, [cd: Map.get(config, "cwd"), env: Map.get(config, "env")], self())

    state = %{
      config: config,
      owner: owner,
      transport: transport,
      tp: tp,
      partial: "",
      next_id: 1,
      pending_rpc: %{},
      session_id: nil
    }

    {:ok,
     request(state, "initialize", %{
       "protocolVersion" => 1,
       "clientCapabilities" => %{
         "fs" => %{"readTextFile" => false, "writeTextFile" => false}
       }
     })}
  end

  @impl GenServer
  def handle_call({:prompt, text}, _from, state) do
    {:reply, :ok,
     request(state, "session/prompt", %{
       "sessionId" => state.session_id,
       "prompt" => [%{"type" => "text", "text" => text}]
     })}
  end

  def handle_call(:cancel, _from, state) do
    state =
      if state.session_id,
        do: notify(state, "session/cancel", %{"sessionId" => state.session_id}),
        else: state

    {:reply, :ok, state}
  end

  def handle_call({:set_model, model_id}, _from, state) do
    if state.session_id do
      {:reply, :ok,
       request(state, "session/set_model", %{
         "sessionId" => state.session_id,
         "modelId" => model_id
       })}
    else
      {:reply, {:error, :no_session}, state}
    end
  end

  def handle_call({:set_mode, mode_id}, _from, state) do
    if state.session_id do
      {:reply, :ok,
       request(state, "session/set_mode", %{
         "sessionId" => state.session_id,
         "modeId" => mode_id
       })}
    else
      {:reply, {:error, :no_session}, state}
    end
  end

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    outcome =
      if option_id,
        do: %{"outcome" => "selected", "optionId" => option_id},
        else: %{"outcome" => "cancelled"}

    {:reply, :ok, respond(state, rpc_id, %{"outcome" => outcome})}
  end

  # --- incoming bytes (real port or fake transport) ---------------------------

  @impl GenServer
  def handle_info({:acp_data, data}, state), do: {:noreply, ingest(state, data)}

  def handle_info({port, {:data, data}}, %{tp: port} = state),
    do: {:noreply, ingest(state, data)}

  def handle_info({:acp_exit, status}, state), do: adapter_exit(state, status)

  def handle_info({port, {:exit_status, status}}, %{tp: port} = state),
    do: adapter_exit(state, status)

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    state.transport.close(state.tp)
    :ok
  end

  # --- framing ----------------------------------------------------------------

  defp ingest(state, data) do
    {lines, partial} = split_lines(state.partial <> data)
    state = %{state | partial: partial}

    Enum.reduce(lines, state, fn line, state ->
      case Jason.decode(line) do
        {:ok, frame} -> handle_frame(state, frame)
        # not JSON — adapter chatter on stdout; ignore
        {:error, _} -> state
      end
    end)
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {partial, lines} = List.pop_at(parts, -1)
    {Enum.reject(lines, &(String.trim(&1) == "")), partial}
  end

  # --- json-rpc ---------------------------------------------------------------

  defp request(state, method, params) do
    id = state.next_id
    frame = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    send_frame(state, frame)
    %{state | next_id: id + 1, pending_rpc: Map.put(state.pending_rpc, id, method)}
  end

  defp notify(state, method, params) do
    send_frame(state, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    state
  end

  defp respond(state, id, result) do
    send_frame(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    state
  end

  defp respond_error(state, id, code, message) do
    send_frame(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })

    state
  end

  defp send_frame(state, frame) do
    state.transport.send_frame(state.tp, [Jason.encode!(frame), "\n"])
  end

  defp emit(state, kvs) do
    send(state.owner, {:backend_event, Backend.plist(kvs)})
    state
  end

  # responses to our requests
  defp handle_frame(state, %{"id" => id} = frame)
       when not is_map_key(frame, "method") do
    {method, pending} = Map.pop(state.pending_rpc, id)
    state = %{state | pending_rpc: pending}

    case {method, frame} do
      {"initialize", %{"result" => _}} ->
        params = %{
          "cwd" => Map.get(state.config, "cwd", File.cwd!()),
          "mcpServers" =>
            acp_servers(
              Map.get(state.config, "mcp-servers") || Map.get(state.config, "mcp_servers") || []
            )
        }

        # connector-declared adapter config, forwarded verbatim. This is how
        # aimax takes control of the agent's surface — the claude-code
        # connector ships settingSources: [] and strictMcpConfig: true, so
        # the adapter reads no user settings file and no user MCP registry,
        # leaving our mcpServers and our answers the only sources.
        params =
          case Map.get(state.config, "meta") do
            nil -> params
            meta -> Map.put(params, "_meta", meta_json(meta))
          end

        request(state, "session/new", params)

      {"session/new", %{"result" => %{"sessionId" => sid} = result}} ->
        state = %{state | session_id: sid}

        # the adapter reports which model the session ACTUALLY runs (and
        # the pickable list) — the truth the modeline shows
        state =
          case result do
            %{"models" => %{"currentModelId" => cur} = ms} ->
              emit(state,
                type: :"model-state",
                current: cur,
                available:
                  for m <- Map.get(ms, "availableModels", []) do
                    [Map.get(m, "modelId"), Map.get(m, "name", "")]
                  end
              )

            _ ->
              state
          end

        # ...and which permission modes it offers, in the SAME payload. We
        # used to drop this: it is how `auto` stops the agent asking at all.
        state = emit_mode_state(state, Map.get(result, "modes"))

        emit(state, type: :ready)

      {"session/set_model", %{"result" => _}} ->
        state

      {"session/set_mode", %{"result" => _}} ->
        state

      {"session/prompt", %{"result" => result}} ->
        emit(state, type: :"turn-end", "stop-reason": Map.get(result, "stopReason", "end_turn"))

      {_, %{"error" => err}} ->
        state =
          emit(state, type: :error, text: "#{method}: #{Map.get(err, "message", inspect(err))}")

        # a failed prompt still ends the turn — a thread must never wedge
        # in :running with no reply coming
        if method == "session/prompt" do
          emit(state, type: :"turn-failed")
        else
          state
        end

      _ ->
        state
    end
  end

  # requests and notifications from the agent
  defp handle_frame(state, %{"method" => method} = frame) do
    id = Map.get(frame, "id")
    params = Map.get(frame, "params", %{})

    case method do
      "session/update" ->
        handle_update(state, Map.get(params, "update", %{}))

      "session/request_permission" ->
        options =
          for opt <- get_in(params, ["options"]) || [] do
            [Map.get(opt, "optionId"), Map.get(opt, "name", ""), Map.get(opt, "kind", "")]
          end

        title = get_in(params, ["toolCall", "title"]) || "tool call"
        kind = get_in(params, ["toolCall", "kind"]) || ""

        emit(state,
          type: :permission,
          "rpc-id": id,
          title: title,
          kind: kind,
          options: options
        )

      # fs/* means files, and agents that want live editor state have the
      # mcp__aimax__ tools — refuse politely so adapters fall back
      m when m in ["fs/read_text_file", "fs/write_text_file"] ->
        respond_error(state, id, -32601, "not supported")

      _ when is_nil(id) ->
        state

      _ ->
        respond_error(state, id, -32601, "method not found: #{method}")
    end
  end

  defp handle_frame(state, _frame), do: state

  defp handle_update(state, %{"sessionUpdate" => kind} = update) do
    case kind do
      "agent_message_chunk" ->
        emit(state, type: :chunk, text: content_text(Map.get(update, "content")))

      "agent_thought_chunk" ->
        emit(state, type: :thought, text: content_text(Map.get(update, "content")))

      "tool_call" ->
        emit(state,
          type: :"tool-call",
          id: Map.get(update, "toolCallId", ""),
          title: Map.get(update, "title", ""),
          kind: Map.get(update, "kind", ""),
          status: Map.get(update, "status", "pending")
        )

      "tool_call_update" ->
        emit(state,
          type: :"tool-update",
          id: Map.get(update, "toolCallId", ""),
          status: Map.get(update, "status", ""),
          text: tool_content_text(Map.get(update, "content"))
        )

      "plan" ->
        entries =
          for e <- Map.get(update, "entries") || [] do
            [Map.get(e, "content", ""), Map.get(e, "status", "")]
          end

        emit(state, type: :plan, entries: entries)

      # the agent switched modes on its own (claude-code does this when it
      # enters plan mode) — the modeline must follow, not guess
      "current_mode_update" ->
        emit(state, type: :"mode-state", current: Map.get(update, "currentModeId", ""))

      _ ->
        state
    end
  end

  defp handle_update(state, _), do: state

  defp content_text(%{"type" => "text", "text" => t}), do: t
  defp content_text(_), do: ""

  defp tool_content_text(nil), do: ""

  defp tool_content_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{"type" => "content", "content" => c} -> content_text(c)
      %{"type" => "diff"} = d -> diff_text(d)
      _ -> ""
    end)
  end

  defp diff_text(%{"path" => path} = d) do
    old = Map.get(d, "oldText") || ""
    new = Map.get(d, "newText", "")

    "--- #{path}\n" <>
      Enum.map_join(String.split(old, "\n"), "", &"-#{&1}\n") <>
      Enum.map_join(String.split(new, "\n"), "", &"+#{&1}\n")
  end

  defp emit_mode_state(state, %{"currentModeId" => cur} = modes) do
    emit(state,
      type: :"mode-state",
      current: cur,
      available:
        for m <- Map.get(modes, "availableModes", []) do
          [Map.get(m, "id"), Map.get(m, "name", ""), Map.get(m, "description", "")]
        end
    )
  end

  defp emit_mode_state(state, _), do: state

  # connector 'meta plists -> JSON. Nested plists become objects, so a
  # connector can declare (meta (claudeCode (options (settingSources ())))).
  # Symbols become strings; the empty list is an empty ARRAY, which is what
  # settingSources: [] needs.
  defp meta_json(plist) when is_list(plist) do
    if plist_shaped?(plist) do
      plist |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {to_string(key(k)), meta_json(v)} end)
    else
      Enum.map(plist, &meta_json/1)
    end
  end

  defp meta_json({:sym, s}), do: s
  defp meta_json(v), do: v

  # a plist is an even-length list whose every other element is a symbol key
  defp plist_shaped?(list) do
    n = length(list)

    n > 0 and rem(n, 2) == 0 and
      list |> Enum.take_every(2) |> Enum.all?(&match?({:sym, _}, &1))
  end

  defp key({:sym, s}), do: s
  defp key(k), do: k

  defp adapter_exit(state, status) do
    emit(state, type: :dead, exit: status)
    {:noreply, %{state | partial: ""}}
  end

  # mcp_servers config (Scheme plists via mcp-acp-servers) -> ACP session/new
  # shape. Env values starting with "@" are key references resolved here —
  # the same convention as MCP client specs, so config files carry no secrets.
  defp acp_servers(servers) when is_list(servers), do: Enum.map(servers, &acp_server/1)

  defp acp_server(flat) when is_list(flat) do
    m = flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {to_string(k), v} end)

    if m["url"] do
      # an http server carries a type — that key is how the adapter tells
      # the two variants apart — and its headers as a name/value list
      %{
        "name" => m["name"],
        "type" => m["type"] || "http",
        "url" => m["url"],
        "headers" => acp_pairs(m["headers"])
      }
    else
      %{
        "name" => m["name"],
        "command" => m["command"],
        "args" => m["args"] || [],
        "env" => acp_pairs(m["env"])
      }
    end
  end

  defp acp_server(other), do: other

  defp acp_pairs(pairs) do
    for [k, v] <- pairs || [], do: %{"name" => to_string(k), "value" => resolve_key(v)}
  end

  defp resolve_key("@" <> var), do: Aimax.Core.Keys.get(var) || ""
  defp resolve_key(v), do: to_string(v)
end
