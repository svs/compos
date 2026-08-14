defmodule Aimax.Core.Desktop do
  @moduledoc """
  Desktop save/restore (Emacs desktop-mode): the editor survives daemon
  restarts. Persists file-backed buffers (path + point), the window tree,
  and faces (theme) to `~/.aimax/desktop.etf` — debounced on editor events,
  flushed on shutdown, restored at boot.

  Restore reopens files through Scheme `(visit ...)` so modes and
  find-file-hook apply, then rebuilds the window tree and points.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Buffer, Editor, Events, Session}

  @debounce 1_500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path, do: Application.get_env(:aimax_core, :desktop_path, Path.expand("~/.aimax/desktop.etf"))

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
    buffers =
      for name <- Aimax.Core.list_buffers(),
          Buffer.exists?(name),
          bpath = Buffer.path(name),
          bpath != nil do
        {bpath, Buffer.point(name), savable_locals(name)}
      end

    # the rule: EVERYTHING survives a reload. Non-file buffers (chat, agent
    # threads, scratch, shells) have no file to reopen — their content is the
    # only source of truth, so it's saved along with point and locals.
    # Space-prefixed names are internal (Emacs convention: " *minibuf*").
    # Buffers with a truthy 'transient local (mail views, listings) hold
    # derived state their mode setup re-renders from locals — name, point,
    # and locals are saved so windows and modes restore, content is not.
    scratch =
      for name <- Aimax.Core.list_buffers(),
          Buffer.exists?(name),
          Buffer.path(name) == nil,
          not String.starts_with?(name, " ") do
        content = if Buffer.get_local(name, "transient"), do: "", else: Buffer.text(name)
        {name, content, Buffer.point(name), savable_locals(name)}
      end

    # v2: every frame's layout, in frame-MRU order (head = most recent).
    # desktop_view is read-only (S15): saving must not run the render
    # walk, which writes viewport tops back into the tree.
    views = for fid <- Editor.frame_list(), do: {fid, Editor.desktop_view(fid)}

    frames =
      for {fid, view} <- views do
        %{id: fid, tree: serialize(view.tree), active_buffer: view.active_buffer}
      end

    desktop = %{
      version: 2,
      buffers: buffers,
      scratch: scratch,
      frames: frames,
      faces: views |> List.first({nil, %{faces: %{}}}) |> elem(1) |> Map.get(:faces)
    }

    file = path()
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, :erlang.term_to_binary(desktop))
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

  # everything Scheme put on the buffer, minus values that can't survive
  # a daemon restart (closures, pids, refs)
  defp savable_locals(name) do
    name |> Buffer.locals() |> Map.filter(fn {_k, v} -> serializable?(v) end)
  end

  defp serializable?(v) when is_function(v) or is_pid(v) or is_reference(v) or is_port(v),
    do: false

  defp serializable?(v) when is_list(v), do: Enum.all?(v, &serializable?/1)
  defp serializable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> serializable?(k) and serializable?(val) end)

  defp serializable?(_), do: true

  # --- restore ---------------------------------------------------------------

  defp do_restore do
    with {:ok, bin} <- File.read(path()),
         %{buffers: buffers} = desktop <- :erlang.binary_to_term(bin) do
      # reopen through visit so modes + hooks apply, then lay the saved
      # buffer-locals back on top so toggled state (preview, line numbers,
      # a hand-picked mode) survives too
      for entry <- buffers, bpath = elem(entry, 0), restorable?(bpath) do
        {point, locals} =
          case entry do
            {_, point} -> {point, %{}}
            {_, point, locals} -> {point, locals}
          end

        Session.call_named("visit", [bpath])
        # visit can decline (unreachable remote host) — skip, don't crash boot
        if Buffer.exists?(bpath) do
          apply_saved_state(bpath, point, locals)
        end
      end

      for {name, text, point, locals} <- desktop[:scratch] || [] do
        restore_scratch(name, text, point, locals)
      end

      restore_frames(desktop)

      for {face, attrs} <- desktop[:faces] || %{} do
        Editor.set_face(face, attrs)
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
    if size > 0, do: Buffer.delete_range(name, 0, size, source: :editor)
    if text != "", do: Buffer.append(name, text, source: :editor)

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
