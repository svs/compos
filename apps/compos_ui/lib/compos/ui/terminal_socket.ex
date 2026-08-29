defmodule Compos.Ui.TerminalSocket do
  use Phoenix.Socket

  channel("terminal", Compos.Ui.TerminalChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
