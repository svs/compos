defmodule Compos.Core do
  @moduledoc "Facade for buffer management."

  alias Compos.Core.{Buffer, BufferStore}

  require Logger

  @registry Compos.Core.BufferRegistry
  @buffer_sup Compos.Core.BufferSupervisor
  @scratch "*scratch*"

  @doc "The compos home dir (config, keys, desktop). Tests point :home at a tmp dir."
  def home, do: Application.get_env(:compos_core, :home) || Path.expand("~/.compos")

  @doc """
  Where user config reads from: ai-config.scm, init.scm, custom.scm,
  theme.scm, secrets, key files. Defaults to `home/0`; COMPOS_CONFIG
  points a scratch daemon at the real config while its state (desktop,
  buffers, socket) stays in its own home.
  """
  def config_dir,
    do: Application.get_env(:compos_core, :config_dir) || home()

  @doc """
  The checkout this daemon runs from, or nil in a release.

  Mix links `_build/<env>/lib/compos_core/priv` to the checkout's
  `apps/compos_core/priv`, so the resolved priv path names the project
  root three directories up. A release copies priv and has no root.
  """
  def project_dir do
    priv = Compos.Core.Session.canonical(Application.app_dir(:compos_core, "priv"))

    case Enum.reverse(Path.split(priv)) do
      ["priv", "compos_core", "apps" | rest] when rest != [] ->
        rest |> Enum.reverse() |> Path.join()

      _ ->
        nil
    end
  end

  @doc """
  Start a buffer named NAME. A known name comes back through `wake/2`,
  with the options it was given; a new name starts empty, or from
  `text:` or `path:`.
  """
  def create_buffer(name, opts \\ []) do
    case wake(name, opts) do
      {:error, :not_found} -> start(name, opts)
      other -> other
    end
  end

  @doc """
  The one door a dormant buffer comes back through.

  A live buffer answers at once. A dormant buffer starts from its
  checkpoint and its log, and one Scheme call, `restore-buffer-runtime!`,
  is queued on the buffer's lane to rebuild what the files do not hold:
  the mode, the keys, the overlays, the folds. The call never waits, and
  it runs only while the buffer is still live. A caller that rebuilds the
  runtime itself, or puts the buffer back to sleep at once, passes
  `restore: false`. An unknown name is `{:error, :not_found}`.
  """
  def wake(name, opts \\ []) do
    cond do
      Buffer.exists?(name) ->
        {:ok, name}

      true ->
        case dormant_checkpoint(name) do
          nil -> {:error, :not_found}
          path -> start(name, Keyword.put(opts, :checkpoint, path))
        end
    end
  end

  # The checkpoint file of a known dormant buffer. A row can outlive its
  # file: the content is gone, and a name that errors forever wedges every
  # later create. Forget the row and start fresh.
  defp dormant_checkpoint(name) do
    case BufferStore.lookup(name) do
      %{id: id} ->
        path = BufferStore.checkpoint_path(id)

        if File.exists?(path) do
          path
        else
          Logger.warning("buffer #{name}: checkpoint file missing, starting fresh")
          BufferStore.forget(name)
          nil
        end

      _ ->
        nil
    end
  end

  defp start(name, opts) do
    {restore?, opts} = Keyword.pop(opts, :restore, true)

    case DynamicSupervisor.start_child(@buffer_sup, {Buffer, Keyword.put(opts, :name, name)}) do
      {:ok, _pid} ->
        if restore? and Keyword.has_key?(opts, :checkpoint), do: restore_runtime_on_wake(name)
        {:ok, name}

      {:error, {:already_started, _}} ->
        {:error, :already_exists}

      other ->
        other
    end
  end

  # A dormant buffer that wakes must be WHOLE before the caller goes on to
  # use it. The rebuild used to be a cast here too, so a wake returned a
  # buffer with its text, its point and its locals but no mode setup: an
  # empty local map and no keys until the cast ran. That is the same race
  # the desktop restore had, entered by a different door.
  #
  # ORDER it when the caller is Scheme. Inside a lane the rebuild runs
  # right here, in this process, before the wake returns -- no lane hop,
  # so no cross-lane wait and no way to block on ourselves.
  #
  # Outside a lane the caller is the Editor GenServer or a LiveView, and
  # a rebuild calls back into the Editor: waiting there would deadlock the
  # process we are waiting for. Those keep the cast, and every one of them
  # goes on to display through Scheme, which makes the buffer whole
  # itself (switch-to-buffer-here!, display-buffer-in-window!).
  @waking :compos_waking_buffer

  defp restore_runtime_on_wake(name) do
    # A rebuild can wake a buffer of its own -- a mode setup that opens its
    # list, a hook that visits a file. One level deep is ordered; deeper is
    # a cast, so a wake can never stand inside its own wake.
    if Compos.Core.Lane.current() && is_nil(Process.get(@waking)) do
      Process.put(@waking, name)

      try do
        case rebuild_runtime(name, Compos.Core.Frame.current()) do
          {:reply, {:error, msg}} ->
            require Logger
            Logger.warning("buffer #{name}: the runtime restore failed on wake: #{msg}")

          _ ->
            :ok
        end
      after
        Process.delete(@waking)
      end

      :ok
    else
      restore_runtime_later(name)
    end
  end

  # One buffer runtime rebuild runs at a time, whatever its lane. A mode
  # setup writes shared Scheme globals (*keymaps* above all) with a
  # read-modify-write. Two setups on two lanes each wrote the table from
  # their own copy, so after a boot a chat kept mode-name chat-mode and
  # lost its keys. The lock is re-entrant: a rebuild that wakes another
  # buffer runs that rebuild inside its own. A holder that dies releases
  # the lock. A wait that exceeds the bound runs the rebuild unlocked and
  # logs it, so the lock can never wedge a lane.
  @rebuild_lock :compos_runtime_rebuild
  @rebuild_wait_ms 30_000

  defp rebuild_runtime(name, fid) do
    with_rebuild_lock(name, fn ->
      Compos.Core.Session.exec_call_named("restore-buffer-runtime!", [name], fid)
    end)
  end

  defp with_rebuild_lock(name, fun) do
    depth = Process.get(@rebuild_lock, 0)

    cond do
      depth > 0 ->
        Process.put(@rebuild_lock, depth + 1)

        try do
          fun.()
        after
          Process.put(@rebuild_lock, depth)
        end

      acquire_rebuild_lock(System.monotonic_time(:millisecond) + @rebuild_wait_ms) ->
        Process.put(@rebuild_lock, 1)

        try do
          fun.()
        after
          Process.delete(@rebuild_lock)
          :global.del_lock({@rebuild_lock, self()}, [node()])
        end

      true ->
        require Logger

        Logger.warning(
          "buffer #{name}: another runtime rebuild held the lock for " <>
            "#{@rebuild_wait_ms}ms; this rebuild runs without it"
        )

        fun.()
    end
  end

  defp acquire_rebuild_lock(deadline) do
    cond do
      :global.set_lock({@rebuild_lock, self()}, [node()], 0) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(5) && acquire_rebuild_lock(deadline)
    end
  end

  @doc """
  Rebuild NAME's Scheme runtime on its own lane, without waiting. The
  frame in hand rides along, as it does for a synchronous call. The job
  skips a buffer that went back to sleep before its turn: a rebuild
  writes locals, and a write wakes.
  """
  def restore_runtime_later(name) do
    fid = Compos.Core.Frame.current()

    Compos.Core.Lane.cast(
      Compos.Core.Lane.for_buffer(name),
      fn _from ->
        if Buffer.exists?(name) do
          # a cast drops its reply: a failed restore must still say why,
          # or the buffer stays live with no keys and nothing names it
          case rebuild_runtime(name, fid) do
            {:reply, {:error, msg}} = reply ->
              require Logger
              Logger.warning("buffer #{name}: the runtime restore failed: #{msg}")
              reply

            reply ->
              reply
          end
        else
          {:reply, :asleep}
        end
      end,
      "call restore-buffer-runtime!"
    )

    :ok
  end

  @doc "Rebuild NAME's Scheme runtime on its own lane and wait for it."
  def restore_runtime(name) do
    # the buffer's own lane, with room for an agent revival: a 20s chat
    # restore on :ui froze every keystroke behind it
    fid = Compos.Core.Frame.current()

    case Compos.Core.Lane.run(
           Compos.Core.Lane.for_buffer(name),
           fn _from -> rebuild_runtime(name, fid) end,
           120_000,
           "call restore-buffer-runtime!"
         ) do
      {:error, msg} ->
        require Logger
        Logger.warning("buffer #{name}: the runtime restore failed: #{inspect(msg)}")

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Wait until every queued runtime rebuild of NAMES has run. A wake queues
  its rebuild and returns; a caller that must read the rebuilt runtime
  (a test, the desktop restore API) waits here, on each buffer's lane.
  """
  def await_restores(names) do
    Enum.each(names, fn name ->
      Compos.Core.Lane.run(
        Compos.Core.Lane.for_buffer(name),
        fn _from -> {:reply, :ok} end,
        120_000,
        "await restore-buffer-runtime!"
      )
    end)

    :ok
  end

  @doc """
  A live process for NAME: a live buffer as it is, a dormant one woken
  through `wake/2` (OPTS go to it), an unknown name created empty.
  """
  def ensure_buffer(name, opts \\ []) do
    if Buffer.exists?(name), do: {:ok, name}, else: create_buffer(name, opts)
  end

  @doc """
  Open a file into a buffer named after its path.

  `persistent: false` opens it for this session only: no checkpoint on
  disk, and no work at the next boot. A file over
  `large-file-warning-threshold` opens that way, because its text becomes
  a rope, a checkpoint, and a restore that every later boot pays for.

  `read: false` binds the buffer to the file without reading it, for a
  file whose viewer reads it from disk. See browser-file-mode.
  """
  def open_file(path, opts \\ []) do
    path = Path.expand(path)
    create_buffer(path, Keyword.merge([path: path], opts))
  end

  def list_buffers do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {name, pid} when is_binary(name) -> if Process.alive?(pid), do: [name], else: []
      _ -> []
    end)
  end

  def buffer_names, do: Enum.uniq(BufferStore.history() ++ list_buffers() ++ BufferStore.names())

  def checkpoint_all do
    Enum.each(list_buffers(), fn name ->
      try do
        Buffer.checkpoint_now(name)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  def kill_buffer(%Buffer.Ref{} = ref) do
    case Buffer.name(ref) do
      nil -> {:error, :not_found}
      name -> kill_buffer(name)
    end
  end

  def kill_buffer(name) do
    case live_pid(name) do
      [{pid, _}] ->
        # An editor always has somewhere live to land. In particular, a
        # bulk kill may remove *scratch* early and then remove the final
        # remaining buffer. release_buffer/1 used to fall back to the dead
        # scratch name in that case, so the next key reached a :noproc.
        # Keep the sole scratch process when it is itself last; otherwise
        # recreate scratch before releasing the last non-scratch buffer.
        # a minibuffer is no place to land: it does not count as live work
        last_live? =
          not Enum.any?(list_buffers(), &(&1 != name and not String.starts_with?(&1, " ")))

        cond do
          last_live? and name == @scratch ->
            :ok

          last_live? ->
            case ensure_buffer(@scratch) do
              {:ok, @scratch} -> do_kill_buffer(name, pid)
              {:error, :already_exists} -> do_kill_buffer(name, pid)
              error -> error
            end

          true ->
            do_kill_buffer(name, pid)
        end

      [] ->
        if BufferStore.known?(name), do: BufferStore.forget(name), else: {:error, :not_found}
    end
  end

  defp do_kill_buffer(name, pid) do
    # windows must never point at the dead: a later interaction with
    # a killed buffer crashes the Editor (taking the keymap with it)
    if Process.whereis(Compos.Core.Editor), do: Compos.Core.Editor.release_buffer(name)

    # llm-mode sessions intentionally outlive turns, but never their
    # owning buffer. Close through LLMSession so its callback closures
    # leave ETS together with the runtime.
    case Buffer.get_local(name, "llm-session-id") do
      id when is_binary(id) ->
        if Compos.Core.LLMSession.running?(id), do: Compos.Core.LLMSession.close(id)

      _ ->
        :ok
    end

    # Forget before the process goes. A write can reach the name while it
    # dies (a queued runtime rebuild, a late hook), and a write to a known
    # dormant name wakes it: the kill would resurrect the buffer from the
    # checkpoint it was about to bury. `discard` stops every checkpoint
    # write first, so nothing is written after the files move.
    :ok = Buffer.discard(name)
    BufferStore.forget(name)
    DynamicSupervisor.terminate_child(@buffer_sup, pid)
  end

  @doc """
  Put a live buffer back to dormancy: checkpoint it, stop its process, keep
  it known. The inverse of `ensure_buffer/1`. Refuses a buffer that is on
  screen, runs a process or agent, or is pinned: `sleep_refusal/2`, the
  guard the idle sweep reads too.
  """
  def sleep_buffer(name) do
    case live_pid(name) do
      [{pid, _}] ->
        case sleep_refusal(name, Buffer.eviction_info(name).locals) do
          nil ->
            :ok = Buffer.checkpoint_now(name)
            DynamicSupervisor.terminate_child(@buffer_sup, pid)

          reason ->
            {:error, reason}
        end

      [] ->
        if BufferStore.known?(name), do: :ok, else: {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc """
  NAME's live process as a registry entry, or []. The registry drops a
  dead process a moment after it goes; an entry for a dead pid is no
  process, and a call through the name would wake the buffer instead.
  """
  def live_pid(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] = entry -> if Process.alive?(pid), do: entry, else: []
      [] -> []
    end
  end

  @doc """
  Why NAME may not sleep now: `:displayed` (a window shows it), `:busy`
  (a process or an agent writes it) or `:pinned`; nil when it may. The
  one guard for `sleep_buffer/1` and for the idle sweep in
  `Compos.Core.BufferStore`. LOCALS are the buffer's locals.
  """
  def sleep_refusal(name, locals) do
    agent = locals["agent-slug"] || locals["chat-agent"]

    cond do
      displayed?(name) -> :displayed
      Compos.Core.Terminal.running?(name) -> :busy
      is_binary(agent) and Compos.Core.Agent.running?(agent) -> :busy
      locals["buffer-pinned"] not in [nil, false] -> :pinned
      true -> nil
    end
  end

  defp displayed?(name) do
    if Process.whereis(Compos.Core.Editor),
      do: Enum.any?(Compos.Core.Editor.list_windows_all(), fn {_win, b, _frame} -> b == name end),
      else: false
  end

  @doc """
  Rename a buffer in place, keeping its process and everything in it.

  The buffer keeps its text, point, mark, locals, overlays, undo history and
  attribution, because nothing moves: the process re-registers under the new
  name and rewrites its checkpoint. Scheme decides WHEN a buffer renames
  itself and what the new name says (`rename-buffer!`); this is the
  mechanism. A file buffer keeps its path — the file on disk does not move.
  """
  def rename_buffer(%Buffer.Ref{} = ref, new) do
    case Buffer.name(ref) do
      nil -> {:error, :no_buffer}
      old -> rename_buffer(old, new)
    end
  end

  def rename_buffer(old, new) when is_binary(old) and is_binary(new) do
    cond do
      old == new ->
        {:error, :same_name}

      new == "" ->
        {:error, :empty_name}

      Buffer.exists?(new) or BufferStore.known?(new) ->
        {:error, :already_exists}

      not (Buffer.exists?(old) or BufferStore.known?(old)) ->
        {:error, :no_buffer}

      true ->
        was_live = Buffer.exists?(old)

        with {:ok, ^old} <- ensure_buffer(old, restore: false),
             :ok <- Buffer.rename(old, new, Buffer.path(old)) do
          if Process.whereis(Compos.Core.Editor),
            do: Compos.Core.Editor.rename_buffer(old, new)

          # a dormant buffer woke for the rename; its runtime comes back
          # under the name it now has
          unless was_live, do: restore_runtime_later(new)
          {:ok, new}
        end
    end
  end

  @doc "Rename or move a file and carry its buffer identity and history with it."
  def rename_file(source, destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    known? = BufferStore.known?(source) or Buffer.exists?(source)
    was_live = Buffer.exists?(source)

    # the buffer wakes before the file moves: a buffer that cannot start
    # stops the rename, and the file stays where its buffer says it is
    with false <- source == destination,
         false <- File.exists?(destination),
         {:ok, _} <- if(known?, do: ensure_buffer(source, restore: false), else: {:ok, nil}),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.rename(source, destination) do
      if known? do
        path = Buffer.path(source)
        dired_dir = Buffer.get_local(source, "dired-dir")
        :ok = Buffer.rename(source, destination, if(path == source, do: destination, else: path))
        if dired_dir == source, do: Buffer.set_local(destination, "dired-dir", destination)

        if Process.whereis(Compos.Core.Editor),
          do: Compos.Core.Editor.rename_buffer(source, destination)

        unless was_live do
          [{pid, _}] = Registry.lookup(@registry, destination)
          DynamicSupervisor.terminate_child(@buffer_sup, pid)
        end
      end

      {:ok, destination}
    else
      true ->
        {:error, :already_exists}

      {:error, reason} ->
        # a buffer woken only for this rename goes back to sleep
        if known? and not was_live do
          case live_pid(source) do
            [{pid, _}] -> DynamicSupervisor.terminate_child(@buffer_sup, pid)
            [] -> :ok
          end
        end

        {:error, reason}
    end
  end
end
