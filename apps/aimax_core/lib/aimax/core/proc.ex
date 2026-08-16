defmodule Aimax.Core.Proc do
  @moduledoc """
  Comint-style process buffers: an OS process whose output streams into a
  buffer (provenance `:process`), input sent via `send_text/2`.

  PTY allocation uses the `script` binary (BSD/macOS) so shells and REPLs get
  a real tty without a NIF dependency. TERM=dumb keeps escape codes minimal;
  a small ANSI strip handles the rest. TODO: proper PTY via erlexec, ring
  buffer for high-volume output, resize, signals.

  The aimax "eyes": the Reactor can watch these buffers like any other —
  process filters are just `on_change` rules.
  """

  use GenServer, restart: :temporary

  alias Aimax.Core.Buffer

  @registry Aimax.Core.ProcRegistry

  def start(buffer_name, cmd) when is_binary(cmd) do
    DynamicSupervisor.start_child(
      Aimax.Core.ProcSupervisor,
      {__MODULE__, buffer: buffer_name, cmd: cmd}
    )
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :buffer)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, name}})
  end

  def running?(buffer_name), do: Registry.lookup(@registry, buffer_name) != []

  def send_text(buffer_name, text) do
    case Registry.lookup(@registry, buffer_name) do
      [{pid, _}] -> GenServer.call(pid, {:send, text})
      [] -> {:error, :no_process}
    end
  end

  def kill(buffer_name) do
    case Registry.lookup(@registry, buffer_name) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> {:error, :no_process}
    end
  end

  @doc "Byte position just after the last process output — user input starts here."
  def mark(buffer_name) do
    case Registry.lookup(@registry, buffer_name) do
      [{pid, _}] -> GenServer.call(pid, :mark)
      [] -> 0
    end
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    # trap exits so terminate/2 runs and can kill the OS process; a closed
    # port only closes stdin, which `script` and its child ignore — each
    # undead pair holds a pty, and the machine has ~511
    Process.flag(:trap_exit, true)
    buffer = Keyword.fetch!(opts, :buffer)
    cmd = Keyword.fetch!(opts, :cmd)
    Aimax.Core.create_buffer(buffer)

    port =
      Port.open({:spawn_executable, "/usr/bin/script"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # -echo: the buffer keeps the user's typed input; the pty must not
        # echo it back (comint would show it twice — or, if a shell disables
        # echo itself, typed input would vanish on send)
        args: ["-q", "/dev/null", "/bin/sh", "-c", "stty -echo 2>/dev/null; " <> cmd],
        env: [{~c"TERM", ~c"dumb"}, {~c"PS1", ~c"$ "}, {~c"PROMPT_EOL_MARK", ~c""}]
      ])

    {:ok, %{buffer: buffer, port: port, mark: 0}}
  end

  @impl true
  def handle_call({:send, text}, _from, state) do
    Port.command(state.port, text)
    {:reply, :ok, state}
  end

  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Buffer.append(state.buffer, strip_ansi(data), source: :process)
    {:noreply, %{state | mark: Buffer.byte_size(state.buffer)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Buffer.append(state.buffer, "\n[process exited: #{status}]\n", source: :process)
    {:stop, :normal, state}
  end

  # port EXIT after exit_status — nothing left to do
  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    with {:os_pid, os_pid} <- Port.info(state.port, :os_pid) do
      System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)])
    end

    :ok
  end

  # CSI/OSC sequences and stray carriage returns from the pty.
  # " +\r" is the partial-line padding trick (zsh PROMPT_SP et al.) — drop the
  # padding with the CR, not just the CR, or prompts render mid-window.
  defp strip_ansi(data) do
    data
    |> String.replace(~r/\e\[[0-9;?]*[a-zA-Z]/, "")
    |> String.replace(~r/\e\][^\a]*(\a|\e\\)/, "")
    |> String.replace(~r/ +\r(\n?)/, "\\1")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "")
  end
end
