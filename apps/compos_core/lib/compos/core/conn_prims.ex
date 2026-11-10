defmodule Compos.Core.Conn.Prims do
  @moduledoc """
  One door for the connection families: MCP servers, LSP servers,
  endpoints, web servers and databases. Each primitive names its KIND.

  Elixir finds the connections and converts their state maps to plists.
  Scheme picks the fields that a row or a view shows.
  """

  import Compos.Core.Prims
  alias Compos.Core.{DB, Endpoint, LSP, MCP, Roots, WebServer}

  # keys that are internal state, not a fact a view shows
  @hidden [:log, :caps]

  # the kinds whose mechanism sends events to one Scheme handler
  @event_kinds ["mcp", "lsp", "endpoint", "terminal", "terminal-title", "terminal-var", "terminal-exit"]

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      {"conn-list",
       "(conn-list KIND) — return one plist per connection of KIND: mcp, lsp, endpoint, web-server or db."} =>
        fn [kind] -> Enum.map(list(s(kind)), &plist/1) end,
      {"conn-detail",
       "(conn-detail KIND NAME) — return the status plist of one connection, or #f when it never started."} =>
        fn [kind, name] ->
          case detail(s(kind), s(name)) do
            nil -> false
            d -> plist(d)
          end
        end,
      {"conn-log", "(conn-log KIND NAME) — return ((time dir text) ...) frames, oldest first."} =>
        fn [kind, name] ->
          for e <- log(s(kind), s(name)), do: [clock(e.at), to_string(e.dir), e.text]
        end,
      {"on-event!",
       "(on-event! KIND HANDLER) — set the ONE handler for events of KIND: mcp (NAME STATUS), lsp (ID METHOD PARAMS), endpoint (NAME KIND TEXT), terminal (BUF STATUS WAS), each the plist terminal-status answers or #f, terminal-title (BUF TITLE), the OSC 0/2 title the program set, terminal-var (BUF NAME VALUE), a variable the program set with OSC 1337 SetUserVar, terminal-exit (BUF STATUS), the exit code when the buffer's process ends."} =>
        fn [kind, handler] ->
          kind = s(kind)
          unless kind in @event_kinds, do: raise_scheme("on-event!: unknown kind #{kind}")
          Roots.put({:on_event, kind}, handler)
          :void
        end
    }
  end

  defp list("mcp"), do: MCP.connections()
  defp list("lsp"), do: LSP.connections()
  defp list("endpoint"), do: Endpoint.connections()
  defp list("web-server"), do: WebServer.servers()
  defp list("db"), do: DB.connections()
  defp list(kind), do: unknown(kind)

  defp detail("mcp", name), do: MCP.detail(name)
  defp detail("endpoint", name), do: Endpoint.detail(name)
  defp detail("web-server", name), do: WebServer.detail(name)
  defp detail("db", name), do: Enum.find(DB.connections(), &(&1.name == name))

  defp detail("lsp", id) do
    with {name, root} <- LSP.parse_id(id), do: LSP.detail(name, root)
  end

  defp detail(kind, _), do: unknown(kind)

  defp log("mcp", name), do: MCP.log(name)
  defp log("endpoint", name), do: Endpoint.log(name)
  defp log(kind, _) when kind in ["web-server", "db"], do: []

  defp log("lsp", id) do
    case LSP.parse_id(id) do
      {name, root} -> LSP.log(name, root)
      nil -> []
    end
  end

  defp log(kind, _), do: unknown(kind)

  defp unknown(kind), do: raise_scheme("conn: unknown kind #{kind}")

  # a state map -> a plist: atom keys become dashed symbols, string keys
  # (JSON from a server) stay as they are, atoms become strings, nil is #f
  defp plist(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _} -> k in @hidden end)
    |> Enum.sort()
    |> Enum.flat_map(fn {k, v} -> [{:sym, key(k)}, plist(v)] end)
  end

  defp plist(l) when is_list(l), do: Enum.map(l, &plist/1)
  defp plist(nil), do: false
  defp plist(b) when is_boolean(b), do: b
  defp plist(a) when is_atom(a), do: Atom.to_string(a)
  defp plist(v), do: v

  defp key(k) when is_atom(k), do: k |> Atom.to_string() |> String.replace("_", "-")
  defp key(k), do: to_string(k)
end
