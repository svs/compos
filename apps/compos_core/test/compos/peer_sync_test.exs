defmodule Compos.PeerSyncTest do
  @moduledoc """
  Phase 6 of `docs/PROVENANCE-CRDT.md`: syncing over the RPC socket.

  There is no Loro server. Loro emits bytes and something moves them, and what
  moves them here is the socket the daemon already listens on, because eval is
  the API. A peer is a home, named by its socket.

  These are the exchange primitives the sync rides on. Reaching a peer over
  the socket is tested in compos_rpc (PeerTest), where the socket listens;
  peer-sync! and peer-pull! live in their package, and its suite tests them.
  """

  use Compos.Case, async: false

  alias Compos.Core.{Buffer, BufferHistory}

  defp buffer(text) do
    name = "peer-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    name
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
end
