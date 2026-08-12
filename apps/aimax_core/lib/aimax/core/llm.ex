defmodule Aimax.Core.LLM do
  @moduledoc """
  The one async LLM primitive everything composes over: gptel pipes, copilot
  completions, chat backends. Runs in a supervised Task — a slow or failing
  request can never block a keystroke.

  The wire is `req_llm`: provider translation, streaming, and tool-call
  encoding are the library's job. This module owns the tool loop, the
  Scheme-registry integration, prompt-cache policy, and the usage ledger.
  Internal loop shapes stay Anthropic-style (`%{"stop_reason" => ...,
  "content" => blocks}`) — `req_llm` structs translate at the edge, and the
  `:llm_request_fun` / `:llm_chat_fun` app-env seams stub the wire for tests
  exactly as before.

  Model routing (`model/0` strings): `"openai:<m>"` / `"openrouter:<m>"`
  route to those providers; a bare id is Anthropic. Keys come from
  `Aimax.Core.Keys` (env -> ~/.aimax/<var>-key -> doppler).

  Tool use (gptel-style, native): `complete_tools/6` runs the tool_use loop.
  Tool definitions and handlers live in the Scheme registry
  (packages/tools.scm, `define-tool!`); this module converts specs to JSON,
  drives the round-trips, and dispatches calls back into the session
  (`Session.call_fn` on the Scheme dispatcher closure).
  """

  alias Aimax.Core.Session

  @max_tool_rounds 25

  @doc "Synchronous request — for callers managing their own tasks."
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
    {:ok, _} =
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        case run_tool_loop([%{role: "user", content: prompt}], system, specs, dispatcher, opts) do
          {:ok, text, usage} ->
            deliver_usage(usage, opts[:on_usage])
            callback.(text)

          {:error, msg} ->
            Session.message("llm error: #{msg}")
        end
      end)

    :ok
  end

  @doc """
  The synchronous tool loop — `complete_tools/6` wraps it in a Task, and
  `Backend.ReqLLM` drives it from its own turn task. `messages` are
  Anthropic-shaped; returns `{:ok, final_text, summed_usage}`.

  Event opts (all optional): `:on_chunk` / `:on_thinking` receive streamed
  text deltas (and, when the wire didn't stream, the whole final text);
  `:on_tool` receives `(id, name, input)` before a dispatch; `:on_tool_done`
  receives `(id, result)` after; `:gate` receives `(name, input)` before a
  dispatch and returns `:allow` or `{:deny, reason}` — the permission
  chokepoint every direct-lane tool call passes through. `:on_record`
  receives `(role, blocks)` for every message this loop appends to
  `messages` — the caller's conversation of record grows by exactly what
  went on the wire. `:model` overrides `model/0`.
  """
  def run_tool_loop(messages, system, specs, dispatcher, opts \\ []) do
    tools = Enum.map(specs, &tool_json/1)
    tool_loop(messages, system, tools, dispatcher, 0, %{}, Map.new(opts))
  end

  defp deliver_usage(usage, on_usage) do
    cost = Aimax.Core.LLMDb.record(model(), usage)
    if on_usage, do: on_usage.(Map.put(usage, "cost", cost))
  end

  defp tool_loop(_messages, _system, _tools, _dispatcher, rounds, _usage, _opts)
       when rounds >= @max_tool_rounds,
       do: {:error, "tool loop exceeded #{@max_tool_rounds} rounds"}

  defp tool_loop(messages, system, tools, dispatcher, rounds, usage, opts) do
    req =
      %{messages: messages, system: system, tools: tools}
      |> maybe_put(:on_chunk, opts[:on_chunk])
      |> maybe_put(:on_thinking, opts[:on_thinking])
      |> maybe_put(:model, opts[:model])

    case chat_fun().(req) do
      {:ok, %{"stop_reason" => "tool_use", "content" => blocks} = resp} ->
        emit_unstreamed_text(resp, opts)

        results =
          for %{"type" => "tool_use"} = b <- blocks do
            if opts[:on_tool], do: opts[:on_tool].(b["id"], b["name"], b["input"])

            {result, error?} =
              case gate_call(opts[:gate], b["name"], b["input"]) do
                :allow -> run_tool(dispatcher, b["name"], b["input"])
                {:deny, why} -> {"permission denied: #{why}", true}
              end

            if opts[:on_tool_done], do: opts[:on_tool_done].(b["id"], result)

            %{type: "tool_result", tool_use_id: b["id"], content: result, is_error: error?}
          end

        # a tool round appends two messages. Both go into the record, in
        # this order: the model re-reads its own call beside its result.
        record(opts, "assistant", blocks)
        record(opts, "user", results)

        messages =
          messages ++ [%{role: "assistant", content: blocks}, %{role: "user", content: results}]

        tool_loop(messages, system, tools, dispatcher, rounds + 1, add_usage(usage, resp), opts)

      {:ok, %{"content" => blocks} = resp} ->
        emit_unstreamed_text(resp, opts)
        record(opts, "assistant", blocks)
        {:ok, Enum.map_join(blocks, "", &(&1["text"] || "")), add_usage(usage, resp)}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # no gate configured (a bare (llm-tools ...) call) runs as before
  defp gate_call(nil, _name, _input), do: :allow
  defp gate_call(gate, name, input), do: gate.(name, input)

  # An empty content list is not a message any provider accepts, so it is
  # not a record entry either.
  defp record(%{on_record: f}, role, blocks) when is_function(f, 2) and blocks != [],
    do: f.(role, blocks)

  defp record(_opts, _role, _blocks), do: :ok

  # a stubbed (or non-streaming) wire emits no deltas — feed the round's
  # text through on_chunk so renderers see it exactly once either way
  defp emit_unstreamed_text(%{"streamed" => true}, _opts), do: :ok

  defp emit_unstreamed_text(%{"content" => blocks}, %{on_chunk: on_chunk})
       when is_function(on_chunk, 1) do
    # the same extraction the loop uses for its final text — a tool_use
    # block simply has no "text", so it contributes nothing
    text = Enum.map_join(blocks, "", &(&1["text"] || ""))
    if text != "", do: on_chunk.(text)
    :ok
  end

  defp emit_unstreamed_text(_resp, _opts), do: :ok

  # sum token counts across the loop's rounds
  defp add_usage(acc, %{"usage" => usage}) when is_map(usage),
    do: Map.merge(acc, usage, fn _k, a, b -> if is_number(a) and is_number(b), do: a + b, else: b end)

  defp add_usage(acc, _), do: acc

  # MCP tools dispatch in Elixir, never through the Scheme session — a slow
  # web fetch inside Session.call_fn would block every keystroke.
  # Returns {result-text, error?}: the wire marks a failed tool result, and
  # the record keeps the mark.
  defp run_tool(_dispatcher, "mcp__" <> _ = name, input) do
    Session.message("tool: #{name} #{inspect(input)}")

    case Aimax.Core.MCP.call_qualified(name, input) do
      {:ok, text} -> {text, false}
      {:error, msg} -> {"error: #{msg}", true}
    end
  end

  defp run_tool(dispatcher, name, input) do
    Session.message("tool: #{name} #{inspect(input)}")

    case Session.call_fn(dispatcher, [name, json_to_scheme(input)]) do
      {:ok, v} when is_binary(v) -> {v, false}
      {:ok, v} -> {Aimax.Scheme.Printer.print(v), false}
      {:error, msg} -> {"error: #{msg}", true}
    end
  catch
    :exit, _ -> {"error: tool dispatch timed out", true}
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

  # --- the req_llm wire ---------------------------------------------------------

  # one chat round: our Anthropic-shaped request -> req_llm -> back. Streams
  # when the caller passed :on_chunk; the response then carries "streamed"
  # so the loop doesn't re-emit the text.
  defp default_chat(%{messages: messages, system: system, tools: tools} = req) do
    model = req[:model] || model()
    spec = req_model_spec(model)

    with :ok <- ensure_key(spec) do
      ctx = to_req_context(messages, system)
      opts = req_opts(spec, tools)

      if req[:on_chunk] do
        case ReqLLM.stream_text(spec, ctx, opts) do
          {:ok, sr} ->
            tee =
              Stream.map(sr.stream, fn chunk ->
                case chunk.type do
                  :content -> if chunk.text not in [nil, ""], do: req.on_chunk.(chunk.text)
                  :thinking -> if req[:on_thinking] && chunk.text, do: req.on_thinking.(chunk.text)
                  _ -> :ok
                end

                chunk
              end)

            case ReqLLM.StreamResponse.to_response(%{sr | stream: tee}) do
              {:ok, resp} -> {:ok, Map.put(from_req_response(resp), "streamed", true)}
              {:error, e} -> {:error, err_msg(e)}
            end

          {:error, e} ->
            {:error, err_msg(e)}
        end
      else
        case ReqLLM.generate_text(spec, ctx, opts) do
          {:ok, resp} -> {:ok, from_req_response(resp)}
          {:error, e} -> {:error, err_msg(e)}
        end
      end
    end
  end

  # Provider routing by model name:
  #   "openrouter:<model>" | "openai:<model>" -> that provider
  #   anything else                           -> Anthropic
  def req_model_spec(model) do
    if String.contains?(model, ":"), do: model, else: "anthropic:" <> model
  end

  defp provider_of(spec), do: spec |> String.split(":", parts: 2) |> hd()

  @provider_keys %{
    "anthropic" => {"ANTHROPIC_API_KEY", :anthropic_api_key},
    "openai" => {"OPENAI_API_KEY", :openai_api_key},
    "openrouter" => {"OPENROUTER_API_KEY", :openrouter_api_key}
  }

  defp ensure_key(spec) do
    case @provider_keys[provider_of(spec)] do
      nil ->
        # an exotic provider spec: let req_llm's own key config handle it
        :ok

      {var, key} ->
        case Aimax.Core.Keys.get(var) do
          k when k in [nil, ""] ->
            {:error, "no #{var} (env, ~/.aimax/#{String.downcase(var)}, or doppler)"}

          k ->
            ReqLLM.put_key(key, k)
            :ok
        end
    end
  end

  defp req_opts(spec, tools) do
    base = [receive_timeout: 180_000, max_tokens: 4096]

    tools_opt =
      if tools == [], do: [], else: [tools: Enum.map(tools, &to_req_tool/1)]

    # cache breakpoints on tools, system, and the last message: chat resends
    # the whole transcript every turn and the tool loop resends it every
    # round — with the prefix cached, repeat input bills at the cache-read
    # rate (~10%) instead of full price
    cache_opt =
      if provider_of(spec) == "anthropic",
        do: [provider_options: [anthropic_prompt_cache: true, anthropic_cache_messages: true]],
        else: []

    # test seam: e.g. [req_http_options: [plug: ...]] to capture the exact
    # request req_llm builds. Merged, not appended — duplicate keys in a
    # keyword list resolve first-wins, which would silently drop it.
    extra = Application.get_env(:aimax_core, :llm_req_opts, [])

    Keyword.merge(base ++ tools_opt ++ cache_opt, extra, fn
      _k, a, b when is_list(a) and is_list(b) -> Keyword.merge(a, b)
      _k, _a, b -> b
    end)
  end

  # our tools never execute through req_llm (the loop dispatches into the
  # Scheme session itself) — the callback is a required-but-inert stub
  defp to_req_tool(%{name: name, description: description, input_schema: schema}) do
    {:ok, tool} =
      ReqLLM.Tool.new(
        name: name,
        description: description,
        parameter_schema: schema |> Jason.encode!() |> Jason.decode!(),
        callback: fn _args -> {:ok, ""} end
      )

    tool
  end

  # Anthropic-shaped loop messages -> ReqLLM.Context
  defp to_req_context(messages, system) do
    sys = if system, do: [ReqLLM.Context.system(system)], else: []
    ReqLLM.Context.new(sys ++ Enum.flat_map(messages, &to_req_msg/1))
  end

  defp to_req_msg(%{role: "assistant", content: blocks}) when is_list(blocks) do
    text =
      blocks |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", &(&1["text"] || ""))

    calls =
      for %{"type" => "tool_use"} = b <- blocks do
        ReqLLM.ToolCall.new(b["id"], b["name"], Jason.encode!(b["input"] || %{}))
      end

    if calls == [],
      do: [ReqLLM.Context.assistant(text)],
      else: [ReqLLM.Context.assistant(text, tool_calls: calls)]
  end

  defp to_req_msg(%{role: "user", content: blocks}) when is_list(blocks) do
    Enum.map(blocks, fn
      %{type: "tool_result", tool_use_id: id, content: c} ->
        ReqLLM.Context.tool_result(id, to_string(c))

      %{"type" => "tool_result", "tool_use_id" => id, "content" => c} ->
        ReqLLM.Context.tool_result(id, to_string(c))

      other ->
        ReqLLM.Context.user(inspect(other))
    end)
  end

  defp to_req_msg(%{role: "user", content: text}), do: [ReqLLM.Context.user(text)]
  defp to_req_msg(%{role: "assistant", content: text}), do: [ReqLLM.Context.assistant(text)]

  # ReqLLM.Response -> the loop's Anthropic shape
  defp from_req_response(resp) do
    text = ReqLLM.Response.text(resp) || ""
    calls = ReqLLM.Response.tool_calls(resp) || []

    blocks =
      if(text == "", do: [], else: [%{"type" => "text", "text" => text}]) ++
        for tc <- calls do
          %{
            "type" => "tool_use",
            "id" => tc.id,
            "name" => tc.function.name,
            "input" =>
              case Jason.decode(tc.function.arguments || "{}") do
                {:ok, m} when is_map(m) -> m
                _ -> %{}
              end
          }
        end

    %{
      "stop_reason" => if(calls == [], do: "end_turn", else: "tool_use"),
      "content" => blocks,
      "usage" => usage_strings(ReqLLM.Response.usage(resp))
    }
  end

  # req_llm usage (atom keys) -> the ledger's Anthropic field names.
  #
  # 'total_cost rides along because req_llm already priced this request
  # against its own model database, and it knows something we cannot see
  # from the token counts alone: whether the provider's input_tokens
  # ALREADY INCLUDES the cached tokens. OpenAI's does, Anthropic's does
  # not. Pricing the raw counts ourselves billed every cached OpenAI token
  # twice — once at the input rate, once at the cache rate.
  defp usage_strings(usage) when is_map(usage) do
    %{
      "input_tokens" => Map.get(usage, :input_tokens, 0),
      "output_tokens" => Map.get(usage, :output_tokens, 0),
      "cache_read_input_tokens" => Map.get(usage, :cached_tokens, 0),
      "cache_creation_input_tokens" => Map.get(usage, :cache_creation_tokens, 0)
    }
    |> maybe_put("cost", numeric(Map.get(usage, :total_cost)))
  end

  defp usage_strings(_), do: %{}

  defp numeric(n) when is_number(n), do: n
  defp numeric(_), do: nil

  defp err_msg(%{__exception__: true} = e), do: Exception.message(e)
  defp err_msg(other), do: inspect(other)

  @doc "Set the model for subsequent requests (scheme: set-llm-model!)."
  def set_model(model), do: :persistent_term.put(:aimax_llm_model, model)

  def model do
    case :persistent_term.get(:aimax_llm_model, nil) do
      nil -> Application.get_env(:aimax_core, :llm_model, "claude-sonnet-5")
      m -> m
    end
  end

  # the plain one-shot completion (the (llm ...) primitive)
  defp default_request(prompt) do
    spec = req_model_spec(model())

    with :ok <- ensure_key(spec) do
      case ReqLLM.generate_text(spec, prompt, req_opts(spec, [])) do
        {:ok, resp} ->
          Aimax.Core.LLMDb.record(model(), usage_strings(ReqLLM.Response.usage(resp)))
          {:ok, ReqLLM.Response.text(resp) || ""}

        {:error, e} ->
          {:error, err_msg(e)}
      end
    end
  end
end
