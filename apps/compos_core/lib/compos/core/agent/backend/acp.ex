defmodule Compos.Core.Agent.Backend.ACP do
  @moduledoc """
  The ACP backend: owns the adapter subprocess (JSON-RPC 2.0 over stdio,
  newline-framed) via `Agent.Transport`, runs the initialize → session/new
  handshake, translates `session/update` notifications into event plists,
  and forwards everything to the owning `Compos.Core.Agent` as
  `{:backend_event, plist}`. Wire mechanics only — status, queueing, and
  rendering live above the seam.
  """

  use Compos.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Compos.Core.JsonRpc
  alias Compos.Core.Agent.Backend

  # --- behaviour --------------------------------------------------------------

  @impl Backend
  def prompt(pid, text, context),
    do: GenServer.call(pid, {:prompt, text, Map.get(context, :images) || []})

  @impl Backend
  def steer(pid, token, text, _display, epoch),
    do: GenServer.call(pid, {:steer, token, text, epoch})

  @impl Backend
  def set_mode(pid, mode_id), do: GenServer.call(pid, {:set_mode, mode_id})

  @impl Backend
  def set_effort(pid, effort), do: GenServer.call(pid, {:set_effort, effort})

  @impl Backend
  def capabilities, do: [:models, :streaming, :session_modes, :reasoning_effort]

  # --- server -----------------------------------------------------------------

  @impl GenServer
  def init({config, owner}) do
    transport = Compos.Core.Agent.Transport.impl()
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
      config_model: nil,
      # a config-option model value is opaque on the wire (dsh spells it
      # ["provider","model"]), so keep display id -> wire value
      config_model_wire: %{},
      # the reasoning-effort option, when the session offers one
      config_efforts: [],
      config_effort: nil,
      # monotonic start per running tool call id; the completing
      # tool-update reads it to stamp duration-ms
      tool_started: %{},
      # an adapter with no system-prompt channel takes our sections on the
      # session's first turn, and only that one
      system_sent: false,
      # the session this thread held before its adapter was closed (an idle
      # park, a daemon restart): initialize asks for it back with
      # session/load when the agent advertises loadSession
      resume: Map.get(config, "resume-session"),
      # session/load replays the whole conversation as session/update
      # notifications before it answers; the transcript already shows that
      # text, so every update is dropped until the reply lands
      loading: false
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
  def handle_call({:prompt, text, images}, _from, state) do
    {state, text} = with_system_preamble(state, text)

    {:reply, :ok,
     request(state, "session/prompt", %{
       "sessionId" => state.session_id,
       "prompt" => [%{"type" => "text", "text" => text} | image_blocks(images)]
     })}
  end

  def handle_call({:steer, token, text, epoch}, _from, %{session_id: sid} = state)
      when is_binary(sid) do
    pending = {:steer, token, epoch}

    state =
      request(
        state,
        "_session/steering",
        %{
          "sessionId" => sid,
          "prompt" => [%{"type" => "text", "text" => text}],
          "_meta" => %{"steering" => %{"idleBehavior" => "promptRequired"}}
        },
        pending
      )

    {:reply, :ok, state}
  end

  def handle_call({:steer, _token, _text, _epoch}, _from, state),
    do: {:reply, {:error, :no_session}, state}

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

  def handle_call({:set_effort, effort}, _from, state) do
    cond do
      is_nil(state.session_id) ->
        {:reply, {:error, :no_session}, state}

      "reasoning_effort" in state.config_option_ids ->
        {:reply, :ok, set_config_option(state, "reasoning_effort", effort)}

      true ->
        {:reply, {:error, :unsupported}, state}
    end
  end

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    outcome =
      if option_id,
        do: %{"outcome" => "selected", "optionId" => option_id},
        else: %{"outcome" => "cancelled"}

    {:reply, :ok, respond(state, rpc_id, %{"outcome" => outcome})}
  end

  # An adapter that reads _meta.systemPrompt needs nothing here. One that
  # drops protocol metadata (dsh) declares 'system-in-prompt, and its
  # sections lead the session's first user message: the head of the prefix
  # the provider caches, so the second turn pays for the new text alone.
  # ACP carries an image as content, not as a path: the bytes go base64 in
  # their own prompt block. A file we cannot read is skipped rather than
  # failing the turn — the message text names the path either way.
  defp image_blocks(images) do
    for %{mime: mime, path: path} <- images,
        {:ok, bytes} <- [File.read(path)] do
      %{"type" => "image", "mimeType" => mime, "data" => Base.encode64(bytes)}
    end
  end

  defp with_system_preamble(%{system_sent: true} = state, text), do: {state, text}

  defp with_system_preamble(state, text) do
    case Map.get(state.config, "system") do
      system when is_binary(system) and system != "" ->
        # the tags are the boundary: without them the model reads our
        # sections and the user's first words as one question
        {%{state | system_sent: true}, "<system>\n" <> system <> "\n</system>\n\n" <> text}

      _ ->
        {%{state | system_sent: true}, text}
    end
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
    {frames, partial} = JsonRpc.decode_lines(state.partial <> data)
    Enum.reduce(frames, %{state | partial: partial}, &handle_frame(&2, &1))
  end

  # --- json-rpc ---------------------------------------------------------------

  defp request(state, method, params, pending_method \\ nil) do
    id = state.next_id
    send_frame(state, JsonRpc.request(id, method, params))

    pending_method = pending_method || method
    %{state | next_id: id + 1, pending_rpc: Map.put(state.pending_rpc, id, pending_method)}
  end

  defp notify(state, method, params), do: send_frame(state, JsonRpc.notification(method, params))
  defp respond(state, id, result), do: send_frame(state, JsonRpc.response(id, result))

  defp respond_error(state, id, code, message),
    do: send_frame(state, JsonRpc.error(id, code, message))

  defp send_frame(state, frame) do
    state.transport.send_frame(state.tp, JsonRpc.encode(frame))
    state
  end

  # Map.get/Map.put, not the struct-update syntax: a backend process
  # started before a hot reload carries a state map without the key
  defp emit(state, kvs) do
    {kvs, started} = Backend.time_tool(kvs, Map.get(state, :tool_started, %{}))
    send(state.owner, {:backend_event, Backend.plist(kvs)})
    Map.put(state, :tool_started, started)
  end

  # responses to our requests
  defp handle_frame(state, %{"id" => id} = frame)
       when not is_map_key(frame, "method") do
    {method, pending} = Map.pop(state.pending_rpc, id)
    state = %{state | pending_rpc: pending}

    case {method, frame} do
      {"initialize", %{"result" => result}} ->
        state =
          if get_in(result, ["_meta", "steering", "supported"]) == true,
            do: emit(state, type: :"steering-ready"),
            else: state

        params = %{
          "cwd" => Map.get(state.config, "cwd", File.cwd!()),
          "mcpServers" =>
            acp_servers(
              Map.get(state.config, "mcp-servers") || Map.get(state.config, "mcp_servers") || [],
              Map.get(state.config, "slug")
            )
        }

        # connector-declared adapter config, forwarded verbatim. This is how
        # compos takes control of the agent's surface — the claude-code
        # connector ships settingSources: [] and strictMcpConfig: true, so
        # the adapter reads no user settings file and no user MCP registry,
        # leaving our mcpServers and our answers the only sources.
        params =
          case Map.get(state.config, "meta") do
            nil -> params
            meta -> Map.put(params, "_meta", meta_json(meta))
          end

        state = Map.put(state, :session_params, params)
        can_load? = get_in(result, ["agentCapabilities", "loadSession"]) == true

        cond do
          is_binary(state.resume) and can_load? ->
            %{state | loading: true}
            |> request("session/load", Map.put(params, "sessionId", state.resume))

          is_binary(state.resume) ->
            # the thread asked for its old session back and this agent cannot
            # give it: say so where the reader will see it, then start fresh
            state
            |> emit(type: :error, text: "the agent cannot resume a session; this is a fresh one")
            |> Map.put(:resume, nil)
            |> request("session/new", params)

          true ->
            request(state, "session/new", params)
        end

      # the old session is back: the same id, the conversation still in the
      # agent. Nothing replayed here reaches the transcript (see :loading).
      {"session/load", %{"result" => result}} ->
        sid = state.resume

        %{state | session_id: sid, loading: false}
        |> emit(type: :session, id: sid, resumed: true)
        |> session_ready(result || %{})

      {"session/load", %{"error" => err}} ->
        state
        |> emit(
          type: :error,
          text:
            "the agent could not resume the session (#{Map.get(err, "message") || Backend.error_text(err)}); this is a fresh one"
        )
        |> Map.merge(%{loading: false, resume: nil})
        |> request("session/new", state.session_params)

      {"session/new", %{"result" => %{"sessionId" => sid} = result}} ->
        %{state | session_id: sid}
        |> emit(type: :session, id: sid, resumed: false)
        |> session_ready(result)

      {"session/set_model", %{"result" => _}} ->
        state

      {"session/set_mode", %{"result" => _}} ->
        state

      # the response carries the COMPLETE option list — setting one option
      # may change another (opencode grows an effort option per model)
      {"session/set_config_option", %{"result" => result}} ->
        ingest_config_options(state, Map.get(result, "configOptions"))

      {"session/prompt", %{"result" => result}} ->
        state
        |> emit_usage(Map.get(result, "usage"))
        |> emit(type: :"turn-end", "stop-reason": Map.get(result, "stopReason", "end_turn"))

      {{:steer, token, epoch}, %{"result" => %{"outcome" => "promptRequired"}}} ->
        emit(state, type: :"steering-fallback", token: token, epoch: epoch)

      {{:steer, token, epoch}, %{"result" => %{"outcome" => outcome}}}
      when outcome in ["injected", "startedNewTurn"] ->
        emit(state, type: :"steering-accepted", token: token, epoch: epoch)

      {{:steer, token, epoch}, %{"error" => _error}} ->
        state
        |> emit(type: :"steering-disabled")
        |> emit(type: :"steering-fallback", token: token, epoch: epoch)

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

  # what a session answers with, new or loaded: the model it runs, the
  # modes and config options it offers, then the thread goes idle
  defp session_ready(state, result) do
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
        state = push_pinned_effort(state)
        state = push_pinned_mode(state)

        emit(state, type: :ready)

  end

  # requests and notifications from the agent
  defp handle_frame(state, %{"method" => method} = frame) do
    id = Map.get(frame, "id")
    params = Map.get(frame, "params", %{})

    case method do
      # a loading session replays its history; the transcript has it already
      "session/update" when state.loading ->
        state

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
      # mcp__compos__ tools — refuse politely so adapters fall back
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
          # claude-code streams tool input: the first tool_call carries an
          # empty rawInput and this refining update carries the real one.
          # Scheme retitles the card from it (agent-tool-refine!).
          name: present_text(Map.get(update, "title")),
          input:
            case Map.fetch(update, "rawInput") do
              {:ok, raw} -> json_text(raw)
              :error -> nil
            end,
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

      # what this conversation now occupies, reported as the turn runs:
      # tokens held and the window they are held in. It is a snapshot, not
      # an increment — Scheme keeps the latest, it does not add them up.
      "usage_update" ->
        state =
          emit(state,
            type: :context,
            used: acp_int(update, "used"),
            size: acp_int(update, "size")
          )

        # The adapter sends this update on every SDK message that moves the
        # token count, and only the one at a cycle's terminal result carries
        # a cost. That makes the cost the one client-visible proof that a
        # cycle produced its result. A steered turn needs it: the adapter
        # moves such a turn's settlement off the result and onto an idle
        # signal it can lose, and then never answers session/prompt. The
        # Agent's settle grace reads this event.
        if Map.has_key?(update, "cost"),
          do: emit(state, type: :"cycle-result"),
          else: state

      "config_option_update" ->
        ingest_config_options(state, Map.get(update, "configOptions"))

      _ ->
        state
    end
  end

  defp handle_update(state, _), do: state

  # PromptResponse.usage is this turn's own tally: the adapter resets it
  # when the turn activates, so a conversation's turns add up without
  # counting a token twice. An adapter that sends none leaves the chat
  # unpriced, exactly as before.
  defp emit_usage(state, usage) when is_map(usage) do
    emit(state,
      type: :usage,
      input: acp_int(usage, "inputTokens"),
      output: acp_int(usage, "outputTokens"),
      "cache-read": acp_int(usage, "cachedReadTokens"),
      "cache-write": acp_int(usage, "cachedWriteTokens")
    )
  end

  defp emit_usage(state, _), do: state

  defp acp_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      n when is_float(n) -> round(n)
      _ -> 0
    end
  end

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

  # --- session config options (ACP extension; opencode, dsh) ------------------
  # The "model" and "mode" options map onto the same model-state/mode-state
  # events the two session/new keys produce, so everything above the seam —
  # modeline, C-c m, permission-mode sync — works unchanged. The
  # "reasoning_effort" option rides on the model entries, which is where the
  # picker reads a model's effort levels from.

  defp ingest_config_options(state, nil), do: state

  defp ingest_config_options(state, options) when is_list(options) do
    state = %{state | config_option_ids: Enum.map(options, & &1["id"])}

    state
    |> ingest_effort_option(Enum.find(options, &(&1["id"] == "reasoning_effort")))
    |> ingest_model_option(Enum.find(options, &(&1["id"] == "model")))
    |> ingest_mode_option(Enum.find(options, &(&1["id"] == "mode")))
  end

  defp ingest_config_options(state, _), do: state

  # An option list nests: an entry that carries its own "options" is a group
  # heading (dsh groups its models by provider), not a value you can select.
  defp option_leaves(list) when is_list(list) do
    Enum.flat_map(list, fn o ->
      case Map.get(o, "options") do
        inner when is_list(inner) -> option_leaves(inner)
        _ -> [o]
      end
    end)
  end

  defp option_leaves(_), do: []

  defp ingest_effort_option(state, %{"currentValue" => cur} = opt) do
    %{
      state
      | config_effort: cur,
        config_efforts: for(o <- option_leaves(Map.get(opt, "options")), do: Map.get(o, "value"))
    }
  end

  defp ingest_effort_option(state, _), do: state

  defp ingest_model_option(state, %{"currentValue" => cur} = opt) do
    leaves = option_leaves(Map.get(opt, "options"))
    wires = for o <- leaves, do: Map.get(o, "value")
    ids = model_ids(wires)
    wire_by_id = Map.new(Enum.zip(ids, wires))
    names = for o <- leaves, do: Map.get(o, "name", "")

    current = Enum.find(ids, fn id -> Map.get(wire_by_id, id) == cur end) || model_id(cur)

    %{state | config_model: current, config_model_wire: wire_by_id}
    |> emit(
      type: :"model-state",
      current: current,
      available:
        for {id, name} <- Enum.zip(ids, names) do
          # the picker reads a model's effort levels from its own entry
          if state.config_efforts == [],
            do: [id, name],
            else: [id, name, state.config_efforts, state.config_effort || ""]
        end
    )
  end

  defp ingest_model_option(state, _), do: state

  defp ingest_mode_option(state, %{"currentValue" => cur} = opt) do
    emit(state,
      type: :"mode-state",
      current: cur,
      available:
        for m <- option_leaves(Map.get(opt, "options")) do
          [Map.get(m, "value"), Map.get(m, "name", ""), Map.get(m, "description", "")]
        end
    )
  end

  defp ingest_mode_option(state, _), do: state

  # A model option value is opaque on the wire. dsh spells it as a JSON
  # ["provider", "model"] pair, which no menu and no modeline can show, so
  # name the model and keep the wire string for the write back. Two
  # providers that serve the same model name keep their whole paths.
  defp model_ids(wires) do
    ids = Enum.map(wires, &model_id/1)
    ambiguous = ids -- Enum.uniq(ids)

    for {wire, id} <- Enum.zip(wires, ids),
        do: if(id in ambiguous, do: model_path(wire), else: id)
  end

  defp model_id(wire) do
    case model_parts(wire) do
      [_ | _] = parts -> List.last(parts)
      _ -> wire
    end
  end

  defp model_path(wire) do
    case model_parts(wire) do
      [_ | _] = parts -> Enum.join(parts, "/")
      _ -> wire
    end
  end

  defp model_parts(wire) when is_binary(wire) do
    case Jason.decode(wire) do
      {:ok, [_ | _] = parts} -> if Enum.all?(parts, &is_binary/1), do: parts, else: nil
      _ -> nil
    end
  end

  defp model_parts(_), do: nil

  defp set_config_option(state, "model", value),
    do: write_config_option(state, "model", Map.get(state.config_model_wire, value, value))

  defp set_config_option(state, id, value), do: write_config_option(state, id, value)

  defp write_config_option(state, id, value) do
    request(state, "session/set_config_option", %{
      "sessionId" => state.session_id,
      "configId" => id,
      "value" => value
    })
  end

  # a pinned model ('model in the resolved config) has no spawn-time route
  # on this lane — the session starts on the agent's default, then we set
  # the option before ready
  # a permission mode chosen while the thread was parked (no adapter) rides
  # in the config; the new session takes it here
  defp push_pinned_mode(%{config: %{"mode" => mode}} = state) when is_binary(mode) do
    if "mode" in state.config_option_ids,
      do: set_config_option(state, "mode", mode),
      else:
        request(state, "session/set_mode", %{"sessionId" => state.session_id, "modeId" => mode})
  end

  defp push_pinned_mode(state), do: state

  defp push_pinned_model(state) do
    model = Map.get(state.config, "model")

    if is_binary(model) and "model" in state.config_option_ids and model != state.config_model,
      do: set_config_option(state, "model", model),
      else: state
  end

  # the same for a pinned reasoning effort
  defp push_pinned_effort(state) do
    effort = Map.get(state.config, "effort")

    if is_binary(effort) and "reasoning_effort" in state.config_option_ids and
         effort != state.config_effort,
       do: set_config_option(state, "reasoning_effort", effort),
       else: state
  end

  # connector 'meta plists -> JSON. Nested plists become objects, so a
  # connector can declare (meta (claudeCode (options (settingSources ())))).
  # Symbols become strings; the empty list is an empty ARRAY, which is what
  # settingSources: [] needs.
  defp meta_json(plist), do: Compos.Core.Plist.to_json(plist)

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
        "command" => absolute_command(m["command"]),
        "args" => m["args"] || [],
        # every stdio server learns which thread spawned it — the compos
        # proxy sends it back as the edit author (buffer-authors)
        "env" => acp_pairs(m["env"]) ++ slug_env(m["env"], slug)
      }
    end
  end

  defp acp_server(other, _slug), do: other

  # A stdio server names its program, and PATH lookup is the adapter's job on
  # most lanes. dsh refuses a relative command, so resolve it here: every
  # adapter accepts the absolute path, and an unresolvable name still travels
  # as written, where the adapter's own error names it.
  defp absolute_command(command) when is_binary(command) do
    if Path.type(command) == :absolute,
      do: command,
      else: System.find_executable(command) || command
  end

  defp absolute_command(command), do: command

  defp slug_env(_pairs, nil), do: []

  defp slug_env(pairs, slug) do
    if Enum.any?(pairs || [], fn [k, _] -> to_string(k) == "COMPOS_AGENT" end),
      do: [],
      else: [%{"name" => "COMPOS_AGENT", "value" => to_string(slug)}]
  end

  defp acp_pairs(pairs) do
    for [k, v] <- pairs || [], do: %{"name" => to_string(k), "value" => to_string(v)}
  end
end
