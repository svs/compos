defmodule Compos.Rpc.McpServer do
  @moduledoc """
  The editor's tool registry served as MCP over a Unix domain socket, for
  every agent the daemon starts.

  An ACP adapter starts its MCP servers as stdio subprocesses. The compos
  entry (mcp.scm) starts `compos-mcp-shim` (native/compos_mcp_shim): it
  sends the agent's slug as the first line, then copies stdio to this
  socket and back. Each connection is one agent session. The MCP work runs
  here, in the daemon, so an agent costs about 1 MB and no extra VM.

  Frames are newline-delimited JSON-RPC, as on stdio. Consecutive read-only
  calls of one connection run together. Any other message is a barrier: it
  waits for earlier reads and blocks later reads until it is done.
  """

  use GenServer

  require Logger

  alias Compos.Core.Session

  # A read-only call answers in milliseconds. One that takes a minute lost
  # its answer in the editor, so the model gets an error it can retry. A
  # write or shell call can run for minutes and keeps the long limit.
  @read_timeout 60_000
  @write_timeout 600_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The socket path: the RPC socket's path with `-mcp` added (mcp.scm reads it the same way)."
  def default_socket_path do
    Application.get_env(
      :compos_rpc,
      :mcp_socket_path,
      Compos.Rpc.Server.default_socket_path() <> "-mcp"
    )
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path, default_socket_path())
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    # exit_on_close false: the shim half-closes on stdin EOF, and the
    # replies to the calls in flight must still reach it
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: :raw,
        active: false,
        exit_on_close: false
      ])

    {:ok, _} = Task.start_link(fn -> accept_loop(lsock) end)
    Logger.info("compos mcp listening on #{path}")
    {:ok, %{lsock: lsock, path: path}}
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} =
          Task.Supervisor.start_child(Compos.Rpc.ConnSupervisor, fn -> serve(sock) end)

        :gen_tcp.controlling_process(sock, pid)
        accept_loop(lsock)

      {:error, :closed} ->
        :ok
    end
  end

  # --- one connection = one agent session --------------------------------------

  defp serve(sock) do
    case recv_line(sock, "") do
      {:ok, slug, rest} ->
        conn = self()
        spawn_link(fn -> read_input(sock, conn, rest) end)
        st = %{sock: sock, slug: clean_slug(slug), effects: %{}}
        schedule(st, 0, [], false)
        :gen_tcp.close(sock)

      _ ->
        :gen_tcp.close(sock)
    end
  end

  # the first line names the agent thread; an empty line names none
  defp clean_slug(line) do
    case String.replace(line, ~r/["\\\r\n]/, "") do
      "" -> nil
      slug -> slug
    end
  end

  defp read_input(sock, conn, buf) do
    case recv_line(sock, buf) do
      {:ok, line, rest} ->
        case String.trim(line) do
          "" ->
            :ok

          json ->
            case Jason.decode(json) do
              {:ok, msg} -> send(conn, {:request, msg})
              {:error, _} -> :ok
            end
        end

        read_input(sock, conn, rest)

      _ ->
        send(conn, :input_done)
    end
  end

  # A Unix socket is a stream: one recv can hold part of a frame or several.
  defp recv_line(sock, buf) do
    case :binary.split(buf, "\n") do
      [line, rest] ->
        {:ok, line, rest}

      [_] ->
        case :gen_tcp.recv(sock, 0) do
          {:ok, chunk} -> recv_line(sock, buf <> chunk)
          error -> error
        end
    end
  end

  defp schedule(st, active_reads, queue, input_done?) do
    cond do
      active_reads == 0 and queue != [] ->
        drain(st, queue, input_done?)

      active_reads == 0 and input_done? ->
        :ok

      true ->
        receive do
          {:request, message} when queue == [] ->
            if read_request?(st, message) do
              start_read(st, message)
              schedule(st, active_reads + 1, [], input_done?)
            else
              schedule(st, active_reads, [message], input_done?)
            end

          {:request, message} ->
            schedule(st, active_reads, queue ++ [message], input_done?)

          :read_done ->
            schedule(st, active_reads - 1, queue, input_done?)

          :input_done ->
            schedule(st, active_reads, queue, true)
        end
    end
  end

  defp drain(st, [], input_done?), do: schedule(st, 0, [], input_done?)

  defp drain(st, [message | rest] = queue, input_done?) do
    if read_request?(st, message) do
      {reads, remaining} = Enum.split_while(queue, &read_request?(st, &1))
      Enum.each(reads, &start_read(st, &1))
      schedule(st, length(reads), remaining, input_done?)
    else
      drain(handle(st, message), rest, input_done?)
    end
  end

  # each read runs in its own process, so its eval runs in its own lane
  defp start_read(st, message) do
    conn = self()

    Task.start(fn ->
      try do
        handle(st, message)
      after
        send(conn, :read_done)
      end
    end)
  end

  defp read_request?(st, %{"method" => "tools/call", "params" => %{"name" => name}}),
    do: read_only?(st, name)

  defp read_request?(_st, _message), do: false

  defp read_only?(st, name), do: Map.get(st.effects, name, false)

  # --- MCP methods ---------------------------------------------------------------

  # tools.scm mcp-proxy-content-prefix: the rest is a JSON array of MCP
  # content blocks (an image a tool read, for example)
  @content_prefix <<0, "compos-content\n">>

  defp handle(st, %{"method" => "initialize", "id" => id} = message) do
    params = message["params"] || %{}

    reply(st, id, %{
      protocolVersion: params["protocolVersion"] || "2025-06-18",
      capabilities: %{tools: %{}},
      serverInfo: %{name: "compos", version: "0.1.0"}
    })

    st
  end

  defp handle(st, %{"method" => "tools/list", "id" => id}) do
    case eval("(mcp-proxy-tools-json)", @write_timeout) do
      {:ok, b64} ->
        tools = b64 |> unprint() |> Base.decode64!() |> Jason.decode!()
        reply(st, id, %{tools: tools})
        %{st | effects: effects(tools)}

      {:error, msg} ->
        reply_error(st, id, error_text(msg))
        st
    end
  end

  defp handle(st, %{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = params}) do
    case call_tool(st, name, params["arguments"] || %{}) do
      {:ok, @content_prefix <> blocks} ->
        reply(st, id, %{content: Jason.decode!(blocks)})

      {:ok, text} when is_binary(text) ->
        if String.valid?(text),
          do: reply(st, id, %{content: [%{type: "text", text: text}]}),
          else:
            reply(st, id, %{
              content: [%{type: "text", text: "error: the tool result is not UTF-8 text"}],
              isError: true
            })

      {:error, msg} ->
        reply(st, id, %{content: [%{type: "text", text: "error: #{msg}"}], isError: true})
    end

    st
  end

  defp handle(st, %{"method" => "ping", "id" => id}) do
    reply(st, id, %{})
    st
  end

  defp handle(st, %{"method" => _, "id" => id}) do
    send_msg(st, %{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found"}})
    st
  end

  defp handle(st, _notification), do: st

  defp effects(tools) do
    Map.new(tools, fn tool ->
      {tool["name"], get_in(tool, ["annotations", "readOnlyHint"]) == true}
    end)
  end

  # `ask` is not an eval: the call waits for the user while the Session
  # stays free for keys and redraws
  defp call_tool(%{slug: nil}, "ask", _args), do: {:error, "ask requires an agent chat"}

  defp call_tool(st, "ask", %{"question" => question} = args) when is_binary(question) do
    answers = if is_list(args["answers"]), do: Enum.map(args["answers"], &to_string/1), else: []

    case Compos.Core.Agent.ask_user(st.slug, question, answers) do
      {:ok, answer} -> {:ok, to_string(answer)}
      {:error, reason} -> {:error, "ask failed: #{inspect(reason)}"}
    end
  end

  defp call_tool(_st, "ask", _args), do: {:error, "ask requires a question and an answers array"}

  defp call_tool(st, name, args) do
    args_b64 = args |> Jason.encode!() |> Base.encode64()
    author = if st.slug, do: ~s{ "agent:#{st.slug}"}, else: ""
    code = ~s{(mcp-proxy-call "#{String.replace(name, ~r/["\\]/, "")}" "#{args_b64}"#{author})}

    case eval(code, call_timeout(st, name)) do
      {:ok, b64} -> {:ok, b64 |> unprint() |> Base.decode64!()}
      {:error, :timeout} -> {:error, "the editor did not answer #{name} in time; retry the call"}
      {:error, msg} -> {:error, error_text(msg)}
    end
  end

  defp call_timeout(st, name), do: if(read_only?(st, name), do: @read_timeout, else: @write_timeout)

  # the eval runs in the calling process's own lane: an agent's long call
  # never queues a keystroke, and two agents never queue behind each other
  defp eval(code, timeout) do
    Session.eval(code, nil, timeout, {:rpc, self()})
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, "the editor eval exited: #{inspect(reason)}"}
  end

  defp error_text(msg) when is_binary(msg), do: msg
  defp error_text(msg), do: inspect(msg)

  # eval returns the printed value; for a base64 payload that is the string
  # in quotes
  defp unprint(printed), do: String.trim(printed, "\"")

  defp reply(st, id, result), do: send_msg(st, %{jsonrpc: "2.0", id: id, result: result})

  defp reply_error(st, id, msg),
    do: send_msg(st, %{jsonrpc: "2.0", id: id, error: %{code: -32000, message: msg}})

  # \uXXXX escapes for all non-ASCII: strict clients (Codex) reject a frame
  # with other escapes
  defp send_msg(st, msg),
    do: :gen_tcp.send(st.sock, [Jason.encode_to_iodata!(msg, escape: :unicode_safe), "\n"])
end
