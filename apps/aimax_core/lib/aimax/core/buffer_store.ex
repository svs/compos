defmodule Aimax.Core.BufferStore do
  @moduledoc """
  Durable buffer catalog.

  Buffer contents belong to the buffer checkpoint in `buffers/`; this process
  only indexes those checkpoints and keeps the cross-process MRU history. A
  buffer may therefore be present here without consuming a process.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Buffer, Editor, Proc}

  @catalog_version 1

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def dir, do: Path.join(Aimax.Core.home(), "buffers")
  def catalog_path, do: Path.join(dir(), "catalog.etf")
  def checkpoint_path(id), do: Path.join(dir(), id <> ".etf")

  def lookup(name), do: GenServer.call(__MODULE__, {:lookup, name})
  def load(name), do: GenServer.call(__MODULE__, {:load, name})
  def known?(name), do: GenServer.call(__MODULE__, {:known?, name})
  def names, do: GenServer.call(__MODULE__, :names)
  def history, do: GenServer.call(__MODULE__, :history)
  def note(meta), do: GenServer.call(__MODULE__, {:note, meta})
  def touch(name), do: GenServer.cast(__MODULE__, {:touch, name})
  def forget(name), do: GenServer.call(__MODULE__, {:forget, name})
  def renamed(old, meta), do: GenServer.call(__MODULE__, {:renamed, old, meta})

  def idle_expired(name, id, generation),
    do: GenServer.cast(__MODULE__, {:idle_expired, name, id, generation})

  @impl true
  def init(_) do
    File.mkdir_p!(dir())
    disk = scan_checkpoints()

    history =
      case read_term(catalog_path()) do
        %{version: @catalog_version, history: h} when is_list(h) -> h
        _ -> []
      end
      |> Enum.filter(&Map.has_key?(disk, &1))

    {:ok, %{entries: disk, history: history ++ (Map.keys(disk) -- history)}}
  end

  @impl true
  def handle_call({:lookup, name}, _from, state), do: {:reply, state.entries[name], state}

  def handle_call({:load, name}, _from, state) do
    value =
      case state.entries[name] do
        %{checkpoint: path} -> read_term(path)
        _ -> nil
      end

    {:reply, value, state}
  end

  def handle_call({:known?, name}, _from, state),
    do: {:reply, Map.has_key?(state.entries, name), state}

  def handle_call(:names, _from, state), do: {:reply, Map.keys(state.entries), state}
  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  def handle_call({:note, meta}, _from, state) do
    state = %{state | entries: Map.put(state.entries, meta.name, meta)}
    persist_catalog(state)
    {:reply, :ok, state}
  end

  def handle_call({:forget, name}, _from, state) do
    case state.entries[name] do
      %{id: id} -> File.rm(checkpoint_path(id))
      _ -> :ok
    end

    state = %{
      state
      | entries: Map.delete(state.entries, name),
        history: List.delete(state.history, name)
    }

    persist_catalog(state)
    {:reply, :ok, state}
  end

  def handle_call({:renamed, old, meta}, _from, state) do
    entries = state.entries |> Map.delete(old) |> Map.put(meta.name, meta)
    history = Enum.map(state.history, &if(&1 == old, do: meta.name, else: &1))
    state = %{state | entries: entries, history: Enum.uniq(history)}
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

  def handle_cast({:idle_expired, name, id, generation}, state) do
    if safe_to_evict?(name, id, generation) do
      # Never wait on a buffer from the catalog process: checkpointing calls
      # back here to publish its metadata. The worker preserves that ordering
      # and leaves the catalog free to receive the note.
      Task.start(fn ->
        case Registry.lookup(Aimax.Core.BufferRegistry, name) do
          [{pid, _}] ->
            if Buffer.prepare_evict(name, generation),
              do: DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)

          [] ->
            :ok
        end
      end)
    end

    {:noreply, state}
  end

  defp safe_to_evict?(name, id, generation) do
    displayed =
      if Process.whereis(Editor),
        do: Enum.any?(Editor.list_windows_all(), fn {_win, b, _frame} -> b == name end),
        else: false

    active_process = Proc.running?(name)

    case Registry.lookup(Aimax.Core.BufferRegistry, name) do
      [{_pid, _}] ->
        info = Buffer.eviction_info(name)
        agent = info.locals["agent-slug"] || info.locals["chat-agent"]
        pinned = info.locals["buffer-pinned"] not in [nil, false]
        active_agent = is_binary(agent) and Aimax.Core.Agent.running?(agent)

        info.id == id and info.idle_gen == generation and not displayed and not active_process and
          not active_agent and not pinned

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end

  defp scan_checkpoints do
    Path.wildcard(Path.join(dir(), "*.etf"))
    |> Enum.reject(&(&1 == catalog_path()))
    |> Enum.reduce(%{}, fn path, acc ->
      case read_term(path) do
        %{version: 1, id: id, name: name} = checkpoint when is_binary(id) and is_binary(name) ->
          if String.starts_with?(name, " "),
            do: acc,
            else:
              Map.put(acc, name, %{id: id, name: name, path: checkpoint[:path], checkpoint: path})

        _ ->
          acc
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
