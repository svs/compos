defmodule Compos.Core.WebServer do
  @moduledoc """
  Programmable HTTP servers owned by Scheme callers.

  Each named server has its own Bandit listener and Scheme handler. Bandit
  owns sockets, HTTP parsing, and response writes. The handler decides all
  routing and response policy from request data.
  """

  use GenServer, restart: :temporary

  alias Compos.Core.{Lane, Session}

  @registry Compos.Core.WebServerRegistry
  @supervisor Compos.Core.WebServerSupervisor
  @escaped :compos_escaped_closures
  @default_max_body 1_048_576

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    @impl true
    def init(name), do: name

    @impl true
    def call(conn, name) do
      case Compos.Core.WebServer.read_request(conn, name) do
        {:ok, request, conn} ->
          name
          |> Compos.Core.WebServer.dispatch(request)
          |> send_response(conn)

        {:error, :too_large, conn} ->
          send_resp(conn, 413, "request body is too large")

        {:error, reason, conn} ->
          send_resp(conn, 400, "could not read request body: #{reason}")
      end
    end

    defp send_response({:ok, response}, conn) do
      response.headers
      |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
      |> send_resp(response.status, response.body)
    end

    defp send_response({:error, reason}, conn), do: send_resp(conn, 500, reason)
  end

  @doc "Start one named server. Port zero asks the OS for an unused port."
  def start(name, spec, handler) when is_binary(name) and is_map(spec) do
    cond do
      not Regex.match?(~r/^[a-z0-9._@-]+$/, name) ->
        {:error, "web server names are [a-z0-9._@-]: #{name}"}

      whereis(name) != nil ->
        {:error, "web server already exists: #{name}"}

      true ->
        lane = Lane.current() || {:web_server, name}

        child = %{
          id: {__MODULE__, name},
          start: {__MODULE__, :start_link, [{name, spec, handler, lane}]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, child) do
          {:ok, pid} -> {:ok, detail(pid)}
          {:error, reason} -> {:error, start_error(reason)}
        end
    end
  end

  def start_link({name, spec, handler, lane}) do
    GenServer.start_link(__MODULE__, {name, spec, handler, lane},
      name: {:via, Registry, {@registry, name}}
    )
  end

  @doc "Stop one server. Stopping a missing server succeeds."
  def stop(name) do
    result =
      case whereis(name) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
      end

    if :ets.whereis(@escaped) != :undefined,
      do: :ets.delete(@escaped, {:web_server_handler, name})

    result
  end

  def whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Return all running servers in name order."
  def servers do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {_name, pid} -> if detail = safe_detail(pid), do: [detail], else: [] end)
    |> Enum.sort_by(& &1.name)
  end

  def detail(name) when is_binary(name) do
    case whereis(name) do
      nil -> nil
      pid -> safe_detail(pid)
    end
  end

  def detail(pid) when is_pid(pid), do: GenServer.call(pid, :detail)

  defp safe_detail(pid) do
    GenServer.call(pid, :detail)
  catch
    :exit, _reason -> nil
  end

  @doc false
  def read_request(conn, name) do
    max_body = GenServer.call(whereis(name), :max_body)

    case read_body(conn, max_body, "") do
      {:ok, body, conn} ->
        remote = conn.remote_ip |> :inet.ntoa() |> to_string()

        request = [
          {:sym, "method"},
          conn.method,
          {:sym, "path"},
          conn.request_path,
          {:sym, "query"},
          conn.query_string,
          {:sym, "headers"},
          Enum.map(conn.req_headers, fn {key, value} -> [key, value] end),
          {:sym, "body"},
          body,
          {:sym, "remote-address"},
          remote
        ]

        {:ok, request, conn}

      error ->
        error
    end
  end

  @doc false
  def dispatch(name, request) do
    with pid when is_pid(pid) <- whereis(name),
         %{handler: handler, lane: lane} <- GenServer.call(pid, :handler),
         {:ok, value} <- Session.call_fn(handler, [request], nil, lane, "web server #{name}"),
         {:ok, response} <- response(value) do
      {:ok, response}
    else
      nil -> {:error, "web server stopped"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    error -> {:error, "web server handler failed: #{Exception.message(error)}"}
  catch
    :exit, reason -> {:error, "web server handler failed: #{inspect(reason)}"}
  end

  @impl true
  def init({name, spec, handler, lane}) do
    with {:ok, ip, host} <- bind_address(Map.get(spec, "host", "127.0.0.1")),
         {:ok, port} <- port(Map.get(spec, "port", 0)),
         {:ok, max_body} <- max_body(Map.get(spec, "max-body", @default_max_body)),
         {:ok, bandit} <-
           Bandit.start_link(
             plug: {Plug, name},
             scheme: :http,
             ip: ip,
             port: port,
             startup_log: false
           ),
         {:ok, {_address, bound_port}} <- ThousandIsland.listener_info(bandit) do
      :ets.insert(@escaped, {{:web_server_handler, name}, handler})

      {:ok,
       %{
         name: name,
         host: host,
         port: bound_port,
         url: "http://#{url_host(host)}:#{bound_port}",
         max_body: max_body,
         handler: handler,
         lane: lane,
         bandit: bandit
       }}
    else
      {:error, reason} -> {:stop, reason}
      :error -> {:stop, "could not read the bound port"}
    end
  end

  @impl true
  def handle_call(:detail, _from, state) do
    {:reply, Map.take(state, [:name, :host, :port, :url, :max_body]), state}
  end

  def handle_call(:handler, _from, state) do
    {:reply, Map.take(state, [:handler, :lane]), state}
  end

  def handle_call(:max_body, _from, state), do: {:reply, state.max_body, state}

  @impl true
  def terminate(_reason, state) do
    if :ets.whereis(@escaped) != :undefined,
      do: :ets.delete(@escaped, {:web_server_handler, state.name})

    :ok
  end

  defp read_body(conn, remaining, acc) do
    case Elixir.Plug.Conn.read_body(conn,
           length: remaining + 1,
           read_length: min(remaining + 1, 64_000)
         ) do
      {:ok, body, conn} when byte_size(body) <= remaining ->
        {:ok, acc <> body, conn}

      {:ok, _body, conn} ->
        {:error, :too_large, conn}

      {:more, body, conn} when byte_size(body) <= remaining ->
        read_body(conn, remaining - byte_size(body), acc <> body)

      {:more, _body, conn} ->
        {:error, :too_large, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp response(body) when is_binary(body), do: {:ok, %{status: 200, headers: [], body: body}}

  defp response(plist) when is_list(plist) do
    values =
      plist
      |> Enum.chunk_every(2)
      |> Map.new(fn
        [{:sym, key}, value] -> {key, value}
        [key, value] -> {to_string(key), value}
      end)

    status = Map.get(values, "status", 200)
    body = Map.get(values, "body", "")
    headers = Map.get(values, "headers", [])

    cond do
      not (is_integer(status) and status in 100..599) ->
        {:error, "response status must be an HTTP status integer"}

      not is_binary(body) ->
        {:error, "response body must be a string"}

      true ->
        response_headers(headers, status, body)
    end
  end

  defp response(_), do: {:error, "handler must return a response plist or body string"}

  defp response_headers(headers, status, body) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      [key, value], {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{String.downcase(key), value} | acc]}}

      _, _ ->
        {:halt, {:error, "response headers must be (NAME VALUE) string pairs"}}
    end)
    |> case do
      {:ok, parsed} -> {:ok, %{status: status, headers: Enum.reverse(parsed), body: body}}
      error -> error
    end
  end

  defp response_headers(_, _, _), do: {:error, "response headers must be a list"}

  defp bind_address("127.0.0.1"), do: {:ok, {127, 0, 0, 1}, "127.0.0.1"}
  defp bind_address("localhost"), do: {:ok, {127, 0, 0, 1}, "127.0.0.1"}
  defp bind_address("loopback"), do: {:ok, :loopback, "127.0.0.1"}
  defp bind_address("0.0.0.0"), do: {:ok, {0, 0, 0, 0}, "0.0.0.0"}
  defp bind_address("any"), do: {:ok, :any, "0.0.0.0"}

  defp bind_address(host) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} ->
        {:ok, ip, host}

      {:error, _} ->
        {:error, "web server host must be an IP address, localhost, loopback, or any"}
    end
  end

  defp bind_address(_), do: {:error, "web server host must be a string"}

  defp port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  defp port(_), do: {:error, "web server port must be an integer from 0 through 65535"}

  defp max_body(bytes) when is_integer(bytes) and bytes > 0, do: {:ok, bytes}
  defp max_body(_), do: {:error, "web server max-body must be a positive integer"}

  defp url_host("0.0.0.0"), do: "127.0.0.1"
  defp url_host(host), do: host

  defp start_error({:shutdown, reason}), do: start_error(reason)
  defp start_error({:failed_to_start_child, _child, reason}), do: start_error(reason)
  defp start_error(reason) when is_binary(reason), do: reason
  defp start_error(reason), do: inspect(reason)
end
