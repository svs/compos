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

    children =
      [
        {Phoenix.PubSub, name: Aimax.Ui.PubSub},
        Aimax.Ui.Oembed,
        Aimax.Ui.Endpoint
      ] ++ app_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Ui.Supervisor)
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
          {Bandit,
           plug: Aimax.Ui.AppServer, scheme: :http, ip: {127, 0, 0, 1}, port: port,
           startup_log: false}
        ]
    end
  end
end
