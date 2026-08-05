defmodule Aimax.Core.LLM do
  @moduledoc """
  The one async LLM primitive everything composes over: gptel pipes, copilot
  completions, agents. Runs in a supervised Task — a slow or failing request
  can never block a keystroke.

  `(llm prompt handler)` from Scheme: handler is called with the completion
  text (via Session, so it can touch buffers). Errors land in *messages*.

  Pluggable request fun (`:llm_request_fun` app env) keeps tests hermetic.
  TODO: streaming (on-chunk handler), conversation state, tool use — the
  agent runtime builds on this.
  """

  alias Aimax.Core.Session

  def complete(prompt, callback) when is_function(callback, 1) do
    {:ok, _} =
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        case request_fun().(prompt) do
          {:ok, text} -> callback.(text)
          {:error, msg} -> Session.message("llm error: #{msg}")
        end
      end)

    :ok
  end

  defp request_fun do
    Application.get_env(:aimax_core, :llm_request_fun, &default_request/1)
  end

  defp default_request(prompt) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] ->
        {:error, "ANTHROPIC_API_KEY not set"}

      key ->
        case Req.post("https://api.anthropic.com/v1/messages",
               json: %{
                 model: Application.get_env(:aimax_core, :llm_model, "claude-sonnet-5"),
                 max_tokens: 4096,
                 messages: [%{role: "user", content: prompt}]
               },
               headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
               receive_timeout: 120_000
             ) do
          {:ok, %{status: 200, body: %{"content" => blocks}}} ->
            {:ok, Enum.map_join(blocks, "", &(&1["text"] || ""))}

          {:ok, %{status: status, body: body}} ->
            {:error, "HTTP #{status}: #{inspect(body)}"}

          {:error, e} ->
            {:error, Exception.message(e)}
        end
    end
  end
end
