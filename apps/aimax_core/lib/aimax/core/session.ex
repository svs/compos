defmodule Aimax.Core.Session do
  @moduledoc """
  An editor session: the process that owns the Scheme interpreter wired to the
  editor primitives. User/agent Scheme executes here — `M-:`, eval-region,
  RPC `eval`, init.scm, and every named command (they're all Scheme closures).

  Commands live in a public ETS table `{name, closure}` — registered by
  `(define-command ...)`, executed via `run_command/1` (from KeyDispatch) or
  `(run-command ...)` (from Scheme, e.g. M-x's confirm callback).

  The echo area is a view: `(message ...)` appends to `*messages*` and sets
  the transient echo. One global session for now; per-client later.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Buffer, Editor}
  alias Aimax.Scheme

  @messages "*messages*"

  # closures that escaped the store into opaque Elixir funs (Reactor handlers,
  # LLM callbacks) — the GC can't see through funs, so they register here
  @escaped :aimax_escaped_closures

  # sweep when the frame count doubles since the last sweep (with a floor so
  # small sessions never bother)
  @gc_floor 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Evaluate Scheme source. Returns {:ok, printed_value} | {:error, msg}."
  def eval(src), do: GenServer.call(__MODULE__, {:eval, src}, 30_000)

  @doc "Run a named command (Scheme closure from the commands table)."
  def run_command(name), do: GenServer.call(__MODULE__, {:run_command, name}, 30_000)

  @doc "Apply a Scheme closure (e.g. a minibuffer confirm callback)."
  def apply_callback(closure, args),
    do: GenServer.call(__MODULE__, {:apply, closure, args}, 30_000)

  @doc "Apply a Scheme closure and return its value (e.g. a completion fn)."
  def call_fn(closure, args),
    do: GenServer.call(__MODULE__, {:call_fn, closure, args}, 30_000)

  def eval_region(buffer, start_pos, end_pos) do
    src = buffer |> Buffer.text() |> binary_part(start_pos, end_pos - start_pos)
    eval(src)
  end

  def eval_buffer(buffer), do: buffer |> Buffer.text() |> eval()

  def message(text) do
    Buffer.append(@messages, text <> "\n", source: :editor)
    Editor.set_echo(text)
    :ok
  end

  def command_names do
    Aimax.Core.SchemeAPI.commands_table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(Aimax.Core.SchemeAPI.commands_table(), [:named_table, :public, :set])
    :ets.new(@escaped, [:named_table, :public, :set])
    {:ok, _} = Aimax.Core.create_buffer(@messages)

    interp = Scheme.new(primitives: Aimax.Core.SchemeAPI.primitives())
    interp = Scheme.register(interp, session_primitives(interp.global))
    interp = load_stdlib!(interp)

    # loading leaves a pile of dead frames behind — sweep once so the
    # doubling threshold starts from a live baseline
    interp = Scheme.gc(interp, external_roots())

    {:ok, %{interp: interp, last_live: map_size(interp.store.frames)}}
  end

  # a primitive calling a dead GenServer (buffer killed while a callback was
  # queued) exits, and a primitive fed garbage (string-prefix? on #f) raises —
  # both must fail the eval, never the Session: this process is the editor's
  # single writer, and its crash cascades into an app shutdown (500s everywhere)
  defp safe(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "exit: #{inspect(reason)}"}
  end

  @impl true
  def handle_call({:eval, src}, _from, state) do
    case safe(fn -> Scheme.eval_string(state.interp, src) end) do
      {:ok, val, interp} -> {:reply, {:ok, Scheme.print(val)}, put_interp(state, interp, val)}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:run_command, name}, _from, state) do
    case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), name) do
      [] ->
        {:reply, {:error, "undefined command"}, state}

      [{^name, closure, _doc}] ->
        case safe(fn -> Scheme.call(state.interp, closure, []) end) do
          {:ok, val, interp} -> {:reply, :ok, put_interp(state, interp, val)}
          {:error, msg} -> {:reply, {:error, msg}, state}
        end
    end
  end

  def handle_call({:apply, closure, args}, _from, state) do
    case safe(fn -> Scheme.call(state.interp, closure, args) end) do
      {:ok, val, interp} ->
        {:reply, :ok, put_interp(state, interp, val)}

      {:error, msg} ->
        message("error: " <> msg)
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:call_fn, closure, args}, _from, state) do
    case safe(fn -> Scheme.call(state.interp, closure, args) end) do
      {:ok, val, interp} -> {:reply, {:ok, val}, put_interp(state, interp, val)}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  # --- frame GC --------------------------------------------------------------

  defp put_interp(state, interp, result) do
    state = %{state | interp: interp}

    if map_size(interp.store.frames) > max(state.last_live * 2, @gc_floor) do
      interp = Scheme.gc(interp, [result | external_roots()])
      %{state | interp: interp, last_live: map_size(interp.store.frames)}
    else
      state
    end
  end

  # every place a live closure can be held outside the store: the commands
  # table, escaped fun-wrapped handlers, active minibuffer handlers (Editor
  # state), and buffer-local values
  defp external_roots do
    minibuffer = Process.whereis(Editor) && Editor.snapshot().minibuffer

    [
      :ets.tab2list(Aimax.Core.SchemeAPI.commands_table()),
      :ets.tab2list(@escaped),
      minibuffer,
      Enum.map(Aimax.Core.list_buffers(), fn name ->
        if Buffer.exists?(name), do: Buffer.locals(name), else: %{}
      end)
    ]
  end

  defp load_stdlib!(interp) do
    interp =
      Enum.reduce(["editor.scm", "dired.scm", "themes.scm"], interp, fn file, interp ->
        path = Application.app_dir(:aimax_core, "priv/#{file}")

        case Scheme.eval_string(interp, File.read!(path)) do
          {:ok, _, interp} ->
            interp

          {:error, msg} ->
            # the stdlib must load — a broken stdlib is a broken editor
            raise "#{file} failed to load: #{msg}"
        end
      end)

    interp |> load_packages() |> load_init()
  end

  # bundled packages: priv/packages/*.scm, loaded after the stdlib. Unlike
  # the stdlib these are severable — org-mode lives here so it can be
  # extracted into a real package later, and a broken package logs loudly
  # instead of bricking boot.
  defp load_packages(interp) do
    bundled =
      :aimax_core
      |> Application.app_dir("priv/packages")
      |> Path.join("*.scm")
      |> Path.wildcard()
      # load order: custom.scm (defcustom) before tools.scm (define-tool!)
      # before everything else — packages register into those registries at
      # load time; the rest load alphabetically
      |> Enum.sort_by(
        &{Enum.find_index(["custom.scm", "tools.scm"], fn n -> n == Path.basename(&1) end) ||
           99, &1}
      )

    # user packages (~/.aimax/packages/*.scm, e.g. installed from github via
    # package-install) load after the bundled set so they can build on it
    user =
      Aimax.Core.home()
      |> Path.join("packages")
      |> Path.join("*.scm")
      |> Path.wildcard()
      |> Enum.sort()

    Enum.reduce(bundled ++ user, interp, fn path, interp ->
      case Scheme.eval_string(interp, File.read!(path)) do
        {:ok, _, interp2} ->
          interp2

        {:error, msg} ->
          Logger.error("package #{Path.basename(path)} failed to load: #{msg}")
          interp
      end
    end)
  end

  # user config: <home>/ai-config.scm, init.scm, then custom.scm (saved
  # customizations load last so they win over init) — errors log loudly
  # but never brick boot. (load "...") works from inside either. Tests set
  # :home to a tmp dir so the user's real init.scm stays out of them.
  defp load_init(interp) do
    Enum.reduce(["ai-config.scm", "init.scm", "custom.scm"], interp, fn file, interp ->
      path = Path.join(Aimax.Core.home(), file)

      with true <- File.exists?(path),
           {:ok, _, interp2} <- Scheme.eval_string(interp, File.read!(path)) do
        interp2
      else
        false ->
          interp

        {:error, msg} ->
          Logger.error("#{file} error: #{msg}")
          interp
      end
    end)
  end

  defp session_primitives(global) do
    eval_src = fn src, store ->
      Enum.reduce(Aimax.Scheme.Reader.read_all(src), {:void, store}, fn form, {_v, store} ->
        Aimax.Scheme.Eval.eval(form, global, store)
      end)
    end

    %{
      "message" => fn [text] ->
        message(to_string(text))
        :void
      end,
      "define-command" => fn
        [name, closure] ->
          :ets.insert(Aimax.Core.SchemeAPI.commands_table(), {command_name(name), closure, ""})
          :void

        [name, doc, closure] when is_binary(doc) ->
          :ets.insert(Aimax.Core.SchemeAPI.commands_table(), {command_name(name), closure, doc})
          :void
      end,
      "command-names" => fn [] -> command_names() end,
      "command-fn" => fn [name] ->
        case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> false
          [{_, closure, _}] -> closure
        end
      end,
      "command-doc" => fn [name] ->
        case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> ""
          [{_, _, doc}] -> doc
        end
      end,
      "run-command" => fn [name], store ->
        case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> raise Aimax.Scheme.Eval.Error, message: "undefined command: #{command_name(name)}"
          [{_, closure, _}] -> Aimax.Scheme.Eval.apply_fn(closure, [], store)
        end
      end,
      "llm" => fn [prompt, callback] ->
        # the callback vanishes into an opaque fun until the reply arrives —
        # root it for the GC, and unroot once it has fired
        key = {:llm, make_ref()}
        :ets.insert(@escaped, {key, callback})

        Aimax.Core.LLM.complete(prompt, fn text ->
          try do
            apply_callback(callback, [text])
          after
            :ets.delete(@escaped, key)
          end
        end)

        :void
      end,
      # gptel-style native tool use: specs/dispatcher come from the Scheme
      # registry (packages/tools.scm) — the loop lives in LLM.complete_tools.
      # An optional sixth arg is a usage callback: it gets a plist of summed
      # token counts + cost before the text callback fires.
      "llm-tools" => fn [prompt, system, specs, dispatcher, callback | rest] ->
        usage_cb = List.first(rest)
        key = {:llm_tools, make_ref()}
        :ets.insert(@escaped, {key, [dispatcher, callback, usage_cb]})

        on_usage =
          usage_cb &&
            fn usage -> apply_callback(usage_cb, [usage_to_plist(usage)]) end

        Aimax.Core.LLM.complete_tools(
          prompt,
          system,
          specs,
          dispatcher,
          fn text ->
            try do
              apply_callback(callback, [text])
            after
              :ets.delete(@escaped, key)
            end
          end,
          on_usage: on_usage
        )

        :void
      end,

      # --- MCP client (Aimax.Core.MCP; policy in packages/mcp.scm) ----------
      "mcp-connect!" => fn [name, spec] ->
        case Aimax.Core.MCP.connect(s(name), mcp_spec(spec)) do
          {:ok, _} -> :void
          {:error, msg} -> raise_scheme("mcp-connect!: #{inspect(msg)}")
        end
      end,
      "mcp-disconnect!" => fn [name] ->
        Aimax.Core.MCP.disconnect(s(name))
        :void
      end,
      "mcp-connections" => fn [] ->
        for c <- Aimax.Core.MCP.connections() do
          [c.name, to_string(c.status), c.tools]
        end
      end,
      "mcp-tool-specs" => fn [names] ->
        Aimax.Core.MCP.tool_specs(Enum.map(names, &s/1))
      end,
      # MCP-shaped JSON for a list of registry tool specs — the proxy's
      # tools/list payload (input_schema key renamed to MCP's camelCase)
      "tool-specs-json" => fn [specs] ->
        specs
        |> Enum.map(fn spec ->
          %{input_schema: schema} = t = Aimax.Core.LLM.tool_json(spec)
          t |> Map.delete(:input_schema) |> Map.put(:inputSchema, schema)
        end)
        |> Jason.encode!()
      end,
      "priv-path" => fn [rel] ->
        Path.join(Application.app_dir(:aimax_core, "priv"), rel)
      end,
      # --- runtime tree-sitter grammars (Aimax.Core.TreeSitter) --------------
      "ts-install-grammar!" => fn [name, url] ->
        n = s(name)
        u = s(url)

        Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
          case Aimax.Core.TreeSitter.install(n, u) do
            "ok" -> message("grammar #{n} installed — buffers pick it up on their next mode set")
            err -> message("grammar #{n}: #{err}")
          end
        end)

        :void
      end,
      "ts-installed-grammars" => fn [] -> Aimax.Core.TreeSitter.installed() end,
      "format-usd" => fn [amount] when is_number(amount) ->
        "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)
      end,
      "llm-price" => fn [model] ->
        case Aimax.Core.LLMDb.price(s(model)) do
          nil -> false
          p -> [{:sym, "input"}, p.input, {:sym, "output"}, p.output,
                {:sym, "cache-read"}, p.cache_read, {:sym, "cache-write"}, p.cache_write]
        end
      end,
      "llm-cost-report" => fn [] ->
        for row <- Aimax.Core.LLMDb.report() do
          [{:sym, "day"}, row.day, {:sym, "model"}, row.model,
           {:sym, "requests"}, row.requests, {:sym, "input"}, row.input,
           {:sym, "output"}, row.output, {:sym, "cost"}, row.cost * 1.0]
        end
      end,
      "set-llm-model!" => fn [m] ->
        Aimax.Core.LLM.set_model(m)
        :void
      end,

      # --- agent threads (ACP runtime, see Aimax.Core.Agent) -----------------
      # config/info/events cross the boundary as flat plists: (key val ...)
      # with symbol keys — this Scheme has no dotted pairs.
      "agent-start!" => fn [slug, config] ->
        case Aimax.Core.Agent.start(to_string(slug), plist_to_map(config)) do
          {:ok, _pid} -> to_string(slug)
          {:error, {:already_started, _}} -> raise_scheme("agent already running: #{s(slug)}")
          {:error, reason} -> raise_scheme("agent-start!: #{inspect(reason)}")
        end
      end,
      "agent-prompt!" => fn [slug, text] ->
        case Aimax.Core.Agent.prompt(s(slug), to_string(text)) do
          :sent -> {:sym, "sent"}
          :queued -> {:sym, "queued"}
          {:error, r} -> raise_scheme("agent-prompt!: #{inspect(r)}")
        end
      end,
      "agent-cancel!" => fn [slug] ->
        Aimax.Core.Agent.cancel(s(slug))
        :void
      end,
      "agent-permission-respond!" => fn [slug, rpc_id, option_id] ->
        option = if option_id in [false, :void], do: nil, else: s(option_id)

        case Aimax.Core.Agent.respond_permission(s(slug), rpc_id, option) do
          :ok -> :void
          {:error, r} -> raise_scheme("agent-permission-respond!: #{inspect(r)}")
        end
      end,
      "agent-append!" => fn [slug, text] ->
        case Aimax.Core.Agent.append_at_mark(s(slug), to_string(text)) do
          mark when is_integer(mark) -> mark
          {:error, r} -> raise_scheme("agent-append!: #{inspect(r)}")
        end
      end,
      "agent-mark" => fn [slug] ->
        case Aimax.Core.Agent.mark(s(slug)) do
          mark when is_integer(mark) -> mark
          {:error, r} -> raise_scheme("agent-mark: #{inspect(r)}")
        end
      end,
      "agent-list" => fn [] -> Aimax.Core.Agent.list() end,
      "agent-kill!" => fn [slug] ->
        Aimax.Core.Agent.kill(s(slug))
        :void
      end,
      # live model switch on the running session (ACP session/set_model)
      "agent-set-model!" => fn [slug, model] ->
        case Aimax.Core.Agent.set_model(s(slug), s(model)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      # -> (slug "a1" buffer "*agent: a1*" status idle queued 0 permission #f)
      "agent-info" => fn [slug] ->
        case Aimax.Core.Agent.info(s(slug)) do
          {:error, _} ->
            false

          info ->
            perm =
              case info.permission do
                nil ->
                  false

                p ->
                  [
                    {:sym, "rpc-id"},
                    p.rpc_id,
                    {:sym, "title"},
                    p.title,
                    {:sym, "options"},
                    Enum.map(p.options, fn {oid, name, kind} -> [oid, name, kind] end)
                  ]
              end

            [
              {:sym, "slug"},
              info.slug,
              {:sym, "buffer"},
              info.buffer,
              {:sym, "status"},
              {:sym, to_string(info.status)},
              {:sym, "queued"},
              info.queued,
              {:sym, "permission"},
              perm
            ]
        end
      end,
      # one global handler for all agent events: (lambda (slug events) ...).
      # It escapes into the Agent GenServers as an opaque fun — root it.
      "agent-on-event!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_handler}, handler})
        :void
      end,
      "set-modeline-extra!" => fn [s] ->
        Editor.set_modeline_extra(to_string(s))
        :void
      end,
      "llm-model" => fn [] -> Aimax.Core.LLM.model() end,
      "eval-string" => fn [src], store -> eval_src.(src, store) end,
      # dynamic global access by symbol — what defcustom/customize are built on
      "symbol-value" => fn [{:sym, name}], store ->
        {Aimax.Scheme.Env.lookup(store, global, name), store}
      end,
      "set-symbol-value!" => fn [{:sym, name}, val], store ->
        {val, Aimax.Scheme.Env.define(store, global, name, val)}
      end,
      "boundp" => fn [{:sym, name}], store ->
        {match?({:ok, _}, Aimax.Scheme.Env.fetch(store, global, name)), store}
      end,
      # every globally bound name (builtins + userland defines) — the
      # discovery surface for agents writing eval-scheme code
      "global-names" => fn [], store ->
        {vars, _parent} = Map.fetch!(store.frames, global)
        {vars |> Map.keys() |> Enum.sort(), store}
      end,
      # load-library: evaluate a Scheme file in the live session
      "load" => fn [path], store ->
        expanded = Path.expand(path)

        case File.read(expanded) do
          {:ok, src} ->
            eval_src.(src, store)

          {:error, reason} ->
            raise Aimax.Scheme.Eval.Error, message: "cannot load #{expanded}: #{reason}"
        end
      end,
      "eval-region" => fn [buffer, s, e], store ->
        src = buffer |> Buffer.text() |> binary_part(s, e - s)
        eval_src.(src, store)
      end,
      "eval-buffer" => fn [buffer], store ->
        eval_src.(Buffer.text(buffer), store)
      end,
      # (on-change! buf (lambda (pos inserted deleted-len source) ...)) -> id
      # Fires ~30ms-debounced on every change, ALL sources (:user, :editor,
      # :undo, agents) — handlers that edit the buffer must write with
      # :editor-source primitives and be idempotent, or they loop.
      # The Reactor handler runs in a Task, so calling back into this
      # GenServer just queues behind the triggering eval.
      "on-change!" => fn [buf, callback] ->
        {:ok, id} =
          Aimax.Core.Reactor.on_change(
            buf,
            :any,
            fn changes -> apply_callback(callback, change_args(changes)) end,
            debounce: 30,
            sources: :all
          )

        # the Reactor holds the callback inside an opaque fun — root it for
        # the GC for as long as the rule lives
        :ets.insert(@escaped, {{:reactor, id}, callback})
        id
      end,
      "remove-on-change!" => fn [id] ->
        Aimax.Core.Reactor.remove(id)
        :ets.delete(@escaped, {:reactor, id})
        :void
      end,

      # Emacs' with-minibuffer-selected-window: run a thunk with
      # current-buffer pointing at the WINDOW's buffer even though a prompt
      # is active — isearch's change handler moves point in the file, not
      # in the prompt it is typing into
      "with-window-buffer" => fn [thunk], store ->
        Editor.set_mb_redirect(false)

        try do
          Aimax.Scheme.Eval.apply_fn(thunk, [], store)
        after
          Editor.set_mb_redirect(true)
        end
      end,

      # --- minibuffer commands (bound in the *minibuf* local keymap) ---------
      # Store-aware: handler closures apply in the CURRENT store — these run
      # inside the Session, so calling back via apply_callback would deadlock.
      "minibuffer-buffer" => fn [] -> Editor.minibuf_name() end,
      "minibuffer-confirm!" => fn [], store ->
        case Editor.minibuffer_close() do
          %{on_confirm: oc} = mb when oc not in [nil, false] ->
            {value, store} = mb_confirm_value(mb, store)
            {_, store} = Aimax.Scheme.Eval.apply_fn(oc, [value], store)
            {:void, store}

          _ ->
            {:void, store}
        end
      end,
      # M-RET: submit the typed input as-is, ignoring the highlighted
      # candidate (vertico-exit-input) — creates files whose names fuzzy-
      # match existing ones
      "minibuffer-confirm-input!" => fn [], store ->
        case Editor.minibuffer_close() do
          %{on_confirm: oc} = mb when oc not in [nil, false] ->
            {_, store} = Aimax.Scheme.Eval.apply_fn(oc, [mb.input], store)
            {:void, store}

          _ ->
            {:void, store}
        end
      end,
      "minibuffer-cancel!" => fn [], store ->
        store =
          case Editor.minibuffer_close() do
            %{on_cancel: oc} when oc not in [nil, false] ->
              {_, store} = Aimax.Scheme.Eval.apply_fn(oc, [], store)
              store

            _ ->
              store
          end

        Editor.set_echo("Quit")
        {:void, store}
      end,
      "minibuffer-complete!" => fn [], store ->
        mb = Editor.snapshot().minibuffer

        cond do
          mb == nil ->
            {:void, store}

          mb.on_complete not in [nil, false] ->
            selected = (mb.sel_touched && Editor.minibuffer_selected()) || false

            case Aimax.Scheme.Eval.apply_fn(mb.on_complete, [mb.input, selected], store) do
              {[new_input, candidates], store}
              when is_binary(new_input) and is_list(candidates) ->
                Editor.minibuffer_set_input(new_input)
                Editor.minibuffer_set_candidates(candidates)
                {:void, store}

              {_, store} ->
                {:void, store}
            end

          true ->
            case Editor.minibuffer_selected() do
              nil -> :ok
              label -> Editor.minibuffer_set_input(label)
            end

            {:void, store}
        end
      end,
      "minibuffer-next!" => fn [] ->
        Editor.minibuffer_move_sel(1)
        :void
      end,
      "minibuffer-prev!" => fn [] ->
        Editor.minibuffer_move_sel(-1)
        :void
      end,
      # DEL: in a path prompt at a directory boundary, kill the whole
      # component (vertico-directory); otherwise one char back at point
      "minibuffer-del!" => fn [] ->
        mb = Editor.snapshot().minibuffer
        input = Buffer.text(Editor.minibuf_name())
        trimmed = String.replace(input, ~r{[^/]+/$}, "")

        if mb && mb.on_complete not in [nil, false] and trimmed != input and
             String.ends_with?(input, "/") do
          Editor.minibuffer_set_input(trimmed)
        else
          Buffer.delete_char(Editor.minibuf_name(), -1)
        end

        :void
      end
    }
  end

  # on_complete prompts (find-file): the input is the path being built.
  # RET means the HIGHLIGHTED candidate whenever one exists (vertico) —
  # resolve it through the completion closure. The typed input wins only
  # when nothing matches (that's how new files are created); M-RET
  # (minibuffer-confirm-input!) always submits the input literally.
  defp mb_confirm_value(%{on_complete: oc} = mb, store) when oc not in [nil, false] do
    if mb[:selected] do
      case Aimax.Scheme.Eval.apply_fn(oc, [mb.input, mb[:selected]], store) do
        {[new_input, _cands], store} when is_binary(new_input) -> {new_input, store}
        {_, store} -> {mb.input, store}
      end
    else
      {mb.input, store}
    end
  end

  defp mb_confirm_value(mb, store), do: {mb[:selected] || mb.input, store}

  # debounce coalesces bursts: first pos, all inserted text, total deleted
  defp change_args(changes) do
    [
      hd(changes).pos,
      Enum.map_join(changes, & &1.inserted),
      changes |> Enum.map(& &1.deleted) |> Enum.sum(),
      changes |> List.last() |> Map.fetch!(:source) |> source_str()
    ]
  end

  defp source_str({:agent, id}), do: "agent:#{id}"
  defp source_str(src), do: to_string(src)

  defp command_name({:sym, s}), do: s
  defp command_name(s) when is_binary(s), do: s

  # --- agent primitive helpers -------------------------------------------------

  defp s({:sym, str}), do: str
  defp s(str) when is_binary(str), do: str

  defp raise_scheme(msg), do: raise(Aimax.Scheme.Eval.Error, message: msg)

  # ('cmd "claude-code-acp" 'cwd "/x") -> %{"cmd" => "...", "cwd" => "/x"}
  # Duplicate keys: FIRST wins, matching scheme's plist-get (configs are
  # built by prepending overrides) — Map.new alone would keep the last.
  defp plist_to_map(plist) when is_list(plist) do
    plist
    |> Enum.chunk_every(2)
    |> Enum.reverse()
    |> Map.new(fn [k, v] -> {s(k), plist_val_to_elixir(v)} end)
  end

  defp plist_val_to_elixir({:sym, str}), do: str
  defp plist_val_to_elixir(v) when is_list(v), do: Enum.map(v, &plist_val_to_elixir/1)
  defp plist_val_to_elixir(v), do: v

  # MCP spec plist: 'env and 'headers values are themselves plists -> maps
  defp mcp_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {k, v} when k in ["env", "headers"] and is_list(v) ->
        {k, v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), b} end)}

      kv ->
        kv
    end)
  end

  defp usage_to_plist(usage) do
    t = Aimax.Core.LLMDb.tokens(usage)

    [{:sym, "input"}, t.input, {:sym, "output"}, t.output,
     {:sym, "cache-read"}, t.cache_read, {:sym, "cache-write"}, t.cache_write,
     {:sym, "cost"}, usage["cost"] || false]
  end
end
