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
        base = [
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

        extra =
          if "--elicitation" in System.argv() do
            [
              %{
                name: "guarded",
                description: "Tool using 2026-07-28 stateless form elicitation.",
                inputSchema: %{
                  type: "object",
                  properties: %{v: %{type: "string"}},
                  required: ["v"]
                }
              },
              %{
                name: "ask_stateful",
                description: "Tool using stateful server-initiated elicitation/create.",
                inputSchema: %{
                  type: "object",
                  properties: %{v: %{type: "string"}},
                  required: ["v"]
                }
              }
            ]
          else
            []
          end

        reply(id, %{tools: base ++ extra})

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => "guarded"} = params} ->
        caps = get_in(params, ["_meta", "io.modelcontextprotocol/clientCapabilities", "elicitation", "form"])
        v = params["arguments"]["v"] || ""

        cond do
          not is_map(caps) ->
            send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32021, message: "elicitation not supported"}})

          params["requestState"] == "state-" <> v ->
            choice = get_in(params, ["inputResponses", "approval_choice", "content", "approval_choice"])
            action = get_in(params, ["inputResponses", "approval_choice", "action"])

            cond do
              action == "accept" and choice in ["ALLOW_ONCE", "ALLOW_TOOL_ALWAYS"] ->
                reply(id, %{resultType: "complete", content: [%{type: "text", text: "approved:" <> choice <> ":" <> v}]})

              true ->
                reply(id, %{resultType: "complete", isError: true, content: [%{type: "text", text: "denied:" <> to_string(choice || action)}]})
            end

          true ->
            reply(id, %{
              resultType: "input_required",
              requestState: "state-" <> v,
              inputRequests: %{
                approval_choice: %{
                  method: "elicitation/create",
                  params: %{
                    mode: "form",
                    message: "**Guarded action** for " <> v,
                    requestedSchema: %{
                      type: "object",
                      required: ["approval_choice"],
                      properties: %{
                        approval_choice: %{
                          type: "string",
                          title: "Allow guarded action?",
                          enum: ["ALLOW_ONCE", "ALLOW_TOOL_ALWAYS", "DENY_ONCE"],
                          enumNames: ["Allow once", "Always allow this tool", "Don't allow"]
                        }
                      }
                    }
                  }
                }
              }
            })
        end

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => "ask_stateful"} = params} ->
        v = params["arguments"]["v"] || ""
        elicit_id = "elicit-" <> to_string(id)
        send_msg(%{
          jsonrpc: "2.0",
          id: elicit_id,
          method: "elicitation/create",
          params: %{
            mode: "form",
            message: "Confirm " <> v,
            requestedSchema: %{
              type: "object",
              required: ["confirm"],
              properties: %{confirm: %{type: "boolean", title: "Proceed?"}}
            }
          }
        })

        Process.put({:await_elicit, elicit_id}, {id, v})

      %{"id" => elicit_id, "result" => res} ->
        case Process.delete({:await_elicit, elicit_id}) do
          {call_id, v} ->
            ok = get_in(res, ["content", "confirm"]) == true
            reply(call_id, %{content: [%{type: "text", text: "stateful:" <> to_string(ok) <> ":" <> v}]})

          nil ->
            :ok
        end

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
