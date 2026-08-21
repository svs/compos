defmodule Aimax.Rpc.ListenerRestartTest do
  @moduledoc """
  restart_listener/1 against the one listener this app boots: the JSON-RPC
  unix socket. The bounce must produce a fresh server that answers again.
  """

  use ExUnit.Case

  alias Aimax.Core.Daemon

  defp connect do
    path = Aimax.Rpc.Server.default_socket_path()
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    sock
  end

  defp rpc(sock, req) do
    :ok = :gen_tcp.send(sock, [Jason.encode!(req), "\n"])
    {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
    Jason.decode!(line)
  end

  test "the rpc listener reads as up with its socket path" do
    rpc = Enum.find(Daemon.listeners(), &(&1.name == "rpc"))
    assert rpc.status == "up"
    assert rpc.address == Aimax.Rpc.Server.default_socket_path()
  end

  test "restart_listener bounces the server and the socket answers again" do
    old_pid = Process.whereis(Aimax.Rpc.Server)
    assert is_pid(old_pid)

    assert :ok = Daemon.restart_listener("rpc")

    new_pid = Process.whereis(Aimax.Rpc.Server)
    assert is_pid(new_pid)
    assert new_pid != old_pid

    sock = connect()
    assert %{"result" => "pong"} = rpc(sock, %{jsonrpc: "2.0", id: 1, method: "ping"})
  end
end
