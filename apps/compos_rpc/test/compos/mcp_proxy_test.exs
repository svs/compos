defmodule Compos.McpProxyTest do
  @moduledoc """
  The bundled compos-mcp-proxy.exs end to end: a real subprocess speaking
  MCP on stdio, bridged to this node's RPC socket — what an external ACP
  agent actually spawns.
  """

  use ExUnit.Case

  @script Path.join(Application.app_dir(:compos_core, "priv"), "compos-mcp-proxy.exs")

  test "initialize, tools/list, and a live tools/call against the registry" do
    slug = "proxy-ask-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Compos.Core.Agent.start(slug, %{
        "backend" => "stub",
        "buffer" => "*agent: #{slug}*"
      })

    on_exit(fn ->
      Compos.Core.Agent.kill(slug)
      Compos.Core.kill_buffer("*agent: #{slug}*")
    end)

    Compos.Core.create_buffer("*proxy-doc*")
    on_exit(fn -> Compos.Core.kill_buffer("*proxy-doc*") end)
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-append! "*proxy-doc*" "hello from compos")})

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: [@script],
        env: [
          {~c"COMPOS_SOCK", String.to_charlist(Compos.Rpc.Server.default_socket_path())},
          {~c"COMPOS_AGENT", String.to_charlist(slug)}
        ]
      ])

    send_msg(port, %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{protocolVersion: "2025-06-18"}
    })

    assert %{"id" => 1, "result" => %{"serverInfo" => %{"name" => "compos"}}} = recv(port)

    send_msg(port, %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})
    assert %{"id" => 2, "result" => %{"tools" => tools}} = recv(port)
    assert "eval-scheme" in Enum.map(tools, & &1["name"])
    assert "ask" in Enum.map(tools, & &1["name"])

    send_msg(port, %{
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: %{name: "eval-scheme", arguments: %{code: ~s{(buffer-text "*proxy-doc*")}}}
    })

    # eval-scheme returns the printed value, quotes included
    assert %{"id" => 3, "result" => %{"content" => [%{"text" => ~s{"hello from compos"}}]}} =
             recv(port)

    # A response can exceed one socket read. The proxy must assemble the
    # newline-delimited frame instead of decoding the first received chunk.
    large = String.duplicate("large response line\n", 2_000)
    Compos.Core.create_buffer("*proxy-large*", text: large)
    on_exit(fn -> Compos.Core.kill_buffer("*proxy-large*") end)

    send_msg(port, %{
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: %{name: "eval-scheme", arguments: %{code: ~s{(buffer-text "*proxy-large*")}}}
    })

    assert %{"id" => 4, "result" => %{"content" => [%{"text" => returned}]}} = recv(port)
    assert returned == Jason.encode!(large)

    send_msg(port, %{
      jsonrpc: "2.0",
      id: 5,
      method: "tools/call",
      params: %{
        name: "ask",
        arguments: %{
          question: "Create a workspace?",
          answers: ["Yes", "No", "Show diff", "Explain"]
        }
      }
    })

    assert eventually(fn ->
             match?(
               %{question: %{question: "Create a workspace?", answers: [_, _, _, _]}},
               Compos.Core.Agent.info(slug)
             )
           end)

    %{question: %{id: question_id}} = Compos.Core.Agent.info(slug)
    assert :ok = Compos.Core.Agent.respond_question(slug, question_id, "Show diff")

    assert %{"id" => 5, "result" => %{"content" => [%{"text" => "Show diff"}]}} = recv(port)

    Port.close(port)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
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
