defmodule Aimax.Core do
  @moduledoc "Facade for buffer management."

  alias Aimax.Core.{Buffer, BufferStore}

  require Logger

  @registry Aimax.Core.BufferRegistry
  @buffer_sup Aimax.Core.BufferSupervisor
  @scratch "*scratch*"

  @doc "The aimax home dir (config, keys, desktop). Tests point :home at a tmp dir."
  def home, do: Application.get_env(:aimax_core, :home) || Path.expand("~/.aimax")

  @doc """
  Where user config reads from: ai-config.scm, init.scm, custom.scm,
  theme.scm, secrets, key files. Defaults to `home/0`; AIMAX_CONFIG
  points a scratch daemon at the real config while its state (desktop,
  buffers, socket) stays in its own home.
  """
  def config_dir,
    do: Application.get_env(:aimax_core, :config_dir) || home()

  def create_buffer(name, opts \\ []) do
    restored = BufferStore.lookup(name)

    # A catalog row can outlive its checkpoint file. The content is gone,
    # and a name that errors forever wedges every later create. Forget the
    # stale row and start fresh.
    restored =
      if restored && not File.exists?(restored.checkpoint) do
        Logger.warning("buffer #{name}: checkpoint file missing, starting fresh")
        BufferStore.forget(name)
        nil
      else
        restored
      end

    opts = if restored, do: Keyword.put_new(opts, :checkpoint, restored.checkpoint), else: opts

    case DynamicSupervisor.start_child(@buffer_sup, {Buffer, Keyword.put(opts, :name, name)}) do
      {:ok, _pid} ->
        # An Editor handler cannot call Session: mode setup can install
        # local keys by calling back into Editor. Its public caller finishes
        # restoration after the Editor call returns. Every other wake is
        # synchronous, so nobody observes a half-restored buffer.
        # `Process.whereis(Session)` answered yes too early: GenServer
        # registers the name before init/1 runs, so Session's own
        # create_buffer("*Messages*") asked its own init to restore a
        # runtime. The lane worker then waited on :await_boot, Session was
        # still inside init, and every boot paid a fixed 60s timeout. Ask
        # whether the interpreter is ready, which is what this guard means.
        if restored && Aimax.Core.Session.ready?() do
          cond do
            self() == Process.whereis(Aimax.Core.Editor) ->
              :ok

            # Scheme evaluates in a Lane worker now, not inside Session, so
            # asking for the Session pid here answered no forever: a wake
            # driven by Scheme fell through to the synchronous restore and
            # called back into the lane it was already running on. Ask the
            # question the code means — am I inside an eval? — and let
            # switch-to-buffer! say when it owns the restore itself.
            Registry.keys(Aimax.Core.LaneRegistry, self()) != [] ->
              unless Process.get(:aimax_inline_runtime_restore, false),
                do: restore_runtime_later(name)

            true ->
              restore_runtime(name)
          end
        end

        {:ok, name}

      {:error, {:already_started, _}} ->
        {:error, :already_exists}

      other ->
        other
    end
  end

  defp restore_runtime_later(name) do
    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn -> restore_runtime(name) end)
  end

  def restore_runtime(name) do
    # the buffer's own lane, with room for an agent revival: a 20s chat
    # restore on :ui froze every keystroke behind it
    Aimax.Core.Session.call_named(
      "restore-buffer-runtime!",
      [name],
      nil,
      120_000,
      Aimax.Core.Lane.for_buffer(name)
    )

    :ok
  end

  @doc "Ensure a live process exists for a live or dormant buffer."
  def ensure_buffer(name) do
    if Buffer.exists?(name), do: {:ok, name}, else: create_buffer(name)
  end

  @doc "Open a file into a buffer named after its path."
  def open_file(path) do
    path = Path.expand(path)
    create_buffer(path, path: path)
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
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        # An editor always has somewhere live to land. In particular, a
        # bulk kill may remove *scratch* early and then remove the final
        # remaining buffer. release_buffer/1 used to fall back to the dead
        # scratch name in that case, so the next key reached a :noproc.
        # Keep the sole scratch process when it is itself last; otherwise
        # recreate scratch before releasing the last non-scratch buffer.
        last_live? = not Enum.any?(list_buffers(), &(&1 != name))

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
    if Process.whereis(Aimax.Core.Editor), do: Aimax.Core.Editor.release_buffer(name)

    # llm-mode sessions intentionally outlive turns, but never their
    # owning buffer. Close through LLMSession so its callback closures
    # leave ETS together with the runtime.
    case Buffer.get_local(name, "llm-session-id") do
      id when is_binary(id) ->
        if Aimax.Core.LLMSession.running?(id), do: Aimax.Core.LLMSession.close(id)

      _ ->
        :ok
    end

    :ok = Buffer.discard(name)
    result = DynamicSupervisor.terminate_child(@buffer_sup, pid)
    BufferStore.forget(name)
    result
  end

  @doc """
  Put a live buffer back to dormancy: checkpoint it, stop its process, keep
  it known. The inverse of `ensure_buffer/1`. Refuses a buffer that is on
  screen, runs a process or agent, or is pinned — the same guards idle
  eviction applies in `BufferStore.safe_to_evict?/3`.
  """
  def sleep_buffer(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] ->
        displayed =
          if Process.whereis(Aimax.Core.Editor),
            do:
              Enum.any?(Aimax.Core.Editor.list_windows_all(), fn {_win, b, _frame} ->
                b == name
              end),
            else: false

        info = Buffer.eviction_info(name)
        agent = info.locals["agent-slug"] || info.locals["chat-agent"]

        cond do
          displayed -> {:error, :displayed}
          Aimax.Core.Proc.running?(name) -> {:error, :busy}
          is_binary(agent) and Aimax.Core.Agent.running?(agent) -> {:error, :busy}
          info.locals["buffer-pinned"] not in [nil, false] -> {:error, :pinned}
          true ->
            :ok = Buffer.checkpoint_now(name)
            DynamicSupervisor.terminate_child(@buffer_sup, pid)
        end

      [] ->
        if BufferStore.known?(name), do: :ok, else: {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :not_found}
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
        {:ok, ^old} = ensure_buffer(old)

        case Buffer.rename(old, new, Buffer.path(old)) do
          :ok ->
            if Process.whereis(Aimax.Core.Editor),
              do: Aimax.Core.Editor.rename_buffer(old, new)

            {:ok, new}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Rename or move a file and carry its buffer identity and history with it."
  def rename_file(source, destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    with false <- source == destination,
         false <- File.exists?(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.rename(source, destination) do
      if BufferStore.known?(source) or Buffer.exists?(source) do
        was_live = Buffer.exists?(source)
        {:ok, ^source} = ensure_buffer(source)
        path = Buffer.path(source)
        dired_dir = Buffer.get_local(source, "dired-dir")
        :ok = Buffer.rename(source, destination, if(path == source, do: destination, else: path))
        if dired_dir == source, do: Buffer.set_local(destination, "dired-dir", destination)

        if Process.whereis(Aimax.Core.Editor),
          do: Aimax.Core.Editor.rename_buffer(source, destination)

        unless was_live do
          [{pid, _}] = Registry.lookup(@registry, destination)
          DynamicSupervisor.terminate_child(@buffer_sup, pid)
        end
      end

      {:ok, destination}
    else
      true -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end
end
