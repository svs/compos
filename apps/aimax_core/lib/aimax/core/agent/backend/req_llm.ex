defmodule Aimax.Core.Agent.Backend.ReqLLM do
  @moduledoc """
  The direct-API backend: turns run in-process through `Aimax.Core.LLM`'s
  req_llm tool loop — streaming deltas, tool cards, usage, queue/interrupt —
  the same thread surface as ACP, no subprocess.

  History is NOT kept here: each turn pulls fresh context (turns, system
  preamble, tool specs, dispatcher) from Scheme through the global
  `agent-context-fn!` closure — the chat's conversation of record stays the
  single truth, and the per-send system prompt (group pull-context) can
  never go stale.

  The turn task both READS and WRITES that record, in one order: it reads
  it, appends the user message it is about to send, and reports every
  further message the tool loop appends (`agent-record-fn!`). So the next
  turn replays byte-for-byte what this one sent — tool calls and tool
  results included — and the provider's prompt cache hits. Nothing is
  reconstructed from rendered text, and no event batch can race the read.

  Each prompt runs in a supervised task; events funnel through this
  GenServer so their order is preserved. `cancel` kills the task and ends
  the turn.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend
  require Logger

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
       # the model this turn is actually running, captured when it starts:
       # C-c m mid-turn used to move state.model, and the finished turn was
       # then priced against a model it never ran on
       turn_model: nil,
       # what the turn has spent so far, reported round by round. A turn
       # that is cancelled or crashes still spent it.
       turn_usage: %{}
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

    {:reply, :ok, %{state | task: task, turn_model: model, turn_usage: %{}}}
  end

  def handle_call(:cancel, _from, %{task: %Task{} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    state = bill(state)
    emit(state, type: :"turn-end", "stop-reason": "cancelled")
    {:reply, :ok, %{state | task: nil}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call({:set_model, model_id}, _from, state),
    do: {:reply, :ok, %{state | model: model_id}}

  # The thread owns the pending slot for BOTH lanes now, so nothing here
  # is waiting on an answer and there is nothing to resolve. Kept because
  # it is a Backend callback and a thread may not know which lane it has.
  def handle_call({:respond_permission, _rpc_id, _option_id}, _from, state),
    do: {:reply, :ok, state}

  # events from the turn task, forwarded in arrival order
  @impl GenServer
  def handle_cast({:turn_event, kvs}, state) do
    emit(state, kvs)
    {:noreply, state}
  end

  # the running usage total, after every round of the loop
  def handle_cast({:turn_usage, usage}, state), do: {:noreply, %{state | turn_usage: usage}}

  # turn task finished
  @impl GenServer
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _text, usage, stop} ->
          state = bill(%{state | turn_usage: usage})
          emit(state, type: :"turn-end", "stop-reason": stop)
          state

        # the loop ended without a result — a round cap, a wire error. It
        # still ran rounds, and those rounds still cost money.
        {:error, msg} ->
          state = bill(state)
          emit(state, type: :error, text: msg)
          emit(state, type: :"turn-end", "stop-reason": "error")
          state
      end

    {:noreply, %{state | task: nil}}
  end

  # turn task crashed (a cancel's :brutal_kill DOWN is flushed above)
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state = bill(state)
    emit(state, type: :error, text: "turn crashed: #{inspect(reason)}")
    emit(state, type: :"turn-end", "stop-reason": "error")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp emit(state, kvs) do
    send(state.owner, {:backend_event, Backend.plist(kvs)})
    state
  end

  # Every path out of a turn passes through here — done, error, round cap,
  # crash, cancel — so the ledger and the chat's own total never disagree
  # with what was actually sent. An empty total (a turn that died before
  # its first round returned) bills nothing.
  defp bill(%{turn_usage: usage} = state) when map_size(usage) == 0, do: state

  defp bill(state) do
    cost = Aimax.Core.LLMDb.record(state.turn_model || LLM.model(), state.turn_usage, state.slug)
    t = Aimax.Core.LLMDb.tokens(state.turn_usage)

    emit(state,
      type: :usage,
      input: t.input,
      output: t.output,
      "cache-read": t.cache_read,
      "cache-write": t.cache_write,
      cost: cost || false
    )

    %{state | turn_usage: %{}}
  end

  # --- the turn (runs in a supervised task) -----------------------------------

  defp run_turn(backend, slug, model, text, display) do
    ev = fn kvs -> GenServer.cast(backend, {:turn_event, kvs}) end

    case fetch_context(slug, display) do
      {:ok, ctx} ->
        messages = Enum.map(ctx.turns, &turn_to_message/1)

        # the user turn joins the record before the wire carries it. The
        # blocks hold what the transcript shows; `wire` holds what was
        # actually sent, which carries the editor context preamble the
        # user never typed.
        record(slug, "user", [["text", display]], if(text == display, do: false, else: text))

        LLM.run_tool_loop(
          messages ++ [%{role: "user", content: text}],
          ctx.system,
          ctx.tools,
          ctx.dispatcher,
          model: model,
          on_record: fn role, blocks -> record(slug, role, blocks_to_record(blocks), false) end,
          on_round_usage: fn usage -> GenServer.cast(backend, {:turn_usage, usage}) end,
          on_chunk: fn t -> ev.(type: :chunk, text: t) end,
          on_thinking: fn t -> ev.(type: :thought, text: t) end,
          # aimax owns permissions on BOTH lanes: the same Scheme policy
          # that answers ACP's requests gates every direct-lane tool call
          gate: fn name, input -> gate(ev, slug, name, input) end,
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

  # The permission gate: ask Scheme's policy, and only when it says "ask"
  # block the turn on a real request. The thread owns that request — the
  # rpc id, the pending slot, the CAS, the deadline — so this lane and the
  # ACP lane resolve one the same way.
  #
  # A missing policy fn means no gate: a bare (llm-tools ...) call has
  # never had one, and must not start wedging.
  defp gate(ev, slug, name, input) do
    case permission_verdict(slug, name, input) do
      :allow ->
        :allow

      :reject ->
        {:deny, "denied by policy"}

      {:crash, why} ->
        # A policy that crashes used to fail OPEN: the tool ran as if it
        # had never been gated. It fails closed now (decided 2026-08-12).
        # A buggy policy stalls agents until it is fixed; that is the
        # intended trade, and the transcript says which policy to fix.
        Logger.error("permission policy crashed: #{why}")
        ev.(type: :error, text: "the permission policy crashed — denying: #{why}")
        {:deny, "the permission policy crashed; fix *permission-policy* and retry"}

      {:ask, raw} ->
        case Aimax.Core.Agent.ask_permission(slug, %{title: name, kind: "tool", raw: raw}) do
          :deny -> {:deny, "denied"}
          {:error, _} -> {:deny, "the thread went away before this was answered"}
          _ -> :allow
        end
    end
  catch
    kind, reason ->
      why = "#{inspect(kind)} #{inspect(reason)}"
      Logger.error("permission gate crashed: #{why}")
      ev.(type: :error, text: "the permission gate crashed — denying: #{why}")
      {:deny, "the permission gate crashed; denied"}
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
          {:ok, _} -> :allow
          {:error, msg} -> {:crash, msg}
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

  # --- the conversation of record <-> the wire --------------------------------
  #
  # A recorded turn is a Scheme plist:
  #
  #   (role "user"|"assistant" blocks BLOCKS wire WIRE)
  #
  # BLOCKS is a list of ("text" STRING), ("tool-use" ID NAME INPUT-JSON) and
  # ("tool-result" ID OUTPUT ERROR?). WIRE is the exact user text that was
  # sent, when it differs from what the transcript shows.

  defp turn_to_message(turn) do
    blocks = Backend.plist_get(turn, "blocks") || []

    case Backend.plist_get(turn, "role") do
      "user" -> user_message(blocks, Backend.plist_get(turn, "wire"))
      _ -> %{role: "assistant", content: Enum.map(blocks, &block_to_wire/1)}
    end
  end

  # a user turn is either prose (one string, so the wire text wins when we
  # have it) or a round of tool results (blocks, never prose)
  defp user_message(_blocks, wire) when is_binary(wire), do: %{role: "user", content: wire}

  defp user_message(blocks, _wire) do
    if Enum.all?(blocks, &match?(["text" | _], &1)) do
      %{role: "user", content: Enum.map_join(blocks, "", fn ["text", t] -> t end)}
    else
      %{role: "user", content: Enum.map(blocks, &block_to_wire/1)}
    end
  end

  defp block_to_wire(["text", t]), do: %{"type" => "text", "text" => t}

  defp block_to_wire(["tool-use", id, name, input]),
    do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => decode_input(input)}

  defp block_to_wire(["tool-result", id, out, err]),
    do: %{type: "tool_result", tool_use_id: id, content: out, is_error: err == true}

  defp decode_input(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp decode_input(_), do: %{}

  # the loop's wire blocks -> record blocks. The tool input is kept as JSON
  # text: it is what goes back on the wire, and it survives a .chat file
  # without a lossy detour through Scheme data.
  defp blocks_to_record(blocks), do: for(b <- blocks, r = block_to_record(b), do: r)

  defp block_to_record(%{"type" => "text", "text" => t}), do: ["text", t]

  defp block_to_record(%{"type" => "tool_use"} = b),
    do: ["tool-use", b["id"], b["name"], Jason.encode!(b["input"] || %{})]

  defp block_to_record(%{type: "tool_result", tool_use_id: id, content: c} = b),
    do: ["tool-result", id, to_string(c), Map.get(b, :is_error, false) == true]

  defp block_to_record(_), do: nil

  # append one turn to the chat's record, synchronously, from the turn task
  defp record(slug, role, blocks, wire) do
    case :ets.lookup(@escaped, {:agent_record}) do
      [] -> :ok
      [{_, fun}] -> Session.call_fn(fun, [slug, role, blocks, wire])
    end
  end

  # (turns (TURN...) system "..." tools (spec...) dispatcher <fn>) —
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
