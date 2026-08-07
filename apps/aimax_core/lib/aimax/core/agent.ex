defmodule Aimax.Core.Agent do
  @moduledoc """
  One agent thread: a GenServer owning backend-agnostic thread machinery —
  status machine (`:starting → :idle → :running → :needs_attention → :dead`),
  prompt queue, ordered event pipeline, output mark, permission bookkeeping.
  Turn execution lives behind `Aimax.Core.Agent.Backend` (ACP subprocess,
  in-process LLM, test stub). Everything visible (transcript rendering,
  keybindings, presets, the *agents* list) is Scheme in
  `priv/packages/agent.scm`.

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
  alias Aimax.Core.Agent.Backend

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

  @doc "Cancel the current turn."
  def cancel(slug), do: call(slug, :cancel)

  @doc "Ask the backend to switch the session's model in place."
  def set_model(slug, model_id), do: call(slug, {:set_model, model_id})

  @doc "Answer a pending permission request by option id (nil = cancel)."
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
      [{pid, _}] ->
        # the agent can die between lookup and call (kill racing a queued
        # render batch) — that must surface as an error, not an exit that
        # takes the CALLER (often the Session) down with it
        try do
          GenServer.call(pid, msg)
        catch
          :exit, _ -> {:error, :no_agent}
        end

      [] ->
        {:error, :no_agent}
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

    # "llm" threads skip the backend entirely: prompts go straight to the
    # in-process LLM with history kept here. (Deleted by W3 — Backend.ReqLLM
    # is the proper version of this.)
    llm? = Map.get(config, "type") == "llm"

    {backend, handle} =
      if llm? do
        {nil, nil}
      else
        backend = Backend.module(config)
        {:ok, handle} = backend.start(config, self())
        {backend, handle}
      end

    state = %{
      slug: slug,
      buffer: buffer,
      config: config,
      llm?: llm?,
      history: [],
      backend: backend,
      handle: handle,
      status: :starting,
      # scheme writes banner + steering marker before starting the runtime and
      # tells us where output goes (just before the marker)
      mark: Map.get(config, "mark", Buffer.byte_size(buffer)),
      events: [],
      in_flight: false,
      prompt_queue: [],
      pending_permission: nil
    }

    if llm? do
      {:ok, set_status(state, :idle)}
    else
      {:ok, state}
    end
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

  def handle_call({:set_model, _model_id}, _from, %{llm?: true} = state),
    do: {:reply, {:error, :unsupported}, state}

  def handle_call({:set_model, model_id}, _from, state),
    do: {:reply, state.backend.set_model(state.handle, model_id), state}

  def handle_call(:cancel, _from, %{llm?: true} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, state) do
    if state.status in [:running, :needs_attention],
      do: state.backend.cancel(state.handle)

    {:reply, :ok, state}
  end

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    case state.pending_permission do
      %{rpc_id: ^rpc_id} ->
        state.backend.respond_permission(state.handle, rpc_id, option_id)

        state =
          state
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
       queued: length(state.prompt_queue),
       permission:
         case state.pending_permission do
           %{rpc_id: id, title: title, options: opts} -> %{rpc_id: id, title: title, options: opts}
           nil -> nil
         end
     }, state}
  end

  # --- backend events ----------------------------------------------------------

  @impl true
  def handle_info({:backend_event, event}, state),
    do: {:noreply, apply_backend_event(state, event)}

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

  def handle_info({:llm_reply, result}, state) do
    state =
      case result do
        {:ok, text} ->
          state
          |> Map.put(:history, state.history ++ [{:assistant, text}])
          |> enqueue(Backend.plist(type: :chunk, text: text))

        {:error, msg} ->
          enqueue(state, Backend.plist(type: :error, text: msg))
      end

    state =
      state
      |> enqueue(Backend.plist(type: :"turn-end", "stop-reason": "end_turn"))
      |> set_status(:idle)
      |> pop_prompt_queue()

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:batch_done, state) do
    state = %{state | in_flight: false}
    {:noreply, maybe_deliver(state)}
  end

  @impl true
  def terminate(_reason, %{llm?: true}), do: :ok

  def terminate(_reason, state) do
    state.backend.close(state.handle)
    :ok
  end

  # the status machine reads the event stream; control events (ready,
  # turn-failed) are consumed here and never reach Scheme
  defp apply_backend_event(state, event) do
    case Backend.event_type(event) do
      "ready" ->
        state |> set_status(:idle) |> pop_prompt_queue()

      "turn-failed" ->
        state |> set_status(:idle) |> pop_prompt_queue()

      "turn-end" ->
        state
        |> enqueue(event)
        |> set_status(:idle)
        |> pop_prompt_queue()

      "permission" ->
        options =
          for [oid, name, kind] <- Backend.plist_get(event, "options") || [] do
            {oid, name, kind}
          end

        pending = %{
          rpc_id: Backend.plist_get(event, "rpc-id"),
          title: Backend.plist_get(event, "title"),
          kind: Backend.plist_get(event, "kind"),
          options: options
        }

        %{state | pending_permission: pending}
        |> set_status(:needs_attention)
        |> enqueue(event)

      "dead" ->
        # deliver what's queued; the thread stays registered so the
        # transcript keeps working (revive reattaches a fresh backend)
        state
        |> Map.put(:status, :dead)
        |> enqueue(event)

      _ ->
        enqueue(state, event)
    end
  end

  # --- lifecycle helpers ------------------------------------------------------

  defp send_prompt(%{llm?: true} = state, text) do
    me = self()
    history = state.history ++ [{:user, text}]

    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
      send(me, {:llm_reply, Aimax.Core.LLM.request(llm_prompt(history))})
    end)

    state
    |> enqueue(Backend.plist(type: :"user-msg", text: text))
    |> Map.put(:history, history)
    |> Map.put(:status, :running)
    |> emit_status(:running)
  end

  defp send_prompt(state, text) do
    state =
      state
      # echo the user turn into the transcript via the ordered event channel —
      # queued messages appear exactly when their turn actually starts
      |> enqueue(Backend.plist(type: :"user-msg", text: text))
      |> Map.put(:status, :running)
      |> emit_status(:running)

    state.backend.prompt(state.handle, text, %{})
    state
  end

  defp llm_prompt(history) do
    turns =
      Enum.map_join(history, "\n\n", fn
        {:user, t} -> "User: #{t}"
        {:assistant, t} -> "Assistant: #{t}"
      end)

    "You are the assistant in an editor chat thread. Reply to the last user " <>
      "turn only, in markdown.\n\n" <> turns
  end

  defp pop_prompt_queue(%{prompt_queue: [next | rest], status: :idle} = state),
    do: send_prompt(%{state | prompt_queue: rest}, next)

  defp pop_prompt_queue(state), do: state

  defp set_status(%{status: s} = state, s), do: state

  defp set_status(state, status),
    do: state |> Map.put(:status, status) |> emit_status(status)

  defp emit_status(state, status),
    do: enqueue(state, Backend.plist(type: :status, status: status))

  # --- event queue -> scheme ---------------------------------------------------

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
