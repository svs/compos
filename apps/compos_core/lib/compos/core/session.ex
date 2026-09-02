defmodule Compos.Core.Session do
  @moduledoc """
  An editor session: loads the Scheme interpreter wired to the editor
  primitives, then hands out its handle. Scheme does NOT execute in this
  process: every entry point routes into an `Compos.Core.Lane` — `:ui` for
  keystrokes and callbacks, a group/agent/conn lane for background work —
  so one long eval never delays a keystroke. This process keeps the slow
  serial duties: boot loading, file reload, and the periodic frame GC.

  Commands live in a public ETS table `{name, closure}` — registered by
  `(define-command ...)`, executed via `run_command/1` (from KeyDispatch) or
  `(run-command ...)` (from Scheme, e.g. M-x's confirm callback).

  The echo area is a view: `(message ...)` records a row in the messages
  table and sets the transient echo. `*Messages*` is a list over that table
  (messages.scm, messages-mode); nothing writes its text directly. One
  global session for now; per-client later.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Buffer, Editor, Frame, Lane, SchemeActor, SchemeTask}
  alias Compos.Scheme
  alias Compos.Scheme.Reader

  @messages "*Messages*"
  @messages_table :compos_messages
  @messages_limit 2_000

  # closures that escaped the store into opaque Elixir funs (Reactor handlers,
  # LLM callbacks) — the GC can't see through funs, so they register here
  @escaped :compos_escaped_closures

  # sweep when the frame count doubles since the last sweep (with a floor so
  # small sessions never bother); checked on a timer — evals no longer pass
  # through this process, so it cannot count them
  @gc_floor 5_000
  @gc_interval 30_000

  # the interpreter handle: constant after init (the store is a shared ETS
  # table), so lane workers read it from persistent_term instead of asking
  # this process
  @pt {__MODULE__, :interp}

  # Every module that supplies a primitive fun. A primitive is an anonymous
  # fun captured from one of these when the session booted; recompiling one
  # purges the version the fun came from, and calling it then raises
  # "function #Function<...> is invalid". The stamp is how a caller asks
  # whether that has happened.
  @primitive_modules [Compos.Core.SchemeAPI, Compos.Scheme.Builtins, __MODULE__]
  @pt_stamp {__MODULE__, :primitive_stamp}

  # how long a waiting mcp-call! waits. The RPC layer gives an eval 30s, so
  # the call must give up first and say so.
  @mcp_wait 25_000

  # the longest a (wait-until) may hold its lane. Lane.run gives an eval
  # 30s, so a runaway predicate must give up first and answer #f.
  @wait_cap 10_000

  @bootstrap_files ~w(editor.scm transient.scm dired.scm themes.scm chrome.scm init.scm)
  @reload_context ~w(origin! package! namespace! category! domain! effects!)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # every entry point carries the caller's frame context into this process:
  # the Scheme runs here, so primitives resolve their frame from OUR pdict,
  # stamped per-call from the fid the caller (Input, LiveView, RPC) passed —
  # nil falls back to the last-active frame

  @doc """
  Evaluate Scheme source. Returns {:ok, printed_value} | {:error, msg}.
  LANE names the serial lane the eval runs in; nil is the `:ui` lane. A
  long eval holds only its own lane — keystrokes ride `:ui` and never
  queue behind agent or RPC work.
  """
  def eval(src, fid \\ nil, timeout \\ 30_000, lane \\ nil) do
    fid = fid(fid)
    Lane.run(lane || :ui, fn from -> exec_eval(src, fid, from) end, timeout, eval_label(src))
  end

  @doc "The live interpreter handle (constant after init)."
  def interp do
    :persistent_term.get(@pt)
  rescue
    # boot: the stdlib is still loading. A call queues behind init — the
    # same wait every caller used to get from the Session mailbox.
    ArgumentError -> GenServer.call(__MODULE__, :await_boot, 60_000)
  end

  @doc """
  Is the interpreter published? A caller that runs during boot must ask
  this before it queues Scheme work. `Process.whereis(Session)` says yes
  from the moment start_link registers the name, which is before init/1
  loads the stdlib.
  """
  def ready? do
    :persistent_term.get(@pt)
    true
  rescue
    ArgumentError -> false
  end

  @doc "Reload changed top-level forms from Scheme files into the live interpreter."
  def reload_files(paths) when is_list(paths),
    do: GenServer.call(__MODULE__, {:reload_files, paths}, 30_000)

  @doc """
  Re-bind every Elixir primitive after a code reload. Returns :ok.

  A primitive is an anonymous fun captured from `Compos.Core.SchemeAPI` and
  `Compos.Scheme.Builtins` when this session booted. Recompiling either module
  purges the version those funs came from, and the next Scheme call raises
  "function #Function<...> is invalid, likely because it points to an old
  version of the code" — the whole editor dead, from one dev recompile.
  Every hot recompile must call this.
  """
  def refresh_primitives, do: GenServer.call(__MODULE__, :refresh_primitives, 30_000)

  @doc """
  Rebind the primitives, but only if a module that supplies one has been
  recompiled since the last binding. Returns :ok.

  The check is three `module_info(:md5)` calls and one persistent_term read,
  so a caller on a request path can ask every time.
  """
  def refresh_primitives_if_stale do
    if primitives_stale?(), do: refresh_primitives(), else: :ok
  end

  @doc "Has a module that supplies a primitive been recompiled since binding?"
  def primitives_stale?, do: :persistent_term.get(@pt_stamp, nil) != primitive_stamp()

  defp primitive_stamp do
    Enum.map(@primitive_modules, fn module ->
      try do
        module.module_info(:md5)
      rescue
        _ -> nil
      end
    end)
  end

  @doc "Run a named command (Scheme closure from the commands table)."
  def run_command(name, fid \\ nil, lane \\ nil) do
    fid = fid(fid)
    Lane.run(lane || :ui, fn _from -> exec_run_command(name, fid) end, 30_000, "command #{name}")
  end

  @doc "Apply a Scheme closure (e.g. a minibuffer confirm callback)."
  def apply_callback(closure, args, fid \\ nil, lane \\ nil) do
    fid = fid(fid)
    Lane.run(lane || :ui, fn _from -> exec_apply(closure, args, fid) end, 30_000, "apply")
  end

  @doc """
  Apply a closure that has been waiting on a reply from outside the editor.

  Closure frames are now published before exposure. Keep the bounded stale-ref
  retry as defense for persisted references from an older or faulty root set:
  dropping an out-of-editor reply loses it outright. Backend.call_context uses
  the same defensive retry. Ordinary callbacks still fail fast.
  """
  def apply_reply_callback(closure, args, fid \\ nil, lane \\ nil, retries \\ 10) do
    result = apply_callback(closure, args, fid, lane)

    case result do
      {:error, msg} when retries > 0 ->
        if is_binary(msg) and msg =~ "stale environment frame" do
          Process.sleep(20)
          apply_reply_callback(closure, args, fid, lane, retries - 1)
        else
          result
        end

      _ ->
        result
    end
  end

  @doc """
  Apply a Scheme closure and return its value (e.g. a completion fn).
  LABEL names the job in the lane's slow-job log; the closure itself has
  no name.
  """
  def call_fn(closure, args, fid \\ nil, lane \\ nil, label \\ "") do
    fid = fid(fid)

    Lane.run(
      lane || :ui,
      fn _from -> exec_call_fn(closure, args, fid) end,
      30_000,
      String.trim("call-fn #{label}")
    )
  end

  @doc "Apply a read-only closure in its own supervised shared-world process."
  def call_fn_concurrent(closure, args, fid \\ nil, timeout \\ 30_000, label \\ "") do
    case SchemeTask.call(closure, args, timeout,
           fid: fid(fid),
           buffer: Frame.buffer_context(),
           label: String.trim("tool #{label}")
         ) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Apply a named global function to ARGS. ARGS pass as values, never through
  source text — the safe call for Elixir callers holding strings (paths,
  buffer names) that must not be interpolated into Scheme.
  """
  def call_named(fun, args, fid \\ nil, timeout \\ 30_000, lane \\ nil) when is_binary(fun) do
    fid = fid(fid)
    Lane.run(lane || :ui, fn _from -> exec_call_named(fun, args, fid) end, timeout, "call #{fun}")
  end

  # A slow eval holds its lane, and the lane log names the job. "eval"
  # alone names nothing: it took a labelled run to learn that the nine
  # second jobs in the suite were all apropos. Carry the source, flattened
  # and short, so the log line is the diagnosis.
  defp eval_label(src) do
    "eval " <> (src |> String.replace(~r/\s+/, " ") |> String.slice(0, 70))
  end

  defp fid(nil), do: Frame.current()
  defp fid(fid), do: fid

  def eval_region(buffer, start_pos, end_pos) do
    src = buffer |> Buffer.text() |> binary_part(start_pos, end_pos - start_pos)
    eval(src)
  end

  def eval_buffer(buffer), do: buffer |> Buffer.text() |> eval()

  # The row goes to the table only. *Messages* is messages-mode's list over
  # the table: the Scheme `message` wrapper redraws it when it is in a
  # window, and a command in it restamps. No buffer write happens here, so
  # a killed *Messages* costs nothing until Scheme makes it again.
  def message(text, level \\ "info", context \\ %{}) do
    :ok = Compos.Core.SchemeTables.ensure_table(@messages_table)
    context = Map.new(context)
    level = normalize_message_level(level)
    source = Map.get(context, :source, "")
    group = Map.get(context, :group, "")
    project = Map.get(context, :project, "")
    id = System.unique_integer([:positive, :monotonic])

    :ets.insert(
      @messages_table,
      {id, System.system_time(:millisecond), level, source, group, project, text}
    )

    trim_messages()
    # Emacs: echo in the frame that triggered; with no frame context (agent
    # events, timers) every frame gets it — *Messages* is shared either way
    if Frame.current(), do: Editor.set_echo(text), else: Editor.set_echo_all(text)
    :ok
  end

  def messages(limit \\ @messages_limit) do
    :ok = Compos.Core.SchemeTables.ensure_table(@messages_table)
    limit = max(0, min(limit, @messages_limit))

    @messages_table
    |> :ets.tab2list()
    |> Enum.take(-limit)
  end

  def clear_messages do
    :ok = Compos.Core.SchemeTables.ensure_table(@messages_table)
    :ets.delete_all_objects(@messages_table)
    :ok
  end

  defp normalize_message_level({:sym, level}), do: normalize_message_level(level)

  defp normalize_message_level(level) do
    case level |> to_string() |> String.downcase() do
      "debug" -> "debug"
      "warning" -> "warning"
      "warn" -> "warning"
      "error" -> "error"
      _ -> "info"
    end
  end

  defp trim_messages do
    overflow = :ets.info(@messages_table, :size) - @messages_limit

    if overflow > 0 do
      @messages_table
      |> :ets.tab2list()
      |> Enum.take(overflow)
      |> Enum.each(fn {id, _, _, _, _, _, _} -> :ets.delete(@messages_table, id) end)
    end
  end

  defp message_rows(limit) do
    messages(limit)
    |> Enum.map(fn {id, time_ms, level, source, group, project, text} ->
      [
        {:sym, "id"},
        id,
        {:sym, "time-ms"},
        time_ms,
        {:sym, "level"},
        level,
        {:sym, "source"},
        source,
        {:sym, "group"},
        group,
        {:sym, "project"},
        project,
        {:sym, "text"},
        text
      ]
    end)
  end

  # Sorted by the downcased name: a plain sort is ASCII, and a mode command
  # takes the mode's name verbatim, so "Dired" sat above every lowercase
  # command at the top of M-x instead of among the d's.
  def command_names do
    Compos.Core.SchemeAPI.commands_table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort_by(&String.downcase/1)
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # The tables belong to Compos.Core.SchemeTables, which runs no Scheme and
    # so cannot die of it. Empty them rather than create them: their identity
    # then survives a crash here, and no lane worker holding the published
    # handle ever reads a dead table id.
    Enum.each(Compos.Core.SchemeTables.named_tables(), &Compos.Core.SchemeTables.reset/1)
    # *Messages* is this session's log, so it starts empty every boot. Drop
    # the row and the checkpoint an older daemon left: without this, the
    # catalog still names *Messages*, create_buffer restores last session's
    # text, and boot pays for a restore nobody wants.
    Compos.Core.BufferStore.forget(@messages)

    case Compos.Core.create_buffer(@messages, persistent: false) do
      {:ok, _} ->
        :ok

      # A restart, not a boot: the log buffer outlived the process that
      # writes to it. Matching only {:ok, _} here made this init fail, and a
      # Session that cannot restart is a Session whose every crash ends as a
      # crash loop and takes the application down with it. Empty the buffer
      # instead, which is what a fresh session's log means.
      {:error, :already_exists} ->
        size = Compos.Core.Buffer.byte_size(@messages)
        if size > 0, do: Compos.Core.Buffer.delete_range(@messages, 0, size, source: :editor)
        :ok
    end

    interp = Scheme.new(primitives: Compos.Core.SchemeAPI.primitives())
    # this process created the environment table, so a crash here would
    # destroy it; hand it to the table owner instead
    Compos.Core.SchemeTables.adopt(interp.store.tid)
    interp = Scheme.register(interp, session_primitives(interp.global))
    interp = load_stdlib!(interp)

    # loading leaves a pile of dead frames behind — sweep once so the
    # doubling threshold starts from a live baseline, then publish the
    # survivors to the shared tier: lanes resolve every rooted closure
    interp = Scheme.gc(interp, external_roots())
    interp = Scheme.flush(interp)

    :persistent_term.put(@pt, interp)
    :persistent_term.put(@pt_stamp, primitive_stamp())
    Process.send_after(self(), :gc_tick, @gc_interval)

    {:ok,
     %{
       last_live: Scheme.frame_count(interp),
       reload_manifest: reload_manifest()
     }}
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

  # per-job timing lives in the Lane worker now: every job reports
  # duration telemetry and slow jobs go to the log with lane and label

  # the caller's frame context, stamped into THIS process for the duration
  # of the Scheme execution — primitives resolve their frame from it. nil
  # clears (a stale pdict from the previous command must not leak forward).
  defp with_fid(nil, fun) do
    Frame.clear()
    fun.()
  end

  defp with_fid(fid, fun), do: Frame.with_frame(fid, fun)

  # --- lane executors ---------------------------------------------------------
  # These run in lane worker processes (or inline on lane re-entry), never in
  # this GenServer: a long eval holds only its own lane. Each one registers
  # with the store (Scheme.with_eval) so a sweep never runs under it.

  @doc false
  def exec_eval(src, fid, from) do
    interp = interp()

    # eval-defer! reads this: an eval that hands its work to a Task keeps
    # the caller's reply slot and answers through eval-resolve! later
    if from, do: Process.put(:eval_reply_to, from)

    result =
      Scheme.exec(interp, fn interp ->
        safe(fn -> with_fid(fid, fn -> Scheme.eval_string(interp, src) end) end)
      end)

    Process.delete(:eval_reply_to)
    deferred = Process.get(:eval_deferred)
    Process.delete(:eval_deferred)

    case {result, deferred} do
      {{:ok, val, _interp}, nil} ->
        root_result(val)
        {:reply, {:ok, Scheme.print(val)}}

      # the reply now belongs to eval-resolve!
      {{:ok, val, _interp}, _token} ->
        root_result(val)
        :noreply

      {{:error, msg}, nil} ->
        {:reply, {:error, msg}}

      # a deferred eval that then failed still owes the caller an answer
      {{:error, msg}, token} ->
        :ets.delete(@escaped, {:eval_pending, token})
        {:reply, {:error, msg}}
    end
  end

  @doc false
  def exec_run_command(name, fid) do
    case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), name) do
      [] ->
        {:reply, {:error, "undefined command"}}

      [{^name, closure, _doc}] ->
        interp = interp()

        result =
          Scheme.exec(interp, fn interp ->
            safe(fn ->
              with_fid(fid, fn ->
                case Scheme.call(interp, closure, []) do
                  {:ok, val, interp} ->
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

                  {:error, msg} ->
                    {:error, msg}
                end
              end)
            end)
          end)

        case result do
          {:ok, val, _interp} ->
            root_result(val)
            {:reply, :ok}

          {:error, msg} ->
            {:reply, {:error, msg}}
        end
    end
  end

  @doc false
  def exec_apply(closure, args, fid) do
    case Scheme.exec(interp(), fn interp ->
           safe(fn -> with_fid(fid, fn -> Scheme.call(interp, closure, args) end) end)
         end) do
      {:ok, val, _interp} ->
        root_result(val)
        {:reply, :ok}

      {:error, msg} ->
        message("error: " <> msg)
        {:reply, {:error, msg}}
    end
  end

  @doc false
  def exec_call_fn(closure, args, fid) do
    case Scheme.exec(interp(), fn interp ->
           safe(fn -> with_fid(fid, fn -> Scheme.call(interp, closure, args) end) end)
         end) do
      {:ok, val, _interp} ->
        root_result(val)
        {:reply, {:ok, val}}

      {:error, msg} ->
        {:reply, {:error, msg}}
    end
  end

  @doc false
  def exec_call_named(fun, args, fid) do
    case Scheme.exec(interp(), fn interp ->
           safe(fn ->
             with_fid(fid, fn ->
               # the name is a code-supplied constant; only ARGS are data
               {:ok, closure, interp} = Scheme.eval_string(interp, fun)
               Scheme.call(interp, closure, args)
             end)
           end)
         end) do
      {:ok, val, _interp} ->
        root_result(val)
        {:reply, {:ok, val}}

      {:error, msg} ->
        {:reply, {:error, msg}}
    end
  end

  # a returned value can carry closures whose frames nothing roots yet —
  # hold the last 32 compound results in the escaped table (a GC root)
  # until they land somewhere rooted or age out of the ring
  defp root_result(val) when is_list(val) or is_map(val) or is_tuple(val) do
    idx = :ets.update_counter(@escaped, :recent_idx, {2, 1, 31, 0}, {:recent_idx, -1})
    :ets.insert(@escaped, {{:recent, idx}, val})
    :ok
  end

  defp root_result(_val), do: :ok

  @impl true
  def handle_call(:await_boot, _from, state) do
    {:reply, :persistent_term.get(@pt), state}
  end

  def handle_call(:refresh_primitives, _from, state) do
    interp = interp()

    # Session's own primitives must go through the SAME rebind. A register
    # after the rebind fixes two things badly. An alias holds a
    # `{:builtin, "define-command", fun}` tuple that only the rebind walk
    # reaches, so `define-command--raw` in editor.scm keeps the purged fun.
    # A register also puts the raw primitive back over the Scheme wrapper
    # that editor.scm defines for the same name.
    extra =
      Map.merge(Compos.Core.SchemeAPI.primitives(), session_primitives(interp.global))

    interp = Scheme.rebind_primitives(interp, extra)
    :persistent_term.put(@pt, interp)
    :persistent_term.put(@pt_stamp, primitive_stamp())
    {:reply, :ok, state}
  end

  def handle_call({:reload_files, paths}, _from, state) do
    # A dev code reload keeps the existing GenServer state. Seed the new
    # manifest lazily so adding this mechanism does not require a restart.
    manifest = Map.get(state, :reload_manifest) || reload_manifest()

    with {:ok, files} <- reload_changes(paths, manifest),
         {:ok, _, _interp} <- eval_reload_forms(files) do
      next_manifest =
        Enum.reduce(files, manifest, fn {path, fingerprints, _forms}, acc ->
          Map.put(acc, path, fingerprints)
        end)

      changed = Enum.reduce(files, 0, fn {_, _, forms}, n -> n + length(forms) end)

      {:reply, {:ok, %{files: length(files), forms: changed}},
       Map.put(state, :reload_manifest, next_manifest)}
    else
      {:error, message} -> {:reply, {:error, message}, state}
    end
  end

  @impl true
  def handle_info({:scheme_debounce, key, generation}, state) do
    case :ets.lookup(@escaped, key) do
      [{^key, {^generation, _timer, callback, arg, fid}}] ->
        :ets.delete(@escaped, key)
        Lane.cast(:ui, fn _from -> exec_apply(callback, [arg], fid) end, "debounce")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # --- frame GC --------------------------------------------------------------
  # Periodic: evals run in lanes now, so growth is checked on a timer. The
  # sweep skips itself when any eval is in flight (Env.begin_gc) — a busy
  # editor just sweeps on a later tick.

  def handle_info(:gc_tick, state) do
    interp = interp()
    count = Scheme.frame_count(interp)

    state =
      if count > max(state.last_live * 2, @gc_floor) do
        Scheme.gc(interp, external_roots())
        after_count = Scheme.frame_count(interp)
        # a busy store skips the sweep: keep the baseline so we retry
        if after_count < count, do: %{state | last_live: after_count}, else: state
      else
        state
      end

    Process.send_after(self(), :gc_tick, @gc_interval)
    {:noreply, state}
  end

  # every place a live closure can be held outside the store: the commands
  # table, escaped fun-wrapped handlers, active minibuffer handlers (Editor
  # state), and buffer-local values
  defp external_roots do
    # every frame's prompt, not just one — a live on_confirm in a background
    # frame must not be collected
    minibuffers = (Process.whereis(Editor) && Editor.all_minibuffers()) || []

    [
      :ets.tab2list(Compos.Core.SchemeAPI.commands_table()),
      :ets.tab2list(@escaped),
      minibuffers,
      Enum.map(Compos.Core.list_buffers(), fn name ->
        if Buffer.exists?(name), do: Buffer.locals(name), else: %{}
      end)
    ]
  end

  defp load_stdlib!(interp) do
    interp =
      Enum.reduce(
        @bootstrap_files,
        interp,
        fn file, interp ->
          path = Application.app_dir(:compos_core, "priv/#{file}")
          # one file is one package here too: dired.scm carried transient's
          # stamp before this, so every dired command was filed under it
          interp = stamp_load_unit(interp, path, :bundled)

          case Scheme.eval_string(interp, File.read!(path)) do
            {:ok, _, interp} ->
              interp

            {:error, msg} ->
              # the stdlib must load — a broken stdlib is a broken editor
              raise "#{file} failed to load: #{msg}"
          end
        end
      )

    # Everything defined after boot — the REPL, a chat's eval-scheme, a
    # runtime define — is the user's, not ours, and the origin says which
    # is which.
    # init.scm above owns the complete bundled package order. User config runs
    # only after that boot manifest has finished and explicitly loads any user
    # packages it wants from ~/.compos/packages.
    interp |> load_user_init() |> stamp_origin_user()
  end

  # The stamp is its own eval, so a package's own line numbers stay its own.
  defp stamp_load_unit(interp, path, origin) do
    code = "(origin! '#{origin}) (package! '#{Path.basename(path, ".scm")})"

    case Scheme.eval_string(interp, code) do
      {:ok, _, interp2} -> interp2
      {:error, _} -> interp
    end
  end

  defp reload_changes(paths, manifest) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      expanded = canonical(path)

      try do
        with {:ok, src} <- File.read(expanded) do
          forms = Reader.read_all(src)
          fingerprints = form_fingerprints(forms)

          changed =
            case Map.fetch(manifest, expanded) do
              {:ok, previous} ->
                Enum.filter(forms, fn form ->
                  reload_context?(form) or not MapSet.member?(previous, form_fingerprint(form))
                end)

              :error ->
                forms
            end

          {:cont, {:ok, [{expanded, fingerprints, changed} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, "#{expanded}: #{inspect(reason)}"}}
        end
      rescue
        error -> {:halt, {:error, "#{expanded}: #{Exception.message(error)}"}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  # A reload is bracketed by two Scheme hooks. `reload-begin!` opens the
  # record; every `define-mode` and `register-minor-mode!` the reload
  # evaluates names itself in it. `reload-finish!` re-runs mode setup on
  # the buffers that wear one of those modes, so a mode change reaches the
  # buffers already open in it. Without that, a reloaded mode holds the old
  # keys and overlays until a restart, which is the reason a restart was
  # ever needed for a mode change.
  #
  # The hooks run inside the same `Scheme.exec` as the forms, so they see
  # exactly the definitions this reload made. Both are guarded by `boundp`:
  # a reload of `editor.scm` itself starts before either name exists.
  @reload_begin "(if (boundp (quote reload-begin!)) (reload-begin!))"
  @reload_finish "(if (boundp (quote reload-finish!)) (reload-finish!))"

  defp eval_reload_forms(files) do
    Scheme.exec(interp(), fn interp ->
      interp = eval_hook(interp, @reload_begin)

      case reduce_reload_files(files, interp) do
        {:ok, value, interp} ->
          {:ok, value, eval_hook(interp, @reload_finish)}

        # The finish hook runs after a failed reload too: the forms that did
        # evaluate can already have redefined a mode, and the record must
        # not carry those names into the next reload.
        {:error, message, interp} ->
          eval_hook(interp, @reload_finish)
          {:error, message}
      end
    end)
  end

  defp reduce_reload_files(files, interp) do
    Enum.reduce_while(files, {:ok, nil, interp}, fn {path, _fingerprints, forms},
                                                    {:ok, _, current} ->
      current = stamp_load_unit(current, path, reload_origin(path))

      case Scheme.eval_forms(current, forms) do
        {:ok, value, next} -> {:cont, {:ok, value, next}}
        {:error, message} -> {:halt, {:error, message, current}}
      end
    end)
  end

  defp eval_hook(interp, src) do
    case Scheme.eval_string(interp, src) do
      {:ok, _, interp2} ->
        interp2

      {:error, message} ->
        Logger.error("reload hook failed: #{message}")
        interp
    end
  end

  defp reload_context?([{:sym, name} | _]), do: name in @reload_context
  defp reload_context?(_), do: false

  defp form_fingerprints(forms), do: MapSet.new(forms, &form_fingerprint/1)
  defp form_fingerprint(form), do: :crypto.hash(:sha256, :erlang.term_to_binary(form))

  defp reload_origin(path) do
    user_packages = Path.join(Compos.Core.config_dir(), "packages") |> canonical()
    if String.starts_with?(canonical(path), user_packages <> "/"), do: :user, else: :bundled
  end

  defp reload_manifest do
    reload_source_paths()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, src} ->
          try do
            Map.put(acc, Path.expand(path), form_fingerprints(Reader.read_all(src)))
          rescue
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp reload_source_paths do
    priv = canonical(Application.app_dir(:compos_core, "priv"))
    packages = Path.wildcard(Path.join([priv, "packages", "**/*.scm"]))
    Enum.map(@bootstrap_files, &Path.join(priv, &1)) ++ packages
  end

  @doc """
  A path with every symlinked ancestor resolved.

  Mix puts a symlink at `_build/dev/lib/compos_core/priv`, so
  `Application.app_dir/2` and a reload request name the same file with two
  different strings. The manifest is keyed by one and looked up by the
  other, and `Path.expand/1` does not resolve links. Every reload of a file
  therefore looked new, and re-evaluated all of it. Both sides go through
  this function now.
  """
  def canonical(path) do
    path = Path.expand(path)

    case :file.read_link(path) do
      {:ok, target} ->
        canonical(Path.expand(target, Path.dirname(path)))

      _ ->
        parent = Path.dirname(path)
        if parent == path, do: path, else: Path.join(canonical(parent), Path.basename(path))
    end
  end

  # (load "foo.scm") from init.scm/ai-config.scm resolves relative to the
  # config home, not the daemon's working directory — the config files are
  # the reader's frame of reference. "~/..." and absolute paths pass through.
  defp expand_load_path(path) do
    cond do
      String.starts_with?(path, "~") -> Path.expand(path)
      Path.type(path) == :absolute -> Path.expand(path)
      true -> Path.join(Compos.Core.config_dir(), path) |> Path.expand()
    end
  end

  # After the explicit bundled priv/init.scm boot manifest: user config is
  # <home>/ai-config.scm, init.scm, then custom.scm (saved
  # customizations load last so they win over init) — errors log loudly
  # but never brick boot. (load "...") works from inside either. Tests set
  # :home to a tmp dir so the user's real init.scm stays out of them.
  defp load_user_init(interp) do
    Enum.reduce(["ai-config.scm", "init.scm", "custom.scm"], interp, fn file, interp ->
      path = Path.join(Compos.Core.config_dir(), file)

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

  defp stamp_origin_user(interp) do
    case Scheme.eval_string(interp, "(origin! 'user)") do
      {:ok, _, interp2} -> interp2
      {:error, _} -> interp
    end
  end

  # one merged map: the three registration modules' docs
  defp primitive_docs do
    Compos.Scheme.Builtins.docs()
    |> Map.merge(Compos.Core.SchemeAPI.docs())
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
      "message" => "(message TEXT [LEVEL]) — log TEXT and show it in the echo area.",
      "message-emit" =>
        "(message-emit TEXT LEVEL SOURCE GROUP PROJECT) — record one structured editor message.",
      "messages-snapshot" =>
        "(messages-snapshot [LIMIT]) — return recent structured editor messages, oldest first.",
      "messages-clear!" => "(messages-clear!) — discard every editor message.",
      "actor-spawn" =>
        "(actor-spawn BEHAVIOR STATE) — start an isolated Scheme actor; BEHAVIOR returns (NEW-STATE REPLY).",
      "actor-self" => "(actor-self) — return the current isolated actor, or #f.",
      "actor-ref?" => "(actor-ref? VALUE) — return #t when VALUE is a Scheme actor reference.",
      "actor-alive?" => "(actor-alive? ACTOR) — return #t when ACTOR is running.",
      "actor-send!" => "(actor-send! ACTOR MESSAGE) — send a data message without waiting.",
      "actor-call" =>
        "(actor-call ACTOR MESSAGE [MS]) — send a data message and return its reply.",
      "actor-after!" => "(actor-after! MS ACTOR MESSAGE) — send a data message after the delay.",
      "actor-monitor!" =>
        "(actor-monitor! OBSERVER TARGET TAG) — send (down TAG REASON) when TARGET stops.",
      "actor-stop!" => "(actor-stop! ACTOR) — stop ACTOR and invalidate its reference.",
      "task-spawn" =>
        "(task-spawn THUNK) — run a zero-argument Scheme closure concurrently over the shared editor world.",
      "task-run!" =>
        "(task-run! THUNK CALLBACK [MS]) — run THUNK concurrently; later call CALLBACK with OK? and its value or error.",
      "task-await" =>
        "(task-await TASK [MS]) — wait for a Scheme task and return its value, or raise its error.",
      "task-ref?" => "(task-ref? VALUE) — return #t when VALUE is a Scheme task reference.",
      "task-alive?" => "(task-alive? TASK) — return #t while TASK remains available.",
      "task-cancel!" => "(task-cancel! TASK) — stop a Scheme task.",
      "define-command" =>
        "(define-command NAME [DOC] FN) — register an M-x command; DOC shows in M-x.",
      "undefine-command" => "(undefine-command NAME) — remove an M-x command from the registry.",
      "command-names" => "(command-names) — return every M-x command name.",
      "global-keys" =>
        "(global-keys) — return ((KEYS COMMAND) ...) for every global key binding.",
      "local-keys" =>
        "(local-keys BUF) — return ((KEYS COMMAND) ...) for BUF's own key bindings.",
      "command-fn" => "(command-fn NAME) — return the command's closure, or #f.",
      "command-doc" =>
        "(command-doc NAME) — return the command's doc string; empty when it has none.",
      "run-command" => "(run-command NAME) — run the named command; error when it is undefined.",
      "llm" => "(llm PROMPT CALLBACK) — start an async completion; CALLBACK gets the reply text.",
      "llm-with-model" =>
        "(llm-with-model PROMPT MODEL CALLBACK) — async completion on MODEL; CALLBACK gets the reply text.",
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
      "lsp-start!" => "(lsp-start! NAME ROOT SPEC) — start a language server for a project root.",
      "lsp-stop!" =>
        "(lsp-stop! ID) — stop the connection \"name@root\" with the shutdown handshake.",
      "lsp-connections" => "(lsp-connections) — return (id status name root) per connection.",
      "lsp-server-detail" =>
        "(lsp-server-detail ID) — return a status plist, or #f when never started.",
      "lsp-log" => "(lsp-log ID) — return ((time dir text) ...) JSON-RPC frames, oldest first.",
      "lsp-on-event!" =>
        "(lsp-on-event! HANDLER) — set the handler that gets (ID METHOD PARAMS) on server events.",
      "lsp-open!" => "(lsp-open! ID BUF) — open BUF on the server and keep it in sync.",
      "lsp-close!" => "(lsp-close! ID BUF) — close BUF on the server.",
      "lsp-notify!" => "(lsp-notify! ID METHOD PARAMS) — send a notification to the server.",
      "lsp-request" => "(lsp-request ID METHOD PARAMS CB) — send a request; CB gets (OK RESULT).",
      "lsp-buffer-request" =>
        "(lsp-buffer-request ID METHOD BUF BYTE-POS [EXTRA] CB) — request at a buffer position; CB gets (OK RESULT).",
      "db-connect!" =>
        "(db-connect! NAME SPEC) — open a named database connection; SPEC has 'adapter 'database 'user 'password 'host or 'socket_dir 'port 'ssl.",
      "db-disconnect!" => "(db-disconnect! NAME) — close the database connection NAME.",
      "db-connected?" => "(db-connected? NAME) — #t when NAME is open.",
      "db-list" => "(db-list) — return (name adapter database) per connection.",
      "db-adapters" => "(db-adapters) — the database adapters this build can open.",
      "db-query" =>
        "(db-query NAME-OR-TRANSACTION SQL [PARAMS] [CB]) — without CB, run on the calling lane and return RESULT; with CB, answer asynchronously with (OK RESULT).",
      "db-with-transaction" =>
        "(db-with-transaction NAME PROC) — call PROC with a scoped transaction handle; commit and return its value, or roll back on error.",
      "endpoint-start!" =>
        "(endpoint-start! NAME SPEC) — open a named connection; SPEC picks the transport and framing.",
      "endpoint-stop!" => "(endpoint-stop! NAME) — close the connection NAME.",
      "endpoint-send!" =>
        "(endpoint-send! NAME TEXT) — write one frame; do not wait for an answer.",
      "endpoint-ask" =>
        "(endpoint-ask NAME TEXT UNTIL [TIMEOUT] CB) — send a frame, collect frames up to the sentinel UNTIL; CB gets (OK FRAMES).",
      "endpoint-on-event!" =>
        "(endpoint-on-event! HANDLER) — set the handler that gets (NAME KIND TEXT) for unsolicited frames.",
      "endpoint-list" =>
        "(endpoint-list) — return (name status transport framing queued) per connection.",
      "endpoint-detail" =>
        "(endpoint-detail NAME) — return a status plist, or #f when never started.",
      "endpoint-log" =>
        "(endpoint-log NAME) — return ((time dir text) ...) frames, oldest first.",
      "web-server-start!" =>
        "(web-server-start! NAME SPEC HANDLER) — start an HTTP callback or webhook server; HANDLER receives a request plist and returns a response plist.",
      "web-server-stop!" => "(web-server-stop! NAME) — stop the named HTTP server.",
      "web-server-list" =>
        "(web-server-list) — return (name host port url max-body) for every programmable HTTP server.",
      "web-server-detail" =>
        "(web-server-detail NAME) — return the server detail plist, or #f when the server is not running.",
      "tool-specs-json" =>
        "(tool-specs-json SPECS) — return the specs as MCP tools/list JSON text.",
      "priv-path" =>
        "(priv-path REL) — return the absolute path of REL in the compos_core priv directory.",
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
      "llm-model-reasoning" =>
        "(llm-model-reasoning MODEL) — return normalized reasoning controls from the shared model catalog, or #f.",
      "llm-available-models" =>
        "(llm-available-models) — return ReqLLM's credential-aware chat model inventory.",
      "llm-session-open!" =>
        "(llm-session-open! ID CONFIG [CONTEXT EVENTS RECORD PERMISSION]) — open a backend-neutral LLM session.",
      "llm-session-send!" =>
        "(llm-session-send! ID TEXT [DISPLAY]) — send or queue a message on an LLM session.",
      "llm-session-cancel!" => "(llm-session-cancel! ID) — cancel an LLM session's current turn.",
      "llm-session-close!" => "(llm-session-close! ID) — close an LLM session.",
      "llm-session-set-model!" =>
        "(llm-session-set-model! ID MODEL) — switch a live LLM session's model when supported.",
      "llm-session-set-effort!" =>
        "(llm-session-set-effort! ID EFFORT) — set reasoning effort for subsequent turns when supported.",
      "llm-session-set-mode!" =>
        "(llm-session-set-mode! ID MODE) — switch a live LLM session's permission mode when supported.",
      "llm-session-on-event!" =>
        "(llm-session-on-event! HANDLER) — set the default normalized-event handler for LLM sessions.",
      "llm-session-context-fn!" =>
        "(llm-session-context-fn! HANDLER) — set the default turn-context provider for LLM sessions.",
      "llm-session-record-fn!" =>
        "(llm-session-record-fn! HANDLER) — set the default conversation-record writer for LLM sessions.",
      "llm-session-permission-fn!" =>
        "(llm-session-permission-fn! HANDLER) — set the default tool permission policy for LLM sessions.",
      "agent-start!" => "(agent-start! SLUG CONFIG) — start an agent thread from a config plist.",
      "agent-prompt!" =>
        "(agent-prompt! SLUG TEXT [DISPLAY]) — send a prompt; return 'sent or 'queued.",
      "agent-cancel!" => "(agent-cancel! SLUG) — cancel the agent's current turn.",
      "agent-dequeue!" =>
        "(agent-dequeue! SLUG TEXT) — remove one queued prompt whose text is TEXT; return #t or #f.",
      "agent-permission-respond!" =>
        "(agent-permission-respond! SLUG RPC-ID OPTION-ID) — answer a pending permission request.",
      "agent-question-respond!" =>
        "(agent-question-respond! SLUG ID ANSWER) — answer a pending branching question.",
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
        "(agent-info SLUG) — return a plist: slug, buffer, status, queued, steering, permission, question; or #f.",
      "agent-steer!" =>
        "(agent-steer! SLUG) — send the oldest queued message into the running turn; return #t when sent.",
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
        "(set-modeline-extra! TEXT) — set the extra text at the right of the frame modeline: a string, or a list of (CLASS TEXT) segments.",
      "llm-model" => "(llm-model) — return the active LLM model id.",
      "llm-context-limit" =>
        "(llm-context-limit MODEL) — input tokens the model accepts, or #f when unknown.",
      "eval-string" => "(eval-string SRC) — evaluate SRC as Scheme; return the last value.",
      "eval-defer!" =>
        "(eval-defer!) — claim the current eval's reply; return a token for eval-resolve!, or #f outside an eval.",
      "eval-resolve!" =>
        "(eval-resolve! TOKEN VALUE) — answer the deferred eval named by TOKEN with VALUE.",
      "with-edit-author" =>
        "(with-edit-author AUTHOR THUNK) — run THUNK; buffer edits it makes are attributed to the string AUTHOR.",
      "current-edit-author" =>
        "(current-edit-author) — the caller process's edit author string, or #f",
      "with-current-buffer" =>
        "(with-current-buffer BUF THUNK) — run THUNK with BUF current without displaying it or changing any window.",
      "with-frame-windows" =>
        "(with-frame-windows THUNK) — run THUNK with no logical buffer context: current-buffer and switch-to-buffer! act on the frame's real windows.",
      "with-scheme-lock" =>
        "(with-scheme-lock KEY THUNK) — run THUNK once at a time for KEY across Scheme processes.",
      "eval-string-safe" =>
        "(eval-string-safe SRC) — evaluate SRC; return (ok VAL) or (error MSG).",
      "wait-until" =>
        "(wait-until PRED &optional TIMEOUT-MS INTERVAL-MS) — poll PRED until it answers true; return #t, or #f at the deadline.",
      "symbol-value" => "(symbol-value 'NAME) — return the global value of the symbol.",
      "set-symbol-value!" =>
        "(set-symbol-value! 'NAME VAL) — set the global value of the symbol.",
      "boundp" => "(boundp 'NAME) — return #t when the symbol has a global binding.",
      "global-names" => "(global-names) — return every globally bound name, sorted.",
      "load" => "(load PATH) — evaluate a Scheme file in the live session.",
      "eval-region" =>
        "(eval-region BUF START END) — evaluate the text between byte offsets START and END.",
      "eval-buffer" => "(eval-buffer BUF) — evaluate the whole buffer as Scheme.",
      "on-change!" =>
        "(on-change! BUF CB ['eager]) — call (CB POS INSERTED DELETED-LEN SOURCE) on changes; fires only while BUF is visible or in the current buffer's group, unless 'eager; return an id.",
      "remove-on-change!" => "(remove-on-change! ID) — remove a change handler by its id.",
      "with-window-buffer" =>
        "(with-window-buffer THUNK) — run THUNK with the window's buffer current, not the prompt.",
      "delete-frame!" =>
        "(delete-frame! [ID]) — delete the frame and run its prompt's cancel handler.",
      "minibuffer-buffer" => "(minibuffer-buffer) — return the minibuffer's buffer name.",
      "minibuffer-state" => "(minibuffer-state) — return the active prompt as a plist, or #f.",
      "minibuffer-input!" => "(minibuffer-input! INPUT) — set the minibuffer input text.",
      "minibuffer-change!" =>
        "(minibuffer-change! INPUT) — set minibuffer input and run its live change handler.",
      "debounce!" =>
        "(debounce! KEY MS CALLBACK ARG) — after MS idle, call CALLBACK with ARG; a newer call with KEY cancels the old one.",
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
      Enum.reduce(Compos.Scheme.Reader.read_all(src), {:void, store}, fn form, {_v, store} ->
        Compos.Scheme.Eval.eval(form, global, store)
      end)
    end

    %{
      "message" => fn
        [text] ->
          message(to_string(text))
          :void

        [text, level] ->
          message(to_string(text), level)
          :void
      end,
      "message-emit" => fn [text, level, source, group, project] ->
        message(to_string(text), level,
          source: to_string(source),
          group: to_string(group),
          project: to_string(project)
        )

        :void
      end,
      "messages-snapshot" => fn
        [] -> message_rows(@messages_limit)
        [limit] -> message_rows(trunc(limit))
      end,
      "messages-clear!" => fn [] ->
        clear_messages()
        :void
      end,
      "actor-spawn" => fn [behavior, initial_state], store ->
        interp = %Scheme{store: store, global: global}

        case SchemeActor.start(interp, behavior, initial_state) do
          {:ok, ref} -> {ref, store}
          {:error, reason} -> raise_scheme("actor-spawn: #{reason}")
        end
      end,
      "actor-self" => fn [] -> SchemeActor.current() end,
      "actor-ref?" => fn [value] -> SchemeActor.actor_ref?(value) end,
      "actor-alive?" => fn [actor] -> SchemeActor.alive?(actor) end,
      "actor-send!" => fn [actor, message] ->
        case SchemeActor.cast(actor, message) do
          :ok -> true
          {:error, reason} -> raise_scheme("actor-send!: #{reason}")
        end
      end,
      "actor-call" => fn
        [actor, message] ->
          actor_call(actor, message, 5_000)

        [actor, message, timeout] ->
          actor_call(actor, message, trunc(timeout))
      end,
      "actor-after!" => fn [milliseconds, actor, message] ->
        case SchemeActor.deliver_after(actor, trunc(milliseconds), message) do
          :ok -> true
          {:error, reason} -> raise_scheme("actor-after!: #{reason}")
        end
      end,
      "actor-monitor!" => fn [observer, target, tag] ->
        case SchemeActor.monitor(observer, target, tag) do
          :ok -> true
          {:error, reason} -> raise_scheme("actor-monitor!: #{reason}")
        end
      end,
      "actor-stop!" => fn [actor] ->
        :ok = SchemeActor.stop(actor)
        true
      end,
      "task-spawn" => fn [closure] ->
        case SchemeTask.start(closure) do
          {:ok, ref} -> ref
          {:error, reason} -> raise_scheme("task-spawn: #{reason}")
        end
      end,
      "task-run!" => fn
        [closure, callback] -> scheme_task_run(closure, callback, 300_000)
        [closure, callback, timeout] -> scheme_task_run(closure, callback, trunc(timeout))
      end,
      "task-await" => fn
        [task] -> scheme_task_await(task, 30_000)
        [task, timeout] -> scheme_task_await(task, trunc(timeout))
      end,
      "task-ref?" => fn [value] -> SchemeTask.task_ref?(value) end,
      "task-alive?" => fn [task] -> SchemeTask.alive?(task) end,
      "task-cancel!" => fn [task] ->
        :ok = SchemeTask.cancel(task)
        true
      end,
      "define-command" => fn
        [name, closure] ->
          :ets.insert(Compos.Core.SchemeAPI.commands_table(), {command_name(name), closure, ""})
          :void

        [name, doc, closure] when is_binary(doc) ->
          :ets.insert(Compos.Core.SchemeAPI.commands_table(), {command_name(name), closure, doc})
          :void
      end,
      "undefine-command" => fn [name] ->
        :ets.delete(Compos.Core.SchemeAPI.commands_table(), command_name(name))
        true
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
        case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> false
          [{_, closure, _}] -> closure
        end
      end,
      "command-doc" => fn [name] ->
        case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> ""
          [{_, _, doc}] -> doc
        end
      end,
      "run-command" => fn [name], store ->
        case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> raise Compos.Scheme.Eval.Error, message: "undefined command: #{command_name(name)}"
          [{_, closure, _}] -> Compos.Scheme.Eval.apply_fn(closure, [], store)
        end
      end,
      "llm" => fn [prompt, callback] ->
        # the callback vanishes into an opaque fun until the reply arrives —
        # root it for the GC, and unroot once it has fired
        key = {:llm, make_ref()}
        :ets.insert(@escaped, {key, callback})

        Compos.Core.LLM.complete(prompt, fn text ->
          try do
            apply_reply_callback(callback, [text])
          after
            :ets.delete(@escaped, key)
          end
        end)

        :void
      end,
      "llm-with-model" => fn [prompt, model, callback] ->
        key = {:llm, make_ref()}
        :ets.insert(@escaped, {key, callback})

        Compos.Core.LLM.complete(prompt, to_string(model), fn text ->
          try do
            apply_reply_callback(callback, [text])
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

        Compos.Core.LLM.complete_tools(
          prompt,
          system,
          specs,
          dispatcher,
          fn text ->
            try do
              apply_reply_callback(callback, [text])
            after
              :ets.delete(@escaped, key)
            end
          end,
          on_usage: on_usage,
          model: requested_model && to_string(requested_model)
        )

        :void
      end,

      # --- browser (Compos.Core.Browser; policy in chrome.scm) ---------------
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

        Compos.Core.Browser.call(s(op), browser_args(args), fn reply ->
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

        Compos.Core.Browser.call(s(op), browser_args(a), fn reply ->
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
        Compos.Core.Browser.serve(handler)
        :void
      end,
      "browser-connected?" => fn [] -> Compos.Core.Browser.connected?() end,
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
        fid = Compos.Core.Frame.current()

        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          Enum.each(keys, &Compos.Core.Input.dispatch(fid, &1))
        end)

        :void
      end,

      # --- MCP client (Compos.Core.MCP; policy in packages/mcp.scm) ----------
      "mcp-connect!" => fn [name, spec] ->
        case Compos.Core.MCP.connect(s(name), mcp_spec(spec)) do
          {:ok, _} -> :void
          {:error, msg} -> raise_scheme("mcp-connect!: #{inspect(msg)}")
        end
      end,
      "mcp-disconnect!" => fn [name] ->
        Compos.Core.MCP.disconnect(s(name))
        :void
      end,
      "mcp-connections" => fn [] ->
        for c <- Compos.Core.MCP.connections() do
          [c.name, to_string(c.status), c.tools, to_string(c.type), c.resources, c.prompts]
        end
      end,
      # what the hub's detail view reads: false for a server never started
      "mcp-server-detail" => fn [name] ->
        case Compos.Core.MCP.detail(s(name)) do
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
              for(
                r <- d.resources,
                do: [r["name"] || "", r["uri"] || "", r["description"] || ""]
              ),
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
        for e <- Compos.Core.MCP.log(s(name)) do
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
        Compos.Core.MCP.tool_specs(Enum.map(names, &s/1))
      end,
      # Wait for a server that is still shaking hands, up to the same
      # bound. An empty tool list reads as "this server serves nothing",
      # which is a lie the caller cannot tell from the truth.
      "mcp-await-ready" => fn args ->
        [server | rest] = args
        server = s(server)
        wait = if is_integer(List.first(rest)), do: List.first(rest), else: @mcp_wait

        task =
          Task.Supervisor.async_nolink(Compos.Core.TaskSupervisor, fn ->
            Compos.Core.MCP.await_ready(server, wait)
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
      # agent through the compos proxy) needs an answer, not a promise.
      "mcp-tool-call" => fn
        [server, tool, args] ->
          mcp_wait_call(s(server), s(tool), mcp_args(args), @mcp_wait)

        [server, tool, args, timeout] when is_integer(timeout) ->
          mcp_wait_call(s(server), s(tool), mcp_args(args), timeout)

        [server, tool, args, callback] ->
          key = {:mcp_call, make_ref()}
          :ets.insert(@escaped, {key, callback})
          {server, tool, args} = {s(server), s(tool), mcp_args(args)}

          Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
            result = Compos.Core.MCP.call_when_ready(server, tool, args, @mcp_wait)

            try do
              apply_callback(callback, mcp_callback_args(result))
            after
              :ets.delete(@escaped, key)
            end
          end)

          :void
      end,
      # --- LSP client (Compos.Core.LSP; policy in packages/lsp.scm) ----------
      "lsp-start!" => fn [name, root, spec] ->
        case Compos.Core.LSP.start(s(name), s(root), lsp_spec(spec)) do
          {:ok, _} -> :void
          {:error, msg} -> raise_scheme("lsp-start!: #{inspect(msg)}")
        end
      end,
      "lsp-stop!" => fn [id] ->
        case Compos.Core.LSP.parse_id(s(id)) do
          {name, root} -> Compos.Core.LSP.stop(name, root)
          _ -> :ok
        end

        :void
      end,
      "lsp-connections" => fn [] ->
        for c <- Compos.Core.LSP.connections(), do: [c.id, to_string(c.status), c.name, c.root]
      end,
      "lsp-server-detail" => fn [id] ->
        with {name, root} <- Compos.Core.LSP.parse_id(s(id)),
             d when d != nil <- Compos.Core.LSP.detail(name, root) do
          [
            {:sym, "status"},
            to_string(d.status),
            {:sym, "reason"},
            Map.get(d, :reason, ""),
            {:sym, "encoding"},
            to_string(Map.get(d, :encoding, "")),
            {:sym, "server-name"},
            Map.get(d, :server_info, %{})["name"] || "",
            {:sym, "docs"},
            Map.get(d, :docs, [])
          ]
        else
          _ -> false
        end
      end,
      "lsp-on-event!" => fn [handler] ->
        :ets.insert(@escaped, {{:lsp_handler}, handler})
        :void
      end,
      "lsp-log" => fn [id] ->
        case Compos.Core.LSP.parse_id(s(id)) do
          {name, root} ->
            for e <- Compos.Core.LSP.log(name, root) do
              [
                e.at
                |> :calendar.system_time_to_local_time(:millisecond)
                |> NaiveDateTime.from_erl!()
                |> Calendar.strftime("%H:%M:%S"),
                to_string(e.dir),
                e.text
              ]
            end

          _ ->
            []
        end
      end,
      "lsp-open!" => fn [id, buf] ->
        {pid, _key} = lsp_conn!(id)
        Compos.Core.LSP.Conn.open_doc(pid, s(buf))
        :void
      end,
      "lsp-close!" => fn [id, buf] ->
        case Compos.Core.LSP.parse_id(s(id)) do
          {name, root} ->
            case Compos.Core.LSP.whereis(name, root) do
              nil -> :ok
              pid -> Compos.Core.LSP.Conn.close_doc(pid, s(buf))
            end

          _ ->
            :ok
        end

        :void
      end,
      "lsp-notify!" => fn [id, method, params] ->
        {pid, _key} = lsp_conn!(id)
        Compos.Core.LSP.Conn.notify(pid, s(method), scheme_to_json(params))
        :void
      end,
      "lsp-request" => fn [id, method, params, callback] ->
        {pid, key} = lsp_conn!(id)
        Compos.Core.LSP.Conn.request(pid, s(method), scheme_to_json(params), lsp_cb(callback, key))
        :void
      end,
      "lsp-buffer-request" => fn
        [id, method, buf, pos, callback] ->
          {pid, key} = lsp_conn!(id)

          Compos.Core.LSP.Conn.buffer_request(
            pid,
            s(method),
            s(buf),
            pos,
            %{},
            lsp_cb(callback, key)
          )

          :void

        [id, method, buf, pos, extra, callback] ->
          {pid, key} = lsp_conn!(id)

          Compos.Core.LSP.Conn.buffer_request(
            pid,
            s(method),
            s(buf),
            pos,
            scheme_to_json(extra),
            lsp_cb(callback, key)
          )

          :void
      end,
      # --- Databases (Compos.Core.DB; policy in packages/db.scm) ------------
      "db-connect!" => fn [name, spec] ->
        case Compos.Core.DB.connect(s(name), plist_to_map(spec)) do
          {:ok, _} -> :void
          {:error, msg} -> raise_scheme("db-connect!: #{msg}")
        end
      end,
      "db-disconnect!" => fn [name] ->
        Compos.Core.DB.disconnect(s(name))
        :void
      end,
      "db-connected?" => fn [name] -> Compos.Core.DB.whereis(s(name)) != nil end,
      "db-list" => fn [] ->
        for c <- Compos.Core.DB.connections(), do: [c.name, c.adapter, c.database]
      end,
      "db-adapters" => fn [] -> String.split(Compos.Core.DB.known_adapters(), ", ") end,
      "db-query" => fn
        [target, sql] ->
          db_query_sync(db_target(target), s(sql), [])

        [target, sql, params] when is_list(params) ->
          db_query_sync(db_target(target), s(sql), db_params(params))

        [name, sql, params, callback] ->
          Compos.Core.DB.query(s(name), s(sql), db_params(params), db_cb(callback))
          :void

        [name, sql, callback] ->
          Compos.Core.DB.query(s(name), s(sql), [], db_cb(callback))
          :void
      end,
      "db-with-transaction" => fn [name, procedure], store ->
        case Compos.Core.DB.with_transaction(s(name), fn transaction ->
               Compos.Scheme.Eval.apply_fn(procedure, [transaction], store)
             end) do
          {:ok, result_and_store} -> result_and_store
          {:error, msg} -> raise_scheme("db-with-transaction: #{msg}")
        end
      end,
      # --- Endpoints (Compos.Core.Endpoint; policy in Scheme packages) ------
      "endpoint-start!" => fn [name, spec] ->
        case Compos.Core.Endpoint.start(s(name), endpoint_spec(spec)) do
          {:ok, _} -> :void
          {:error, msg} -> raise_scheme("endpoint-start!: #{inspect(msg)}")
        end
      end,
      "endpoint-stop!" => fn [name] ->
        Compos.Core.Endpoint.stop(s(name))
        :void
      end,
      "endpoint-send!" => fn [name, text] ->
        Compos.Core.Endpoint.Conn.send_frame(endpoint_conn!(name), s(text))
        :void
      end,
      "endpoint-ask" => fn
        [name, text, until, callback] ->
          endpoint_ask(name, text, until, false, callback)

        [name, text, until, timeout, callback] ->
          endpoint_ask(name, text, until, timeout, callback)
      end,
      "endpoint-on-event!" => fn [handler] ->
        :ets.insert(@escaped, {{:endpoint_handler}, handler})
        :void
      end,
      "endpoint-list" => fn [] ->
        for c <- Compos.Core.Endpoint.connections(),
            do: [c.name, to_string(c.status), to_string(c.transport), c.framing, c.queued]
      end,
      "endpoint-detail" => fn [name] ->
        case Compos.Core.Endpoint.detail(s(name)) do
          nil ->
            false

          d ->
            [
              {:sym, "status"},
              to_string(d.status),
              {:sym, "reason"},
              Map.get(d, :reason, ""),
              {:sym, "transport"},
              to_string(d.transport),
              {:sym, "framing"},
              Map.get(d, :framing, ""),
              {:sym, "queued"},
              Map.get(d, :queued, 0)
            ]
        end
      end,
      "endpoint-log" => fn [name] ->
        for e <- Compos.Core.Endpoint.log(s(name)) do
          [
            e.at
            |> :calendar.system_time_to_local_time(:millisecond)
            |> NaiveDateTime.from_erl!()
            |> Calendar.strftime("%H:%M:%S"),
            to_string(e.dir),
            e.text
          ]
        end
      end,
      # --- Inbound HTTP servers (Bandit mechanism; Scheme handlers) -------
      "web-server-start!" => fn [name, spec, handler] ->
        case Compos.Core.WebServer.start(s(name), plist_to_map(spec), handler) do
          {:ok, detail} -> web_server_detail(detail)
          {:error, msg} -> raise_scheme("web-server-start!: #{msg}")
        end
      end,
      "web-server-stop!" => fn [name] ->
        Compos.Core.WebServer.stop(s(name))
        :void
      end,
      "web-server-list" => fn [] ->
        for server <- Compos.Core.WebServer.servers() do
          [server.name, server.host, server.port, server.url, server.max_body]
        end
      end,
      "web-server-detail" => fn [name] ->
        case Compos.Core.WebServer.detail(s(name)) do
          nil -> false
          detail -> web_server_detail(detail)
        end
      end,
      # MCP-shaped JSON for a list of registry tool specs — the proxy's
      # tools/list payload (input_schema key renamed to MCP's camelCase)
      "tool-specs-json" => fn [specs] ->
        specs
        |> Enum.map(fn spec ->
          %{input_schema: schema} = t = Compos.Core.LLM.tool_json(spec)

          t
          |> Map.delete(:input_schema)
          |> Map.put(:inputSchema, schema)
          |> Map.put(:annotations, Compos.Core.LLM.tool_annotations(spec))
        end)
        |> Jason.encode!()
      end,
      # canonical: the build dir holds a symlink to the checkout's priv, and
      # a path that names the source file is the one a reader can open,
      # reload, and diff. A release has no link, so the path is unchanged.
      "priv-path" => fn [rel] ->
        canonical(Path.join(Application.app_dir(:compos_core, "priv"), rel))
      end,
      # --- runtime tree-sitter grammars (Compos.Core.TreeSitter) --------------
      "ts-install-grammar!" => fn [name, url] ->
        n = s(name)
        u = s(url)

        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          case Compos.Core.TreeSitter.install(n, u) do
            "ok" -> message("grammar #{n} installed — buffers pick it up on their next mode set")
            err -> message("grammar #{n}: #{err}")
          end
        end)

        :void
      end,
      "ts-installed-grammars" => fn [] -> Compos.Core.TreeSitter.installed() end,
      "format-usd" => fn [amount] when is_number(amount) ->
        "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)
      end,
      "llm-price" => fn [model] ->
        case Compos.Core.LLMDb.price(s(model)) do
          nil ->
            false

          p ->
            [
              {:sym, "input"},
              p.input,
              {:sym, "output"},
              p.output,
              {:sym, "cache-read"},
              p.cache_read,
              {:sym, "cache-write"},
              p.cache_write
            ]
        end
      end,
      "llm-cost-report" => fn [] ->
        for row <- Compos.Core.LLMDb.report() do
          [
            {:sym, "day"},
            row.day,
            {:sym, "model"},
            row.model,
            {:sym, "requests"},
            row.requests,
            {:sym, "input"},
            row.input,
            {:sym, "output"},
            row.output,
            {:sym, "cache-read"},
            row.cache_read,
            {:sym, "cache-write"},
            row.cache_write,
            # as whole percent: Scheme has no float formatting worth the name
            {:sym, "hit-rate"},
            case Compos.Core.LLMDb.hit_rate(row) do
              nil -> false
              r -> round(r * 100)
            end,
            {:sym, "cost"},
            row.cost * 1.0
          ]
        end
      end,
      "set-llm-model!" => fn [m] ->
        Compos.Core.LLM.set_model(m)
        :void
      end,
      # how long the provider holds a cached prefix ("5m", "1h") — the
      # defcustom llm-cache-ttl sets it
      "set-llm-cache-ttl!" => fn [ttl] ->
        Compos.Core.LLM.set_cache_ttl(to_string(ttl))
        :void
      end,
      # what a backend can do, by its resolved 'backend name — Scheme asks
      # this instead of asking which connector it is looking at
      "backend-capabilities" => fn [name] ->
        Enum.map(Compos.Core.Agent.Backend.capabilities_of(s(name)), &{:sym, to_string(&1)})
      end,
      "llm-max-tokens" => fn [model] ->
        Compos.Core.LLMDb.max_tokens(s(model)) || false
      end,
      "llm-model-reasoning" => fn [model] ->
        case Compos.Core.ModelCatalog.reasoning(s(model)) do
          nil -> false
          controls -> Compos.Core.LLM.json_to_scheme(controls)
        end
      end,
      # ReqLLM's credential-aware inventory sees only the environment. Compos's
      # key chain (env -> ~/.compos/<name>-key -> Doppler) is Scheme, so seed
      # ReqLLM's credential table from it first — a key in the file or Doppler
      # then counts as configured and the model shows in the picker. Runs in
      # the Session, so eval_src reaches the chain with no round-trip.
      "llm-available-models" => fn [], store ->
        store =
          Enum.reduce(ReqLLM.Providers.list(), store, fn provider, store ->
            {key, store} = eval_src.("(llm-key \"#{provider}\")", store)

            if is_binary(key) and key != "" do
              ReqLLM.put_key(ReqLLM.Keys.config_key(provider), key)
            end

            store
          end)

        {Compos.Core.ModelCatalog.available_models(), store}
      end,

      # --- backend-neutral LLM sessions -------------------------------------
      # A frontend may install callbacks scoped to this session. Omitted
      # callbacks fall back to the chat globals below, preserving existing
      # agent integrations while inline/document frontends use the same
      # lifecycle and backend adapters.
      "llm-session-open!" => fn [id, config | rest] ->
        keys = [:context, :handler, :record, :permission]

        callbacks =
          keys
          |> Enum.zip(rest)
          |> Map.new(fn {key, callback} -> {key, callback} end)

        case Compos.Core.LLMSession.open(s(id), plist_to_map(config), callbacks) do
          {:ok, _pid} -> s(id)
          {:error, {:already_started, _}} -> raise_scheme("LLM session already running: #{s(id)}")
          {:error, reason} -> raise_scheme("llm-session-open!: #{inspect(reason)}")
        end
      end,
      "llm-session-send!" => fn [id, text | rest] ->
        display =
          case rest do
            [d] when is_binary(d) -> d
            _ -> nil
          end

        case Compos.Core.LLMSession.send(s(id), to_string(text), display) do
          :sent -> {:sym, "sent"}
          :queued -> {:sym, "queued"}
          {:error, r} -> raise_scheme("llm-session-send!: #{inspect(r)}")
        end
      end,
      "llm-session-cancel!" => fn [id] ->
        Compos.Core.LLMSession.cancel(s(id))
        :void
      end,
      "llm-session-close!" => fn [id] ->
        Compos.Core.LLMSession.close(s(id))
        :void
      end,
      "llm-session-set-model!" => fn [id, model] ->
        case Compos.Core.LLMSession.set_model(s(id), s(model)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      "llm-session-set-effort!" => fn [id, effort] ->
        case Compos.Core.LLMSession.set_effort(s(id), s(effort)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      "llm-session-set-mode!" => fn [id, mode] ->
        case Compos.Core.LLMSession.set_mode(s(id), s(mode)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      "llm-session-on-event!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_handler}, handler})
        :void
      end,
      "llm-session-context-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_context}, handler})
        :void
      end,
      "llm-session-record-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_record}, handler})
        :void
      end,
      "llm-session-permission-fn!" => fn [handler] ->
        :ets.insert(@escaped, {{:agent_permission}, handler})
        :void
      end,

      # --- agent threads (ACP runtime, see Compos.Core.Agent) -----------------
      # config/info/events cross the boundary as flat plists: (key val ...)
      # with symbol keys — this Scheme has no dotted pairs.
      "agent-start!" => fn [slug, config] ->
        case Compos.Core.LLMSession.open(to_string(slug), plist_to_map(config)) do
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

        case Compos.Core.LLMSession.send(s(slug), to_string(text), display) do
          :sent -> {:sym, "sent"}
          :queued -> {:sym, "queued"}
          :answered -> {:sym, "answered"}
          {:error, r} -> raise_scheme("agent-prompt!: #{inspect(r)}")
        end
      end,
      "agent-steer!" => fn [slug] ->
        case Compos.Core.LLMSession.steer_next(s(slug)) do
          :sent -> true
          {:error, _reason} -> false
        end
      end,
      "agent-cancel!" => fn [slug] ->
        Compos.Core.LLMSession.cancel(s(slug))
        :void
      end,
      "agent-dequeue!" => fn [slug, text] ->
        case Compos.Core.LLMSession.dequeue(s(slug), to_string(text)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      "agent-permission-respond!" => fn [slug, rpc_id, option_id] ->
        option = if option_id in [false, :void], do: nil, else: s(option_id)

        case Compos.Core.Agent.respond_permission(s(slug), rpc_id, option) do
          :ok -> :void
          {:error, r} -> raise_scheme("agent-permission-respond!: #{inspect(r)}")
        end
      end,
      "agent-question-respond!" => fn [slug, question_id, answer] ->
        case Compos.Core.Agent.respond_question(s(slug), question_id, to_string(answer)) do
          :ok -> :void
          {:error, r} -> raise_scheme("agent-question-respond!: #{inspect(r)}")
        end
      end,
      "agent-append!" => fn [slug, text] ->
        case Compos.Core.Agent.append_at_mark(s(slug), to_string(text)) do
          mark when is_integer(mark) -> mark
          {:error, r} -> raise_scheme("agent-append!: #{inspect(r)}")
        end
      end,
      "agent-mark" => fn [slug] ->
        case Compos.Core.Agent.mark(s(slug)) do
          mark when is_integer(mark) -> mark
          {:error, r} -> raise_scheme("agent-mark: #{inspect(r)}")
        end
      end,
      "agent-list" => fn [] -> Compos.Core.Agent.list() end,
      "agent-kill!" => fn [slug] ->
        Compos.Core.LLMSession.close(s(slug))
        :void
      end,
      # live model switch on the running session (ACP session/set_model)
      "agent-set-model!" => fn [slug, model] ->
        case Compos.Core.LLMSession.set_model(s(slug), s(model)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      # live permission-mode switch (ACP session/set_mode); #f when the
      # backend doesn't do modes — the caller then answers requests itself
      "agent-set-mode!" => fn [slug, mode] ->
        case Compos.Core.LLMSession.set_mode(s(slug), s(mode)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      # -> (slug "a1" buffer "*agent: a1*" status idle queued 0 permission #f)
      "agent-info" => fn [slug] ->
        case Compos.Core.Agent.info(s(slug)) do
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

            question =
              case info.question do
                nil ->
                  false

                q ->
                  [
                    {:sym, "id"},
                    q.id,
                    {:sym, "question"},
                    q.question,
                    {:sym, "answers"},
                    q.answers
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
              {:sym, "steering"},
              info.steering,
              {:sym, "permission"},
              perm,
              {:sym, "question"},
              question
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
        Compos.Core.Agent.permission_deadline(s(slug), trunc(ms))
        :void
      end,
      "set-modeline-extra!" => fn [s] ->
        Editor.set_modeline_extra(modeline_extra(s))
        :void
      end,
      "llm-model" => fn [] -> Compos.Core.LLM.model() end,
      "llm-context-limit" => fn [m] -> Compos.Core.LLMDb.context_limit(to_string(m)) || false end,
      "eval-string" => fn [src], store -> eval_src.(src, store) end,
      # The deferred-reply lane. An eval that hands slow work to a Task
      # claims its caller's reply slot with eval-defer! and answers through
      # eval-resolve! when the Task's callback delivers the value. The
      # caller blocks in its own process; the Session moves on at once.
      "eval-defer!" => fn [] ->
        case Process.get(:eval_reply_to) do
          nil ->
            false

          from ->
            token = make_ref()
            :ets.insert(@escaped, {{:eval_pending, token}, from})
            Process.put(:eval_deferred, token)
            token
        end
      end,
      "eval-resolve!" => fn [token, value] ->
        case :ets.lookup(@escaped, {:eval_pending, token}) do
          [{key, from}] ->
            :ets.delete(@escaped, key)
            GenServer.reply(from, {:ok, Scheme.print(value)})
            :void

          # already resolved, or the caller gave up — nobody to answer
          [] ->
            :void
        end
      end,
      # (with-edit-author AUTHOR THUNK) — every buffer mutation THUNK makes
      # is attributed to AUTHOR (see buffer-authors). The try/after restore
      # is the point: a raising handler must not leave the author stuck on
      # the session, misattributing every later keystroke.
      "with-edit-author" => fn [author, thunk], store ->
        prev = Process.get(:compos_edit_author)

        if author == false,
          do: Process.delete(:compos_edit_author),
          else: Process.put(:compos_edit_author, to_string(author))

        try do
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
        after
          if prev,
            do: Process.put(:compos_edit_author, prev),
            else: Process.delete(:compos_edit_author)
        end
      end,
      "current-edit-author" => fn [] -> Process.get(:compos_edit_author) || false end,
      # Emacs' logical current-buffer binding, deliberately separate from
      # window display. Tool evaluation uses this so visit/switch operations
      # can establish the buffer commands act on without hijacking the user's
      # selected window.
      "with-current-buffer" => fn [buffer, thunk], store ->
        buffer = to_string(buffer)

        unless Compos.Core.Buffer.exists?(buffer) do
          raise Compos.Scheme.Eval.Error, message: "no such buffer: #{buffer}"
        end

        Compos.Core.Frame.with_buffer(buffer, fn ->
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
        end)
      end,
      # The deliberate exit from that binding. Inside the thunk,
      # current-buffer and the switch primitives resolve through the
      # frame's real windows, so a tool that intends a display change can
      # make one and observe it truthfully.
      "with-frame-windows" => fn [thunk], store ->
        Compos.Core.Frame.without_buffer(fn ->
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
        end)
      end,
      # Scheme tasks share global bindings. This narrow lock lets Scheme
      # publish an expensive derived value once after shared source changes.
      # The process identity keeps :global's requester identity distinct.
      "with-scheme-lock" => fn [key, thunk], store ->
        lock = {{__MODULE__, :scheme_lock, key}, self()}

        :global.trans(lock, fn ->
          # A waiting eval can hold shared reads from before the lock. Refresh
          # them so the critical section sees the previous owner's writes.
          Compos.Scheme.Env.forget_cached_reads()
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
        end)
      end,
      # (wait-until PRED &optional TIMEOUT-MS INTERVAL-MS) -> #t | #f
      #
      # Wait for work that is not on this lane: a subprocess handshake, a
      # debounce, a fetch that answers through a callback. Polling beats a
      # fixed sleep — it returns the moment the condition holds, and a
      # sleep long enough to be safe is a sleep long enough to be slow.
      #
      # This BLOCKS its lane, the way mcp-call! does. Lanes are serial and
      # independent, so a wait on the RPC or test lane never delays a
      # keystroke on :ui.
      #
      # It therefore CANNOT wait for work that needs the lane it is holding.
      # lsp.scm delivers its events on :ui, so a wait-until on :ui for an
      # LSP connection to reach "ready" blocks the very transition it waits
      # for and always times out — while the same server polled from
      # outside an eval is ready in two seconds. Waiting for a debounce, a
      # buffer another process writes, or an MCP reply is fine: those
      # complete elsewhere. @wait_cap keeps a bad predicate well inside the
      # 30s Lane timeout, so a runaway wait reports as #f and not as a
      # frozen lane nobody can name.
      "wait-until" => fn args, store ->
        [pred | rest] = args
        timeout = min(wait_arg(rest, 0, 2_000), @wait_cap)
        interval = max(wait_arg(rest, 1, 20), 5)
        deadline = System.monotonic_time(:millisecond) + timeout
        wait_until_loop(pred, deadline, interval, store)
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
        {Compos.Scheme.Env.lookup(store, global, name), store}
      end,
      "set-symbol-value!" => fn [{:sym, name}, val], store ->
        {val, Compos.Scheme.Env.define(store, global, name, val)}
      end,
      "boundp" => fn [{:sym, name}], store ->
        {match?({:ok, _}, Compos.Scheme.Env.fetch(store, global, name)), store}
      end,
      # every globally bound name (builtins + userland defines) — the
      # discovery surface for agents writing eval-scheme code
      "global-names" => fn [], store ->
        {Compos.Scheme.Env.frame_names(store, global) |> Enum.sort(), store}
      end,
      # the doc sweep's surface: apropos scope "all" and describe-function
      # read these instead of showing a bare name. A userland alias of a
      # builtin — (define raw-buffer-create buffer-create) — carries the
      # builtin value, so the lookup follows the value to the real name.
      "primitive-doc" => fn [name], store ->
        n = doc_name(name)

        resolved =
          case Compos.Scheme.Env.fetch(store, global, n) do
            {:ok, {:builtin, builtin_name, _}} -> builtin_name
            _ -> n
          end

        {primitive_docs()[resolved] || primitive_docs()[n] || false, store}
      end,
      "primitive-docs" => fn [] ->
        primitive_docs() |> Enum.sort() |> Enum.map(fn {n, d} -> [n, d] end)
      end,
      # load-library: evaluate a Scheme file in the live session. A relative
      # path resolves against the config home, so init.scm can source
      # (load "providers.scm") without knowing where the daemon was started.
      "load" => fn [path], store ->
        expanded = expand_load_path(path)

        case File.read(expanded) do
          {:ok, src} ->
            eval_src.(src, store)

          {:error, reason} ->
            raise Compos.Scheme.Eval.Error, message: "cannot load #{expanded}: #{reason}"
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
      # Visibility: the rule fires only while BUF is on screen or in the
      # current buffer's group; other changes park and fire once when the
      # buffer comes back into scope. (on-change! BUF FN 'eager) opts out
      # for work whose output leaves the buffer.
      "on-change!" => fn [buf, callback | rest] ->
        {:ok, id} =
          Compos.Core.Reactor.on_change(
            buf,
            :any,
            fn changes -> apply_callback(callback, change_args(changes)) end,
            debounce: 30,
            sources: :all,
            eager: Enum.any?(rest, &match?({:sym, "eager"}, &1))
          )

        # the Reactor holds the callback inside an opaque fun — root it for
        # the GC for as long as the rule lives
        :ets.insert(@escaped, {{:reactor, id}, callback})
        id
      end,
      "remove-on-change!" => fn [id] ->
        Compos.Core.Reactor.remove(id)
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
          Compos.Scheme.Eval.apply_fn(thunk, [], store)
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
            {_, store} = Compos.Scheme.Eval.apply_fn(oc, [], store)
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
              Compos.Core.Candidates.total(mb.list),
              {:sym, "candidates"},
              Enum.map(Compos.Core.Candidates.rows(mb.list), fn c ->
                [{:sym, "label"}, c.label, {:sym, "hint"}, c.hint || ""]
              end)
            ]
        end
      end,
      "minibuffer-input!" => fn [input] ->
        Editor.minibuffer_set_input(s(input))
        :void
      end,
      # Browser prompts do not pass through KeyDispatch, whose normal edit
      # path fires on_change. Keep the store-aware callback here so a dynamic
      # candidate provider behaves identically on both input surfaces.
      "minibuffer-change!" => fn [input], store ->
        input = s(input)
        Editor.minibuffer_set_input(input)

        case Editor.snapshot().minibuffer do
          %{on_change: oc} when oc not in [nil, false] ->
            {_, store} = Compos.Scheme.Eval.apply_fn(oc, [input], store)
            {:void, store}

          _ ->
            {:void, store}
        end
      end,
      # A small, general Scheme-side debounce. The callback stays rooted in
      # @escaped until its timer fires; the generation check makes a cancelled
      # timer harmless even if its message was already in this mailbox.
      "debounce!" => fn [key, ms, callback, arg] ->
        key = {:debounce, s(key)}

        case :ets.lookup(@escaped, key) do
          [{^key, {_generation, timer, _callback, _arg, _fid}}] ->
            Process.cancel_timer(timer)

          _ ->
            :ok
        end

        generation = make_ref()
        # the primitive runs in a lane worker; the timer must land on the
        # Session, whose handle_info routes the callback back into a lane
        timer =
          Process.send_after(
            Process.whereis(__MODULE__),
            {:scheme_debounce, key, generation},
            trunc(ms)
          )

        :ets.insert(@escaped, {key, {generation, timer, callback, arg, Frame.current()}})
        :void
      end,
      "minibuffer-confirm!" => fn [], store ->
        case Editor.minibuffer_close() do
          %{on_confirm: oc} = mb when oc not in [nil, false] ->
            {value, store} = mb_confirm_value(mb, store)
            {_, store} = Compos.Scheme.Eval.apply_fn(oc, [value], store)
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
            {_, store} = Compos.Scheme.Eval.apply_fn(oc, [mb.input], store)
            {:void, store}

          _ ->
            {:void, store}
        end
      end,
      "minibuffer-cancel!" => fn [], store ->
        store =
          case Editor.minibuffer_close() do
            %{on_cancel: oc} when oc not in [nil, false] ->
              {_, store} = Compos.Scheme.Eval.apply_fn(oc, [], store)
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
                Enum.map(Compos.Core.Candidates.filtered(mb.list), fn c ->
                  [c.label, c.hint || ""]
                end)
              ],
              [{:sym, "confirm"}, mb[:on_confirm] || false],
              [{:sym, "cancel"}, mb[:on_cancel] || false],
              [{:sym, "complete"}, mb[:on_complete] || false],
              [{:sym, "collect"}, mb[:on_collect] || false]
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

            case Compos.Scheme.Eval.apply_fn(mb.on_complete, [mb.input, selected], store) do
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

        if (mb && mb.on_complete not in [nil, false]) and trimmed != input and
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
      case Compos.Scheme.Eval.apply_fn(oc, [mb.input, mb[:selected]], store) do
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

  # the modeline extra: one string, or one (class text) pair per segment
  defp modeline_extra(segments) when is_list(segments) do
    for [class, text] <- segments, do: {to_string(class), to_string(text)}
  end

  defp modeline_extra(text), do: to_string(text)

  defp s({:sym, str}), do: str
  defp s(str) when is_binary(str), do: str

  defp raise_scheme(msg), do: raise(Compos.Scheme.Eval.Error, message: msg)

  defp actor_call(actor, message, timeout) do
    case SchemeActor.call(actor, message, timeout) do
      {:ok, reply} -> reply
      {:error, reason} -> raise_scheme("actor-call: #{reason}")
    end
  end

  defp scheme_task_await(task, timeout) do
    case SchemeTask.await(task, timeout) do
      {:ok, value} -> value
      {:error, reason} -> raise_scheme("task-await: #{reason}")
    end
  end

  defp scheme_task_run(closure, callback, timeout) do
    case SchemeTask.start(closure) do
      {:ok, task} ->
        key = {:scheme_task_callback, task.id}
        :ets.insert(@escaped, {key, callback})
        fid = Frame.current()
        lane = Lane.current() || :ui

        case Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
               result = SchemeTask.await(task, timeout)

               args =
                 case result do
                   {:ok, value} -> [true, value]
                   {:error, reason} -> [false, reason]
                 end

               try do
                 apply_callback(callback, args, fid, lane)
               after
                 :ets.delete(@escaped, key)
                 SchemeTask.cancel(task)
               end
             end) do
          {:ok, _pid} ->
            task

          {:error, reason} ->
            :ets.delete(@escaped, key)
            SchemeTask.cancel(task)
            raise_scheme("task-run!: #{inspect(reason)}")
        end

      {:error, reason} ->
        raise_scheme("task-run!: #{reason}")
    end
  end

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

  # false is the only false value in this dialect: nil, '() and 0 are all
  # true, so the test is exactly `!= false` and never Elixir truthiness.
  defp wait_until_loop(pred, deadline, interval, store) do
    {value, store} = Compos.Scheme.Eval.apply_fn(pred, [], store)

    cond do
      value != false ->
        {true, store}

      System.monotonic_time(:millisecond) >= deadline ->
        {false, store}

      true ->
        Process.sleep(interval)
        # reads of shared frames are cached per process and cleared once
        # per exec. Polling happens INSIDE one exec, so without this the
        # predicate re-reads its own first answer until the deadline.
        Compos.Scheme.Env.forget_cached_reads()
        wait_until_loop(pred, deadline, interval, store)
    end
  end

  defp wait_arg(rest, index, default) do
    case Enum.at(rest, index) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  # the task owns the timeout, not the connection: Conn gives a tool call
  # two minutes, and the session cannot wait that long for anything
  defp mcp_wait_call(server, tool, args, timeout) do
    task =
      Task.Supervisor.async_nolink(Compos.Core.TaskSupervisor, fn ->
        Compos.Core.MCP.call_when_ready(server, tool, args, timeout)
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
  # spec plist -> the map LSP.Conn reads: env becomes a map; settings and
  # init-options become JSON-ready values (they cross the wire verbatim)
  defp lsp_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {"env", v} when is_list(v) ->
        {"env", v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), b} end)}

      {"settings", v} ->
        {"settings", Compos.Core.Plist.to_json(v)}

      {"init-options", v} ->
        {"init_options", Compos.Core.Plist.to_json(v)}

      kv ->
        kv
    end)
  end

  defp lsp_conn!(id) do
    with {name, root} <- Compos.Core.LSP.parse_id(s(id)),
         pid when pid != nil <- Compos.Core.LSP.whereis(name, root) do
      {pid, {name, root}}
    else
      _ -> raise_scheme("lsp: no connection #{s(id)}")
    end
  end

  # A GC-rooted result callback. It fires from the conn process, so the
  # Scheme apply always moves to a task. The apply runs on the :ui lane
  # on purpose: the exec that created the callback runs there too, and
  # lane order guarantees its frames flush before the callback needs
  # them — a fast server on another lane would apply a closure whose
  # environment is not published yet.
  defp lsp_cb(callback, _key) do
    refkey = {:lsp_call, make_ref()}
    :ets.insert(@escaped, {refkey, callback})

    fn result ->
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        try do
          apply_callback(callback, lsp_callback_args(result))
        after
          :ets.delete(@escaped, refkey)
        end
      end)
    end
  end

  defp lsp_callback_args({:ok, result}), do: [true, Compos.Core.LLM.json_to_scheme(result)]
  defp lsp_callback_args({:error, msg}), do: [false, to_string(msg)]

  # Scheme values -> bound query parameters. A parameter is never spliced
  # into SQL text, so a string stays a string whatever it contains.
  defp db_params(list) when is_list(list), do: Enum.map(list, &db_param/1)
  defp db_params(_), do: []

  defp db_param({:sym, "null"}), do: nil
  defp db_param(false), do: false
  defp db_param(true), do: true
  defp db_param({:sym, other}), do: other
  defp db_param(v), do: v

  # A decoded row value -> a Scheme term. SQL NULL becomes #f, the same
  # answer json-parse gives, and a numeric becomes text so no precision is
  # lost on the way through a float.
  defp db_value(nil), do: false
  defp db_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp db_value(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp db_value(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp db_value(%Date{} = d), do: Date.to_iso8601(d)
  defp db_value(%Time{} = t), do: Time.to_iso8601(t)
  defp db_value(v) when is_list(v), do: Enum.map(v, &db_value/1)
  defp db_value(v) when is_map(v) and not is_struct(v), do: Compos.Core.LLM.json_to_scheme(v)
  defp db_value(v) when is_struct(v), do: inspect(v)
  defp db_value(v), do: v

  defp db_cb(callback) do
    refkey = {:db_call, make_ref()}
    :ets.insert(@escaped, {refkey, callback})

    fn result ->
      try do
        apply_callback(callback, db_callback_args(result))
      after
        :ets.delete(@escaped, refkey)
      end
    end
  end

  defp db_query_sync(name, sql, params) do
    case Compos.Core.DB.query(name, sql, params) do
      {:ok, result} ->
        db_result(result)

      {:error, msg} ->
        raise_scheme("db-query: #{msg}")
    end
  end

  defp db_result(result) do
    [true, value] = db_callback_args({:ok, result})
    value
  end

  defp db_target(%Compos.Core.DB.Transaction{} = transaction), do: transaction
  defp db_target(name), do: s(name)

  defp db_callback_args({:ok, r}) do
    [
      true,
      [
        {:sym, "columns"},
        r.columns,
        {:sym, "rows"},
        Enum.map(r.rows, fn row -> Enum.map(row, &db_value/1) end),
        {:sym, "count"},
        r.num_rows,
        {:sym, "command"},
        r.command
      ]
    ]
  end

  defp db_callback_args({:error, msg}), do: [false, to_string(msg)]

  # endpoint spec plist -> the map Endpoint.Conn reads. 'env is itself a
  # plist; 'args is a list of strings; everything else crosses verbatim.
  defp endpoint_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {"env", v} when is_list(v) ->
        {"env",
         v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), to_string(b)} end)}

      {"args", v} when is_list(v) ->
        {"args", Enum.map(v, &to_string/1)}

      {k, v} ->
        {k, v}
    end)
  end

  defp endpoint_conn!(name) do
    case Compos.Core.Endpoint.whereis(s(name)) do
      nil -> raise_scheme("endpoint: no connection #{s(name)}")
      pid -> pid
    end
  end

  defp endpoint_ask(name, text, until, timeout, callback) do
    pid = endpoint_conn!(name)
    sentinel = if until == false, do: nil, else: s(until)
    ms = if is_integer(timeout) and timeout > 0, do: timeout, else: nil
    Compos.Core.Endpoint.Conn.ask(pid, s(text), sentinel, ms, endpoint_cb(callback))
    :void
  end

  # A GC-rooted result callback, same shape as lsp_cb/2: it fires from the
  # conn process, so the Scheme apply always moves to a task.
  defp endpoint_cb(callback) do
    refkey = {:endpoint_call, make_ref()}
    :ets.insert(@escaped, {refkey, callback})

    fn result ->
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        try do
          apply_callback(callback, endpoint_callback_args(result))
        after
          :ets.delete(@escaped, refkey)
        end
      end)
    end
  end

  defp endpoint_callback_args({:ok, frames}), do: [true, frames]
  defp endpoint_callback_args({:error, msg}), do: [false, to_string(msg)]

  defp web_server_detail(detail) do
    [
      {:sym, "name"},
      detail.name,
      {:sym, "host"},
      detail.host,
      {:sym, "port"},
      detail.port,
      {:sym, "url"},
      detail.url,
      {:sym, "max-body"},
      detail.max_body
    ]
  end

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
  defp browser_args(args), do: Compos.Core.Plist.to_json(args, :null)

  # the interpreter waits here, so the ceiling is 5s and the default 2s: a page
  # that is slower than that is a page the caller should ask about again
  defp browser_wait_ms(ms) when is_integer(ms) and ms > 0, do: min(ms, 5_000)
  defp browser_wait_ms(_), do: 2_000

  defp browser_reply({:ok, result}) when is_map(result),
    do: [{:sym, "ok"}, true | Compos.Core.LLM.json_to_scheme(result)]

  defp browser_reply({:ok, _}), do: [{:sym, "ok"}, true]
  defp browser_reply({:error, msg}), do: [{:sym, "ok"}, false, {:sym, "error"}, msg]

  @doc """
  The inverse of `Compos.Core.LLM.json_to_scheme/1`, for values headed out to
  JSON. The convention lives in `Compos.Core.Plist`, because three places
  had three slightly different ideas of what counted as a plist.
  """
  defdelegate scheme_to_json(value), to: Compos.Core.Plist, as: :to_json

  defp usage_to_plist(usage) do
    t = Compos.Core.LLMDb.tokens(usage)

    [
      {:sym, "input"},
      t.input,
      {:sym, "output"},
      t.output,
      {:sym, "cache-read"},
      t.cache_read,
      {:sym, "cache-write"},
      t.cache_write,
      {:sym, "cost"},
      usage["cost"] || false
    ]
  end
end
