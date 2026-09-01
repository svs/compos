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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path,
    do: Application.get_env(:compos_core, :desktop_path, Path.expand("~/.compos/desktop.etf"))

  @doc "Synchronous snapshot to disk (also used by tests)."
  def save_now, do: GenServer.call(__MODULE__, :save)

  @doc "Restore from disk over the current editor state."
  def restore_now, do: GenServer.call(__MODULE__, :restore, 30_000)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_editor()
    if Application.get_env(:compos_core, :desktop_autorestore, true), do: send(self(), :restore)
    {:ok, %{timer: nil, globals: []}}
  end

  @impl true
  def handle_call(:save, _from, state) do
    {result, state} = do_save(state)
    {:reply, result, state}
  end

  def handle_call(:restore, _from, state) do
    {:reply, do_restore(), state}
  end

  @impl true
  def handle_info({:editor_change, _}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, @debounce)}}
  end

  def handle_info(:flush, state) do
    {_result, state} = do_save(state)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:restore, state) do
    do_restore()
    {:noreply, state}
  end

  def handle_info({:seed_globals, globals}, state),
    do: {:noreply, %{state | globals: globals}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_save(state)
    :ok
  end

  # --- snapshot --------------------------------------------------------------

  # Presentation only. Each buffer owns its durable state and writes its own
  # checkpoint on a debounce after a change, so the desktop sweeps nothing.
  defp do_save(state) do
    # v2: every frame's layout, in frame-MRU order (head = most recent).
    # desktop_view is read-only (S15): saving must not run the render
    # walk, which writes viewport tops back into the tree.
    views = for fid <- Editor.frame_list(), do: {fid, Editor.desktop_view(fid)}

    frames =
      for {fid, view} <- views do
        %{id: fid, tree: serialize(view.tree), active_buffer: view.active_buffer}
      end

    globals = scheme_globals(state.globals)

    desktop = %{
      version: 3,
      frames: frames,
      globals: globals
    }

    file = path()
    rotate_backup(file)
    Compos.Core.BufferStore.atomic_write(file, :erlang.term_to_binary(desktop))
    {:ok, %{state | globals: globals}}
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
  defp scheme_globals(last) do
    case Session.call_named("desktop-globals", [], nil, @globals_timeout) do
      {:ok, globals} when is_list(globals) -> Enum.filter(globals, &serializable?/1)
      _ -> last
    end
  catch
    :exit, _ ->
      Logger.warning("desktop: Session busy, saved the previous globals")
      last
  end

  # --- restore ---------------------------------------------------------------

  defp do_restore do
    with {:ok, bin} <- File.read(path()),
         %{} = desktop <- :erlang.binary_to_term(bin) do
      restore_frames(desktop)

      # Runtime setup reads persisted policy. Group modelines, for example,
      # validate buffer membership against the durable group record table.
      # Restore globals before setup so valid IDs are not treated as dangling
      # and written back as empty buffer locals.
      case desktop[:globals] do
        nil -> :ok
        [] -> :ok
        globals -> Session.call_named("desktop-globals!", [globals])
      end

      # Waking installs literal buffer state. Runtime-only mode machinery is
      # rebuilt only after the Editor call has returned, avoiding a
      # Session -> Editor deadlock during tree construction.
      Editor.list_windows_all()
      |> Enum.map(fn {_win, name, _frame} -> name end)
      |> Enum.uniq()
      |> Enum.each(&Compos.Core.restore_runtime/1)

      # Faces are not restored. themes.scm persists the theme NAME and
      # derives the faces at boot, so a theme edit applies on restart.
      # Replaying the saved face table put the previous session's colours
      # over the freshly derived theme.

      # Seed the cache: a save that runs before the Session is free again
      # writes these back, not an empty list.
      send(self(), {:seed_globals, desktop[:globals] || []})

      Session.message("Desktop restored")
      :ok
    else
      {:error, :enoent} -> :ok
      _ -> :error
    end
  rescue
    e ->
      Logger.warning("desktop restore failed: #{Exception.message(e)}")
      :error
  end

  # v2: recreate every saved frame and lay its tree back; reversed so the
  # MRU head attaches last and ends up last-active. A browser that connected
  # before restore ran gets its same-id frame overwritten and re-renders.
  # v1 (single :tree key): one frame, restored into the default.
  defp restore_frames(%{frames: frames}) do
    for %{id: fid, tree: tree, active_buffer: active} <- Enum.reverse(frames) do
      {:ok, ^fid} = Editor.attach_frame(fid)
      Editor.restore_tree(tree, active, fid)
    end
  end

  defp restore_frames(%{tree: tree} = desktop),
    do: Editor.restore_tree(tree, desktop[:active_buffer])

  defp restore_frames(_), do: :ok
end
