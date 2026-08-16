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

  alias Aimax.Core.{Buffer, Editor, Frame}
  alias Aimax.Scheme

  @messages "*messages*"

  # closures that escaped the store into opaque Elixir funs (Reactor handlers,
  # LLM callbacks) — the GC can't see through funs, so they register here
  @escaped :aimax_escaped_closures

  # sweep when the frame count doubles since the last sweep (with a floor so
  # small sessions never bother)
  @gc_floor 5_000

  # how long a waiting mcp-call! waits. The RPC layer gives an eval 30s, so
  # the call must give up first and say so.
  @mcp_wait 25_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # every entry point carries the caller's frame context into this process:
  # the Scheme runs here, so primitives resolve their frame from OUR pdict,
  # stamped per-call from the fid the caller (Input, LiveView, RPC) passed —
  # nil falls back to the last-active frame

  @doc "Evaluate Scheme source. Returns {:ok, printed_value} | {:error, msg}."
  def eval(src, fid \\ nil), do: GenServer.call(__MODULE__, {:eval, src, fid(fid)}, 30_000)

  @doc "Run a named command (Scheme closure from the commands table)."
  def run_command(name, fid \\ nil),
    do: GenServer.call(__MODULE__, {:run_command, name, fid(fid)}, 30_000)

  @doc "Apply a Scheme closure (e.g. a minibuffer confirm callback)."
  def apply_callback(closure, args, fid \\ nil),
    do: GenServer.call(__MODULE__, {:apply, closure, args, fid(fid)}, 30_000)

  @doc "Apply a Scheme closure and return its value (e.g. a completion fn)."
  def call_fn(closure, args, fid \\ nil),
    do: GenServer.call(__MODULE__, {:call_fn, closure, args, fid(fid)}, 30_000)

  @doc """
  Apply a named global function to ARGS. ARGS pass as values, never through
  source text — the safe call for Elixir callers holding strings (paths,
  buffer names) that must not be interpolated into Scheme.
  """
  def call_named(fun, args, fid \\ nil) when is_binary(fun),
    do: GenServer.call(__MODULE__, {:call_named, fun, args, fid(fid)}, 30_000)

  defp fid(nil), do: Frame.current()
  defp fid(fid), do: fid

  def eval_region(buffer, start_pos, end_pos) do
    src = buffer |> Buffer.text() |> binary_part(start_pos, end_pos - start_pos)
    eval(src)
  end

  def eval_buffer(buffer), do: buffer |> Buffer.text() |> eval()

  def message(text) do
    Buffer.append(@messages, text <> "\n", source: :editor)
    # Emacs: echo in the frame that triggered; with no frame context (agent
    # events, timers) every frame gets it — *messages* is shared either way
    if Frame.current(), do: Editor.set_echo(text), else: Editor.set_echo_all(text)
    :ok
  end

  # Sorted by the downcased name: a plain sort is ASCII, and a mode command
  # takes the mode's name verbatim, so "Dired" sat above every lowercase
  # command at the top of M-x instead of among the d's.
  def command_names do
    Aimax.Core.SchemeAPI.commands_table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&String.downcase/1)
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

  # the caller's frame context, stamped into THIS process for the duration
  # of the Scheme execution — primitives resolve their frame from it. nil
  # clears (a stale pdict from the previous command must not leak forward).
  defp with_fid(nil, fun) do
    Frame.clear()
    fun.()
  end

  defp with_fid(fid, fun), do: Frame.with_frame(fid, fun)

  @impl true
  def handle_call({:eval, src, fid}, _from, state) do
    case safe(fn -> with_fid(fid, fn -> Scheme.eval_string(state.interp, src) end) end) do
      {:ok, val, interp} -> {:reply, {:ok, Scheme.print(val)}, put_interp(state, interp, val)}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:run_command, name, fid}, _from, state) do
    case :ets.lookup(Aimax.Core.SchemeAPI.commands_table(), name) do
      [] ->
        {:reply, {:error, "undefined command"}, state}

      [{^name, closure, _doc}] ->
        case safe(fn ->
               with_fid(fid, fn ->
                 {:ok, val, interp} = Scheme.call(state.interp, closure, [])

                 # the post-command hook: policy reacts to what the command
                 # changed — the expanded modeline re-reads its buffer. A
                 # hook error must never fail the command that ran.
                 try do
                   case Scheme.eval_string(
                          interp,
                          "(when (boundp 'post-command!) (post-command!))"
                        ) do
                     {:ok, _hv, interp2} -> {:ok, val, interp2}
                     _ -> {:ok, val, interp}
                   end
                 rescue
                   _ -> {:ok, val, interp}
                 catch
                   _, _ -> {:ok, val, interp}
                 end
               end)
             end) do
          {:ok, val, interp} -> {:reply, :ok, put_interp(state, interp, val)}
          {:error, msg} -> {:reply, {:error, msg}, state}
        end
    end
  end

  def handle_call({:apply, closure, args, fid}, _from, state) do
    case safe(fn -> with_fid(fid, fn -> Scheme.call(state.interp, closure, args) end) end) do
      {:ok, val, interp} ->
        {:reply, :ok, put_interp(state, interp, val)}

      {:error, msg} ->
        message("error: " <> msg)
        {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:call_fn, closure, args, fid}, _from, state) do
    case safe(fn -> with_fid(fid, fn -> Scheme.call(state.interp, closure, args) end) end) do
      {:ok, val, interp} -> {:reply, {:ok, val}, put_interp(state, interp, val)}
      {:error, msg} -> {:reply, {:error, msg}, state}
    end
  end

  def handle_call({:call_named, fun, args, fid}, _from, state) do
    case safe(fn ->
           with_fid(fid, fn ->
             # the name is a code-supplied constant; only ARGS are data
             {:ok, closure, interp} = Scheme.eval_string(state.interp, fun)
             Scheme.call(interp, closure, args)
           end)
         end) do
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
    # every frame's prompt, not just one — a live on_confirm in a background
    # frame must not be collected
    minibuffers = (Process.whereis(Editor) && Editor.all_minibuffers()) || []

    [
      :ets.tab2list(Aimax.Core.SchemeAPI.commands_table()),
      :ets.tab2list(@escaped),
      minibuffers,
      Enum.map(Aimax.Core.list_buffers(), fn name ->
        if Buffer.exists?(name), do: Buffer.locals(name), else: %{}
      end)
    ]
  end

  defp load_stdlib!(interp) do
    interp =
      Enum.reduce(["editor.scm", "dired.scm", "themes.scm", "chrome.scm"], interp, fn file, interp ->
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

  # one merged map: the three registration modules' docs
  defp primitive_docs do
    Aimax.Scheme.Builtins.docs()
    |> Map.merge(Aimax.Core.SchemeAPI.docs())
    |> Map.merge(docs())
  end

  defp doc_name({:sym, n}), do: n
  defp doc_name(n) when is_binary(n), do: n

  @doc """
  One-line doc string for every primitive that `session_primitives/1`
  registers. Format: a call signature, then " — ", then one sentence.
  """
  def docs do
    %{
      "primitive-doc" =>
        "(primitive-doc NAME) — return the one-line doc for an Elixir primitive, or #f.",
      "primitive-docs" =>
        "(primitive-docs) — return (NAME DOC) pairs for every Elixir primitive, sorted.",
      "message" => "(message TEXT) — show TEXT in the echo area.",
      "define-command" =>
        "(define-command NAME [DOC] FN) — register an M-x command; DOC shows in M-x.",
      "command-names" => "(command-names) — return every M-x command name.",
      "global-keys" => "(global-keys) — return ((KEYS COMMAND) ...) for every global key binding.",
      "local-keys" =>
        "(local-keys BUF) — return ((KEYS COMMAND) ...) for BUF's own key bindings.",
      "command-fn" => "(command-fn NAME) — return the command's closure, or #f.",
      "command-doc" =>
        "(command-doc NAME) — return the command's doc string; empty when it has none.",
      "run-command" => "(run-command NAME) — run the named command; error when it is undefined.",
      "llm" => "(llm PROMPT CALLBACK) — start an async completion; CALLBACK gets the reply text.",
      "llm-tools" =>
        "(llm-tools PROMPT SYSTEM SPECS DISPATCHER CB [USAGE-CB]) — async tool loop; CB gets text.",
      "browser-call" =>
        "(browser-call OP ARGS CB) — send OP to the browser; CB gets a reply plist.",
      "browser-call-sync" =>
        "(browser-call-sync OP ARGS [MS]) — send OP and wait for the reply plist (default 2s, max 5s).",
      "browser-serve!" =>
        "(browser-serve! HANDLER) — set the handler for browser requests: (HANDLER OP ARGS).",
      "browser-connected?" =>
        "(browser-connected?) — return #t when a browser extension is connected.",
      "dispatch-keys" =>
        "(dispatch-keys KEYS) — dispatch key chords through the serialized GUI input queue, in order.",
      "mcp-connect!" => "(mcp-connect! NAME SPEC) — connect an MCP server from a spec plist.",
      "mcp-disconnect!" => "(mcp-disconnect! NAME) — disconnect the named MCP server.",
      "mcp-connections" =>
        "(mcp-connections) — return (name status tools type resources prompts) per connection.",
      "mcp-server-detail" =>
        "(mcp-server-detail NAME) — return a status plist, or #f when never started.",
      "mcp-on-change!" =>
        "(mcp-on-change! HANDLER) — set the handler that gets (NAME STATUS) on server changes.",
      "mcp-log" => "(mcp-log NAME) — return ((time dir text) ...) JSON-RPC frames, oldest first.",
      "mcp-tool-specs" => "(mcp-tool-specs NAMES) — return the tool specs of the named servers.",
      "mcp-await-ready" =>
        "(mcp-await-ready SERVER [MS]) — wait until the server is ready; return #t or #f.",
      "mcp-tool-call" =>
        "(mcp-tool-call SERVER TOOL ARGS [TIMEOUT|CB]) — call one tool; without CB, wait for text.",
      "tool-specs-json" =>
        "(tool-specs-json SPECS) — return the specs as MCP tools/list JSON text.",
      "priv-path" =>
        "(priv-path REL) — return the absolute path of REL in the aimax_core priv directory.",
      "ts-install-grammar!" =>
        "(ts-install-grammar! NAME URL) — install a tree-sitter grammar in the background.",
      "ts-installed-grammars" =>
        "(ts-installed-grammars) — return the installed tree-sitter grammar names.",
      "format-usd" => "(format-usd AMOUNT) — return AMOUNT as a dollar string with 4 decimals.",
      "llm-price" => "(llm-price MODEL) — return the model's token price plist, or #f.",
      "llm-cost-report" =>
        "(llm-cost-report) — return one usage plist per day and model, with cost.",
      "set-llm-model!" => "(set-llm-model! MODEL) — set the active LLM model.",
      "set-llm-cache-ttl!" =>
        "(set-llm-cache-ttl! TTL) — set how long the provider holds a cached prefix.",
      "backend-capabilities" =>
        "(backend-capabilities NAME) — return the backend's capability symbols.",
      "llm-max-tokens" =>
        "(llm-max-tokens MODEL) — return the model's maximum output tokens, or #f.",
      "agent-start!" => "(agent-start! SLUG CONFIG) — start an agent thread from a config plist.",
      "agent-prompt!" =>
        "(agent-prompt! SLUG TEXT [DISPLAY]) — send a prompt; return 'sent or 'queued.",
      "agent-cancel!" => "(agent-cancel! SLUG) — cancel the agent's current turn.",
      "agent-permission-respond!" =>
        "(agent-permission-respond! SLUG RPC-ID OPTION-ID) — answer a pending permission request.",
      "agent-append!" =>
        "(agent-append! SLUG TEXT) — insert TEXT at the agent's mark; return the new byte offset.",
      "agent-mark" => "(agent-mark SLUG) — return the agent's output mark as a byte offset.",
      "agent-list" => "(agent-list) — return the slugs of the running agent threads, sorted.",
      "agent-kill!" => "(agent-kill! SLUG) — stop the agent thread.",
      "agent-set-model!" =>
        "(agent-set-model! SLUG MODEL) — switch the live session's model; return #t or #f.",
      "agent-set-mode!" =>
        "(agent-set-mode! SLUG MODE) — switch the permission mode; #f when unsupported.",
      "agent-info" =>
        "(agent-info SLUG) — return a plist: slug, buffer, status, queued, permission; or #f.",
      "agent-on-event!" =>
        "(agent-on-event! HANDLER) — set the global agent event handler: (HANDLER SLUG EVENTS).",
      "agent-context-fn!" =>
        "(agent-context-fn! HANDLER) — set the direct lane's context provider for each turn.",
      "agent-record-fn!" =>
        "(agent-record-fn! HANDLER) — set the direct lane's record writer for wire messages.",
      "agent-permission-fn!" =>
        "(agent-permission-fn! HANDLER) — set the tool policy; it returns allow, ask, or reject.",
      "agent-permission-deadline!" =>
        "(agent-permission-deadline! SLUG MS) — arm an auto-deny deadline on the permission.",
      "set-modeline-extra!" =>
        "(set-modeline-extra! TEXT) — set the extra text that the modeline shows.",
      "llm-model" => "(llm-model) — return the active LLM model id.",
      "llm-context-limit" =>
        "(llm-context-limit MODEL) — input tokens the model accepts, or #f when unknown.",
      "eval-string" => "(eval-string SRC) — evaluate SRC as Scheme; return the last value.",
      "with-edit-author" => "(with-edit-author AUTHOR THUNK) — run THUNK; buffer edits it makes are attributed to the string AUTHOR.",
      "eval-string-safe" =>
        "(eval-string-safe SRC) — evaluate SRC; return (ok VAL) or (error MSG).",
      "symbol-value" => "(symbol-value 'NAME) — return the global value of the symbol.",
      "set-symbol-value!" => "(set-symbol-value! 'NAME VAL) — set the global value of the symbol.",
      "boundp" => "(boundp 'NAME) — return #t when the symbol has a global binding.",
      "global-names" => "(global-names) — return every globally bound name, sorted.",
      "load" => "(load PATH) — evaluate a Scheme file in the live session.",
      "eval-region" =>
        "(eval-region BUF START END) — evaluate the text between byte offsets START and END.",
      "eval-buffer" => "(eval-buffer BUF) — evaluate the whole buffer as Scheme.",
      "on-change!" =>
        "(on-change! BUF CB) — call (CB POS INSERTED DELETED-LEN SOURCE) on changes; return an id.",
      "remove-on-change!" => "(remove-on-change! ID) — remove a change handler by its id.",
      "with-window-buffer" =>
        "(with-window-buffer THUNK) — run THUNK with the window's buffer current, not the prompt.",
      "delete-frame!" =>
        "(delete-frame! [ID]) — delete the frame and run its prompt's cancel handler.",
      "minibuffer-buffer" => "(minibuffer-buffer) — return the minibuffer's buffer name.",
      "minibuffer-state" => "(minibuffer-state) — return the active prompt as a plist, or #f.",
      "minibuffer-input!" => "(minibuffer-input! INPUT) — set the minibuffer input text.",
      "minibuffer-confirm!" =>
        "(minibuffer-confirm!) — close the prompt; run its confirm handler with the value.",
      "minibuffer-confirm-input!" =>
        "(minibuffer-confirm-input!) — close the prompt; submit the input, not the candidate.",
      "minibuffer-cancel!" =>
        "(minibuffer-cancel!) — close the prompt; run its cancel handler; echo Quit.",
      "minibuffer-detach!" =>
        "(minibuffer-detach!) — close the prompt; return its state and closures, or #f.",
      "minibuffer-complete!" =>
        "(minibuffer-complete!) — run the prompt's completion, or copy the selection to the input.",
      "minibuffer-next!" => "(minibuffer-next!) — move the candidate selection down one.",
      "minibuffer-prev!" => "(minibuffer-prev!) — move the candidate selection up one.",
      "minibuffer-del!" =>
        "(minibuffer-del!) — delete one char back; at a directory boundary, delete the component."
    }
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
      # ((KEYS COMMAND) ...) for every global binding
      "global-keys" => fn [] ->
        for {seq, cmd} <- Editor.global_keys(), do: [seq, cmd]
      end,
      # ((KEYS COMMAND) ...) for one buffer's own bindings
      "local-keys" => fn [buf] ->
        for {seq, cmd} <- Editor.local_keys(buf), do: [seq, cmd]
      end,
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
      "llm-with-model" => fn [prompt, model, callback] ->
        key = {:llm, make_ref()}
        :ets.insert(@escaped, {key, callback})

        Aimax.Core.LLM.complete(prompt, to_string(model), fn text ->
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
      # token counts + cost before the text callback fires.  A seventh arg
      # pins the model for buffer-local callers such as llm-mode.
      "llm-tools" => fn [prompt, system, specs, dispatcher, callback | rest] ->
        usage_cb = List.first(rest)
        requested_model = Enum.at(rest, 1)
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
          on_usage: on_usage,
          model: requested_model && to_string(requested_model)
        )

        :void
      end,

      # --- browser (Aimax.Core.Browser; policy in chrome.scm) ---------------
      # Outbound: OP is the extension verb ("tabs", "eval", "read", "overlay",
      # "type", "click"...), ARGS a plist, CALLBACK gets a plist back — 'ok #t
      # plus the reply, or 'ok #f and 'error. Async because a page operation is
      # slow and keystrokes must not block behind it.
      "browser-call" => fn [op, args, callback] ->
        key = {:browser, make_ref()}
        :ets.insert(@escaped, {key, callback})
        # the frame that asked, carried across the round-trip: a command that
        # queries the browser and only then prompts must prompt in the frame
        # it came from, not in whichever was last active when the reply landed
        fid = Frame.current()

        Aimax.Core.Browser.call(s(op), browser_args(args), fn reply ->
          try do
            apply_callback(callback, [browser_reply(reply)], fid)
          after
            :ets.delete(@escaped, key)
          end
        end)

        :void
      end,
      # The same call, waited on. A tool the model calls has to RETURN what the
      # page said: a callback answers later, and by then the model's turn is
      # over. The wait is safe because the reply runs in the bridge's own task
      # and never re-enters this process — it only sends a message here. It
      # does hold the interpreter, so the ceiling is low and the default lower.
      "browser-call-sync" => fn args ->
        [op, a | rest] = args
        ms = rest |> List.first() |> browser_wait_ms()
        me = self()
        ref = make_ref()

        Aimax.Core.Browser.call(s(op), browser_args(a), fn reply ->
          send(me, {:browser_sync, ref, reply})
        end)

        receive do
          {:browser_sync, ^ref, reply} -> browser_reply(reply)
        after
          ms -> [{:sym, "ok"}, false, {:sym, "error"}, "the browser did not answer in time"]
        end
      end,
      # Inbound: HANDLER answers what the browser asks — (HANDLER OP ARGS).
      # M-x in a tab is this: the extension asks "commands", chrome.scm says
      # what the list is. Rooted, since it outlives the call that made it.
      "browser-serve!" => fn [handler] ->
        :ets.insert(@escaped, {{:browser_handler, :serve}, handler})
        Aimax.Core.Browser.serve(handler)
        :void
      end,
      "browser-connected?" => fn [] -> Aimax.Core.Browser.connected?() end,
      # A chord arriving from a tab goes through the same dispatcher the GUI
      # uses. It has to run OFF this process: KeyDispatch calls back into
      # Session, and calling it from inside Session would deadlock — hence the
      # task, and hence no return value to hand back.
      #
      # The whole sequence goes in ONE task, in order. A task per key races,
      # and a prefix that arrives after its own suffix composes into nothing —
      # which is exactly how C-x b silently did nothing.
      # the Task waits on the input queue, so the injected sequence runs
      # after the event that asked for it and cannot interleave with a
      # user keystroke mid-chord (dup #23). It carries the caller's frame.
      "dispatch-keys" => fn [specs] ->
        keys = Enum.map(specs, &s/1)
        fid = Aimax.Core.Frame.current()

        Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
          Enum.each(keys, &Aimax.Core.Input.dispatch(fid, &1))
        end)

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
          [c.name, to_string(c.status), c.tools, to_string(c.type), c.resources, c.prompts]
        end
      end,
      # what the hub's detail view reads: false for a server never started
      "mcp-server-detail" => fn [name] ->
        case Aimax.Core.MCP.detail(s(name)) do
          nil ->
            false

          d ->
            [
              {:sym, "status"},
              to_string(d.status),
              {:sym, "type"},
              to_string(d.type),
              {:sym, "server-name"},
              d.server_info["name"] || "",
              {:sym, "server-version"},
              d.server_info["version"] || "",
              {:sym, "reason"},
              d.reason,
              {:sym, "tools"},
              d.tools,
              {:sym, "resources"},
              for(r <- d.resources, do: [r["name"] || "", r["uri"] || "", r["description"] || ""]),
              {:sym, "prompts"},
              for(p <- d.prompts, do: [p["name"] || "", p["description"] || ""])
            ]
        end
      end,
      # (mcp-on-change! (lambda (name status) ...)) — the hub redraws itself
      # when a server becomes ready, dies, or fails. Rooted like the agent
      # event handler.
      "mcp-on-change!" => fn [handler] ->
        :ets.insert(@escaped, {{:mcp_handler}, handler})
        :void
      end,
      "mcp-log" => fn [name] ->
        for e <- Aimax.Core.MCP.log(s(name)) do
          [
            # the reader is looking at a clock on their own wall, not UTC
            e.at
            |> :calendar.system_time_to_local_time(:millisecond)
            |> NaiveDateTime.from_erl!()
            |> Calendar.strftime("%H:%M:%S"),
            to_string(e.dir),
            e.text
          ]
        end
      end,
      "mcp-tool-specs" => fn [names] ->
        Aimax.Core.MCP.tool_specs(Enum.map(names, &s/1))
      end,
      # Wait for a server that is still shaking hands, up to the same
      # bound. An empty tool list reads as "this server serves nothing",
      # which is a lie the caller cannot tell from the truth.
      "mcp-await-ready" => fn args ->
        [server | rest] = args
        server = s(server)
        wait = if is_integer(List.first(rest)), do: List.first(rest), else: @mcp_wait

        task =
          Task.Supervisor.async_nolink(Aimax.Core.TaskSupervisor, fn ->
            Aimax.Core.MCP.await_ready(server, wait)
          end)

        case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
          {:ok, ready?} -> ready?
          _ -> false
        end
      end,
      # Call one tool on one server. The work runs in a task, never here:
      # this process draws the editor, and a server that answers in its own
      # time must not stop it. With a callback the call returns at once;
      # without one the caller waits, bounded, because the eval path (an
      # agent through the aimax proxy) needs an answer, not a promise.
      "mcp-tool-call" => fn
        [server, tool, args] ->
          mcp_wait_call(s(server), s(tool), mcp_args(args), @mcp_wait)

        [server, tool, args, timeout] when is_integer(timeout) ->
          mcp_wait_call(s(server), s(tool), mcp_args(args), timeout)

        [server, tool, args, callback] ->
          key = {:mcp_call, make_ref()}
          :ets.insert(@escaped, {key, callback})
          {server, tool, args} = {s(server), s(tool), mcp_args(args)}

          Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
            result = Aimax.Core.MCP.call_when_ready(server, tool, args, @mcp_wait)

            try do
              apply_callback(callback, mcp_callback_args(result))
            after
              :ets.delete(@escaped, key)
            end
          end)

          :void
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
           {:sym, "output"}, row.output,
           {:sym, "cache-read"}, row.cache_read, {:sym, "cache-write"}, row.cache_write,
           # as whole percent: Scheme has no float formatting worth the name
           {:sym, "hit-rate"},
           (case Aimax.Core.LLMDb.hit_rate(row) do
              nil -> false
              r -> round(r * 100)
            end),
           {:sym, "cost"}, row.cost * 1.0]
        end
      end,
      "set-llm-model!" => fn [m] ->
        Aimax.Core.LLM.set_model(m)
        :void
      end,
      # how long the provider holds a cached prefix ("5m", "1h") — the
      # defcustom llm-cache-ttl sets it
      "set-llm-cache-ttl!" => fn [ttl] ->
        Aimax.Core.LLM.set_cache_ttl(to_string(ttl))
        :void
      end,
      # what a backend can do, by its resolved 'backend name — Scheme asks
      # this instead of asking which connector it is looking at
      "backend-capabilities" => fn [name] ->
        Enum.map(Aimax.Core.Agent.Backend.capabilities_of(s(name)), &{:sym, to_string(&1)})
      end,
      "llm-max-tokens" => fn [model] ->
        Aimax.Core.LLMDb.max_tokens(s(model)) || false
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
      # optional third arg: the display text (what the transcript shows and
      # records as the user turn) when the wire text carries seed context
      "agent-prompt!" => fn [slug, text | rest] ->
        display =
          case rest do
            [d] when is_binary(d) -> d
            _ -> nil
          end

        case Aimax.Core.Agent.prompt(s(slug), to_string(text), display) do
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
      # live permission-mode switch (ACP session/set_mode); #f when the
      # backend doesn't do modes — the caller then answers requests itself
      "agent-set-mode!" => fn [slug, mode] ->
        case Aimax.Core.Agent.set_mode(s(slug), s(mode)) do
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
      # the direct lane's context provider: (lambda (slug display-text) ...)
      # -> (turns ... system ... tools ... dispatcher ...), called by
      # Backend.ReqLLM at each turn start. Rooted like the event handler.
      "agent-context-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_context}, handler})
        :void
      end,
      # the direct lane's record writer: (lambda (slug role blocks wire) ...),
      # called by the turn task for every message it puts on the wire. The
      # task reads the record and writes it in ONE order, so the next turn
      # replays exactly what the last one sent. Rooted like the handlers
      # above.
      "agent-record-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_record}, handler})
        :void
      end,
      # the permission policy the DIRECT lane consults before every tool
      # call: (lambda (slug name kind raw) ...) -> allow | ask | reject.
      # (The ACP lane answers its own requests through the same policy,
      # from the event handler.) Rooted like the handlers above.
      "agent-permission-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_permission}, handler})
        :void
      end,
      # arm an auto-deny deadline on the thread's pending permission
      "agent-permission-deadline!" => fn [slug, ms] ->
        Aimax.Core.Agent.permission_deadline(s(slug), trunc(ms))
        :void
      end,
      "set-modeline-extra!" => fn [s] ->
        Editor.set_modeline_extra(to_string(s))
        :void
      end,
      "llm-model" => fn [] -> Aimax.Core.LLM.model() end,
      "llm-context-limit" => fn [m] -> Aimax.Core.LLMDb.context_limit(to_string(m)) || false end,
      "eval-string" => fn [src], store -> eval_src.(src, store) end,
      # (with-edit-author AUTHOR THUNK) — every buffer mutation THUNK makes
      # is attributed to AUTHOR (see buffer-authors). The try/after restore
      # is the point: a raising handler must not leave the author stuck on
      # the session, misattributing every later keystroke.
      "with-edit-author" => fn [author, thunk], store ->
        prev = Process.get(:aimax_edit_author)
        if author == false,
          do: Process.delete(:aimax_edit_author),
          else: Process.put(:aimax_edit_author, to_string(author))

        try do
          Aimax.Scheme.Eval.apply_fn(thunk, [], store)
        after
          if prev,
            do: Process.put(:aimax_edit_author, prev),
            else: Process.delete(:aimax_edit_author)
        end
      end,
      # (eval-string-safe SRC) -> (ok VAL) | (error MSG) — the catch this
      # dialect lacks; the eval-scheme tool's did-you-mean feedback needs to
      # observe the error instead of aborting the whole handler
      "eval-string-safe" => fn [src], store ->
        try do
          {val, store2} = eval_src.(src, store)
          {[{:sym, "ok"}, val], store2}
        rescue
          e -> {[{:sym, "error"}, Exception.message(e)], store}
        catch
          :exit, reason -> {[{:sym, "error"}, "exit: #{inspect(reason)}"], store}
        end
      end,
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
      # the doc sweep's surface: apropos scope "all" and describe-function
      # read these instead of showing a bare name. A userland alias of a
      # builtin — (define raw-buffer-create buffer-create) — carries the
      # builtin value, so the lookup follows the value to the real name.
      "primitive-doc" => fn [name], store ->
        n = doc_name(name)

        resolved =
          case Aimax.Scheme.Env.fetch(store, global, n) do
            {:ok, {:builtin, builtin_name, _}} -> builtin_name
            _ -> n
          end

        {primitive_docs()[resolved] || primitive_docs()[n] || false, store}
      end,
      "primitive-docs" => fn [] ->
        primitive_docs() |> Enum.sort() |> Enum.map(fn {n, d} -> [n, d] end)
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

      # store-aware (an active prompt's on_cancel closure applies in the
      # CURRENT store); refuses the sole frame
      "delete-frame!" => fn args, store ->
        fid =
          case args do
            [] -> Frame.current() || Editor.last_active_frame()
            [id] -> s(id)
          end

        case Editor.delete_frame(fid) do
          {:ok, %{on_cancel: oc}} when oc not in [nil, false] ->
            {_, store} = Aimax.Scheme.Eval.apply_fn(oc, [], store)
            {true, store}

          {:ok, _} ->
            {true, store}

          {:error, :last_frame} ->
            raise_scheme("delete-frame!: cannot delete the sole frame")

          {:error, :no_frame} ->
            {false, store}
        end
      end,

      # --- minibuffer commands (bound in the *minibuf* local keymap) ---------
      # Store-aware: handler closures apply in the CURRENT store — these run
      # inside the Session, so calling back via apply_callback would deadlock.
      "minibuffer-buffer" => fn [] -> Editor.minibuf_name() end,
      # What the minibuffer is currently asking, as data — #f when it isn't
      # asking anything. The GUI reads this off the render payload; a browser
      # tab has no render payload, so it reads it here and draws its own.
      "minibuffer-state" => fn [] ->
        case Editor.snapshot().minibuffer do
          nil ->
            false

          mb ->
            [
              {:sym, "prompt"},
              mb.prompt,
              {:sym, "input"},
              mb.input,
              {:sym, "sel"},
              mb.list.sel,
              {:sym, "total"},
              Aimax.Core.Candidates.total(mb.list),
              {:sym, "candidates"},
              Enum.map(Aimax.Core.Candidates.rows(mb.list), fn c ->
                [{:sym, "label"}, c.label, {:sym, "hint"}, c.hint || ""]
              end)
            ]
        end
      end,
      "minibuffer-input!" => fn [input] ->
        Editor.minibuffer_set_input(s(input))
        :void
      end,
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
      # collect: close the prompt WITHOUT running any handler, and hand the
      # caller everything the prompt was — the candidates that survive the
      # current input, and the handler closures themselves. Scheme adopts
      # them, so the prompt continues as a buffer (embark-collect). This is
      # the only way out of a prompt that neither confirms nor cancels.
      "minibuffer-detach!" => fn [] ->
        case Editor.minibuffer_close() do
          nil ->
            false

          mb ->
            [
              [{:sym, "prompt"}, mb.prompt],
              [{:sym, "input"}, mb.input],
              [
                {:sym, "candidates"},
                Enum.map(Aimax.Core.Candidates.filtered(mb.list), fn c ->
                  [c.label, c.hint || ""]
                end)
              ],
              [{:sym, "confirm"}, mb[:on_confirm] || false],
              [{:sym, "cancel"}, mb[:on_cancel] || false],
              [{:sym, "complete"}, mb[:on_complete] || false]
            ]
        end
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
  # when nothing matches (that's how new files are created), or when the
  # input names a directory and the user did not touch the selection —
  # then RET opens the directory (Editor.prompt_preselected?/1). M-RET
  # (minibuffer-confirm-input!) always submits the input literally.
  defp mb_confirm_value(%{on_complete: oc} = mb, store) when oc not in [nil, false] do
    if mb[:selected] && not Editor.prompt_preselected?(mb) do
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
    |> Map.new(fn [k, v] -> {s(k), config_val(s(k), v)} end)
  end

  # 'meta is forwarded to an adapter as JSON, where an OBJECT and an ARRAY
  # are different things — and only the {:sym, _} keys tell them apart
  # ((settingSources ()) is a one-key object; ("user" "local") is a list).
  # Flattening symbols here would erase that, so this value stays raw and
  # the backend converts it.
  defp config_val("meta", v), do: v
  defp config_val(_k, v), do: plist_val_to_elixir(v)

  defp plist_val_to_elixir({:sym, str}), do: str
  defp plist_val_to_elixir(v) when is_list(v), do: Enum.map(v, &plist_val_to_elixir/1)
  defp plist_val_to_elixir(v), do: v

  # the task owns the timeout, not the connection: Conn gives a tool call
  # two minutes, and the session cannot wait that long for anything
  defp mcp_wait_call(server, tool, args, timeout) do
    task =
      Task.Supervisor.async_nolink(Aimax.Core.TaskSupervisor, fn ->
        Aimax.Core.MCP.call_when_ready(server, tool, args, timeout)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} -> text
      {:ok, {:error, msg}} -> raise_scheme("mcp-call!: #{msg}")
      _ -> raise_scheme("mcp-call!: #{server} #{tool} did not answer in time")
    end
  end

  # tool arguments come as a JSON string (what an agent writes through
  # eval-scheme) or as a plist (what Scheme code writes)
  defp mcp_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp mcp_args(args) when is_list(args) do
    case scheme_to_json(args) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp mcp_args(_), do: %{}

  # (lambda (ok text) ...) — an error is text too, and a handler that only
  # displays the answer needs no second branch
  defp mcp_callback_args({:ok, text}), do: [true, text]
  defp mcp_callback_args({:error, msg}), do: [false, to_string(msg)]

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

  # Scheme plist -> JSON object for the extension. #f becomes null here,
  # because to the extension an omitted argument is absent, not false.
  defp browser_args(args), do: Aimax.Core.Plist.to_json(args, :null)

  # the interpreter waits here, so the ceiling is 5s and the default 2s: a page
  # that is slower than that is a page the caller should ask about again
  defp browser_wait_ms(ms) when is_integer(ms) and ms > 0, do: min(ms, 5_000)
  defp browser_wait_ms(_), do: 2_000

  defp browser_reply({:ok, result}) when is_map(result),
    do: [{:sym, "ok"}, true | Aimax.Core.LLM.json_to_scheme(result)]

  defp browser_reply({:ok, _}), do: [{:sym, "ok"}, true]
  defp browser_reply({:error, msg}), do: [{:sym, "ok"}, false, {:sym, "error"}, msg]

  @doc """
  The inverse of `Aimax.Core.LLM.json_to_scheme/1`, for values headed out to
  JSON. The convention lives in `Aimax.Core.Plist`, because three places
  had three slightly different ideas of what counted as a plist.
  """
  defdelegate scheme_to_json(value), to: Aimax.Core.Plist, as: :to_json


  defp usage_to_plist(usage) do
    t = Aimax.Core.LLMDb.tokens(usage)

    [{:sym, "input"}, t.input, {:sym, "output"}, t.output,
     {:sym, "cache-read"}, t.cache_read, {:sym, "cache-write"}, t.cache_write,
     {:sym, "cost"}, usage["cost"] || false]
  end
end
