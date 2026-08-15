# aimax-mcp-proxy — the editor's tool registry served as an MCP server.
#
# External ACP agents (claude-code, codex) get eval-scheme — and with it
# the whole editor API — through this bridge: stdio MCP
# on this side, the daemon's JSON-RPC socket (~/.aimax/sock, AIMAX_SOCK to
# override) on the other. Spawned per agent session via the 'aimax entry
# the mcp package registers; runs on OTP's :json — no deps.
#
# Payloads cross the RPC boundary base64-encoded (mcp-proxy-tools-json /
# mcp-proxy-call in tools.scm): eval returns *printed* Scheme values, and
# printed-string escaping is not JSON-compatible for every byte — base64
# survives both directions untouched.
defmodule AimaxProxy do
  def sock, do: System.get_env("AIMAX_SOCK") || Path.expand("~/.aimax/sock")

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
          protocolVersion: params["protocolVersion"] || "2025-06-18",
          capabilities: %{tools: %{}},
          serverInfo: %{name: "aimax", version: "0.1.0"}
        })

      %{"method" => "tools/list", "id" => id} ->
        case rpc_eval("(mcp-proxy-tools-json)") do
          {:ok, b64} -> reply(id, %{tools: b64 |> unprint() |> Base.decode64!() |> :json.decode()})
          {:error, msg} -> reply_error(id, msg)
        end

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}} ->
        args_b64 = %{} |> Map.merge(args || %{}) |> :json.encode() |> IO.iodata_to_binary() |> Base.encode64()

        case rpc_eval(~s{(mcp-proxy-call "#{name}" "#{args_b64}"#{author_arg()})}) do
          {:ok, b64} ->
            reply(id, %{content: [%{type: "text", text: b64 |> unprint() |> Base.decode64!()}]})

          {:error, msg} ->
            reply(id, %{content: [%{type: "text", text: "error: #{msg}"}], isError: true})
        end

      %{"method" => "ping", "id" => id} ->
        reply(id, %{})

      %{"method" => _, "id" => id} ->
        send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found"}})

      _notification ->
        :ok
    end
  end

  # eval returns the printed value; for a base64 payload that is just the
  # string in quotes — strip them
  defp unprint(printed), do: String.trim(printed, "\"")

  # AIMAX_AGENT (set by the ACP backend at spawn) names the thread this
  # proxy serves; it rides into mcp-proxy-call so buffer edits carry it.
  # Slugs are machine-generated, but strip quote-breaking bytes anyway —
  # this string lands inside an eval form.
  defp author_arg do
    case System.get_env("AIMAX_AGENT") do
      nil -> ""
      slug -> ~s{ "agent:#{String.replace(slug, ~r/["\\\n]/, "")}"}
    end
  end

  defp rpc_eval(code) do
    req =
      %{jsonrpc: "2.0", id: 1, method: "eval", params: %{code: code}}
      |> :json.encode()
      |> IO.iodata_to_binary()

    with {:ok, s} <-
           :gen_tcp.connect({:local, String.to_charlist(sock())}, 0,
             [:binary, active: false, packet: :line],
             5_000
           ),
         :ok <- :gen_tcp.send(s, req <> "\n"),
         {:ok, resp} <- :gen_tcp.recv(s, 0, 120_000) do
      :gen_tcp.close(s)

      case :json.decode(resp) do
        %{"result" => r} -> {:ok, r}
        %{"error" => e} -> {:error, e["message"] || "rpc error"}
        _ -> {:error, "bad rpc response"}
      end
    else
      err -> {:error, "aimax rpc unreachable: #{inspect(err)}"}
    end
  end

  defp reply(id, result), do: send_msg(%{jsonrpc: "2.0", id: id, result: result})

  defp reply_error(id, msg),
    do: send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32000, message: msg}})

  defp send_msg(msg), do: msg |> :json.encode() |> IO.iodata_to_binary() |> IO.puts()
end

AimaxProxy.loop()
