defmodule Aimax.RpcTest do
  use ExUnit.Case

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

  test "ping" do
    sock = connect()
    assert %{"result" => "pong", "id" => 1} = rpc(sock, %{jsonrpc: "2.0", id: 1, method: "ping"})
  end

  test "eval drives the editor over the socket" do
    sock = connect()
    name = "rpc-buf-#{System.unique_integer([:positive])}"

    code = ~s{(begin (buffer-create "#{name}") (buffer-append! "#{name}" "via rpc") (buffer-text "#{name}"))}

    resp = rpc(sock, %{jsonrpc: "2.0", id: 2, method: "eval", params: %{code: code}})
    assert resp["result"] == inspect("via rpc")
    assert Aimax.Core.Buffer.text(name) == "via rpc"
  end

  test "state persists across connections (one session)" do
    assert %{"result" => _} =
             rpc(connect(), %{
               jsonrpc: "2.0",
               id: 3,
               method: "eval",
               params: %{code: "(define rpc-x 99)"}
             })

    assert %{"result" => "99"} =
             rpc(connect(), %{jsonrpc: "2.0", id: 4, method: "eval", params: %{code: "rpc-x"}})
  end

  test "errors come back as JSON-RPC errors" do
    sock = connect()

    assert %{"error" => %{"code" => -32000, "message" => msg}} =
             rpc(sock, %{jsonrpc: "2.0", id: 5, method: "eval", params: %{code: "(boom)"}})

    assert msg =~ "unbound"

    assert %{"error" => %{"code" => -32601}} =
             rpc(sock, %{jsonrpc: "2.0", id: 6, method: "nope"})
  end
end
