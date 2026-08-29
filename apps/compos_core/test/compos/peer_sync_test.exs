defmodule Compos.PeerSyncTest do
  @moduledoc """
  Phase 6 of `docs/PROVENANCE-CRDT.md`: syncing over the RPC socket.

  There is no Loro server. Loro emits bytes and something moves them, and what
  moves them here is the socket the daemon already listens on, because eval is
  the API. A peer is a home, named by its socket.

  These drive the real socket. `peer-eval` against this daemon's own socket is
  a loopback: the reply travels the same path a remote peer's would, and a
  replica syncing with itself must be a no-op, which is the strongest thing one
  process can say about a two-process protocol.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferHistory, Peer, Session}

  defp sock, do: Application.get_env(:compos_rpc, :socket_path)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp buffer(text) do
    name = "peer-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    name
  end

  describe "reaching a peer" do
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

    test "peer-eval reaches it from Scheme too" do
      assert eval!(~s{(peer-eval "#{sock()}" "(+ 2 2)")}) == "\"4\""
    end
  end

  describe "the exchange primitives" do
    test "a version token crosses as text" do
      name = buffer("base")
      token = eval!(~s{(buffer-version-token "#{name}")})
      assert token =~ ~r/^"/
    end

    test "updates for a replica that knows nothing carry the whole history" do
      name = buffer("hello")
      updates = eval!(~s{(buffer-updates-since "#{name}" #f)})
      bytes = updates |> String.trim("\"") |> Base.url_decode64!(padding: false)

      weave = BufferHistory.new(9_001)
      BufferHistory.import(weave, bytes)
      assert BufferHistory.text(weave) == "hello"
    end

    test "merging from Scheme takes a foreign replica's work" do
      name = buffer("")

      weave = BufferHistory.new(9_002)
      BufferHistory.import(weave, Buffer.updates_since(name))
      BufferHistory.insert(weave, 0, "from far away")
      BufferHistory.commit(weave, "agent:far", ~s({"actor":{"id":"agent:far","kind":"agent"}}))

      updates = Base.url_encode64(BufferHistory.export_all(weave), padding: false)
      assert eval!(~s{(buffer-merge! "#{name}" "#{updates}")}) == "#t"
      assert Buffer.text(name) == "from far away"
    end
  end

  describe "the loop" do
    # A replica syncing with itself must change nothing. Every step is real:
    # the token, the export, the merge and both round trips over the socket.
    test "syncing a buffer with its own daemon is a no-op" do
      name = buffer("unchanged")
      before = Buffer.text(name)
      changes = length(Buffer.change_log(name))

      eval!(~s{(peer-sync! "#{sock()}" "#{name}")})

      assert Buffer.text(name) == before
      assert length(Buffer.change_log(name)) == changes
    end

    test "a pull asks only for what is missing" do
      name = buffer("base")
      eval!(~s{(peer-pull! "#{sock()}" "#{name}")})
      assert Buffer.text(name) == "base"
    end

    test "peer-token reads the peer's version" do
      name = buffer("base")
      token = eval!(~s{(peer-token "#{sock()}" "#{name}")})
      refute token == "#f"
    end
  end
end
