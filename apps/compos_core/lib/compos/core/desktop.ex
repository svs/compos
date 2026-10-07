defmodule Compos.Core.Desktop do
  @moduledoc """
  Desktop save/restore owns presentation only: frames, window trees, faces,
  and declared Scheme globals. Buffer processes checkpoint and restore their
  own state independently.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Editor, Events, Session}

  @debounce 1_500

  # The desktop must never wait on the Session for long. The Session runs one
  # form at a time, so a slow shell command or agent turn parks every caller
  # behind it. The globals are small and change rarely, so a save that cannot
  # read them writes the last values it read.
  @globals_timeout 2_000

  # Putting the globals back is not on a keystroke path, so it waits as long
  # as a restore does.
  @install_timeout 30_000

  # How long to wait before asking a replacement Session for its attention
  # again. The new one loads the whole stdlib before it answers.
  @reseed_retry 1_000

  # How long the restore waits for the on-screen buffers to become whole
  # before it hands the frames back. Long enough for a mode setup and a
  # font-lock pass, short enough that one slow chat cannot hold the boot.
  @restore_first_budget 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path,
    do: Application.get_env(:compos_core, :desktop_path, Path.expand("~/.compos/desktop.etf"))

  @doc "Synchronous snapshot to disk (also used by tests)."
  def save_now, do: GenServer.call(__MODULE__, :save)

  @doc """
  Restore from disk over the current editor state, and wait for the
  runtime of every shown buffer: a wake queues its rebuild on the
  buffer's lane, and a caller of this API reads the rebuilt runtime.
  """
  def restore_now do
    result = GenServer.call(__MODULE__, :restore, 30_000)
    Compos.Core.await_restores(shown_buffers())
    result
  end

  @doc """
  The globals a desktop file holds, without touching the editor.

  Scheme installs them itself (`M-x desktop-read-globals`): this process
  must not, because installing calls into the Session, and the Scheme
  caller is already inside it.
  """
  def file_globals(file) do
    with {:ok, bin} <- File.read(file),
         %{} = desktop <- :erlang.binary_to_term(bin),
         globals when is_list(globals) <- desktop[:globals] || [] do
      {:ok, globals}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :not_a_desktop_file}
    end
  end

  # --- server ----------------------------------------------------------------

  @initial %{timer: nil, globals: [], session: nil, scheme_stale?: false, restore_pending?: false}

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_editor()
    send(self(), :watch_session)
    # A restore is owed from here until one finishes. While it is owed this
    # process knows less than the file does, so it may not write over it.
    restore? = Application.get_env(:compos_core, :desktop_autorestore, true)
    if restore?, do: send(self(), :restore)
    {:ok, %{@initial | restore_pending?: restore?}}
  end

  # Compos.Core.Hotload swaps a recompiled module into the running VM, so a
  # release upgrade's code_change/3 never runs and this process keeps the
  # state map the OLD module built. A new key would then raise on the first
  # update — the reload the editor promises would break the desktop instead
  # of improving it. Fill the missing keys in on the way through.
  # The first message after the swap also arms what the old module never
  # had: without this the monitor waits for a restart of this process, and
  # the reload has to be trusted to reach a running editor.
  defp upgrade(state) do
    unless Map.has_key?(state, :session), do: send(self(), :watch_session)
    # The old module's state has no restore_pending? key, and that process
    # was already serving this editor. Only a process that starts fresh
    # owes a restore before it may write the file.
    swapped? = not Map.has_key?(state, :restore_pending?)
    state = Map.merge(@initial, state)
    if swapped?, do: %{state | restore_pending?: false}, else: state
  end

  @impl true
  def handle_call(msg, from, state), do: on_call(msg, from, upgrade(state))

  @impl true
  def handle_info(msg, state), do: on_info(msg, upgrade(state))

  defp on_call(:save, _from, state) do
    {result, state} = do_save(state)
    {:reply, result, state}
  end

  defp on_call(:restore, _from, state) do
    {result, state} = do_restore(state)
    {:reply, result, state}
  end

  defp on_info({:editor_change, _}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, @debounce)}}
  end

  defp on_info(:flush, state) do
    {_result, state} = do_save(state)
    {:noreply, %{state | timer: nil}}
  end

  defp on_info(:restore, state) do
    {_result, state} = do_restore(state)
    {:noreply, state}
  end

  defp on_info(:watch_session, state),
    do: {:noreply, %{state | session: watch_session(state)}}

  defp on_info({:DOWN, ref, :process, _dead, reason}, %{session: {_watched, ref}} = state) do
    Logger.error(
      "desktop: the Session stopped (#{inspect(reason)}). Its replacement boots a new " <>
        "interpreter that holds the defvar defaults, so this process holds the only " <>
        "copy of the persisted globals until it takes them back."
    )

    send(self(), :reseed)
    {:noreply, %{state | session: nil, scheme_stale?: true}}
  end

  # The new Session says so itself, in case this process restarted at the
  # same moment and never held the monitor that would have told it. When the
  # monitor did its work already, this arrives second and must do nothing:
  # holding the monitor on the Session that is up, with nothing stale, is
  # exactly the state a finished recovery leaves. Without the check both
  # paths recovered, and the second one rebuilt every buffer again.
  defp on_info(:scheme_rebooted, state) do
    if state.scheme_stale? or watching_current?(state) do
      {:noreply, state}
    else
      send(self(), :reseed)
      {:noreply, %{state | scheme_stale?: true}}
    end
  end

  defp on_info(:reseed, state) do
    if is_nil(Process.whereis(Session)) do
      Process.send_after(self(), :reseed, @reseed_retry)
      {:noreply, state}
    else
      {:noreply, reseed(state)}
    end
  end

  defp on_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_save(upgrade(state))
    :ok
  end

  # --- snapshot --------------------------------------------------------------

  # Presentation only. Each buffer owns its durable state and writes its own
  # checkpoint on a debounce after a change, so the desktop sweeps nothing.
  # A restore that fails leaves this process holding nothing: no globals,
  # and no frames it put on screen. The editor still runs, so an ordinary
  # change still asks for a save, and that save used to write the empty
  # Scheme defaults over a good file. Every group the user had went with
  # it. A process that never restored holds no opinion the file needs.
  defp do_save(%{restore_pending?: true} = state) do
    Logger.warning(
      "desktop: refused to save. This process never restored, so the file on " <>
        "disk holds more than it does."
    )

    {:error, state}
  end

  defp do_save(state) do
    # v2: every frame's layout, in frame-MRU order (head = most recent).
    # desktop_view is read-only (S15): saving must not run the render
    # walk, which writes viewport tops back into the tree.
    views = for fid <- Editor.frame_list(), do: {fid, Editor.desktop_view(fid)}

    frames =
      for {fid, view} <- views do
        %{
          id: fid,
          tree: serialize(view.tree),
          hidden: Enum.map(Map.get(view, :hidden, []), &serialize/1),
          active_buffer: view.active_buffer
        }
      end

    {globals, state} = scheme_globals(state)

    desktop = %{
      version: 3,
      frames: frames,
      globals: globals
    }

    file = path()
    rotate_backup(file)
    Compos.Core.BufferStore.atomic_write(file, :erlang.term_to_binary(desktop))
    {:ok, state}
  rescue
    e ->
      Logger.warning("desktop save failed: #{Exception.message(e)}")
      {:error, state}
  end

  @backup_every 600
  @backup_keep 50

  # The desktop file is rewritten seconds after every change, so a bad state
  # overwrites the only copy before anyone notices. A dated copy at most every
  # ten minutes bounds a loss to that window; fifty copies bound the disk.
  defp rotate_backup(file) do
    if File.exists?(file) do
      dir = Path.join(Path.dirname(file), "desktop-backups")
      File.mkdir_p!(dir)
      backups = dir |> Path.join("desktop-*.etf") |> Path.wildcard() |> Enum.sort()

      fresh? =
        case List.last(backups) do
          nil ->
            false

          last ->
            case File.stat(last, time: :posix) do
              {:ok, %{mtime: t}} -> System.os_time(:second) - t < @backup_every
              _ -> false
            end
        end

      unless fresh? do
        stamp = Calendar.strftime(NaiveDateTime.utc_now(), "%Y%m%d-%H%M%S")
        File.cp(file, Path.join(dir, "desktop-" <> stamp <> ".etf"))
        Enum.each(Enum.drop(backups, -(@backup_keep - 1)), &File.rm/1)
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("desktop backup rotation failed: #{Exception.message(e)}")
      :ok
  end

  # the leaf carries the per-window point and scroll state — saved so
  # each window reopens at its own spot, pinned if the reader pinned it
  defp serialize(%{type: :leaf, buffer: b} = leaf) do
    {:leaf, b, Map.get(leaf, :top, 0), Map.get(leaf, :point, 0), Map.get(leaf, :manual, false),
     Map.get(leaf, :ctop, 0), Map.get(leaf, :history, [])}
  end

  defp serialize(%{type: :split, dir: dir, children: [a, b]} = split),
    do: {:split, dir, Map.get(split, :ratio, 0.5), serialize(a), serialize(b)}

  defp serializable?(v) when is_function(v) or is_pid(v) or is_reference(v) or is_port(v),
    do: false

  defp serializable?(v) when is_list(v), do: Enum.all?(v, &serializable?/1)
  defp serializable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> serializable?(k) and serializable?(val) end)

  defp serializable?(_), do: true

  # Scheme state that must outlive a restart. The desktop carries the
  # values and reads none of them: priv/editor.scm says which globals ride
  # along (persist-global!) and hands them over as one list. Filtered the
  # same way locals are — a global holding a pid or a fun is dropped, not
  # written.
  #
  # The read happens only against the interpreter this process seeded. A
  # Session that died and came back answers every one of these with its
  # defvar default, and a save that believes that answer writes the empty
  # set over the good file: on 2026-09-11 that lost 35 groups, the group
  # graveyard, both connector catalogs and every history in one autosave.
  # Until the replacement takes the globals back, a save writes the set
  # this process already holds.
  defp scheme_globals(%{scheme_stale?: true} = state) do
    Logger.warning("desktop: the Scheme world has not taken the globals back; saved the last set")
    {state.globals, state}
  end

  defp scheme_globals(state) do
    if same_session?(state) do
      read_globals(state)
    else
      Logger.error("desktop: the Session changed under this process; saved the last globals")
      send(self(), :reseed)
      {state.globals, %{state | session: nil, scheme_stale?: true}}
    end
  end

  defp read_globals(state) do
    case Session.call_named("desktop-globals", [], nil, @globals_timeout) do
      {:ok, globals} when is_list(globals) ->
        globals = Enum.filter(globals, &serializable?/1)
        {globals, %{state | globals: globals}}

      _ ->
        {state.globals, state}
    end
  catch
    :exit, _ ->
      Logger.warning("desktop: Session busy, saved the previous globals")
      {state.globals, state}
  end

  # --- the Scheme world's copy ------------------------------------------------
  #
  # Every persisted global lives in a Scheme variable, and the Session owns
  # the interpreter those variables live in. A Session restart therefore
  # empties all of them at once while the frames, buffers and windows on the
  # Elixir side carry on unchanged. Watch the Session, put the values back
  # when a replacement boots, and hold every save to the last good set in
  # the meantime.

  # Always through the previous monitor, never beside it: a reseed retries
  # on a timer, and a second monitor on the same Session means a second
  # :DOWN and a second recovery for one death.
  defp watch_session(state) do
    case state.session do
      {_pid, ref} -> Process.demonitor(ref, [:flush])
      nil -> :ok
    end

    case Process.whereis(Session) do
      nil ->
        Process.send_after(self(), :watch_session, 200)
        nil

      pid ->
        {pid, Process.monitor(pid)}
    end
  end

  # For a save: only a Session this process KNOWS it did not seed makes the
  # read untrustworthy. No monitor yet (boot) is not that case.
  defp same_session?(%{session: {pid, _ref}}), do: Process.whereis(Session) == pid
  defp same_session?(_state), do: true

  # For a recovery: nothing to do only when this process holds the monitor
  # on the Session that is up. No monitor means the recovery has not run.
  defp watching_current?(%{session: {pid, _ref}}), do: Process.whereis(Session) == pid
  defp watching_current?(_state), do: false

  defp reseed(state) do
    state = %{state | session: watch_session(state)}

    cond do
      not await_session() ->
        Process.send_after(self(), :reseed, @reseed_retry)
        state

      install_globals(state.globals) ->
        Logger.info(
          "desktop: put #{length(state.globals)} globals back into the new interpreter"
        )

        rebuild_scheme_runtime(length(state.globals))
        %{state | scheme_stale?: false}

      true ->
        Process.send_after(self(), :reseed, @reseed_retry)
        state
    end
  end

  # A replacement Session registers its name before init/1 loads the stdlib,
  # and the published interpreter handle is still the dead one until that
  # load ends. Ask the process itself, which answers only once it is booted.
  defp await_session do
    GenServer.call(Session, :await_boot, 60_000)
    true
  catch
    :exit, _ -> false
  end

  defp install_globals([]), do: true

  defp install_globals(globals) do
    case Session.call_named("desktop-globals!", [globals], nil, @install_timeout) do
      {:ok, _} ->
        true

      other ->
        install_one_at_a_time(globals, inspect(other))
    end
  catch
    :exit, reason ->
      install_one_at_a_time(globals, inspect(reason))
  end

  # The whole set goes back in one call, and one restore that raises takes
  # every global after it down with it: the editor then comes up with no
  # groups, no layouts and no history, and the only sign is a line in the
  # log. So when that call fails, put them back one at a time and lose
  # only the key that cannot restore itself.
  defp install_one_at_a_time(globals, why) do
    Logger.warning("desktop: the globals did not install in one call (#{why}); one at a time")
    ok = Enum.count(globals, &install_global/1)
    Logger.warning("desktop: #{ok} of #{length(globals)} globals went back")
    ok > 0
  end

  defp install_global([key, value]) do
    case Session.call_named("desktop-global!", [key, value], nil, @install_timeout) do
      {:ok, _} ->
        true

      other ->
        Logger.warning("desktop: the global #{inspect(key)} did not install: #{inspect(other)}")
        false
    end
  catch
    :exit, reason ->
      Logger.warning("desktop: the global #{inspect(key)} did not install: #{inspect(reason)}")
      false
  end

  defp install_global(_), do: false

  # The buffers a window shows, any frame.
  # Rebuild these buffers' runtimes before the frames go back, in parallel
  # and on a budget. Each one runs on its own lane, so the cost is the
  # slowest buffer rather than their sum, and boot stays the 3s it became.
  # A buffer that does not make the budget -- a chat whose agent revival is
  # slow -- keeps its queued rebuild and, failing that, is made whole by
  # the first key pressed in it (editor.scm, key-binding-dispatch).
  defp restore_runtime_first([]), do: :ok

  defp restore_runtime_first(names) do
    names
    |> Task.async_stream(&Compos.Core.restore_runtime/1,
      max_concurrency: max(length(names), 1),
      timeout: @restore_first_budget,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, _} ->
        :ok

      {:exit, reason} ->
        Logger.warning(
          "desktop restore: a buffer's runtime did not rebuild before its frame " <>
            "(#{inspect(reason)}). Its queued rebuild stands, and the first key " <>
            "in it rebuilds it."
        )
    end)
  end

  defp shown_buffers do
    Editor.list_windows_all()
    |> Enum.map(fn {_win, name, _frame} -> name end)
    |> Enum.uniq()
  end

  # Every buffer the saved trees name. A leaf is `{:leaf, name, ...}`; a
  # split ends in its two children, whatever rides between.
  defp tree_buffers(%{frames: frames}) when is_list(frames),
    do:
      frames
      |> Enum.flat_map(fn f ->
        leaf_names(Map.get(f, :tree)) ++ Enum.flat_map(Map.get(f, :hidden, []), &leaf_names/1)
      end)
      |> Enum.uniq()

  defp tree_buffers(%{tree: tree}), do: tree |> leaf_names() |> Enum.uniq()
  defp tree_buffers(_), do: []

  defp leaf_names(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 2 do
    case elem(tuple, 0) do
      :leaf ->
        name = elem(tuple, 1)
        if is_binary(name), do: [name], else: []

      :split when tuple_size(tuple) >= 4 ->
        n = tuple_size(tuple)
        leaf_names(elem(tuple, n - 2)) ++ leaf_names(elem(tuple, n - 1))

      _ ->
        []
    end
  end

  defp leaf_names(_), do: []

  # A Session restart is not a boot: every buffer is already awake, and its
  # mode setup, minor modes and derived state went with the old interpreter.
  # So rebuild all of them, not only the ones a window shows, or a buffer
  # nobody is looking at comes back half-built and stays that way.
  #
  # An open prompt goes first. Its on_confirm and on_change are closures in
  # the dead environment, which Compos.Core.SchemeTables drops thirty
  # seconds later: pressing RET on that prompt then raises. A boot has no
  # prompt open, so neither does a restart.
  #
  # The sweep runs off this process: each buffer restores on its own lane,
  # and the desktop must stay free to answer a save while they do.
  defp rebuild_scheme_runtime(globals) do
    Enum.each(Editor.frame_list(), &Editor.minibuffer_close/1)

    buffers = Compos.Core.list_buffers()

    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      Enum.each(buffers, &Compos.Core.restore_runtime/1)

      # *Messages* is the editor's log, and a restart the reader did not ask
      # for belongs in it: the groups, the histories and every buffer's mode
      # just went away and came back.
      Session.message(
        "The Scheme world restarted. Restored #{length(buffers)} buffers and " <>
          "#{globals} globals.",
        "warn"
      )

      Logger.info("desktop: rebuilt the Scheme runtime of #{length(buffers)} buffers")
    end)
  end

  # --- restore ---------------------------------------------------------------

  defp do_restore(state) do
    with {:ok, bin} <- File.read(path()),
         %{} = desktop <- :erlang.binary_to_term(bin) do
      # Hold the file's globals before anything else can fail. A save that
      # runs next writes what this process holds, so the values must be
      # here even when the install below never happens.
      state = %{state | globals: desktop[:globals] || []}

      restore_world(desktop, state)
    else
      {:error, :enoent} -> {:ok, %{state | restore_pending?: false}}
      _ -> {:error, state}
    end
  rescue
    e ->
      Logger.warning("desktop restore failed: #{Exception.message(e)}")
      {:error, state}
  end

  # Everything here talks to the Editor and to the Session, and a boot that
  # wakes many buffers keeps both busy for longer than a call waits. A call
  # that gives up exits, an exit is not an exception, and the exit used to
  # take this process down with the globals it had just read still in a
  # local. The supervisor then started a process holding nothing, and the
  # next ordinary save wrote that nothing to disk.
  #
  # So catch the exit, keep the globals, and ask for the whole restore
  # again. The restore stays owed until one run finishes, and do_save
  # refuses to write while it is owed, so the file keeps the real state.
  defp restore_world(desktop, state) do
    # Every buffer a saved tree names comes back as a process first, with
    # its literal state and no runtime: the trees need live buffers, and a
    # mode setup reads the group records, which the globals below put
    # back. A boot wakes only these; the rest stay dormant and rebuild
    # when something wakes them.
    woken = tree_buffers(desktop)
    Enum.each(woken, &Compos.Core.ensure_buffer(&1, restore: false))

    # Runtime setup reads persisted policy. Group modelines, for example,
    # validate buffer membership against the durable group record table.
    # Restore globals before setup so valid IDs are not treated as dangling
    # and written back as empty buffer locals.
    #
    # An install that fails leaves the Scheme world empty, so mark it and
    # retry: a save must not copy that emptiness to disk.
    state = %{state | scheme_stale?: not install_globals(state.globals)}
    if state.scheme_stale?, do: Process.send_after(self(), :reseed, @reseed_retry)

    # ORDER, not a race. The frames used to go back first and every
    # runtime followed as a cast, so a buffer could be on screen, with its
    # text and its point, while its mode setup had not run: an empty local
    # map, no keys, no overlays. A chat whose RET fell through to the
    # global map is that, and it reads as "the restart lost chat-mode".
    #
    # The buffers the saved trees name are the ones that land on screen,
    # and tree_buffers already knows them before a frame exists. Make
    # those whole first; the frames then cannot show an unfinished buffer.
    restore_runtime_first(woken)

    restore_frames(desktop)

    # Whatever the frame rebuild put on screen that the trees did not name
    # -- a sealed group, a layout reflow, a frame that was already here --
    # follows on its own lane. These are not on screen yet when the wait
    # above runs, so they cannot be part of it.
    (shown_buffers() -- woken)
    |> Enum.uniq()
    |> Enum.each(&Compos.Core.restore_runtime_later/1)

    # Faces are not restored. themes.scm persists the theme NAME and
    # derives the faces at boot, so a theme edit applies on restart.
    # Replaying the saved face table put the previous session's colours
    # over the freshly derived theme.

    Session.message("Desktop restored")
    {:ok, %{state | restore_pending?: false}}
  catch
    :exit, reason ->
      Logger.warning(
        "desktop restore: the editor did not answer (#{inspect(reason)}). " <>
          "Holding the file's globals and trying again; nothing saves until it works."
      )

      Process.send_after(self(), :restore, @reseed_retry)
      {:error, state}
  end

  # v2: recreate every saved frame and lay its tree back; reversed so the
  # MRU head attaches last and ends up last-active. A browser that connected
  # before restore ran gets its same-id frame overwritten and re-renders.
  # v1 (single :tree key): one frame, restored into the default.
  defp restore_frames(%{frames: frames}) do
    for %{id: fid, tree: tree, active_buffer: active} = frame <- Enum.reverse(frames) do
      # no client: the frame waits for its tab to reconnect, and expires
      # on the editor's grace when none does
      {:ok, ^fid} = Editor.attach_frame(fid, client: nil)
      Editor.restore_tree(tree, active, fid)
      Editor.set_hidden_windows(Map.get(frame, :hidden, []), fid)
    end
  end

  defp restore_frames(%{tree: tree} = desktop),
    do: Editor.restore_tree(tree, desktop[:active_buffer])

  defp restore_frames(_), do: :ok
end
