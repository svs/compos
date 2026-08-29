# Minimal MCP server over stdio for tests: newline-delimited JSON-RPC,
# initialize handshake, one tool ("echo"). Uses OTP's :json — no deps, so it
# runs as `elixir fake_mcp_server.exs` straight from a Port.
#
# It advertises resources AND prompts but only implements resources/list:
# prompts/list falls through to -32601, which is exactly what a real server
# that overstates its capabilities does, and the client must survive it.
defmodule FakeMCP do
  def loop do
    case IO.gets("") do
      :eof -> :ok
      {:error, _} -> :ok
      line ->
        line |> String.trim() |> handle()
        loop()
    end
  end

  defp handle(""), do: :ok

  defp handle(line) do
    case :json.decode(line) do
      %{"method" => "initialize", "id" => id, "params" => params} ->
        reply(id, %{
          protocolVersion: params["protocolVersion"],
          capabilities: %{tools: %{}, resources: %{}, prompts: %{}},
          serverInfo: %{name: "fake-mcp", version: "0.0.1"}
        })

      %{"method" => "resources/list", "id" => id} ->
        reply(id, %{
          resources: [
            %{uri: "file:///fake.txt", name: "fake.txt", description: "A fake file."}
          ]
        })

      %{"method" => "tools/list", "id" => id} ->
        reply(id, %{
          tools: [
            %{
              name: "echo",
              description: "Echo back v.",
              annotations: %{readOnlyHint: true},
              inputSchema: %{
                type: "object",
                properties: %{
                  v: %{type: "string", description: "value to echo"},
                  wait: %{type: "integer", description: "milliseconds to wait"}
                },
                required: ["v"]
              }
            }
          ]
        })

      %{"method" => "tools/call", "id" => id, "params" => params} ->
        if is_integer(params["arguments"]["wait"]), do: Process.sleep(params["arguments"]["wait"])
        v = params["arguments"]["v"] || ""
        reply(id, %{content: [%{type: "text", text: "echo:" <> v}]})

      %{"method" => _, "id" => id} ->
        send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found"}})

      _notification ->
        :ok
    end
  end

  defp reply(id, result), do: send_msg(%{jsonrpc: "2.0", id: id, result: result})

  # the client may disconnect mid-reply; a dead stdout is not news
  defp send_msg(msg) do
    msg |> :json.encode() |> IO.iodata_to_binary() |> IO.puts()
  catch
    _, _ -> :ok
  end
end

FakeMCP.loop()
