defmodule Aimax.Core do
  @moduledoc "Facade for buffer management."

  alias Aimax.Core.Buffer

  @registry Aimax.Core.BufferRegistry
  @buffer_sup Aimax.Core.BufferSupervisor

  def create_buffer(name, opts \\ []) do
    case DynamicSupervisor.start_child(@buffer_sup, {Buffer, Keyword.put(opts, :name, name)}) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _}} -> {:error, :already_exists}
      other -> other
    end
  end

  @doc "Open a file into a buffer named after its path."
  def open_file(path) do
    path = Path.expand(path)
    create_buffer(path, path: path)
  end

  def list_buffers do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def kill_buffer(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@buffer_sup, pid)
      [] -> {:error, :not_found}
    end
  end
end
