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
      session_id: nil,
      # ACP session config options (opencode): which option ids the session
      # exposes, and the model id it currently runs
      config_option_ids: [],
      config_model: nil
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
    cond do
      is_nil(state.session_id) ->
        {:reply, {:error, :no_session}, state}

      "model" in state.config_option_ids ->
        {:reply, :ok, set_config_option(state, "model", model_id)}

      true ->
        {:reply, :ok,
         request(state, "session/set_model", %{
           "sessionId" => state.session_id,
           "modelId" => model_id
         })}
    end
  end

  def handle_call({:set_mode, mode_id}, _from, state) do
    cond do
      is_nil(state.session_id) ->
        {:reply, {:error, :no_session}, state}

      "mode" in state.config_option_ids ->
        {:reply, :ok, set_config_option(state, "mode", mode_id)}

      true ->
        {:reply, :ok,
         request(state, "session/set_mode", %{
           "sessionId" => state.session_id,
           "modeId" => mode_id
         })}
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
              Map.get(state.config, "mcp-servers") || Map.get(state.config, "mcp_servers") || [],
              Map.get(state.config, "slug")
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

        # a config-options agent (opencode) reports model and mode as
        # session config options instead of the two keys above
        state = ingest_config_options(state, Map.get(result, "configOptions"))
        state = push_pinned_model(state)

        emit(state, type: :ready)

      {"session/set_model", %{"result" => _}} ->
        state

      {"session/set_mode", %{"result" => _}} ->
        state

      # the response carries the COMPLETE option list — setting one option
      # may change another (opencode grows an effort option per model)
      {"session/set_config_option", %{"result" => result}} ->
        ingest_config_options(state, Map.get(result, "configOptions"))

      {"session/prompt", %{"result" => result}} ->
        emit(state, type: :"turn-end", "stop-reason": Map.get(result, "stopReason", "end_turn"))

      {_, %{"error" => err}} ->
        state =
          emit(state,
            type: :error,
            text: "#{method}: #{Map.get(err, "message") || Backend.error_text(err)}"
          )

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

        tool_call = Map.get(params, "toolCall") || %{}
        title = Map.get(tool_call, "title") || "tool call"
        kind = Map.get(tool_call, "kind") || ""

        emit(state,
          type: :permission,
          "rpc-id": id,
          title: title,
          kind: kind,
          # The whole tool call, so the deny patterns see the ARGUMENTS.
          # A title says "Run command"; only the payload says `git push
          # --force`. Without this the deny-list was blind on this lane
          # while holding on the other.
          raw: raw_of(tool_call),
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

  # a tool call as one searchable string; an adapter may put anything in
  # there, so an unencodable payload degrades to inspect rather than
  # taking the connection down
  defp raw_of(tool_call) do
    case Jason.encode(tool_call) do
      {:ok, json} -> json
      _ -> inspect(tool_call)
    end
  end

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
          # ACP supplies structured rawInput for exactly this purpose. Keep
          # transport conversion here; Scheme decides which argument names
          # and values make a useful card title.
          name: present_text(Map.get(update, "title")),
          input: json_text(Map.get(update, "rawInput")),
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

      "config_option_update" ->
        ingest_config_options(state, Map.get(update, "configOptions"))

      _ ->
        state
    end
  end

  defp handle_update(state, _), do: state

  defp present_text(value) when is_binary(value) and value != "", do: value
  defp present_text(_), do: nil

  defp json_text(nil), do: nil

  defp json_text(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end

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

  # --- session config options (ACP extension; opencode) -----------------------
  # The "model" and "mode" options map onto the same model-state/mode-state
  # events the two session/new keys produce, so everything above the seam —
  # modeline, C-c m, permission-mode sync — works unchanged. Other option
  # ids (opencode's per-model "effort") are ignored for now.

  defp ingest_config_options(state, nil), do: state

  defp ingest_config_options(state, options) when is_list(options) do
    state = %{state | config_option_ids: Enum.map(options, & &1["id"])}

    state =
      case Enum.find(options, &(&1["id"] == "model")) do
        %{"currentValue" => cur} = opt ->
          %{state | config_model: cur}
          |> emit(
            type: :"model-state",
            current: cur,
            available:
              for m <- Map.get(opt, "options", []) do
                [Map.get(m, "value"), Map.get(m, "name", "")]
              end
          )

        _ ->
          state
      end

    case Enum.find(options, &(&1["id"] == "mode")) do
      %{"currentValue" => cur} = opt ->
        emit(state,
          type: :"mode-state",
          current: cur,
          available:
            for m <- Map.get(opt, "options", []) do
              [Map.get(m, "value"), Map.get(m, "name", ""), Map.get(m, "description", "")]
            end
        )

      _ ->
        state
    end
  end

  defp ingest_config_options(state, _), do: state

  defp set_config_option(state, id, value) do
    request(state, "session/set_config_option", %{
      "sessionId" => state.session_id,
      "configId" => id,
      "value" => value
    })
  end

  # a pinned model ('model in the resolved config) has no spawn-time route
  # on this lane — the session starts on the agent's default, then we set
  # the option before ready
  defp push_pinned_model(state) do
    model = Map.get(state.config, "model")

    if is_binary(model) and "model" in state.config_option_ids and model != state.config_model,
      do: set_config_option(state, "model", model),
      else: state
  end

  # connector 'meta plists -> JSON. Nested plists become objects, so a
  # connector can declare (meta (claudeCode (options (settingSources ())))).
  # Symbols become strings; the empty list is an empty ARRAY, which is what
  # settingSources: [] needs.
  defp meta_json(plist), do: Aimax.Core.Plist.to_json(plist)

  defp adapter_exit(state, status) do
    emit(state, type: :dead, exit: status)
    {:noreply, %{state | partial: ""}}
  end

  # mcp_servers config (Scheme plists via mcp-acp-servers) -> ACP session/new
  # shape. Env, header and url values arrive literal: mcp-acp-server already
  # resolved every "@VAR" key reference through packages/keys.scm.
  defp acp_servers(servers, slug) when is_list(servers),
    do: Enum.map(servers, &acp_server(&1, slug))

  defp acp_server(flat, slug) when is_list(flat) do
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
        # every stdio server learns which thread spawned it — the aimax
        # proxy sends it back as the edit author (buffer-authors)
        "env" => acp_pairs(m["env"]) ++ slug_env(m["env"], slug)
      }
    end
  end

  defp acp_server(other, _slug), do: other

  defp slug_env(_pairs, nil), do: []

  defp slug_env(pairs, slug) do
    if Enum.any?(pairs || [], fn [k, _] -> to_string(k) == "AIMAX_AGENT" end),
      do: [],
      else: [%{"name" => "AIMAX_AGENT", "value" => to_string(slug)}]
  end

  defp acp_pairs(pairs) do
    for [k, v] <- pairs || [], do: %{"name" => to_string(k), "value" => to_string(v)}
  end
end
