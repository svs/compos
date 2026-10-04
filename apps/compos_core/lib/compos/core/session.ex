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

  alias Compos.Core.{Buffer, Editor, Frame, Hotload, Lane, SchemeTask}
  alias Compos.Scheme
  import Compos.Core.Prims
  alias Compos.Scheme.Prim

  @messages "*Messages*"
  @messages_table :compos_messages
  @messages_limit 2_000

  alias Compos.Core.Roots

  # how many times apply_reply_callback re-applies a closure whose frame is
  # still stale; past this the reply is dropped and reported once
  @stale_frame_retries 10

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
  @primitive_modules [
    Compos.Core.SchemeAPI,
    Compos.Scheme.Builtins,
    __MODULE__,
    Compos.Core.Browser.Prims,
    Compos.Core.MCP.Prims,
    Compos.Core.LSP.Prims,
    Compos.Core.DB.Prims,
    Compos.Core.Endpoint.Prims,
    Compos.Core.WebServer.Prims,
    Compos.Core.Conn.Prims,
    Compos.Core.LLMSession.Prims
  ]
  @pt_stamp {__MODULE__, :primitive_stamp}
  # the merged doc map, derived once per primitive generation: the entries
  # build closures, and apropos asks for a doc per global name
  @pt_docs {__MODULE__, :primitive_docs}

  # The files that failed to load at boot. A boot error has to outlive the
  # init that made it: there is no editor to report it to until the
  # interpreter is published.
  @pt_boot_errors {__MODULE__, :boot_errors}

  # how long a waiting mcp-call! waits. The RPC layer gives an eval 30s, so
  # the call must give up first and say so.

  # the longest a (wait-until) may hold its lane. Lane.run gives an eval
  # 30s, so a runaway predicate must give up first and answer #f.
  @wait_cap 10_000

  @bootstrap_files ~w(editor.scm themes.scm init.scm)

  # user config, in load order: saved customizations load last so they win
  @user_config_files ~w(ai-config.scm init.scm custom.scm)

  @doc "The bootstrap files, in load order."
  def bootstrap_files, do: @bootstrap_files

  @doc "The user config files, in load order."
  def user_config_files, do: @user_config_files

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

    try do
      Lane.run(lane || :ui, fn from -> exec_eval(src, fid, from) end, timeout, eval_label(src))
    catch
      :exit, {:timeout, _} = reason ->
        Logger.warning("timed out Scheme eval; full source follows:\n#{src}")
        exit(reason)
    end
  end

  @doc "The live interpreter handle (constant after init)."
  def interp do
    :persistent_term.get(@pt)
  rescue
    # boot: the stdlib is still loading. A call queues behind init — the
    # same wait every caller used to get from the Session mailbox.
    ArgumentError ->
      # ...unless this IS the Session, loading. A call then goes to this
      # process from this process, and the VM answers "process attempted to
      # call itself" — an exit with no file name in it, which took down the
      # whole application. Exit with a reason the load path recognises
      # instead, so the boot names the file and carries on without it.
      if self() == Process.whereis(__MODULE__) do
        exit({:calling_self, {__MODULE__, :interp, []}})
      else
        GenServer.call(__MODULE__, :await_boot, 60_000)
      end
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

  @doc """
  Apply a Scheme closure (e.g. a minibuffer confirm callback). BUFFER, when
  given, is the logical current buffer to restore for the call — a task's
  callback runs in a fresh process, so without it the call would pick up
  whatever buffer the caller's frame happens to be showing by then.
  """
  def apply_callback(closure, args, fid \\ nil, lane \\ nil, buffer \\ nil) do
    fid = fid(fid)

    Lane.run(
      lane || :ui,
      fn _from -> exec_apply(closure, args, fid, buffer) end,
      30_000,
      apply_label(closure)
    )
  end

  # the slow-job log names the callback by the head of its body, so a slow
  # "apply" says which hook ran, not only that one did
  defp apply_label({:closure, _params, body, _env}) do
    "apply " <> (body |> Compos.Scheme.Printer.print() |> String.slice(0, 80))
  rescue
    _ -> "apply"
  end

  defp apply_label(_), do: "apply"

  @doc """
  Apply a closure that has been waiting on a reply from outside the editor.

  Closure frames are now published before exposure. Keep the bounded stale-ref
  retry as defense for persisted references from an older or faulty root set:
  dropping an out-of-editor reply loses it outright. Backend.call_context uses
  the same defensive retry. Ordinary callbacks still fail fast.
  """
  def apply_reply_callback(
        closure,
        args,
        fid \\ nil,
        lane \\ nil,
        retries \\ @stale_frame_retries
      ) do
    result = apply_callback(closure, args, fid, lane)

    case result do
      {:error, msg} when retries > 0 ->
        if stale_frame?(msg) do
          Process.sleep(20)
          apply_reply_callback(closure, args, fid, lane, retries - 1)
        else
          result
        end

      # retries exhausted: exec_apply stayed quiet for every attempt, so the
      # lost reply would otherwise leave no trace at all. Say it once.
      {:error, msg} ->
        if stale_frame?(msg) do
          message("error: #{msg} (reply dropped after #{@stale_frame_retries} retries)")
        end

        result

      _ ->
        result
    end
  end

  defp stale_frame?(msg), do: is_binary(msg) and msg =~ "stale environment frame"

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
    # A published handle means a previous incarnation died. Unpublish it
    # FIRST, before anything else in this init can take time: every caller
    # then queues on :await_boot, which is exactly what it does at a cold
    # boot, instead of evaluating against a world that is being replaced.
    # Left published, that world answers for the ~2.5s this load takes, and
    # every define, set! and buffer local it writes dies with the inherited
    # environment table 30 seconds later. The registry tables below are
    # already empty by then too, so an M-x during the window finds no
    # command at all.
    restart? = :persistent_term.get(@pt, nil) != nil
    # this boot's errors, not the last one's
    :persistent_term.erase(@pt_boot_errors)

    if restart? do
      :persistent_term.erase(@pt)
      :persistent_term.erase(@pt_stamp)

      Logger.error(
        "scheme: the Session is restarting. Its interpreter is unpublished until " <>
          "this load ends, so no caller runs against the dead one."
      )
    end

    # The tables belong to Compos.Core.SchemeTables, which runs no Scheme and
    # so cannot die of it. Empty them rather than create them: their identity
    # then survives a crash here, and no lane worker holding the published
    # handle ever reads a dead table id.
    Enum.each(Compos.Core.SchemeTables.reset_tables(), &Compos.Core.SchemeTables.reset/1)
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

    # This process alone evaluates until the interp is published below, so
    # the load runs with promotion off: with the global frame still in the
    # local tier, every promotion re-walked every global binding.
    t0 = System.monotonic_time(:millisecond)

    interp =
      Compos.Scheme.Env.unpublished(fn ->
        interp = Scheme.new(primitives: Compos.Core.SchemeAPI.primitives())
        # this process created the environment table, so a crash here would
        # destroy it; hand it to the table owner instead
        Compos.Core.SchemeTables.adopt(interp.store.tid)
        interp = Scheme.register(interp, Prim.funs(session_primitives(interp.global)))
        load_stdlib!(interp)
      end)

    # Loading leaves millions of dead frames behind. Publish only the
    # frames a root or the global frame can reach and drop the rest in one
    # pass: a sweep that snapshotted every dead frame first took seconds.
    # The doubling threshold then starts from a live baseline.
    loaded = Scheme.frame_count(interp)
    interp = Scheme.flush(interp, external_roots())

    Logger.info(
      "scheme boot: #{loaded} frames loaded, #{Scheme.frame_count(interp)} kept, " <>
        "#{System.monotonic_time(:millisecond) - t0}ms"
    )

    :persistent_term.put(@pt, interp)
    :persistent_term.put(@pt_stamp, primitive_stamp())
    :persistent_term.erase(@pt_docs)
    Process.send_after(self(), :gc_tick, @gc_interval)

    # A restart is a boot of the Scheme world, so the Scheme world's durable
    # state has to come back the way a boot brings it back. Compos.Core.Desktop
    # holds it and does the work; it is told here as well as by its own
    # monitor, so a Desktop that restarted at the same moment still hears.
    if restart?, do: send(Process.whereis(Compos.Core.Desktop) || self(), :scheme_rebooted)

    # The editor is up, so the files that did not load can say so where the
    # user reads them. *Messages* is this session's log and it is already
    # created above.
    report_boot_errors!()

    {:ok,
     %{
       last_live: Scheme.frame_count(interp),
       reload_manifest: Hotload.Scheme.manifest()
     }}
  end

  # Report the boot errors as *Messages* rows, one per file. message/3
  # writes an ETS row and echoes; it runs no Scheme, so the report never
  # depends on the part of the world that failed to load.
  defp report_boot_errors!() do
    Enum.each(boot_errors(), fn {file, msg} ->
      message("#{file} did not load: #{msg}", "error", source: "boot")
    end)
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

  # same, plus a logical buffer to restore around the call — the callback of
  # a task-run! runs in a fresh process, so this is how it gets back the
  # buffer its task body was running as (see scheme_task_run/3).
  defp with_fid(nil, buffer, fun) do
    Frame.clear()
    if buffer, do: Frame.with_buffer(buffer, fun), else: fun.()
  end

  defp with_fid(fid, buffer, fun) do
    Frame.with_frame(fid, fn ->
      if buffer, do: Frame.with_buffer(buffer, fun), else: fun.()
    end)
  end

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
        Roots.drop({:eval_pending, token})
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
  def exec_apply(closure, args, fid, buffer \\ nil) do
    case Scheme.exec(interp(), fn interp ->
           safe(fn -> with_fid(fid, buffer, fn -> Scheme.call(interp, closure, args) end) end)
         end) do
      {:ok, val, _interp} ->
        root_result(val)
        {:reply, :ok}

      {:error, msg} ->
        # a stale frame is the transient apply_reply_callback retries away.
        # Reporting each attempt put up to ten identical lines in *Messages*
        # for one reply that then succeeded; the exhausted case reports there.
        unless stale_frame?(msg), do: message("error: " <> msg)
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
    idx = :ets.update_counter(Roots.table(), :recent_idx, {2, 1, 31, 0}, {:recent_idx, -1})
    Roots.put({:recent, idx}, val)
    :ok
  end

  defp root_result(_val), do: :ok

  @impl true
  def handle_call(:await_boot, _from, state) do
    {:reply, :persistent_term.get(@pt), state}
  end

  def handle_call(:refresh_primitives, _from, state) do
    # A page load can ask for this while Hotload's swap has the primitive
    # module unloaded for a moment. A raise here kills Session, and the
    # core supervisor gives up (2026-09-05: "module Compos.Core.SchemeAPI is
    # not available" took the daemon down). Refuse instead; Hotload rebinds
    # again when its swap completes.
    if Code.ensure_loaded?(Compos.Core.SchemeAPI) and
         function_exported?(Compos.Core.SchemeAPI, :primitives, 0) do
      interp = interp()

      # Session's own primitives must go through the SAME rebind. A register
      # after the rebind fixes two things badly. An alias holds a
      # `{:builtin, "define-command", fun}` tuple that only the rebind walk
      # reaches, so `define-command--raw` in editor.scm keeps the purged fun.
      # A register also puts the raw primitive back over the Scheme wrapper
      # that editor.scm defines for the same name.
      extra =
        Map.merge(
          Compos.Core.SchemeAPI.primitives(),
          Prim.funs(session_primitives(interp.global))
        )

      interp = Scheme.rebind_primitives(interp, extra)
      :persistent_term.put(@pt, interp)
      :persistent_term.put(@pt_stamp, primitive_stamp())
      :persistent_term.erase(@pt_docs)
      {:reply, :ok, state}
    else
      {:reply, {:error, :primitives_not_loaded}, state}
    end
  end

  def handle_call({:reload_files, paths}, _from, state) do
    # A dev code reload keeps the existing GenServer state. Seed the new
    # manifest lazily so adding this mechanism does not require a restart.
    manifest = Map.get(state, :reload_manifest) || Hotload.Scheme.manifest()

    with {:ok, files} <- Hotload.Scheme.changes(paths, manifest),
         {:ok, _, _interp} <- Hotload.Scheme.eval(files) do
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
    case Roots.get(key) do
      {^generation, _timer, _callback, _arg, _fid} ->
        # Keep the generation rooted while waiting for the UI lane. A new
        # keystroke may cancel/replace it after the timer fires but before
        # the lane is free to run this callback.
        Lane.cast(:ui, fn _from -> exec_debounce(key, generation) end, "debounce")

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

  defp exec_debounce(key, generation) do
    case Roots.get(key) do
      {^generation, _timer, callback, arg, fid} ->
        # Delete only this generation; concurrent rescheduling must survive.
        case :ets.select_delete(Roots.table(), [{{key, {generation, :_, :_, :_, :_}}, [], [true]}]) do
          1 -> exec_apply(callback, [arg], fid)
          0 -> {:reply, :ok}
        end

      _ ->
        {:reply, :ok}
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
      :ets.tab2list(Compos.Core.SchemeAPI.commands_table()),
      Roots.all(),
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
          # one file is one package here too
          interp = Hotload.Scheme.stamp_load_unit(interp, path, :bundled)

          # A file that does not load is a file that is not loaded. It is
          # never a daemon that does not start. This used to raise, which
          # failed Session.init, which failed the supervisor, which stopped
          # the application: one bad form in one bundled file and there was
          # no editor to read the error in. Emacs boots and shows you the
          # error, and so does this. record_boot_error!/2 keeps it for the
          # *Messages* buffer, and the editor comes up without that file.
          case safe_eval_string(interp, File.read!(path), file) do
            {:ok, _, interp} ->
              interp

            {:error, msg} ->
              record_boot_error!(file, msg)
              interp
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
    Enum.reduce(@user_config_files, interp, fn file, interp ->
      path = Path.join(Compos.Core.config_dir(), file)

      with true <- File.exists?(path),
           {:ok, _, interp2} <- safe_eval_string(interp, File.read!(path), file) do
        interp2
      else
        false ->
          interp

        {:error, msg} ->
          record_boot_error!(file, msg)
          interp
      end
    end)
  end

  # Scheme.eval_string answers {:error, msg} for a Scheme error. A
  # primitive that raises, exits or throws answers with nothing at all: it
  # unwinds the whole load. One boot-time example is a primitive that asks
  # for the interpreter handle, which is unpublished until this load ends,
  # so the ask becomes a GenServer.call from this process to itself. Turn
  # every one of those into the same {:error, msg} the reader produces, so
  # one bad file costs that file and nothing more.
  defp safe_eval_string(interp, source, file) do
    Scheme.eval_string(interp, source)
  rescue
    error -> {:error, "#{file}: #{Exception.message(error)}"}
  catch
    :exit, {:calling_self, _} ->
      {:error,
       "#{file}: a form called the interpreter while it was still loading. " <>
         "Boot-time code may not ask for the published interpreter."}

    :exit, reason ->
      {:error, "#{file}: exited: #{inspect(reason)}"}

    kind, value ->
      {:error, "#{file}: #{kind}: #{inspect(value)}"}
  end

  # One package of the boot manifest. The store the loaded file wrote is
  # kept even when a later form in it failed: the definitions that did
  # evaluate are real, and dropping them would take working packages down
  # with the broken one.
  defp boot_load(eval_src, src, store, file) do
    eval_src.(src, store)
  rescue
    error ->
      record_boot_error!(file, Exception.message(error))
      {:void, store}
  catch
    :exit, {:calling_self, _} ->
      record_boot_error!(
        file,
        "a form called the interpreter while it was still loading. " <>
          "Boot-time code may not ask for the published interpreter."
      )

      {:void, store}

    kind, value ->
      record_boot_error!(file, "#{kind}: #{inspect(value)}")
      {:void, store}
  end

  # The boot errors, oldest first. They are collected during init, before
  # there is an editor to show them in, and written to *Messages* once the
  # interpreter is published.
  defp record_boot_error!(file, msg) do
    Logger.error("scheme: #{file} did not load: #{msg}")
    :persistent_term.put(@pt_boot_errors, boot_errors() ++ [{file, msg}])
  end

  @doc "The files that did not load at boot, with the reason for each."
  def boot_errors, do: :persistent_term.get(@pt_boot_errors, [])

  defp stamp_origin_user(interp) do
    case Scheme.eval_string(interp, "(origin! 'user)") do
      {:ok, _, interp2} -> interp2
      {:error, _} -> interp
    end
  end

  # one merged map: the three registration modules' docs
  defp primitive_docs do
    :persistent_term.get(@pt_docs, nil) ||
      (
        docs =
          Compos.Scheme.Builtins.docs()
          |> Map.merge(Compos.Core.SchemeAPI.docs())
          |> Map.merge(docs())

        :persistent_term.put(@pt_docs, docs)
        docs
      )
  end

  defp doc_name({:sym, n}), do: n
  defp doc_name(n) when is_binary(n), do: n

  @doc """
  One-line doc string for every primitive that `session_primitives/1`
  registers. Format: a call signature, then " — ", then one sentence.
  """
  def docs, do: Prim.docs(session_primitives(nil))

  defp session_primitives(global) do
    eval_src = fn src, store ->
      Enum.reduce(Compos.Scheme.Reader.read_all(src), {:void, store}, fn form, {_v, store} ->
        Compos.Scheme.Eval.eval(form, global, store)
      end)
    end

    %{
      {"message", "(message TEXT [LEVEL]) — log TEXT and show it in the echo area."} => fn
        [text] ->
          message(to_string(text))
          :void

        [text, level] ->
          message(to_string(text), level)
          :void
      end,
      {"message-emit",
       "(message-emit TEXT LEVEL SOURCE GROUP PROJECT) — record one structured editor message."} =>
        fn [text, level, source, group, project] ->
          message(to_string(text), level,
            source: to_string(source),
            group: to_string(group),
            project: to_string(project)
          )

          :void
        end,
      {"messages-snapshot",
       "(messages-snapshot [LIMIT]) — return recent structured editor messages, oldest first."} =>
        fn
          [] -> message_rows(@messages_limit)
          [limit] -> message_rows(trunc(limit))
        end,
      {"messages-clear!", "(messages-clear!) — discard every editor message."} => fn [] ->
        clear_messages()
        :void
      end,
      {"task-spawn",
       "(task-spawn THUNK) — run a zero-argument Scheme closure concurrently over the shared editor world."} =>
        fn [closure] ->
          case SchemeTask.start(closure) do
            {:ok, ref} -> ref
            {:error, reason} -> raise_scheme("task-spawn: #{reason}")
          end
        end,
      {"task-run!",
       "(task-run! THUNK CALLBACK [MS]) — run THUNK concurrently; later call CALLBACK with OK? and its value or error."} =>
        fn
          [closure, callback] -> scheme_task_run(closure, callback, 300_000)
          [closure, callback, timeout] -> scheme_task_run(closure, callback, trunc(timeout))
        end,
      {"task-await",
       "(task-await TASK [MS]) — wait for a Scheme task and return its value, or raise its error."} =>
        fn
          [task] -> scheme_task_await(task, 30_000)
          [task, timeout] -> scheme_task_await(task, trunc(timeout))
        end,
      {"task-alive?", "(task-alive? TASK) — return #t while TASK remains available."} => fn [task] ->
        SchemeTask.alive?(task)
      end,
      {"task-cancel!", "(task-cancel! TASK) — stop a Scheme task."} => fn [task] ->
        :ok = SchemeTask.cancel(task)
        true
      end,
      {"define-command",
       "(define-command NAME [DOC] FN) — register an M-x command; DOC shows in M-x."} => fn
        [name, closure] ->
          :ets.insert(Compos.Core.SchemeAPI.commands_table(), {command_name(name), closure, ""})
          :void

        [name, doc, closure] when is_binary(doc) ->
          :ets.insert(Compos.Core.SchemeAPI.commands_table(), {command_name(name), closure, doc})
          :void
      end,
      {"undefine-command", "(undefine-command NAME) — remove an M-x command from the registry."} =>
        fn [name] ->
          :ets.delete(Compos.Core.SchemeAPI.commands_table(), command_name(name))
          true
        end,
      {"command-names", "(command-names) — return every M-x command name."} => fn [] ->
        command_names()
      end,
      # ((KEYS COMMAND) ...) for every global binding
      {"command-fn", "(command-fn NAME) — return the command's closure, or #f."} => fn [name] ->
        case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> false
          [{_, closure, _}] -> closure
        end
      end,
      {"command-doc",
       "(command-doc NAME) — return the command's doc string; empty when it has none."} => fn [
                                                                                                name
                                                                                              ] ->
        case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
          [] -> ""
          [{_, _, doc}] -> doc
        end
      end,
      {"run-command", "(run-command NAME) — run the named command; error when it is undefined."} =>
        fn [name], store ->
          case :ets.lookup(Compos.Core.SchemeAPI.commands_table(), command_name(name)) do
            [] ->
              raise Compos.Scheme.Eval.Error, message: "undefined command: #{command_name(name)}"

            [{_, closure, _}] ->
              Compos.Scheme.Eval.apply_fn(closure, [], store)
          end
        end,
      {"llm", "(llm PROMPT CALLBACK) — start an async completion; CALLBACK gets the reply text."} =>
        fn [prompt, callback] ->
          # the callback vanishes into an opaque fun until the reply arrives —
          # root it for the GC, and unroot once it has fired
          key = {:llm, make_ref()}
          Roots.put(key, callback)

          Compos.Core.LLM.complete(prompt, fn text ->
            try do
              apply_reply_callback(callback, [text])
            after
              Roots.drop(key)
            end
          end)

          :void
        end,
      {"llm-with-model",
       "(llm-with-model PROMPT MODEL CALLBACK [ON-ERROR]) — async completion on MODEL; CALLBACK gets the reply text, ON-ERROR the error text."} =>
        fn [prompt, model, callback | rest] ->
          key = {:llm, make_ref()}
          Roots.put(key, {callback, rest})

          on_error =
            case rest do
              [fail | _] when fail != false ->
                fn msg ->
                  try do
                    apply_reply_callback(fail, [to_string(msg)])
                  after
                    Roots.drop(key)
                  end
                end

              _ ->
                fn msg ->
                  Roots.drop(key)
                  __MODULE__.message("llm error: #{msg}")
                end
            end

          Compos.Core.LLM.complete(
            prompt,
            to_string(model),
            fn text ->
              try do
                apply_reply_callback(callback, [text])
              after
                Roots.drop(key)
              end
            end,
            on_error
          )

          :void
        end,
      # gptel-style native tool use: specs/dispatcher come from the Scheme
      # registry (packages/tools.scm) — the loop lives in LLM.complete_tools.
      # An optional sixth arg is a usage callback: it gets a plist of summed
      # token counts + cost before the text callback fires.  A seventh arg
      # pins the model for buffer-local callers such as llm-mode.
      {"llm-tools",
       "(llm-tools PROMPT SYSTEM SPECS DISPATCHER CB [USAGE-CB]) — async tool loop; CB gets text."} =>
        fn [prompt, system, specs, dispatcher, callback | rest] ->
          usage_cb = List.first(rest)
          requested_model = Enum.at(rest, 1)
          key = {:llm_tools, make_ref()}
          Roots.put(key, [dispatcher, callback, usage_cb])

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
                Roots.drop(key)
              end
            end,
            on_usage: on_usage,
            model: requested_model && to_string(requested_model)
          )

          :void
        end,

      # --- runtime tree-sitter grammars (Compos.Core.TreeSitter) --------------
      {"ts-install-grammar!",
       "(ts-install-grammar! NAME URL) — install a tree-sitter grammar in the background."} =>
        fn [name, url] ->
          n = s(name)
          u = s(url)

          Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
            case Compos.Core.TreeSitter.install(n, u) do
              "ok" ->
                message("grammar #{n} installed — buffers pick it up on their next mode set")

              err ->
                message("grammar #{n}: #{err}")
            end
          end)

          :void
        end,
      {"ts-installed-grammars",
       "(ts-installed-grammars) — return the installed tree-sitter grammar names."} => fn [] ->
        Compos.Core.TreeSitter.installed()
      end,
      {"format-usd", "(format-usd AMOUNT) — return AMOUNT as a dollar string with 4 decimals."} =>
        fn [amount] when is_number(amount) ->
          "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 4)
        end,
      {"llm-cost-report",
       "(llm-cost-report) — return one usage plist per day and model, with cost."} => fn [] ->
        for row <- Compos.Core.LLMUsage.report() do
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
            case Compos.Core.LLMUsage.hit_rate(row) do
              nil -> false
              r -> round(r * 100)
            end,
            {:sym, "cost"},
            row.cost * 1.0
          ]
        end
      end,
      {"set-llm-model!", "(set-llm-model! MODEL) — set the active LLM model."} => fn [m] ->
        Compos.Core.LLM.set_model(m)
        :void
      end,
      # how long the provider holds a cached prefix ("5m", "1h") — the
      # defcustom llm-cache-ttl sets it
      {"set-llm-cache-ttl!",
       "(set-llm-cache-ttl! TTL) — set how long the provider holds a cached prefix."} => fn [ttl] ->
        Compos.Core.LLM.set_cache_ttl(to_string(ttl))
        :void
      end,
      # what a backend can do, by its resolved 'backend name — Scheme asks
      # this instead of asking which connector it is looking at
      {"backend-capabilities",
       "(backend-capabilities NAME) — return the backend's capability symbols."} => fn [name] ->
        Enum.map(Compos.Core.Agent.Backend.capabilities_of(s(name)), &{:sym, to_string(&1)})
      end,
      {"llm-max-tokens",
       "(llm-max-tokens MODEL) — return the model's maximum output tokens, or #f."} => fn [model] ->
        Compos.Core.ModelCatalog.max_tokens(s(model)) || false
      end,
      {"llm-model-reasoning",
       "(llm-model-reasoning MODEL) — return normalized reasoning controls from the shared model catalog, or #f."} =>
        fn [model] ->
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
      {"llm-available-models",
       "(llm-available-models) — return ReqLLM's credential-aware chat model inventory."} =>
        fn [], store ->
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

      # --- agent threads (ACP runtime, see Compos.Core.Agent) -----------------
      # config/info/events cross the boundary as flat plists: (key val ...)
      # with symbol keys — this Scheme has no dotted pairs.
      {"agent-start!", "(agent-start! SLUG CONFIG) — start an agent thread from a config plist."} =>
        fn [slug, config] ->
          case Compos.Core.LLMSession.open(to_string(slug), plist_to_map(config)) do
            {:ok, _pid} -> to_string(slug)
            {:error, {:already_started, _}} -> raise_scheme("agent already running: #{s(slug)}")
            {:error, reason} -> raise_scheme("agent-start!: #{inspect(reason)}")
          end
        end,
      # optional third arg: the display text (what the transcript shows and
      # records as the user turn) when the wire text carries seed context
      {"agent-prompt!",
       "(agent-prompt! SLUG TEXT [DISPLAY]) — send a prompt; return 'sent or 'queued."} => fn [
                                                                                                slug,
                                                                                                text
                                                                                                | rest
                                                                                              ] ->
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
      {"agent-steer!",
       "(agent-steer! SLUG) — send the oldest queued message into the running turn; return #t when sent."} =>
        fn [slug] ->
          case Compos.Core.LLMSession.steer_next(s(slug)) do
            :sent -> true
            {:error, _reason} -> false
          end
        end,
      {"agent-dequeue!",
       "(agent-dequeue! SLUG TEXT) — remove one queued prompt whose text is TEXT; return #t or #f."} =>
        fn [slug, text] ->
          case Compos.Core.LLMSession.dequeue(s(slug), to_string(text)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      {"agent-permission-respond!",
       "(agent-permission-respond! SLUG RPC-ID OPTION-ID) — answer a pending permission request."} =>
        fn [slug, rpc_id, option_id] ->
          option = if option_id in [false, :void], do: nil, else: s(option_id)

          case Compos.Core.Agent.respond_permission(s(slug), rpc_id, option) do
            :ok -> :void
            {:error, r} -> raise_scheme("agent-permission-respond!: #{inspect(r)}")
          end
        end,
      # WE ask, on our own lane. The proxy gate reaches a verdict of ask
      # and has no backend rpc to ride, so it raises the SAME card the ACP
      # lane raises and waits on the answer. This blocks the calling
      # process — never the Session, because the caller is a Task behind
      # eval-defer!.
      {"agent-ask-permission!",
       "(agent-ask-permission! SLUG TITLE RAW [MS]) — raise a permission card in the chat and block until it is answered, or deny it after MS; return 'allow, 'always or 'deny."} =>
        fn args ->
          [slug, title, raw | rest] = args

          request = %{title: to_string(title), kind: "tool", raw: to_string(raw)}

          request =
            case rest do
              [ms] when is_number(ms) and ms > 0 -> Map.put(request, :timeout_ms, trunc(ms))
              _ -> request
            end

          case Compos.Core.Agent.ask_permission(s(slug), request) do
            :always -> {:sym, "always"}
            :allow -> {:sym, "allow"}
            _ -> {:sym, "deny"}
          end
        end,
      {"agent-question-respond!",
       "(agent-question-respond! SLUG ID ANSWER) — answer a pending branching question."} => fn [
                                                                                                  slug,
                                                                                                  question_id,
                                                                                                  answer
                                                                                                ] ->
        case Compos.Core.Agent.respond_question(s(slug), question_id, to_string(answer)) do
          :ok -> :void
          {:error, r} -> raise_scheme("agent-question-respond!: #{inspect(r)}")
        end
      end,
      {"agent-append!",
       "(agent-append! SLUG TEXT) — insert TEXT at the agent's mark; return the new byte offset."} =>
        fn [slug, text] ->
          case Compos.Core.Agent.append_at_mark(s(slug), to_string(text)) do
            mark when is_integer(mark) -> mark
            {:error, r} -> raise_scheme("agent-append!: #{inspect(r)}")
          end
        end,
      {"agent-mark", "(agent-mark SLUG) — return the agent's output mark as a byte offset."} =>
        fn [slug] ->
          case Compos.Core.Agent.mark(s(slug)) do
            mark when is_integer(mark) -> mark
            {:error, r} -> raise_scheme("agent-mark: #{inspect(r)}")
          end
        end,
      {"agent-list", "(agent-list) — return the slugs of the running agent threads, sorted."} =>
        fn [] -> Compos.Core.Agent.list() end,
      {"agent-kill!", "(agent-kill! SLUG) — stop the agent thread."} => fn [slug] ->
        Compos.Core.LLMSession.close(s(slug))
        :void
      end,
      # live model switch on the running session (ACP session/set_model)
      {"agent-set-model!",
       "(agent-set-model! SLUG MODEL) — switch the live session's model; return #t or #f."} =>
        fn [slug, model] ->
          case Compos.Core.LLMSession.set_model(s(slug), s(model)) do
            :ok -> true
            {:error, _} -> false
          end
        end,
      # live permission-mode switch (ACP session/set_mode); #f when the
      # backend doesn't do modes — the caller then answers requests itself
      {"agent-set-mode!",
       "(agent-set-mode! SLUG MODE) — switch the permission mode; #f when unsupported."} => fn [
                                                                                                 slug,
                                                                                                 mode
                                                                                               ] ->
        case Compos.Core.LLMSession.set_mode(s(slug), s(mode)) do
          :ok -> true
          {:error, _} -> false
        end
      end,
      # -> (slug "a1" buffer "*agent: a1*" status idle queued 0 permission #f)
      {"agent-info",
       "(agent-info SLUG) — return a plist: slug, buffer, status, queued, steering, ending, steers, settling, silent, permission, question; or #f. ending is #t while a finished turn waits on an unresolved steer. settling is #t while a steered turn waits for its close; silent is #t while a turn waits for the connector's first event."} =>
        fn [slug] ->
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
                {:sym, "ending"},
                info.ending,
                {:sym, "steers"},
                info.steers,
                # the two silences a stalled chat can be in. An Agent from
                # before a hot reload reports neither, so ask with a default
                {:sym, "settling"},
                Map.get(info, :settling, false),
                {:sym, "silent"},
                Map.get(info, :silent, false),
                {:sym, "permission"},
                perm,
                {:sym, "question"},
                question
              ]
          end
        end,
      # one global handler for all agent events: (lambda (slug events) ...).
      # It escapes into the Agent GenServers as an opaque fun — root it.
      {"agent-on-event!",
       "(agent-on-event! HANDLER) — set the global agent event handler: (HANDLER SLUG EVENTS)."} =>
        fn [handler] ->
          Roots.put({:agent_handler}, handler)
          :void
        end,
      # the turn-end fan-out: (lambda (slug stop-reason) ...). The Agent
      # dispatches it once per completed turn, AFTER the batch carrying that
      # turn-end has rendered, and on the :ui lane — a listener reads a
      # finished transcript and touches buffers that are not the agent's.
      {"agent-on-turn-end!",
       "(agent-on-turn-end! HANDLER) — set the turn-end handler: (HANDLER SLUG STOP-REASON), called on the :ui lane after the turn has rendered."} =>
        fn [handler] ->
          Roots.put({:agent_turn_end}, handler)
          :void
        end,
      # the direct lane's context provider: (lambda (slug display-text) ...)
      # -> (turns ... system ... tools ... dispatcher ...), called by
      # Backend.ReqLLM at each turn start. Rooted like the event handler.
      {"agent-context-fn!",
       "(agent-context-fn! HANDLER) — set the direct lane's context provider for each turn."} =>
        fn [handler] ->
          Roots.put({:agent_context}, handler)
          :void
        end,
      # the direct lane's record writer: (lambda (slug role blocks wire) ...),
      # called by the turn task for every message it puts on the wire. The
      # task reads the record and writes it in ONE order, so the next turn
      # replays exactly what the last one sent. Rooted like the handlers
      # above.
      {"agent-record-fn!",
       "(agent-record-fn! HANDLER) — set the direct lane's record writer for wire messages."} =>
        fn [handler] ->
          Roots.put({:agent_record}, handler)
          :void
        end,
      # the permission policy the DIRECT lane consults before every tool
      # call: (lambda (slug name kind raw) ...) -> allow | ask | reject.
      # (The ACP lane answers its own requests through the same policy,
      # from the event handler.) Rooted like the handlers above.
      {"agent-permission-fn!",
       "(agent-permission-fn! HANDLER) — set the tool policy; it returns allow, ask, or reject."} =>
        fn [handler] ->
          Roots.put({:agent_permission}, handler)
          :void
        end,
      # arm an auto-deny deadline on the thread's pending permission
      {"agent-permission-deadline!",
       "(agent-permission-deadline! SLUG MS) — arm an auto-deny deadline on the permission."} =>
        fn [slug, ms] ->
          Compos.Core.Agent.permission_deadline(s(slug), trunc(ms))
          :void
        end,
      {"set-modeline-extra!",
       "(set-modeline-extra! TEXT) — set the extra text at the right of the frame modeline: a string, or a list of (CLASS TEXT) segments."} =>
        fn [s] ->
          Editor.set_modeline_extra(modeline_extra(s))
          :void
        end,
      {"frame-chrome-set!",
       "(frame-chrome-set! KEY VALUE) — set the chrome value KEY (a string) that every frame draws: echo-hints, mode-line-format, workspace-help, tabs-more-title."} =>
        fn [key, value] ->
          Editor.set_chrome(to_string(key), value)
          :void
        end,
      {"llm-model", "(llm-model) — return the active LLM model id."} => fn [] ->
        Compos.Core.LLM.model()
      end,
      {"llm-context-limit",
       "(llm-context-limit MODEL) — input tokens the model accepts, or #f when unknown."} => fn [
                                                                                                  m
                                                                                                ] ->
        Compos.Core.ModelCatalog.context_limit(to_string(m)) || false
      end,
      {"eval-string", "(eval-string SRC) — evaluate SRC as Scheme; return the last value."} =>
        fn [src], store -> eval_src.(src, store) end,
      # The deferred-reply lane. An eval that hands slow work to a Task
      # claims its caller's reply slot with eval-defer! and answers through
      # eval-resolve! when the Task's callback delivers the value. The
      # caller blocks in its own process; the Session moves on at once.
      {"eval-defer!",
       "(eval-defer!) — claim the current eval's reply; return a token for eval-resolve!, or #f outside an eval."} =>
        fn [] ->
          case Process.get(:eval_reply_to) do
            nil ->
              false

            from ->
              token = make_ref()
              Roots.put({:eval_pending, token}, from)
              Process.put(:eval_deferred, token)
              token
          end
        end,
      {"eval-resolve!",
       "(eval-resolve! TOKEN VALUE) — answer the deferred eval named by TOKEN with VALUE."} =>
        fn [token, value] ->
          # take is one step: two resolves never both answer the caller
          case Roots.take({:eval_pending, token}) do
            nil ->
              # already resolved, or the caller gave up: nobody to answer
              :void

            from ->
              GenServer.reply(from, {:ok, Scheme.print(value)})
              :void
          end
        end,
      # (with-edit-author AUTHOR THUNK) — every buffer mutation THUNK makes
      # is attributed to AUTHOR (see buffer-authors). The try/after restore
      # is the point: a raising handler must not leave the author stuck on
      # the session, misattributing every later keystroke.
      {"with-edit-author",
       "(with-edit-author AUTHOR THUNK) — run THUNK; buffer edits it makes are attributed to the string AUTHOR."} =>
        fn [author, thunk], store ->
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
      {"current-edit-author",
       "(current-edit-author) — the caller process's edit author string, or #f"} => fn [] ->
        Process.get(:compos_edit_author) || false
      end,
      # Emacs' logical current-buffer binding, deliberately separate from
      # window display. Tool evaluation uses this so visit/switch operations
      # can establish the buffer commands act on without hijacking the user's
      # selected window.
      {"with-current-buffer",
       "(with-current-buffer BUF THUNK) — run THUNK with BUF current without displaying it or changing any window."} =>
        fn [buffer, thunk], store ->
          buffer = to_string(buffer)

          unless Compos.Core.Buffer.exists?(buffer) do
            raise Compos.Scheme.Eval.Error, message: "no such buffer: #{buffer}"
          end

          Compos.Core.Frame.with_buffer(buffer, fn ->
            Compos.Scheme.Eval.apply_fn(thunk, [], store)
          end)
        end,
      {"with-buffer-display-update",
       "(with-buffer-display-update BUF THUNK) — keep the previous presentation visible until THUNK finishes updating text, styling and selection; release on errors too."} =>
        fn [buffer, thunk], store ->
          Compos.Core.Events.with_display_update(to_string(buffer), fn ->
            Compos.Scheme.Eval.apply_fn(thunk, [], store)
          end)
        end,
      # The deliberate exit from that binding. Inside the thunk,
      # current-buffer and the switch primitives resolve through the
      # frame's real windows, so a tool that intends a display change can
      # make one and observe it truthfully.
      {"buffer-context?",
       "(buffer-context?) — #t inside a logical current-buffer binding; window placement must not change the frame there."} =>
        fn [] -> Frame.buffer_context() != nil end,
      {"with-frame-windows",
       "(with-frame-windows THUNK) — run THUNK with no logical buffer context: current-buffer and switch-to-buffer! act on the frame's real windows."} =>
        fn [thunk], store ->
          Compos.Core.Frame.without_buffer(fn ->
            Compos.Scheme.Eval.apply_fn(thunk, [], store)
          end)
        end,
      # Scheme tasks share global bindings. This narrow lock lets Scheme
      # publish an expensive derived value once after shared source changes.
      # The process identity keeps :global's requester identity distinct.
      {"with-scheme-lock",
       "(with-scheme-lock KEY THUNK) — run THUNK once at a time for KEY across Scheme processes."} =>
        fn [key, thunk], store ->
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
      {"wait-until",
       "(wait-until PRED &optional TIMEOUT-MS INTERVAL-MS) — poll PRED until it answers true; return #t, or #f at the deadline."} =>
        fn args, store ->
          [pred | rest] = args
          timeout = min(wait_arg(rest, 0, 2_000), @wait_cap)
          interval = max(wait_arg(rest, 1, 20), 5)
          deadline = System.monotonic_time(:millisecond) + timeout
          wait_until_loop(pred, deadline, interval, store)
        end,
      # (eval-string-safe SRC) -> (ok VAL) | (error MSG) — the catch this
      # dialect lacks; the eval-scheme tool's did-you-mean feedback needs to
      # observe the error instead of aborting the whole handler
      {"eval-string-safe",
       "(eval-string-safe SRC) — evaluate SRC; return (ok VAL) or (error MSG)."} => fn [src],
                                                                                       store ->
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
      {"symbol-value", "(symbol-value 'NAME) — return the global value of the symbol."} => fn [
                                                                                                {:sym,
                                                                                                 name}
                                                                                              ],
                                                                                              store ->
        {Compos.Scheme.Env.lookup(store, global, name), store}
      end,
      {"set-symbol-value!", "(set-symbol-value! 'NAME VAL) — set the global value of the symbol."} =>
        fn [{:sym, name}, val], store ->
          {val, Compos.Scheme.Env.define(store, global, name, val)}
        end,
      {"unbind-global!", "(unbind-global! 'NAME) — remove the global binding of the symbol."} =>
        fn [{:sym, name}], store ->
          {:void, Compos.Scheme.Env.unbind(store, global, name)}
        end,
      {"function-interpose!",
       "(function-interpose! 'NAME WRAPPER) — internal binding wrapper; WRAPPER receives ORIGINAL and ARGS; #f removes it."} =>
        fn [{:sym, name}, wrapper], store ->
          {:void, Compos.Scheme.Env.interpose(store, global, name, wrapper)}
        end,
      {"boundp", "(boundp 'NAME) — return #t when the symbol has a global binding."} => fn [
                                                                                             {:sym,
                                                                                              name}
                                                                                           ],
                                                                                           store ->
        {match?({:ok, _}, Compos.Scheme.Env.fetch(store, global, name)), store}
      end,
      # every globally bound name (builtins + userland defines) — the
      # discovery surface for agents writing eval-scheme code
      {"global-names", "(global-names) — return every globally bound name, sorted."} => fn [],
                                                                                           store ->
        {Compos.Scheme.Env.frame_names(store, global) |> Enum.sort(), store}
      end,
      # the doc sweep's surface: apropos scope "all" and describe-function
      # read these instead of showing a bare name. A userland alias of a
      # builtin — (define raw-buffer-create buffer-create) — carries the
      # builtin value, so the lookup follows the value to the real name.
      {"primitive-doc",
       "(primitive-doc NAME) — return the one-line doc for an Elixir primitive, or #f."} => fn [
                                                                                                 name
                                                                                               ],
                                                                                               store ->
        n = doc_name(name)

        resolved =
          case Compos.Scheme.Env.fetch(store, global, n) do
            {:ok, {:builtin, builtin_name, _}} -> builtin_name
            _ -> n
          end

        {primitive_docs()[resolved] || primitive_docs()[n] || false, store}
      end,
      {"primitive-docs",
       "(primitive-docs) — return (NAME DOC) pairs for every Elixir primitive, sorted."} =>
        fn [] ->
          primitive_docs() |> Enum.sort() |> Enum.map(fn {n, d} -> [n, d] end)
        end,
      # load-library: evaluate a Scheme file in the live session. A relative
      # path resolves against the config home, so init.scm can source
      # (load "providers.scm") without knowing where the daemon was started.
      {"load", "(load PATH) — evaluate a Scheme file in the live session."} => fn [path], store ->
        expanded = expand_load_path(path)

        case File.read(expanded) do
          {:ok, src} ->
            # At boot, priv/init.scm loads every bundled package in one
            # eval. A file that does not read or does not evaluate must
            # cost that file alone: raising here aborted the manifest, so
            # one bad form in one package silently took every package
            # after it, and the editor came up missing half of itself.
            # Boot records the error and goes on. After boot, a load is a
            # command the user ran and its error belongs to the caller.
            if ready?() do
              eval_src.(src, store)
            else
              boot_load(eval_src, src, store, Path.basename(expanded))
            end

          {:error, reason} ->
            if ready?() do
              raise Compos.Scheme.Eval.Error, message: "cannot load #{expanded}: #{reason}"
            else
              record_boot_error!(Path.basename(expanded), "cannot read: #{reason}")
              {:void, store}
            end
        end
      end,
      {"eval-region",
       "(eval-region BUF START END) — evaluate the text between byte offsets START and END."} =>
        fn [buffer, s, e], store ->
          src = buffer |> Buffer.text() |> binary_part(s, e - s)
          eval_src.(src, store)
        end,
      {"eval-buffer", "(eval-buffer BUF) — evaluate the whole buffer as Scheme."} => fn [buffer],
                                                                                        store ->
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
      # The handler is an MFA, never a fun: a fun from this module dies
      # when a hot reload purges the module version it came from, and the
      # rule then fails on every change until a restart.
      {"on-change!",
       "(on-change! BUF CB ['eager]) — call (CB POS INSERTED DELETED-LEN SOURCE) on changes; fires only while BUF is visible or in the current buffer's group, unless 'eager; return an id."} =>
        fn [buf, callback | rest] ->
          {:ok, id} =
            Compos.Core.Reactor.on_change(
              buf,
              :any,
              {__MODULE__, :fire_change, [callback]},
              debounce: 30,
              sources: :all,
              eager: Enum.any?(rest, &match?({:sym, "eager"}, &1))
            )

          # the Reactor holds the callback inside an opaque fun — root it for
          # the GC for as long as the rule lives
          Roots.put({:reactor, id}, callback)
          id
        end,
      {"remove-on-change!", "(remove-on-change! ID) — remove a change handler by its id."} => fn [
                                                                                                   id
                                                                                                 ] ->
        Compos.Core.Reactor.remove(id)
        Roots.drop({:reactor, id})
        :void
      end,

      # Emacs' with-minibuffer-selected-window: run a thunk with
      # current-buffer pointing at the WINDOW's buffer even though a prompt
      # is active — isearch's change handler moves point in the file, not
      # in the prompt it is typing into
      {"with-window-buffer",
       "(with-window-buffer THUNK) — run THUNK with the window's buffer current, not the prompt."} =>
        fn [thunk], store ->
          Editor.set_mb_redirect(false)

          try do
            Compos.Scheme.Eval.apply_fn(thunk, [], store)
          after
            Editor.set_mb_redirect(true)
          end
        end,

      # store-aware (an active prompt's on_cancel closure applies in the
      # CURRENT store); refuses the sole frame
      {"delete-frame!",
       "(delete-frame! [ID]) — delete the frame and run its prompt's cancel handler."} => fn args,
                                                                                             store ->
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
      {"minibuffer-buffer", "(minibuffer-buffer) — return the minibuffer's buffer name."} =>
        fn [] -> Editor.minibuf_name() end,
      # What the minibuffer is currently asking, as data — #f when it isn't
      # asking anything. The GUI reads this off the render payload; a browser
      # tab has no render payload, so it reads it here and draws its own.
      {"minibuffer-state",
       "(minibuffer-state) — return the active prompt as a plist (prompt, input, sel, total, legend, candidates), or #f."} =>
        fn [] ->
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
                # the prompt's flavour word, which decides its shape. A
                # surface that draws its own prompt reads this to know
                # whether it was asked for the bar, the popup or the modal.
                {:sym, "style"},
                Map.get(mb, :style) || false,
                # the prompt's own key legend, as Scheme wrote it
                {:sym, "legend"},
                Map.get(mb, :legend) || [],
                {:sym, "candidates"},
                Enum.map(Compos.Core.Candidates.rows(mb.list), fn c ->
                  [{:sym, "label"}, c.label, {:sym, "hint"}, c.hint || ""]
                end)
              ]
          end
        end,
      {"minibuffer-style!",
       "(minibuffer-style! STYLE) — change the open prompt's style, and so its shape, without closing it: \"modal\", \"panel\", \"minibuffer\", or #f."} =>
        fn [style] ->
          Editor.minibuffer_set_style(if(style in [false, nil], do: nil, else: s(style)))
          :void
        end,
      {"minibuffer-input!", "(minibuffer-input! INPUT) — set the minibuffer input text."} => fn [
                                                                                                  input
                                                                                                ] ->
        Editor.minibuffer_set_input(s(input))
        :void
      end,
      # Browser prompts do not pass through KeyDispatch, whose normal edit
      # path fires on_change. Keep the store-aware callback here so a dynamic
      # candidate provider behaves identically on both input surfaces.
      {"minibuffer-change!",
       "(minibuffer-change! INPUT) — set minibuffer input and run its live change handler."} =>
        fn [input], store ->
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
      # Roots until its timer fires; the generation check makes a cancelled
      # timer harmless even if its message was already in this mailbox.
      {"debounce!",
       "(debounce! KEY MS CALLBACK ARG) — after MS idle, call CALLBACK with ARG; a newer call with KEY cancels the old one."} =>
        fn [key, ms, callback, arg] ->
          key = {:debounce, s(key)}

          case Roots.get(key) do
            {_generation, timer, _callback, _arg, _fid} -> Process.cancel_timer(timer)
            _ -> :ok
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

          Roots.put(key, {generation, timer, callback, arg, Frame.current()})
          :void
        end,
      {"debounce-cancel!",
       "(debounce-cancel! KEY) — cancel KEY's pending debounce timer; a later fire is a no-op."} =>
        fn [key] ->
          key = {:debounce, s(key)}

          # delete only the generation that was read: a debounce! that
          # lands between the read and the delete keeps its own entry
          case Roots.get(key) do
            {generation, timer, _callback, _arg, _fid} ->
              Process.cancel_timer(timer)

              :ets.select_delete(Roots.table(), [
                {{key, {generation, :_, :_, :_, :_}}, [], [true]}
              ])

            _ ->
              :ok
          end

          :void
        end,
      {"minibuffer-confirm!",
       "(minibuffer-confirm!) — close the prompt; run its confirm handler with the value."} =>
        fn [], store ->
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
      {"minibuffer-confirm-input!",
       "(minibuffer-confirm-input!) — close the prompt; submit the input, not the candidate."} =>
        fn [], store ->
          case Editor.minibuffer_close() do
            %{on_confirm: oc} = mb when oc not in [nil, false] ->
              {_, store} = Compos.Scheme.Eval.apply_fn(oc, [mb.input], store)
              {:void, store}

            _ ->
              {:void, store}
          end
        end,
      {"minibuffer-cancel!",
       "(minibuffer-cancel!) — close the prompt; run its cancel handler; echo Quit."} => fn [],
                                                                                            store ->
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
      {"minibuffer-detach!",
       "(minibuffer-detach!) — close the prompt; return its state and closures, or #f."} =>
        fn [] ->
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
      {"minibuffer-complete!",
       "(minibuffer-complete!) — run the prompt's completion, or copy the selection to the input."} =>
        fn [], store ->
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
      {"minibuffer-next!", "(minibuffer-next!) — move the candidate selection down one."} =>
        fn [] ->
          Editor.minibuffer_move_sel(1)
          :void
        end,
      {"minibuffer-prev!", "(minibuffer-prev!) — move the candidate selection up one."} =>
        fn [] ->
          Editor.minibuffer_move_sel(-1)
          :void
        end,
      # The palette's second list. The prompt keeps the state and sends the
      # whole rail each time, so this holds no cursor of its own: rows in,
      # rows out, and INDEX says which one wears the highlight. A row is
      # (LABEL HINT . REST); REST is the prompt's own and never travels.
      {"minibuffer-rail!",
       "(minibuffer-rail! ROWS INDEX FOCUSED) — set the palette's right-hand list. ROWS is ((LABEL HINT ...) ...), INDEX the row on, FOCUSED whether the arrows are in it; '() clears it."} =>
        fn [rows, index, focused] ->
          rail =
            case rows do
              [_ | _] ->
                i = index |> trunc() |> max(0) |> min(length(rows) - 1)

                %{
                  focused: focused not in [false, nil],
                  rows:
                    rows
                    |> Enum.with_index()
                    |> Enum.map(fn {row, k} ->
                      {label, hint} =
                        case row do
                          [l, h | _] -> {l, h}
                          [l] -> {l, ""}
                          l -> {l, ""}
                        end

                      %{label: s(label), hint: s(hint), selected: k == i}
                    end)
                }

              _ ->
                nil
            end

          Editor.minibuffer_set_rail(rail)
          :void
        end,
      # DEL: in a path prompt at a directory boundary, kill the whole
      # component (vertico-directory); otherwise one char back at point
      {"minibuffer-del!",
       "(minibuffer-del!) — delete one char back; at a directory boundary, delete the component."} =>
        fn [] ->
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
    |> Map.merge(Compos.Core.Browser.Prims.entries())
    |> Map.merge(Compos.Core.MCP.Prims.entries())
    |> Map.merge(Compos.Core.LSP.Prims.entries())
    |> Map.merge(Compos.Core.DB.Prims.entries())
    |> Map.merge(Compos.Core.Endpoint.Prims.entries())
    |> Map.merge(Compos.Core.WebServer.Prims.entries())
    |> Map.merge(Compos.Core.Conn.Prims.entries())
    |> Map.merge(Compos.Core.LLMSession.Prims.entries())
    |> Compos.Core.SchemeRawNames.add()
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
  @doc "The Reactor's door for an `on-change!` rule: apply CALLBACK to the change args."
  def fire_change(callback, changes), do: apply_callback(callback, change_args(changes))

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
        Roots.put(key, callback)
        fid = Frame.current()
        buffer = Frame.buffer_context()
        lane = Lane.current() || :ui

        case Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
               result = SchemeTask.await(task, timeout)

               args =
                 case result do
                   {:ok, value} -> [true, value]
                   {:error, reason} -> [false, reason]
                 end

               try do
                 apply_callback(callback, args, fid, lane, buffer)
               after
                 Roots.drop(key)
                 SchemeTask.cancel(task)
               end
             end) do
          {:ok, _pid} ->
            task

          {:error, reason} ->
            Roots.drop(key)
            SchemeTask.cancel(task)
            raise_scheme("task-run!: #{inspect(reason)}")
        end

      {:error, reason} ->
        raise_scheme("task-run!: #{reason}")
    end
  end

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

  @doc """
  The inverse of `Compos.Core.LLM.json_to_scheme/1`, for values headed out to
  JSON. The convention lives in `Compos.Core.Plist`, because three places
  had three slightly different ideas of what counted as a plist.
  """
  defdelegate scheme_to_json(value), to: Compos.Core.Plist, as: :to_json

  defp usage_to_plist(usage) do
    t = Compos.Core.LLMUsage.tokens(usage)

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
