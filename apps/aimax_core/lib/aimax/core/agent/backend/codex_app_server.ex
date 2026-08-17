defmodule Aimax.Core.Agent.Backend.CodexAppServer do
  @moduledoc """
  Native Codex App Server backend.

  App Server is JSONL over stdio. It deliberately uses the same normalized
  event contract as every other LLM lane; Codex protocol objects stop here,
  while chats, scratch buffers and inline prompts keep sharing LLMSession.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend

  @impl Backend
  def start(config, owner), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl Backend
  def prompt(pid, text, context), do: GenServer.call(pid, {:prompt, text, context})

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
  def set_effort(pid, effort), do: GenServer.call(pid, {:set_effort, effort})

  @impl Backend
  def respond_permission(pid, rpc_id, option_id),
    do: GenServer.call(pid, {:respond_permission, rpc_id, option_id})

  @impl Backend
  def capabilities, do: [:models, :streaming, :reasoning_effort]

  @impl GenServer
  def init({config, owner}) do
    transport = Aimax.Core.Agent.Transport.impl()
    cmd = Map.get(config, "cmd", "codex app-server")

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
      pending_server: %{},
      thread_id: nil,
      turn_id: nil,
      pending_prompt: nil,
      model: string_value(Map.get(config, "model")),
      effort: normalize_effort(Map.get(config, "effort")),
      models: []
    }

    {:ok,
     request(state, "initialize", %{
       "clientInfo" => %{"name" => "aimax", "title" => "Aimax", "version" => "0.1"},
       "capabilities" => %{}
     })}
  end

  @impl GenServer
  def handle_call({:prompt, text, context}, _from, %{thread_id: nil} = state) do
    {method, params} =
      case string_value(Map.get(state.config, "thread-id") || Map.get(state.config, "thread_id")) do
        nil ->
          {"thread/start", thread_start_params(state.config, state.model, context)}

        thread_id ->
          {"thread/resume", thread_resume_params(state.config, state.model, context, thread_id)}
      end

    state =
      state
      |> request(method, params)
      |> Map.put(:pending_prompt, {text, context})

    {:reply, :ok, state}
  end

  def handle_call({:prompt, text, _context}, _from, state) do
    {:reply, :ok, start_turn(state, text)}
  end

  def handle_call(:cancel, _from, %{thread_id: tid, turn_id: turn_id} = state)
      when is_binary(tid) and is_binary(turn_id) do
    {:reply, :ok, request(state, "turn/interrupt", %{"threadId" => tid, "turnId" => turn_id})}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  # Developer instructions contain the exact runtime model identity and are
  # fixed when a Codex thread starts. Let the shared chat switcher reattach
  # and replay the transcript so changing model cannot leave stale identity.
  def handle_call({:set_model, _model_id}, _from, state),
    do: {:reply, {:error, :requires_new_thread}, state}

  def handle_call({:set_effort, effort}, _from, state),
    do: {:reply, :ok, %{state | effort: normalize_effort(effort)}}

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    {request_info, pending} = Map.pop(state.pending_server, rpc_id)
    state = %{state | pending_server: pending}

    state =
      case permission_result(request_info, option_id) do
        {:ok, result} -> respond(state, rpc_id, result)
        :unknown -> respond_error(state, rpc_id, -32601, "unsupported approval request")
      end

    {:reply, :ok, state}
  end

  defp start_turn(state, text) do
    params = %{
      "threadId" => state.thread_id,
      "input" => [%{"type" => "text", "text" => text}]
    }

    params = if state.model, do: Map.put(params, "model", state.model), else: params
    params = if state.effort, do: Map.put(params, "effort", state.effort), else: params
    request(state, "turn/start", params)
  end

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

  defp ingest(state, data) do
    {lines, partial} = split_lines(state.partial <> data)
    state = %{state | partial: partial}

    Enum.reduce(lines, state, fn line, acc ->
      case Jason.decode(line) do
        {:ok, frame} -> handle_frame(acc, frame)
        {:error, _} -> acc
      end
    end)
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {partial, lines} = List.pop_at(parts, -1)
    {Enum.reject(lines, &(String.trim(&1) == "")), partial}
  end

  # App Server uses JSON-RPC semantics but intentionally omits the
  # `jsonrpc: "2.0"` header on the wire.
  defp request(state, method, params) do
    id = state.next_id
    send_frame(state, %{"id" => id, "method" => method, "params" => params})

    %{
      state
      | next_id: id + 1,
        pending_rpc: Map.put(state.pending_rpc, id, method)
    }
  end

  defp notify(state, method, params \\ %{}) do
    send_frame(state, %{"method" => method, "params" => params})
    state
  end

  defp respond(state, id, result) do
    send_frame(state, %{"id" => id, "result" => result})
    state
  end

  defp respond_error(state, id, code, message) do
    send_frame(state, %{"id" => id, "error" => %{"code" => code, "message" => message}})
    state
  end

  defp send_frame(state, frame),
    do: state.transport.send_frame(state.tp, [Jason.encode!(frame), "\n"])

  defp emit(state, kvs) do
    send(state.owner, {:backend_event, Backend.plist(kvs)})
    state
  end

  # Responses to requests initiated here.
  defp handle_frame(state, %{"id" => id} = frame) when not is_map_key(frame, "method") do
    {method, pending} = Map.pop(state.pending_rpc, id)
    state = %{state | pending_rpc: pending}

    case {method, frame} do
      {"initialize", %{"result" => _}} ->
        state
        |> notify("initialized")
        |> request("model/list", %{})
        |> emit(type: :ready)

      {"model/list", %{"result" => %{"data" => models}}} ->
        models = Enum.reject(models, &Map.get(&1, "hidden", false))
        %{state | models: models} |> emit_model_state()

      {method, %{"result" => %{"thread" => %{"id" => tid}} = result}}
      when method in ["thread/start", "thread/resume"] ->
        model = string_value(Map.get(result, "model")) || state.model

        state =
          %{state | thread_id: tid, model: model}
          |> emit(type: :"thread-id", id: tid)
          |> emit_model_state()

        case state.pending_prompt do
          {text, _context} -> state |> Map.put(:pending_prompt, nil) |> start_turn(text)
          nil -> state
        end

      {"turn/start", %{"result" => %{"turn" => %{"id" => turn_id}}}} ->
        %{state | turn_id: turn_id}

      {"turn/start", %{"error" => error}} ->
        state
        |> emit(type: :error, text: error_message("turn/start", error))
        |> emit(type: :"turn-failed")

      {_, %{"error" => error}} ->
        emit(state, type: :error, text: error_message(method, error))

      _ ->
        state
    end
  end

  # Requests initiated by Codex (approvals and, eventually, dynamic tools).
  defp handle_frame(state, %{"id" => id, "method" => method} = frame) do
    params = Map.get(frame, "params", %{})

    if method in [
         "item/commandExecution/requestApproval",
         "item/fileChange/requestApproval",
         "item/permissions/requestApproval"
       ] do
      state = %{state | pending_server: Map.put(state.pending_server, id, {method, params})}
      emit_permission(state, id, method, params)
    else
      respond_error(state, id, -32601, "method not supported: #{method}")
    end
  end

  # Notifications initiated by Codex.
  defp handle_frame(state, %{"method" => method, "params" => params}) do
    case method do
      "turn/started" ->
        %{state | turn_id: get_in(params, ["turn", "id"]) || Map.get(params, "turnId")}

      "turn/completed" ->
        turn = Map.get(params, "turn", %{})
        status = Map.get(turn, "status", "completed")
        state = %{state | turn_id: nil}

        if status == "failed" do
          state
          |> emit(type: :error, text: turn_error(turn))
          |> emit(type: :"turn-failed")
        else
          emit(state, type: :"turn-end", "stop-reason": status)
        end

      "item/agentMessage/delta" ->
        emit(state, type: :chunk, text: Map.get(params, "delta", ""))

      "item/reasoning/summaryTextDelta" ->
        emit(state, type: :thought, text: Map.get(params, "delta", ""))

      "item/started" ->
        item_started(state, Map.get(params, "item", %{}))

      "item/completed" ->
        item_completed(state, Map.get(params, "item", %{}))

      "item/commandExecution/outputDelta" ->
        tool_delta(state, params)

      "item/fileChange/outputDelta" ->
        tool_delta(state, params)

      "item/mcpToolCall/progress" ->
        tool_delta(state, params)

      "turn/plan/updated" ->
        entries =
          for p <- Map.get(params, "plan", []) do
            [Map.get(p, "step", ""), Map.get(p, "status", "pending")]
          end

        emit(state, type: :plan, entries: entries)

      "error" ->
        emit(state, type: :error, text: error_message("codex", params))

      _ ->
        state
    end
  end

  defp handle_frame(state, _frame), do: state

  defp thread_start_params(config, model, context) do
    %{
      "cwd" => Map.get(config, "cwd", File.cwd!()),
      # Chats still own their transcript and use an ephemeral Codex thread.
      # llm-mode opts into a native persisted thread so its ordinary buffer
      # can resume the same conversation after an editor restart.
      "ephemeral" => not truthy?(Map.get(config, "persist-thread"))
    }
    |> put_if("model", model)
    |> put_if("approvalPolicy", approval_policy(Map.get(config, "permission-mode")))
    |> put_if("developerInstructions", developer_instructions(config, model, context))
    |> put_if("config", codex_config(config))
  end

  defp thread_resume_params(config, model, context, thread_id) do
    %{
      "threadId" => thread_id,
      "cwd" => Map.get(config, "cwd", File.cwd!())
    }
    |> put_if("model", model)
    |> put_if("approvalPolicy", approval_policy(Map.get(config, "permission-mode")))
    |> put_if("developerInstructions", developer_instructions(config, model, context))
    |> put_if("config", codex_config(config))
  end

  defp approval_policy(mode) when mode in ["auto", :auto, {:sym, "auto"}], do: "never"
  defp approval_policy(_), do: "on-request"

  # agent.scm assembles the common primer and preset note under the same
  # meta.systemPrompt.append field used by claude-code-acp. Preserve that
  # single instruction source when the transport is native Codex.
  defp developer_instructions(config, model, context) do
    base =
      config
      |> Map.get("meta")
      |> case do
        nil -> nil
        meta -> meta |> Aimax.Core.Plist.to_json() |> get_in(["systemPrompt", "append"])
      end
      |> string_value()

    system = string_value(Map.get(context, :system) || Map.get(context, "system"))

    identity =
      if model do
        "Your exact runtime model ID is #{inspect(model)}. When asked which model you are, " <>
          "report that exact ID; do not replace it with a generic Codex or GPT family name."
      end

    [base, system, identity]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      instructions -> instructions
    end
  end

  # Scheme resolves key references before they reach a backend. Convert its
  # server records to Codex's normal config shape so a preset exposes the
  # same MCP servers on either stateful lane.
  defp codex_config(config) do
    servers = Map.get(config, "mcp-servers") || Map.get(config, "mcp_servers") || []

    mcp_servers =
      servers
      |> Enum.map(&codex_mcp_server/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    if map_size(mcp_servers) == 0, do: nil, else: %{"mcp_servers" => mcp_servers}
  end

  defp codex_mcp_server(flat) when is_list(flat) do
    server = flat |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {to_string(k), v} end)

    case string_value(server["name"]) do
      nil ->
        nil

      name ->
        value =
          if server["url"] do
            %{"url" => string_value(server["url"])}
            |> put_if("http_headers", pair_map(server["headers"]))
          else
            %{
              "command" => string_value(server["command"]),
              "args" => Enum.map(server["args"] || [], &to_string/1)
            }
            |> put_if("env", pair_map(server["env"]))
          end

        {name, value}
    end
  end

  defp codex_mcp_server(_), do: nil

  defp pair_map(nil), do: nil

  defp pair_map(pairs) do
    result = Map.new(pairs, fn [key, value] -> {to_string(key), to_string(value)} end)
    if map_size(result) == 0, do: nil, else: result
  end

  defp truthy?(value), do: value in [true, "true", true, {:sym, "true"}]

  defp emit_model_state(state) do
    available =
      for m <- state.models do
        Aimax.Core.ModelCatalog.picker_entry(m)
      end

    emit(state, type: :"model-state", current: state.model || "", available: available)
  end

  defp item_started(state, %{"type" => type} = item)
       when type in [
              "commandExecution",
              "fileChange",
              "mcpToolCall",
              "dynamicToolCall",
              "webSearch",
              "imageView",
              "collabAgentToolCall"
            ] do
    emit(state,
      type: :"tool-call",
      id: Map.get(item, "id", ""),
      title: item_title(item),
      kind: item_kind(item),
      status: Map.get(item, "status", "pending")
    )
  end

  defp item_started(state, _item), do: state

  defp item_completed(state, %{"type" => type} = item)
       when type in [
              "commandExecution",
              "fileChange",
              "mcpToolCall",
              "dynamicToolCall",
              "webSearch",
              "imageView",
              "collabAgentToolCall"
            ] do
    emit(state,
      type: :"tool-update",
      id: Map.get(item, "id", ""),
      status: completed_status(item),
      text: completed_text(item)
    )
  end

  defp item_completed(state, _item), do: state

  defp tool_delta(state, params) do
    emit(state,
      type: :"tool-update",
      id: Map.get(params, "itemId", ""),
      status: "in_progress",
      text: Map.get(params, "delta", "")
    )
  end

  defp item_title(%{"type" => "commandExecution"} = item), do: Map.get(item, "command", "command")

  defp item_title(%{"type" => "fileChange"} = item) do
    paths = for c <- Map.get(item, "changes", []), do: Map.get(c, "path", "")

    case Enum.reject(paths, &(&1 == "")) do
      [] -> "Edit files"
      names -> "Edit " <> Enum.join(names, ", ")
    end
  end

  defp item_title(%{"type" => "mcpToolCall"} = item),
    do: "#{Map.get(item, "server", "mcp")}/#{Map.get(item, "tool", "tool")}"

  defp item_title(%{"type" => "dynamicToolCall"} = item), do: Map.get(item, "tool", "tool")
  defp item_title(%{"type" => "webSearch"} = item), do: "Search: #{Map.get(item, "query", "")}"
  defp item_title(%{"type" => "imageView"} = item), do: "View #{Map.get(item, "path", "image")}"
  defp item_title(%{"type" => "collabAgentToolCall"} = item), do: Map.get(item, "tool", "agent")
  defp item_title(_), do: "tool"

  defp item_kind(%{"type" => "commandExecution"}), do: "execute"
  defp item_kind(%{"type" => "fileChange"}), do: "edit"
  defp item_kind(%{"type" => "mcpToolCall"}), do: "mcp"
  defp item_kind(%{"type" => "webSearch"}), do: "search"
  defp item_kind(%{"type" => type}), do: type

  defp completed_status(%{"status" => status}) when status in ["failed", "declined", "error"],
    do: "failed"

  defp completed_status(_), do: "completed"

  # Output deltas are authoritative for commands and patches; repeating
  # aggregatedOutput on completion would duplicate their bodies.
  defp completed_text(%{"type" => "mcpToolCall", "error" => error}) when not is_nil(error),
    do: json_text(error)

  defp completed_text(%{"type" => "mcpToolCall", "result" => result}) when not is_nil(result),
    do: json_text(result)

  defp completed_text(%{"type" => "dynamicToolCall", "contentItems" => items}),
    do: json_text(items)

  defp completed_text(_), do: ""

  defp emit_permission(state, id, method, params) do
    {title, kind} =
      case method do
        "item/commandExecution/requestApproval" ->
          {Map.get(params, "command") || Map.get(params, "reason") || "Run command", "execute"}

        "item/fileChange/requestApproval" ->
          {Map.get(params, "reason") || "Edit files", "edit"}

        _ ->
          {Map.get(params, "reason") || "Grant additional permissions", "permissions"}
      end

    emit(state,
      type: :permission,
      "rpc-id": id,
      title: title,
      kind: kind,
      raw: json_text(params),
      options: [
        ["allow_once", "Allow", "allow_once"],
        ["allow_always", "Always", "allow_always"],
        ["reject_once", "Reject", "reject_once"]
      ]
    )
  end

  defp permission_result({method, _params}, option_id)
       when method in [
              "item/commandExecution/requestApproval",
              "item/fileChange/requestApproval"
            ] do
    decision =
      case option_id do
        "allow_once" -> "accept"
        "allow_always" -> "acceptForSession"
        "reject_once" -> "decline"
        _ -> "cancel"
      end

    {:ok, %{"decision" => decision}}
  end

  defp permission_result({"item/permissions/requestApproval", params}, option_id) do
    permissions =
      if option_id in ["allow_once", "allow_always"],
        do: Map.get(params, "permissions", %{}),
        else: %{}

    scope = if option_id == "allow_always", do: "session", else: "turn"
    {:ok, %{"permissions" => permissions, "scope" => scope}}
  end

  defp permission_result(_, _), do: :unknown

  defp turn_error(turn) do
    case Map.get(turn, "error") do
      %{"message" => message} -> message
      nil -> "Codex turn failed"
      error -> json_text(error)
    end
  end

  defp error_message(method, %{"message" => message}), do: "#{method}: #{message}"

  defp error_message(method, %{"error" => %{"message" => message}}),
    do: "#{method}: #{message}"

  defp error_message(method, error), do: "#{method}: #{Backend.error_text(error)}"

  defp json_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> text
      _ -> inspect(value)
    end
  end

  defp string_value(value) when is_binary(value), do: value
  defp string_value({:sym, value}), do: value
  defp string_value(_), do: nil

  defp normalize_effort(value) do
    case string_value(value) do
      effort when effort in [nil, "", "default"] -> nil
      effort -> effort
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp adapter_exit(state, status) do
    emit(state, type: :dead, exit: status)
    {:noreply, %{state | partial: ""}}
  end
end
