defmodule Aimax.Ui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # server generation id: clients that reconnect across a restart detect the
    # mismatch and full-reload, so stale CSS/JS never renders new markup
    :persistent_term.put(:aimax_boot_id, Integer.to_string(System.system_time(:millisecond)))

    # the app origin's password, new on every boot: an app URL from the last
    # run reaches nothing
    :persistent_term.put(
      :aimax_app_token,
      :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    )

    # the address this editor answers on. Scheme reads it through
    # (editor-url) to write a buffer link; aimax_core must not depend on
    # this app, so the value travels as a term, not as a call.
    :persistent_term.put(:aimax_editor_url, "http://localhost:#{http_port()}")

    children =
      [
        Aimax.Ui.Telemetry,
        {Phoenix.PubSub, name: Aimax.Ui.PubSub},
        Aimax.Ui.Oembed,
        Aimax.Ui.Endpoint
      ] ++ app_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Ui.Supervisor)
  end

  defp http_port do
    Application.get_env(:aimax_ui, Aimax.Ui.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4004)
  end

  # A second origin, on loopback, that serves previewed apps and nothing
  # else. `app_port: nil` (the test env) leaves it off; the router is a
  # plain Plug, so the tests call it without a socket.
  defp app_server do
    case Application.get_env(:aimax_ui, :app_port) do
      nil ->
        []

      port ->
        [
          # the fixed id lets Aimax.Core.Daemon.restart_listener/1 find and
          # bounce this child by name
          Supervisor.child_spec(
            {Bandit,
             plug: Aimax.Ui.AppServer, scheme: :http, ip: {127, 0, 0, 1}, port: port,
             startup_log: false},
            id: :aimax_app_server
          )
        ]
    end
  end
end
