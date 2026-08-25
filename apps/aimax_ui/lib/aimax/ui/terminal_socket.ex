defmodule Aimax.Ui.TerminalSocket do
  use Phoenix.Socket

  channel("terminal", Aimax.Ui.TerminalChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
