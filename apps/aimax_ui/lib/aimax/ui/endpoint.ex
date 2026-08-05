defmodule Aimax.Ui.Endpoint do
  use Phoenix.Endpoint, otp_app: :aimax_ui

  @session_options [
    store: :cookie,
    key: "_aimax_key",
    signing_salt: "aimax-ui-salt",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  # LiveView's browser JS is shipped prebuilt inside the hex packages —
  # serve it straight from deps; no node/esbuild toolchain.
  plug Plug.Static, at: "/phx", from: {:phoenix, "priv/static"}
  plug Plug.Static, at: "/lv", from: {:phoenix_live_view, "priv/static"}

  plug Plug.Session, @session_options
  plug Aimax.Ui.Router
end
