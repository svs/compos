defmodule Aimax.Core.Agent.Backend.ReqLLM do
  @moduledoc """
  The direct-API backend: turns run in-process through `Aimax.Core.LLM`'s
  req_llm tool loop — streaming deltas, tool cards, usage, queue/interrupt —
  the same thread surface as ACP, no subprocess.

  History is NOT kept here: each turn pulls fresh context (turns, system
  preamble, tool specs, dispatcher) from Scheme through the global
  `agent-context-fn!` closure — `'chat-turns` stays the single truth, and
  the per-send system prompt (group pull-context) can never go stale.

  Each prompt runs in a supervised task; events funnel through this
  GenServer so their order is preserved. `cancel` kills the task and ends
  the turn.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend
  alias Aimax.Core.{LLM, Session}

  @escaped :aimax_escaped_closures

  # --- behaviour --------------------------------------------------------------

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

  # the api lane is stateless — a model switch is just a variable, so it
  # always succeeds in place and the conversation continues
  @impl Backend
  def set_model(pid, model_id), do: GenServer.call(pid, {:set_model, model_id})

  @impl Backend
  def respond_permission(pid, rpc_id, option_id),
    do: GenServer.call(pid, {:respond_permission, rpc_id, option_id})

  @impl Backend
  def capabilities, do: [:models, :streaming]

  # --- server -----------------------------------------------------------------

  @impl GenServer
  def init({config, owner}) do
    send(owner, {:backend_event, Backend.plist(type: :ready)})

    {:ok,
     %{
       owner: owner,
       slug: Map.get(config, "slug"),
       model: Map.get(config, "model"),
       task: nil,
       next_rpc_id: 1,
       pending: nil
     }}
  end

  @impl GenServer
  def handle_call({:prompt, text, context}, _from, state) do
    me = self()
    slug = state.slug
    model = state.model || LLM.model()
    display = Map.get(context, :display, text)

    task =
      Task.Supervisor.async_nolink(Aimax.Core.TaskSupervisor, fn ->
        run_turn(me, slug, model, text, display)
      end)

    {:reply, :ok, %{state | task: task}}
  end

  def handle_call(:cancel, _from, %{task: %Task{} = task} = state) do
    state = release_pending(state, :deny)
    Task.shutdown(task, :brutal_kill)
    emit(state, type: :"turn-end", "stop-reason": "cancelled")
    {:reply, :ok, %{state | task: nil}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call({:set_model, model_id}, _from, state),
    do: {:reply, :ok, %{state | model: model_id}}

  # the turn task asks before running a gated tool; the reply comes later,
  # when the user (or a deadline) answers — hence no immediate {:reply, ...}
  def handle_call({:ask_permission, title, kind, raw}, from, state) do
    id = state.next_rpc_id

    emit(state,
      type: :permission,
      "rpc-id": id,
      title: title,
      kind: kind,
      # what the gate judged — the renderer re-consults the same policy
      # and must not see less than the gate did
      raw: raw,
      options: [
        ["allow", "Allow", "allow_once"],
        ["always", "Always", "allow_always"],
        ["deny", "Reject", "reject_once"]
      ]
    )

    {:noreply, %{state | next_rpc_id: id + 1, pending: %{rpc_id: id, from: from}}}
  end

  # CAS on rpc_id: answering a request that is already resolved (or was
  # never ours) is a NO-OP, never an error — double answers are routine
  # when a banner and a deadline race
  def handle_call({:respond_permission, rpc_id, option_id}, _from, state) do
    case state.pending do
      %{rpc_id: ^rpc_id} ->
        {:reply, :ok, release_pending(state, verdict_of(option_id))}

      _ ->
        {:reply, :ok, state}
    end
  end

  defp verdict_of(nil), do: :deny
  defp verdict_of("deny"), do: :deny
  defp verdict_of(opt) when is_binary(opt), do: if(opt == "always", do: :always, else: :allow)

  defp release_pending(%{pending: %{from: from}} = state, verdict) do
    GenServer.reply(from, verdict)
    %{state | pending: nil}
  end

  defp release_pending(state, _verdict), do: state

  # events from the turn task, forwarded in arrival order
  @impl GenServer
  def handle_cast({:turn_event, kvs}, state) do
    emit(state, kvs)
    {:noreply, state}
  end

  # turn task finished
  @impl GenServer
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, _text, usage} ->
        cost = Aimax.Core.LLMDb.record(state.model || LLM.model(), usage)
        t = Aimax.Core.LLMDb.tokens(usage)

        emit(state,
          type: :usage,
          input: t.input,
          output: t.output,
          "cache-read": t.cache_read,
          "cache-write": t.cache_write,
          cost: cost || false
        )

        emit(state, type: :"turn-end", "stop-reason": "end_turn")

      {:error, msg} ->
        emit(state, type: :error, text: msg)
        emit(state, type: :"turn-end", "stop-reason": "error")
    end

    {:noreply, %{state | task: nil}}
  end

  # turn task crashed (a cancel's :brutal_kill DOWN is flushed above)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = release_pending(state, :deny)
    emit(state, type: :error, text: "turn crashed: #{inspect(reason)}")
    emit(state, type: :"turn-end", "stop-reason": "error")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # a closing backend must never leave a turn task blocked on an answer
  @impl GenServer
  def terminate(_reason, state) do
    release_pending(state, :deny)
    :ok
  end

  defp emit(state, kvs) do
    send(state.owner, {:backend_event, Backend.plist(kvs)})
    state
  end

  # --- the turn (runs in a supervised task) -----------------------------------

  defp run_turn(backend, slug, model, text, display) do
    ev = fn kvs -> GenServer.cast(backend, {:turn_event, kvs}) end

    case fetch_context(slug, display) do
      {:ok, ctx} ->
        messages = Enum.map(ctx.turns, fn [role, t] -> %{role: to_string(role), content: t} end)

        LLM.run_tool_loop(
          messages ++ [%{role: "user", content: text}],
          ctx.system,
          ctx.tools,
          ctx.dispatcher,
          model: model,
          on_chunk: fn t -> ev.(type: :chunk, text: t) end,
          on_thinking: fn t -> ev.(type: :thought, text: t) end,
          # aimax owns permissions on BOTH lanes: the same Scheme policy
          # that answers ACP's requests gates every direct-lane tool call
          gate: fn name, input -> gate(backend, slug, name, input) end,
          on_tool: fn id, name, input ->
            # the title carries a one-line summary so the card says what it
            # DID without being opened; the input itself goes into the body,
            # ahead of the result, so opening one shows the whole call
            ev.(
              type: :"tool-call",
              id: id,
              title: tool_card_title(name, input),
              kind: "tool",
              status: "pending"
            )

            ev.(type: :"tool-update", id: id, status: "running", text: tool_input_text(input))
          end,
          on_tool_done: fn id, result ->
            ev.(type: :"tool-update", id: id, status: "completed", text: tool_card_text(result))
          end
        )

      {:error, msg} ->
        {:error, msg}
    end
  end

  # the permission gate: ask Scheme's policy, and only when it says "ask"
  # block the turn on a real request (which the banner, or a deadline,
  # answers). A missing policy fn means no gate — never a wedged turn.
  defp gate(backend, slug, name, input) do
    case permission_verdict(slug, name, input) do
      :allow ->
        :allow

      :reject ->
        {:deny, "denied by policy"}

      {:ask, raw} ->
        case GenServer.call(backend, {:ask_permission, name, "tool", raw}, :infinity) do
          :deny -> {:deny, "denied"}
          _ -> :allow
        end
    end
  catch
    # a policy that crashes must not wedge the turn — fail open, exactly
    # as an ungated tool would run
    :exit, _ -> :allow
  end

  defp permission_verdict(slug, name, input) do
    case :ets.lookup(@escaped, {:agent_permission}) do
      [] ->
        :allow

      [{_, fun}] ->
        raw = name <> " " <> inspect(input)

        case Session.call_fn(fun, [slug, name, "tool", raw]) do
          {:ok, {:sym, "ask"}} -> {:ask, raw}
          {:ok, {:sym, "reject"}} -> :reject
          _ -> :allow
        end
    end
  end

  # tool results can be huge (buffer-text of a big file) — the card shows a
  # trimmed body; the model still gets the full result
# A tool card used to read "tool eval-scheme" and open onto nothing: the
  # input was thrown away and the body held only the result, which is often
  # empty. Fifteen identical cards tell you nothing about what happened.
  defp tool_card_title(name, input) do
    case summarise(input) do
      "" -> name
      s -> "#{name} · #{s}"
    end
  end

  # one line, enough to tell two calls apart in a list
  defp summarise(input) do
    input
    |> primary_arg()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 72)
  end

  # most tools have one argument that matters; show that rather than a blob
  defp primary_arg(input) when is_map(input) do
    case input do
      %{"code" => c} -> c
      %{"query" => q} -> q
      %{"path" => p} -> p
      %{"name" => n} -> n
      other -> Jason.encode!(other)
    end
  end

  defp primary_arg(other), do: other

  defp tool_input_text(input) when is_map(input) and map_size(input) == 0, do: ""

  defp tool_input_text(input) do
    body =
      case input do
        %{"code" => c} -> c
        other -> Jason.encode!(other, pretty: true)
      end

    String.trim_trailing(to_string(body)) <> "\n\n"
  end

  defp tool_card_text(result) do
    s = result |> to_string() |> String.trim()

    case s do
      "" -> ""
      s when byte_size(s) > 2000 -> binary_part(s, 0, floor_utf8(s, 2000)) <> "\n[…]\n"
      s -> s <> "\n"
    end
  end

  # a mid-UTF-8 cut poisons the JSON encoder — back off to a char boundary
  defp floor_utf8(_bin, at) when at <= 0, do: 0

  defp floor_utf8(bin, at) do
    case binary_part(bin, at, 1) do
      <<b>> when b < 128 or b >= 192 -> at
      _ -> floor_utf8(bin, at - 1)
    end
  end

  # (turns ((role text)...) system "..." tools (spec...) dispatcher <fn>) —
  # from the global agent-context-fn! closure, called with (slug display)
  defp fetch_context(slug, display) do
    case :ets.lookup(@escaped, {:agent_context}) do
      [] ->
        {:error, "no agent-context-fn! registered"}

      [{_, fun}] ->
        case Session.call_fn(fun, [slug, display]) do
          {:ok, plist} ->
            {:ok,
             %{
               turns: Backend.plist_get(plist, "turns") || [],
               system: plist_str(Backend.plist_get(plist, "system")),
               tools: Backend.plist_get(plist, "tools") || [],
               dispatcher: Backend.plist_get(plist, "dispatcher")
             }}

          {:error, msg} ->
            {:error, "context fn failed: #{msg}"}
        end
    end
  end

  defp plist_str(v) when is_binary(v), do: v
  defp plist_str(_), do: nil
end
