defmodule Aimax.Core.Peer do
  @moduledoc """
  Another replica, reached over its own JSON-RPC socket. Mechanism only: what
  to sync, when, and with whom is Scheme (`priv/packages/peers.scm`).

  A peer is a home, so it is named by the socket that home listens on. A local
  path reaches a daemon on this machine; `host:/path` reaches one over ssh,
  through the same `~/.ssh/config` that remote buffers already use.

  The call is `eval`, because eval is the API. Nothing here knows what a
  buffer is: it sends Scheme and returns what came back.
  """

  require Logger

  alias Aimax.Core.Remote

  @connect_timeout 5_000
  @call_timeout 30_000

  @doc """
  Evaluate `code` on the peer and return its printed result.

  `{:ok, printed}` when the peer answered, `{:error, reason}` when it could not
  be reached or refused. A peer that is off is an ordinary error, not a crash:
  replicas go away, and the ones still here keep working.
  """
  def eval(peer, code) when is_binary(code) do
    request = %{jsonrpc: "2.0", id: 1, method: "eval", params: %{code: code}}

    with {:ok, line} <- send_line(peer, Jason.encode!(request) <> "\n"),
         {:ok, %{"result" => result}} <- decode(line) do
      {:ok, result}
    else
      {:ok, %{"error" => %{"message" => message}}} -> {:error, message}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # A local socket: talk to it directly.
  defp send_line(path, line) when is_binary(path) do
    if String.contains?(path, ":"), do: send_over_ssh(path, line), else: send_local(path, line)
  end

  defp send_local(path, line) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line],
           @connect_timeout
         ) do
      {:ok, sock} ->
        try do
          with :ok <- :gen_tcp.send(sock, line),
               {:ok, reply} <- :gen_tcp.recv(sock, 0, @call_timeout) do
            {:ok, reply}
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `host:/path`: the remote daemon's socket, reached the way remote buffers
  # already are. Its own `nc -U` does the talking on the far side.
  defp send_over_ssh(spec, line) do
    [host, path] = String.split(spec, ":", parts: 2)

    case Remote.sh(host, "printf %s " <> shell_quote(line) <> " | nc -U " <> shell_quote(path)) do
      {:ok, out} -> {:ok, out}
      other -> other
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp decode(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :unreadable_reply}
    end
  end
end
