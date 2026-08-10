defmodule Aimax.Rpc.Server do
  @moduledoc """
  JSON-RPC 2.0 over a Unix domain socket, newline-delimited — the aimax
  "Thin Transport, Thick Scheme" control port. `eval` is the primary API:
  agents script atomic multi-step actions in one round-trip.

      echo '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"code":"(+ 1 2)"}}' \\
        | nc -U ~/.aimax/sock

  Methods: `eval` (params.code), `ping`.

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

  defp handle_request(%{"method" => "eval", "params" => %{"code" => code}} = req) do
    case Session.eval(code) do
      {:ok, printed} -> %{jsonrpc: "2.0", id: req["id"], result: printed}
      {:error, msg} -> error_resp(req["id"], -32000, msg)
    end
  end

  defp handle_request(%{"method" => "ping"} = req),
    do: %{jsonrpc: "2.0", id: req["id"], result: "pong"}

  defp handle_request(req), do: error_resp(req["id"], -32601, "method not found")

  defp error_resp(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
end
