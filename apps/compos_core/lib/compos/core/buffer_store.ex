defmodule Compos.Core.BufferStore do
  @moduledoc """
  The dormant half of the buffer store: the checkpoint directory, the
  MRU history, the idle sweep and the graveyard.

  A persistent buffer keeps two files. The checkpoint, `buffers/<id>.etf`,
  holds its identity, its facts, its locals, its folds and its recording
  policy. The log, `docs/<id>.loro`, holds its text and every change to
  it (`Compos.Core.BufferHistoryStore`). A buffer may therefore be known
  here without consuming a process.

  A checkpoint of version 1 carries the text as well; one of version 2
  carries it only when the log cannot answer for it. `migrate/1` rewrites
  the version 1 files once, at the first boot after the change, and only
  a file whose log holds the same text byte for byte.

  The read model of a dormant buffer is its row in `Compos.Core.BufferView`.
  This process writes those rows from the checkpoints at boot, and again
  when the view restarts; it keeps no copy of them. `catalog.etf` holds
  the MRU list of buffer names and nothing else.
  """

  use GenServer

  require Logger

  alias Compos.Core.{Buffer, BufferView}

  @catalog_version 1

  # A local this big or smaller is indexed with its buffer's row. The
  # ones above it (a chat's block index, a list's row cache) stay in the
  # checkpoint, and a reader that wants one pays for the file.
  @local_index_bytes 1024

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def dir, do: Path.join(Compos.Core.home(), "buffers")
  def catalog_path, do: Path.join(dir(), "catalog.etf")
  def checkpoint_path(id), do: Path.join(dir(), id <> ".etf")

  @doc "The row of a live or dormant buffer, or nil."
  def lookup(name) do
    case BufferView.fetch(name) do
      {:ok, row} -> row
      :error -> nil
    end
  end

  def lookup_id(id) do
    case BufferView.fetch(%Buffer.Ref{id: id}) do
      {:ok, row} -> row
      :error -> nil
    end
  end

  @doc "The checkpoint of NAME, read from its file, or nil."
  def load(name), do: GenServer.call(__MODULE__, {:load, name})
  def load_id(id), do: GenServer.call(__MODULE__, {:load_id, id})

  @doc "Whether NAME has a row: a live buffer, or a dormant one with a checkpoint."
  def known?(name), do: BufferView.has_row?(name)

  @doc """
  The dormant row of one checkpoint: the facts a list reads for a row it
  never opens, the locals small enough to index, and the names of the
  rest.
  """
  def row_of_checkpoint(%{id: id, name: name} = checkpoint) do
    locals = if is_map(checkpoint[:locals]), do: checkpoint[:locals], else: %{}

    dormant_row(%{
      name: name,
      id: id,
      path: checkpoint[:path],
      size: checkpoint[:size] || byte_size(checkpoint[:text] || ""),
      modified: checkpoint[:modified] || false,
      read_only: checkpoint[:read_only] || false,
      point: checkpoint[:point] || 0,
      mark: checkpoint[:mark],
      version: checkpoint[:buffer_version] || 0,
      locals: locals
    })
  end

  @doc """
  The dormant row a live row leaves behind when its buffer stops. Nil
  when the buffer wrote no checkpoint, or when it died with a change the
  checkpoint does not hold and the file cannot be read: the file is what
  a wake restores, so the row must say what the file says.
  """
  def row_of_view(%{id: id} = view) do
    path = checkpoint_path(id)

    cond do
      not File.exists?(path) ->
        nil

      Map.get(view, :dirty, false) ->
        case read_term(path) do
          %{id: ^id, name: _} = checkpoint -> row_of_checkpoint(checkpoint)
          _ -> nil
        end

      true ->
        dormant_row(%{
          name: view.name,
          id: id,
          path: view.path,
          size: view.size,
          modified: view.modified,
          read_only: view.read_only,
          point: view.point,
          mark: view.mark,
          version: view.version,
          locals: checkpoint_locals(view.locals, view.modified)
        })
    end
  end

  defp dormant_row(%{locals: locals} = facts) do
    facts
    |> Map.merge(%{
      live: false,
      persistent: true,
      locals: small_locals(locals),
      local_keys: Map.keys(locals)
    })
  end

  @doc "The locals small enough to index with their buffer's row."
  def small_locals(locals) do
    for {k, v} <- locals, :erlang.external_size(v) <= @local_index_bytes, into: %{}, do: {k, v}
  end

  # The auto-revert base is the text a buffer last agreed with its file on.
  # A clean buffer agrees with its file by definition, and waking re-seeds
  # the base from disk, so a checkpoint that carried it wrote the file into
  # the checkpoint a second time: 21.4 MB across 294 checkpoints here, and
  # 11.7 MB of that had drifted from the buffer's own text, so it described
  # nothing. Only a buffer with unsaved work keeps it, because there it is
  # the merge base and nothing on disk can rebuild it.
  @doc "The locals a checkpoint holds: the serializable ones the mode did not mark derived."
  def checkpoint_locals(locals, true), do: serializable_locals(locals)

  def checkpoint_locals(locals, false),
    do: locals |> Map.drop(["auto-revert-base"]) |> serializable_locals()

  defp serializable_locals(locals) do
    skip =
      case locals["desktop-skip-locals"] do
        list when is_list(list) -> Enum.map(list, &local_key/1)
        _ -> []
      end

    locals |> Map.drop(skip) |> Map.filter(fn {_k, v} -> serializable?(v) end)
  end

  defp local_key({:sym, key}), do: key
  defp local_key(key), do: to_string(key)

  @doc "Whether a term can go to disk: no fun, pid, reference or port anywhere in it."
  def serializable?(v) when is_function(v) or is_pid(v) or is_reference(v) or is_port(v),
    do: false

  def serializable?(v) when is_list(v), do: Enum.all?(v, &serializable?/1)
  def serializable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  def serializable?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> serializable?(k) and serializable?(val) end)

  def serializable?(_), do: true

  @doc "The names of the dormant buffers."
  def names, do: BufferView.dormant_names()
  def history, do: GenServer.call(__MODULE__, :history)
  def touch(name), do: GenServer.cast(__MODULE__, {:touch, name})
  def forget(name), do: GenServer.call(__MODULE__, {:forget, name})
  def renamed(old, new), do: GenServer.call(__MODULE__, {:renamed, old, new})

  @doc "Write the dormant rows again from the checkpoints; a live row is never touched."
  def reindex, do: GenServer.cast(__MODULE__, :reindex)

  def idle_expired(name, id, generation),
    do: GenServer.cast(__MODULE__, {:idle_expired, name, id, generation})

  @impl true
  def init(_) do
    File.mkdir_p!(dir())
    migrate(checkpoint_files())
    disk = scan_checkpoints()

    history =
      case read_term(catalog_path()) do
        %{version: @catalog_version, history: h} when is_list(h) -> h
        _ -> []
      end
      |> Enum.filter(&(&1 in disk))

    {:ok, %{history: history ++ (disk -- history)}}
  end

  @impl true
  def handle_call({:load, name}, _from, state), do: {:reply, load_row(lookup(name)), state}
  def handle_call({:load_id, id}, _from, state), do: {:reply, load_row(lookup_id(id)), state}
  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  def handle_call({:forget, name}, _from, state) do
    case lookup(name) do
      %{id: id} ->
        # A kill never erases. The checkpoint and the history log move to
        # the graveyard, and the burial line keeps the id -> name mapping
        # that recovery needs.
        entomb(id, name)

      _ ->
        :ok
    end

    BufferView.forget(name)
    state = %{state | history: List.delete(state.history, name)}
    persist_catalog(state)
    {:reply, :ok, state}
  end

  def handle_call({:renamed, old, new}, _from, state) do
    history = Enum.map(state.history, &if(&1 == old, do: new, else: &1))
    state = %{state | history: Enum.uniq(history)}
    persist_catalog(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:touch, name}, %{history: [name | _]} = state), do: {:noreply, state}

  def handle_cast({:touch, name}, state) do
    history = Enum.take([name | List.delete(state.history, name)], 500)
    state = %{state | history: history}
    persist_catalog(state)
    {:noreply, state}
  end

  def handle_cast(:reindex, state) do
    scan_checkpoints()
    {:noreply, state}
  end

  def handle_cast({:idle_expired, name, id, generation}, state) do
    if safe_to_evict?(name, id, generation) do
      # Never wait on a buffer from this process: the worker keeps this
      # process free to answer a load while the buffer checkpoints.
      Task.start(fn ->
        case Compos.Core.live_pid(name) do
          [{pid, _}] ->
            if Buffer.prepare_evict(name, generation),
              do: DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end

    {:noreply, state}
  end

  defp load_row(%{id: id}), do: read_term(checkpoint_path(id))
  defp load_row(_), do: nil

  # The idle timer fired for one generation of one buffer. The buffer must
  # still be that buffer, still idle, and free to sleep by the one guard.
  defp safe_to_evict?(name, id, generation) do
    case Compos.Core.live_pid(name) do
      [{_pid, _}] ->
        info = Buffer.eviction_info(name)

        info.id == id and info.idle_gen == generation and
          Compos.Core.sleep_refusal(name, info.locals) == nil

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  def graveyard_dir, do: Path.join(dir(), "dead")

  def graveyard_log, do: Path.join(dir(), "graveyard.log")

  @doc """
  Delete every graveyard entry (checkpoint and log) buried more than
  KEEP_DAYS ago, by file mtime. The burial line in `graveyard.log` stays,
  so the id -> name record outlives the bytes. Returns how many ids went.
  """
  def sweep_graveyard(keep_days) when is_integer(keep_days) and keep_days >= 0 do
    cutoff = System.os_time(:second) - keep_days * 86_400
    dead_logs = Path.join(Compos.Core.BufferHistoryStore.dir(), "dead")

    ids =
      Enum.uniq(
        ids_in(graveyard_dir(), ".etf") ++ ids_in(dead_logs, ".loro")
      )

    ids
    |> Enum.filter(fn id ->
      older?(Path.join(graveyard_dir(), id <> ".etf"), cutoff) and
        older?(Path.join(dead_logs, id <> ".loro"), cutoff)
    end)
    |> Enum.map(fn id ->
      File.rm(Path.join(graveyard_dir(), id <> ".etf"))
      File.rm(Path.join(dead_logs, id <> ".loro"))
    end)
    |> length()
  end

  @doc """
  Delete the history log of every dormant buffer whose checkpoint carries
  its text and whose mode opted out of recording: the text is a rendering
  of a record kept elsewhere, and the log repeats the checkpoint. Live
  buffers are left to their own process. The graveyard is swept the same
  way. Returns how many logs went.
  """
  def sweep_redundant_history do
    live =
      Compos.Core.list_buffers()
      |> Enum.map(&Buffer.id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    logs = Compos.Core.BufferHistoryStore.dir()

    sweep_pairs(dir(), logs, live) +
      sweep_pairs(graveyard_dir(), Path.join(logs, "dead"), MapSet.new())
  end

  defp sweep_pairs(checkpoints, logs, live) do
    checkpoints
    |> ids_in(".etf")
    |> Enum.reject(&MapSet.member?(live, &1))
    |> Enum.filter(fn id ->
      File.exists?(Path.join(logs, id <> ".loro")) and
        redundant_log?(Path.join(checkpoints, id <> ".etf"))
    end)
    |> Enum.map(&File.rm(Path.join(logs, &1 <> ".loro")))
    |> length()
  end

  # text in the checkpoint, recording off by a mode's policy. A user's own
  # stop keeps its log: provenance-start bridges the gap from it.
  defp redundant_log?(checkpoint) do
    case File.read(checkpoint) do
      {:ok, bytes} ->
        cp = :erlang.binary_to_term(bytes)

        is_map(cp) and is_binary(cp[:text]) and
          match?(%{enabled: false, policy_source: "mode"}, cp[:provenance])

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp ids_in(directory, ext) do
    case File.ls(directory) do
      {:ok, files} ->
        for f <- files, String.ends_with?(f, ext), do: Path.basename(f, ext)

      _ ->
        []
    end
  end

  # a missing file is as old as can be
  defp older?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime <= cutoff
      _ -> true
    end
  end

  defp entomb(id, name) do
    src = checkpoint_path(id)

    moved_checkpoint =
      if File.exists?(src) do
        File.mkdir_p!(graveyard_dir())
        File.rename(src, Path.join(graveyard_dir(), id <> ".etf")) == :ok
      else
        false
      end

    moved_log = Compos.Core.BufferHistoryStore.entomb(id)

    if moved_checkpoint or moved_log do
      line = "#{DateTime.to_iso8601(DateTime.utc_now())} #{id} #{name}\n"
      File.write(graveyard_log(), line, [:append])
    end

    :ok
  rescue
    e ->
      Logger.warning("could not entomb #{name}: #{Exception.message(e)}")
      :ok
  end

  defp checkpoint_files do
    Path.wildcard(Path.join(dir(), "*.etf")) |> Enum.reject(&(&1 == catalog_path()))
  end

  @migrated_marker ".checkpoints-v2"

  @doc """
  The one-shot migration of a home to version 2 checkpoints: once, at the
  first boot after the change. A version 1 file is rewritten without its
  text only when its log holds the same text byte for byte and the buffer
  records; every other file is left as it is, and reads as before. The
  marker file in the directory says the pass ran.
  """
  def migrate(paths) do
    marker = Path.join(dir(), @migrated_marker)

    unless File.exists?(marker) do
      done = Enum.count(paths, &migrate_checkpoint/1)
      Logger.info("buffer store: #{done} of #{length(paths)} checkpoints now keep their text in the log")
      File.write(marker, "checkpoints are version 2 since #{DateTime.to_iso8601(DateTime.utc_now())}\n")
    end

    :ok
  rescue
    e ->
      Logger.warning("buffer store: the checkpoint migration stopped: #{Exception.message(e)}")
      :ok
  end

  defp migrate_checkpoint(path) do
    case read_term(path) do
      %{version: 1, id: id, text: text} = cp when is_binary(id) and is_binary(text) ->
        recording? =
          case cp[:provenance] do
            %{enabled: false} -> false
            _ -> true
          end

        log_text =
          case recording? and Compos.Core.BufferHistoryStore.load(id) do
            %Compos.Core.BufferHistory{} = weave -> Compos.Core.BufferHistory.text(weave)
            _ -> nil
          end

        if log_text == text do
          rewritten = cp |> Map.delete(:text) |> Map.merge(%{version: 2, size: byte_size(text)})
          atomic_write(path, :erlang.term_to_binary(rewritten))
          true
        else
          false
        end

      _ ->
        false
    end
  rescue
    e ->
      Logger.warning("buffer store: #{Path.basename(path)} was not migrated: #{Exception.message(e)}")
      false
  end

  # Every checkpoint in the directory becomes a dormant row, unless its
  # name already has one (a live buffer). Answers the names it found.
  defp scan_checkpoints do
    checkpoint_files()
    |> Enum.flat_map(fn path ->
      case read_term(path) do
        %{version: v, id: id, name: name} = checkpoint
        when v in [1, 2] and is_binary(id) and is_binary(name) ->
          if String.starts_with?(name, " ") do
            []
          else
            BufferView.put_new(row_of_checkpoint(checkpoint))
            [name]
          end

        _ ->
          []
      end
    end)
  end

  defp read_term(path) do
    with {:ok, bin} <- File.read(path) do
      :erlang.binary_to_term(bin)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp persist_catalog(state) do
    atomic_write(
      catalog_path(),
      :erlang.term_to_binary(%{version: @catalog_version, history: state.history})
    )
  rescue
    e -> Logger.warning("buffer catalog save failed: #{Exception.message(e)}")
  end

  def atomic_write(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, bytes, [:binary])
    File.rename!(tmp, path)
    :ok
  end
end
