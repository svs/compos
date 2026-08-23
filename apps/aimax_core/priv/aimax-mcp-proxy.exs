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
    scheduler = self()
    spawn(fn -> read_input(scheduler) end)
    schedule(0, [], false)
  end

  defp read_input(scheduler) do
    case IO.gets("") do
      :eof ->
        send(scheduler, :input_done)

      {:error, _} ->
        send(scheduler, :input_done)

      line ->
        case String.trim(line) do
          "" -> :ok
          json -> send(scheduler, {:request, :json.decode(json)})
        end

        read_input(scheduler)
    end
  end

  # Consecutive read-only calls share one window. Any other message is a
  # barrier: it waits for earlier reads and blocks later reads until done.
  defp schedule(active_reads, queue, input_done?) do
    cond do
      active_reads == 0 and queue != [] ->
        drain(queue, input_done?)

      active_reads == 0 and input_done? ->
        :ok

      true ->
        receive do
          {:request, message} when queue == [] ->
            if read_request?(message) do
              start_read(message)
              schedule(active_reads + 1, [], input_done?)
            else
              schedule(active_reads, [message], input_done?)
            end

          {:request, message} ->
            schedule(active_reads, queue ++ [message], input_done?)

          :read_done ->
            schedule(active_reads - 1, queue, input_done?)

          :input_done ->
            schedule(active_reads, queue, true)
        end
    end
  end

  defp drain([], input_done?), do: schedule(0, [], input_done?)

  defp drain([message | rest], input_done?) do
    if read_request?(message) do
      {reads, remaining} = Enum.split_while([message | rest], &read_request?/1)
      Enum.each(reads, &start_read/1)
      schedule(length(reads), remaining, input_done?)
    else
      handle(message)
      drain(rest, input_done?)
    end
  end

  defp start_read(message) do
    scheduler = self()

    Task.start(fn ->
      try do
        handle(message)
      after
        send(scheduler, :read_done)
      end
    end)
  end

  defp read_request?(message) do
    case message do
      %{"method" => "tools/call", "params" => %{"name" => name}} ->
        read_only?(name)

      _ -> false
    end
  end

  defp handle(message) do
    case message do
      %{"method" => "initialize", "id" => id, "params" => params} ->
        reply(id, %{
          protocolVersion: params["protocolVersion"] || "2025-06-18",
          capabilities: %{tools: %{}},
          serverInfo: %{name: "aimax", version: "0.1.0"}
        })

      %{"method" => "tools/list", "id" => id} ->
        case rpc_eval("(mcp-proxy-tools-json)") do
          {:ok, b64} ->
            tools = b64 |> unprint() |> Base.decode64!() |> :json.decode()
            remember_effects(tools)
            reply(id, %{tools: tools})

          {:error, msg} ->
            reply_error(id, msg)
        end

      %{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}} ->
        case call_tool(name, args || %{}) do
          {:ok, text} ->
            reply(id, %{content: [%{type: "text", text: text}]})

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

  defp remember_effects(tools) do
    table = effects_table()
    :ets.delete_all_objects(table)

    for %{"name" => name} = tool <- tools do
      read_only = get_in(tool, ["annotations", "readOnlyHint"]) == true
      :ets.insert(table, {name, read_only})
    end
  end

  defp read_only?(name) do
    case :ets.lookup(effects_table(), name) do
      [{^name, true}] -> true
      _ -> false
    end
  end

  defp effects_table do
    case :ets.whereis(:aimax_proxy_effects) do
      :undefined -> :ets.new(:aimax_proxy_effects, [:named_table, :public, :set])
      table -> table
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
    case agent_slug() do
      nil -> ""
      slug -> ~s{ "agent:#{slug}"}
    end
  end

  defp agent_slug do
    case System.get_env("AIMAX_AGENT") do
      nil -> nil
      slug -> String.replace(slug, ~r/["\\\n]/, "")
    end
  end

  defp call_tool("ask", %{"question" => question} = args) when is_binary(question) do
    case agent_slug() do
      nil ->
        {:error, "ask requires an agent chat"}

      slug ->
        answers =
          if is_list(args["answers"]), do: Enum.map(args["answers"], &to_string/1), else: []

        rpc_request("agent/ask", %{slug: slug, question: question, answers: answers}, :infinity)
    end
  end

  defp call_tool("ask", _args), do: {:error, "ask requires a question and an answers array"}

  defp call_tool(name, args) do
    args_b64 =
      %{}
      |> Map.merge(args)
      |> json_encode()
      |> IO.iodata_to_binary()
      |> Base.encode64()

    case rpc_eval(~s{(mcp-proxy-call "#{name}" "#{args_b64}"#{author_arg()})}) do
      {:ok, b64} -> {:ok, b64 |> unprint() |> Base.decode64!()}
      error -> error
    end
  end

  defp rpc_eval(code) do
    rpc_request("eval", %{code: code}, 600_000)
  end

  defp rpc_request(method, params, timeout) do
    req =
      %{jsonrpc: "2.0", id: 1, method: method, params: params}
      |> json_encode()
      |> IO.iodata_to_binary()

    with {:ok, s} <-
           :gen_tcp.connect(
             {:local, String.to_charlist(sock())},
             0,
             [:binary, active: false, packet: :raw],
             5_000
           ) do
      try do
        with :ok <- :gen_tcp.send(s, req <> "\n"),
             {:ok, resp} <- recv_line(s, "", timeout) do
          decode_rpc_response(resp)
        else
          err -> {:error, "aimax rpc unreachable: #{inspect(err)}"}
        end
      after
        :gen_tcp.close(s)
      end
    else
      err -> {:error, "aimax rpc unreachable: #{inspect(err)}"}
    end
  end

  # Unix-domain sockets are streams. One recv can return only part of a large
  # JSON-RPC response, even though the protocol uses one newline-delimited
  # frame. Accumulate bytes until that delimiter instead of decoding a chunk.
  defp recv_line(socket, acc, timeout) do
    case :binary.match(acc, "\n") do
      {at, 1} ->
        {:ok, binary_part(acc, 0, at)}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, chunk} -> recv_line(socket, acc <> chunk, timeout)
          error -> error
        end
    end
  end

  defp decode_rpc_response(resp) do
    try do
      case :json.decode(resp) do
        %{"result" => r} -> {:ok, r}
        %{"error" => e} -> {:error, e["message"] || "rpc error"}
        _ -> {:error, "bad rpc response"}
      end
    rescue
      error -> {:error, "bad rpc response: #{Exception.message(error)}"}
    end
  end

  # OTP's default :json encoder emits Elixir-style `\x{...}` escapes for
  # non-ASCII binaries. They are not JSON: strict clients (including Codex)
  # discard the tools/list frame and wait until startup times out. Escape all
  # binaries with JSON's portable `\uXXXX` form instead.
  defp json_encode(value) do
    :json.encode(value, fn
      binary, _encode when is_binary(binary) -> :json.encode_binary_escape_all(binary)
      other, encode -> :json.encode_value(other, encode)
    end)
  end

  defp reply(id, result), do: send_msg(%{jsonrpc: "2.0", id: id, result: result})

  defp reply_error(id, msg),
    do: send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32000, message: msg}})

  defp send_msg(msg), do: msg |> json_encode() |> IO.iodata_to_binary() |> IO.puts()
end

unless System.get_env("AIMAX_PROXY_NO_LOOP") == "1", do: AimaxProxy.loop()
