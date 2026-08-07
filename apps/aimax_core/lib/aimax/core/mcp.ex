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
  Session.call_fn would block every keystroke for its duration.

  Server names are [a-z0-9-] so the qualified form splits unambiguously.
  """

  alias Aimax.Core.MCP.Conn

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

  @doc "All connections: [%{name, status, tools}]."
  def connections do
    Registry.select(Aimax.Core.MCPRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {name, pid} ->
      %{name: name, status: Conn.status(pid), tools: length(specs_for(name))}
    end)
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
