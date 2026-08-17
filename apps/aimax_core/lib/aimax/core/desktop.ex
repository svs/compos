defmodule Aimax.Core.Desktop do
  @moduledoc """
  Desktop save/restore owns presentation only: frames, window trees, faces,
  and declared Scheme globals. Buffer processes checkpoint and restore their
  own state independently.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Buffer, Editor, Events, Session}

  @debounce 1_500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path,
    do: Application.get_env(:aimax_core, :desktop_path, Path.expand("~/.aimax/desktop.etf"))

  @doc "Synchronous snapshot to disk (also used by tests)."
  def save_now, do: GenServer.call(__MODULE__, :save)

  @doc "Restore from disk over the current editor state."
  def restore_now, do: GenServer.call(__MODULE__, :restore, 30_000)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Events.subscribe_editor()
    if Application.get_env(:aimax_core, :desktop_autorestore, true), do: send(self(), :restore)
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_call(:save, _from, state) do
    {:reply, do_save(), state}
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
    do_save()
    {:noreply, %{state | timer: nil}}
  end

  def handle_info(:restore, state) do
    do_restore()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: do_save()

  # --- snapshot --------------------------------------------------------------

  defp do_save do
    # Synchronize presentation with the buffers' independently-owned durable
    # state. The desktop does not read or embed that state.
    Aimax.Core.checkpoint_all()

    # v2: every frame's layout, in frame-MRU order (head = most recent).
    # desktop_view is read-only (S15): saving must not run the render
    # walk, which writes viewport tops back into the tree.
    views = for fid <- Editor.frame_list(), do: {fid, Editor.desktop_view(fid)}

    frames =
      for {fid, view} <- views do
        %{id: fid, tree: serialize(view.tree), active_buffer: view.active_buffer}
      end

    desktop = %{
      version: 3,
      frames: frames,
      faces: views |> List.first({nil, %{faces: %{}}}) |> elem(1) |> Map.get(:faces),
      globals: scheme_globals()
    }

    file = path()
    Aimax.Core.BufferStore.atomic_write(file, :erlang.term_to_binary(desktop))
    :ok
  rescue
    e ->
      Logger.warning("desktop save failed: #{Exception.message(e)}")
      :error
  end

  # the leaf carries the per-window point and scroll state — saved so
  # each window reopens at its own spot, pinned if the reader pinned it
  defp serialize(%{type: :leaf, buffer: b} = leaf) do
    {:leaf, b, Map.get(leaf, :top, 0), Map.get(leaf, :point, 0), Map.get(leaf, :manual, false),
     Map.get(leaf, :ctop, 0)}
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
  defp scheme_globals do
    case Session.call_named("desktop-globals", []) do
      {:ok, globals} when is_list(globals) -> Enum.filter(globals, &serializable?/1)
      _ -> []
    end
  end

  # --- restore ---------------------------------------------------------------

  defp do_restore do
    with {:ok, bin} <- File.read(path()),
         %{} = desktop <- :erlang.binary_to_term(bin) do
      # v1/v2 migration only. Version 3 never stores buffer state here.
      buffers = desktop[:buffers] || []
      # reopen through visit so modes + hooks apply, then lay the saved
      # buffer-locals back on top so toggled state (preview, line numbers,
      # a hand-picked mode) survives too
      for entry <- buffers, bpath = elem(entry, 0) do
        {point, locals, text} =
          case entry do
            {_, point} -> {point, %{}, nil}
            {_, point, locals} -> {point, locals, nil}
            {_, point, locals, text} -> {point, locals, text}
          end

        # a vanished file with saved unsaved edits still restores: the
        # snapshot text is the only copy of that work. One buffer that
        # dies mid-restore must not abort the loop: every buffer after it
        # in the file — every chat — would be lost, and the next save
        # would write the crippled state over the desktop.
        try do
          if restorable?(bpath) or is_binary(text) do
            Session.call_named("visit", [bpath])
            # visit can decline (unreachable remote host) — skip, don't crash boot
            if Buffer.exists?(bpath) do
              # unsaved edits lay over what visit read. When a save landed
              # before the restart the texts match, nothing is replaced, and
              # the buffer stays clean. When the file moved on disk AND the
              # snapshot holds edits, the snapshot wins — it is the copy the
              # user watched leave their fingers.
              if is_binary(text) and text != Buffer.text(bpath) do
                size = Buffer.byte_size(bpath)

                if size > 0,
                  do: Buffer.delete_range(bpath, 0, size, source: :editor, author: :none)

                if text != "", do: Buffer.append(bpath, text, source: :editor, author: :none)
              end

              apply_saved_state(bpath, point, locals)
            end
          end
        catch
          kind, reason ->
            Logger.warning("desktop: skipped #{bpath}: #{inspect(kind)} #{inspect(reason)}")
        end
      end

      for {name, text, point, locals} <- desktop[:scratch] || [] do
        try do
          restore_scratch(name, text, point, locals)
        catch
          kind, reason ->
            Logger.warning("desktop: skipped #{name}: #{inspect(kind)} #{inspect(reason)}")
        end
      end

      restore_frames(desktop)

      # Waking installs literal buffer state. Runtime-only mode machinery is
      # rebuilt only after the Editor call has returned, avoiding a
      # Session -> Editor deadlock during tree construction.
      Editor.list_windows_all()
      |> Enum.map(fn {_win, name, _frame} -> name end)
      |> Enum.uniq()
      |> Enum.each(&Aimax.Core.restore_runtime/1)

      for {face, attrs} <- desktop[:faces] || %{} do
        Editor.set_face(face, attrs)
      end

      # Scheme globals last: nothing else in the restore reads them, and
      # they must land on top of whatever the stdlib set at load time
      case desktop[:globals] do
        nil -> :ok
        [] -> :ok
        globals -> Session.call_named("desktop-globals!", [globals])
      end

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

  # non-file buffer: content and locals go down first, THEN set-mode! —
  # the mode's setup fn rebuilds presentation (local keys, overlays,
  # folds) from the locals it finds on the buffer
  # remote buffers restore by re-fetching over ssh — (visit) does that;
  # a vanished local file is the only thing that drops a buffer
  defp restorable?(bpath),
    do: File.exists?(bpath) or String.starts_with?(bpath, "/ssh:")

  defp restore_scratch(name, text, point, locals) do
    unless Buffer.exists?(name), do: Aimax.Core.create_buffer(name)

    size = Buffer.byte_size(name)
    # :none — a restore is not an edit; the content stays unattributed
    if size > 0, do: Buffer.delete_range(name, 0, size, source: :editor, author: :none)
    if text != "", do: Buffer.append(name, text, source: :editor, author: :none)

    apply_saved_state(name, point, locals)
  end

  # ONE restore path for saved buffer state (S2, dup #27): the locals go
  # down first, THEN set-mode! runs unconditionally — every mode's setup
  # fn rebuilds presentation (local keys, overlays, folds) from the locals
  # it finds on the buffer. Minor modes rebuild the same way. Point goes
  # last: a setup fn is free to move it.
  defp apply_saved_state(name, point, locals) do
    Enum.each(locals, fn {k, v} -> Buffer.set_local(name, k, v) end)

    if mode = locals["mode-name"] do
      Session.call_named("desktop-apply-mode!", [name, mode])
    end

    if locals["minor-modes"] not in [nil, []] do
      Session.call_named("restore-minor-modes!", [name])
    end

    Buffer.goto(name, point)
  end
end
