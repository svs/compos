defmodule Aimax.Core.MCP do
  @moduledoc """
  MCP client: connect external Model Context Protocol servers and expose
  their tools to the LLM tool loop.

  Which servers exist and when to connect them is Scheme policy
  (packages/mcp.scm); this module is mechanism only. A connection is a
  `MCP.Conn` GenServer speaking JSON-RPC over stdio (spawned subprocess)
  or streamable HTTP. Once the handshake finishes, the server's tools are
  published to :persistent_term as specs shaped like the Scheme tool
  registry — `[qualified_name, description, input_schema_json]` — so
  `llm-tool-specs`-style lists can carry them unchanged.

  Tool names are qualified `mcp__<server>__<tool>` (Anthropic tool-name
  charset). `LLM.run_tool/3` routes that prefix straight here — MCP calls
  must NOT dispatch through the Scheme session: a slow web fetch inside
  Session.call_fn would block every keystroke for its duration. Scheme
  calls a tool with `mcp-call!`, and that primitive obeys the same rule —
  it runs `call_when_ready/4` in a task, never in the session process.

  Server names are [a-z0-9-] so the qualified form splits unambiguously.
  """

  alias Aimax.Core.{Session}
  alias Aimax.Core.MCP.Conn

  @escaped :aimax_escaped_closures

  def connect(name, spec) when is_binary(name) do
    cond do
      not Regex.match?(~r/^[a-z0-9-]+$/, name) ->
        {:error, "mcp server names are [a-z0-9-]: #{name}"}

      connected?(name) ->
        {:ok, :already}

      true ->
        DynamicSupervisor.start_child(Aimax.Core.MCPSupervisor, {Conn, {name, spec}})
    end
  end

  def disconnect(name) do
    case whereis(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Aimax.Core.MCPSupervisor, pid)
    end

    :persistent_term.erase({:aimax_mcp, name})
    :ok
  end

  def connected?(name), do: whereis(name) != nil

  def whereis(name) do
    case Registry.lookup(Aimax.Core.MCPRegistry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "All connections: [%{name, status, type, tools, resources, prompts}]."
  def connections do
    Registry.select(Aimax.Core.MCPRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      s = Conn.summary(pid)

      %{
        name: name,
        status: s.status,
        type: s.type,
        tools: length(specs_for(name)),
        resources: s.resources,
        prompts: s.prompts
      }
    end)
  end

  @doc """
  Everything the hub's detail view shows for one server, live or dead:
  %{status, type, server_info, tools, resources, prompts, log}. A server
  that died leaves the record `remember/2` stored, so the row that just
  went red can still say why.
  """
  def detail(name) do
    case whereis(name) do
      nil ->
        case last(name) do
          nil -> nil
          l -> %{status: l.status, type: :unknown, server_info: %{}, tools: [],
                 resources: [], prompts: [], log: l.log, reason: l.reason}
        end

      pid ->
        case Conn.detail(pid) do
          nil -> nil
          d -> Map.merge(d, %{tools: tools_of(name), log: Conn.log(pid), reason: ""})
        end
    end
  end

  @doc "The frame log for a server, live or last-known."
  def log(name) do
    case whereis(name) do
      nil -> (last(name) || %{log: []}).log
      pid -> Conn.log(pid)
    end
  end

  @doc """
  Tell Scheme a server changed state, if anything registered interest
  (`mcp-on-change!`). A hub whose rows sit on "connecting" forever reads as
  broken, and there is no timer in the editor to poll with.
  """
  def notify(name, status) do
    with tid when tid != :undefined <- :ets.whereis(@escaped),
         [{_, handler}] <- :ets.lookup(tid, {:mcp_handler}) do
      Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
        Session.apply_callback(handler, [name, to_string(status)])
      end)
    end

    :ok
  end

  @doc "What a connection left behind when it stopped: %{status, reason, log}."
  def remember(name, record), do: :persistent_term.put({:aimax_mcp_last, name}, record)

  def last(name), do: :persistent_term.get({:aimax_mcp_last, name}, nil)

  # [name, description] per bridged tool, unqualified — the detail view
  # reads like the server's own documentation, not like our tool namespace
  defp tools_of(name) do
    prefix = "mcp__#{name}__"

    for [qualified, desc | _] <- specs_for(name),
        do: [String.replace_prefix(qualified, prefix, ""), desc]
  end

  @doc "Scheme-shaped tool specs for the given server names (ready servers only)."
  def tool_specs(names), do: Enum.flat_map(names, &specs_for/1)

  defp specs_for(name) do
    case :persistent_term.get({:aimax_mcp, name}, nil) do
      %{specs: specs} -> specs
      _ -> []
    end
  end

  @doc "Call a tool by qualified name (mcp__server__tool) with a JSON args map."
  def call_qualified("mcp__" <> rest, args) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] -> call(server, tool, args)
      _ -> {:error, "bad mcp tool name: mcp__#{rest}"}
    end
  end

  def call_qualified(name, _), do: {:error, "bad mcp tool name: #{name}"}

  @doc """
  Call a tool, waiting up to `wait_ms` for a server that is still shaking
  hands. A caller that connects a server and calls it in the same breath
  has no other way to know when the tools arrive. Run this in a task: it
  sleeps.
  """
  def call_when_ready(server, tool, args, wait_ms) do
    if await_ready(server, wait_ms),
      do: call(server, tool, args),
      else: {:error, "mcp server not connected: #{server}"}
  end

  @doc "Wait for the handshake to publish a server's tools. Run this in a task: it sleeps."
  def await_ready(server, wait_ms) do
    cond do
      ready?(server) -> true
      whereis(server) == nil -> false
      wait_ms <= 0 -> false
      true ->
        Process.sleep(50)
        await_ready(server, wait_ms - 50)
    end
  end

  @doc "True once the handshake published the server's tools."
  def ready?(server), do: :persistent_term.get({:aimax_mcp, server}, nil) != nil

  def call(server, qualified_tool, args) do
    with pid when pid != nil <- whereis(server),
         %{tools: tools} <- :persistent_term.get({:aimax_mcp, server}, nil) do
      # the wire name may differ from the qualified segment (charset mangling)
      tool = Map.get(tools, qualified_tool, qualified_tool)
      Conn.call_tool(pid, tool, args)
    else
      _ -> {:error, "mcp server not connected: #{server}"}
    end
  end

  @doc false
  def publish(name, tools) do
    specs =
      for t <- tools do
        [
          "mcp__#{name}__#{sanitize(t["name"])}",
          t["description"] || t["name"],
          Jason.encode!(t["inputSchema"] || %{"type" => "object", "properties" => %{}})
        ]
      end

    wire_names = Map.new(tools, fn t -> {sanitize(t["name"]), t["name"]} end)
    :persistent_term.put({:aimax_mcp, name}, %{specs: specs, tools: wire_names})
  end

  defp sanitize(tool), do: String.replace(tool, ~r/[^a-zA-Z0-9_-]/, "_")
end
