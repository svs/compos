defmodule Compos.Ui.Endpoint do
  use Phoenix.Endpoint, otp_app: :compos_ui

  @session_options [
    store: :cookie,
    key: "_compos_key",
    signing_salt: "compos-ui-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  socket("/terminal", Compos.Ui.TerminalSocket,
    websocket: [check_origin: true],
    longpoll: false
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
  end

  # The Chrome extension's wire. The extension dials from its service worker,
  # so Chrome stamps Origin: chrome-extension://<id> on the handshake. A web
  # page cannot forge that header, so the origin check rejects every https://
  # page that dials this loopback port — the one real attacker here, since a
  # page you visit runs on your machine and reaches 127.0.0.1 too. Loopback
  # alone does not stop it. path: "/" mounts it at /browser rather than
  # Phoenix's default /browser/websocket — the extension scans ports, so the
  # address it dials should be the one a person would write down.
  socket("/browser", Compos.Ui.BrowserSocket,
    websocket: [check_origin: {__MODULE__, :browser_origin?, []}, path: "/"],
    longpoll: false
  )

  # LiveView's browser JS is shipped prebuilt inside the hex packages —
  # serve it straight from deps; no node/esbuild toolchain.
  plug(Plug.Static, at: "/phx", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/lv", from: {:phoenix_live_view, "priv/static"})

  # the PWA manifest and icons — Chrome installs the editor as its own app
  plug(Plug.Static, at: "/", from: :compos_ui, only: ~w(manifest.webmanifest icons images))

  # Tidewave is an MCP server over the running daemon: a coding agent evaluates
  # Elixir in this VM, reads the logs, and reads the docs of the locked deps.
  # It mounts at /tidewave/mcp. Dev only, so a release never carries it.
  if Mix.env() == :dev do
    plug(Tidewave)
  end

  if code_reloading? do
    plug(Phoenix.LiveReloader)
    # No Phoenix.CodeReloader here. That plug compiles in this VM on a page
    # load, and an in-process compile unloads a stale module before it
    # compiles the new one; Compos.Core.Editor died in that gap. Only
    # Compos.Core.Hotload recompiles, out of process, and swaps the changed
    # modules in with no gap.
    #
    # A swap replaces the module the Scheme primitives were captured from.
    # A primitive is an anonymous fun, and a fun from a purged version
    # raises "function #Function<...> is invalid" on the next keystroke.
    # Hotload rebinds after every swap; this closes the window before a
    # request reaches a LiveView.
    plug(:rebind_scheme_primitives)
  end

  plug(Plug.Session, @session_options)

  plug(Compos.Ui.Router)

  @doc false
  def rebind_scheme_primitives(conn, _opts) do
    Compos.Core.Session.refresh_primitives_if_stale()
    conn
  rescue
    _ -> conn
  catch
    :exit, _ -> conn
  end

  @doc """
  Accept the browser bridge only from a Chrome extension origin.

  Phoenix passes the parsed Origin URI. The extension's service worker dials
  with scheme "chrome-extension"; a web page dials with "http"/"https" and
  cannot change that header. So this refuses every page and admits the
  extension. Any installed extension passes — pin the id with a manifest "key"
  and match uri.host to tighten this to one extension.
  """
  def browser_origin?(%URI{scheme: "chrome-extension"}), do: true
  def browser_origin?(_), do: false
end
