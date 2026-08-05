defmodule Aimax.Ui.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # server generation id: clients that reconnect across a restart detect the
    # mismatch and full-reload, so stale CSS/JS never renders new markup
    :persistent_term.put(:aimax_boot_id, Integer.to_string(System.system_time(:millisecond)))

    children = [
      {Phoenix.PubSub, name: Aimax.Ui.PubSub},
      Aimax.Ui.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aimax.Ui.Supervisor)
  end
end
