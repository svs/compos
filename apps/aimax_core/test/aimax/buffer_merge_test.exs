defmodule Aimax.BufferMergeTest do
  @moduledoc """
  Phase 6 of `docs/PROVENANCE-CRDT.md`: a buffer takes changes another replica
  made.

  The other replica here is a bare `BufferHistory` with its own peer id, driven
  directly. That is what a peer on another machine looks like from this side,
  and it is the only honest way to stand one up in this VM: every buffer in one
  daemon shares that daemon's peer id, so two buffers are not two replicas of
  anything.

  Nothing below is about the wire. It is about whether a change from elsewhere
  lands correctly once it arrives: the point must not jump to it, the rope must
  follow the history, and both sides must agree afterwards.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, BufferHistory, KeyDispatch}

  @peer 424_242

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp buffer(text) do
    name = "merge-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)
    name
  end

  # A replica that already knows everything this buffer knows.
  defp peer_of(name) do
    weave = BufferHistory.new(@peer)
    BufferHistory.import(weave, Buffer.updates_since(name))
    weave
  end

  defp peer_writes(weave, pos, text, actor) do
    BufferHistory.insert(weave, pos, text)
    BufferHistory.commit(weave, actor, ~s({"actor":{"id":"#{actor}","kind":"agent"}}))
    weave
  end

  defp assert_mirrored(name) do
    assert BufferHistory.text(Buffer.history(name)) == Buffer.text(name)
  end

  describe "taking a change from elsewhere" do
    test "the text arrives" do
      name = buffer("")
      weave = peer_of(name) |> peer_writes(0, "shared", "agent:far")

      assert {:ok, true} = Buffer.merge(name, BufferHistory.export_all(weave))
      assert Buffer.text(name) == "shared"
      assert_mirrored(name)
    end

    test "merging the same bytes twice changes nothing the second time" do
      name = buffer("")
      weave = peer_of(name) |> peer_writes(0, "once", "agent:far")
      updates = BufferHistory.export_all(weave)

      assert {:ok, true} = Buffer.merge(name, updates)
      assert {:ok, false} = Buffer.merge(name, updates)
      assert Buffer.text(name) == "once"
    end

    test "who wrote it survives the trip" do
      name = buffer("")
      weave = peer_of(name) |> peer_writes(0, "by an agent", "agent:codex")
      Buffer.merge(name, BufferHistory.export_all(weave))

      ids = Enum.map(Buffer.change_log(name), & &1.actor["id"])
      assert "agent:codex" in ids
    end

    test "a merge is refused rather than accepted half way" do
      name = buffer("intact")
      assert {:error, _} = Buffer.merge(name, "not a history")
      assert Buffer.text(name) == "intact"
      assert_mirrored(name)
    end
  end

  describe "the point" do
    test "an arriving change above the point carries it, rather than moving to it" do
      name = buffer("hello world")
      :ok = Buffer.goto(name, 6)

      weave = peer_of(name) |> peer_writes(0, "XXX", "agent:far")
      Buffer.merge(name, BufferHistory.export_all(weave))

      assert Buffer.text(name) == "XXXhello world"
      assert Buffer.point(name) == 9
    end

    test "an arriving change below the point leaves it alone" do
      name = buffer("hello")
      :ok = Buffer.goto(name, 2)

      weave = peer_of(name) |> peer_writes(5, " there", "agent:far")
      Buffer.merge(name, BufferHistory.export_all(weave))

      assert Buffer.text(name) == "hello there"
      assert Buffer.point(name) == 2
    end
  end

  describe "concurrent work" do
    test "an edit made here and one made there both survive" do
      name = buffer("base")
      weave = peer_of(name)

      # Neither side has seen the other yet.
      Buffer.append(name, "-mine", source: :user)
      peer_writes(weave, 0, "theirs-", "agent:far")

      Buffer.merge(name, BufferHistory.export_all(weave))

      assert Buffer.text(name) =~ "theirs-"
      assert Buffer.text(name) =~ "-mine"
      assert_mirrored(name)
    end

    test "both sides end with the same text" do
      name = buffer("base")
      weave = peer_of(name)

      Buffer.append(name, "-mine", source: :user)
      peer_writes(weave, 0, "theirs-", "agent:far")

      # each takes what the other has
      Buffer.merge(name, BufferHistory.export_all(weave))
      BufferHistory.import(weave, Buffer.updates_since(name))

      assert BufferHistory.text(weave) == Buffer.text(name)
    end

    test "both actors are named in the merged history" do
      name = buffer("base")
      weave = peer_of(name)

      Buffer.append(name, "!", source: {:agent, "one"})
      peer_writes(weave, 0, "?", "agent:two")
      Buffer.merge(name, BufferHistory.export_all(weave))

      ids = Enum.map(Buffer.change_log(name), & &1.actor["id"])
      assert "agent:one" in ids
      assert "agent:two" in ids
    end

    test "typing continues over an arriving change" do
      name = buffer("")
      weave = peer_of(name)
      Aimax.Core.Editor.set_window_buffer(name)
      press(["a", "b"])

      peer_writes(weave, 0, "REMOTE", "agent:far")
      Buffer.merge(name, BufferHistory.export_all(weave))

      press(["c"])
      assert Buffer.text(name) =~ "REMOTE"
      assert_mirrored(name)
    end
  end

  describe "undo across a merge" do
    test "undoing my own work does not take back theirs" do
      name = buffer("")
      weave = peer_of(name)

      Buffer.append(name, "mine", source: :user)
      peer_writes(weave, 0, "THEIRS", "agent:far")
      Buffer.merge(name, BufferHistory.export_all(weave))

      assert :ok = Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "THEIRS"
      assert_mirrored(name)
    end
  end

  describe "asking for what is missing" do
    test "a version token asks for only the changes since it" do
      name = buffer("base")
      token = Buffer.version_token(name)
      Buffer.append(name, " and more", source: :user)

      everything = Buffer.updates_since(name)
      since = Buffer.updates_since(name, token)

      assert byte_size(since) < byte_size(everything)

      weave = BufferHistory.new(@peer)
      BufferHistory.import(weave, everything)
      assert BufferHistory.text(weave) == "base and more"
    end
  end
end
