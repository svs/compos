defmodule Compos.Ui.TerminalChannelTest do
  use ExUnit.Case

  import Phoenix.ChannelTest

  alias Compos.Core.Terminal

  @endpoint Compos.Ui.Endpoint

  test "the channel carries raw PTY output and input without LiveView" do
    name = "*terminal-channel-#{System.unique_integer([:positive])}*"
    {:ok, _} = Terminal.start(name, "cat")

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Compos.Core.kill_buffer(name)
    end)

    {:ok, socket} = connect(Compos.Ui.TerminalSocket, %{})

    {:ok, %{history: history}, socket} =
      subscribe_and_join(socket, "terminal", %{"buffer" => name})

    assert is_binary(history)
    push(socket, "input", %{"data" => "channel-round-trip\n"})

    assert_push("output", %{data: encoded}, 2_000)
    assert Base.decode64!(encoded) =~ "channel-round-trip"
  end
end
