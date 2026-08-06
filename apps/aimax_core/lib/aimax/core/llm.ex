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

  @doc "Synchronous request — for callers managing their own tasks (LLM threads)."
  def request(prompt), do: request_fun().(prompt)

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

  @doc "Set the model for subsequent requests (scheme: set-llm-model!)."
  def set_model(model), do: :persistent_term.put(:aimax_llm_model, model)

  def model do
    case :persistent_term.get(:aimax_llm_model, nil) do
      nil -> Application.get_env(:aimax_core, :llm_model, "claude-sonnet-5")
      m -> m
    end
  end

  # key sources per var: env -> ~/.aimax/<lowercased>-key -> doppler (cached)
  defp api_key(var \\ "ANTHROPIC_API_KEY") do
    with nil <- non_empty(System.get_env(var)),
         nil <- file_key(var),
         nil <- doppler_key(var) do
      nil
    end
  end

  defp non_empty(s) when s in [nil, ""], do: nil
  defp non_empty(s), do: s

  defp file_key(var) do
    name = var |> String.replace("_API_KEY", "") |> String.downcase()

    case File.read(Path.join(Aimax.Core.home(), "#{name}-key")) do
      {:ok, key} -> non_empty(String.trim(key))
      _ -> nil
    end
  end

  # doppler (project personal / config dev), same source as ~/.emacs.d/secrets.el
  defp doppler_key(var) do
    cache_key = {:aimax_doppler, var}

    case :persistent_term.get(cache_key, :unset) do
      :unset ->
        key =
          case System.cmd(
                 "doppler",
                 ["secrets", "get", var, "--project", "personal", "--config", "dev", "--plain"],
                 stderr_to_stdout: true
               ) do
            {out, 0} -> non_empty(String.trim(out))
            _ -> nil
          end

        :persistent_term.put(cache_key, key)
        key

      cached ->
        cached
    end
  rescue
    # doppler binary missing
    _ -> nil
  end

  # Provider routing by model name:
  #   "openrouter:<model>"      -> OpenRouter (openai-compatible)
  #   "openai:<model>"          -> OpenAI
  #   anything else             -> Anthropic
  defp default_request(prompt) do
    case model() do
      "openrouter:" <> m ->
        openai_style(
          "https://openrouter.ai/api/v1/chat/completions",
          "OPENROUTER_API_KEY",
          m,
          prompt,
          [{"http-referer", "https://github.com/svs/ai-max.el"}, {"x-title", "ai-max.el"}]
        )

      "openai:" <> m ->
        openai_style("https://api.openai.com/v1/chat/completions", "OPENAI_API_KEY", m, prompt, [])

      m ->
        anthropic(m, prompt)
    end
  end

  defp anthropic(model, prompt) do
    case api_key("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] ->
        {:error, "no ANTHROPIC_API_KEY (env, ~/.aimax/anthropic-key, or doppler)"}

      key ->
        Req.post("https://api.anthropic.com/v1/messages",
          json: %{model: model, max_tokens: 4096, messages: [%{role: "user", content: prompt}]},
          headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
          receive_timeout: 180_000
        )
        |> case do
          {:ok, %{status: 200, body: %{"content" => blocks}}} ->
            {:ok, Enum.map_join(blocks, "", &(&1["text"] || ""))}

          other ->
            format_error(other)
        end
    end
  end

  defp openai_style(url, key_var, model, prompt, extra_headers) do
    case api_key(key_var) do
      key when key in [nil, ""] ->
        {:error, "no #{key_var} (env, ~/.aimax/..., or doppler)"}

      key ->
        Req.post(url,
          json: %{model: model, messages: [%{role: "user", content: prompt}]},
          headers: [{"authorization", "Bearer #{key}"} | extra_headers],
          receive_timeout: 180_000
        )
        |> case do
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
            {:ok, text}

          other ->
            format_error(other)
        end
    end
  end

  defp format_error({:ok, %{status: status, body: body}}), do: {:error, "HTTP #{status}: #{inspect(body)}"}
  defp format_error({:error, e}), do: {:error, Exception.message(e)}
  defp format_error(other), do: {:error, inspect(other)}
end
