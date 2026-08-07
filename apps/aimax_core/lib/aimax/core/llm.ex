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
  with params ((pname type description [optional]) ...) — or, for bridged
  MCP tools, a JSON input-schema string in place of the params list.
  `dispatcher` is a Scheme closure `(name args-plist) -> result`; `callback`
  gets the final text. opts: `:on_usage` is called (before `callback`) with
  the summed usage map of every round, plus "cost" when llmdb prices the
  model; the request is also recorded in the LLMDb ledger.
  """
  def complete_tools(prompt, system, specs, dispatcher, callback, opts \\ [])
      when is_function(callback, 1) do
    tools = Enum.map(specs, &tool_json/1)

    {:ok, _} =
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        case tool_loop([%{role: "user", content: prompt}], system, tools, dispatcher, 0, %{}) do
          {:ok, text, usage} ->
            deliver_usage(usage, opts[:on_usage])
            callback.(text)

          {:error, msg} ->
            Session.message("llm error: #{msg}")
        end
      end)

    :ok
  end

  defp deliver_usage(usage, on_usage) do
    cost = Aimax.Core.LLMDb.record(model(), usage)
    if on_usage, do: on_usage.(Map.put(usage, "cost", cost))
  end

  defp tool_loop(_messages, _system, _tools, _dispatcher, rounds, _usage)
       when rounds >= @max_tool_rounds,
       do: {:error, "tool loop exceeded #{@max_tool_rounds} rounds"}

  defp tool_loop(messages, system, tools, dispatcher, rounds, usage) do
    case chat_fun().(%{messages: messages, system: system, tools: tools}) do
      {:ok, %{"stop_reason" => "tool_use", "content" => blocks} = resp} ->
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

        tool_loop(messages, system, tools, dispatcher, rounds + 1, add_usage(usage, resp))

      {:ok, %{"content" => blocks} = resp} ->
        {:ok, Enum.map_join(blocks, "", &(&1["text"] || "")), add_usage(usage, resp)}

      {:error, msg} ->
        {:error, msg}
    end
  end

  # sum token counts across the loop's rounds
  defp add_usage(acc, %{"usage" => usage}) when is_map(usage),
    do: Map.merge(acc, usage, fn _k, a, b -> if is_number(a) and is_number(b), do: a + b, else: b end)

  defp add_usage(acc, _), do: acc

  # MCP tools dispatch in Elixir, never through the Scheme session — a slow
  # web fetch inside Session.call_fn would block every keystroke
  defp run_tool(_dispatcher, "mcp__" <> _ = name, input) do
    Session.message("tool: #{name} #{inspect(input)}")

    case Aimax.Core.MCP.call_qualified(name, input) do
      {:ok, text} -> text
      {:error, msg} -> "error: #{msg}"
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
  # null -> #f (this Scheme has no nil). Also the (json-parse) primitive.
  def json_to_scheme(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> [{:sym, k}, json_to_scheme(v)] end)

  def json_to_scheme(l) when is_list(l), do: Enum.map(l, &json_to_scheme/1)
  def json_to_scheme(nil), do: false
  def json_to_scheme(v), do: v

  @doc """
  One Scheme tool spec -> Anthropic tool JSON. Public because the MCP proxy
  surface (tool-specs-json primitive) reuses it to serve the same registry
  to external ACP agents.
  """
  # MCP-bridged tools carry their original JSON schema verbatim
  def tool_json([name, description, schema]) when is_binary(schema),
    do: %{name: plain(name), description: description, input_schema: Jason.decode!(schema)}

  def tool_json([name, description, params]) do
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
        # cache breakpoints on tools, system, and the last message: chat
        # resends the whole transcript every turn and the tool loop resends
        # it every round — with the prefix cached, repeat input bills at the
        # cache-read rate (~10%) instead of full price
        body = %{
          model: model,
          max_tokens: 4096,
          messages: cache_last(messages),
          tools: cache_last_tool(tools)
        }

        body =
          if system,
            do:
              Map.put(body, :system, [
                %{type: "text", text: system, cache_control: %{type: "ephemeral"}}
              ]),
            else: body

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

  # moving cache breakpoint: the last message's last content block. Each
  # request extends the previous one's prefix, so round N of the tool loop
  # (and turn N of a chat) reads rounds 1..N-1 from cache.
  defp cache_last([]), do: []

  defp cache_last(messages) do
    List.update_at(messages, -1, fn
      %{content: content} = m when is_binary(content) ->
        %{m | content: [%{type: "text", text: content, cache_control: %{type: "ephemeral"}}]}

      %{content: blocks} = m when is_list(blocks) ->
        %{m | content: List.update_at(blocks, -1, &Map.put(&1, :cache_control, %{type: "ephemeral"}))}

      m ->
        m
    end)
  end

  defp cache_last_tool([]), do: []

  defp cache_last_tool(tools),
    do: List.update_at(tools, -1, &Map.put(&1, :cache_control, %{type: "ephemeral"}))

  @doc "Set the model for subsequent requests (scheme: set-llm-model!)."
  def set_model(model), do: :persistent_term.put(:aimax_llm_model, model)

  def model do
    case :persistent_term.get(:aimax_llm_model, nil) do
      nil -> Application.get_env(:aimax_core, :llm_model, "claude-sonnet-5")
      m -> m
    end
  end

  # key sources per var: env -> ~/.aimax/<lowercased>-key -> doppler (cached);
  # shared with MCP server specs via Aimax.Core.Keys
  defp api_key(var), do: Aimax.Core.Keys.get(var)

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
          {:ok, %{status: 200, body: %{"content" => blocks} = body}} ->
            if is_map(body["usage"]), do: Aimax.Core.LLMDb.record(model, body["usage"])
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
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]} = body}} ->
            if is_map(body["usage"]), do: Aimax.Core.LLMDb.record(model(), body["usage"])
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
