defmodule Compos.Core.LSP do
  @moduledoc """
  LSP client: language servers as project-scoped subprocesses.

  Which servers exist, which modes attach, and what the results look
  like is Scheme policy (packages/lsp.scm); this module is mechanism.
  A connection is an `LSP.Conn` GenServer keyed {name, root} — one
  server per project root. Scheme addresses a connection by the id
  string `"name@root"`, built and parsed only here.

  Events flow to Scheme through one rooted handler (`lsp-on-event!`,
  stored in :compos_escaped_closures like the MCP handler): the handler
  receives (ID METHOD PARAMS). Status changes arrive on the same pipe
  as method "compos/status". Callbacks run on the connection's own
  `{:lsp, key}` lane, so a diagnostics burst never queues behind a
  keystroke.
  """

  alias Compos.Core.{Session, LLM}
  alias Compos.Core.LSP.Conn

  @escaped :compos_escaped_closures

  def start(name, root, spec) when is_binary(name) and is_binary(root) do
    cond do
      not Regex.match?(~r/^[a-z0-9-]+$/, name) ->
        {:error, "lsp server names are [a-z0-9-]: #{name}"}

      not String.starts_with?(root, "/") ->
        {:error, "lsp root must be an absolute path: #{root}"}

      whereis(name, root) != nil ->
        {:ok, :already}

      true ->
        DynamicSupervisor.start_child(Compos.Core.LSPSupervisor, {Conn, {{name, root}, spec}})
    end
  end

  def stop(name, root) do
    case whereis(name, root) do
      nil -> :ok
      pid -> Conn.stop_gracefully(pid)
    end

    :ok
  end

  def whereis(name, root) do
    case Registry.lookup(Compos.Core.LSPRegistry, {name, root}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "All connections: [%{id, name, root, status}]."
  def connections do
    Registry.select(Compos.Core.LSPRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {{name, root} = key, pid} ->
      %{id: id_string(key), name: name, root: root, status: Conn.status(pid)}
    end)
  end

  def detail(name, root) do
    case whereis(name, root) do
      nil ->
        case last({name, root}) do
          nil -> nil
          l -> %{status: l.status, reason: l.reason, docs: [], log: l.log}
        end

      pid ->
        case Conn.detail(pid) do
          nil -> nil
          d -> Map.merge(d, %{log: Conn.log(pid), reason: ""})
        end
    end
  end

  def log(name, root) do
    case whereis(name, root) do
      nil -> (last({name, root}) || %{log: []}).log
      pid -> Conn.log(pid)
    end
  end

  def id_string({name, root}), do: "#{name}@#{root}"

  @doc "\"name@/abs/root\" -> {name, root} | nil."
  def parse_id(id) when is_binary(id) do
    case String.split(id, "@", parts: 2) do
      [name, root] when root != "" -> {name, root}
      _ -> nil
    end
  end

  def parse_id(_), do: nil

  @doc "Tell the Scheme handler a connection changed state."
  def notify(key, status),
    do: dispatch_event(key, "compos/status", %{"status" => to_string(status)})

  @doc "Forward a server event to the Scheme handler, on the connection's lane."
  def dispatch_event(key, method, params) do
    with tid when tid != :undefined <- :ets.whereis(@escaped),
         [{_, handler}] <- :ets.lookup(tid, {:lsp_handler}) do
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        Session.apply_callback(
          handler,
          [id_string(key), method, LLM.json_to_scheme(params)],
          nil,
          {:lsp, key}
        )
      end)
    end

    :ok
  end

  @doc "What a connection left behind when it stopped: %{status, reason, log}."
  def remember(key, record), do: :persistent_term.put({:compos_lsp_last, key}, record)

  def last(key), do: :persistent_term.get({:compos_lsp_last, key}, nil)
end
