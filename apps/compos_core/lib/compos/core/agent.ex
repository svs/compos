defmodule Compos.Core.Agent do
  @moduledoc """
  One agent thread: a GenServer that owns the backend adapter, the timers,
  the context fetch and the ordered event pipe to Scheme. What the thread
  does with each message is Scheme's: `agent-step` in
  `scheme/packages/agent-machine.scm` keeps the status machine
  (`starting -> idle -> running -> needs_attention -> dead`), the prompt
  queue, steering and its settlement, the idle park and the revive, and
  the permission and question slots. This process calls it in place (the
  step is pure, so it needs no lane) and runs the effects it answers.
  Turn execution lives behind `Compos.Core.Agent.Backend`; everything
  visible is Scheme in `scheme/packages/agent.scm`.

  Events reach Scheme in ordered batches through the owning `LLMSession`
  callback (or the default registered by chat), via `Session.apply_callback`
  from a Task, never synchronously from this process, so Session -> Agent
  calls cannot deadlock. A batch in flight buffers the next, and a batch is
  bounded in size as well as in time (`@batch_max_events`), so an eval
  queued on the same lane waits behind one slice, never a whole burst.

  The output mark: agent text inserts at the buffer-local
  'agent-saved-mark, always before the input at buffer end.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Compos.Core.{Buffer, Session}
  alias Compos.Core.Agent.Backend
  alias Compos.Scheme

  @registry Compos.Core.AgentRegistry
  alias Compos.Core.Roots
  @chunk_batch_ms 25
  @batch_max_events 200
  @idle_default_ms 600_000

  # --- api --------------------------------------------------------------------

  def start(slug, config) when is_map(config) do
    DynamicSupervisor.start_child(
      Compos.Core.AgentSupervisor,
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

  @doc """
  Send or queue a user message. Returns :sent | :queued. `display` is what
  the transcript shows and records as the user turn when it differs from the
  wire text (seed prompts carry context the user never typed). `images` are
  attachments the user pasted, `[%{mime: _, path: _}]`; they ride with THIS
  message and no other, so a queued one keeps its own.
  """
  def prompt(slug, text, display \\ nil, images \\ []),
    do: call(slug, {:prompt, text, display, images})

  @doc """
  Drain prompts explicitly promoted into the RUNNING turn. A boundary-steering
  backend calls this before its next model request. Each drained message echoes
  as a `user-msg` event at that moment, so the transcript shows it where the
  model actually reads it. Returns `[{text, display}]`; `[]` when idle or
  nothing was promoted.
  """
  def take_steering(slug), do: call(slug, :take_steering)

  @doc "Promote the oldest queued prompt into the running turn."
  def steer_next(slug), do: call(slug, :steer_next)

  @doc """
  Remove one queued prompt without running it. Matches the first queue
  entry whose display text equals `text`. Returns :ok | {:error, :not_found}.
  """
  def dequeue(slug, text), do: call(slug, {:dequeue, text})

  @doc """
  Move one queued prompt to the front, so it runs next. Matches the first
  queue entry whose display text equals `text`. Returns :ok | {:error, :not_found}.
  """
  def promote(slug, text), do: call(slug, {:promote, text})

  @doc "Cancel the current turn."
  def cancel(slug), do: call(slug, :cancel)

  @doc "Ask the backend to switch the session's model in place."
  def set_model(slug, model_id), do: call(slug, {:set_model, model_id})

  @doc "Set the reasoning effort used by subsequent turns."
  def set_effort(slug, effort), do: call(slug, {:set_effort, effort})

  @doc """
  Switch the session's permission mode. `{:error, :unsupported}` when the
  backend doesn't advertise `:session_modes` — the caller then falls back
  to answering requests itself, which is always available.
  """
  def set_mode(slug, mode_id), do: call(slug, {:set_mode, mode_id})

  @doc """
  Answer a pending permission request by option id (nil = cancel).
  Idempotent: answering one that is already resolved is a no-op, not an
  error — a banner and a deadline racing must never surface as a failure.
  """
  def respond_permission(slug, rpc_id, option_id),
    do: call(slug, {:respond_permission, rpc_id, option_id})

  @doc """
  Ask the user a branching question and block the calling tool until the
  user answers. This channel is independent from tool permissions.

  `answers` is any-length list of labels. The user can also type a free-form
  answer in the chat input.
  """
  def ask_user(slug, question, answers \\ []) when is_binary(question) and is_list(answers),
    do: call(slug, {:ask_user, question, answers}, :infinity)

  @doc "Answer a pending branching question. Stale answers are no-ops."
  def respond_question(slug, question_id, answer),
    do: call(slug, {:respond_question, question_id, answer})

  @doc """
  Ask this thread for a verdict on a tool call, and block until it comes.

  ONE gate. A backend that runs turns itself (the direct lane) calls this
  rather than keeping its own rpc-id counter, pending slot and CAS; a
  backend whose agent asks US (ACP) emits a `permission` event and the
  same slot answers it. Either way the thread owns the id, the CAS, the
  deadline and the deny-on-close, so the two lanes cannot drift apart on
  what an unanswered request means.

  Returns `:allow | :always | :deny`.
  """
  def ask_permission(slug, %{title: _, kind: _, raw: _} = request),
    do: call(slug, {:ask_permission, request}, :infinity)

  @doc """
  Auto-resolve the pending permission as cancelled after `ms` unless it is
  answered first. Scheme arms this for chats no one is looking at, so
  headless work can never hang on a banner nobody will see.
  """
  def permission_deadline(slug, ms), do: call(slug, {:permission_deadline, ms})

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

  defp call(slug, msg, timeout \\ 5000) do
    case Registry.lookup(@registry, slug) do
      [{pid, _}] ->
        # the agent can die between lookup and call (kill racing a queued
        # render batch) — that must surface as an error, not an exit that
        # takes the CALLER (often the Session) down with it
        try do
          GenServer.call(pid, msg, timeout)
        catch
          :exit, _ -> {:error, :no_agent}
        end

      [] ->
        {:error, :no_agent}
    end
  end

  # --- server -----------------------------------------------------------------

  @doc """
  The Scheme lane this agent's callbacks run in. Fixed at agent start
  from the chat buffer's group.
  """
  def lane(slug) do
    Roots.get({:agent_lane, slug}) || {:agent, slug}
  end


  @impl true
  def init(opts) do
    # Backends are linked per session. A subprocess/protocol crash must mark
    # the lane dead, not take this owner down with it: queued render callbacks
    # still call append_at_mark, and the next send can revive a dead lane.
    Process.flag(:trap_exit, true)

    slug = Keyword.fetch!(opts, :slug)
    config = Keyword.fetch!(opts, :config)
    buffer = Map.get(config, "buffer", "*agent: #{slug}*")

    Compos.Core.create_buffer(buffer)
    buffer_ref = Buffer.ref(buffer)

    # the agent's Scheme (renderer, policy and record fns) runs in this
    # lane: serial with itself and its group, concurrent with the UI
    Roots.put({:agent_lane, slug}, Compos.Core.Lane.for_buffer(buffer))

    backend = Backend.module(config)
    {:ok, handle} = backend.start(Map.put(config, "slug", slug), self())
    caps = backend.capabilities()

    steering =
      cond do
        :push_steering in caps -> "push"
        :boundary_steering in caps -> "boundary"
        true -> "none"
      end

    {:ok, m} = scheme("agent-machine-new", [sym(steering), idle_ms(config), :stateless in caps])

    {:ok,
     %{
       slug: slug,
       buffer_ref: buffer_ref,
       config: config,
       backend: backend,
       handle: handle,
       m: m,
       timers: %{},
       waiters: %{},
       events: [],
       in_flight: false,
       delivery_timer: nil
     }}
  end

  defp idle_ms(config) do
    case Map.get(config, "idle-seconds") do
      s when is_integer(s) and s >= 0 -> s * 1000
      _ -> Application.get_env(:compos_core, :agent_idle_ms, @idle_default_ms)
    end
  end

  @impl true
  def handle_call(msg, from, state), do: call_in(msg, from, upgrade(state))

  # parked (no adapter): a choice made now rides in the config the next
  # adapter starts with, so nothing is lost and nothing is woken for it
  defp call_in({:set_model, model_id}, _from, %{handle: nil} = state),
    do: {:reply, :ok, %{state | config: Map.put(state.config, "model", model_id)}}

  defp call_in({:set_effort, effort}, _from, %{handle: nil} = state),
    do: {:reply, :ok, %{state | config: Map.put(state.config, "effort", effort)}}

  defp call_in({:set_mode, mode_id}, _from, %{handle: nil} = state),
    do: {:reply, :ok, %{state | config: Map.put(state.config, "mode", mode_id)}}

  defp call_in({:set_model, model_id}, _from, state),
    do: {:reply, state.backend.set_model(state.handle, model_id), state}

  defp call_in({:set_effort, effort}, _from, state),
    do: {:reply, if_capable(state, :reasoning_effort, &(&1.set_effort(state.handle, effort))), state}

  defp call_in({:set_mode, mode_id}, _from, state),
    do: {:reply, if_capable(state, :session_modes, &(&1.set_mode(state.handle, mode_id))), state}

  defp call_in({:append_at_mark, text}, _from, state) do
    # The buffer-local 'agent-saved-mark is the one truth for where the
    # transcript ends; the buffer computes the position and advances the
    # local inside one message.
    try do
      {:reply,
       Buffer.insert_at_local(state.buffer_ref, "agent-saved-mark", text,
         source: {:agent, state.slug}
       ), state}
    catch
      # a killed target buffer discards a late chunk, never this process
      :exit, _ -> {:reply, {:error, :no_buffer}, state}
    end
  end

  defp call_in(:mark, _from, state) do
    mark =
      try do
        Buffer.get_local(state.buffer_ref, "agent-saved-mark") ||
          Buffer.byte_size(state.buffer_ref)
      catch
        :exit, _ -> 0
      end

    {:reply, mark, state}
  end

  defp call_in(:info, _from, state) do
    {:ok, info} = scheme("agent-machine-info", [state.m])
    info = info |> Enum.chunk_every(2) |> Map.new(fn [{:sym, k}, v] -> {String.to_atom(k), v} end)
    {:reply,
     %{
       info
       | status: elixir(info.status),
         session: nil?(info.session),
         permission: shape(info.permission, [:rpc_id, :title, :options]),
         question: shape(info.question, [:id, :question, :answers])
     }
     |> Map.merge(%{slug: state.slug, buffer: Buffer.name(state.buffer_ref), buffer_id: Buffer.id(state.buffer_ref)}),
     state}
  end

  # the backend's verdict on a push steer decides the reply, so it is
  # asked inside the same call
  defp call_in(:steer_next, _from, state) do
    case step(state, [sym("steer-next")]) do
      {[{:sym, "steer"}, token, text, display, epoch], state} ->
        result =
          case state.backend.steer(state.handle, token, text, nil?(display), epoch) do
            :ok -> sym("ok")
            {:error, why} -> [sym("error"), why]
          end

        {reply, state} = step(state, [sym("steered"), token, result])
        {:reply, elixir(reply), state}

      {reply, state} ->
        {:reply, elixir(reply), state}
    end
  end

  defp call_in(msg, from, state) do
    case step(state, machine_msg(msg)) do
      # a backend that runs its own turns asks US; the verdict comes when
      # the banner, a deadline or a close resolves the slot
      {[{:sym, "defer"}, id], state} -> {:noreply, put_in(state.waiters[id], from)}
      {reply, state} -> {:reply, elixir(reply), state}
    end
  end

  defp machine_msg({:prompt, text, display, images}),
    do: [sym("prompt"), text, display || false, images]

  defp machine_msg(:take_steering), do: [sym("take-steering")]
  defp machine_msg({:dequeue, text}), do: [sym("dequeue"), text]
  defp machine_msg({:promote, text}), do: [sym("promote"), text]
  defp machine_msg(:cancel), do: [sym("cancel")]
  defp machine_msg({:respond_permission, id, option}), do: [sym("respond-permission"), id, option || false]
  defp machine_msg({:permission_deadline, ms}), do: [sym("permission-deadline"), ms]
  defp machine_msg({:respond_question, id, nil}), do: [sym("respond-question"), id, false]
  defp machine_msg({:respond_question, id, answer}), do: [sym("respond-question"), id, to_string(answer)]

  defp machine_msg({:ask_user, question, answers}),
    do: [sym("ask-user"), question, answers |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))]

  defp machine_msg({:ask_permission, req}),
    do: [sym("ask-permission"), sv(req.title), sv(req.kind), sv(req.raw), req[:timeout_ms] || false]

  defp shape(false, _keys), do: nil

  defp shape(values, keys) do
    m = keys |> Enum.zip(values) |> Map.new()
    if is_map_key(m, :options), do: %{m | options: Enum.map(m.options, &List.to_tuple/1)}, else: m
  end

  defp if_capable(state, cap, fun),
    do: if(cap in state.backend.capabilities(), do: fun.(state.backend), else: {:error, :unsupported})

  # --- messages ---------------------------------------------------------------

  @impl true
  def handle_info(msg, state), do: info_in(msg, upgrade(state))

  defp info_in({:backend_event, event}, state),
    do: {:noreply, state |> step([sym("backend-event"), event]) |> elem(1)}

  defp info_in({:EXIT, handle, reason}, %{handle: handle} = state) do
    state =
      if reason in [:normal, :shutdown],
        do: state,
        else: enqueue(state, Backend.plist(type: :error, text: "backend exited: #{Backend.error_text(reason)}"))

    info_in({:backend_event, Backend.plist(type: :dead, exit: Backend.error_text(reason))}, state)
  end

  # the context comes back stamped with the turn it was fetched for; the
  # machine drops one for a turn that was cancelled meanwhile
  defp info_in({:context, epoch, text, display, images, sent_at, {:ok, context}}, state) do
    context = Map.merge(context, %{display: display, images: images, sent_at: sent_at})
    msg = [sym("context"), epoch, sym("ok"), context[:steer_settle_seconds] || false, context[:silent_turn_seconds] || false]
    {_, state} = step(Map.put(state, :turn, {text, context}), msg)
    {:noreply, Map.delete(state, :turn)}
  end

  defp info_in({:context, epoch, _text, _display, _images, _sent_at, {:error, why}}, state),
    do: {:noreply, state |> step([sym("context"), epoch, sym("error"), why]) |> elem(1)}

  defp info_in({:timer, name, token, msg}, state) do
    if Map.get(state.timers, name) == token,
      do: {:noreply, state |> Map.update!(:timers, &Map.delete(&1, name)) |> step(msg) |> elem(1)},
      else: {:noreply, state}
  end

  defp info_in({:step, msg}, state), do: {:noreply, state |> step(msg) |> elem(1)}

  defp info_in({:permission_timeout, id}, state),
    do: info_in({:step, [sym("permission-timeout"), id]}, state)

  defp info_in({:deliver_events, token}, %{delivery_timer: {_timer, token}} = state),
    do: {:noreply, state |> Map.put(:delivery_timer, nil) |> maybe_deliver()}

  defp info_in(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:batch_done, state),
    do: {:noreply, deliver_or_schedule(%{upgrade(state) | in_flight: false})}

  @impl true
  def terminate(_reason, state) do
    # a killed thread must never leave anyone blocked on an answer: not an
    # adapter waiting on the wire, and not a turn task waiting on us
    state = upgrade(state)
    {_, state} = step(state, [sym("terminate")])
    if state.handle, do: state.backend.close(state.handle)
    :ok
  end

  # --- the machine ------------------------------------------------------------

  # One message through agent-step, then its effects, in order. A machine
  # that fails keeps the old state: the thread stays up and says why.
  defp step(state, msg) do
    case scheme("agent-step", [state.m, msg]) do
      {:ok, [m, reply, effects]} ->
        {reply, Enum.reduce(effects, %{state | m: m}, &effect/2)}

      {:error, why} ->
        Logger.error("agent #{state.slug}: agent-step failed on #{inspect(msg, limit: 5)}: #{why}")
        {[sym("error"), :machine], state}
    end
  end

  # The step is pure: it runs here, in this process, over the shared world,
  # and never waits on a lane.
  defp scheme(fun, args) do
    case Scheme.exec(Session.interp(), fn i ->
           with {:ok, f, i} <- Scheme.eval_string(i, fun), do: Scheme.call(i, f, args)
         end) do
      {:ok, val, _} -> {:ok, val}
      {:error, why} -> {:error, why}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # each event goes at once, as it always did: the first of a burst is a
  # batch of its own, and the rest gather while it is in flight
  defp effect([{:sym, "emit"}, event], state), do: enqueue(state, event)

  defp effect([{:sym, "arm"}, {:sym, name}, ms, msg], state) do
    token = make_ref()
    Process.send_after(self(), {:timer, name, token, msg}, ms)
    put_in(state.timers[name], token)
  end

  defp effect([{:sym, "disarm"}, {:sym, name}], state),
    do: %{state | timers: Map.delete(state.timers, name)}

  defp effect([{:sym, "after"}, ms, msg], state) do
    Process.send_after(self(), {:step, msg}, ms)
    state
  end

  defp effect([{:sym, "fetch-context"}, epoch, text, display, images], state) do
    # The context a turn runs against is assembled once, in a task: the
    # fetch calls into the Scheme session, and the session often calls
    # this process (agent-prompt!). It comes back THROUGH this process,
    # stamped with its turn, so a cancel in between drops it.
    me = self()
    slug = state.slug
    sent_at = System.monotonic_time(:millisecond)

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      t0 = System.monotonic_time(:millisecond)
      result = Backend.context(slug, display)

      :telemetry.execute(
        [:compos, :chat, :stage],
        %{duration: System.monotonic_time(:millisecond) - t0, queue: max(t0 - sent_at, 0)},
        %{slug: slug, stage: "context", detail: ""}
      )

      send(me, {:context, epoch, text, display, images, sent_at, result})
    end)

    state
  end

  defp effect([{:sym, "prompt"}], %{turn: {text, context}} = state) do
    state.backend.prompt(state.handle, text, context)
    state
  end

  defp effect([{:sym, "cancel"}], state) do
    if state.handle, do: state.backend.cancel(state.handle)
    state
  end

  # drop the handle first: the EXIT the close raises must not read as a
  # dead backend (that clause matches the current handle only)
  defp effect([{:sym, "park"}], state) do
    state.backend.close(state.handle)
    %{state | handle: nil}
  end

  defp effect([{:sym, "revive"}, resume], state) do
    config = Map.put(state.config, "resume-session", nil?(resume))
    {:ok, handle} = state.backend.start(Map.put(config, "slug", state.slug), self())
    %{state | handle: handle, config: config}
  end

  defp effect([{:sym, "respond-permission"}, id, option], state) do
    state.backend.respond_permission(state.handle, id, nil?(option))
    state
  end

  defp effect([{:sym, "respond-question"}, id, answer], state) do
    if function_exported?(state.backend, :respond_question, 3),
      do: state.backend.respond_question(state.handle, id, nil?(answer))

    state
  end

  defp effect([{:sym, "reply"}, id, value], state) do
    {from, waiters} = Map.pop(state.waiters, id)
    if from, do: GenServer.reply(from, elixir(value))
    %{state | waiters: waiters}
  end

  defp sym(name), do: {:sym, name}

  defp sv(nil), do: false
  defp sv(v) when is_atom(v) and not is_boolean(v), do: {:sym, to_string(v)}
  defp sv(v), do: v

  defp nil?(false), do: nil
  defp nil?(v), do: v

  # a machine answer as the Elixir caller expects it
  defp elixir({:sym, s}), do: String.to_atom(s)
  defp elixir([{:sym, "error"}, why]), do: {:error, elixir(why)}
  defp elixir([{:sym, "ok"}, value]), do: {:ok, value}
  defp elixir(list) when is_list(list), do: Enum.map(list, fn [t, d] -> {t, nil?(d)} end)
  defp elixir(v), do: v

  # --- event queue -> scheme ---------------------------------------------------

  defp enqueue(state, event), do: deliver_or_schedule(%{state | events: state.events ++ [event]})

  defp deliver_or_schedule(%{events: []} = state), do: state
  defp deliver_or_schedule(%{in_flight: true} = state), do: state

  defp deliver_or_schedule(state) do
    if Enum.all?(state.events, &(Backend.event_type(&1) == "chunk")) do
      schedule_delivery(state)
    else
      state |> cancel_delivery() |> maybe_deliver()
    end
  end

  defp schedule_delivery(%{delivery_timer: nil} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:deliver_events, token}, @chunk_batch_ms)
    %{state | delivery_timer: {timer, token}}
  end

  defp schedule_delivery(state), do: state

  defp cancel_delivery(%{delivery_timer: nil} = state), do: state

  defp cancel_delivery(state) do
    {timer, _token} = state.delivery_timer
    Process.cancel_timer(timer)
    %{state | delivery_timer: nil}
  end

  defp maybe_deliver(%{events: []} = state), do: state
  defp maybe_deliver(%{in_flight: true} = state), do: state

  defp maybe_deliver(state) do
    # the escaped table dies with the Session during a restart; an agent
    # draining backend events in that window must not crash over it
    handler =
      Compos.Core.LLMSession.callback(state.slug, :handler) ||
        Roots.get({:agent_handler})

    case handler do
      nil ->
        # no handler registered (yet) — hold events until one appears
        state

      handler ->
        {slice, rest} = Enum.split(state.events, @batch_max_events)
        slug = state.slug
        me = self()

        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          try do
            batch =
              case scheme("agent-coalesce", [slice]) do
                {:ok, batch} -> batch
                {:error, _} -> slice
              end

            # the agent's own lane: rendering serializes with this agent's
            # other Scheme and never queues a keystroke behind it
            Session.apply_callback(handler, [slug, batch], nil, lane(slug))
            notify_turn_end(slug, batch)
          after
            GenServer.cast(me, :batch_done)
          end
        end)

        %{state | events: rest, in_flight: true}
    end
  end

  # The turn-end fan-out, for everybody ELSE (a parent chat waiting on a
  # subagent, a fleet view): after the transcript batch has run, on the
  # :ui lane. It carries the slug and the stop reason; Scheme decides what
  # counts as a normal end.
  defp notify_turn_end(slug, batch) do
    if handler = Roots.get({:agent_turn_end}) do
      for event <- batch, Backend.event_type(event) == "turn-end" do
        stop = Backend.plist_get(event, "stop-reason") || "end_turn"
        Session.apply_callback(handler, [slug, to_string(stop)], nil, :ui)
      end
    end

    :ok
  end

  # --- hot reload ---------------------------------------------------------------
  # A thread started before agent-step existed holds the old state map.
  # Remove after the first daemon restart that follows 2026-11-08.

  defp upgrade(%{m: _} = state), do: state

  defp upgrade(old) do
    entry = fn {t, d, i} -> [t, d || false, i] end
    perm = fn p -> [p.rpc_id, sv(p.title), sv(p.kind), Enum.map(p.options, &Tuple.to_list/1), not is_nil(p[:from])] end
    perms = List.wrap(old.pending_permission) ++ Map.get(old, :waiting_permissions, [])
    q = old.pending_question

    armed =
      for {key, name} <- [steering_settle_timer: "steer-settle", settle_timer: "settle", silent_timer: "silent", idle_timer: "idle"],
          Map.get(old, key),
          do: name

    rows = [
      status: sym(to_string(old.status)), parked: is_nil(old.handle), resume: Map.get(old, :resume) || false,
      queue: Enum.map(old.prompt_queue, entry), "steering-queue": Enum.map(old.steering_queue, entry),
      steers: for({k, {t, d, e, o}} <- old.pending_steers, do: [k, t, d || false, e, sym(to_string(o))]),
      "steer-order": old.pending_steer_order, fallbacks: Enum.map(old.steering_fallbacks, entry),
      "turn-end": old.pending_turn_end || false, steered: Map.get(old, :steered_turn, false),
      "settle-ms": Map.get(old, :settle_grace_ms, 180_000), "silent-ms": Map.get(old, :silent_grace_ms, 180_000),
      "stale-ends": old.stale_turn_ends, "next-steer": old.next_steer_id, steering: sym(to_string(old.steering)),
      permission: (old.pending_permission && perm.(old.pending_permission)) || false,
      waiting: Enum.map(Map.get(old, :waiting_permissions, []), perm),
      question: (q && [q.id, q.question, q.answers, not is_nil(q.from)]) || false,
      epoch: old.epoch, "context-pending": old.context_pending, "next-rpc": old.next_rpc_id,
      "idle-ms": Map.get(old, :idle_ms, 0), stateless: :stateless in old.backend.capabilities(),
      armed: Enum.map(armed, &sym/1), fx: [], reply: sym("ok")
    ]

    waiters = for(p <- perms, p[:from], into: %{}, do: {p.rpc_id, p.from})
    waiters = if q && q.from, do: Map.put(waiters, q.id, q.from), else: waiters

    state =
      old
      |> Map.take([:slug, :buffer_ref, :config, :backend, :handle, :events, :delivery_timer])
      |> Map.merge(%{m: Enum.map(rows, fn {k, v} -> [sym(to_string(k)), v] end), timers: %{}, waiters: waiters, in_flight: false})

    # every timer the old shape held is armed again, from now
    again = %{
      "steer-settle" => {2000, [sym("steer-settle"), old.epoch]},
      "settle" => {Map.get(old, :settle_grace_ms, 180_000), [sym("settle-grace"), old.epoch]},
      "silent" => {Map.get(old, :silent_grace_ms, 180_000), [sym("silent-turn"), old.epoch]},
      "idle" => {Map.get(old, :idle_ms, 0), [sym("idle-park")]}
    }

    Enum.reduce(armed, state, fn name, st ->
      {ms, msg} = again[name]
      effect([sym("arm"), sym(name), ms, msg], st)
    end)
  end
end
