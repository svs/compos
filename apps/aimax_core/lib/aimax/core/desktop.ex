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
    render = Editor.render_state()

    buffers =
      for name <- Aimax.Core.list_buffers(),
          Buffer.exists?(name),
          bpath = Buffer.path(name),
          bpath != nil do
        {bpath, Buffer.point(name)}
      end

    desktop = %{
      buffers: buffers,
      tree: serialize(render.tree),
      active_buffer: active_buffer(render.tree, render.active),
      faces: render.faces
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

  defp serialize(%{type: :leaf, buffer: b}), do: {:leaf, b}

  defp serialize(%{type: :split, dir: dir, children: [a, b]}),
    do: {:split, dir, serialize(a), serialize(b)}

  defp active_buffer(tree, active_id), do: find_buffer(tree, active_id)

  defp find_buffer(%{type: :leaf, id: id, buffer: b}, id), do: b
  defp find_buffer(%{type: :leaf}, _id), do: nil

  defp find_buffer(%{type: :split, children: c}, id),
    do: Enum.find_value(c, &find_buffer(&1, id))

  # --- restore ---------------------------------------------------------------

  defp do_restore do
    with {:ok, bin} <- File.read(path()),
         %{buffers: buffers, tree: tree} = desktop <- :erlang.binary_to_term(bin) do
      # reopen through visit so modes + hooks apply
      for {bpath, point} <- buffers, File.exists?(bpath) do
        Session.eval(~s{(visit "#{bpath}")})
        Buffer.goto(bpath, point)
      end

      Editor.restore_tree(tree, desktop[:active_buffer])

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
end
