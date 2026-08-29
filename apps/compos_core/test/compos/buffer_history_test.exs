defmodule Compos.BufferHistoryTest do
  use ExUnit.Case, async: true

  alias Compos.Core.BufferHistory, as: History

  @human "user:local"
  @agent "agent:codex"

  # A document with both actors registered, each blind to the other's work.
  defp two_actor_doc(peer \\ 1) do
    weave = History.new(peer)
    :ok = History.register_actor(weave, @human, ["agent"])
    :ok = History.register_actor(weave, @agent, ["user"])
    weave
  end

  defp write(weave, pos, text, origin, actor) do
    History.insert(weave, pos, text)
    History.commit(weave, origin, actor <> "|" <> text)
    weave
  end

  describe "text" do
    test "inserts and deletes at byte offsets" do
      weave = History.new(1)
      assert History.insert(weave, 0, "hello world") == 11
      assert History.delete(weave, 5, 6) == 5
      assert History.text(weave) == "hello"
      assert History.byte_size(weave) == 5
    end

    test "counts bytes, not characters" do
      weave = History.new(1)
      History.insert(weave, 0, "héllo")
      assert History.byte_size(weave) == 6
      assert History.text(weave) == "héllo"
    end

    test "update replaces the whole text" do
      weave = History.new(1)
      History.insert(weave, 0, "one two three")
      History.commit(weave, "user", "seed")

      assert History.update(weave, "one TWO three") == 13
      assert History.text(weave) == "one TWO three"
    end
  end

  describe "attribution" do
    test "the commit message survives an export and reopen" do
      weave = History.new(7)
      write(weave, 0, "AAA", "user", @human)
      write(weave, 3, "BBB", "agent:codex", @agent)

      {:ok, reopened} = History.open(9, History.export_snapshot(weave))

      assert History.text(reopened) == "AAABBB"
      messages = Enum.map(History.changes(reopened), & &1.message)
      assert messages == ["#{@human}|AAA", "#{@agent}|BBB"]
    end

    test "history records the writing peer, not the reader" do
      weave = History.new(7)
      write(weave, 0, "AAA", "user", @human)

      {:ok, reopened} = History.open(9, History.export_snapshot(weave))
      assert [%{peer: 7}] = History.changes(reopened)
    end
  end

  describe "per-actor undo" do
    test "the human's undo skips the agent's edit" do
      weave = two_actor_doc()
      write(weave, 0, "HUMAN", "user", @human)
      write(weave, 5, "AGENT", "agent:codex", @agent)
      assert History.text(weave) == "HUMANAGENT"

      assert History.undo(weave, @human) == true
      assert History.text(weave) == "AGENT"
    end

    test "the agent's edits never enter the human's stack" do
      weave = two_actor_doc()
      write(weave, 0, "AAA", "user", @human)
      write(weave, 3, "BBB", "agent:codex", @agent)

      assert History.undo_count(weave, @human) == {1, 0}
      assert History.undo_count(weave, @agent) == {1, 0}
    end

    # The failure this guards: an undo is itself a change carrying the `undo`
    # origin. Without excluding it, the agent's undo lands on the human's
    # stack, and the human's next undo restores the text just removed.
    test "one actor's undo does not enter the other's stack" do
      weave = two_actor_doc()
      write(weave, 0, "AAA", "user", @human)
      write(weave, 3, "BBB", "agent:codex", @agent)
      write(weave, 6, "CCC", "user", @human)

      assert {2, 0} = History.undo_count(weave, @human)

      History.undo(weave, @agent)
      assert History.text(weave) == "AAACCC"
      assert {2, 0} = History.undo_count(weave, @human)

      History.undo(weave, @human)
      assert History.text(weave) == "AAA"
    end

    test "redo returns the actor's own work" do
      weave = two_actor_doc()
      write(weave, 0, "AAA", "user", @human)

      History.undo(weave, @human)
      assert History.text(weave) == ""
      assert History.redo(weave, @human) == true
      assert History.text(weave) == "AAA"
    end

    test "an unregistered actor cannot undo" do
      weave = History.new(1)
      assert {:error, message} = History.undo(weave, "nobody")
      assert message =~ "no undo manager"
    end
  end

  describe "export and import" do
    test "updates carry only what the peer is missing" do
      a = History.new(1)
      write(a, 0, "shared", "user", @human)

      b = History.new(2)
      History.import(b, History.export_snapshot(a))
      assert History.text(b) == "shared"

      mark = History.version(b)
      write(a, 6, " and more", "user", @human)

      updates = History.export_updates(a, mark)
      History.import(b, updates)
      assert History.text(b) == "shared and more"
    end

    test "importing the same bytes twice changes nothing" do
      a = History.new(1)
      write(a, 0, "once", "user", @human)
      snapshot = History.export_snapshot(a)

      b = History.new(2)
      History.import(b, snapshot)
      History.import(b, snapshot)
      assert History.text(b) == "once"
      assert length(History.changes(b)) == 1
    end

    test "concurrent edits on two replicas converge" do
      a = History.new(1)
      write(a, 0, "base", "user", @human)

      b = History.new(2)
      History.import(b, History.export_snapshot(a))
      mark_a = History.version(a)
      mark_b = History.version(b)

      # Neither replica sees the other yet.
      write(a, 4, "-from-a", "user", @human)
      write(b, 0, "from-b-", "user", @human)
      refute History.text(a) == History.text(b)

      History.import(a, History.export_updates(b, mark_b))
      History.import(b, History.export_updates(a, mark_a))

      assert History.text(a) == History.text(b)
      assert History.text(a) =~ "from-b-"
      assert History.text(a) =~ "-from-a"
    end
  end

  describe "cursors" do
    test "a cursor moves when text is inserted above it" do
      weave = History.new(1)
      write(weave, 0, "0123456789", "user", @human)

      cursor = History.cursor(weave, 5)
      assert History.cursor_pos(weave, cursor) == 5

      write(weave, 0, "abc", "agent:codex", @agent)
      assert History.cursor_pos(weave, cursor) == 8
    end

    # A cursor names an operation, not an offset, and operations are durable.
    # An anchor handed out now must still mean the same place after a restart.
    test "a cursor resolves against a reopened document" do
      weave = History.new(1)
      write(weave, 0, "0123456789", "user", @human)
      cursor = History.cursor(weave, 5)

      {:ok, reopened} = History.open(2, History.export_snapshot(weave))
      assert History.cursor_pos(reopened, cursor) == 5

      write(reopened, 0, "abc", "user", @human)
      assert History.cursor_pos(reopened, cursor) == 8
    end

    test "a cursor survives a deletion above it" do
      weave = History.new(1)
      write(weave, 0, "0123456789", "user", @human)
      cursor = History.cursor(weave, 8)

      History.delete(weave, 0, 4)
      History.commit(weave, "user", "trim")
      assert History.cursor_pos(weave, cursor) == 4
    end
  end
end
