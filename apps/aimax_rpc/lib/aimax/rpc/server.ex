defmodule Aimax.Rpc.Server do
  @moduledoc """
  JSON-RPC 2.0 over a Unix domain socket, newline-delimited — the aimax
  "Thin Transport, Thick Scheme" control port. `eval` is the primary API:
  agents script atomic multi-step actions in one round-trip.

      echo '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(+ 1 2)"}}' \\
        | nc -U ~/.aimax/sock

  Methods: `eval` (params.code), `reload` (params.paths), `shutdown`, `ping`.

  Frames: eval runs against the **last-active frame** (the one that saw
  input most recently). Window primitives act there; target another frame
  explicitly with `(select-frame! id)` — ids from `(frame-list)`. Note that
  `select-frame!`/`select-window!` make that frame last-active, so the next
  browser keystroke notwithstanding, subsequent evals stay there.

  TODO: `subscribe` (buffer events pushed as JSON-RPC notifications), auth
  once the socket can leave localhost, MCP server layered on the same core.
  """

  use GenServer

  require Logger

  alias Aimax.Core.Session

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def default_socket_path do
    Application.get_env(:aimax_rpc, :socket_path, Path.expand("~/.aimax/sock"))
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :socket_path, default_socket_path())
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: :line,
        active: false,
        reuseaddr: true
      ])

    server = self()
    {:ok, _} = Task.start_link(fn -> accept_loop(lsock, server) end)
    Logger.info("aimax rpc listening on #{path}")
    {:ok, %{lsock: lsock, path: path}}
  end

  defp accept_loop(lsock, server) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        {:ok, pid} = Task.Supervisor.start_child(Aimax.Rpc.ConnSupervisor, fn -> serve(sock) end)
        :gen_tcp.controlling_process(sock, pid)
        accept_loop(lsock, server)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, line} ->
        :gen_tcp.send(sock, [handle_line(line), "\n"])
        serve(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end

  @doc false
  def handle_line(line) do
    case Jason.decode(line) do
      {:ok, req} -> req |> handle_request() |> Jason.encode!()
      {:error, _} -> Jason.encode!(error_resp(nil, -32700, "parse error"))
    end
  end

  # 600s: a deferred eval (eval-defer!) answers when its Task ends, and only
  # this conn's process waits. The eval runs in this connection's own lane:
  # an agent's long eval must never queue a keystroke behind it, and two
  # connections must not queue behind each other.
  defp handle_request(%{"method" => "eval", "params" => %{"code" => code}} = req) do
    case Session.eval(code, nil, 600_000, {:rpc, self()}) do
      {:ok, printed} ->
        %{jsonrpc: "2.0", id: req["id"], result: printed}

      {:error, msg} ->
        # the same did-you-mean the eval-scheme tool gets. A raw socket
        # client used to receive "unbound variable: buffer-insert" and
        # nothing else, while the tool path handed back the nearest real
        # names with their signatures.
        error_resp(req["id"], -32000, suggest(msg))
    end
  end

  # A client that connects cold used to learn nothing: it got a socket and
  # no idea what was on the other end. `initialize` answers with the
  # primer — what this is, the one call that finds everything else, and the
  # category list — so being useful is one round-trip away.
  defp handle_request(%{"method" => "initialize"} = req) do
    case Session.eval("(hello)") do
      {:ok, printed} ->
        %{jsonrpc: "2.0", id: req["id"], result: %{primer: unquote_printed(printed)}}

      {:error, msg} ->
        error_resp(req["id"], -32000, msg)
    end
  end

  defp handle_request(%{"method" => "reload", "params" => %{"paths" => paths}} = req)
       when is_list(paths) do
    case Session.reload_files(paths) do
      {:ok, count} -> %{jsonrpc: "2.0", id: req["id"], result: %{"reloaded" => count}}
      {:error, msg} -> error_resp(req["id"], -32000, msg)
    end
  end

  defp handle_request(%{"method" => "shutdown"} = req) do
    case Aimax.Core.Desktop.save_now() do
      :ok ->
        Task.start(fn ->
          Process.sleep(100)
          System.stop(0)
        end)

        %{jsonrpc: "2.0", id: req["id"], result: "stopping"}

      :error ->
        error_resp(req["id"], -32000, "desktop save failed; refusing to stop")
    end
  end

  defp handle_request(%{"method" => "ping"} = req),
    do: %{jsonrpc: "2.0", id: req["id"], result: "pong"}

  # `ask` is intentionally not an eval. The connection task can wait for the
  # user while the Scheme Session remains free to process keys and redraws.
  defp handle_request(
         %{
           "method" => "agent/ask",
           "params" => %{"slug" => slug, "question" => question} = params
         } = req
       )
       when is_binary(slug) and is_binary(question) do
    answers =
      case params["answers"] do
        values when is_list(values) -> Enum.map(values, &to_string/1)
        _ -> []
      end

    case Aimax.Core.Agent.ask_user(slug, question, answers) do
      {:ok, answer} -> %{jsonrpc: "2.0", id: req["id"], result: answer}
      {:error, reason} -> error_resp(req["id"], -32000, "ask failed: #{inspect(reason)}")
    end
  end

  defp handle_request(req), do: error_resp(req["id"], -32601, "method not found")

  defp error_resp(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  # eval returns a PRINTED value, so a string comes back quoted
  defp unquote_printed(<<?", _::binary>> = printed) do
    case Code.string_to_quoted(printed) do
      {:ok, s} when is_binary(s) -> s
      _ -> printed
    end
  end

  defp unquote_printed(printed), do: printed

  defp suggest("unbound variable: " <> name = msg) do
    case Session.eval(~s{(tool--format-suggestions (tool--suggest "#{name}"))}) do
      {:ok, printed} ->
        case unquote_printed(printed) do
          "" -> msg
          hits -> msg <> " — did you mean:" <> hits
        end

      _ ->
        msg
    end
  end

  defp suggest(msg), do: msg
end
