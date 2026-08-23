defmodule Aimax.DocTest do
  use ExUnit.Case, async: true

  alias Aimax.Core.Doc

  @human "user:local"
  @agent "agent:codex"

  # A document with both actors registered, each blind to the other's work.
  defp two_actor_doc(peer \\ 1) do
    doc = Doc.new(peer)
    :ok = Doc.register_actor(doc, @human, ["agent"])
    :ok = Doc.register_actor(doc, @agent, ["user"])
    doc
  end

  defp write(doc, pos, text, origin, actor) do
    Doc.insert(doc, pos, text)
    Doc.commit(doc, origin, actor <> "|" <> text)
    doc
  end

  describe "text" do
    test "inserts and deletes at byte offsets" do
      doc = Doc.new(1)
      assert Doc.insert(doc, 0, "hello world") == 11
      assert Doc.delete(doc, 5, 6) == 5
      assert Doc.text(doc) == "hello"
      assert Doc.byte_size(doc) == 5
    end

    test "counts bytes, not characters" do
      doc = Doc.new(1)
      Doc.insert(doc, 0, "héllo")
      assert Doc.byte_size(doc) == 6
      assert Doc.text(doc) == "héllo"
    end

    test "update replaces the whole text" do
      doc = Doc.new(1)
      Doc.insert(doc, 0, "one two three")
      Doc.commit(doc, "user", "seed")

      assert Doc.update(doc, "one TWO three") == 13
      assert Doc.text(doc) == "one TWO three"
    end
  end

  describe "attribution" do
    test "the commit message survives an export and reopen" do
      doc = Doc.new(7)
      write(doc, 0, "AAA", "user", @human)
      write(doc, 3, "BBB", "agent:codex", @agent)

      {:ok, reopened} = Doc.open(9, Doc.export_snapshot(doc))

      assert Doc.text(reopened) == "AAABBB"
      messages = Enum.map(Doc.history(reopened), & &1.message)
      assert messages == ["#{@human}|AAA", "#{@agent}|BBB"]
    end

    test "history records the writing peer, not the reader" do
      doc = Doc.new(7)
      write(doc, 0, "AAA", "user", @human)

      {:ok, reopened} = Doc.open(9, Doc.export_snapshot(doc))
      assert [%{peer: 7}] = Doc.history(reopened)
    end
  end

  describe "per-actor undo" do
    test "the human's undo skips the agent's edit" do
      doc = two_actor_doc()
      write(doc, 0, "HUMAN", "user", @human)
      write(doc, 5, "AGENT", "agent:codex", @agent)
      assert Doc.text(doc) == "HUMANAGENT"

      assert Doc.undo(doc, @human) == true
      assert Doc.text(doc) == "AGENT"
    end

    test "the agent's edits never enter the human's stack" do
      doc = two_actor_doc()
      write(doc, 0, "AAA", "user", @human)
      write(doc, 3, "BBB", "agent:codex", @agent)

      assert Doc.undo_count(doc, @human) == {1, 0}
      assert Doc.undo_count(doc, @agent) == {1, 0}
    end

    # The failure this guards: an undo is itself a change carrying the `undo`
    # origin. Without excluding it, the agent's undo lands on the human's
    # stack, and the human's next undo restores the text just removed.
    test "one actor's undo does not enter the other's stack" do
      doc = two_actor_doc()
      write(doc, 0, "AAA", "user", @human)
      write(doc, 3, "BBB", "agent:codex", @agent)
      write(doc, 6, "CCC", "user", @human)

      assert {2, 0} = Doc.undo_count(doc, @human)

      Doc.undo(doc, @agent)
      assert Doc.text(doc) == "AAACCC"
      assert {2, 0} = Doc.undo_count(doc, @human)

      Doc.undo(doc, @human)
      assert Doc.text(doc) == "AAA"
    end

    test "redo returns the actor's own work" do
      doc = two_actor_doc()
      write(doc, 0, "AAA", "user", @human)

      Doc.undo(doc, @human)
      assert Doc.text(doc) == ""
      assert Doc.redo(doc, @human) == true
      assert Doc.text(doc) == "AAA"
    end

    test "an unregistered actor cannot undo" do
      doc = Doc.new(1)
      assert {:error, message} = Doc.undo(doc, "nobody")
      assert message =~ "no undo manager"
    end
  end

  describe "export and import" do
    test "updates carry only what the peer is missing" do
      a = Doc.new(1)
      write(a, 0, "shared", "user", @human)

      b = Doc.new(2)
      Doc.import(b, Doc.export_snapshot(a))
      assert Doc.text(b) == "shared"

      mark = Doc.version(b)
      write(a, 6, " and more", "user", @human)

      updates = Doc.export_updates(a, mark)
      Doc.import(b, updates)
      assert Doc.text(b) == "shared and more"
    end

    test "importing the same bytes twice changes nothing" do
      a = Doc.new(1)
      write(a, 0, "once", "user", @human)
      snapshot = Doc.export_snapshot(a)

      b = Doc.new(2)
      Doc.import(b, snapshot)
      Doc.import(b, snapshot)
      assert Doc.text(b) == "once"
      assert length(Doc.history(b)) == 1
    end

    test "concurrent edits on two replicas converge" do
      a = Doc.new(1)
      write(a, 0, "base", "user", @human)

      b = Doc.new(2)
      Doc.import(b, Doc.export_snapshot(a))
      mark_a = Doc.version(a)
      mark_b = Doc.version(b)

      # Neither replica sees the other yet.
      write(a, 4, "-from-a", "user", @human)
      write(b, 0, "from-b-", "user", @human)
      refute Doc.text(a) == Doc.text(b)

      Doc.import(a, Doc.export_updates(b, mark_b))
      Doc.import(b, Doc.export_updates(a, mark_a))

      assert Doc.text(a) == Doc.text(b)
      assert Doc.text(a) =~ "from-b-"
      assert Doc.text(a) =~ "-from-a"
    end
  end

  describe "cursors" do
    test "a cursor moves when text is inserted above it" do
      doc = Doc.new(1)
      write(doc, 0, "0123456789", "user", @human)

      cursor = Doc.cursor(doc, 5)
      assert Doc.cursor_pos(doc, cursor) == 5

      write(doc, 0, "abc", "agent:codex", @agent)
      assert Doc.cursor_pos(doc, cursor) == 8
    end

    test "a cursor survives a deletion above it" do
      doc = Doc.new(1)
      write(doc, 0, "0123456789", "user", @human)
      cursor = Doc.cursor(doc, 8)

      Doc.delete(doc, 0, 4)
      Doc.commit(doc, "user", "trim")
      assert Doc.cursor_pos(doc, cursor) == 4
    end
  end
end
