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
       task: nil
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
    Task.shutdown(task, :brutal_kill)
    emit(state, type: :"turn-end", "stop-reason": "cancelled")
    {:reply, :ok, %{state | task: nil}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call({:set_model, model_id}, _from, state),
    do: {:reply, :ok, %{state | model: model_id}}

  # no wire to answer — permission flow lands with W5's dispatcher gate
  def handle_call({:respond_permission, _rpc_id, _option_id}, _from, state),
    do: {:reply, :ok, state}

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
    emit(state, type: :error, text: "turn crashed: #{inspect(reason)}")
    emit(state, type: :"turn-end", "stop-reason": "error")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
          on_tool: fn id, name, _input ->
            ev.(type: :"tool-call", id: id, title: name, kind: "tool", status: "pending")
          end,
          on_tool_done: fn id, result ->
            ev.(type: :"tool-update", id: id, status: "completed", text: tool_card_text(result))
          end
        )

      {:error, msg} ->
        {:error, msg}
    end
  end

  # tool results can be huge (buffer-text of a big file) — the card shows a
  # trimmed body; the model still gets the full result
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
