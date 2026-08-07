defmodule Aimax.Core.Agent.Backend.Stub do
  @moduledoc """
  A scripted backend: no wire, no subprocess — the test seam for everything
  ABOVE the backend contract (status machine, queueing, rendering,
  permissions), the way FakeTransport is the seam below ACP.

  Config carries `"script"`: a list of turns, each a list of flat event
  plists. Each prompt replays the next turn's events and ends the turn with
  `turn-end`. A `permission` event pauses the replay until
  `respond_permission` (answers are recorded in the handle for assertions).

  Scheme boundary note: `plist_to_map` stringifies symbols, so script events
  arrive as `["type", "chunk", "text", "hi"]` — keys are rebuilt into
  `{:sym, _}` and the `type` value back into a symbol here.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend

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

  @impl Backend
  def set_model(_pid, _model_id), do: {:error, :unsupported}

  @impl Backend
  def respond_permission(pid, rpc_id, option_id),
    do: GenServer.call(pid, {:respond_permission, rpc_id, option_id})

  @impl Backend
  def capabilities, do: []

  @doc "Test hook: every permission answer this stub received, in order."
  def answers(pid), do: GenServer.call(pid, :answers)

  @doc "Test hook: every prompt text this stub received, in order."
  def prompts(pid), do: GenServer.call(pid, :prompts)

  # --- server -----------------------------------------------------------------

  @impl GenServer
  def init({config, owner}) do
    send(owner, {:backend_event, Backend.plist(type: :ready)})

    {:ok,
     %{
       owner: owner,
       script: Map.get(config, "script") || [],
       paused: nil,
       answers: [],
       prompts: []
     }}
  end

  @impl GenServer
  def handle_call({:prompt, text, _context}, _from, state) do
    {turn, rest} =
      case state.script do
        [t | r] -> {t, r}
        [] -> {[], []}
      end

    state = %{state | script: rest, prompts: state.prompts ++ [text]}
    {:reply, :ok, play(state, Enum.map(turn, &to_event/1))}
  end

  def handle_call({:respond_permission, _rpc_id, option_id}, _from, %{paused: rest} = state)
      when is_list(rest) do
    state = %{state | paused: nil, answers: state.answers ++ [option_id]}
    {:reply, :ok, play(state, rest)}
  end

  def handle_call({:respond_permission, _rpc_id, option_id}, _from, state) do
    {:reply, :ok, %{state | answers: state.answers ++ [option_id]}}
  end

  def handle_call(:cancel, _from, %{paused: rest} = state) when is_list(rest) do
    send(state.owner, {:backend_event, Backend.plist(type: :"turn-end", "stop-reason": "cancelled")})
    {:reply, :ok, %{state | paused: nil}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:answers, _from, state), do: {:reply, state.answers, state}
  def handle_call(:prompts, _from, state), do: {:reply, state.prompts, state}

  defp play(state, []) do
    send(state.owner, {:backend_event, Backend.plist(type: :"turn-end", "stop-reason": "end_turn")})
    state
  end

  defp play(state, [event | rest]) do
    send(state.owner, {:backend_event, event})

    if Backend.event_type(event) == "permission" do
      %{state | paused: rest}
    else
      play(state, rest)
    end
  end

  # ["type", "chunk", "text", "hi"] (post-boundary strings) -> symbol plist
  defp to_event(flat) when is_list(flat) do
    flat
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn [k, v] -> [{:sym, to_string(k)}, event_val(to_string(k), v)] end)
  end

  defp event_val("type", v) when is_binary(v), do: {:sym, v}
  defp event_val(_k, v), do: v
end
