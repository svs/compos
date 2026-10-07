defmodule Compos.Core.SchemeAPI do
  @moduledoc """
  The complete primitive surface exposed to Scheme. Deliberately small: raw
  buffer/point mutations, window-tree mutations, minibuffer activation, keymap
  table entry, kill-ring access. Everything with *policy* — what C-k kills,
  what find-file prompts, what M-x lists — is Scheme (priv/editor.scm).

  Conventions: predicates `?`, mutators `!`.
  """

  alias Compos.Core
  alias Compos.Scheme.Prim
  alias Compos.Core.{Buffer, Editor, Git}

  @commands :compos_commands

  alias Compos.Core.Roots

  def commands_table, do: @commands

  def primitives, do: Prim.funs(entries())

  @doc "Every primitive under its {name, doc} key, raw names included."
  def entries do
    buffer_primitives()
    |> Map.merge(editor_primitives())
    |> Map.merge(git_primitives())
    |> Map.merge(watch_primitives())
    |> Map.merge(telemetry_primitives())
    |> Map.merge(event_log_primitives())
    |> Map.merge(workflow_primitives())
    |> Map.merge(sysmon_primitives())
    |> Map.merge(profiler_primitives())
    |> Map.merge(discovery_primitives())
    |> Map.merge(irc_primitives())
    |> Map.merge(google_primitives())
    |> Map.merge(http_primitives())
    |> Map.merge(Compos.Core.Cron.primitives())
    |> Compos.Core.SchemeRawNames.add()
  end

  # A buffer that cannot start is a Scheme error that names it, never a
  # fresh empty buffer under its name.
  defp started!({:error, {:unrestorable, name, reason}}),
    do: raise(Buffer.Unrestorable, name: name, reason: reason)

  defp started!(_), do: :ok

  # one whole-buffer rewrite: five packages wrote create, unlock, clear,
  # append, relock around every render
  defp set_text(name, text) do
    unless Buffer.exists?(name), do: Compos.Core.create_buffer(name)
    :ok = Buffer.replace_range(name, 0, Buffer.byte_size(name), text, source: :editor)
  end

  defp google_primitives do
    convert = &Compos.Core.LLM.json_to_scheme/1

    %{
      {"google-oauth-start!",
       "(google-oauth-start! CLIENT SCOPES) — start native desktop OAuth using a client JSON file or installed-client record."} =>
        fn [path, scopes] ->
          convert.(Compos.Core.Google.connect(Compos.Core.Session.scheme_to_json(path), scopes))
        end,
      {"google-oauth-status",
       "(google-oauth-status) — current OAuth progress without credentials."} => fn [] ->
        convert.(Compos.Core.Google.status())
      end,
      {"google-accounts",
       "(google-accounts) — connected account subjects, emails, and scopes; never tokens."} =>
        fn [] -> convert.(Compos.Core.Google.accounts()) end,
      {"google-http!",
       "(google-http! ACCOUNT METHOD URL PARAMS BODY [CALLBACK]) — authenticated Google HTTP request with an explicit account."} =>
        fn
          [account, url, request_json, callback] ->
            async_dispatch(callback, fn ->
              convert.(Compos.Core.Google.request_json(account, url, request_json))
            end)

          [account, method, url, params, body | rest] ->
            params = Compos.Core.Session.scheme_to_json(params)
            body = Compos.Core.Session.scheme_to_json(body)

            work = fn ->
              convert.(Compos.Core.Google.request(account, method, url, params, body))
            end

            case rest do
              [] -> work.()
              [callback] -> async_dispatch(callback, work)
            end
        end,
      {"google-revoke!",
       "(google-revoke! ACCOUNT CALLBACK) — revoke and remove one Google account connection."} =>
        fn [account, callback] ->
          async_dispatch(callback, fn -> convert.(Compos.Core.Google.disconnect(account)) end)
        end
    }
  end

  # Every HTTP request in the editor is its own curl command line.
  # graphql.scm, sentry.scm, feeds.scm, notmuch.scm and package.scm each
  # wrote their own quoting, their own timeout, and their own way of digging
  # the status code out of the output. This is one door instead, through Req,
  # which is already a dependency. No shell means no quoting to get wrong and
  # no token in a command line, so a header can carry a secret directly.
  # Those five still shell out: they move over one at a time.
  #
  # Scheme asks in a plist and reads a plist back:
  #
  #   (http-request "https://api.example.com/v1/people"
  #                 '(method "POST" headers (authorization "Bearer t")
  #                   json (name "ada")))
  #   => (ok #t status 201 headers (content-type "application/json")
  #       body "{...}" json (id 7))
  #
  # Without a callback this holds the calling lane, like the inline form of
  # shell-command->string, and carries the same short limit for the same
  # reason: the caller is often the Session. With a callback the request
  # runs in a Task and may wait much longer.
  defp http_primitives do
    %{
      {"http-request",
       "(http-request URL [OPTS] [CALLBACK]) — make one HTTP request and return (ok BOOL status N headers PLIST body STRING [json VALUE] [error TEXT]). OPTS is a plist of method, headers, params, body, json, form, timeout, connect-timeout, redirect and max-bytes. Without CALLBACK it holds the lane for up to 15 seconds; with CALLBACK it runs in a Task and CALLBACK gets the answer."} =>
        fn
          [url] ->
            http_call(url, [], http_inline_limit())

          [url, opts] ->
            if is_list(opts) or opts == false do
              http_call(url, opts, http_inline_limit())
            else
              async_dispatch(opts, fn -> http_call(url, [], http_async_limit()) end)
            end

          [url, opts, callback] ->
            async_dispatch(callback, fn -> http_call(url, opts, http_async_limit()) end)
        end
    }
  end

  @http_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp http_call(url, opts, limit) do
    o = http_opts(opts)

    with {:ok, url} <- http_url(url),
         {:ok, method} <- http_method(o) do
      http_send(method, url, o, http_json_body(opts), limit)
    else
      {:error, message} -> http_failure(message)
    end
  end

  defp http_opts(opts) when is_list(opts) do
    case Compos.Core.Plist.to_json(opts) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp http_opts(_), do: %{}

  # #f in a JSON body means null, not the boolean false, so the body is
  # converted on its own. Everywhere else in OPTS, #f means off.
  defp http_json_body(opts) when is_list(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [{:sym, "json"}, value] -> {:ok, Compos.Core.Plist.to_json(value, :null)}
      _ -> nil
    end)
  end

  defp http_json_body(_), do: nil

  # A relative URL has nowhere to go, and a scheme we do not speak reaches a
  # different part of Req entirely: say so here instead of raising there.
  defp http_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, url}

      _ ->
        {:error, "Use an absolute http:// or https:// URL: " <> url}
    end
  end

  defp http_url(_), do: {:error, "The URL must be a string."}

  defp http_method(o) do
    name =
      case Map.get(o, "method") do
        value when value in [nil, false, ""] -> "get"
        value -> value |> to_string() |> String.downcase()
      end

    case Map.fetch(@http_methods, name) do
      {:ok, verb} -> {:ok, verb}
      :error -> {:error, "Unsupported HTTP method: " <> name}
    end
  end

  defp http_send(method, url, o, json, limit) do
    req =
      [
        method: method,
        url: url,
        decode_body: false,
        retry: false,
        redirect: Map.get(o, "redirect", true) != false,
        receive_timeout: http_limit(Map.get(o, "timeout"), limit),
        connect_options: [timeout: http_limit(Map.get(o, "connect-timeout"), 10_000)]
      ]
      |> http_option(:headers, http_pairs(Map.get(o, "headers")))
      |> http_option(:params, http_pairs(Map.get(o, "params")))
      |> http_body(o, json)

    case http_perform(req) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        http_reply(status, headers, body, o)

      other ->
        http_failure(http_reason(other))
    end
  rescue
    e -> http_failure(http_reason(e))
  end

  defp http_option(req, _key, []), do: req
  defp http_option(req, key, value), do: Keyword.put(req, key, value)

  # Scheme writes a header set as a plist, (authorization "Bearer t"), and as
  # a list of pairs when a name is not a symbol: (("X-Trace-Id" "7")).
  defp http_pairs(map) when is_map(map),
    do: for({key, value} <- map, do: {to_string(key), http_scalar(value)})

  defp http_pairs(list) when is_list(list) do
    Enum.flat_map(list, fn
      [key, value] -> [{to_string(key), http_scalar(value)}]
      {key, value} -> [{to_string(key), http_scalar(value)}]
      _ -> []
    end)
  end

  defp http_pairs(_), do: []

  defp http_scalar(value) when is_binary(value), do: value
  defp http_scalar(value) when is_number(value), do: to_string(value)
  defp http_scalar(value) when is_boolean(value), do: to_string(value)
  defp http_scalar(value), do: value

  # Three ways to say what to send, tried in the order a caller means them:
  # json encodes and sets the content type, form url-encodes, body is the
  # bytes verbatim.
  defp http_body(req, o, json) do
    cond do
      match?({:ok, _}, json) ->
        {:ok, value} = json
        Keyword.put(req, :json, value)

      Map.get(o, "form", false) != false ->
        Keyword.put(req, :form, http_pairs(Map.get(o, "form")))

      is_binary(Map.get(o, "body")) ->
        Keyword.put(req, :body, Map.get(o, "body"))

      true ->
        req
    end
  end

  # The seam lets a test answer a request with no network, the way
  # :google_http does for Google.
  defp http_perform(req) do
    case Application.get_env(:compos_core, :http_request) do
      nil -> Req.request(req)
      adapter -> adapter.(req)
    end
  end

  # One shape for every answer, reached or not. graphql.scm had to tell a
  # transport failure from an HTTP status by whether the last line of curl's
  # output parsed as a number; a caller here reads ok, then status.
  defp http_reply(status, headers, body, o) do
    body = if is_binary(body), do: body, else: IO.iodata_to_binary(body)
    {body, truncated?} = http_truncate(body, Map.get(o, "max-bytes"))

    reply = %{
      "ok" => status in 200..299,
      "status" => status,
      "headers" => http_reply_headers(headers),
      "body" => body
    }

    reply = if truncated?, do: Map.put(reply, "truncated", true), else: reply

    # The body stays the bytes that arrived. A JSON answer is parsed as well,
    # under its own key, so no caller parses it a second time.
    reply =
      case Jason.decode(body) do
        {:ok, value} when is_map(value) or is_list(value) -> Map.put(reply, "json", value)
        _ -> reply
      end

    Compos.Core.LLM.json_to_scheme(reply)
  end

  defp http_reply_headers(headers) when is_map(headers) or is_list(headers) do
    Map.new(headers, fn {name, value} -> {to_string(name), http_header_value(value)} end)
  rescue
    _ -> %{}
  end

  defp http_reply_headers(_), do: %{}

  defp http_header_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp http_header_value(value), do: to_string(value)

  # max-bytes counts bytes, not characters: the point is a ceiling on what a
  # buffer has to hold when a URL answers with a gigabyte.
  defp http_truncate(body, max) when is_integer(max) and max > 0 and byte_size(body) > max,
    do: {binary_part(body, 0, max), true}

  defp http_truncate(body, _max), do: {body, false}

  defp http_failure(message) do
    Compos.Core.LLM.json_to_scheme(%{
      "ok" => false,
      "status" => false,
      "headers" => %{},
      "body" => "",
      "error" => message
    })
  end

  defp http_reason(%{__exception__: true} = e), do: Exception.message(e)
  defp http_reason({:error, reason}), do: http_reason(reason)
  defp http_reason(reason) when is_atom(reason), do: "the request failed: " <> to_string(reason)
  defp http_reason(reason), do: "the request failed: " <> inspect(reason)

  defp http_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp http_limit(_value, default), do: default

  defp http_inline_limit, do: Application.get_env(:compos_core, :http_timeout_ms, 15_000)

  defp http_async_limit, do: Application.get_env(:compos_core, :http_async_timeout_ms, 120_000)

  @doc "One-line doc for every primitive: signature, then an em dash, then one sentence."
  def docs, do: Prim.docs(entries())

  # The durable event log (Compos.Core.Events.Log). events.scm wraps these
  # in event-publish!, event-subscribe! and the views; nothing else should
  # need them.
  defp event_log_primitives do
    alias Compos.Core.Events.Log

    %{
      {"event-log-append!",
       "(event-log-append! TOPIC KIND DATA) — write one event to the durable log and return its seq. Use event-publish!."} =>
        fn [topic, kind, data] -> Log.append(topic, kind, data) end,
      {"event-log-read",
       "(event-log-read AFTER PATTERN LIMIT) — at most LIMIT events after seq AFTER whose topic PATTERN matches (#f: every topic), oldest first."} =>
        fn [after_seq, pattern, limit] ->
          Log.read(trunc(after_seq || 0), pattern, trunc(limit)) |> Enum.map(&event_plist/1)
        end,
      {"event-log-newest",
       "(event-log-newest PATTERN LIMIT) — at most LIMIT events whose topic PATTERN matches (#f: every topic), newest first."} =>
        fn [pattern, limit] -> Log.newest(pattern, trunc(limit)) |> Enum.map(&event_plist/1) end,
      {"event-log-seq", "(event-log-seq) — the seq of the newest event in the durable log, or 0."} =>
        fn [] -> Log.seq() end,
      {"event-log-position",
       "(event-log-position NAME) — the saved seq of the subscriber NAME, or #f."} =>
        fn [name] -> Log.position(name) || false end,
      {"event-log-position-set!",
       "(event-log-position-set! NAME SEQ) — save the seq of the last event the subscriber NAME took."} =>
        fn [name, seq] ->
          :ok = Log.set_position(name, trunc(seq))
          :void
        end,
      {"event-log-forget!", "(event-log-forget! NAME) — drop the saved position of NAME."} =>
        fn [name] ->
          :ok = Log.forget(name)
          :void
        end,
      {"event-log-import!",
       "(event-log-import! EVENTS POSITIONS) — load EVENTS, plists with seq topic kind data at, and POSITIONS, an alist of name and seq, into an empty log; return how many events went in."} =>
        fn [events, positions] ->
          events =
            for e <- events do
              m = plist_map(e)
              %{seq: m["seq"], topic: m["topic"], kind: m["kind"], data: m["data"], at: m["at"] || 0}
            end

          positions = for [name | seq] <- positions, do: {name, pos_seq(seq)}
          Log.import(events, positions)
        end
    }
  end

  # Workflows (Compos.Core.Workflow): supervised consumers of the log whose
  # handlers are Scheme. workflows.scm wraps these in define-workflow!,
  # emit! and once!. Inside a workflow's batch, emit! and once! collect in
  # the lane process instead of writing, and the batch commits them with
  # its new position in one transaction.
  defp workflow_primitives do
    alias Compos.Core.{Workflow, Workflows}
    alias Compos.Core.Events.Log

    %{
      {"workflow-define!",
       "(workflow-define! NAME SPEC) — start or reconfigure the workflow NAME. SPEC is a plist: listen (patterns), quiet-ms, max-wait-ms, batch, max-attempts, backoff-ms, max-backoff-ms, timeout-ms, from."} =>
        fn [name, spec] ->
          m = plist_map(spec)

          opts =
            for {key, field} <- [
                  {"quiet-ms", :quiet_ms},
                  {"max-wait-ms", :max_wait_ms},
                  {"batch", :batch},
                  {"max-attempts", :max_attempts},
                  {"backoff-ms", :backoff_ms},
                  {"max-backoff-ms", :max_backoff_ms},
                  {"timeout-ms", :timeout_ms},
                  {"from", :from}
                ],
                is_number(m[key]),
                into: %{},
                do: {field, trunc(m[key])}

          case Workflows.define(Map.merge(opts, %{name: name, listen: m["listen"] || []})) do
            :ok -> true
            {:error, reason} -> raise "workflow-define!: " <> to_string(reason)
          end
        end,
      {"workflow-stop!", "(workflow-stop! NAME) — stop the workflow NAME; its position stays."} =>
        fn [name] ->
          Workflows.stop(name)
          :void
        end,
      {"workflow-pause!", "(workflow-pause! NAME) — pause NAME after the batch it runs, if any."} =>
        fn [name] -> Workflow.pause(name) == :ok end,
      {"workflow-resume!", "(workflow-resume! NAME) — let NAME run again."} =>
        fn [name] -> Workflow.resume(name) == :ok end,
      {"workflow-step!", "(workflow-step! NAME) — run one batch of NAME, then pause it."} =>
        fn [name] -> Workflow.step(name) == :ok end,
      {"workflow-rewind!", "(workflow-rewind! NAME SEQ) — move NAME back to SEQ; it takes every event after SEQ again."} =>
        fn [name, seq] -> Workflow.rewind(name, trunc(seq)) == :ok end,
      {"workflow-status",
       "(workflow-status NAME) — a plist: status, position, head, behind, runs, handled, failed, parked, attempts, last-error, running-ms; #f when NAME does not run."} =>
        fn [name] ->
          case Workflow.status(name) do
            %{} = s -> Compos.Core.Events.scheme(s)
            _ -> false
          end
        end,
      {"workflow-names", "(workflow-names) — the names of the running workflows."} =>
        fn [] -> Workflows.names() end,
      {"workflow-in-batch?", "(workflow-in-batch?) — #t inside a workflow's batch, where emit! and once! wait for the commit."} =>
        fn [] -> Process.get(:compos_workflow_txn) != nil end,
      {"workflow-emit!",
       "(workflow-emit! TOPIC KIND DATA) — write an event: now, answering its seq, or inside a batch at its commit, answering #f."} =>
        fn [topic, kind, data] ->
          case Process.get(:compos_workflow_txn) do
            nil ->
              Log.append(topic, kind, data)

            txn ->
              Process.put(:compos_workflow_txn, %{txn | emits: [{topic, kind, data} | txn.emits]})
              false
          end
        end,
      {"workflow-once",
       "(workflow-once KEY) — (VALUE) when once! has recorded KEY, in the log or in this batch, else #f."} =>
        fn [key] ->
          pending =
            case Process.get(:compos_workflow_txn) do
              nil -> nil
              txn -> List.keyfind(txn.onces, key, 0)
            end

          case pending do
            {_, value} ->
              [value]

            nil ->
              case Log.once(key) do
                {:ok, value} -> [value]
                :none -> false
              end
          end
        end,
      {"workflow-once-record!",
       "(workflow-once-record! KEY VALUE) — record VALUE under KEY: now, or inside a batch at its commit."} =>
        fn [key, value] ->
          case Process.get(:compos_workflow_txn) do
            nil ->
              Log.put_once(key, value)

            txn ->
              Process.put(:compos_workflow_txn, %{txn | onces: [{key, value} | txn.onces]})
              value
          end
        end
    }
  end

  defp event_plist(e) do
    [{:sym, "seq"}, e.seq, {:sym, "topic"}, e.topic, {:sym, "kind"}, e.kind, {:sym, "data"},
     e.data, {:sym, "at"}, e.at]
  end

  defp plist_map(plist) do
    plist
    |> Enum.chunk_every(2)
    |> Map.new(fn
      [{:sym, k}, v] -> {k, v}
      [k, v] -> {k, v}
    end)
  end

  # an alist pair (name . seq) reads as [name | seq]; (name seq) as [name, seq]
  defp pos_seq([seq]), do: seq
  defp pos_seq(seq), do: seq

  defp telemetry_primitives do
    %{
      {"telemetry-snapshot",
       "(telemetry-snapshot [LIMIT]) — return recent telemetry events of every layer, newest first."} =>
        fn
          [] -> telemetry_events(200)
          [limit] -> telemetry_events(trunc(limit))
        end,
      {"telemetry-clear!", "(telemetry-clear!) — discard retained telemetry events."} => fn [] ->
        :ok = Compos.Core.Telemetry.clear()
        :void
      end,
      {"llm-catalog-info",
       "(llm-catalog-info) — the loaded model catalog: snapshot-id, captured-at, models, providers, stale-days, path."} =>
        fn [] -> catalog_plist(Compos.Core.ModelCatalog.snapshot_info()) end,
      {"llm-catalog-install!",
       "(llm-catalog-install! CALLBACK) — fetch the newest published model catalog, keep it, and load it. The callback gets one list: ok and then either the catalog info or an error message. It runs off the lane, being a network fetch of several megabytes."} =>
        fn [callback] ->
          async_dispatch(callback, fn ->
            case Compos.Core.ModelCatalog.refresh() do
              {:ok, info} -> [true, catalog_plist(info)]
              {:error, msg} -> [false, to_string(msg)]
            end
          end)
        end,
      {"telemetry-reattach!",
       "(telemetry-reattach!) — attach the collector's handler again. A reload that adds an event needs this: the running collector attached the list it started with."} =>
        fn [] ->
          :ok = Compos.Core.Telemetry.reattach()
          :void
        end
    }
  end

  defp sysmon_primitives do
    alias Compos.Core.SysMon

    %{
      {"vm-sample",
       "(vm-sample) — one plist of VM and host counters: scheduler utilization, memory, rates since the previous sample, os_mon load, memory and disks."} =>
        fn [] -> SysMon.sample() end,
      {"vm-processes",
       "(vm-processes LIMIT SORT FILTER) — plist (rows count matched): at most LIMIT process rows whose name or pid contains FILTER, sorted by \"reds\", \"memory\", \"queue\" or \"name\"."} =>
        fn
          [limit, sort, filter] ->
            SysMon.processes(trunc(limit), sysmon_text(sort), sysmon_text(filter))

          [limit, sort] ->
            SysMon.processes(trunc(limit), sysmon_text(sort), "")

          [limit] ->
            SysMon.processes(trunc(limit), "reds", "")
        end,
      {"vm-process-info",
       "(vm-process-info PID) — a plist of one process's state, or #f when the pid is gone."} =>
        fn [pid] -> SysMon.process_info(sysmon_text(pid)) end,
      {"vm-process-kill!",
       "(vm-process-kill! PID) — exit the process with reason kill; #t when it was alive."} =>
        fn [pid] -> SysMon.kill(sysmon_text(pid)) end
    }
  end

  defp sysmon_text(v) when is_binary(v), do: v
  defp sysmon_text({:sym, v}), do: v
  defp sysmon_text(false), do: ""
  defp sysmon_text(v), do: to_string(v)

  defp profiler_primitives do
    alias Compos.Core.Profiler

    %{
      {"profile-start!",
       "(profile-start! [PREFIXES]) — arm the call_time tracer over every loaded module whose name starts with one of PREFIXES (default \"Elixir.Compos.\"), and take the before snapshot of the processes and the VM."} =>
        fn
          [] -> Profiler.start()
          [prefixes] -> Profiler.start(profiler_prefixes(prefixes))
        end,
      {"profile-stop",
       "(profile-stop) — disarm and answer one profile as a plist: wall-us, at-ms, the hot functions, the busy processes, and the VM deltas; #f when nothing was armed."} =>
        fn [] -> Profiler.stop() end,
      {"profile-cancel!",
       "(profile-cancel!) — disarm the tracer and forget the snapshot; #t when a profile was armed."} =>
        fn [] -> Profiler.cancel() end
    }
  end

  defp profiler_prefixes(list) when is_list(list), do: Enum.map(list, &sysmon_text/1)
  defp profiler_prefixes(v), do: [sysmon_text(v)]

  defp telemetry_events(limit) do
    limit = max(0, min(limit, 1_000))

    Compos.Core.Telemetry.events(limit)
    |> Enum.map(fn event ->
      [
        {:sym, "kind"},
        event.kind,
        {:sym, "time-ms"},
        event.time_ms,
        {:sym, "duration-ms"},
        event.duration_ms,
        {:sym, "queue-ms"},
        event.queue_ms,
        {:sym, "backlog"},
        event.backlog,
        {:sym, "owner"},
        event.owner,
        {:sym, "label"},
        event.label,
        {:sym, "status"},
        event.status,
        {:sym, "layer"},
        Map.get(event, :layer, "scheme"),
        {:sym, "tid"},
        Map.get(event, :tid) || false,
        {:sym, "detail"},
        Map.get(event, :detail, "")
      ]
    end)
  end

  defp buffer_primitives do
    %{
      {"buffer-create",
       "(buffer-create NAME) — create an empty buffer NAME and return NAME. A NAME that is a file on disk loads that file instead."} =>
        fn [name] ->
          Core.create_buffer(name)
          name
        end,
      {"buffer-list", "(buffer-list) — return the names of all buffers."} => fn [] ->
        Core.list_buffers()
      end,
      {"buffer-list-mru",
       "(buffer-list-mru) — return buffer names in most-recently-used order, without internal buffers."} =>
        fn [] -> Editor.buffer_mru() end,
      {"buffer-bury!", "(buffer-bury! BUF) — move BUF to the end of the buffer list."} => fn [buf] ->
        Editor.mru_bury(Compos.Core.Prims.s(buf))
        :void
      end,
      {"window-prev-buffers",
       "(window-prev-buffers [ID]) — return the window's previous buffers, most recent first."} =>
        fn
          [] -> Editor.window_buffer_history()
          [id] -> Editor.window_buffer_history(id)
        end,
      {"set-window-prev-buffers!",
       "(set-window-prev-buffers! ID PREV) — replace the window's previous buffers with PREV, most recent first."} =>
        fn [id, history] when is_list(history) ->
          Editor.set_window_history(id, history)
        end,
      # the whole history: ("buffer" NAME) and ("group" NAME) rows in
      # recency order — a group switch is an entry like a buffer visit
      {"mru-list",
       "(mru-list) — return (\"buffer\" NAME) and (\"group\" NAME) rows: the whole history in recency order."} =>
        fn [] -> Editor.mru_all() end,
      {"mru-note-group!", "(mru-note-group! NAME) — record a group switch as a history entry."} =>
        fn [g] ->
          Editor.mru_note_group(g)
          :void
        end,
      {"buffer-exists?", "(buffer-exists? NAME) — return #t if the buffer NAME exists."} => fn [
                                                                                                 name
                                                                                               ] ->
        Buffer.exists?(name)
      end,
      {"buffer-ref",
       "(buffer-ref BUF) — return an immutable buffer handle for local reads and writes across renames, or #f if unknown."} =>
        fn [name] -> Buffer.ref(name) || false end,
      # the buffer list names dormant buffers too: they hold a checkpoint
      # and no process. A verb asks this, not exists?, or it refuses to act
      # on the rows it shows.
      {"buffer-known?",
       "(buffer-known? NAME) — return #t if the buffer NAME is live OR dormant in the store; a dormant buffer wakes when you visit or edit it."} =>
        fn [name] ->
          Buffer.exists?(name) or Compos.Core.BufferStore.known?(name)
        end,
      {"buffer-text", "(buffer-text BUF) — return the buffer's whole text as a string."} => fn [
                                                                                                 name
                                                                                               ] ->
        Buffer.text(name)
      end,
      {"buffer-size", "(buffer-size BUF) — return the buffer's size in bytes."} => fn [name] ->
        Buffer.byte_size(name)
      end,
      {"buffer-modified?",
       "(buffer-modified? BUF) — return #t if the buffer changed after its last save."} => fn [
                                                                                                name
                                                                                              ] ->
        Buffer.modified?(name)
      end,
      {"buffer-persistent?",
       "(buffer-persistent? BUF) — return #t if the buffer writes a checkpoint and comes back at the next boot."} =>
        fn [name] -> Buffer.persistent?(name) end,
      {"buffer-path", "(buffer-path BUF) — return the buffer's file path, or #f if it has none."} =>
        fn [name] -> Buffer.path(name) || false end,
      # named buffer ops are programmatic (:editor source) — they bypass
      # read-only, like Emacs' inhibit-read-only
      {"buffer-append!",
       "(buffer-append! BUF TEXT) — append TEXT to the buffer's end; ignores read-only."} => fn [
                                                                                                  name,
                                                                                                  text
                                                                                                ] ->
        :ok = Buffer.append(name, text, source: :editor)
        :void
      end,
      {"buffer-insert!",
       "(buffer-insert! BUF POS TEXT) — insert TEXT at byte POS; ignores read-only."} => fn [
                                                                                              name,
                                                                                              pos,
                                                                                              text
                                                                                            ] ->
        :ok = Buffer.insert_at(name, pos, text, source: :editor)
        :void
      end,
      {"buffer-insert-at-local!",
       "(buffer-insert-at-local! BUF LOCAL TEXT) — insert TEXT at the byte position the buffer-local LOCAL names and advance the local, atomically; return the advanced position."} =>
        fn [name, local, text] ->
          Buffer.insert_at_local(name, plain(local), to_string(text), source: :editor)
        end,
      {"buffer-marker-local!",
       "(buffer-marker-local! BUF LOCAL &optional TYPE) — declare LOCAL a marker: the buffer keeps the position current through every edit, as it keeps point. TYPE 'advance (default) moves it with text inserted exactly on it; 'stay does not."} =>
        fn
          [name, local] ->
            :ok = Buffer.declare_marker_local(name, plain(local))
            :void

          [name, local, type] ->
            :ok =
              Buffer.declare_marker_local(
                name,
                plain(local),
                if(plain(type) == "stay", do: :stay, else: :advance)
              )

            :void
        end,
      {"buffer-delete-range!",
       "(buffer-delete-range! BUF POS LEN) — delete LEN bytes at byte POS; ignores read-only."} =>
        fn [name, pos, len] ->
          :ok = Buffer.delete_range(name, pos, len, source: :editor)
          :void
        end,
      {"buffer-replace-range!",
       "(buffer-replace-range! BUF POS LEN TEXT) — replace LEN bytes at byte POS with TEXT as one undo step; ignores read-only."} =>
        fn [name, pos, len, text] ->
          :ok = Buffer.replace_range(name, pos, len, text, source: :editor)
          :void
        end,
      {"buffer-set-text!",
       "(buffer-set-text! BUF TEXT [READ-ONLY?]) — make BUF (created when missing) hold TEXT alone, past read-only; with READ-ONLY? given, set the flag after."} =>
        fn
          [name, text] ->
            set_text(name, text)
            :void

          [name, text, read_only] ->
            set_text(name, text)
            Buffer.set_read_only(name, read_only == true)
            :void
        end,
      {"buffer-version-token",
       "(buffer-version-token BUF) — what this replica knows, as an opaque token to hand a peer; #f if the buffer records no history."} =>
        fn [name] ->
          case Buffer.version_token(name) do
            token when is_binary(token) -> Base.url_encode64(token, padding: false)
            _ -> false
          end
        end,
      {"buffer-updates-since",
       "(buffer-updates-since BUF TOKEN) — every change a replica at TOKEN has not seen, base64. Pass #f for a replica that knows nothing."} =>
        fn [name, token] ->
          from =
            case token do
              t when is_binary(t) -> Base.url_decode64!(t, padding: false)
              _ -> nil
            end

          case Buffer.updates_since(name, from) do
            bytes when is_binary(bytes) -> Base.url_encode64(bytes, padding: false)
            {:error, reason} -> raise Compos.Scheme.Eval.Error, message: inspect(reason)
          end
        end,
      {"buffer-merge!",
       "(buffer-merge! BUF UPDATES) — take base64 changes another replica made; the rope follows and the point stays put. #t when the text changed."} =>
        fn [name, updates] ->
          bytes = Base.url_decode64!(updates, padding: false)

          case Buffer.merge(name, bytes) do
            {:ok, changed?} -> changed?
            {:error, reason} -> raise Compos.Scheme.Eval.Error, message: inspect(reason)
          end
        end,
      {"peer-eval",
       "(peer-eval SOCKET CODE) — evaluate CODE on the daemon listening at SOCKET, a local path or host:/path over ssh. Returns its printed result, or raises when it cannot be reached."} =>
        fn [socket, code] ->
          case Compos.Core.Peer.eval(socket, code) do
            {:ok, printed} -> printed
            {:error, reason} -> raise Compos.Scheme.Eval.Error, message: inspect(reason)
          end
        end,
      {"buffer-anchor",
       "(buffer-anchor BUF POS) — an opaque anchor on byte POS that keeps naming the same place while the text around it changes; #f if the buffer records no history."} =>
        fn [name, pos] ->
          Buffer.anchor(name, pos) || false
        end,
      {"buffer-anchor-pos",
       "(buffer-anchor-pos BUF ANCHOR) — where an anchor from buffer-anchor points now, or #f if it cannot be resolved. Read a position now, edit at it later, and the edit still lands where you meant."} =>
        fn [name, anchor] ->
          Buffer.anchor_pos(name, anchor) || false
        end,
      {"buffer-authors",
       "(buffer-authors BUF) — return (START END AUTHOR) attribution spans for the current text."} =>
        fn [name] ->
          for {s, e, a} <- Buffer.authors(name), do: [s, e, a]
        end,
      {"buffer-author-lines",
       "(buffer-author-lines BUF) — return (LINE AUTHOR BYTES) attribution rows, 1-based, in line order; a line two actors touched appears once per actor."} =>
        fn [name] ->
          for {line, author, bytes} <- Buffer.author_lines(name), do: [line, author, bytes]
        end,
      {"buffer-edit-log",
       "(buffer-edit-log BUF) — return (VERSION AUTHOR POS INS DEL) edit records, newest first."} =>
        fn [name] ->
          for {v, a, pos, ins, del} <- Buffer.edit_log(name), do: [v, a || false, pos, ins, del]
        end,
      {"buffer-provenance-status",
       "(buffer-provenance-status BUF) — return the durable recording state and accepted head."} =>
        fn [name] ->
          Buffer.provenance(name) |> json_to_scheme_value()
        end,
      {"buffer-history",
       "(buffer-history BUF) — return every change to the buffer, oldest first: who made it, what it did, and when. A delete reports how many bytes it removed, not the text."} =>
        fn [name] ->
          Buffer.change_log(name) |> json_to_scheme_value()
        end,
      {"buffer-provenance-start!",
       "(buffer-provenance-start! BUF [ACTOR REASON POLICY]) — start or resume recording; bridges any gap."} =>
        fn
          [name] ->
            :ok = Buffer.provenance_start(name, source: :editor)
            :void

          [name, actor, reason, policy_source] ->
            :ok =
              Buffer.provenance_start(
                name,
                source: :editor,
                author: plain(actor),
                reason: plain(reason),
                policy_source: plain(policy_source)
              )

            :void
        end,
      {"buffer-provenance-stop!",
       "(buffer-provenance-stop! BUF [ACTOR REASON POLICY]) — stop recording; keeps all history."} =>
        fn
          [name] ->
            :ok = Buffer.provenance_stop(name, source: :editor)
            :void

          [name, actor, reason, policy_source] ->
            :ok =
              Buffer.provenance_stop(
                name,
                source: :editor,
                author: plain(actor),
                reason: plain(reason),
                policy_source: plain(policy_source)
              )

            :void
        end,
      {"buffer-provenance-discard!",
       "(buffer-provenance-discard! BUF [ACTOR REASON POLICY]) — stop recording and delete the history; the checkpoint carries the text. For a buffer that renders a record kept elsewhere."} =>
        fn
          [name] ->
            :ok = Buffer.provenance_discard(name, source: :editor)
            :void

          [name, actor, reason, policy_source] ->
            :ok =
              Buffer.provenance_discard(
                name,
                source: :editor,
                author: plain(actor),
                reason: plain(reason),
                policy_source: plain(policy_source)
              )

            :void
        end,
      {"buffer-store-sweep-graveyard!",
       "(buffer-store-sweep-graveyard! KEEP-DAYS) — delete graveyard checkpoints and logs buried more than KEEP-DAYS ago; the burial log stays. Returns the count."} =>
        fn [days] when is_integer(days) and days >= 0 ->
          Compos.Core.BufferStore.sweep_graveyard(days)
        end,
      {"buffer-store-sweep-redundant-history!",
       "(buffer-store-sweep-redundant-history!) — delete the history log of every dormant buffer whose checkpoint carries its text and whose mode opted out of recording. Returns the count."} =>
        fn [] -> Compos.Core.BufferStore.sweep_redundant_history() end,
      {"buffer-provenance-checkpoint!",
       "(buffer-provenance-checkpoint! BUF) — close the current changeset."} => fn [name] ->
        case Buffer.provenance_checkpoint(name, source: :editor) do
          :ok -> :void
          {:error, reason} -> [{:sym, "error"}, Atom.to_string(reason)]
        end
      end,
      # overlays: (overlay-set! buf 'org (list (list s e "org-todo") ...))
      # replaces the tag's whole range set — the fontification model is
      # "mode recomputes"; positions auto-adjust between recomputes
      {"overlay-set!",
       "(overlay-set! BUF TAG RANGES) — replace TAG's overlays with (START END FACE) byte ranges."} =>
        fn [name, tag, ranges] ->
          :ok =
            Buffer.set_overlays(
              name,
              plain(tag),
              Enum.map(ranges, fn [s, e, f] -> {s, e, plain(f)} end)
            )

          :void
        end,
      {"overlay-set-range!",
       "(overlay-set-range! BUF TAG START END RANGES [VERSION]) — replace TAG's overlays that start in START..END with RANGES; #f when BUF is no longer at VERSION."} =>
        fn args ->
          [name, tag, start, stop, ranges | rest] = args
          version = List.first(rest)

          Buffer.set_overlays_range(
            name,
            plain(tag),
            start,
            stop,
            Enum.map(ranges, fn [s, e, f] -> {s, e, plain(f)} end),
            if(is_integer(version), do: version)
          ) == :ok
        end,
      {"jit-lock-enable!",
       "(jit-lock-enable! ON) — ask Display for the lines it builds, and run fontification-functions on them."} =>
        fn [on] ->
          Compos.Core.JitLock.enable(on not in [false, nil])
          :void
        end,
      {"jit-lock-refontify!",
       "(jit-lock-refontify! BUF) — forget what BUF fontified, so the next draw runs fontification-functions again."} =>
        fn [name] ->
          if Buffer.exists?(name), do: Buffer.jit_reset(name)
          :void
        end,
      {"overlay-clear!",
       "(overlay-clear! BUF TAG) — remove TAG's overlays; the tag 'all removes every overlay."} =>
        fn [name, tag] ->
          :ok = Buffer.clear_overlays(name, if(plain(tag) == "all", do: :all, else: plain(tag)))
          :void
        end,
      {"buffer-overlays",
       "(buffer-overlays BUF [TAG]) — return all overlays, or TAG's alone, as (START END FACE) byte ranges."} =>
        fn
          [name] ->
            Enum.map(Buffer.overlays(name), fn {s, e, f} -> [s, e, f] end)

          [name, tag] ->
            Enum.map(Buffer.overlays(name, plain(tag)), fn {s, e, f} -> [s, e, f] end)
        end,
      # folding: ranges is a list of (start end) byte ranges to hide.
      # A buffer has several fold owners, so ranges are tagged and each
      # owner replaces only its own tag. The display hides the union.
      # The untagged pair below writes and reads the "default" tag.
      {"buffer-hidden",
       "(buffer-hidden BUF) — return the hidden (folded) byte ranges as (START END) pairs."} =>
        fn [name] ->
          Enum.map(Buffer.hidden(name), fn {s, e} -> [s, e] end)
        end,
      {"fold-set!",
       "(fold-set! BUF TAG RANGES) — replace TAG's hidden (START END) byte ranges; the display hides the union of all tags."} =>
        fn [name, tag, ranges] ->
          :ok = Buffer.set_hidden(name, plain(tag), Enum.map(ranges, fn [s, e] -> {s, e} end))
          :void
        end,
      {"fold-get",
       "(fold-get BUF [TAG]) — return TAG's hidden ranges; no TAG, or 'all, returns the union."} =>
        fn
          [name] -> Enum.map(Buffer.hidden(name), fn {s, e} -> [s, e] end)
          [name, tag] -> Enum.map(Buffer.hidden(name, fold_tag(tag)), fn {s, e} -> [s, e] end)
        end,
      {"fold-clear!",
       "(fold-clear! BUF [TAG]) — drop TAG's folds; no TAG, or 'all, drops every tag's."} => fn
        [name] ->
          :ok = Buffer.clear_hidden(name)
          :void

        [name, tag] ->
          :ok = Buffer.clear_hidden(name, fold_tag(tag))
          :void
      end,
      {"buffer-narrow!",
       "(buffer-narrow! BUF START END) — narrow visible text to the exclusive byte range without changing buffer access."} =>
        fn [name, start, stop] ->
          :ok = Buffer.narrow(name, start, stop)
          :void
        end,
      {"buffer-narrow-range",
       "(buffer-narrow-range BUF) — return the active (START END) narrowing, or #f."} => fn [name] ->
        case Buffer.narrow_range(name) do
          {start, stop} -> [start, stop]
          nil -> false
        end
      end,
      {"buffer-widen!", "(buffer-widen! BUF) — make the complete buffer visible."} => fn [name] ->
        :ok = Buffer.widen(name)
        :void
      end,
      # text properties: values on the text, moved by every edit, taken by
      # inserted text under the Emacs stickiness rules. The Emacs names,
      # with BUF first as every buffer primitive here takes it.
      {"put-text-property!",
       "(put-text-property! BUF START END PROP VALUE) — give the text START..END the property PROP with VALUE; #f removes it."} =>
        fn [name, start, stop, prop, value] ->
          :ok = Buffer.put_text_property(name, start, stop, plain(prop), value)
          :void
        end,
      {"remove-text-properties!",
       "(remove-text-properties! BUF START END PROPS) — take the properties PROPS, a list of names, off START..END."} =>
        fn [name, start, stop, props] ->
          :ok = Buffer.remove_text_properties(name, start, stop, Enum.map(props, &plain/1))
          :void
        end,
      {"get-text-property",
       "(get-text-property BUF POS PROP) — the value of PROP at POS, or #f."} =>
        fn [name, pos, prop] ->
          case Buffer.get_text_property(name, pos, plain(prop)) do
            nil -> false
            value -> value
          end
        end,
      {"text-properties-at",
       "(text-properties-at BUF POS) — every property at POS, as (PROP VALUE) pairs."} =>
        fn [name, pos] ->
          Enum.map(Buffer.text_properties_at(name, pos), fn {prop, value} -> [{:sym, prop}, value] end)
        end,
      {"next-single-property-change",
       "(next-single-property-change BUF POS PROP [LIMIT]) — the first position after POS where PROP changes; #f when it does not, LIMIT when not before LIMIT."} =>
        fn [name, pos, prop | rest] ->
          Buffer.next_single_property_change(name, pos, plain(prop), limit(rest)) || false
        end,
      {"previous-single-property-change",
       "(previous-single-property-change BUF POS PROP [LIMIT]) — the last position before POS where PROP changes; #f when it does not, LIMIT when not after LIMIT."} =>
        fn [name, pos, prop | rest] ->
          Buffer.previous_single_property_change(name, pos, plain(prop), limit(rest)) || false
        end,
      {"text-property-any",
       "(text-property-any BUF START END PROP VALUE) — the first position in START..END where PROP is VALUE, or #f."} =>
        fn [name, start, stop, prop, value] ->
          Buffer.text_property_any(name, start, stop, plain(prop), value) || false
        end,
      {"text-property-spans",
       "(text-property-spans BUF PROP) — every span of PROP as (START END VALUE), in order."} =>
        fn [name, prop] ->
          Enum.map(Buffer.text_property_spans(name, plain(prop)), fn {s, e, v} -> [s, e, v] end)
        end,
      {"text-property-default-nonsticky!",
       "(text-property-default-nonsticky! PROP ON) — with ON, text typed at the end of a PROP span takes no PROP; the Emacs variable of that name."} =>
        fn [prop, on] ->
          :ok = Compos.Core.TextProps.set_default_nonsticky(plain(prop), on not in [false, nil])
          :void
        end,
      {"text-property-default-nonsticky",
       "(text-property-default-nonsticky) — the property names that do not grow over text typed at their end."} =>
        fn [] -> Enum.map(Compos.Core.TextProps.default_nonsticky(), &{:sym, &1}) end,
      {"buffer-set-read-only!",
       "(buffer-set-read-only! BUF BOOL) — set the buffer's read-only flag."} => fn [name, bool] ->
        Buffer.set_read_only(name, bool == true)
        :void
      end,
      {"buffer-read-only?", "(buffer-read-only? BUF) — return #t if the buffer is read-only."} =>
        fn [name] -> Buffer.read_only?(name) end,
      {"buffer-kill!", "(buffer-kill! BUF) — kill the buffer and release its windows."} => fn [
                                                                                                name
                                                                                              ] ->
        Core.kill_buffer(name)
        :void
      end,
      # remote files: ssh transport only — /ssh: path syntax, remote buffers,
      # and save interception are Scheme (priv/editor.scm)
      {"ssh-command", "(ssh-command) — return the configured ssh command string."} => fn [] ->
        Compos.Core.Remote.ssh()
      end,
      {"remote-read",
       "(remote-read HOST PATH [CALLBACK]) — read a remote file; return text, 'directory, 'absent, or (error MSG). With CALLBACK, run in a Task and hand it the value."} =>
        fn [host, path | rest] ->
          work = fn ->
            case Compos.Core.Remote.read(host, path) do
              {:ok, text} -> text
              :directory -> {:sym, "directory"}
              :absent -> {:sym, "absent"}
              {:error, msg} -> [{:sym, "error"}, msg]
            end
          end

          case rest do
            [] -> work.()
            [callback] -> async_dispatch(callback, work)
          end
        end,
      {"remote-list-dir",
       "(remote-list-dir HOST DIR [CALLBACK]) — list a remote directory; return entries or (error MSG). With CALLBACK, run in a Task and hand it the value."} =>
        fn [host, dir | rest] ->
          work = fn ->
            case Compos.Core.Remote.list_dir(host, dir) do
              {:ok, entries} -> entries
              {:error, msg} -> [{:sym, "error"}, msg]
            end
          end

          case rest do
            [] -> work.()
            [callback] -> async_dispatch(callback, work)
          end
        end,
      {"remote-sh",
       "(remote-sh HOST CMD [CALLBACK]) — run CMD on HOST over ssh; return #t or (error MSG). With CALLBACK, run in a Task and hand it the value."} =>
        fn [host, cmd | rest] ->
          work = fn ->
            case Compos.Core.Remote.sh(host, cmd) do
              :ok -> true
              {:error, msg} -> [{:sym, "error"}, msg]
            end
          end

          case rest do
            [] -> work.()
            [callback] -> async_dispatch(callback, work)
          end
        end,
      {"remote-write",
       "(remote-write HOST PATH TEXT [CALLBACK]) — write TEXT to a remote file; return #t or (error MSG). With CALLBACK, run in a Task and hand it the value."} =>
        fn [host, path, text | rest] ->
          work = fn ->
            case Compos.Core.Remote.write(host, path, text) do
              :ok -> true
              {:error, msg} -> [{:sym, "error"}, msg]
            end
          end

          case rest do
            [] -> work.()
            [callback] -> async_dispatch(callback, work)
          end
        end,
      {"buffer-mark-saved!", "(buffer-mark-saved! BUF) — clear the buffer's modified flag."} =>
        fn [name] ->
          Buffer.mark_saved(name)
          :void
        end,
      {"find-file",
       "(find-file PATH [PERSISTENT?] [READ?]) — open the file PATH in a buffer and return the buffer name. PERSISTENT? #f opens it for this session only: no checkpoint, and no restore at the next boot. READ? #f binds the buffer to the file without reading it, for a file whose viewer reads it from disk."} =>
        fn
          [path] ->
            find_file(path, [])

          # A second argument of #f opens the file for this session only.
          # Scheme decides that: see large-file-warning-threshold.
          [path, persistent?] ->
            find_file(path, persistent: persistent? != false)

          # A third of #f never reads the file: the buffer is bound to the
          # path and its viewer reads the bytes from disk. Scheme decides
          # that too: see browser-file-mode.
          [path, persistent?, read?] ->
            find_file(path, persistent: persistent? != false, read: read? != false)
        end,
      # directory listing: names only, directories marked with trailing "/"
      {"list-dir",
       "(list-dir DIR) — return sorted entry names; directories carry a trailing slash."} => fn [
                                                                                                  dir
                                                                                                ] ->
        expanded = Path.expand(if dir == "", do: ".", else: dir)

        case File.ls(expanded) do
          {:ok, entries} ->
            entries
            |> Enum.sort()
            |> Enum.map(fn e ->
              if File.dir?(Path.join(expanded, e)), do: e <> "/", else: e
            end)

          {:error, _} ->
            []
        end
      end,
      # One read supplies Dired's row data. File.lstat/2 preserves links,
      # and exact bytes stay separate from the formatted display value.
      {"directory-entries",
       "(directory-entries DIR) — return sorted entry plists with name, type, exact bytes, mtime, size, date, and perms; return (error MSG) when DIR cannot be read."} =>
        fn [dir] ->
          expanded = Path.expand(if dir == "", do: ".", else: dir)

          case File.ls(expanded) do
            {:ok, names} ->
              names
              |> Enum.sort()
              |> Enum.map(&directory_entry(expanded, &1))

            {:error, reason} ->
              [{:sym, "error"}, file_error(reason, expanded)]
          end
        end,
      {"expand-path", "(expand-path PATH) — expand PATH to an absolute path."} => fn [p] ->
        Path.expand(p)
      end,
      # A write rule compares a path against a root directory. In development
      # _build/dev/lib/compos_core/priv is a symlink to apps/compos_core/priv,
      # so the same directory has two names and a text prefix test fails on one
      # of them. Scheme has no way to read a link, so this resolves them.
      {"file-realpath",
       "(file-realpath PATH) — expand PATH and resolve any symlink in it, so two names for one directory compare equal."} =>
        fn [p] -> realpath(Path.expand(p)) end,
      # (file-stat path) -> (perms size date) strings, dired-style
      {"file-stat", "(file-stat PATH) — return (PERMS SIZE DATE) strings in dired style."} => fn [
                                                                                                   p
                                                                                                 ] ->
        case File.stat(Path.expand(p), time: :posix) do
          {:ok, stat} ->
            [format_mode(stat), format_size(stat.size), format_mtime(stat.mtime)]

          {:error, _} ->
            ["----------", "?", "?"]
        end
      end,
      # a sortable mtime (posix seconds), 0 when the file is gone — file-stat
      # formats for display and cannot be ordered
      {"file-mtime",
       "(file-mtime PATH) — return the file's mtime in posix seconds, or 0 if it is gone."} =>
        fn [p] ->
          case File.stat(Path.expand(p), time: :posix) do
            {:ok, stat} -> stat.mtime
            {:error, _} -> 0
          end
        end,
      # a comparable byte count, for the same reason file-mtime exists:
      # file-stat formats a size for display ("17.3M") and cannot be
      # compared. Local paths only, like file-mtime — a remote path fails
      # the stat and answers 0, so a caller sizing a file to decide how
      # much work to do treats a remote file as it did before.
      {"file-size",
       "(file-size PATH) — return the file's size in bytes, or 0 if it is gone or remote."} =>
        fn [p] ->
          case File.stat(Path.expand(p)) do
            {:ok, stat} -> stat.size
            {:error, _} -> 0
          end
        end,
      # one segment, so a file buffer's slashes survive the round trip
      {"url-encode", "(url-encode S) — percent-encode S as one URL path segment."} => fn [s] ->
        URI.encode(s, &URI.char_unreserved?/1)
      end,
      {"url-decode", "(url-decode S) — decode a percent-encoded URL segment."} => fn [s] ->
        URI.decode(s)
      end,
      {"file-exists?", "(file-exists? PATH) — return #t if PATH exists."} => fn [p] ->
        File.exists?(Path.expand(p))
      end,
      # a file that is not there yet can be created, so it counts as writable
      {"file-writable?",
       "(file-writable? PATH) — return #t when the process can write PATH, or PATH does not exist yet."} =>
        fn [p] ->
          case File.stat(Path.expand(p)) do
            {:ok, stat} -> stat.access in [:write, :read_write]
            {:error, _} -> true
          end
        end,
      {"file-directory?", "(file-directory? PATH) — return #t if PATH is a directory."} => fn [p] ->
        File.dir?(Path.expand(p))
      end,
      # (read-file PATH) -> contents, or #f if unreadable
      {"read-file", "(read-file PATH) — return the file's contents, or #f if unreadable."} => fn [
                                                                                                   p
                                                                                                 ] ->
        case File.read(Path.expand(p)) do
          {:ok, text} -> text
          {:error, _} -> false
        end
      end,
      # (getenv NAME) — an unset OR empty variable is #f: a caller asking for
      # a key wants the next source in the chain, not the empty string
      {"getenv",
       "(getenv NAME) — return the environment variable NAME, or #f if it is unset or empty."} =>
        fn [name] ->
          case System.get_env(name) do
            v when v in [nil, ""] -> false
            v -> v
          end
        end,
      # This is mechanism, including for agent-attributed evals. Scheme's
      # permission policy is an overridable convenience, not an OS sandbox.
      {"shell-command->string",
       "(shell-command->string CMD [DIR] [CALLBACK]) — run CMD in a shell; stderr merges into the output. With CALLBACK, run in a Task and return :void at once; CALLBACK gets the output. Without CALLBACK, block up to the shell time limit, then kill CMD and return what it wrote."} =>
        fn
          [cmd] ->
            shell_to_string(cmd, File.cwd!())

          [cmd, dir_or_cb | rest] ->
            {dir, callback} =
              case {dir_or_cb, rest} do
                {cb, []} when not is_binary(cb) -> {File.cwd!(), cb}
                {dir, []} -> {Path.expand(dir), nil}
                {dir, [cb]} -> {Path.expand(dir), cb}
              end

            if callback do
              async_dispatch(callback, fn -> shell_to_string(cmd, dir, shell_async_limit()) end)
            else
              shell_to_string(cmd, dir)
            end
        end,
      {"scheme-read",
       "(scheme-read STR) — read STR as Scheme data; return the list of top-level forms, or #f when STR does not parse."} =>
        fn [src] ->
          try do
            Compos.Scheme.Reader.read_all(src)
          rescue
            _ -> false
          end
        end,
      # (json-parse STR) — objects become flat plists with symbol keys,
      # null becomes #f; #f on parse failure
      {"json-parse",
       "(json-parse STR) — parse JSON; objects become plists with symbol keys; #f on failure."} =>
        fn [s] ->
          case Jason.decode(s) do
            {:ok, v} -> Compos.Core.LLM.json_to_scheme(v)
            {:error, _} -> false
          end
        end,
      # (json-encode V [PRETTY]) — the inverse: a plist becomes an object,
      # any other list an array. Escaping is the encoder's job, so a value
      # survives a round trip through a file that the printer's own escapes
      # do not. A truthy PRETTY indents the output.
      {"json-encode",
       "(json-encode V [PRETTY]) — encode a Scheme value as a JSON string; a plist becomes an object. A truthy PRETTY indents the output."} =>
        fn
          [v] -> Jason.encode!(Compos.Core.Session.scheme_to_json(v))
          [v, false] -> Jason.encode!(Compos.Core.Session.scheme_to_json(v))
          [v, _pretty] -> Jason.encode!(Compos.Core.Session.scheme_to_json(v), pretty: true)
        end,
      # Formatting is lexical. A Scheme parse and encode cannot preserve JSON
      # null or object key order, so this narrow mechanism keeps the source
      # values intact while Scheme decides when a buffer uses it.
      {"json-format",
       "(json-format STR) — indent valid JSON without changing its values or object key order; return #f on invalid input."} =>
        fn [text] ->
          case Jason.decode(text) do
            {:ok, _value} -> Jason.Formatter.pretty_print(text) <> "\n"
            {:error, _reason} -> false
          end
        end,
      {"write-file!",
       "(write-file! PATH TEXT) — write TEXT to PATH, create parent directories; return #t."} =>
        fn [p, text] ->
          path = Path.expand(p)
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, text)
          true
        end,
      {"start-process!",
       "(start-process! BUF CMD) — start a shell process attached to BUF; return #t on success."} =>
        fn [buffer, cmd] ->
          case Compos.Core.Terminal.start(buffer, cmd, raw: false) do
            {:ok, _} -> true
            {:error, {:already_started, _}} -> true
            _ -> false
          end
        end,
      {"start-terminal!",
       "(start-terminal! BUF CMD) — start a raw PTY whose bounded plain transcript stays in BUF; return #t on success."} =>
        fn [buffer, cmd] ->
          case Compos.Core.Terminal.start(buffer, cmd) do
            {:ok, _} -> true
            {:error, {:already_started, _}} -> true
            _ -> false
          end
        end,
      {"process-send!",
       "(process-send! BUF TEXT) — send TEXT to the buffer's process; return #t on success."} =>
        fn [buffer, text] ->
          Compos.Core.Terminal.send_text(buffer, text) == :ok
        end,
      {"process-running?", "(process-running? BUF) — return #t if the buffer's process runs."} =>
        fn [buffer] ->
          Compos.Core.Terminal.running?(buffer)
        end,
      {"process-mark",
       "(process-mark BUF) — return the byte position just after the last process output."} =>
        fn [buffer] -> Compos.Core.Terminal.mark(buffer) end,
      {"buffer-substring",
       "(buffer-substring START END) — return the current buffer's text between byte START and END."} =>
        fn [s, e] -> Buffer.slice(Editor.current_buffer(), s, e) end,
      {"process-kill!", "(process-kill! BUF) — kill the buffer's process."} => fn [buffer] ->
        Compos.Core.Terminal.kill(buffer)
        :void
      end,
      {"process-list",
       "(process-list) — return ((BUF CMD) ...) for every running process buffer."} => fn [] ->
        for {name, cmd} <- Compos.Core.Terminal.list(), do: [name, cmd]
      end,
      {"process-restart!",
       "(process-restart! BUF) — kill the buffer's process and run its command again; return #t on success."} =>
        fn [buffer] ->
          case Compos.Core.Terminal.restart(buffer) do
            {:ok, _} -> true
            _ -> false
          end
        end,
      # current line's text (policy-free helper for comint & friends)
      {"line-text", "(line-text) — return the current line's text, without the newline."} =>
        fn [] ->
          buf = Editor.current_buffer()
          text = Buffer.text(buf)
          {bol, eol} = Compos.Core.Text.line_bounds(text, Buffer.point(buf))
          binary_part(text, bol, eol - bol)
        end
    }
  end

  defp irc_primitives do
    %{
      {"irc-parse",
       "(irc-parse LINE) — split one IRC line into (prefix P command C params (...) trailing T)."} =>
        fn [line] ->
          m = Compos.Core.IRC.parse(line)

          [
            {:sym, "prefix"},
            m.prefix || false,
            {:sym, "command"},
            m.command,
            {:sym, "params"},
            m.params,
            {:sym, "trailing"},
            m.trailing || false,
            {:sym, "raw"},
            m.raw
          ]
        end,
      {"irc-format",
       "(irc-format COMMAND PARAMS [TRAILING]) — one IRC line from a command, its params, and an optional trailing text."} =>
        fn
          [command, params] -> Compos.Core.IRC.format(command, params)
          [command, params, trailing] -> Compos.Core.IRC.format(command, params, trailing)
        end
    }
  end

  defp discovery_primitives do
    %{
      {"embedding-cache-clear!",
       "(embedding-cache-clear!) — delete cached apropos vectors from disk and memory; return the cache path."} =>
        fn [] ->
          path = Compos.Core.EmbeddingIndex.cache_path()
          :ok = Compos.Core.EmbeddingIndex.clear(path)
          path
        end,
      {"embedding-sync!",
       "(embedding-sync! TEXTS KEY) — embed missing catalog TEXTS with OpenAI and persist their vectors by content hash."} =>
        fn [texts, key] ->
          case Compos.Core.EmbeddingIndex.sync(texts, to_string(key)) do
            {:ok, count} -> count
            {:error, _reason} -> false
          end
        end,
      # GEN is the catalog generation the texts belong to: the index keeps
      # the vectors it gathered for that generation and rebuilds them for no
      # other. `false` for a query nobody asked before, which needs the
      # network — the caller decides whether to wait for one.
      {"embedding-search",
       "(embedding-search QUERY TEXTS KEY LIMIT ELIGIBLE GEN CACHED-ONLY) — eligible cosine scores for QUERY against the vectors of catalog generation GEN. CACHED-ONLY answers #f rather than embedding a query over the network."} =>
        fn [query, texts, key, limit, eligible, gen, cached_only] ->
          opts = [gen: gen, cached_only: cached_only == true]

          case Compos.Core.EmbeddingIndex.search(to_string(query), texts, to_string(key), opts) do
            {:ok, scores} ->
              # ELIGIBLE is #t when no filter narrows the answer. Building that
              # mask and handing it over was most of what a query cost, and
              # every entry in it said yes.
              scores
              |> then(fn scored ->
                if is_list(eligible) do
                  mask = List.to_tuple(eligible)

                  Enum.filter(scored, fn {index, _score} ->
                    index < tuple_size(mask) and elem(mask, index)
                  end)
                else
                  scored
                end
              end)
              |> Enum.take(max(0, limit))
              |> Enum.map(fn {index, score} -> [index, score] end)

            {:error, :absent} ->
              false

            # the caller withheld the texts for a generation the index has not
            # gathered yet; it retries with them
            {:error, :not_prepared} ->
              {:sym, "not-prepared"}

            {:error, _reason} ->
              []
          end
        end,
      # Embed QUERY for the next ask. It runs off the caller's lane, so the
      # ask that missed answers from the catalog now and the one after it
      # gets the semantic pass for free.
      {"embedding-warm!",
       "(embedding-warm! QUERY TEXTS KEY GEN) — embed QUERY off the caller's lane so the next ask scores without waiting."} =>
        fn [query, texts, key, gen] ->
          q = to_string(query)
          k = to_string(key)

          Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
            Compos.Core.EmbeddingIndex.search(q, texts, k, gen: gen)
          end)

          :void
        end
    }
  end

  defp editor_primitives do
    %{
      # point & motion — operate on the current (active window's) buffer
      {"current-buffer", "(current-buffer) — return the name of the current buffer."} => fn [] ->
        Editor.current_buffer()
      end,
      {"point", "(point) — return point in the current buffer as a byte offset."} => fn [] ->
        Buffer.point(Editor.current_buffer())
      end,
      {"buffer-point", "(buffer-point BUF) — return the buffer's point as a byte offset."} => fn [
                                                                                                   name
                                                                                                 ] ->
        Buffer.point(name)
      end,
      {"buffer-line-at-point",
       "(buffer-line-at-point BUF) — return (LINE TEXT) for the buffer's point."} => fn [name] ->
        {line, text} = Buffer.line_at_point(name)
        [line, text]
      end,
      # ~/.compos in real life, a tmp dir in tests — config and user packages
      {"compos-home", "(compos-home) — return the compos home directory path (~/.compos)."} =>
        fn [] -> Compos.Core.home() end,
      {"compos-priv-dir",
       "(compos-priv-dir) — return the bundled Scheme directory (the editor's priv dir)."} =>
        fn [] -> Application.app_dir(:compos_core, "priv") end,
      {"compos-project-dir",
       "(compos-project-dir) — the checkout this daemon runs from, or #f in a release."} =>
        fn [] -> Compos.Core.project_dir() || false end,
      {"compos-config-dir",
       "(compos-config-dir) — where user config reads from (COMPOS_CONFIG, else the home)."} =>
        fn [] -> Compos.Core.config_dir() end,
      # The socket THIS daemon listens on. A second daemon (COMPOS_HOME, or the
      # verify config) listens elsewhere, and anything it spawns must come back
      # to it rather than to the default path.
      {"compos-socket-path",
       "(compos-socket-path) — return the path of this daemon's JSON-RPC socket."} => fn [] ->
        Application.get_env(:compos_rpc, :socket_path, Path.join(Compos.Core.home(), "sock"))
        |> Path.expand()
      end,
      {"socket-listeners",
       "(socket-listeners) — return ((NAME STATUS ADDRESS) ...) for the daemon's listen sockets."} =>
        fn [] ->
          for l <- Compos.Core.Daemon.listeners(), do: [l.name, l.status, l.address]
        end,
      {"listener-restart!",
       "(listener-restart! NAME) — stop and start the named listen socket; return #t."} => fn [
                                                                                                name
                                                                                              ] ->
        case Compos.Core.Daemon.restart_listener(name) do
          :ok ->
            true

          {:error, reason} ->
            raise Compos.Scheme.Eval.Error,
              message: "listener-restart!: #{name}: #{inspect(reason)}"
        end
      end,
      {"daemon-restart!",
       "(daemon-restart!) — save the desktop, restart the daemon, and reload Scheme; return #t."} =>
        fn [] ->
          case Compos.Core.Daemon.restart() do
            :ok ->
              true

            {:error, :desktop_save_failed} ->
              raise Compos.Scheme.Eval.Error, message: "desktop save failed; refusing to restart"

            {:error, {:spawn_failed, _code, out}} ->
              raise Compos.Scheme.Eval.Error,
                message: "could not respawn the daemon: #{inspect(out)}"

            {:error, {:compile_failed, out}} ->
              raise Compos.Scheme.Eval.Error,
                message: "the tree does not compile; staying up: #{out}"
          end
        end,
      # A reload changes what a render would produce, but nothing asks for
      # one: the client repaints on an editor event, and evaluating a
      # definition is not an event. Without this a reloaded modeline, face,
      # or fringe stays on screen exactly as it was until the next keystroke,
      # which reads as "the reload did nothing".
      {"redraw!", "(redraw!) — tell every connected client to re-render every frame; return #t."} =>
        fn [] ->
          Compos.Core.Events.broadcast_editor(:redraw)
          Enum.each(Editor.frame_list(), &Compos.Core.Events.broadcast_frame/1)
          true
        end,
      {"desktop-dirty!",
       "(desktop-dirty!) — schedule persistence after Scheme-owned desktop state changes; return #t."} =>
        fn [] ->
          Compos.Core.Events.broadcast_editor(:scheme_state)
          true
        end,
      # The way back from a boot that brought the windows back and lost the
      # groups. This only reads the file: desktop-globals! installs them,
      # because installing runs Scheme and the caller is already in it.
      {"desktop-file-globals",
       "(desktop-file-globals FILE) — return the globals a desktop file holds, as ((KEY VALUE) ...); the editor is not touched."} =>
        fn [file] ->
          case Compos.Core.Desktop.file_globals(file) do
            {:ok, globals} ->
              globals

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error,
                message: "desktop globals not read from #{file}: #{inspect(reason)}"
          end
        end,
      # The incremental form reloader, which lives in the Session. Scheme
      # cannot reach it otherwise: the diff is over read forms, and the
      # manifest of what each file last held is the Session's state.
      {"reload-files!",
       "(reload-files! PATHS) — evaluate the changed top-level forms of each .scm and refresh the modes they redefine; return (FILES FORMS)."} =>
        fn [paths] ->
          case Compos.Core.Session.reload_files(List.wrap(paths)) do
            {:ok, %{files: files, forms: forms}} ->
              [files, forms]

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error, message: "reload failed: #{inspect(reason)}"
          end
        end,
      # A primitive is an anonymous fun captured when the session booted.
      # Recompiling the module that holds it purges that version, and the
      # next call raises "points to an old version of the code". The dev
      # watcher rebinds after every recompile; this is the door to ask by
      # name when a daemon is already wedged.
      {"refresh-primitives!",
       "(refresh-primitives!) — rebind every Elixir primitive to the version now loaded; return #t."} =>
        fn [] ->
          :ok = Compos.Core.Session.refresh_primitives()
          true
        end,
      {"daemon-provision-workspace!",
       "(daemon-provision-workspace! PATH NAME) — start or reuse a daemon from PATH; return (URL HOME PORT), or #f when this editor starts no workspace daemons."} =>
        fn [workspace, name] ->
          case Compos.Core.Daemon.provision_workspace(workspace, name) do
            {:ok, %{url: url, home: home, port: port}} ->
              [url, home, port]

            {:error, :disabled} ->
              false

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error,
                message: "workspace daemon failed: #{inspect(reason)}"
          end
        end,
      {"goto-char!", "(goto-char! POS) — move point to byte POS; return POS."} => fn [pos] ->
        Buffer.goto(Editor.current_buffer(), pos)
        pos
      end,
      # goto-char! in a named buffer: an async refresh restores point in the
      # buffer it rebuilt, which is not always the current one
      {"buffer-goto!", "(buffer-goto! BUF POS) — move the named buffer's point to byte POS."} =>
        fn [name, pos] ->
          Buffer.goto(name, pos)
          pos
        end,
      {"buffer-windows-follow-point!",
       "(buffer-windows-follow-point! BUF) — every window that shows BUF drops its scroll pin and follows point again; call it after a page replaces its text and places point."} =>
        fn [name] ->
          Editor.windows_follow_point(name) == :ok
        end,
      {"forward-char!",
       "(forward-char!) — move point one character forward; return the new point."} => fn [] ->
        Buffer.forward_char(Editor.current_buffer())
      end,
      {"backward-char!",
       "(backward-char!) — move point one character backward; return the new point."} => fn [] ->
        Buffer.backward_char(Editor.current_buffer())
      end,
      {"forward-word!",
       "(forward-word!) — move point to the end of the next word; return the new point."} =>
        fn [] -> Buffer.forward_word(Editor.current_buffer()) end,
      {"backward-word!",
       "(backward-word!) — move point to the start of the previous word; return the new point."} =>
        fn [] -> Buffer.backward_word(Editor.current_buffer()) end,
      {"next-line!",
       "(next-line!) — move point one line down, keep the goal column; return the new point."} =>
        fn [] -> Buffer.next_line(Editor.current_buffer()) end,
      {"previous-line!",
       "(previous-line!) — move point one line up, keep the goal column; return the new point."} =>
        fn [] -> Buffer.previous_line(Editor.current_buffer()) end,
      {"beginning-of-line!",
       "(beginning-of-line!) — move point to the line start; return the new point."} => fn [] ->
        Buffer.beginning_of_line(Editor.current_buffer())
      end,
      {"end-of-line!", "(end-of-line!) — move point to the line end; return the new point."} =>
        fn [] -> Buffer.end_of_line(Editor.current_buffer()) end,
      {"beginning-of-buffer!",
       "(beginning-of-buffer!) — move point to byte 0; return the new point."} => fn [] ->
        Buffer.beginning_of_buffer(Editor.current_buffer())
      end,
      {"end-of-buffer!",
       "(end-of-buffer!) — move point to the buffer's end; return the new point."} => fn [] ->
        Buffer.end_of_buffer(Editor.current_buffer())
      end,
      # 1-based line -> its start byte offset, O(log n) via the rope's own
      # line index (same lookup mouse-click position resolution already
      # uses) — for goto-line, never walk next-line! in a loop for this
      {"line-start-position",
       "(line-start-position LINE) — return the start byte offset of 1-based LINE."} => fn [line] ->
        {start, _text} = Buffer.line_at(Editor.current_buffer(), trunc(line))
        start
      end,
      {"line-number-at-pos",
       "(line-number-at-pos POS) — return the 1-based line byte offset POS is on."} => fn [pos] ->
        Buffer.line_of(Editor.current_buffer(), trunc(pos))
      end,

      # editing (user-sourced: respects read-only)
      {"insert!", "(insert! TEXT) — insert TEXT at point; errors if the buffer is read-only."} =>
        fn [text] ->
          case Buffer.insert(Editor.current_buffer(), text) do
            :ok -> :void
            {:error, :read_only} -> raise Compos.Scheme.Eval.Error, message: "Buffer is read-only"
          end
        end,
      {"delete-char!",
       "(delete-char! N) — delete N characters at point, backward if negative; return the text."} =>
        fn [n] ->
          case Buffer.delete_char(Editor.current_buffer(), n) do
            {:ok, deleted} -> deleted
            {:error, :read_only} -> raise Compos.Scheme.Eval.Error, message: "Buffer is read-only"
          end
        end,
      {"kill-line!",
       "(kill-line!) — delete from point to the line end, or the newline; return the text."} =>
        fn [] ->
          case Buffer.kill_line(Editor.current_buffer()) do
            {:ok, killed} -> killed
            {:error, :read_only} -> raise Compos.Scheme.Eval.Error, message: "Buffer is read-only"
          end
        end,
      {"undo!", "(undo!) — undo one step in the current buffer; return #t on success."} =>
        fn [] ->
          Buffer.undo(Editor.current_buffer()) == :ok
        end,
      # the redo-run flag only; undo-boundary! is the boundary
      {"break-undo-chain!",
       "(break-undo-chain!) — end a run of undos, so the next undo reverses them (redo). It is not a boundary: see undo-boundary!."} =>
        fn [] ->
          buf = Editor.current_buffer()
          if Buffer.exists?(buf), do: Buffer.break_undo_chain(buf)
          :void
        end,
      {"undo-group!",
       "(undo-group! BUF ON) — while ON, BUF's edits stay one undo step; a block's replace uses this so one landing is one undo."} =>
        fn [name, on] ->
          if Compos.Core.Buffer.exists?(name), do: Compos.Core.Buffer.undo_group(name, on == true)
          :void
        end,
      {"undo-exempt!",
       "(undo-exempt! COMMAND) — exempt COMMAND from the automatic undo-chain break."} => fn [
                                                                                               name
                                                                                             ] ->
        Editor.add_undo_exempt(name)
        :void
      end,
      {"buffer-save!",
       "(buffer-save! [PATH]) — save the current buffer to its path; return the path or #f. With PATH, save there and adopt PATH as the buffer's path."} =>
        fn
          [] ->
            case Buffer.save(Editor.current_buffer()) do
              {:ok, path} -> path
              {:error, :no_path} -> false
            end

          [path] ->
            {:ok, path} = Buffer.save(Editor.current_buffer(), path)
            path
        end,
      {"buffer-detach!",
       "(buffer-detach! NAME) — forget NAME's file; text, point, locals and undo stay. Return #t, or #f when no live buffer has that name."} =>
        fn [name] ->
          if Buffer.exists?(name) do
            Buffer.detach(name)
            true
          else
            false
          end
        end,

      # kill ring
      {"kill-push!", "(kill-push! TEXT) — push TEXT onto the kill ring."} => fn [text] ->
        Editor.kill_push(text)
        :void
      end,
      {"kill-append!",
       "(kill-append! TEXT BEFORE?) — grow the newest kill-ring entry with TEXT, in front when BEFORE? is true."} =>
        fn [text, before?] ->
          Editor.kill_append(text, before? == true)
          :void
        end,
      {"kill-top", "(kill-top) — return the newest kill-ring entry, or \"\" when empty."} =>
        fn [] -> Editor.kill_top() end,
      {"kill-nth", "(kill-nth I) — return kill-ring entry I (0 is newest), or \"\" when absent."} =>
        fn [i] -> Editor.kill_nth(i) end,
      {"kill-ring-size", "(kill-ring-size) — return the number of kill-ring entries."} => fn [] ->
        Editor.kill_size()
      end,
      {"client-select!",
       "(client-select! ALTER DIR GRANULARITY [COUNT]) — ask this frame's editable surface to move (\"move\") or extend (\"extend\") its selection \"forward\" or \"backward\" by \"character\", \"word\", \"line\", \"lineboundary\", \"paragraph\" or \"documentboundary\"; COUNT (default 1) applies the move that many times in one request, which is how a page moves; the client answers with point and mark."} =>
        fn
          [alter, dir, granularity] ->
            Editor.select_request(alter, dir, granularity)
            :void

          [alter, dir, granularity, count] ->
            Editor.select_request(alter, dir, granularity, trunc(count))
            :void
        end,
      {"clipboard-put!",
       "(clipboard-put! TEXT) — put TEXT on the OS clipboard of this frame's client."} => fn [
                                                                                               text
                                                                                             ] ->
        Editor.put_clipboard(text)
        :void
      end,

      # the LiveView app puts its own base URL at boot; a headless daemon
      # (tests, RPC with no web app) still answers with the default
      {"editor-url",
       "(editor-url) — return the base URL this editor serves, e.g. http://localhost:4004."} =>
        fn [] ->
          :persistent_term.get(:compos_editor_url, "http://localhost:4004")
        end,
      {"daemon-name", "(daemon-name) — return this daemon's configured name."} => fn [] ->
        Application.get_env(:compos_core, :name, "compos")
      end,
      {"daemon-source-root",
       "(daemon-source-root) — return the checkout that supplies this daemon's code."} => fn [] ->
        File.cwd!()
      end,
      {"daemon-workspace-root",
       "(daemon-workspace-root) — return this daemon's workspace root, or #f."} => fn [] ->
        Application.get_env(:compos_core, :workspace_root, false)
      end,
      {"daemon-set-workspace-label!",
       "(daemon-set-workspace-label! PROJECT NAME) — set this daemon's frame-wide workspace label."} =>
        fn [project, name] ->
          Application.put_env(:compos_core, :workspace_project, to_string(project))
          Application.put_env(:compos_core, :workspace_name, to_string(name))
          Compos.Core.Events.broadcast_editor(:workspace_label)
          :void
        end,
      {"daemon-registry-path",
       "(daemon-registry-path) — return the shared daemon registry file path."} => fn [] ->
        Application.get_env(
          :compos_core,
          :daemon_registry_path,
          Path.expand("~/.compos/daemons.json")
        )
      end,
      {"client-slide!",
       "(client-slide! DIR) — ask this frame's client to slide its panes on the next render; DIR is \"forward\" or \"backward\"."} =>
        fn [dir] ->
          Editor.slide(to_string(dir))
          :void
        end,
      {"navigate-url!", "(navigate-url! URL) — navigate this frame's browser tab to URL."} => fn [
                                                                                                   url
                                                                                                 ] ->
        Editor.navigate(url)
        :void
      end,

      # buffer-local variables
      {"buffer-set-local!", "(buffer-set-local! BUF KEY VALUE) — set a buffer-local variable."} =>
        fn [buf, k, v] ->
          Buffer.set_local(buf, plain(k), v)
          :void
        end,
      {"buffer-set-locals!",
       "(buffer-set-locals! BUF PLIST) — set several buffer-locals in one change; the frame refreshes once, not once per key."} =>
        fn [buf, plist] when is_list(plist) ->
          locals =
            plist
            |> Enum.chunk_every(2)
            |> Enum.map(fn [k, v] -> {plain(k), v} end)
            |> Map.new()

          Buffer.set_locals(buf, locals)
          :void
        end,
      {"group-index-select",
       "(group-index-select NAMES KEYS) — the NAMES, in order, whose group locals name one of KEYS or need the slow path; #f with no index."} =>
        fn [names, keys] when is_list(names) and is_list(keys) ->
          case Compos.Core.GroupIndex.select(names, keys) do
            :error -> false
            hits -> hits
          end
        end,
      {"group-index-buckets",
       "(group-index-buckets [NAMES]) — ((KEY NAME ...) ...): NAMES, every buffer most recent first by default, that are not context-only, by the group key their locals hold, each in the order of NAMES; KEY slow needs the slow path. #f with no index."} =>
        fn args ->
          names = with [names] when is_list(names) <- args, do: names, else: (_ -> Compos.Core.GroupIndex.all())

          case Compos.Core.GroupIndex.buckets(names) do
            :error -> false
            buckets -> Enum.map(buckets, fn {k, ns} -> [if(k == :slow, do: {:sym, "slow"}, else: k) | ns] end)
          end
        end,
      {"group-index-ensure!",
       "(group-index-ensure! [REBUILD]) — build the group index from the buffer rows when it is missing, or file every row again with REBUILD; #t once it exists."} =>
        fn args ->
          Compos.Core.BufferView.ensure_group_index(args == [true])
          Compos.Core.GroupIndex.ready?()
        end,
      {"group-index-modes",
       "(group-index-modes [NAMES]) — ((MODE NAME ...) ...): NAMES, every buffer most recent first by default, by their mode, in the order of their first name; #f with no index."} =>
        fn args ->
          names = with [names] when is_list(names) <- args, do: names, else: (_ -> Compos.Core.GroupIndex.mru())

          case Compos.Core.GroupIndex.modes(names) do
            :error -> false
            modes -> Enum.map(modes, fn {m, ns} -> [m | ns] end)
          end
        end,
      {"group-index-keys",
       "(group-index-keys NAMES) — each name's group key, in order: the id or name its locals hold, slow, or #f; #f with no index."} =>
        fn [names] when is_list(names) ->
          case Compos.Core.GroupIndex.group_keys_of(names) do
            :error ->
              false

            keys ->
              Enum.map(keys, fn
                nil -> false
                :slow -> {:sym, "slow"}
                k -> k
              end)
          end
        end,
      {"group-index-mode-counts",
       "(group-index-mode-counts) — ((MODE N) ...) over every buffer, sorted by mode; #f with no index."} =>
        fn [] ->
          case Compos.Core.GroupIndex.mode_counts() do
            :error -> false
            counts -> Enum.map(counts, fn {m, n} -> [m, n] end)
          end
        end,
      {"buffer-index-select",
       "(buffer-index-select KEYS [NAMES]) — NAMES, every buffer most recent first by default, filed under any of KEYS: (mode MODE), (has LOCAL), or a group key; #f with no index."} =>
        fn [keys | rest] when is_list(keys) ->
          names = with [names] when is_list(names) <- rest, do: names, else: (_ -> Compos.Core.GroupIndex.mru())

          keys =
            Enum.map(keys, fn
              [{:sym, "mode"}, m] -> {:mode, m}
              [{:sym, "has"}, l] -> {:has, Compos.Core.Prims.s(l)}
              k -> k
            end)

          case Compos.Core.GroupIndex.filed(names, keys) do
            :error -> false
            hits -> hits
          end
        end,
      {"buffer-local",
       "(buffer-local BUF KEY) — return a buffer-local variable's value, or #f if unset."} => fn [
                                                                                                   buf,
                                                                                                   k
                                                                                                 ] ->
        Buffer.get_local(buf, plain(k)) || false
      end,
      {"buffer-read-many",
       "(buffer-read-many NAMES FIELDS LOCAL-KEYS) — one metadata snapshot per buffer; rows are (NAME FIELD-VALUES... LOCAL-VALUES...). Missing values are #f. Dormant buffers stay asleep. Fields: path, size, modified, read_only, point, mark, id."} =>
        fn [names, fields, keys] ->
          allowed = ~w(path size modified read_only point mark id)a

          fields =
            Enum.map(fields, fn field ->
              name = plain(field)

              Enum.find(allowed, &(Atom.to_string(&1) == name)) ||
                raise(ArgumentError, "unsupported buffer field: #{name}")
            end)

          Buffer.read_many(names, fields, Enum.map(keys, &plain/1))
        end,
      # every local at once, so a help page can show a buffer's own state.
      # The name comes back as a symbol, the way the setter takes it.
      {"buffer-locals",
       "(buffer-locals BUF) — return ((KEY VALUE) ...) for every buffer-local, sorted by name."} =>
        fn [buf] ->
          buf
          |> Buffer.locals()
          |> Enum.map(fn {k, v} -> {to_string(k), v} end)
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {k, v} -> [{:sym, k}, v || false] end)
        end,

      # mark & region
      {"set-mark!", "(set-mark! POS) — set the mark at byte POS; #f clears the mark."} => fn
        [false] ->
          Buffer.set_mark(Editor.current_buffer(), nil)
          :void

        [pos] ->
          Buffer.set_mark(Editor.current_buffer(), pos)
          :void
      end,
      {"mark", "(mark) — return the mark's byte offset, or #f if no mark is set."} => fn [] ->
        Buffer.mark(Editor.current_buffer()) || false
      end,
      {"region-beginning",
       "(region-beginning) — return the smaller of point and mark as a byte offset."} => fn [] ->
        region_bounds() |> elem(0)
      end,
      {"region-end", "(region-end) — return the larger of point and mark as a byte offset."} =>
        fn [] -> region_bounds() |> elem(1) end,
      {"region-text", "(region-text) — return the text between point and mark."} => fn [] ->
        {s, e} = region_bounds()
        buf = Editor.current_buffer()
        buf |> Buffer.text() |> binary_part(s, e - s)
      end,
      {"delete-region!", "(delete-region!) — delete the text between point and mark."} => fn [] ->
        {s, e} = region_bounds()
        if e > s, do: Buffer.delete_range(Editor.current_buffer(), s, e - s)
        :void
      end,
      {"exchange-point-and-mark!",
       "(exchange-point-and-mark!) — swap point and mark; return #f if no mark is set."} =>
        fn [] ->
          buf = Editor.current_buffer()

          case Buffer.mark(buf) do
            nil ->
              false

            m ->
              p = Buffer.point(buf)
              Buffer.set_mark(buf, p)
              Buffer.goto(buf, m)
              true
          end
        end,

      # tree-sitter: structural nav + queries on the current buffer.
      # Language comes from the buffer-local "ts-lang" (set by modes).
      {"ts-nav",
       "(ts-nav OP) — tree-sitter motion 'forward|'backward|'up|'down; return a byte pos or #f."} =>
        fn [op] ->
          buf = Editor.current_buffer()

          case Buffer.get_local(buf, "ts-lang") do
            nil ->
              false

            lang ->
              case Compos.Core.TS.ts_nav(lang, Buffer.text(buf), Buffer.point(buf), plain(op)) do
                nil -> false
                pos -> pos
              end
          end
        end,
      # node identity is a byte range, so the caller can walk from the node
      # it stands on instead of from the deepest node under point
      {"ts-node",
       "(ts-node KIND START END OP) — the node KIND covers the range (\"\" for the smallest); return its 'at|'parent|'child|'next|'prev|'top as (KIND START END), or #f."} =>
        fn [kind, start, stop, op] ->
          buf = Editor.current_buffer()
          kind = if is_binary(kind), do: kind, else: ""

          case Buffer.ts_node(buf, kind, start, stop, plain(op)) do
            nil -> false
            {kind, s, e} -> [kind, s, e]
          end
        end,
      {"ts-children",
       "(ts-children KIND START END) — the named children of that node as ((KIND START END) ...); the range 0..SIZE names the whole file."} =>
        fn [kind, start, stop] ->
          kind = if is_binary(kind), do: kind, else: ""

          Editor.current_buffer()
          |> Buffer.ts_children(kind, start, stop)
          |> Enum.map(fn {k, s, e} -> [k, s, e] end)
        end,
      {"ts-query",
       "(ts-query QUERY) — run a tree-sitter query; return (CAPTURE START END) byte ranges."} =>
        fn [query] ->
          buf = Editor.current_buffer()

          case Buffer.get_local(buf, "ts-lang") do
            nil ->
              []

            lang ->
              lang
              |> Compos.Core.TS.ts_query_nif(Buffer.text(buf), query)
              |> Enum.map(fn {cap, s, e} -> [cap, s, e] end)
          end
        end,
      # Detached text has no buffer parser state. Search commands use this
      # mechanism for a file or an explicit language without changing a
      # buffer's mode or its incremental parser.
      # A list of queries shares one parse, and the answer is one capture
      # list per query.
      {"ts-query-string",
       "(ts-query-string LANG TEXT QUERY) — run a tree-sitter query on detached text; return (CAPTURE START END) byte ranges. With a list of queries, parse once and return one list per query."} =>
        fn [lang, text, query] ->
          cond do
            not (is_binary(lang) and is_binary(text)) ->
              []

            is_binary(query) ->
              lang
              |> Compos.Core.TS.ts_query_nif(text, query)
              |> Enum.map(fn {cap, s, e} -> [cap, s, e] end)

            is_list(query) and Enum.all?(query, &is_binary/1) ->
              lang
              |> Compos.Core.TS.ts_queries(text, query)
              |> Enum.map(fn caps -> Enum.map(caps, fn {cap, s, e} -> [cap, s, e] end) end)

            true ->
              []
          end
        end,
      # Markdown reads its inline ranges this way: the block grammar names
      # them, and one call runs the inline grammar over each of them.
      {"ts-query-ranges",
       "(ts-query-ranges LANG TEXT RANGES QUERY) — parse each (START END) range of TEXT as LANG, run QUERY on it; return (CAPTURE START END) byte ranges in TEXT."} =>
        fn [lang, text, ranges, query] ->
          if is_binary(lang) and is_binary(text) and is_binary(query) and is_list(ranges) do
            size = byte_size(text)

            ranges =
              for [s, e] <- ranges,
                  is_integer(s),
                  is_integer(e),
                  0 <= s,
                  s < e,
                  e <= size,
                  do: {s, e}

            lang
            |> Compos.Core.TS.ts_query_ranges(text, ranges, query)
            |> Enum.map(fn {cap, s, e} -> [cap, s, e] end)
          else
            []
          end
        end,
      {"ts-langs", "(ts-langs) — return the names of the loaded tree-sitter languages."} =>
        fn [] -> Compos.Core.TS.ts_langs() end,
      # one-shot highlight of detached text (embedded code blocks in
      # prose modes); the buffer's own language never enters into it
      {"ts-highlight-string",
       "(ts-highlight-string LANG TEXT) — highlight TEXT as LANG; return (START END SCOPE) byte ranges, () for an unknown language."} =>
        fn [lang, text] ->
          if is_binary(lang) and is_binary(text) do
            lang
            |> Compos.Core.TS.ts_highlight(text)
            |> Enum.map(fn {s, e, scope} -> [s, e, scope] end)
          else
            []
          end
        end,

      # A diff side is a list of lines, drawn one row each. The lines
      # parse as one text, so a string or a comment that spans lines keeps
      # its colour.
      {"ts-highlight-lines",
       "(ts-highlight-lines LANG LINES) — highlight LINES as one LANG text; return per line its (START END SCOPE) runs, in the line's bytes, without overlap."} =>
        fn [lang, lines] ->
          if is_binary(lang) and is_list(lines) and Enum.all?(lines, &is_binary/1) do
            lang
            |> Compos.Core.TS.highlight_lines(lines)
            |> Enum.map(fn runs -> Enum.map(runs, fn {s, e, scope} -> [s, e, scope] end) end)
          else
            []
          end
        end,

      # search: returns (start end) byte range or #f
      {"buffer-search",
       "(buffer-search Q FROM) — search forward from byte FROM; return (START END) or #f."} =>
        fn [q, from] ->
          case Buffer.search(Editor.current_buffer(), q, from, :forward) do
            {s, e} -> [s, e]
            nil -> false
          end
        end,
      {"buffer-search-backward",
       "(buffer-search-backward Q FROM) — search backward from byte FROM; return (START END) or #f."} =>
        fn [q, from] ->
          case Buffer.search(Editor.current_buffer(), q, from, :backward) do
            {s, e} -> [s, e]
            nil -> false
          end
        end,

      # faces: (set-face-attribute! 'modeline 'bg "#2f3140" 'fg "#fff" ...)
      {"set-face-attribute!",
       "(set-face-attribute! FACE KEY VALUE ...) — set the face's attributes from key-value pairs."} =>
        fn [face | kvs] ->
          attrs =
            kvs
            |> Enum.chunk_every(2)
            |> Map.new(fn [k, v] -> {plain(k), plain(v)} end)

          Editor.set_face(plain(face), attrs)
          :void
        end,
      {"face-clear!",
       "(face-clear! FACE) — forget every attribute of FACE; load-theme clears a face before it applies the theme."} =>
        fn [face] ->
          Editor.clear_face(plain(face))
          :void
        end,
      {"face-batch!",
       "(face-batch! OPS) — apply a list of face changes as one change: (clear FACE) forgets a face, (set FACE KEY VALUE ...) merges attributes. The page renders once, after the last one."} =>
        fn [ops] ->
          ops
          |> Enum.map(fn
            [{:sym, "clear"}, face] ->
              {:clear, plain(face)}

            [{:sym, "set"}, face | kvs] ->
              {:set, plain(face),
               kvs |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {plain(k), plain(v)} end)}
          end)
          |> Editor.set_faces()

          :void
        end,
      {"frame-faces-set!",
       "(frame-faces-set! OPS SKIN [FRAME]) — lay face-batch! OPS and a SKIN stylesheet over the global faces for FRAME alone; OPS #f gives the frame the global faces again."} =>
        fn args ->
          [ops, skin | rest] = args

          ops =
            if is_list(ops),
              do:
                Enum.map(ops, fn
                  [{:sym, "clear"}, face] ->
                    {:clear, plain(face)}

                  [{:sym, "set"}, face | kvs] ->
                    {:set, plain(face),
                     kvs |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {plain(k), plain(v)} end)}
                end),
              else: nil

          fid =
            case rest do
              [f] when is_binary(f) -> f
              _ -> nil
            end

          Editor.set_frame_faces(ops, if(is_binary(skin), do: skin, else: nil), fid)
          :void
        end,
      {"face-attribute",
       "(face-attribute FACE ATTR) — the value FACE sets for ATTR, or #f. Inheritance is resolved by the display, not here."} =>
        fn [face, attr] ->
          case get_in(Editor.faces(), [plain(face), plain(attr)]) do
            nil -> false
            v -> v
          end
        end,
      {"face-list", "(face-list) — the names of every face the editor holds."} => fn [] ->
        Map.keys(Editor.faces())
      end,

      # windows (tiling tree)
      {"split-window!",
       "(split-window! DIR [RATIO]) — split the active window 'h or 'v at RATIO (default 0.5)."} =>
        fn
          [dir] ->
            Editor.split(dir_atom(dir))
            :void

          [dir, ratio] ->
            Editor.split(dir_atom(dir), ratio / 1)
            :void
        end,
      # a dock is a pane of the FRAME, not of a window: it spans the frame
      # and the windows above it shrink by its share
      {"split-root!",
       "(split-root! DIR [RATIO]) — split the FRAME 'h or 'v at RATIO; the new window spans the frame and every other window shrinks. Returns the new window."} =>
        fn
          [dir] -> Editor.split_root(dir_atom(dir))
          [dir, ratio] -> Editor.split_root(dir_atom(dir), ratio / 1)
        end,
      {"delete-window!", "(delete-window!) — delete the active window; return #t on success."} =>
        fn [] -> Editor.delete_window() == :ok end,
      {"delete-window-id!", "(delete-window-id! WIN) — delete window WIN; return #t on success."} =>
        fn [id] -> Editor.delete_window_by_id(id) == :ok end,
      # false when the two panes make no rectangle: only a whole shared
      # edge can merge, so an eat never resizes a pane it leaves alone
      {"window-eat-id!",
       "(window-eat-id! ID VICTIM) — window ID takes the space of window VICTIM; #t when it did."} =>
        fn [id, victim] -> Editor.eat_window(id, victim) == :ok end,
      # hidden windows: a window with no pane keeps its id, buffer, history
      # and point. Which window hides, and when, is Scheme's decision.
      {"window-hidden-list",
       "(window-hidden-list) — return (WIN BUFFER) pairs for the selected frame's hidden windows, most recently used first."} =>
        fn [] -> Enum.map(Editor.hidden_windows(), fn {id, b} -> [id, b] end) end,
      {"window-new-hidden!",
       "(window-new-hidden! BUFFER) — make a hidden window on BUFFER; return its id, or #f."} =>
        fn [buffer] ->
          case Editor.new_hidden_window(buffer) do
            id when is_integer(id) -> id
            _ -> false
          end
        end,
      {"window-swap-hidden!",
       "(window-swap-hidden! VISIBLE HIDDEN) — show hidden window HIDDEN in the pane of VISIBLE, which becomes hidden; #t when it did."} =>
        fn [visible, hidden] -> Editor.swap_hidden_window(visible, hidden) == :ok end,
      {"window-arrange-line!",
       "(window-arrange-line! DIR RATIO IDS) — lay the frame out as one line of windows IDS, visible or hidden; DIR h is side by side, v is stacked; the first pane takes RATIO, or each pane its share when RATIO is a list; a visible window not in IDS becomes hidden; #t when it did."} =>
        fn [dir, ratio, ids] ->
          dir = if plain(dir) == "v", do: :v, else: :h
          Editor.arrange_line(dir, ratio, ids) == :ok
        end,
      {"window-hidden-delete!",
       "(window-hidden-delete! WIN) — delete hidden window WIN; #t when it did."} =>
        fn [id] -> Editor.delete_hidden_window(id) == :ok end,
      {"window-list",
       "(window-list) — return (WIN BUFFER) pairs for the selected frame's windows."} => fn [] ->
        Enum.map(Editor.list_windows(), fn {id, b} -> [id, b] end)
      end,
      # the layout round-trips as one opaque value: Scheme stores it in a
      # buffer-local and hands it back; only Elixir reads its insides.
      # The tree travels as the same tuple spec the desktop file uses,
      # which is what restore_tree accepts.
      {"window-tree",
       "(window-tree) — return the frame's window layout as an opaque value for window-tree-set!."} =>
        fn [] ->
          v = Editor.desktop_view()

          %{
            tree: tree_spec(v.tree),
            active: v.active_buffer,
            hidden: Enum.map(Map.get(v, :hidden, []), &tree_spec/1)
          }
        end,
      {"window-tree-set!",
       "(window-tree-set! LAYOUT) — replace the frame's windows with a layout from window-tree."} =>
        fn [%{tree: tree, active: active} = layout]
           when elem(tree, 0) in [:leaf, :split] ->
          Editor.restore_tree(tree, active)
          # the layout's hidden windows replace the frame's; a layout saved
          # before hidden windows existed has none
          Editor.set_hidden_windows(Map.get(layout, :hidden, []))
          :void
        end,
      # the same look, one level up from window-preview-buffer!: a whole
      # arrangement drawn without an entry in the history
      {"window-tree-preview!",
       "(window-tree-preview! LAYOUT) — draw a layout from window-tree as a look: the windows change, the MRU ring does not."} =>
        fn [%{tree: tree, active: active}]
           when elem(tree, 0) in [:leaf, :split] ->
          Editor.preview_tree(tree, active)
          :void
        end,
      # A saved layout names buffers, and a name can outlive its buffer.
      # Scheme decides what to do about that — visit the file, drop the
      # window — so it must be able to read the names back out.
      {"window-tree-buffers",
       "(window-tree-buffers LAYOUT) — return the buffer names a layout from window-tree holds."} =>
        fn [%{tree: tree}] -> tree_buffers(tree) end,
      {"window-tree-hidden-buffers",
       "(window-tree-hidden-buffers LAYOUT) — return the buffer names of the hidden windows a layout from window-tree holds."} =>
        fn [layout] when is_map(layout) ->
          Enum.flat_map(Map.get(layout, :hidden, []), &tree_buffers/1)
        end,
      # A rename must reach a stored layout too, not only the live frame.
      # The swap is tree mechanics; which stores hold a layout is policy,
      # so Scheme owns the sweep and this returns one renamed copy.
      {"window-tree-rename",
       "(window-tree-rename LAYOUT OLD NEW) — a copy of LAYOUT with the buffer name OLD replaced by NEW."} =>
        fn [%{tree: tree, active: active} = layout, old, new] ->
          %{
            layout
            | tree: tree_rename(tree, old, new),
              active: if(active == old, do: new, else: active)
          }
          |> Map.update(:hidden, [], fn hidden -> Enum.map(hidden, &tree_rename(&1, old, new)) end)
        end,
      # Emacs quit-restore as leaf data: what quit-window undoes in a window
      {"window-restore",
       "(window-restore WIN) — (KIND BUFFER POINT) while WIN still shows what a display or a look put there, else #f. KIND window: the display made WIN; other: it covered BUFFER; preview: a look covers BUFFER."} =>
        fn [id] ->
          case Editor.window_restore(id) do
            {kind, covered, point} ->
              [{:sym, Atom.to_string(kind)}, covered || false, point || false]

            nil ->
              false
          end
        end,
      {"set-window-restore!",
       "(set-window-restore! WIN RECORD) — set WIN's restore record, (KIND BUFFER POINT) as window-restore answers, or #f to clear it."} =>
        fn
          [id, false] ->
            Editor.set_window_restore(id, nil)

          [id, [{:sym, kind}, covered, point]] when kind in ["window", "other", "preview"] ->
            Editor.set_window_restore(
              id,
              {%{"window" => :window, "other" => :other, "preview" => :preview}[kind],
               if(is_binary(covered), do: covered), if(is_integer(point), do: point)}
            )
        end,
      {"window-owner",
       "(window-owner WIN) — the window that asked for WIN (a preview's or a display's owner), or #f."} =>
        fn [id] -> Editor.window_owner(id) || false end,
      {"set-window-owner!",
       "(set-window-owner! WIN OWNER) — record the window OWNER as the one that asked for WIN; #f clears it."} =>
        fn [id, owner] -> Editor.set_window_owner(id, owner) end,
      {"window-rects",
       "(window-rects) — return (WIN BUFFER X Y W H) rows with fractional rectangles."} =>
        fn [] -> Editor.window_rects() end,
      {"select-window!",
       "(select-window! WIN) — make WIN and its frame active; return #t on success."} => fn [id] ->
        Editor.set_active(id) == :ok
      end,
      {"window-swap-id!",
       "(window-swap-id! FIRST SECOND) — swap the buffers of two windows; #t when it did."} =>
        fn [first, second] ->
          Editor.swap_windows(first, second) == :ok
        end,
      {"active-window", "(active-window) — return the active window's id."} => fn [] ->
        Editor.active_window()
      end,
      {"window-point",
       "(window-point WIN) — WIN's own point (Emacs window-point): the buffer's for the selected window, the stored one for any other; #f for no window."} =>
        fn [id] ->
          case Editor.window_point(id) do
            {:ok, p} -> p
            _ -> false
          end
        end,
      {"window-set-point!",
       "(window-set-point! WIN POS) — put WIN's point at byte POS (Emacs set-window-point); #t when WIN exists."} =>
        fn [id, pos] -> Editor.set_window_point(id, pos) == :ok end,
      {"scroll-window!",
       "(scroll-window! WIN LINES) — scroll window WIN by LINES; return #t on success."} => fn [
                                                                                                 id,
                                                                                                 lines
                                                                                               ] ->
        Editor.scroll_window(id, lines) == :ok
      end,
      {"delete-other-windows!",
       "(delete-other-windows!) — delete every window in the frame except the active one."} =>
        fn [] ->
          Editor.delete_other_windows()
          :void
        end,
      {"other-window!", "(other-window!) — select the next window in the frame."} => fn [] ->
        Editor.other_window()
        :void
      end,
      {"switch-to-buffer!",
       "(switch-to-buffer! BUF) — show BUF in the active window; return BUF."} => fn [name] ->
        # A forgotten name gets a fresh buffer here too — C-x b creates. A
        # dormant name wakes through the one door.
        started!(Core.ensure_buffer(name))

        if Compos.Core.Frame.buffer_context(),
          do: Compos.Core.Frame.put_buffer(name),
          else: Editor.set_window_buffer(name)

        name
      end,
      # editor.scm wraps this raw primitive: switch-to-buffer-here! runs
      # restore-buffer-runtime! itself, inline, so a dormant buffer's mode
      # setup completes in the current interpreter before the switch
      # returns. The wake here therefore queues no rebuild of its own.
      {"window-switch-buffer!",
       "(window-switch-buffer! BUF) — raw switch that restores a dormant BUF inline; return BUF."} =>
        fn [name] ->
          started!(Core.ensure_buffer(name, restore: false))

          if Compos.Core.Frame.buffer_context(),
            do: Compos.Core.Frame.put_buffer(name),
            else: Editor.set_window_buffer(name)

          name
        end,

      # frames: one per attached client; window primitives above act on the
      # selected frame implicitly. delete-frame! lives in Session (it must
      # fire an active prompt's on_cancel in the current store).
      {"frame-list", "(frame-list) — return frame ids in most-recently-used order."} => fn [] ->
        Editor.frame_list()
      end,
      # A client subscribes to its own frame (Events.subscribe_frame), so the
      # subscriber count is the number of clients that show the frame now.
      {"frame-clients", "(frame-clients ID) — return the number of clients attached to frame ID."} =>
        fn [id] ->
          length(Registry.lookup(Compos.Core.Events.registry(), {:frame, id}))
        end,
      {"selected-frame", "(selected-frame) — return the current frame's id."} => fn [] ->
        Compos.Core.Frame.current() || Editor.last_active_frame()
      end,
      {"select-frame!", "(select-frame! FRAME) — make FRAME current; return #t on success."} =>
        fn [id] ->
          # commands run with the dispatching frame stamped in the pdict —
          # retarget it too, or the next primitive undoes the selection
          ok = Editor.select_frame(id) == :ok
          if ok, do: Compos.Core.Frame.put(id)
          ok
        end,
      # a frame of its own: the multi-frame tests and a script that opens a
      # second workspace ask for one
      {"make-frame!", "(make-frame!) — create a frame and return its id."} => fn [] ->
        {:ok, id} = Editor.attach_frame(nil)
        id
      end,
      # every window everywhere: ((id buffer frame-id) ...) — the cross-frame
      # walk for kill-buffer replacement, agent window release
      {"window-list-all",
       "(window-list-all) — return (WIN BUFFER FRAME) rows for every window in every frame."} =>
        fn [] ->
          Enum.map(Editor.list_windows_all(), fn {id, b, fid} -> [id, b, fid] end)
        end,
      # set any window's buffer without selecting it (no frame/focus change)
      {"window-set-buffer!",
       "(window-set-buffer! WIN BUF) — show BUF in window WIN without selection; return #t."} =>
        fn [id, name] ->
          Editor.window_set_buffer(id, name) == :ok
        end,
      {"frame-of-window", "(frame-of-window WIN) — return the id of the window's frame, or #f."} =>
        fn [id] -> Editor.frame_of_window(id) || false end,

      # minibuffer & keymap — 3-arity: (prompt candidates on-confirm);
      # 4-arity adds an on-complete fn: input -> (list new-input candidates)
      {"minibuffer-read",
       "(minibuffer-read PROMPT CANDIDATES [ON-COMPLETE] ON-CONFIRM) — activate the minibuffer."} =>
        fn
          [prompt, candidates, callback] ->
            Editor.minibuffer_activate(prompt, candidates, callback)
            :void

          [prompt, candidates, on_complete, callback] ->
            Editor.minibuffer_activate(prompt, candidates, callback, on_complete)
            :void
        end,
      # full form: handlers is an alist of (list 'confirm f) (list 'change f)
      # (list 'complete f) (list 'cancel f) (list 'collect f) (list 'initial "text")
      # (list 'match-hint #t) — the last one widens the filter to the
      # annotation, so a prompt matches what a candidate MEANS. #t means
      # the first field; an integer N means the first N fields.
      {"minibuffer-read*",
       "(minibuffer-read* PROMPT CANDIDATES HANDLERS) — activate the minibuffer with a handler alist: confirm, cancel, complete, change, collect, initial, filter, match-hint, completion-style, preselect, style (\"palette\" floats), note (the palette rail's footer line), legend (((KEY LABEL) ...) for the palette head). A candidate is LABEL, (LABEL HINT), (LABEL HINT KIND), (LABEL HINT KIND CHIPS [FACE]), or (LABEL HINT KIND CHIPS FACE FACTS) where FACTS is ((KEY VALUE) ...) for the palette rail."} =>
        fn [prompt, candidates, handlers] ->
          map =
            Map.new(handlers, fn [k, v] ->
              case plain(k) do
                "initial" -> {:input, v}
                # A dynamic provider has already filtered/ranked its results.
                "filter" -> {:filter, v}
                "match-hint" -> {:match_hint, v}
                # how the input matches a candidate: flex, substring, prefix,
                # regexp, exact. The prompt chooses; the engine applies.
                "completion-style" -> {:completion_style, Compos.Core.Candidates.style(v)}
                # which row RET takes when the person did not arrow: 'first is
                # the highlighted candidate (vertico), 'prompt is the typed
                # input. A destination prompt (write-file) asks for 'prompt.
                "preselect" -> {:preselect, String.to_atom(plain(v))}
                # A prompt can reuse a domain list when its filtered result is
                # collected. Scheme decides the target and receives the rows.
                "collect" -> {:on_collect, v}
                # the shape the prompt takes: "modal" (a centered panel over
                # a scrim, spelled "palette" before it had a name), "popup"
                # (an overlay on the bottom edge that reflows nothing), or the
                # minibuffer rows, which every other value asks for
                "style" -> {:style, v}
                # the palette's own words: a footer note for the facts rail
                # and a key legend for the head row, ((KEY LABEL) ...)
                "note" -> {:note, v}
                "legend" -> {:legend, v}
                key -> {String.to_existing_atom("on_" <> key), v}
              end
            end)

          Editor.minibuffer_activate_full(prompt, candidates, map)
          :void
        end,
      {"transient-show!",
       "(transient-show! MENU) — show this frame's Transient modal; #t locks keys with no menu; #f clears it."} =>
        fn
          [false] ->
            Editor.set_transient(nil)
            :void

          # #t locks key routing to the frame's transient keymap with no menu
          # panel: the overview needs modal keys over a visible layout
          [true] ->
            Editor.set_transient(%{lock: true})
            :void

          [[title, groups]] ->
            Editor.set_transient(transient_menu(title, groups, []))
            :void

          # (TITLE GROUPS META): META is an alist of header, rail, and legend
          # parts. Scheme decides what each transient says; this only carries
          # the strings to the frame.
          [[title, groups, meta]] ->
            Editor.set_transient(transient_menu(title, groups, meta))
            :void
        end,
      # the dispatcher's ladder reads the frame in one call
      {"key-context",
       "(key-context) — (BUFFER OVERRIDING) for a key lookup: the buffer the key acts on, and (KEYMAP LOCK?) for the frame's overriding keymap or #f."} =>
        fn [] ->
          %{buffer: buffer, overriding: over} = Editor.key_context()

          [
            buffer,
            case over do
              %{map: m, lock: lock} -> [m, lock == true]
              _ -> false
            end
          ]
        end,
      {"overriding-map!",
       "(overriding-map! KEYMAP [LOCK?] [UNTIL-COMMAND?]) — the frame's overriding keymap, ahead of every other; #f clears it. LOCK? makes an unbound key undefined (Transient). UNTIL-COMMAND? drops it when the next command finishes (the prefix argument)."} =>
        fn
          [false] ->
            Editor.set_overriding_map(nil)

          [name] ->
            Editor.set_overriding_map(plain(name))

          [name, lock] ->
            Editor.set_overriding_map(plain(name), lock == true)

          [name, lock, until] ->
            Editor.set_overriding_map(plain(name), lock == true, until == true)
        end,
      {"completion-requery!",
       "(completion-requery!) — narrow the popup to the text between its start and point."} =>
        fn [] ->
          Compos.Core.KeyDispatch.requery_completion()
          :void
        end,
      {"ignore-errors", "(ignore-errors THUNK) — THUNK's value, or #f when it raises."} => fn [
                                                                                                thunk
                                                                                              ],
                                                                                              store ->
        try do
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
        rescue
          _ -> {false, store}
        catch
          _, _ -> {false, store}
        end
      end,
      # describe-key arms this, then reads the sequence back with (last-keys)
      {"capture-key!",
       "(capture-key! COMMAND) — the next key sequence runs COMMAND instead of its own binding; COMMAND reads it with (last-keys). #f disarms."} =>
        fn [command] ->
          Editor.set_key_capture(command)
          :void
        end,
      # the mechanism under (trace-key): KeyDispatch records a row per phase
      {"trace-key!",
       "(trace-key! KEYS) — dispatch the key list in this process; return one state row per phase."} =>
        fn [specs] ->
          specs
          |> List.wrap()
          |> Enum.flat_map(&String.split(plain(&1), " ", trim: true))
          |> Compos.Core.KeyDispatch.trace_keys()
        end,
      # a mode's own stylesheet, rendered into the page beside the face
      # variables. Modes are trusted code — they can eval anything — so the
      # CSS ships raw.
      {"define-style!",
       "(define-style! NAME CSS) — register a stylesheet the page renders; modes ship their own CSS with this."} =>
        fn [name, css] ->
          Editor.set_style(plain(name), css)
          :void
        end,
      {"style-css",
       "(style-css NAME) — the stylesheet NAME wears now, or \"\" when nothing registered one."} =>
        fn [name] -> Editor.style_css(plain(name)) end,
      # The languages whose blocks offer the run key in the rendered page.
      # The fence-kind registry pushes the list on every registration, so
      # the page never mirrors the registry by hand.
      {"preview-run-langs!",
       "(preview-run-langs! LANGS) — name the block languages whose rendered page offers the run key; the fence-kind registry calls this."} =>
        fn [langs] ->
          :persistent_term.put(
            {Compos.Core.Markdown.Html, :run_langs},
            Enum.map(langs, &String.downcase/1)
          )

          :void
        end,
      {"last-command", "(last-command) — return the name of the last command that ran."} =>
        fn [] -> Editor.last_command() end,
      {"this-command",
       "(this-command) — the name of the command now running; \"\" outside a command."} =>
        fn [] -> Editor.this_command() end,
      {"set-this-command!",
       "(set-this-command! NAME) — what the next command sees as last-command; yank-pop sets \"yank\"."} =>
        fn [name] ->
          Editor.set_this_command(name)
          :void
        end,
      {"undo-boundary!",
       "(undo-boundary!) — Emacs undo-boundary: the edits so far are one undo step, the edits after this are the next, even inside one command."} =>
        fn [] ->
          Buffer.undo_boundary(Editor.current_buffer())
          :void
        end,
      {"last-keys",
       "(last-keys) — return the key sequence whose keymap lookup ran the current command."} =>
        fn [] -> Editor.last_keys() end,
      {"current-prefix-arg",
       "(current-prefix-arg) — return this frame's raw one-shot prefix argument, or #f."} =>
        fn [] -> Editor.prefix_arg() || false end,
      {"set-prefix-arg!",
       "(set-prefix-arg! VALUE) — set this frame's raw one-shot prefix argument; #f clears it."} =>
        fn [arg] ->
          Editor.set_prefix_arg(arg)
          :void
        end,
      {"window-rows",
       "(window-rows [WIN]) — text rows of WIN, or of the active window when WIN is omitted."} =>
        fn
          [] -> Editor.window_rows()
          [win] when is_integer(win) -> Editor.window_rows(win)
          _ -> Editor.window_rows()
        end,
      # the client measures its own font and reports it; a window nobody
      # measured is worth the default
      {"buffer-cols",
       "(buffer-cols BUF) — return the text columns of a window showing BUF, else the active window's."} =>
        fn [name] -> Editor.buffer_cols(name) end,
      {"window-cols",
       "(window-cols [WIN]) — return the number of text columns in WIN, or in the active window."} =>
        fn
          [] -> Editor.window_cols()
          [win] when is_integer(win) -> Editor.window_cols(win)
          _ -> Editor.window_cols()
        end,
      # the wrap map is a measurement the client made; Scheme reads it
      # and decides what a row move means
      {"window-wrap-map",
       "(window-wrap-map WIN) — return (VERSION ROWS) as the client measured WIN: the buffer version the page showed, and the byte offsets where its visual rows begin; #f when nothing was measured."} =>
        fn
          [win] when is_integer(win) ->
            case Editor.wrap_map(win) do
              {v, rows} -> [v, rows]
              _ -> false
            end

          _ ->
            false
        end,
      {"window-set-wrap-map!",
       "(window-set-wrap-map! WIN VERSION ROWS) — record a wrap map for WIN the way the client does; for tests and headless drivers."} =>
        fn [win, v, rows]
           when is_integer(win) and is_integer(v) and is_list(rows) ->
          Editor.set_wrap_map(win, v, rows)
          :void
        end,
      {"buffer-version",
       "(buffer-version BUF) — return the buffer's edit version; it grows by one per change."} =>
        fn [name] -> Buffer.version(name) || 0 end,
      {"frame-cols", "(frame-cols) — estimate the usable text columns across the current frame."} =>
        fn [] -> Editor.frame_cols() end,
      {"recenter!", "(recenter!) — center the active window on the cursor line."} => fn [] ->
        Editor.recenter()
        :void
      end,

      # completion popup: candidates = strings or (label hint) pairs
      {"completion-show!",
       "(completion-show! START END CANDIDATES) — show the completion popup for the text START..END; accept replaces that range, and END may lie past point."} =>
        fn [start, end_, candidates] ->
          point = Buffer.point(Editor.current_buffer())
          tail = if is_integer(end_), do: end_ - point, else: 0
          Editor.completion_show(start, tail, candidates)
          :void
        end,
      {"completion-move!", "(completion-move! DELTA) — move the popup selection by DELTA rows."} =>
        fn [delta] ->
          Editor.completion_move(delta)
          :void
        end,
      {"completion-accept!",
       "(completion-accept!) — close the popup; return (START END LABEL) of the selection, END as of now, or #f."} =>
        fn [] ->
          case Editor.completion_accept() do
            {start, tail, label} -> [start, Buffer.point(Editor.current_buffer()) + tail, label]
            nil -> false
          end
        end,
      # the one matcher every surface narrows with; STYLE as in completion-style
      {"completion-match?",
       "(completion-match? LABEL QUERY [STYLE]) — does QUERY match LABEL the way a prompt matches: 'flex (default), 'substring, 'prefix, 'regexp, 'exact."} =>
        fn
          [label, query] ->
            Compos.Core.Candidates.matches?(label, query, [], :flex)

          [label, query, style] ->
            Compos.Core.Candidates.matches?(label, query, [], Compos.Core.Candidates.style(style))
        end,
      {"regexp-quote", "(regexp-quote TEXT) — TEXT with every regexp character escaped."} => fn [
                                                                                                  text
                                                                                                ] ->
        Regex.escape(text)
      end,
      {"completion-dismiss!", "(completion-dismiss!) — dismiss the completion popup."} => fn [] ->
        Editor.completion_dismiss()
        :void
      end,
      # words in the current buffer with the given prefix (dabbrev fuel)
      {"buffer-words",
       "(buffer-words PREFIX) — return the buffer's words with PREFIX, sorted, without PREFIX itself."} =>
        fn [prefix] ->
          text = Buffer.text(Editor.current_buffer())

          ~r/[A-Za-z_][A-Za-z0-9_?!-]*/
          |> Regex.scan(text)
          |> List.flatten()
          |> Enum.uniq()
          |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 != prefix))
          |> Enum.sort()
        end,
      # whitespace-separated word count (writing-mode modeline, M-x count-words)
      {"count-words", "(count-words BUF) — return the buffer's whitespace-separated word count."} =>
        fn [buf] ->
          ~r/\S+/ |> Regex.scan(Buffer.text(buf)) |> length()
        end,
      # the highlighted candidate (consult-style preview reads it on move)
      {"minibuffer-selected",
       "(minibuffer-selected) — return the highlighted minibuffer candidate."} => fn [] ->
        Editor.minibuffer_selected()
      end,
      # escape hatch: current-buffer defaults to the minibuffer's OWN text
      # while one is active, so a preview hook that wants to act on the
      # invoking buffer (e.g. goto-char! for a same-buffer position
      # preview) must toggle this off around that call, then back on
      {"set-mb-redirect!",
       "(set-mb-redirect! BOOL) — toggle redirection of current-buffer to the minibuffer's text."} =>
        fn [bool] ->
          Editor.set_mb_redirect(bool)
          :void
        end,
      # show a buffer in a window without MRU bookkeeping — candidate
      # preview must not reorder the buffer ring. The optional WIN is the
      # modal switcher's home window; default is the active window.
      {"window-preview-buffer!",
       "(window-preview-buffer! BUF [WIN]) — show BUF in WIN (default: the active window) without MRU changes."} =>
        fn
          [name] -> Editor.preview_buffer(name) == :ok
          [name, win] -> Editor.preview_buffer(name, nil, win) == :ok
        end,
      # the way back to dormancy: preview wakes candidates, the prompt's
      # close puts the ones nobody picked back to sleep
      {"buffer-sleep!",
       "(buffer-sleep! NAME) — checkpoint NAME and stop its process; the buffer stays known. #f when NAME is on screen, busy, or pinned."} =>
        fn [name] ->
          Compos.Core.sleep_buffer(name) == :ok
        end,
      {"minibuffer-set-candidates!",
       "(minibuffer-set-candidates! CANDIDATES) — replace the minibuffer's candidate list."} =>
        fn [candidates] ->
          Editor.minibuffer_set_candidates(candidates)
          :void
        end,
      {"set-frame-group-label!",
       "(set-frame-group-label! NAME [FRAME]) — record a frame's group context; #f clears it. FRAME defaults to the selected one."} =>
        fn
          [label] ->
            Editor.set_frame_group_label(if(is_binary(label), do: label, else: nil))
            :void

          [label, fid] ->
            Editor.set_frame_group_label(
              if(is_binary(label), do: label, else: nil),
              if(is_binary(fid), do: fid, else: nil)
            )

            :void
        end,
      {"set-frame-group-style!",
       "(set-frame-group-style! NAME COLOR [FRAME]) — record a frame's group label and accent color."} =>
        fn
          [label, color] ->
            Editor.set_frame_group_style(
              if(is_binary(label), do: label, else: nil),
              if(is_binary(color), do: color, else: nil)
            )

            :void

          [label, color, fid] ->
            Editor.set_frame_group_style(
              if(is_binary(label), do: label, else: nil),
              if(is_binary(color), do: color, else: nil),
              if(is_binary(fid), do: fid, else: nil)
            )

            :void
        end,

      # filesystem (dired's hands)
      {"delete-file!",
       "(delete-file! PATH) — delete a file or empty directory; return #t or error."} => fn [p] ->
        path = Path.expand(p)

        result =
          case File.lstat(path) do
            {:ok, %{type: :directory}} -> File.rmdir(path)
            {:ok, _} -> File.rm(path)
            {:error, reason} -> {:error, reason}
          end

        case result do
          :ok ->
            true

          {:error, reason} ->
            raise Compos.Scheme.Eval.Error, message: "delete failed: #{reason} (#{path})"
        end
      end,
      {"trash-file!",
       "(trash-file! PATH) — move one file or directory to the user trash; return its new path."} =>
        fn [p] ->
          path = Path.expand(p)
          trash = user_trash_dir()
          :ok = File.mkdir_p(trash)
          target = unused_path(Path.join(trash, Path.basename(path)))

          case File.rename(path, target) do
            :ok ->
              target

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error,
                message: "trash failed: #{reason} (#{path} -> #{target})"
          end
        end,
      {"copy-file!",
       "(copy-file! SOURCE DESTINATION) — copy one file or directory without overwriting; return DESTINATION."} =>
        fn [source, destination] ->
          source = Path.expand(source)
          destination = Path.expand(destination)

          cond do
            path_present?(destination) ->
              raise Compos.Scheme.Eval.Error,
                message: "copy failed: destination exists (#{destination})"

            true ->
              :ok = File.mkdir_p(Path.dirname(destination))

              case File.cp_r(source, destination) do
                {:ok, _paths} ->
                  destination

                {:error, reason, failed} ->
                  raise Compos.Scheme.Eval.Error,
                    message: "copy failed: #{reason} (#{failed})"
              end
          end
        end,
      {"set-file-mode!", "(set-file-mode! PATH MODE) — set octal MODE such as 755 on PATH."} =>
        fn [p, mode] ->
          path = Path.expand(p)

          with {value, ""} <- Integer.parse(to_string(mode), 8),
               :ok <- File.chmod(path, value) do
            true
          else
            :error ->
              raise Compos.Scheme.Eval.Error, message: "invalid octal mode: #{mode}"

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error,
                message: "chmod failed: #{reason} (#{path})"

            {_value, _rest} ->
              raise Compos.Scheme.Eval.Error, message: "invalid octal mode: #{mode}"
          end
        end,
      {"touch-file!", "(touch-file! PATH) — update PATH's mtime or create an empty file."} => fn [
                                                                                                   p
                                                                                                 ] ->
        path = Path.expand(p)
        :ok = File.mkdir_p(Path.dirname(path))

        case File.touch(path) do
          :ok ->
            true

          {:error, reason} ->
            raise Compos.Scheme.Eval.Error,
              message: "touch failed: #{reason} (#{path})"
        end
      end,
      {"make-symlink!",
       "(make-symlink! TARGET LINK) — create LINK as a symbolic link to TARGET without overwriting."} =>
        fn [target, link] ->
          link = Path.expand(link)

          if path_present?(link) do
            raise Compos.Scheme.Eval.Error,
              message: "link failed: destination exists (#{link})"
          else
            :ok = File.mkdir_p(Path.dirname(link))

            case File.ln_s(target, link) do
              :ok ->
                link

              {:error, reason} ->
                raise Compos.Scheme.Eval.Error,
                  message: "link failed: #{reason} (#{link})"
            end
          end
        end,
      # the buffer keeps its process, so nothing in it moves. A name that is
      # taken (live or in history) answers false: the caller picks another.
      {"buffer-rename!",
       "(buffer-rename! OLD NEW) — rename a buffer in place, keeping its text, point, locals and undo; return NEW, or #f if the name is taken. Policy lives in rename-buffer!."} =>
        fn [old, new] ->
          case Compos.Core.rename_buffer(old, new) do
            {:ok, name} -> name
            {:error, _reason} -> false
          end
        end,
      {"rename-file!",
       "(rename-file! SOURCE DESTINATION) — move a file or directory and carry an open buffer with it."} =>
        fn [source, destination] ->
          case Compos.Core.rename_file(source, destination) do
            {:ok, path} ->
              path

            {:error, reason} ->
              raise Compos.Scheme.Eval.Error,
                message:
                  "rename failed: #{reason} (#{Path.expand(source)} -> #{Path.expand(destination)})"
          end
        end,
      {"make-directory!",
       "(make-directory! PATH) — create the directory and its parents; return #t."} => fn [p] ->
        File.mkdir_p!(Path.expand(p))
        true
      end
    }
  end

  # --- git (Compos.Core.Git; policy in packages/git.scm) ----------------------
  # Every primitive takes an optional trailing callback. With one, the git
  # command runs in a supervised Task and the callback gets the value — the
  # Session never blocks on git. Without one, the caller waits: an agent
  # through the RPC `eval` path needs an answer, not a promise.
  #
  # Values cross as plists — (key value ...) with symbol keys. An error is
  # the plist (error "message"), which `list?` tells apart from a string.
  defp git_primitives do
    %{
      {"git-root",
       "(git-root DIR [CB]) — return the absolute work-tree root of DIR, or (error MSG)."} => fn [
                                                                                                   dir
                                                                                                   | rest
                                                                                                 ] ->
        git_dispatch(rest, fn -> Git.root(dir) end, & &1)
      end,
      # (git-status DIR [PATHSPEC] [CALLBACK]) — a pathspec scopes the read
      # to one subtree, so the diff you get is the directory you are in
      # (diff-word-range OLD NEW) -> ((OS OE) (NS NE)), or #f when the two
      # lines differ at neither end. Byte scanning with UTF-8 boundaries is
      # mechanism; deciding what to emphasise with it is diff-mode's.
      {"diff-word-range",
       "(diff-word-range OLD NEW) — return ((OS OE) (NS NE)) byte ranges of the differing span, or #f."} =>
        fn [old, new] ->
          case word_range(old, new) do
            nil -> false
            {{os, oe}, {ns, ne}} -> [[os, oe], [ns, ne]]
          end
        end,
      # (diff-parse TEXT) -> the same file plists git-diff returns. Text that
      # git handed us whole — a commit — has no structured form of its own.
      {"diff-parse",
       "(diff-parse TEXT) — parse unified-diff TEXT into the same file plists git-diff returns."} =>
        fn [text] ->
          text |> Compos.Core.Git.parse() |> diff_plist()
        end,
      {"git-prefix",
       "(git-prefix DIR [CB]) — return DIR's path inside its work tree with a trailing slash, or \"\" at the root."} =>
        fn [dir | rest] ->
          git_dispatch(rest, fn -> Git.prefix(dir) end, & &1)
        end,
      {"git-status",
       "(git-status DIR [PATHSPEC] [CB]) — return (path P orig-path P2 index X worktree Y) plists; a pathspec scopes the read."} =>
        fn [dir | rest] ->
          {path, rest} = opt_path(rest)

          git_dispatch(
            rest,
            fn -> Git.status(dir, path) end,
            &Enum.map(&1, fn e -> status_plist(e) end)
          )
        end,
      # (git-diff DIR) | (git-diff DIR OPTS) | (git-diff DIR OPTS CALLBACK)
      {"git-diff",
       "(git-diff DIR [OPTS] [CB]) — return parsed file plists; OPTS is (base REF path P staged BOOL)."} =>
        fn
          [dir] ->
            git_dispatch([], fn -> Git.diff(dir, []) end, &diff_plist/1)

          [dir, opts] ->
            if callback?(opts) do
              git_dispatch([opts], fn -> Git.diff(dir, []) end, &diff_plist/1)
            else
              git_dispatch([], fn -> Git.diff(dir, diff_opts(opts)) end, &diff_plist/1)
            end

          [dir, opts | rest] ->
            git_dispatch(rest, fn -> Git.diff(dir, diff_opts(opts)) end, &diff_plist/1)
        end,
      {"git-stage-file",
       "(git-stage-file DIR PATH [CB]) — stage one path in the index; return #t or (error MSG)."} =>
        fn [dir, path | rest] ->
          git_dispatch(rest, fn -> Git.stage_file(dir, path) end, fn _ -> true end)
        end,
      {"git-stage-patch",
       "(git-stage-patch DIR PATCH [CB]) — apply one unified patch to the index; return #t or (error MSG)."} =>
        fn [dir, patch | rest] ->
          git_dispatch(rest, fn -> Git.stage_patch(dir, patch) end, fn _ -> true end)
        end,
      {"git-log",
       "(git-log DIR N [PATHSPEC] [CB]) — return the last N commits as (sha short-sha author date subject) plists."} =>
        fn [dir, n | rest] ->
          {path, rest} = opt_path(rest)

          git_dispatch(
            rest,
            fn -> Git.log(dir, n, path) end,
            &Enum.map(&1, fn c -> log_plist(c) end)
          )
        end,
      {"git-show", "(git-show DIR REF [CB]) — return the raw text of one commit."} => fn [
                                                                                           dir,
                                                                                           ref
                                                                                           | rest
                                                                                         ] ->
        git_dispatch(rest, fn -> Git.show(dir, plain(ref)) end, & &1)
      end
    }
  end

  # --- the file watcher (Compos.Core.Watch) -----------------------------------
  # The event is content-free: it names the root and nothing else, so the
  # handler re-queries. `fs-on-change!` holds ONE handler, like
  # `on-event!`; editor.scm keeps the subscriber list, because a list of
  # subscribers is policy.
  defp watch_primitives do
    %{
      {"watch-path!",
       "(watch-path! DIR ['deep]) — watch DIR for changes, refcounted; return the watched root or (error MSG). A plain watch counts the direct children of DIR; 'deep counts the whole tree below it."} =>
        fn [dir | rest] ->
          deep? = rest == [{:sym, "deep"}]

          case Compos.Core.Watch.watch(plain(dir), Compos.Core.Watch, deep: deep?) do
            {:ok, root} -> root
            {:error, msg} -> [{:sym, "error"}, msg]
          end
        end,
      {"unwatch-path!",
       "(unwatch-path! DIR ['deep]) — drop one watch reference, 'deep for a deep one; the subscription stops at zero."} =>
        fn [dir | rest] ->
          Compos.Core.Watch.unwatch(plain(dir), Compos.Core.Watch, deep: rest == [{:sym, "deep"}])
          :void
        end,
      {"watched-paths", "(watched-paths) — return the watched roots."} => fn [] ->
        Compos.Core.Watch.watching()
      end,
      {"fs-on-change!",
       "(fs-on-change! FN) — register the ONE handler that gets a root when a watched tree changes."} =>
        fn [handler] ->
          Roots.put({:fs_handler}, handler)
          :void
        end,
      # clicking a block in a rich view. The client holds a buffer and the
      # block's own id string, not a command, so it needs a closure to hand
      # them to — the same one-handler shape as on-event! and
      # fs-on-change!. What an id means is the mode's business.
      {"block-on-click!",
       "(block-on-click! FN) — register the ONE handler that gets (BUF ID) when a block with a click id is clicked."} =>
        fn [handler] ->
          Roots.put({:block_click_handler}, handler)
          :void
        end
    }
  end

  @doc """
  Run the registered block click handler. The UI calls this: it holds a
  buffer and an opaque block id, and the policy for what a click does is
  Scheme's.
  """
  def block_click(buffer, id) do
    with handler when handler != nil <- Roots.get({:block_click_handler}) do
      Compos.Core.Session.apply_callback(handler, [buffer, id])
    end

    :ok
  end

  # The intra-line diff: strip the common prefix and the common suffix and
  # report what is left on each side. Exact when one span changed, which is
  # what most edited lines are, and it never lies about the ends.
  defp word_range(old, new) do
    p = common_prefix_len(old, new)

    s =
      common_suffix_len(
        binary_part(old, p, byte_size(old) - p),
        binary_part(new, p, byte_size(new) - p)
      )

    omid = byte_size(old) - p - s
    nmid = byte_size(new) - p - s

    if omid <= 0 and nmid <= 0,
      do: nil,
      else: {{p, p + omid}, {p, p + nmid}}
  end

  defp common_prefix_len(a, b), do: common_prefix_len(a, b, 0)

  defp common_prefix_len(a, b, i) do
    if i < byte_size(a) and i < byte_size(b) and :binary.at(a, i) == :binary.at(b, i),
      do: common_prefix_len(a, b, i + 1),
      else: utf8_floor(a, i)
  end

  defp common_suffix_len(a, b), do: common_suffix_len(a, b, 0)

  defp common_suffix_len(a, b, i) do
    sa = byte_size(a) - 1 - i
    sb = byte_size(b) - 1 - i

    if sa >= 0 and sb >= 0 and :binary.at(a, sa) == :binary.at(b, sb),
      do: common_suffix_len(a, b, i + 1),
      # the suffix STARTS at byte_size - i, and that index must be a
      # character boundary too, or the emphasis splits a codepoint
      else: byte_size(a) - utf8_floor(a, byte_size(a) - i)
  end

  # never split a multi-byte character: walk back off a continuation byte
  defp utf8_floor(_bin, 0), do: 0

  defp utf8_floor(bin, i) do
    if i < byte_size(bin) and Bitwise.band(:binary.at(bin, i), 0xC0) == 0x80,
      do: utf8_floor(bin, i - 1),
      else: i
  end

  # a leading string in the tail is a pathspec; a closure is the callback
  defp opt_path([p | rest]) when is_binary(p), do: {p, rest}
  defp opt_path(rest), do: {nil, rest}

  defp git_dispatch([], work, shape), do: git_value(work.(), shape)

  defp git_dispatch([callback | _], work, shape),
    do: async_dispatch(callback, fn -> git_value(work.(), shape) end)

  # run WORK in a Task and hand its value to CALLBACK through the Session —
  # the single writer of the interpreter store. The closure stays rooted in
  # Roots until the callback fires, which protects it from the GC.
  defp async_dispatch(callback, work) do
    key = {:async_call, make_ref()}
    rooted? = Roots.put(key, callback)

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      value = work.()

      try do
        Compos.Core.Session.apply_callback(callback, [value])
      after
        if rooted?, do: Roots.drop(key)
      end
    end)

    :void
  end

  # a plist Scheme reads: nil becomes #f, which every caller already handles
  defp catalog_plist(info) when is_map(info) do
    for key <- [:snapshot_id, :captured_at, :models, :providers, :stale_days, :path],
        reduce: [] do
      acc ->
        name = key |> Atom.to_string() |> String.replace("_", "-")
        acc ++ [{:sym, name}, Map.get(info, key) || false]
    end
  end

  defp git_value({:ok, value}, shape), do: shape.(value)
  defp git_value({:error, msg}, _shape), do: [{:sym, "error"}, msg]

  defp callback?({:closure, _, _, _}), do: true
  defp callback?({:builtin, _, _}), do: true
  defp callback?({:interposed, _, _}), do: true
  defp callback?(_), do: false

  defp status_plist(e) do
    [
      {:sym, "path"},
      e.path,
      {:sym, "orig-path"},
      e.orig_path || false,
      {:sym, "index"},
      e.index,
      {:sym, "worktree"},
      e.worktree
    ]
  end

  defp diff_plist(files) do
    for f <- files do
      [
        {:sym, "file-a"},
        f.file_a || false,
        {:sym, "file-b"},
        f.file_b || false,
        {:sym, "binary?"},
        f.binary?,
        {:sym, "patch-head"},
        Map.get(f, :patch_head, ""),
        {:sym, "start-byte"},
        Map.get(f, :start_byte, 0),
        {:sym, "end-byte"},
        Map.get(f, :end_byte, 0),
        {:sym, "hunks"},
        Enum.map(f.hunks, &hunk_plist/1)
      ]
    end
  end

  defp hunk_plist(h) do
    [
      {:sym, "header"},
      h.header,
      {:sym, "old-start"},
      h.old_start,
      {:sym, "old-count"},
      h.old_count,
      {:sym, "new-start"},
      h.new_start,
      {:sym, "new-count"},
      h.new_count,
      {:sym, "patch"},
      Map.get(h, :patch, ""),
      {:sym, "start-byte"},
      Map.get(h, :start_byte, 0),
      {:sym, "end-byte"},
      Map.get(h, :end_byte, 0),
      {:sym, "lines"},
      for({tag, text} <- h.lines, do: [{:sym, Atom.to_string(tag)}, text])
    ]
  end

  defp log_plist(c) do
    [
      {:sym, "sha"},
      c.sha,
      {:sym, "short-sha"},
      c.short_sha,
      {:sym, "author"},
      c.author,
      {:sym, "date"},
      c.date,
      {:sym, "subject"},
      c.subject
    ]
  end

  # (base "HEAD" path "lib/x.ex" staged #t) — a #f base drops the ref and
  # diffs the work tree against the index
  defp diff_opts(plist) when is_list(plist), do: diff_opts(plist, [])
  defp diff_opts(_), do: []

  defp diff_opts([key, value | rest], acc) do
    acc =
      case plain(key) do
        "base" -> Keyword.put(acc, :base, opt_string(value))
        "path" -> Keyword.put(acc, :path, opt_string(value))
        "staged" -> Keyword.put(acc, :staged, value == true)
        _ -> acc
      end

    diff_opts(rest, acc)
  end

  defp diff_opts(_, acc), do: acc

  defp opt_string(false), do: nil
  defp opt_string(value), do: plain(value)

  defp dir_atom({:sym, "h"}), do: :h
  defp dir_atom({:sym, "v"}), do: :v
  defp dir_atom("h"), do: :h
  defp dir_atom("v"), do: :v

  defp json_to_scheme_value(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
    |> Compos.Core.LLM.json_to_scheme()
  end

  defp plain({:sym, s}), do: s
  defp plain(v), do: v

  # the optional LIMIT of a property-change search: an integer, or nothing
  defp limit([limit | _]) when is_integer(limit), do: limit
  defp limit(_), do: nil

  # The transient menu the frame renders. META rows: ("subtitle" TEXT),
  # ("context" TEXT), ("chips" ((LABEL ACTIVE?) ...)), ("columns" ((TITLE ...) ...)),
  # ("detail" (TITLE ((KEY VALUE TONE) ...) NOTE)), ("legend" ((KEY LABEL) ...)),
  # ("layout" NAME).
  defp transient_menu(title, groups, meta) do
    meta = Map.new(meta, fn [k, v] -> {plain(k), v} end)

    columns =
      case Map.get(meta, "columns") do
        [_ | _] = cols -> Enum.map(cols, fn col -> Enum.map(col, &to_string/1) end)
        # a menu with no columns of its own: one column per group
        _ -> Enum.map(groups, fn [heading, _rows] -> [heading] end)
      end

    %{
      title: title,
      columns: columns,
      subtitle: Map.get(meta, "subtitle", ""),
      layout: Map.get(meta, "layout", ""),
      context: Map.get(meta, "context", ""),
      chips:
        Enum.map(Map.get(meta, "chips", []), fn [label, active] ->
          %{label: label, active: active == true}
        end),
      detail: transient_detail(Map.get(meta, "detail", false)),
      legend:
        Enum.map(Map.get(meta, "legend", []), fn [key, label] -> %{key: key, label: label} end),
      groups:
        Enum.map(groups, fn [heading, rows] ->
          %{
            title: heading,
            items:
              Enum.map(rows, fn [key, description, value, kind, behavior, selected] ->
                %{
                  key: key,
                  description: description,
                  value: value,
                  kind: plain(kind),
                  behavior: plain(behavior),
                  selected: selected
                }
              end)
          }
        end)
    }
  end

  defp transient_detail([title, rows, note]) do
    %{
      title: title,
      rows: Enum.map(rows, fn [k, v, tone] -> %{k: k, v: v, tone: plain(tone)} end),
      note: note
    }
  end

  defp transient_detail(_), do: nil

  defp find_file(path, opts) do
    case Core.open_file(path, opts) do
      {:ok, name} -> name
      {:error, :already_exists} -> Path.expand(path)
    end
  end

  # the desktop's tuple spec for a window tree — what restore_tree accepts
  defp tree_buffers({:leaf, b, _, _, _, _, _, _, _}), do: [b]
  defp tree_buffers({:leaf, b, _, _, _, _, _}), do: [b]
  defp tree_buffers({:leaf, b, _, _, _, _}), do: [b]
  defp tree_buffers({:split, _, _, a, b}), do: tree_buffers(a) ++ tree_buffers(b)
  defp tree_buffers(_), do: []

  defp tree_rename({:leaf, b, top, point, manual, ctop}, old, new),
    do: {:leaf, if(b == old, do: new, else: b), top, point, manual, ctop}

  defp tree_rename({:leaf, b, top, point, manual, ctop, history}, old, new) do
    renamed = Enum.map(history, fn name -> if name == old, do: new, else: name end)
    {:leaf, if(b == old, do: new, else: b), top, point, manual, ctop, renamed}
  end

  defp tree_rename({:leaf, b, top, point, manual, ctop, history, restore, owner}, old, new) do
    {:leaf, b2, top, point, manual, ctop, history} =
      tree_rename({:leaf, b, top, point, manual, ctop, history}, old, new)

    {:leaf, b2, top, point, manual, ctop, history, Editor.restore_rename(restore, old, new),
     owner}
  end

  defp tree_rename({:split, dir, ratio, a, b}, old, new),
    do: {:split, dir, ratio, tree_rename(a, old, new), tree_rename(b, old, new)}

  defp tree_rename(other, _old, _new), do: other

  defp tree_spec(%{type: :leaf, buffer: b} = leaf) do
    {:leaf, b, Map.get(leaf, :top, 0), Map.get(leaf, :point, 0), Map.get(leaf, :manual, false),
     Map.get(leaf, :ctop, 0), Map.get(leaf, :history, []), Map.get(leaf, :restore),
     Map.get(leaf, :owner)}
  end

  defp tree_spec(%{type: :split, dir: dir, children: [a, b]} = s),
    do: {:split, dir, Map.get(s, :ratio, 0.5), tree_spec(a), tree_spec(b)}

  # (fold-get BUF 'all) reads the union, the same word overlay-clear! uses
  defp fold_tag(tag), do: if(plain(tag) == "all", do: :all, else: plain(tag))

  # A key sequence is a list of keys. Scheme writes one the way a person
  # says it — "C-x b" — and the keymaps hold ["C-x", "b"]. Take either.
  # A bare string reaching the keymap walk raises inside the Editor call,
  # and an Editor that dies loses every buffer's local keymap.
  # a binding is a command name, or (keymap NAME): a prefix key that leads
  # to another keymap


  # System.cmd has no time limit, so a hung command would hold the caller —
  # and in the inline form the caller is the Session — forever. Run through
  # a port, kill the OS process at the limit, and return what it wrote.
  defp shell_to_string(cmd, dir, limit \\ nil) do
    limit = limit || shell_inline_limit()

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", cmd],
        cd: dir
      ])

    deadline = System.monotonic_time(:millisecond) + limit
    t0 = System.monotonic_time(:millisecond)
    out = collect_port(port, deadline, [])
    report_slow_shell(cmd, dir, System.monotonic_time(:millisecond) - t0)
    out
  rescue
    _ -> ""
  end

  # The inline form holds its lane for as long as the command runs, so a
  # slow command is a frozen editor. The lane log names the job "eval" and
  # stops there; without the command text, a slow shell is invisible. Name
  # it here, at the same threshold the lane uses.
  @slow_shell_ms 250

  defp report_slow_shell(cmd, dir, ms) when ms > @slow_shell_ms do
    require Logger
    Logger.warning("shell: #{ms}ms in #{dir}: #{String.slice(cmd, 0, 160)}")
  end

  defp report_slow_shell(_cmd, _dir, _ms), do: :ok

  defp collect_port(port, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, chunk}} ->
        collect_port(port, deadline, [acc | chunk])

      {^port, {:exit_status, _}} ->
        IO.iodata_to_binary(acc)
    after
      max(left, 0) ->
        kill_port(port)
        IO.iodata_to_binary(acc)
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)])
      _ -> :ok
    end

    Port.close(port)
    flush_port(port)
  catch
    _, _ -> flush_port(port)
  end

  # a port message left in the mailbox would reach handle_info and crash
  # the Session — drain every message the closed port already sent
  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp shell_inline_limit, do: Application.get_env(:compos_core, :shell_timeout_ms, 15_000)

  defp shell_async_limit,
    do: Application.get_env(:compos_core, :shell_async_timeout_ms, 600_000)

  defp directory_entry(dir, base) do
    path = Path.join(dir, base)

    case File.lstat(path, time: :posix) do
      {:ok, stat} ->
        name = if stat.type == :directory, do: base <> "/", else: base

        [
          {:sym, "name"},
          name,
          {:sym, "type"},
          Atom.to_string(stat.type),
          {:sym, "bytes"},
          stat.size,
          {:sym, "mtime"},
          stat.mtime,
          {:sym, "size"},
          format_size(stat.size),
          {:sym, "date"},
          format_mtime(stat.mtime),
          {:sym, "perms"},
          format_mode(stat)
        ]

      {:error, reason} ->
        [
          {:sym, "name"},
          base,
          {:sym, "type"},
          "missing",
          {:sym, "bytes"},
          0,
          {:sym, "mtime"},
          0,
          {:sym, "size"},
          "?",
          {:sym, "date"},
          "?",
          {:sym, "perms"},
          "??????????",
          {:sym, "error"},
          file_error(reason, path)
        ]
    end
  end

  defp file_error(reason, path) do
    detail = reason |> :file.format_error() |> List.to_string()
    "#{detail}: #{path}"
  end

  defp path_present?(path) do
    case File.lstat(path) do
      {:ok, _} -> true
      {:error, :enoent} -> false
      {:error, _} -> true
    end
  end

  defp user_trash_dir do
    case Application.get_env(:compos_core, :trash_dir) do
      nil ->
        home = System.user_home!()

        case :os.type() do
          {:unix, :darwin} ->
            Path.join(home, ".Trash")

          _ ->
            Path.join([
              System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share"),
              "Trash",
              "files"
            ])
        end

      dir ->
        Path.expand(dir)
    end
  end

  defp unused_path(path, suffix \\ 0) do
    candidate = if suffix == 0, do: path, else: path <> ".#{suffix}"
    if path_present?(candidate), do: unused_path(path, suffix + 1), else: candidate
  end

  # Resolve every symlink on the path, one component at a time. A link that
  # points at another link resolves through @realpath_hops rounds and then
  # stops, so a link that points at itself cannot spin here.
  @realpath_hops 8
  defp realpath(path) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc -> resolve_link(Path.join(acc, seg), @realpath_hops) end)
  end

  defp resolve_link(path, 0), do: path

  defp resolve_link(path, hops) do
    case File.read_link(path) do
      {:ok, "/" <> _ = target} -> resolve_link(Path.expand(target), hops - 1)
      {:ok, target} -> resolve_link(Path.expand(target, Path.dirname(path)), hops - 1)
      _ -> path
    end
  end

  defp format_mode(stat) do
    type =
      case stat.type do
        :directory -> "d"
        :symlink -> "l"
        :regular -> "-"
        :device -> "b"
        _ -> "?"
      end

    bits =
      [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
      |> Enum.zip(~w(r w x r w x r w x))
      |> Enum.map_join(fn {bit, ch} ->
        if Bitwise.band(stat.mode, bit) != 0, do: ch, else: "-"
      end)

    type <> bits
  end

  defp format_size(size) when size >= 1_048_576, do: "#{Float.round(size / 1_048_576, 1)}M"
  defp format_size(size) when size >= 1024, do: "#{Float.round(size / 1024, 1)}k"
  defp format_size(size), do: "#{size}"

  defp format_mtime(posix) do
    dt = DateTime.from_unix!(posix)
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), dt.month - 1)
    day = String.pad_leading("#{dt.day}", 2)
    hh = String.pad_leading("#{dt.hour}", 2, "0")
    mm = String.pad_leading("#{dt.minute}", 2, "0")
    "#{month} #{day} #{hh}:#{mm}"
  end

  defp region_bounds do
    buf = Editor.current_buffer()
    p = Buffer.point(buf)

    case Buffer.mark(buf) do
      nil -> {p, p}
      m -> {min(p, m), max(p, m)}
    end
  end
end
