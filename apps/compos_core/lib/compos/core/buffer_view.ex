defmodule Compos.Core.BufferView do
  @moduledoc """
  The buffer read model: one public ETS row per live buffer, holding what a
  reader needs and no process to ask for it.

  The buffer process owns its row and is the only writer. Every other
  process reads the row directly, so a render never queues behind a
  reparse, a checkpoint, or a save in the buffer that it draws. Before
  this, `Compos.Core.Editor` called each visible buffer from inside its own
  `handle_call`, which made one busy buffer stall every client.

  This process owns the TABLE and nothing else. It creates the table and it
  deletes the row of a buffer that dies. It runs no buffer code and holds no
  buffer state, so a buffer crash cannot take the read model with it.

  A row holds the rope handle, not the flattened text. The rope is an
  immutable Rustler resource: every edit returns a new handle, so a reader
  may hold one and call the NIF while the writer edits on. The reader
  flattens the bytes in its OWN process, which moves that O(n) copy off the
  serial path. The writer publishes `bin` as well whenever it already holds
  the flattened text, and `text/1` takes it when it is there.

  A name with no row is not an error. The reader falls back to the buffer
  process, and then to the checkpoint of a dormant buffer, exactly as
  before. The row is an accelerator, never the only answer.
  """

  use GenServer

  alias Compos.Core.Buffer.Ref
  alias Compos.Core.Rope

  @table :compos_buffer_view

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The read model table."
  def table, do: @table

  @doc """
  Watch PID so its row goes when it does. A buffer calls this once, from
  `init`; `terminate` also forgets the row, and this covers the kill that
  runs no `terminate`.
  """
  def track(pid, name), do: GenServer.cast(__MODULE__, {:track, pid, name})

  @doc "Drop NAME's row. The rename path calls this for the name it leaves."
  def forget(name) do
    case lookup(name) do
      [{^name, %{id: id}}] -> :ets.delete(@table, {:id, id})
      _ -> :ok
    end

    :ets.delete(@table, name)
    :ok
  rescue
    # the table is gone (see `lookup/1`) — there is no row to drop
    ArgumentError -> :ok
  end

  @doc "Publish VIEW under its own name, and under its id for `Ref` readers."
  def put(%{name: name, id: id} = view) do
    :ets.insert(@table, [{name, view}, {{:id, id}, name}])
    :ok
  rescue
    # A publish runs inside a buffer callback. If this process died and took
    # the table with it, the buffer must carry on and let its readers fall
    # back to calling it. The rows return when this process restarts.
    ArgumentError -> :ok
  end

  @doc "VIEW for a name or a `Ref`. `:error` when the buffer has no row."
  def fetch(%Ref{id: id}) do
    case lookup({:id, id}) do
      [{_, name}] -> fetch(name)
      [] -> :error
    end
  end

  def fetch(name) when is_binary(name) do
    case lookup(name) do
      [{^name, view}] -> {:ok, view}
      [] -> :error
    end
  end

  def fetch(_), do: :error

  # A read against a table that does not exist raises. That happens only
  # between this process dying and its supervisor restarting it, and the
  # honest answer in that window is "no row", not a crash in the reader.
  defp lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  @doc "One field of a buffer's view, or nil when it has no row."
  def get(name, key) do
    case fetch(name) do
      {:ok, view} -> Map.get(view, key)
      :error -> nil
    end
  end

  @doc """
  The buffer text. The writer's flattened copy when it published one,
  otherwise flattened here, in the calling process.
  """
  def text(%{bin: bin}) when is_binary(bin), do: bin
  def text(%{rope: rope}), do: Rope.to_binary(rope)

  @doc """
  Every tag's overlay ranges, as one list.

  The row holds the per-tag map, because that is what the buffer already
  has. Flattening it belongs to the reader: an edit adjusts every range,
  so a writer that flattened would pay per keystroke for a shape only a
  render wants.
  """
  def overlays(%{overlays: by_tag}), do: by_tag |> Map.values() |> Enum.concat()

  @doc "Every tag's folded lines, as one sorted list."
  def hidden(%{hidden: by_tag}), do: by_tag |> Map.values() |> Enum.concat() |> Enum.sort()

  @doc """
  The render payload for one window, or nil when the buffer has no row.

  Same shape as `Buffer.render_snapshot/2`, computed from the row. The
  geometry is the WINDOW's: a stored per-window point wins over the buffer
  point, and it is clamped on read because undo swaps a whole rope under
  stored positions.
  """
  def snapshot(name, win_id \\ nil) do
    case fetch(name) do
      {:ok, view} -> snapshot_of(view, win_id)
      :error -> nil
    end
  end

  @doc "The render payload for a view already in hand."
  def snapshot_of(view, win_id) do
    {point, mark} =
      case win_id && view.win_points[win_id] do
        %{point: p, mark: m} -> {clamp(p, view.size), m && clamp(m, view.size)}
        _ -> {view.point, view.mark}
      end

    cursor_line = Rope.byte_to_line(view.rope, point)

    %{
      text: text(view),
      point: point,
      mark: mark,
      version: view.version,
      modified: view.modified,
      locals: view.locals,
      overlays: overlays(view),
      overlay_gen: view.overlay_gen,
      hidden: hidden(view),
      # A hot-loaded daemon can still hold rows published under the first
      # display-range name. Preserve that narrowing until the owner republishes.
      narrow_range: Map.get(view, :narrow_range, Map.get(view, :display_range)),
      path: view.path,
      read_only: view.read_only,
      total_lines: Rope.line_count(view.rope),
      cursor_line: cursor_line,
      line: cursor_line + 1,
      col: point - Rope.line_to_byte(view.rope, cursor_line)
    }
  end

  defp clamp(pos, size), do: pos |> max(0) |> min(size)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # A restart starts with an empty table and an empty watch list, and a
    # buffer only publishes when something about it changes. Adopt every live
    # buffer now: ask it to republish, and watch it again. Otherwise the model
    # heals one edit at a time, and the buffers that died meanwhile leave rows
    # nobody deletes.
    watched =
      Compos.Core.BufferRegistry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.reduce(%{}, fn {key, pid}, acc ->
        name = if is_binary(key), do: key, else: Map.get(acc, pid)
        send(pid, :republish_view)

        if Map.has_key?(acc, pid) do
          Map.put(acc, pid, name || acc[pid])
        else
          Process.monitor(pid)
          Map.put(acc, pid, name)
        end
      end)

    {:ok, watched}
  end

  @impl true
  def handle_cast({:track, pid, name}, watched) do
    if Map.has_key?(watched, pid) do
      {:noreply, watched}
    else
      Process.monitor(pid)
      {:noreply, Map.put(watched, pid, name)}
    end
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, _reason}, watched) do
    {name, watched} = Map.pop(watched, pid)

    # A rename moved the row under a new name while we still hold the old
    # one. Forget the name the row itself claims, so a rename cannot strand
    # a row, and a dead buffer cannot delete the row of the live buffer that
    # took its old name.
    if name do
      case :ets.lookup(@table, name) do
        [{^name, %{name: current}}] -> forget(current)
        _ -> forget(name)
      end
    end

    {:noreply, watched}
  end

  def handle_info(_, watched), do: {:noreply, watched}
end
