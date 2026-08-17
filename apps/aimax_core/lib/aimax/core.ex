defmodule Aimax.Core do
  @moduledoc "Facade for buffer management."

  alias Aimax.Core.{Buffer, BufferStore}

  @registry Aimax.Core.BufferRegistry
  @buffer_sup Aimax.Core.BufferSupervisor

  @doc "The aimax home dir (config, keys, desktop). Tests point :home at a tmp dir."
  def home, do: Application.get_env(:aimax_core, :home) || Path.expand("~/.aimax")

  def create_buffer(name, opts \\ []) do
    restored = BufferStore.lookup(name)

    if restored && not File.exists?(restored.checkpoint) do
      {:error, :checkpoint_missing}
    else
      opts = if restored, do: Keyword.put_new(opts, :checkpoint, restored.checkpoint), else: opts

      case DynamicSupervisor.start_child(@buffer_sup, {Buffer, Keyword.put(opts, :name, name)}) do
        {:ok, _pid} ->
          # An Editor handler cannot call Session: mode setup can install
          # local keys by calling back into Editor. Its public caller finishes
          # restoration after the Editor call returns. Every other wake is
          # synchronous, so nobody observes a half-restored buffer.
          if restored && Process.whereis(Aimax.Core.Session) do
            cond do
              self() == Process.whereis(Aimax.Core.Editor) ->
                :ok

              self() == Process.whereis(Aimax.Core.Session) ->
                unless Process.get(:aimax_inline_runtime_restore), do: restore_runtime_later(name)

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
  end

  defp restore_runtime_later(name) do
    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn -> restore_runtime(name) end)
  end

  def restore_runtime(name) do
    Aimax.Core.Session.call_named("restore-buffer-runtime!", [name])
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

      [] ->
        if BufferStore.known?(name), do: BufferStore.forget(name), else: {:error, :not_found}
    end
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
