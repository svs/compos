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

  Model routing (`model/0` strings): `"openai:<m>"` / `"openrouter:<m>"` /
  `"deepseek:<m>"` route to those providers; a bare id is Anthropic. A
  provider key comes from Scheme: this module asks `key-get` for a name,
  and packages/keys.scm decides which source answers.

  Tool use (gptel-style, native): `complete_tools/6` runs the tool_use loop.
  Tool definitions and handlers live in the Scheme registry
  (packages/tools.scm, `define-tool!`); this module converts specs to JSON,
  drives the round-trips, and dispatches calls back into the session
  (`Session.call_fn` on the Scheme dispatcher closure).
  """

  alias Aimax.Core.Session

  @max_tool_rounds 25

  @doc "Synchronous request — for callers managing their own tasks."
  def request(prompt), do: run_request(prompt, model())

  @doc "Run FUN with a process-local provider key, without requiring a Scheme session."
  def with_provider_key(provider, key, fun)
      when is_binary(provider) and is_binary(key) and is_function(fun, 0) do
    slot = {__MODULE__, :provider_key, provider}
    previous = Process.get(slot)
    Process.put(slot, key)

    try do
      fun.()
    after
      if previous, do: Process.put(slot, previous), else: Process.delete(slot)
    end
  end

  def complete(prompt, callback) when is_function(callback, 1),
    do: complete(prompt, model(), callback)

  def complete(prompt, requested_model, callback)
      when is_binary(requested_model) and is_function(callback, 1) do
    {:ok, _} =
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        case run_request(prompt, requested_model) do
          {:ok, text} -> callback.(text)
          {:error, msg} -> Session.message("llm error: #{msg}")
        end
      end)

    :ok
  end

  # Tests and user integrations historically supplied a one-argument seam.
  # A two-argument seam can additionally observe/honor the buffer-local model.
  defp run_request(prompt, requested_model) do
    case Application.get_env(:aimax_core, :llm_request_fun) do
      nil -> default_request(prompt, requested_model)
      fun when is_function(fun, 1) -> fun.(prompt)
      fun when is_function(fun, 2) -> fun.(prompt, requested_model)
    end
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
          {:ok, text, usage, _stop} ->
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
  Anthropic-shaped; returns `{:ok, final_text, summed_usage, stop_reason}`.
  The stop reason is the provider's own: a reply cut off at the token limit
  says so instead of passing for a finished one.

  Event opts (all optional): `:on_chunk` / `:on_thinking` receive streamed
  text deltas (and, when the wire didn't stream, the whole final text);
  `:on_tool` receives `(id, name, input)` before a dispatch; `:on_tool_done`
  receives `(id, result)` after; `:gate` receives `(name, input)` before a
  dispatch and returns `:allow` or `{:deny, reason}` — the permission
  chokepoint every direct-lane tool call passes through. `:on_record`
  receives `(role, blocks)` for every message this loop appends to
  `messages` — the caller's conversation of record grows by exactly what
  went on the wire. `:on_round_usage` receives the running usage total
  after each round, so a turn that never returns can still be billed.
  `:model` overrides `model/0`.
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
      |> maybe_put(:reasoning_effort, opts[:reasoning_effort])

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

        usage = add_usage(usage, resp)
        report_usage(opts, usage)
        tool_loop(messages, system, tools, dispatcher, rounds + 1, usage, opts)

      {:ok, %{"content" => blocks} = resp} ->
        emit_unstreamed_text(resp, opts)
        record(opts, "assistant", blocks)
        usage = add_usage(usage, resp)
        report_usage(opts, usage)
        {:ok, Enum.map_join(blocks, "", &(&1["text"] || "")), usage, stop_of(resp)}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp stop_of(%{"stop_reason" => r}) when is_binary(r), do: r
  defp stop_of(_), do: "end_turn"

  # The running total, after every round. A turn that is cancelled or that
  # dies mid-loop still spent what it spent: the caller holds this figure
  # and can bill it even though no result ever came back.
  defp report_usage(%{on_round_usage: f}, usage) when is_function(f, 1), do: f.(usage)
  defp report_usage(_opts, _usage), do: :ok

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
    do:
      Map.merge(acc, usage, fn _k, a, b ->
        if is_number(a) and is_number(b), do: a + b, else: b
      end)

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

    with {:ok, key_opts_list} <- key_opts(spec) do
      ctx = to_req_context(messages, system)
      opts = key_opts_list ++ req_opts(spec, tools)

      opts =
        if req[:reasoning_effort],
          do: Keyword.put(opts, :reasoning_effort, req.reasoning_effort),
          else: opts

      if req[:on_chunk] do
        # only the call that STARTS the stream retries: once a delta has
        # reached the renderer, a second attempt would print the reply twice
        case with_retry(fn -> ReqLLM.stream_text(spec, ctx, opts) end) do
          {:ok, sr} ->
            tee =
              Stream.map(sr.stream, fn chunk ->
                case chunk.type do
                  :content ->
                    if chunk.text not in [nil, ""], do: req.on_chunk.(chunk.text)

                  :thinking ->
                    if req[:on_thinking] && chunk.text, do: req.on_thinking.(chunk.text)

                  _ ->
                    :ok
                end

                chunk
              end)

            case ReqLLM.StreamResponse.to_response(%{sr | stream: tee}) do
              {:ok, resp} -> {:ok, Map.put(from_req_response(resp, spec), "streamed", true)}
              {:error, e} -> {:error, err_msg(e)}
            end

          {:error, e} ->
            {:error, err_msg(e)}
        end
      else
        case with_retry(fn -> ReqLLM.generate_text(spec, ctx, opts) end) do
          {:ok, resp} -> {:ok, from_req_response(resp, spec)}
          {:error, e} -> {:error, err_msg(e)}
        end
      end
    end
  end

  # 500 and 529 are the provider saying "not now". req_llm retries transport
  # errors and 429; it does not retry these, so the user did — by resending
  # a whole uncached transcript, which is the most expensive gesture in the
  # editor. Three tries, jittered, then the error stands.
  @retry_max 3

  defp with_retry(fun, attempt \\ 1) do
    case fun.() do
      {:error, e} = err ->
        if attempt < @retry_max and retryable?(e) do
          Process.sleep(backoff_ms(attempt))
          with_retry(fun, attempt + 1)
        else
          err
        end

      ok ->
        ok
    end
  end

  @retry_statuses [500, 502, 503, 529]

  # req_llm reports the status as an integer on one error struct and as a
  # string on another, and wraps a provider error inside a request error —
  # so look at the whole chain rather than one field's declared type
  defp retryable?(%{status: status}) when status in @retry_statuses, do: true

  defp retryable?(%{status: status}) when is_binary(status) do
    case Integer.parse(status) do
      {n, _} -> n in @retry_statuses
      :error -> false
    end
  end

  defp retryable?(%{reason: reason}) when is_map(reason), do: retryable?(reason)
  defp retryable?(_), do: false

  # 500ms, then 1s, each plus up to half its own width — two clients hitting
  # the same overloaded provider must not march in step
  defp backoff_ms(attempt) do
    base = Application.get_env(:aimax_core, :llm_retry_base_ms, 500) * Integer.pow(2, attempt - 1)
    base + :rand.uniform(max(div(base, 2), 1))
  end

  # Provider routing by model name: "provider:<model>" passes through to that
  # provider; a bare id is Anthropic. The provider set is not enumerated here
  # — req_llm owns the providers, Scheme owns the keys.
  def req_model_spec(model) do
    if String.contains?(model, ":"), do: model, else: "anthropic:" <> model
  end

  defp provider_of(spec), do: spec |> String.split(":", parts: 2) |> hd()

  # Hand the resolved key VALUE to req_llm as a per-request :api_key option.
  # Elixir asks Scheme for the value BY PROVIDER ((llm-key "deepseek")); the
  # provider -> key association is explicit Scheme config, so there is no
  # provider -> secret-name convention anywhere in Elixir. A process-dict
  # override (the catalog backfill task's with_provider_key) still wins,
  # keyed by provider — and because it short-circuits, that task needs no
  # running Session. No key anywhere is an error, not a silent env fallback.
  defp key_opts(spec) do
    provider = provider_of(spec)

    key =
      Process.get({__MODULE__, :provider_key, provider}) ||
        case Session.call_named("llm-key", [provider]) do
          {:ok, k} when is_binary(k) and k != "" -> k
          _ -> nil
        end

    case key do
      k when is_binary(k) and k != "" -> {:ok, [api_key: k]}
      _ -> {:error, "no api key provided for #{provider}"}
    end
  end

  defp req_opts(spec, tools) do
    base = [receive_timeout: 180_000, max_tokens: max_tokens(spec)]

    tools_opt =
      if tools == [], do: [], else: [tools: Enum.map(tools, &to_req_tool/1)]

    # cache breakpoints on tools, system, and the last message: chat resends
    # the whole transcript every turn and the tool loop resends it every
    # round — with the prefix cached, repeat input bills at the cache-read
    # rate (~10%) instead of full price. The TTL buys the gap between two
    # messages in one sitting: the default five minutes expires while the
    # user reads the reply, and the next turn pays the write again.
    cache_opt =
      if anthropic_cached?(spec),
        do: [
          provider_options: [
            anthropic_prompt_cache: true,
            anthropic_cache_messages: true,
            anthropic_prompt_cache_ttl: cache_ttl()
          ]
        ],
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

  # Anthropic's cache is Anthropic's whether the request goes direct or
  # through OpenRouter — the gate used to read the provider prefix alone,
  # so every openrouter:anthropic/* chat paid full price for a prefix the
  # model would have cached.
  defp anthropic_cached?(spec) do
    case String.split(spec, ":", parts: 2) do
      ["anthropic", _] -> true
      ["openrouter", model] -> String.starts_with?(model, "anthropic/")
      _ -> false
    end
  end

  @doc """
  How long the provider holds a cached prefix. Scheme owns the policy
  (defcustom `llm-cache-ttl`); this is where the value lands.
  """
  def set_cache_ttl(ttl) when is_binary(ttl), do: :persistent_term.put(:aimax_llm_cache_ttl, ttl)

  defp cache_ttl, do: :persistent_term.get(:aimax_llm_cache_ttl, "1h")

  # The model's own output limit, from the models.dev catalog. A flat 4096
  # truncated long replies on models that allow far more, and a length stop
  # reported itself as a clean end_turn — the reply just stopped.
  defp max_tokens(spec) do
    Application.get_env(:aimax_core, :llm_max_tokens) || Aimax.Core.LLMDb.max_tokens(spec) || 4096
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
  defp from_req_response(resp, spec) do
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
      "stop_reason" => stop_reason(resp, calls),
      "content" => blocks,
      "usage" => usage_strings(ReqLLM.Response.usage(resp), spec)
    }
  end

  # The provider's own finish reason, not a guess from the block list. A
  # reply cut off at the token limit used to arrive as "end_turn": the
  # transcript showed a sentence stopping mid-word and said nothing.
  defp stop_reason(resp, calls) do
    case Map.get(resp, :finish_reason) do
      :length -> "max_tokens"
      :content_filter -> "content_filter"
      _ when calls != [] -> "tool_use"
      _ -> "end_turn"
    end
  end

  # req_llm usage (atom keys) -> the ledger's Anthropic field names.
  #
  # Two usage shapes arrive here. Anthropic reports input_tokens WITHOUT
  # the cached tokens. OpenAI, and every provider that copies its shape,
  # reports them INSIDE input_tokens. A ledger that mixes the two cannot
  # state a cache hit rate: the editor read 47% where the true figure was
  # 92%, because the cached tokens sat in both terms of the fraction.
  #
  # So "input_tokens" means FRESH input on every lane, normalized here —
  # the one place that still knows which provider answered.
  #
  # 'total_cost rides along because req_llm already priced this request
  # against its own model database, from the provider's raw numbers. It
  # remains the accurate figure; the fallback in LLMDb prices these
  # normalized counts, and now it agrees.
  @doc """
  req_llm usage + a model spec -> the ledger's field names, with
  `"input_tokens"` normalized to fresh input. Public because it is the
  seam the ledger's arithmetic depends on, and the `:llm_chat_fun` test
  stub bypasses the wire that calls it.
  """
  def usage_strings(usage, spec) when is_map(usage) do
    input = Map.get(usage, :input_tokens, 0)
    cached = Map.get(usage, :cached_tokens, 0)

    %{
      "input_tokens" => if(cached_inside_input?(spec), do: max(input - cached, 0), else: input),
      "output_tokens" => Map.get(usage, :output_tokens, 0),
      "cache_read_input_tokens" => cached,
      "cache_creation_input_tokens" => Map.get(usage, :cache_creation_tokens, 0)
    }
    |> maybe_put("cost", numeric(Map.get(usage, :total_cost)))
  end

  def usage_strings(_, _), do: %{}

  # Anthropic's own API is the exception: it counts cached tokens beside
  # the input, not inside it. openrouter speaks the OpenAI usage shape
  # whatever model sits behind it.
  defp cached_inside_input?(spec), do: provider_of(spec) != "anthropic"

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
  defp default_request(prompt, requested_model) do
    spec = req_model_spec(requested_model)

    with {:ok, key_opts_list} <- key_opts(spec) do
      opts = key_opts_list ++ req_opts(spec, [])

      case with_retry(fn -> ReqLLM.generate_text(spec, prompt, opts) end) do
        {:ok, resp} ->
          Aimax.Core.LLMDb.record(
            requested_model,
            usage_strings(ReqLLM.Response.usage(resp), spec)
          )

          {:ok, ReqLLM.Response.text(resp) || ""}

        {:error, e} ->
          {:error, err_msg(e)}
      end
    end
  end
end
