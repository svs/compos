defmodule Aimax.Core.Watch do
  @moduledoc """
  One filesystem subscription per watched root, debounced, content-free.

  The event says which root changed and nothing else. Subscribers re-query:
  a diff buffer runs `git diff` again, a preview reloads its file. The
  producer therefore never grows when a new kind of subscriber appears.

  `watch/1` refcounts. Two buffers that watch the same repository share one
  subscription, and the subscription stops when the last one leaves.
  `Path.expand/1` normalizes the root, so `"."` and `"/abs/dir"` are the
  same watcher.

  A watch is shallow: only a change to a direct child of the root counts.
  fsevents reports the whole tree below the root, and a Dired buffer on
  the home directory must not refresh for every write under it. A diff
  buffer asks for `deep: true` and gets the whole repository.

  The Scheme handler runs at most once at a time per root. An event that
  arrives while a run is in flight marks the root pending, and the root
  runs once more when the run ends. The `:ui` lane therefore holds one
  handler job per root, never a queue of them.

  Policy lives in Scheme: `(watch-path! DIR)`, `(unwatch-path! DIR)`, and
  `(on-fs-change! FN)` in `priv/editor.scm`.
  """

  use GenServer

  require Logger

  alias Aimax.Core.{Events, Session}

  # 150 ms after the last event in a burst. An editor save is one burst; so
  # is an agent that writes twelve files.
  @debounce_ms 150

  # ...but a long write stream must not starve the refresh forever, so the
  # burst broadcasts at this age even while events keep arriving.
  @max_wait_ms 1_000

  @escaped :aimax_escaped_closures

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Watch `root`, or add a reference to the watch it already has. `deep: true`
  makes changes anywhere below the root count; the default counts only the
  root's direct children.
  """
  def watch(root, server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:watch, Path.expand(root), Keyword.get(opts, :deep, false)})

  @doc "Drop one reference, `deep: true` for a deep one. The subscription stops at zero."
  def unwatch(root, server \\ __MODULE__, opts \\ []),
    do: GenServer.call(server, {:unwatch, Path.expand(root), Keyword.get(opts, :deep, false)})

  @doc "The watched roots, sorted."
  def watching(server \\ __MODULE__), do: GenServer.call(server, :watching)

  @impl true
  def init(_opts) do
    # a FileSystem backend that dies must not take the watcher with it
    Process.flag(:trap_exit, true)
    {:ok, %{roots: %{}, pids: %{}}}
  end

  @impl true
  def handle_call({:watch, root, deep?}, _from, state) do
    case state.roots[root] do
      nil ->
        start_watch(root, deep?, state)

      entry ->
        entry = %{entry | count: entry.count + 1, deep: entry.deep + bit(deep?)}
        {:reply, {:ok, root}, put_entry(state, root, entry)}
    end
  end

  # The deep count can never exceed the reference count: a caller that
  # drops a deep reference without saying so still ends the deep watch
  # when the last reference leaves.
  def handle_call({:unwatch, root, deep?}, _from, state) do
    case state.roots[root] do
      nil ->
        {:reply, :ok, state}

      %{count: 1} = entry ->
        {:reply, :ok, stop_watch(state, root, entry)}

      entry ->
        count = entry.count - 1
        deep = min(max(entry.deep - bit(deep?), 0), count)
        {:reply, :ok, put_entry(state, root, %{entry | count: count, deep: deep})}
    end
  end

  def handle_call(:watching, _from, state), do: {:reply, Enum.sort(Map.keys(state.roots)), state}

  @impl true
  def handle_info({:file_event, pid, {path, _events}}, state) do
    with root when is_binary(root) <- state.pids[pid],
         entry when not is_nil(entry) <- state.roots[root],
         true <- relevant?(path),
         true <- entry.deep > 0 or direct_child?(path, root, entry.real) do
      {:noreply, put_entry(state, root, arm(entry, root))}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info({:fs_changed, root}, state) do
    case state.roots[root] do
      nil ->
        {:noreply, state}

      entry ->
        Events.broadcast_fs(root)
        entry = %{entry | timer: nil, burst_start: nil}

        entry =
          if entry.running,
            do: %{entry | pending: true},
            else: start_handler(entry, root)

        {:noreply, put_entry(state, root, entry)}
    end
  end

  # the handler run for a root ended: run once more if events came meanwhile
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.roots, fn {_root, entry} -> entry.running == ref end) do
      nil ->
        {:noreply, state}

      {root, entry} ->
        entry = %{entry | running: nil}
        entry = if entry.pending, do: start_handler(%{entry | pending: false}, root), else: entry
        {:noreply, put_entry(state, root, entry)}
    end
  end

  # the backend went away: forget the root rather than die with it
  def handle_info({:EXIT, pid, reason}, state) do
    case state.pids[pid] do
      nil ->
        {:noreply, state}

      root ->
        if reason != :normal do
          Logger.warning("Aimax.Core.Watch: the watcher for #{root} stopped: #{inspect(reason)}")
        end

        {:noreply,
         %{state | roots: Map.delete(state.roots, root), pids: Map.delete(state.pids, pid)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- subscriptions ---------------------------------------------------------

  # the seam: tests swap in a backend that sends nothing, so the debounce and
  # the .git filter are testable without fsevents' coalescing and lookback
  defp backend, do: Application.get_env(:aimax_core, :fs_backend, FileSystem)

  defp start_watch(root, deep?, state) do
    if File.dir?(root) do
      case backend().start_link(dirs: [root]) do
        {:ok, pid} ->
          backend().subscribe(pid)

          entry = %{
            pid: pid,
            real: realpath(root),
            count: 1,
            deep: bit(deep?),
            timer: nil,
            burst_start: nil,
            running: nil,
            pending: false
          }

          {:reply, {:ok, root},
           %{
             state
             | roots: Map.put(state.roots, root, entry),
               pids: Map.put(state.pids, pid, root)
           }}

        {:error, reason} ->
          {:reply, {:error, "cannot watch #{root}: #{inspect(reason)}"}, state}
      end
    else
      {:reply, {:error, "not a directory: #{root}"}, state}
    end
  end

  defp stop_watch(state, root, entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    if entry.running, do: Process.demonitor(entry.running, [:flush])
    if Process.alive?(entry.pid), do: GenServer.stop(entry.pid, :normal)

    %{state | roots: Map.delete(state.roots, root), pids: Map.delete(state.pids, entry.pid)}
  end

  defp put_entry(state, root, entry), do: %{state | roots: Map.put(state.roots, root, entry)}

  defp bit(true), do: 1
  defp bit(false), do: 0

  # The root itself, or a file or directory directly inside it. fsevents
  # names the path with every symlink resolved (`/private/tmp`, not
  # `/tmp`), so the root is known both ways.
  defp direct_child?(path, root, real) do
    parent = Path.dirname(path)
    path == root or path == real or parent == root or parent == real
  end

  # the path with every symlink in it resolved, as fsevents reports it
  defp realpath(path) do
    Enum.reduce(Path.split(path), "", fn part, acc ->
      here = if acc == "", do: part, else: Path.join(acc, part)

      case :file.read_link_all(here) do
        {:ok, target} -> Path.expand(to_string(target), acc)
        _ -> here
      end
    end)
  end

  # --- debounce --------------------------------------------------------------

  defp arm(entry, root) do
    now = System.monotonic_time(:millisecond)
    started = entry.burst_start || now

    if entry.timer, do: Process.cancel_timer(entry.timer)

    delay = min(@debounce_ms, max(0, started + @max_wait_ms - now))
    %{entry | timer: Process.send_after(self(), {:fs_changed, root}, delay), burst_start: started}
  end

  # git writes hundreds of object files per commit and none of them change
  # what a diff shows. The index, HEAD, and the refs do.
  defp relevant?(path) do
    parts = Path.split(path)

    case Enum.find_index(parts, &(&1 == ".git")) do
      nil ->
        true

      i ->
        case Enum.drop(parts, i + 1) do
          ["index" | _] -> true
          ["HEAD" | _] -> true
          ["refs" | _] -> true
          _ -> false
        end
    end
  end

  # --- the event -------------------------------------------------------------

  # Scheme handlers run in the Session, reached from a Task. Running them
  # here would block the watcher, and a handler that calls back into
  # `watch-path!` would deadlock it. The monitor on the Task is how the
  # root learns that the run ended.
  defp start_handler(entry, root) do
    with tid when tid != :undefined <- :ets.whereis(@escaped),
         [{_, handler}] <- :ets.lookup(tid, {:fs_handler}),
         {:ok, pid} <-
           Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
             Session.apply_callback(handler, [root])
           end) do
      %{entry | running: Process.monitor(pid)}
    else
      _ -> entry
    end
  end
end
