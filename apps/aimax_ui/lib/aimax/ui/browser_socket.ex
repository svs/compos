defmodule Aimax.Ui.BrowserSocket do
  @moduledoc """
  Raw WebSocket the ai-max Chrome extension dials to reach this daemon.

  No channels and no LiveView — the frames are the `Aimax.Core.Browser`
  protocol, plain JSON in both directions. One extension serves every daemon on
  the machine, so the first thing we send is our name: that's how the options
  page can tell you which port is work and which is home.
  """
  @behaviour Phoenix.Socket.Transport

  alias Aimax.Core.Browser

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(_state), do: {:ok, %{}}

  @impl true
  def init(state) do
    Browser.attach(self())
    hello = Jason.encode!(%{event: "hello", name: Application.get_env(:aimax_core, :name, "aimax")})
    send(self(), {:browser_send, hello})
    {:ok, state}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    Browser.incoming(text)
    {:ok, state}
  end

  @impl true
  def handle_info({:browser_send, text}, state), do: {:push, {:text, text}, state}
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state) do
    Browser.detach(self())
    :ok
  end
end
