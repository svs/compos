defmodule Aimax.McpProxyTest do
  @moduledoc """
  The bundled aimax-mcp-proxy.exs end to end: a real subprocess speaking
  MCP on stdio, bridged to this node's RPC socket — what an external ACP
  agent actually spawns.
  """

  use ExUnit.Case

  @script Path.join(Application.app_dir(:aimax_core, "priv"), "aimax-mcp-proxy.exs")

  test "initialize, tools/list, and a live tools/call against the registry" do
    Aimax.Core.create_buffer("*proxy-doc*")
    on_exit(fn -> Aimax.Core.kill_buffer("*proxy-doc*") end)
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-append! "*proxy-doc*" "hello from aimax")})

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: [@script],
        env: [{~c"AIMAX_SOCK", String.to_charlist(Aimax.Rpc.Server.default_socket_path())}]
      ])

    send_msg(port, %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{protocolVersion: "2025-06-18"}})
    assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "aimax"}}} = recv(port)

    send_msg(port, %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})
    assert %{"id" => 2, "result" => %{"tools" => tools}} = recv(port)
    assert "eval-scheme" in Enum.map(tools, & &1["name"])

    send_msg(port, %{
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: %{name: "eval-scheme", arguments: %{code: ~s{(buffer-text "*proxy-doc*")}}}
    })

    # eval-scheme returns the printed value, quotes included
    assert %{"id" => 3, "result" => %{"content" => [%{"text" => ~s{"hello from aimax"}}]}} =
             recv(port)

    Port.close(port)
  end

  defp send_msg(port, msg), do: Port.command(port, Jason.encode!(msg) <> "\n")

  # skip non-JSON stdout chatter (elixir boot warnings etc.)
  defp recv(port, acc \\ "") do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data

        case String.split(acc, "\n", parts: 2) do
          [line, rest] ->
            case Jason.decode(line) do
              {:ok, msg} -> msg
              {:error, _} -> recv(port, rest)
            end

          [_] ->
            recv(port, acc)
        end

      {^port, {:exit_status, s}} ->
        flunk("proxy exited: #{s}")
    after
      15_000 -> flunk("no proxy response")
    end
  end
end
