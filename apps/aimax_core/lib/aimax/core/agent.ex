defmodule Aimax.Core.Agent do
  @moduledoc """
  One agent thread: a GenServer owning an ACP (Agent Client Protocol) adapter
  subprocess — JSON-RPC over stdio, newline-framed. Mechanism only: session
  lifecycle, framing, the event queue, the prompt queue, permission plumbing.
  Everything visible (transcript rendering, keybindings, presets, the *agents*
  list) is Scheme in `priv/packages/agent.scm`.

  Events are delivered to Scheme in ordered batches through one global handler
  (`agent-on-event!`), via `Session.apply_callback` from a Task — never
  synchronously from this process, so Session -> Agent calls can't deadlock.
  Adjacent text chunks coalesce per batch; a batch in flight buffers the next.

  The output mark: agent text inserts at `mark`, always before the steering
  prompt marker at buffer end. `append_at_mark/2` is called by Scheme (the
  renderer); the mark chases user edits above it via buffer change events.
  """

  use GenServer, restart: :temporary

  alias Aimax.Core.{Buffer, Events, Session}

  @registry Aimax.Core.AgentRegistry
  @escaped :aimax_escaped_closures

  # --- api --------------------------------------------------------------------

  def start(slug, config) when is_map(config) do
    DynamicSupervisor.start_child(
      Aimax.Core.AgentSupervisor,
      {__MODULE__, slug: slug, config: config}
    )
  end

  def start_link(opts) do
    slug = Keyword.fetch!(opts, :slug)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, slug}})
  end

  def running?(slug), do: Registry.lookup(@registry, slug) != []

  def list do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  @doc "Send or queue a user message. Returns :sent | :queued."
  def prompt(slug, text), do: call(slug, {:prompt, text})

  @doc "Cancel the current turn (ACP session/cancel)."
  def cancel(slug), do: call(slug, :cancel)

  @doc "Answer a pending session/request_permission by option id (nil = cancel)."
  def respond_permission(slug, rpc_id, option_id),
    do: call(slug, {:respond_permission, rpc_id, option_id})

  @doc "Insert rendered output at the output mark. Returns the new mark."
  def append_at_mark(slug, text), do: call(slug, {:append_at_mark, text})

  def mark(slug), do: call(slug, :mark)

  def info(slug), do: call(slug, :info)

  def kill(slug) do
    case Registry.lookup(@registry, slug) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :no_agent}
    end
  end

  defp call(slug, msg) do
    case Registry.lookup(@registry, slug) do
      [{pid, _}] -> GenServer.call(pid, msg)
      [] -> {:error, :no_agent}
    end
  end

  # --- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    slug = Keyword.fetch!(opts, :slug)
    config = Keyword.fetch!(opts, :config)
    buffer = Map.get(config, "buffer", "*agent: #{slug}*")

    Aimax.Core.create_buffer(buffer)
    Events.subscribe(buffer)

    transport = Aimax.Core.Agent.Transport.impl()
    cmd = Map.get(config, "cmd", "claude-code-acp")

    {:ok, tp} =
      transport.open(cmd, [cd: Map.get(config, "cwd"), env: Map.get(config, "env")], self())

    state = %{
      slug: slug,
      buffer: buffer,
      config: config,
      transport: transport,
      tp: tp,
      partial: "",
      next_id: 1,
      pending_rpc: %{},
      session_id: nil,
      status: :starting,
      # scheme writes banner + steering marker before starting the runtime and
      # tells us where output goes (just before the marker)
      mark: Map.get(config, "mark", Buffer.byte_size(buffer)),
      events: [],
      in_flight: false,
      prompt_queue: [],
      pending_permission: nil
    }

    {:ok,
     request(state, "initialize", %{
       "protocolVersion" => 1,
       "clientCapabilities" => %{
         "fs" => %{"readTextFile" => false, "writeTextFile" => false}
       }
     })}
  end

  @impl true
  def handle_call({:prompt, text}, _from, state) do
    case state.status do
      :idle ->
        {:reply, :sent, send_prompt(state, text)}

      s when s in [:starting, :running, :needs_attention] ->
        {:reply, :queued, %{state | prompt_queue: state.prompt_queue ++ [text]}}

      :dead ->
        {:reply, {:error, :dead}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    state =
      if state.status in [:running, :needs_attention] and state.session_id do
        notify(state, "session/cancel", %{"sessionId" => state.session_id})
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    case state.pending_permission do
      %{rpc_id: ^rpc_id} ->
        outcome =
          if option_id,
            do: %{"outcome" => "selected", "optionId" => option_id},
            else: %{"outcome" => "cancelled"}

        state =
          state
          |> respond(rpc_id, %{"outcome" => outcome})
          |> Map.put(:pending_permission, nil)
          |> set_status(:running)

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :no_pending_permission}, state}
    end
  end

  def handle_call({:append_at_mark, text}, _from, state) do
    Buffer.insert_at(state.buffer, state.mark, text, source: {:agent, state.slug})
    mark = state.mark + byte_size(text)
    {:reply, mark, %{state | mark: mark}}
  end

  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       slug: state.slug,
       buffer: state.buffer,
       status: state.status,
       session_id: state.session_id,
       queued: length(state.prompt_queue),
       permission:
         case state.pending_permission do
           %{rpc_id: id, title: title, options: opts} -> %{rpc_id: id, title: title, options: opts}
           nil -> nil
         end
     }, state}
  end

  # --- incoming bytes (real port or fake transport) ---------------------------

  @impl true
  def handle_info({:acp_data, data}, state), do: {:noreply, ingest(state, data)}

  def handle_info({port, {:data, data}}, %{tp: port} = state),
    do: {:noreply, ingest(state, data)}

  def handle_info({:acp_exit, status}, state), do: adapter_exit(state, status)

  def handle_info({port, {:exit_status, status}}, %{tp: port} = state),
    do: adapter_exit(state, status)

  # keep the output mark ahead of user edits above it; our own inserts via
  # append_at_mark already moved it
  def handle_info({:buffer_change, buf, change}, %{buffer: buf} = state) do
    state =
      if change.source == {:agent, state.slug} do
        state
      else
        %{state | mark: adjust_mark(state.mark, change)}
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:batch_done, state) do
    state = %{state | in_flight: false}
    {:noreply, maybe_deliver(state)}
  end

  @impl true
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

  # responses to our requests
  defp handle_frame(state, %{"id" => id} = frame)
       when not is_map_key(frame, "method") do
    {method, pending} = Map.pop(state.pending_rpc, id)
    state = %{state | pending_rpc: pending}

    case {method, frame} do
      {"initialize", %{"result" => _}} ->
        request(state, "session/new", %{
          "cwd" => Map.get(state.config, "cwd", File.cwd!()),
          "mcpServers" => Map.get(state.config, "mcp_servers", [])
        })

      {"session/new", %{"result" => %{"sessionId" => sid}}} ->
        %{state | session_id: sid}
        |> set_status(:idle)
        |> pop_prompt_queue()

      {"session/prompt", %{"result" => result}} ->
        state
        |> enqueue(
          plist(type: :"turn-end", "stop-reason": Map.get(result, "stopReason", "end_turn"))
        )
        |> set_status(:idle)
        |> pop_prompt_queue()

      {_, %{"error" => err}} ->
        enqueue(
          state,
          plist(type: :error, text: "#{method}: #{Map.get(err, "message", inspect(err))}")
        )

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
            {Map.get(opt, "optionId"), Map.get(opt, "name", ""), Map.get(opt, "kind", "")}
          end

        title = get_in(params, ["toolCall", "title"]) || "tool call"
        kind = get_in(params, ["toolCall", "kind"]) || ""

        %{state | pending_permission: %{rpc_id: id, title: title, kind: kind, options: options}}
        |> set_status(:needs_attention)
        |> enqueue(
          plist(
            type: :permission,
            "rpc-id": id,
            title: title,
            kind: kind,
            options: Enum.map(options, fn {oid, name, k} -> [oid, name, k] end)
          )
        )

      # fs proxy lands in Phase 4; refuse politely so adapters fall back
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
        enqueue(state, plist(type: :chunk, text: content_text(Map.get(update, "content"))))

      "agent_thought_chunk" ->
        enqueue(state, plist(type: :thought, text: content_text(Map.get(update, "content"))))

      "tool_call" ->
        enqueue(
          state,
          plist(
            type: :"tool-call",
            id: Map.get(update, "toolCallId", ""),
            title: Map.get(update, "title", ""),
            kind: Map.get(update, "kind", ""),
            status: Map.get(update, "status", "pending")
          )
        )

      "tool_call_update" ->
        enqueue(
          state,
          plist(
            type: :"tool-update",
            id: Map.get(update, "toolCallId", ""),
            status: Map.get(update, "status", ""),
            text: tool_content_text(Map.get(update, "content"))
          )
        )

      "plan" ->
        entries =
          for e <- Map.get(update, "entries") || [] do
            [Map.get(e, "content", ""), Map.get(e, "status", "")]
          end

        enqueue(state, plist(type: :plan, entries: entries))

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

  # --- lifecycle helpers ------------------------------------------------------

  defp send_prompt(state, text) do
    state
    |> Map.put(:status, :running)
    |> emit_status(:running)
    |> request("session/prompt", %{
      "sessionId" => state.session_id,
      "prompt" => [%{"type" => "text", "text" => text}]
    })
  end

  defp pop_prompt_queue(%{prompt_queue: [next | rest], status: :idle} = state),
    do: send_prompt(%{state | prompt_queue: rest}, next)

  defp pop_prompt_queue(state), do: state

  defp set_status(%{status: s} = state, s), do: state

  defp set_status(state, status),
    do: state |> Map.put(:status, status) |> emit_status(status)

  defp emit_status(state, status),
    do: enqueue(state, plist(type: :status, status: status))

  defp adapter_exit(state, status) do
    state =
      state
      |> Map.put(:status, :dead)
      |> enqueue(plist(type: :dead, exit: status))

    # deliver what's queued, then stop once the batch drains
    {:noreply, maybe_deliver(%{state | partial: ""})}
  end

  # --- event queue -> scheme ---------------------------------------------------

  # events are scheme plists: (type chunk text "...") — flat lists, symbol keys
  defp plist(kvs) do
    Enum.flat_map(kvs, fn {k, v} -> [{:sym, to_string(k)}, plist_val(v)] end)
  end

  defp plist_val(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: {:sym, to_string(v)}

  defp plist_val(v), do: v

  defp enqueue(state, event) do
    maybe_deliver(%{state | events: state.events ++ [event]})
  end

  defp maybe_deliver(%{events: []} = state), do: state
  defp maybe_deliver(%{in_flight: true} = state), do: state

  defp maybe_deliver(state) do
    case :ets.lookup(@escaped, {:agent_handler}) do
      [] ->
        # no handler registered (yet) — hold events until one appears
        state

      [{_, handler}] ->
        batch = coalesce(state.events)
        slug = state.slug
        me = self()

        Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
          try do
            Session.apply_callback(handler, [slug, batch])
          after
            GenServer.cast(me, :batch_done)
          end
        end)

        %{state | events: [], in_flight: true}
    end
  end

  # adjacent chunks melt into one append
  defp coalesce([[{:sym, "type"}, {:sym, "chunk"}, {:sym, "text"}, a] | rest]) do
    case coalesce(rest) do
      [[{:sym, "type"}, {:sym, "chunk"}, {:sym, "text"}, b] | tail] ->
        [[{:sym, "type"}, {:sym, "chunk"}, {:sym, "text"}, a <> b] | tail]

      tail ->
        [[{:sym, "type"}, {:sym, "chunk"}, {:sym, "text"}, a] | tail]
    end
  end

  defp coalesce([e | rest]), do: [e | coalesce(rest)]
  defp coalesce([]), do: []

  defp adjust_mark(mark, %{pos: pos, inserted: ins, deleted: del}) do
    cond do
      pos > mark -> mark
      pos + del <= mark -> mark - del + byte_size(ins)
      # deletion spans the mark — clamp to its start
      true -> pos + byte_size(ins)
    end
  end
end
