defmodule Compos.PeerTest do
  @moduledoc """
  Reaching a peer: `Compos.Core.Peer.eval/2` over the RPC socket.

  Against this daemon's own socket it is a loopback: the reply travels the
  same path a remote peer's would. It lives here because compos_rpc is the
  app that listens on the socket.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Peer

  defp sock, do: Application.get_env(:compos_rpc, :socket_path)

  test "eval crosses the socket and comes back" do
    assert {:ok, "3"} = Peer.eval(sock(), "(+ 1 2)")
  end

  test "a peer that is not there is an error, not a crash" do
    assert {:error, _} = Peer.eval("/tmp/no-such-daemon-#{System.unique_integer()}.sock", "1")
  end

  test "an error on the far side comes back as one" do
    assert {:error, message} = Peer.eval(sock(), "(no-such-function)")
    assert message =~ "no-such-function"
  end
end
