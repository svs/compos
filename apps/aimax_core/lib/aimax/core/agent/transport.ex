defmodule Aimax.Core.Agent.Transport do
  @moduledoc """
  How an Agent talks to its ACP adapter process. The behaviour exists for the
  same reason as `:llm_request_fun`: tests swap in a fake and drive the whole
  agent path without an adapter binary or network.

  The owner process receives `{:acp_data, binary}` for incoming bytes and
  `{:acp_exit, status}` when the adapter dies.
  """

  @callback open(cmd :: String.t(), opts :: keyword, owner :: pid) :: {:ok, term}
  @callback send_frame(state :: term, data :: iodata) :: :ok
  @callback close(state :: term) :: :ok

  def impl, do: Application.get_env(:aimax_core, :acp_transport, __MODULE__.Port)
end

defmodule Aimax.Core.Agent.Transport.Port do
  @moduledoc """
  Plain stdio port to the adapter — line-framed JSON-RPC, so no PTY, no
  `script(1)`, no ANSI stripping (contrast `Proc`). The adapter's stderr is
  left alone; it goes to the daemon log.
  """

  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, opts, _owner) do
    [exe | args] = String.split(cmd, " ", trim: true)

    env =
      case Keyword.get(opts, :env) do
        nil ->
          []

        env ->
          # from scheme this is a list of (name value) pairs, not tuples
          Enum.map(env, fn
            {k, v} -> {to_charlist(k), to_charlist(v)}
            [k, v] -> {to_charlist(k), to_charlist(v)}
          end)
      end

    port_opts =
      [:binary, :exit_status, args: args] ++
        case Keyword.get(opts, :cd) do
          nil -> []
          cwd -> [cd: to_charlist(cwd)]
        end ++
        # the daemon is often launched from inside a Claude Code shell;
        # claude-code-acp refuses to nest when it inherits CLAUDECODE
        # (false in a port env deletes the var from the child)
        [env: [{~c"CLAUDECODE", false} | env]]

    exe_path = System.find_executable(exe) || raise "agent adapter not found: #{exe}"
    port = Port.open({:spawn_executable, exe_path}, port_opts)
    {:ok, port}
  end

  @impl true
  def send_frame(port, data) do
    Port.command(port, data)
    :ok
  end

  @impl true
  def close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
