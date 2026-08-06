defmodule Aimax.Core.LLM do
  @moduledoc """
  The one async LLM primitive everything composes over: gptel pipes, copilot
  completions, agents. Runs in a supervised Task — a slow or failing request
  can never block a keystroke.

  `(llm prompt handler)` from Scheme: handler is called with the completion
  text (via Session, so it can touch buffers). Errors land in *messages*.

  Pluggable request fun (`:llm_request_fun` app env) keeps tests hermetic.

  Tool use (gptel-style, native): `complete_tools/5` runs the Anthropic
  tool_use loop. Tool definitions and handlers live in the Scheme registry
  (packages/tools.scm, `define-tool!`); this module only converts specs to
  JSON, drives the round-trips, and dispatches calls back into the session
  (`Session.call_fn` on the Scheme dispatcher closure). The `:llm_chat_fun`
  app env stubs the wire for tests.
  TODO: streaming (on-chunk handler), tools for openai-style providers.
  """

  alias Aimax.Core.Session

  @max_tool_rounds 25

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

  @doc """
  Async tool loop. `specs` is Scheme data: ((name description params) ...)
  with params ((pname type description [optional]) ...). `dispatcher` is a
  Scheme closure `(name args-plist) -> result`; `callback` gets the final text.
  """
  def complete_tools(prompt, system, specs, dispatcher, callback)
      when is_function(callback, 1) do
    tools = Enum.map(specs, &tool_json/1)

    {:ok, _} =
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        case tool_loop([%{role: "user", content: prompt}], system, tools, dispatcher, 0) do
          {:ok, text} -> callback.(text)
          {:error, msg} -> Session.message("llm error: #{msg}")
        end
      end)

    :ok
  end

  defp tool_loop(_messages, _system, _tools, _dispatcher, rounds)
       when rounds >= @max_tool_rounds,
       do: {:error, "tool loop exceeded #{@max_tool_rounds} rounds"}

  defp tool_loop(messages, system, tools, dispatcher, rounds) do
    case chat_fun().(%{messages: messages, system: system, tools: tools}) do
      {:ok, %{"stop_reason" => "tool_use", "content" => blocks}} ->
        results =
          for %{"type" => "tool_use"} = b <- blocks do
            %{
              type: "tool_result",
              tool_use_id: b["id"],
              content: run_tool(dispatcher, b["name"], b["input"])
            }
          end

        messages =
          messages ++ [%{role: "assistant", content: blocks}, %{role: "user", content: results}]

        tool_loop(messages, system, tools, dispatcher, rounds + 1)

      {:ok, %{"content" => blocks}} ->
        {:ok, Enum.map_join(blocks, "", &(&1["text"] || ""))}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp run_tool(dispatcher, name, input) do
    Session.message("tool: #{name} #{inspect(input)}")

    case Session.call_fn(dispatcher, [name, json_to_scheme(input)]) do
      {:ok, v} when is_binary(v) -> v
      {:ok, v} -> Aimax.Scheme.Printer.print(v)
      {:error, msg} -> "error: #{msg}"
    end
  catch
    :exit, _ -> "error: tool dispatch timed out"
  end

  # JSON objects -> flat plists with {:sym, key} keys (house convention);
  # null -> #f (this Scheme has no nil)
  defp json_to_scheme(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> [{:sym, k}, json_to_scheme(v)] end)

  defp json_to_scheme(l) when is_list(l), do: Enum.map(l, &json_to_scheme/1)
  defp json_to_scheme(nil), do: false
  defp json_to_scheme(v), do: v

  defp tool_json([name, description, params]) do
    properties =
      Map.new(params, fn [p, type, pdesc | _] ->
        {plain(p), %{type: plain(type), description: pdesc}}
      end)

    required =
      for [p, _, _ | rest] <- params, {:sym, "optional"} not in rest, do: plain(p)

    %{
      name: plain(name),
      description: description,
      input_schema: %{type: "object", properties: properties, required: required}
    }
  end

  defp plain({:sym, s}), do: s
  defp plain(s) when is_binary(s), do: s

  defp chat_fun do
    Application.get_env(:aimax_core, :llm_chat_fun, &default_chat/1)
  end

  defp default_chat(%{messages: messages, system: system, tools: tools}) do
    case model() do
      "openrouter:" <> _ ->
        {:error, "tool use needs an Anthropic model — (set-llm-model! \"claude-sonnet-5\")"}

      "openai:" <> _ ->
        {:error, "tool use needs an Anthropic model — (set-llm-model! \"claude-sonnet-5\")"}

      m ->
        anthropic_chat(m, messages, system, tools)
    end
  end

  defp anthropic_chat(model, messages, system, tools) do
    case api_key("ANTHROPIC_API_KEY") do
      key when key in [nil, ""] ->
        {:error, "no ANTHROPIC_API_KEY (env, ~/.aimax/anthropic-key, or doppler)"}

      key ->
        body = %{model: model, max_tokens: 4096, messages: messages, tools: tools}
        body = if system, do: Map.put(body, :system, system), else: body

        Req.post("https://api.anthropic.com/v1/messages",
          json: body,
          headers: [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}],
          receive_timeout: 180_000
        )
        |> case do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          other -> format_error(other)
        end
    end
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
