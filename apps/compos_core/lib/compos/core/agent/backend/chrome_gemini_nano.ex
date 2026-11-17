defmodule Compos.Core.Agent.Backend.ChromeGeminiNano do
  @moduledoc """
  A stateless backend for Chrome's built-in Gemini Nano Prompt API.

  Chrome owns the model and its local inference runtime. The backend sends the
  current transcript to the compos extension, which evaluates the Prompt API
  in the active page. No API key or model process runs in the daemon.
  """

  use Compos.Core.Agent.Backend

  use GenServer, restart: :temporary

  alias Compos.Core.Agent.Backend
  alias Compos.Core.Browser

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
       # what the usage report names
       slug: Map.get(config, "slug"),
       connector: Map.get(config, "connector"),
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
    report_usage(state, "cancelled")
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
        report_usage(state, "done")
        emit(state, type: :"turn-end", "stop-reason": "end_turn")

      {:ok, other} ->
        emit(state, type: :error, text: "Chrome Gemini Nano returned a non-text result")
        report_usage(state, "failed")
        emit(state, type: :"turn-end", "stop-reason": "error")
        _ = other

      {:error, reason} ->
        emit(state, type: :error, text: "Chrome Gemini Nano: #{reason}")
        report_usage(state, "failed")
        emit(state, type: :"turn-end", "stop-reason": "error")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp emit(state, kvs), do: send(state.owner, {:backend_event, Backend.plist(kvs)})

  # The model runs in the browser and reports no tokens. The turn still
  # goes to the usage report (Compos.Core.LLM.report_usage/2), so a reader
  # can count it, or cost it in its own terms.
  defp report_usage(state, how) do
    Compos.Core.LLM.report_usage(%{
      slug: Map.get(state, :slug),
      connector: Map.get(state, :connector),
      backend: "chrome-gemini-nano",
      model: state.model,
      end: how
    })
  end

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
