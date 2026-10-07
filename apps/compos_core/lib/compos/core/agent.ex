defmodule Compos.Core.Agent do
  @moduledoc """
  One agent thread: a GenServer owning backend-agnostic thread machinery —
  status machine (`:starting → :idle → :running → :needs_attention → :dead`),
  prompt queue, ordered event pipeline, output mark, permission bookkeeping.
  Turn execution lives behind `Compos.Core.Agent.Backend` (ACP subprocess,
  in-process LLM, test stub). Everything visible (transcript rendering,
  keybindings, presets, the *agents* list) is Scheme in
  `scheme/packages/agent.scm`.

  Events are delivered to Scheme in ordered batches through the owning
  `LLMSession` callback (or the default registered by chat), via
  `Session.apply_callback` from a Task — never synchronously from this process,
  so Session -> Agent calls can't deadlock.
  Adjacent text chunks coalesce in a short frame-sized batch. A batch in flight
  buffers the next, and a batch is bounded in size as well as in time: a
  burst of events applies in slices of `@batch_max_events`, so an eval queued
  on the same lane waits behind one slice, never behind the whole burst.
  This keeps token streaming from monopolizing Scheme input.

  The output mark: agent text inserts at `mark`, always before the steering
  prompt marker at buffer end. `append_at_mark/2` is called by Scheme (the
  renderer); the mark chases user edits above it via buffer change events.
  """

  use GenServer, restart: :temporary

  alias Compos.Core.{Buffer, Session}
  alias Compos.Core.Agent.Backend

  @registry Compos.Core.AgentRegistry
  alias Compos.Core.Roots
  @chunk_batch_ms 25
  @batch_max_events 200

  # How long a steered turn waits, after the cycle result the adapter
  # settles on, for the reply to session/prompt. The healthy reply follows
  # the result within milliseconds, so this only expires when the adapter
  # lost the idle it needed. Scheme overrides it per turn through the turn
  # context (steer-settle-seconds); 0 turns the recovery off.
  @settle_grace_ms 180_000

  # How long a turn waits for the connector to say ANYTHING. A connector
  # that takes the prompt and emits no event at all cannot end its own
  # turn, so the chat waits at "waiting..." for good. The number is high on
  # purpose: the direct lane's first event is the first token, and a slow
  # model must never lose a live turn to this. Scheme overrides it per turn
  # through the turn context (silent-turn-seconds); 0 turns the recovery off.
  @silent_grace_ms 180_000

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
    capabilities = backend.capabilities()

    steering =
      cond do
        :push_steering in capabilities -> :push
        :boundary_steering in capabilities -> :boundary
        true -> :none
      end

    {:ok,
     %{
       slug: slug,
       buffer_ref: buffer_ref,
       config: config,
       backend: backend,
       handle: handle,
       status: :starting,
       events: [],
       in_flight: false,
       delivery_timer: nil,
       context_pending: false,
       prompt_queue: [],
       steering_queue: [],
       pending_steers: %{},
       pending_steer_order: [],
       steering_fallbacks: [],
       pending_turn_end: nil,
       steering_settle_timer: nil,
       # A steer moves an ACP turn's settlement off the model result and
       # onto an idle signal the adapter can lose, so a steered turn can
       # end with no reply to session/prompt. These two fields are the
       # recovery: the turn remembers that it was steered, and the timer
       # runs from the cycle result the adapter settles on.
       steered_turn: false,
       settle_timer: nil,
       settle_grace_ms: @settle_grace_ms,
       # The other silence: a turn that never produced a first event. The
       # timer runs from the moment the prompt goes to the connector and
       # stops at the connector's first word.
       silent_timer: nil,
       silent_grace_ms: @silent_grace_ms,
       # how many terminal backend events belong to turns this side has
       # already ended (see the cancel above): each one is swallowed once
       stale_turn_ends: 0,
       next_steer_id: 1,
       steering: steering,
       pending_permission: nil,
       pending_question: nil,
       # which turn a context fetch belongs to (see send_prompt)
       epoch: 0,
       # ids for the requests WE raise; an adapter's own requests arrive
       # carrying theirs
       next_rpc_id: 1,
       # the backend's session id (the :session event), which an idle park
       # and a daemon restart hand back to the next adapter as
       # "resume-session"; nil until the backend names one
       resume: nil,
       # the idle clock: a thread idle this long closes its adapter
       idle_timer: nil,
       idle_ms: idle_ms(config)
     }}
  end

  @impl true
  def handle_call({:prompt, text, display, images}, _from, state) do
    case state.pending_question do
      %{id: id} ->
        answer = display || text
        {:reply, :answered, resolve_question(state, id, answer)}

      nil ->
        prompt_call(text, display, images, state)
    end
  end

  def handle_call({:set_model, model_id}, _from, state),
    do: {:reply, state.backend.set_model(state.handle, model_id), state}

  def handle_call({:set_effort, effort}, _from, state) do
    if :reasoning_effort in state.backend.capabilities() do
      {:reply, state.backend.set_effort(state.handle, effort), state}
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  def handle_call({:set_mode, mode_id}, _from, state) do
    if :session_modes in state.backend.capabilities() do
      {:reply, state.backend.set_mode(state.handle, mode_id), state}
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  def handle_call(:take_steering, _from, %{steering_queue: [_ | _] = queue, status: s} = state)
      when s in [:running, :needs_attention] do
    state =
      Enum.reduce(queue, state, fn {text, display, _images}, acc ->
        enqueue(acc, Backend.plist(type: :"user-msg", text: display || text))
      end)

    # steering joins a turn already in flight, where only text can land.
    # An attachment's path rides in that text, so nothing is lost silently.
    {:reply, for({t, d, _} <- queue, do: {t, d}), %{state | steering_queue: []}}
  end

  def handle_call(:take_steering, _from, state), do: {:reply, [], state}

  # A turn whose end already arrived takes no steer. The backend is finished
  # with it, so an accepted steer lands a user message in a closed turn: the
  # transcript shows it as sent and nothing ever answers it. The message
  # stays in the queue, and finish_turn's pop_prompt_queue sends it as its
  # own turn.
  def handle_call(:steer_next, _from, %{pending_turn_end: event} = state)
      when not is_nil(event),
      do: {:reply, {:error, :turn_ending}, state}

  def handle_call(:steer_next, _from, state) do
    case {state.status, state.steering, state.prompt_queue} do
      {s, :push, [{text, display, _images} | rest]} when s in [:running, :needs_attention] ->
        token = state.next_steer_id

        case state.backend.steer(state.handle, token, text, display, state.epoch) do
          :ok ->
            pending = Map.put(state.pending_steers, token, {text, display, state.epoch, :pending})

            {:reply, :sent,
             %{
               state
               | prompt_queue: rest,
                 pending_steers: pending,
                 pending_steer_order: state.pending_steer_order ++ [token],
                 next_steer_id: token + 1
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {s, :boundary, [next | rest]} when s in [:running, :needs_attention] ->
        {:reply, :sent,
         %{state | prompt_queue: rest, steering_queue: state.steering_queue ++ [next]}}

      {_status, :none, _queue} ->
        {:reply, {:error, :unsupported}, state}

      {_status, _steering, []} ->
        {:reply, {:error, :empty}, state}

      _ ->
        {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:dequeue, text}, _from, state) do
    case Enum.split_while(state.prompt_queue, fn {t, d, _} -> (d || t) != text end) do
      {_, []} -> {:reply, {:error, :not_found}, state}
      {before, [_ | rest]} -> {:reply, :ok, %{state | prompt_queue: before ++ rest}}
    end
  end

  def handle_call(:cancel, _from, state) do
    # Abort means the whole pending run list. A terminal backend event may
    # still arrive for the active turn, but it must not start queued work.
    # Advancing the epoch also discards a context fetch for a cancelled turn.
    context_pending = state.context_pending
    deferred_turn_end = state.pending_turn_end
    state = cancel_steering_settle_timer(state)

    state = %{
      state
      | prompt_queue: [],
        steering_queue: [],
        pending_steers: %{},
        pending_steer_order: [],
        steering_fallbacks: [],
        pending_turn_end: nil,
        steering_settle_timer: nil,
        epoch: state.epoch + 1,
        context_pending: false
    }

    state =
      if state.pending_question,
        do: resolve_question(state, state.pending_question.id, nil),
        else: state

    state =
      cond do
        deferred_turn_end ->
          finish_turn(state, deferred_turn_end)

        context_pending ->
          state
          |> enqueue(Backend.plist(type: :"turn-end", "stop-reason": "cancelled"))
          |> set_status(:idle)

        state.status in [:running, :needs_attention] ->
          # Tell the backend, then end the turn HERE. A cancel that only
          # asks is a cancel a wedged adapter can ignore -- ACP's
          # session/cancel is a notification with no reply, so a turn whose
          # prompt reply never comes would stay :running for good and the
          # chat would say "streaming" at a model that stopped, with every
          # later message queued behind it. The user said stop: the turn is
          # over on this side now, whatever the wire does later.
          state.backend.cancel(state.handle)

          finish_turn(
            %{state | stale_turn_ends: state.stale_turn_ends + 1},
            Backend.plist(type: :"turn-end", "stop-reason": "cancelled")
          )

        true ->
          state
      end

    {:reply, :ok, state}
  end

  # a backend that runs its own turns asks US. No immediate reply: the
  # verdict comes when the banner, a deadline, or a close resolves the
  # slot — the same slot an adapter's own request would occupy.
  def handle_call({:ask_permission, req}, from, state) do
    id = state.next_rpc_id

    options = [
      ["allow", "Allow", "allow_once"],
      ["always", "Always", "allow_always"],
      ["deny", "Deny", "reject_once"]
    ]

    pending = %{
      rpc_id: id,
      title: req.title,
      kind: req.kind,
      options: for([oid, name, kind] <- options, do: {oid, name, kind}),
      # WE asked: the verdict goes back to this caller, not out to a backend
      from: from
    }

    # a card the editor raised itself may carry its own deadline; nobody
    # answering it in time is a no
    if ms = req[:timeout_ms], do: Process.send_after(self(), {:permission_timeout, id}, ms)

    state =
      %{state | next_rpc_id: id + 1, pending_permission: pending}
      |> set_status(:needs_attention)
      |> enqueue(
        Backend.plist(
          type: :permission,
          "rpc-id": id,
          title: req.title,
          kind: req.kind,
          raw: req.raw,
          options: options,
          # the editor asked because its own policy said ask: the card
          # shows, and no chat policy answers it on the user's behalf
          editor: true
        )
      )

    {:noreply, state}
  end

  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    # CAS on rpc_id: only the request still pending resolves, and a stale
    # answer is a silent no-op
    case state.pending_permission do
      %{rpc_id: ^rpc_id} -> {:reply, :ok, resolve_permission(state, option_id)}
      _ -> {:reply, :ok, state}
    end
  end

  # A question is a tool call, not a permission request. It has its own
  # pending slot and returns the selected label (or typed answer) to the
  # blocked tool task.
  def handle_call({:ask_user, question, answers}, from, state) do
    cond do
      state.pending_question ->
        {:reply, {:error, :question_already_pending}, state}

      true ->
        id = state.next_rpc_id
        answers = answers |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

        pending = %{
          id: id,
          question: question,
          answers: answers,
          from: from
        }

        state =
          %{state | next_rpc_id: id + 1, pending_question: pending}
          |> set_status(:needs_attention)
          |> enqueue(
            Backend.plist(
              type: :question,
              id: id,
              question: question,
              answers: answers
            )
          )

        {:noreply, state}
    end
  end

  def handle_call({:respond_question, question_id, answer}, _from, state) do
    {:reply, :ok, resolve_question(state, question_id, answer)}
  end

  def handle_call({:permission_deadline, ms}, _from, state) do
    case state.pending_permission do
      %{rpc_id: id} ->
        Process.send_after(self(), {:permission_timeout, id}, ms)
        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:append_at_mark, text}, _from, state) do
    # The buffer-local 'agent-saved-mark is the one truth for where the
    # transcript ends. This process held a second copy once, synced over
    # change events; the copies drifted, and every later insert wrote
    # transcript text into the input region. The buffer computes the
    # position and advances the local inside one message.
    try do
      {:reply,
       Buffer.insert_at_local(state.buffer_ref, "agent-saved-mark", text,
         source: {:agent, state.slug}
       ), state}
    catch
      # Rendering is downstream of the backend. Killing the target buffer
      # must discard a late chunk, not kill the session process with :noproc.
      :exit, _ -> {:reply, {:error, :no_buffer}, state}
    end
  end

  def handle_call(:mark, _from, state) do
    mark =
      try do
        Buffer.get_local(state.buffer_ref, "agent-saved-mark") ||
          Buffer.byte_size(state.buffer_ref)
      catch
        :exit, _ -> 0
      end

    {:reply, mark, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       slug: state.slug,
       buffer: Buffer.name(state.buffer_ref),
       buffer_id: Buffer.id(state.buffer_ref),
       status: state.status,
       queued:
         length(state.prompt_queue) + length(state.steering_queue) +
           map_size(state.pending_steers) + length(state.steering_fallbacks),
       steering: state.steering != :none,
       # the turn the backend already ended, still held open behind an
       # unresolved steer. Every stall in this area lived in this field and
       # nothing reported it.
       ending: not is_nil(state.pending_turn_end),
       # a steered turn whose result landed, counting down to the recovery
       settling: not is_nil(Map.get(state, :settle_timer)),
       # a turn the connector has not answered with one event yet
       silent: not is_nil(Map.get(state, :silent_timer)),
       steers: length(state.pending_steer_order),
       permission:
         case state.pending_permission do
           %{rpc_id: id, title: title, options: opts} ->
             %{rpc_id: id, title: title, options: opts}

           nil ->
             nil
         end,
       question:
         case state.pending_question do
           %{id: id, question: question, answers: answers} ->
             %{id: id, question: question, answers: answers}

           nil ->
             nil
         end
     }, state}
  end

  # parked: the adapter was closed while the thread sat idle. Open a new
  # one on the old session; the prompt waits in the queue until `ready`.
  defp prompt_call(text, display, images, %{handle: nil, status: :idle} = state),
    do: {:reply, :queued, state |> revive_backend() |> queue_prompt(text, display, images)}

  defp prompt_call(text, display, images, state) do
    case state.status do
      :idle ->
        {:reply, :sent, send_prompt(state, text, display, images)}

      s when s in [:starting, :running, :needs_attention] ->
        {:reply, :queued, queue_prompt(state, text, display, images)}

      :dead ->
        {:reply, {:error, :dead}, state}
    end
  end

  # --- backend events ----------------------------------------------------------

  @impl true
  def handle_info({:backend_event, event}, state) do
    {:noreply, apply_backend_event(state, event)}
  end

  def handle_info({:EXIT, handle, reason}, %{handle: handle} = state) do
    state =
      state
      |> then(fn s ->
        if reason in [:normal, :shutdown],
          do: s,
          else:
            enqueue(
              s,
              Backend.plist(type: :error, text: "backend exited: #{Backend.error_text(reason)}")
            )
      end)
      |> apply_backend_event(Backend.plist(type: :dead, exit: Backend.error_text(reason)))

    {:noreply, state}
  end

  # the context for a turn that is still the current one
  def handle_info({:context, epoch, text, display, images, sent_at, result}, %{epoch: epoch} = state) do
    state = %{state | context_pending: false}

    case result do
      {:ok, context} ->
        context = context |> Map.put(:display, display) |> Map.put(:images, images)
        state.backend.prompt(state.handle, text, Map.put(context, :sent_at, sent_at))

        state =
          state
          |> settle_grace_from(context)
          |> silent_grace_from(context)
          |> arm_silent()

        {:noreply, state}

      {:error, why} ->
        state =
          state
          |> enqueue(Backend.plist(type: :error, text: why))
          |> set_status(:idle)
          |> pop_prompt_queue()

        {:noreply, state}
    end
  end

  # ...and for one that was cancelled while we were fetching it
  def handle_info({:context, _epoch, _text, _display, _images, _result}, state),
    do: {:noreply, state}

  # nobody is looking at this chat and nobody answered — deny and say so,
  # rather than leaving the turn wedged forever
  def handle_info({:permission_timeout, id}, state) do
    case state.pending_permission do
      %{rpc_id: ^id, title: title} ->
        state =
          state
          |> enqueue(Backend.plist(type: :"permission-timeout", title: title))
          |> resolve_permission(nil)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:deliver_events, token}, %{delivery_timer: {_timer, token}} = state) do
    {:noreply, state |> Map.put(:delivery_timer, nil) |> maybe_deliver()}
  end

  def handle_info({:deliver_events, _stale}, state), do: {:noreply, state}

  def handle_info(
        {:steering_settle_timeout, epoch},
        %{epoch: epoch, pending_turn_end: event} = state
      )
      when not is_nil(event) do
    # The turn is confirmed complete, so an unacknowledged steer can no
    # longer be trusted as delivered. Put every unresolved entry back in
    # submission order and let the ordinary queue make progress. Supported
    # push backends acknowledge consumed steering before terminal completion;
    # this timeout is recovery for a lost or malformed protocol response.
    pending =
      Map.new(state.pending_steers, fn
        {token, {text, display, steer_epoch, :pending}} ->
          {token, {text, display, steer_epoch, :fallback}}

        entry ->
          entry
      end)

    state =
      %{state | pending_steers: pending, steering_settle_timer: nil}
      |> drain_settled_steering()
      |> maybe_finish_deferred_turn()

    {:noreply, state}
  end

  # a stale-epoch timeout still spent its timer: clear the ref, or the
  # dead reference blocks re-arming and parks every later turn-end
  def handle_info({:steering_settle_timeout, _stale_epoch}, state),
    do: {:noreply, %{state | steering_settle_timer: nil}}

  # The steered turn produced its result and then said nothing, and the
  # adapter never answered session/prompt. The turn is over: the adapter
  # settles such a turn on an idle signal, and it lost that idle. End the
  # turn HERE, tell the adapter so it drops the turn it still holds, and
  # swallow the reply if one arrives after all.
  def handle_info({:settle_grace, epoch}, %{epoch: epoch, status: :running} = state) do
    grace = Map.get(state, :settle_grace_ms, @settle_grace_ms)
    state = Map.put(state, :settle_timer, nil)
    state.backend.cancel(state.handle)

    state =
      state
      |> enqueue(Backend.plist(type: :"turn-settled", seconds: div(grace, 1000)))
      |> Map.put(:stale_turn_ends, state.stale_turn_ends + 1)
      |> finish_turn(Backend.plist(type: :"turn-end", "stop-reason": "end_turn"))

    {:noreply, state}
  end

  def handle_info({:settle_grace, _stale}, state),
    do: {:noreply, Map.put(state, :settle_timer, nil)}

  # The connector took the prompt and said nothing at all: no chunk, no
  # tool, no result, no end. Such a turn never closes itself, so the chat
  # waits for good. End it HERE and tell the adapter to drop the turn it
  # still holds. Scheme decides what happens to the session next.
  def handle_info({:silent_turn, epoch}, %{epoch: epoch, status: :running} = state) do
    grace = Map.get(state, :silent_grace_ms, @silent_grace_ms)
    state = Map.put(state, :silent_timer, nil)
    state.backend.cancel(state.handle)

    state =
      state
      |> enqueue(Backend.plist(type: :"turn-silent", seconds: div(grace, 1000)))
      |> Map.put(:stale_turn_ends, state.stale_turn_ends + 1)
      |> finish_turn(Backend.plist(type: :"turn-end", "stop-reason": "error"))

    {:noreply, state}
  end

  def handle_info({:idle_park, ref}, %{idle_timer: ref} = state) do
    state = %{state | idle_timer: nil}
    if parkable?(state), do: {:noreply, park(state)}, else: {:noreply, state}
  end

  def handle_info({:idle_park, _stale}, state), do: {:noreply, state}

  def handle_info({:silent_turn, _stale}, state),
    do: {:noreply, Map.put(state, :silent_timer, nil)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:batch_done, state) do
    state = %{state | in_flight: false}
    {:noreply, deliver_or_schedule(state)}
  end

  @impl true
  def terminate(_reason, state) do
    # a killed thread must never leave anyone blocked on an answer: not an
    # adapter waiting on the wire, and not a turn task waiting on us
    if state.pending_permission, do: resolve_permission(state, nil)
    if state.pending_question, do: resolve_question(state, state.pending_question.id, nil)

    state.backend.close(state.handle)
    :ok
  end

  # One place resolves a pending request, whichever side raised it: reply
  # to the turn task that is blocked on us, or answer the adapter that
  # asked. Then clear the slot and go back to running.
  defp resolve_permission(state, option_id) do
    case state.pending_permission do
      %{from: from} = pending when not is_nil(from) ->
        GenServer.reply(from, verdict_of(pending, option_id))

      pending ->
        state.backend.respond_permission(state.handle, pending.rpc_id, option_id)
    end

    state
    |> Map.put(:pending_permission, nil)
    |> attention_resolved_status()
  end

  defp resolve_question(%{pending_question: %{id: id} = pending} = state, id, answer) do
    answer = if is_nil(answer), do: nil, else: to_string(answer)

    case pending.from do
      nil ->
        if function_exported?(state.backend, :respond_question, 3) do
          state.backend.respond_question(state.handle, id, answer)
        end

      from ->
        GenServer.reply(from, if(answer, do: {:ok, answer}, else: {:error, :cancelled}))
    end

    state
    |> Map.put(:pending_question, nil)
    |> enqueue(
      Backend.plist(
        type: :"question-answer",
        id: id,
        answer: answer || "cancelled"
      )
    )
    |> attention_resolved_status()
  end

  defp resolve_question(state, _id, _answer), do: state

  defp attention_resolved_status(state) do
    if state.pending_permission || state.pending_question,
      do: set_status(state, :needs_attention),
      else: set_status(state, :running)
  end

  # The option's KIND is the vocabulary, not its id: an adapter names its
  # own ids and ours are only ours, but every ACP option declares a kind.
  # No option (a cancel, a close, a deadline) is a denial.
  defp verdict_of(_pending, nil), do: :deny

  defp verdict_of(%{options: options}, option_id) do
    case List.keyfind(options, option_id, 0) do
      {_, _, "allow_always"} -> :always
      {_, _, "allow_once"} -> :allow
      {_, _, kind} -> if String.starts_with?(to_string(kind), "allow"), do: :allow, else: :deny
      nil -> :deny
    end
  end

  # The status machine reads the event stream. A failed backend turn still
  # becomes a normal terminal event for Scheme. Without that event, the Agent
  # goes idle while the chat keeps its active flag and waiting presentation.
  # Bookkeeping events say nothing about whether the turn still produces.
  # Every other event does: it is output, so the adapter has not reached the
  # result a steered turn settles on, and the settle grace disarms.
  @settle_quiet_events ~w(context usage model-state mode-state status cycle-result
                          steering-ready steering-disabled steering-accepted
                          steering-fallback)

  defp apply_backend_event(state, event) do
    type = Backend.event_type(event)

    state =
      if is_nil(Map.get(state, :settle_timer)) or type in @settle_quiet_events,
        do: state,
        else: cancel_settle_timer(state)

    # Every event counts here, bookkeeping included: the silence watchdog
    # asks only whether the connector speaks at all.
    state = cancel_silent_timer(state)

    apply_event(state, event)
  end

  defp apply_event(state, event) do
    case Backend.event_type(event) do
      # the terminal event of a turn this side already ended -- a backend
      # that answered our cancel after we stopped waiting for it. Ending
      # again would run every turn-end listener twice, and could close a
      # turn that is not the one it belongs to.
      t when t in ["turn-end", "turn-failed"] and state.stale_turn_ends > 0 ->
        %{state | stale_turn_ends: state.stale_turn_ends - 1}

      # The cycle produced its terminal result. On a steered turn the adapter
      # holds the reply to session/prompt until an idle signal that may never
      # come, so start counting from here.
      "cycle-result" ->
        arm_settle(state)

      "steering-ready" ->
        %{state | steering: :push}

      "steering-disabled" ->
        %{state | steering: :none}

      "steering-accepted" ->
        steering_accepted(state, event)

      "steering-fallback" ->
        steering_fallback(state, event)

      "ready" ->
        state |> set_status(:idle) |> pop_prompt_queue()

      "turn-failed" ->
        apply_event(
          state,
          Backend.plist(type: :"turn-end", "stop-reason": "error")
        )

      "turn-end" ->
        # A transport may report completion before its steering RPC reply.
        # Keep the turn open until every committed steer is accepted or put
        # back; otherwise a younger queued prompt can overtake or erase it.
        if state.pending_steer_order == [] do
          finish_turn(state, event)
        else
          # always a FRESH timer, stamped with the current epoch: a ref left
          # over from a fired-and-ignored timeout would otherwise satisfy the
          # arming check forever, and every later turn-end would park with
          # no recovery
          state = cancel_steering_settle_timer(state)
          timer = Process.send_after(self(), {:steering_settle_timeout, state.epoch}, 2_000)
          %{state | pending_turn_end: event, steering_settle_timer: timer}
        end

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

      "question" ->
        pending = %{
          id: Backend.plist_get(event, "id"),
          question: Backend.plist_get(event, "question"),
          answers: Backend.plist_get(event, "answers") || [],
          from: nil
        }

        %{state | pending_question: pending}
        |> set_status(:needs_attention)
        |> enqueue(event)

      # the backend named its session: kept for the next adapter (an idle
      # park, a revive) and forwarded, so the chat can keep it across a
      # daemon restart
      "session" ->
        state
        |> Map.put(:resume, Backend.plist_get(event, "id"))
        |> enqueue(event)

      "dead" ->
        # deliver what's queued; the thread stays registered so the
        # transcript keeps working (revive reattaches a fresh backend)
        state
        |> cancel_idle_timer()
        |> Map.put(:status, :dead)
        |> enqueue(event)

      _ ->
        enqueue(state, event)
    end
  end

  # --- lifecycle helpers ------------------------------------------------------

  defp queue_prompt(state, text, display, images),
    do: %{state | prompt_queue: state.prompt_queue ++ [{text, display, images}]}

  # The adapter injected the text into the running turn, which moves that
  # turn's settlement off its result (see arm_settle).
  defp steering_accepted(state, event) do
    settle_steering(Map.put(state, :steered_turn, true), event, :accepted)
  end

  defp steering_fallback(state, event) do
    settle_steering(state, event, :fallback)
  end

  defp settle_steering(state, event, outcome) do
    token = Backend.plist_get(event, "token")
    epoch = Backend.plist_get(event, "epoch")

    state =
      case Map.fetch(state.pending_steers, token) do
        {:ok, {text, display, ^epoch, :pending}} when epoch == state.epoch ->
          %{
            state
            | pending_steers:
                Map.put(state.pending_steers, token, {text, display, epoch, outcome})
          }

        _ ->
          state
      end

    state
    |> drain_settled_steering()
    |> maybe_finish_deferred_turn()
  end

  defp drain_settled_steering(%{pending_steer_order: []} = state), do: state

  defp drain_settled_steering(%{pending_steer_order: [token | rest]} = state) do
    case Map.get(state.pending_steers, token) do
      {_text, _display, _epoch, :pending} ->
        state

      {text, display, _epoch, :accepted} ->
        %{
          state
          | pending_steers: Map.delete(state.pending_steers, token),
            pending_steer_order: rest
        }
        |> enqueue(Backend.plist(type: :"user-msg", text: display || text))
        |> drain_settled_steering()

      {text, display, _epoch, :fallback} ->
        %{
          state
          | pending_steers: Map.delete(state.pending_steers, token),
            pending_steer_order: rest,
            steering_fallbacks: state.steering_fallbacks ++ [{text, display, []}]
        }
        |> drain_settled_steering()

      nil ->
        drain_settled_steering(%{state | pending_steer_order: rest})
    end
  end

  defp maybe_finish_deferred_turn(%{pending_steer_order: [], pending_turn_end: event} = state)
       when not is_nil(event),
       do: finish_turn(%{state | pending_turn_end: nil}, event)

  defp maybe_finish_deferred_turn(state), do: state

  defp finish_turn(state, event) do
    # a turn that ends with a request still open (the agent gave up,
    # the wire died) resolves it cancelled — never a stuck banner
    state
    |> cancel_settle_timer()
    |> cancel_silent_timer()
    |> Map.put(:steered_turn, false)
    |> cancel_steering_settle_timer()
    |> restore_boundary_steering()
    |> restore_push_fallbacks()
    |> then(fn s -> if s.pending_permission, do: resolve_permission(s, nil), else: s end)
    |> then(fn s ->
      if s.pending_question, do: resolve_question(s, s.pending_question.id, nil), else: s
    end)
    |> enqueue(event)
    |> set_status(:idle)
    |> pop_prompt_queue()
  end

  # A steered turn only. An ordinary ACP turn answers session/prompt at its
  # result, so it needs no net, and arming one there would put a deadline on
  # a healthy turn.
  defp arm_settle(%{steered_turn: true, status: :running} = state) do
    grace = Map.get(state, :settle_grace_ms, @settle_grace_ms)

    if is_integer(grace) and grace > 0 do
      state = cancel_settle_timer(state)

      Map.put(
        state,
        :settle_timer,
        Process.send_after(self(), {:settle_grace, state.epoch}, grace)
      )
    else
      state
    end
  end

  defp arm_settle(state), do: state

  # Every turn, every connector: the prompt is on the wire and the first
  # event has not come back yet.
  defp arm_silent(%{status: :running} = state) do
    grace = Map.get(state, :silent_grace_ms, @silent_grace_ms)

    if is_integer(grace) and grace > 0 do
      state = cancel_silent_timer(state)

      Map.put(
        state,
        :silent_timer,
        Process.send_after(self(), {:silent_turn, state.epoch}, grace)
      )
    else
      state
    end
  end

  defp arm_silent(state), do: state

  # Scheme says how long the recovery waits, per turn, the way it says the
  # empty-reply nudge. A turn that names no number keeps the default.
  defp settle_grace_from(state, context) do
    case Map.get(context, :steer_settle_seconds) do
      n when is_integer(n) and n >= 0 -> Map.put(state, :settle_grace_ms, n * 1000)
      _ -> state
    end
  end

  defp silent_grace_from(state, context) do
    case Map.get(context, :silent_turn_seconds) do
      n when is_integer(n) and n >= 0 -> Map.put(state, :silent_grace_ms, n * 1000)
      _ -> state
    end
  end

  # Map.get/Map.put, not the struct-update syntax: an Agent started before a
  # hot reload carries a state map without these keys
  defp cancel_settle_timer(state) do
    case Map.get(state, :settle_timer) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, :settle_timer, nil)
    end
  end

  defp cancel_silent_timer(state) do
    case Map.get(state, :silent_timer) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, :silent_timer, nil)
    end
  end

  defp cancel_steering_settle_timer(%{steering_settle_timer: nil} = state), do: state

  defp cancel_steering_settle_timer(state) do
    Process.cancel_timer(state.steering_settle_timer)
    %{state | steering_settle_timer: nil}
  end

  defp restore_boundary_steering(%{steering_queue: []} = state), do: state

  defp restore_boundary_steering(state) do
    %{
      state
      | prompt_queue: state.steering_queue ++ state.prompt_queue,
        steering_queue: []
    }
  end

  defp restore_push_fallbacks(%{steering_fallbacks: []} = state), do: state

  defp restore_push_fallbacks(state) do
    %{
      state
      | prompt_queue: state.steering_fallbacks ++ state.prompt_queue,
        steering_fallbacks: []
    }
  end

  defp send_prompt(state, text, display, images) do
    state =
      state
      # echo the user turn into the transcript via the ordered event channel —
      # queued messages appear exactly when their turn actually starts. The
      # event carries the DISPLAY text: what the user typed, not the seed
      # context wrapped around it on the wire.
      |> enqueue(Backend.plist(type: :"user-msg", text: display || text))
      # a backend that never answered the last cancel never will: drop the
      # debt here, or the swallow would eat THIS turn's end instead
      |> Map.put(:stale_turn_ends, 0)
      |> cancel_settle_timer()
      |> cancel_silent_timer()
      |> Map.put(:steered_turn, false)
      |> Map.put(:status, :running)
      |> emit_status(:running)

    # The context a turn runs against is assembled HERE, once, and handed
    # to the backend — a backend no longer reaches into a global to find
    # out what conversation it is in.
    #
    # It is assembled in a task, and it must be: the fetch calls into the
    # Scheme session, and this GenServer is often called FROM the session
    # (agent-prompt!). Fetching it inline would have the session waiting on
    # us while we wait on the session. It happens at turn start rather than
    # at send time so a queued message gets a fresh system prompt.
    # The context comes back THROUGH this process, stamped with the turn
    # it was fetched for. A cancel while the fetch is in flight ends that
    # turn and pops the next one; without the stamp the late context would
    # then start a turn for a message the user already took back.
    me = self()
    slug = state.slug
    epoch = state.epoch + 1
    display = display || text

    sent_at = System.monotonic_time(:millisecond)

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      t0 = System.monotonic_time(:millisecond)
      result = Backend.context(slug, display)
      ms = System.monotonic_time(:millisecond) - t0

      :telemetry.execute(
        [:compos, :chat, :stage],
        %{duration: ms, queue: max(t0 - sent_at, 0)},
        %{slug: slug, stage: "context", detail: ""}
      )

      send(me, {:context, epoch, text, display, images, sent_at, result})
    end)

    %{state | epoch: epoch, context_pending: true}
  end

  defp pop_prompt_queue(%{prompt_queue: [{next, display, images} | rest], status: :idle} = state),
    do: send_prompt(%{state | prompt_queue: rest}, next, display, images)

  defp pop_prompt_queue(state), do: state

  defp set_status(%{status: s} = state, s), do: state

  defp set_status(state, status),
    do: state |> Map.put(:status, status) |> emit_status(status) |> idle_clock(status)

  # --- idle park ----------------------------------------------------------------
  #
  # An idle adapter is two OS processes and up to a few hundred MB for a
  # conversation nobody is having. A thread idle for `idle_ms` closes its
  # adapter and keeps the session id; the next prompt opens a new adapter
  # on the same session (ACP session/load), so the agent keeps its memory.
  # A thread with no session to come back to is never parked: no :session
  # event yet, or a stateless lane that has no process to close.

  @idle_default_ms 600_000

  defp idle_ms(config) do
    case Map.get(config, "idle-seconds") do
      s when is_integer(s) and s >= 0 -> s * 1000
      _ -> Application.get_env(:compos_core, :agent_idle_ms, @idle_default_ms)
    end
  end

  defp idle_clock(state, :idle), do: arm_idle_timer(state)
  defp idle_clock(state, _status), do: cancel_idle_timer(state)

  defp arm_idle_timer(state) do
    state = cancel_idle_timer(state)
    ms = Map.get(state, :idle_ms, 0)

    if is_integer(ms) and ms > 0 and parkable?(state) do
      ref = make_ref()
      Process.send_after(self(), {:idle_park, ref}, ms)
      Map.put(state, :idle_timer, ref)
    else
      state
    end
  end

  defp cancel_idle_timer(state), do: Map.put(state, :idle_timer, nil)

  defp parkable?(state) do
    state.status == :idle and is_binary(Map.get(state, :resume)) and not is_nil(state.handle) and
      state.prompt_queue == [] and state.steering_queue == [] and
      is_nil(state.pending_permission) and is_nil(state.pending_question) and
      not state.context_pending and :stateless not in state.backend.capabilities()
  end

  defp park(state) do
    handle = state.handle
    # drop the handle first: the EXIT the close raises must not read as a
    # dead backend (that clause matches the current handle only)
    state = %{state | handle: nil}
    state.backend.close(handle)
    state
  end

  defp revive_backend(%{handle: nil} = state) do
    config = Map.put(state.config, "resume-session", Map.get(state, :resume))
    {:ok, handle} = state.backend.start(Map.put(config, "slug", state.slug), self())
    %{state | handle: handle, config: config} |> set_status(:starting)
  end

  defp revive_backend(state), do: state

  defp emit_status(state, status),
    do: enqueue(state, Backend.plist(type: :status, status: status))

  # --- event queue -> scheme ---------------------------------------------------

  defp enqueue(state, event) do
    state
    |> Map.update!(:events, &(&1 ++ [event]))
    |> deliver_or_schedule()
  end

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
    # draining backend events in that window must not crash over it — a
    # crashed agent leaves its session record orphaned
    handler =
      Compos.Core.LLMSession.callback(state.slug, :handler) ||
        Roots.get({:agent_handler})

    case handler do
      nil ->
        # no handler registered (yet) — hold events until one appears
        state

      handler ->
        {slice, rest} = Enum.split(state.events, @batch_max_events)
        batch = coalesce(slice)
        slug = state.slug
        me = self()

        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          try do
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

  # The turn-end fan-out. The batch above belongs to the transcript: it
  # renders on this agent's own lane and lands the assistant's turn in the
  # record. This second dispatch is for everybody ELSE — a parent chat
  # waiting on a subagent, a fleet view — so it fires AFTER that batch has
  # run, and on the :ui lane, because such a listener reads a FINISHED
  # transcript and touches buffers that are not this agent's.
  #
  # It carries the slug and the stop reason; Scheme decides what counts as
  # a normal end and what counts as an error.
  defp notify_turn_end(slug, batch) do
    handler =
      Roots.get({:agent_turn_end})

    if handler do
      for event <- batch, Backend.event_type(event) == "turn-end" do
        stop = Backend.plist_get(event, "stop-reason") || "end_turn"
        Session.apply_callback(handler, [slug, to_string(stop)], nil, :ui)
      end
    end

    :ok
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
end
