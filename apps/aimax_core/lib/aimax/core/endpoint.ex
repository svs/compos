defmodule Aimax.Core.Endpoint do
  @moduledoc """
  Endpoints: named long-lived connections to the world outside the editor.

  What an endpoint is, when it starts, and what its frames mean is Scheme
  policy; this module is mechanism. An endpoint is an `Endpoint.Conn`
  GenServer keyed by name — one connection per name. Scheme addresses a
  connection by that name and never sees a pid or a port.

  Two transports (exec, tcp) and four framings (line, delimiter,
  content-length, raw) live in `Endpoint.Conn`. Nothing here knows a
  protocol: an endpoint moves frames, and the package on top decides
  whether a frame is JSON-RPC, a SQL result row, or a line of text.

  Unsolicited frames flow to Scheme through one rooted handler
  (`endpoint-on-event!`, stored in :aimax_escaped_closures like the MCP
  and LSP handlers): the handler receives (NAME KIND TEXT), where KIND is
  "frame" for a frame nobody asked for and "status" for a lifecycle
  change. Callbacks run on the connection's own `{:endpoint, name}` lane,
  so a chatty endpoint never queues behind a keystroke.
  """

  alias Aimax.Core.Session
  alias Aimax.Core.Endpoint.Conn

  @escaped :aimax_escaped_closures

  @doc "Start an endpoint. Names are [a-z0-9-]; one connection per name."
  def start(name, spec) when is_binary(name) and is_map(spec) do
    cond do
      not Regex.match?(~r/^[a-z0-9._@-]+$/, name) ->
        {:error, "endpoint names are [a-z0-9._@-]: #{name}"}

      whereis(name) != nil ->
        {:ok, :already}

      true ->
        DynamicSupervisor.start_child(Aimax.Core.EndpointSupervisor, {Conn, {name, spec}})
    end
  end

  def stop(name) do
    case whereis(name) do
      nil -> :ok
      pid -> Conn.stop_gracefully(pid)
    end

    :ok
  end

  def whereis(name) do
    case Registry.lookup(Aimax.Core.EndpointRegistry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "All endpoints: [%{name, status, transport}]."
  def connections do
    Registry.select(Aimax.Core.EndpointRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      d = Conn.detail(pid) || %{status: :busy, transport: :unknown, framing: "", queued: 0}
      Map.merge(d, %{name: name})
    end)
    |> Enum.sort_by(& &1.name)
  end

  def detail(name) do
    case whereis(name) do
      nil ->
        case last(name) do
          nil -> nil
          l -> %{status: l.status, reason: l.reason, transport: :none, framing: "", queued: 0}
        end

      pid ->
        case Conn.detail(pid) do
          nil -> nil
          d -> Map.put(d, :reason, "")
        end
    end
  end

  def log(name) do
    case whereis(name) do
      nil -> (last(name) || %{log: []}).log
      pid -> Conn.log(pid)
    end
  end

  @doc "Tell the Scheme handler an endpoint changed state."
  def notify(name, status), do: dispatch(name, "status", to_string(status))

  @doc "Forward an unsolicited frame to the Scheme handler."
  def dispatch_frame(name, frame), do: dispatch(name, "frame", frame)

  defp dispatch(name, kind, text) do
    with tid when tid != :undefined <- :ets.whereis(@escaped),
         [{_, handler}] <- :ets.lookup(tid, {:endpoint_handler}) do
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        Session.apply_callback(handler, [name, kind, text], nil, {:endpoint, name})
      end)
    end

    :ok
  end

  @doc "What a connection left behind when it stopped: %{status, reason, log}."
  def remember(name, record), do: :persistent_term.put({:aimax_endpoint_last, name}, record)

  def last(name), do: :persistent_term.get({:aimax_endpoint_last, name}, nil)
end
