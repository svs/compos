defmodule Compos.Ui.TerminalChannel do
  @moduledoc """
  A direct terminal wire that bypasses LiveView rendering.

  The channel carries raw PTY output as base64 and sends input and terminal
  geometry back to the core terminal process.
  """

  use Phoenix.Channel

  alias Compos.Core.Terminal

  @impl true
  def join("terminal", %{"buffer" => buffer}, socket) when is_binary(buffer) do
    case Terminal.subscribe(buffer) do
      {:ok, history} ->
        # the size rides with the transcript: it is the width the bytes wrapped at
        {cols, rows} = Terminal.size(buffer)

        {:ok, %{history: Base.encode64(history), cols: cols, rows: rows},
         assign(socket, :buffer, buffer)}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  def join("terminal", _params, _socket), do: {:error, %{reason: "missing buffer"}}

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    Terminal.send_text(socket.assigns.buffer, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and cols > 0 and is_integer(rows) and rows > 0 do
    Terminal.resize(socket.assigns.buffer, cols, rows)
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:terminal_data, buffer, data}, %{assigns: %{buffer: buffer}} = socket) do
    push(socket, "output", %{data: Base.encode64(data)})
    {:noreply, socket}
  end

  def handle_info({:terminal_renamed, buffer, new}, %{assigns: %{buffer: buffer}} = socket) do
    {:noreply, assign(socket, :buffer, new)}
  end

  def handle_info({:terminal_exit, buffer, status}, %{assigns: %{buffer: buffer}} = socket) do
    push(socket, "exit", %{status: status})
    {:noreply, socket}
  end
end
