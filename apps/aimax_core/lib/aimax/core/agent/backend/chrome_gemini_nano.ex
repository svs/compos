defmodule Aimax.Core.Agent.Backend.ChromeGeminiNano do
  @moduledoc """
  A stateless backend for Chrome's built-in Gemini Nano Prompt API.

  Chrome owns the model and its local inference runtime. The backend sends the
  current transcript to the ai-max extension, which evaluates the Prompt API
  in the active page. No API key or model process runs in the daemon.
  """

  @behaviour Aimax.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Aimax.Core.Agent.Backend
  alias Aimax.Core.Browser

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
  def respond_permission(_pid, _rpc_id, _option_id), do: :ok

  @impl Backend
  def capabilities, do: [:models, :stateless]

  @impl GenServer
  def init({config, owner}) do
    send(owner, {:backend_event, Backend.plist(type: :ready)})

    {:ok,
     %{
       owner: owner,
       model: Map.get(config, "model", "gemini-nano"),
       request: nil
     }}
  end

  @impl GenServer
  def handle_call({:prompt, _text, _context}, _from, %{request: ref} = state)
      when is_reference(ref),
      do: {:reply, {:error, :busy}, state}

  def handle_call({:prompt, text, context}, _from, state) do
    ref = make_ref()
    backend = self()

    args = %{
      "system" => Map.get(context, :system, ""),
      "messages" => history(Map.get(context, :turns, [])),
      "prompt" => text
    }

    Browser.call("gemini-nano", args, fn
      {:ok, result} -> send(backend, {:chrome_result, ref, {:ok, result}})
      {:error, reason} -> send(backend, {:chrome_result, ref, {:error, reason}})
    end)

    {:reply, :ok, %{state | request: ref}}
  end

  def handle_call({:set_model, "gemini-nano"}, _from, state), do: {:reply, :ok, state}
  def handle_call({:set_model, _model}, _from, state), do: {:reply, {:error, :unsupported}, state}

  def handle_call(:cancel, _from, %{request: ref} = state) when is_reference(ref) do
    emit(state, type: :"turn-end", "stop-reason": "cancelled")
    {:reply, :ok, %{state | request: nil}}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_info({:chrome_result, ref, result}, %{request: ref} = state) do
    state = %{state | request: nil}

    case result do
      {:ok, text} when is_binary(text) ->
        emit(state, type: :chunk, text: text)
        emit(state, type: :"turn-end", "stop-reason": "end_turn")

      {:ok, other} ->
        emit(state, type: :error, text: "Chrome Gemini Nano returned a non-text result")
        emit(state, type: :"turn-end", "stop-reason": "error")
        _ = other

      {:error, reason} ->
        emit(state, type: :error, text: "Chrome Gemini Nano: #{reason}")
        emit(state, type: :"turn-end", "stop-reason": "error")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit(state, kvs), do: send(state.owner, {:backend_event, Backend.plist(kvs)})

  defp history(turns) do
    Enum.flat_map(turns, fn turn ->
      role = Backend.plist_get(turn, "role")

      text =
        turn
        |> Backend.plist_get("blocks")
        |> List.wrap()
        |> Enum.flat_map(fn block ->
          case block do
            ["text", value] when is_binary(value) -> [value]
            _ -> []
          end
        end)
        |> Enum.join("")

      if role in ["user", "assistant"] and text != "",
        do: [%{"role" => role, "content" => text}],
        else: []
    end)
  end
end
