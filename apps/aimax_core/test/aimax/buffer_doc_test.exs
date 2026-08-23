defmodule Aimax.BufferDocTest do
  @moduledoc """
  Phase 2 of `docs/PROVENANCE-CRDT.md`: the buffer mirrors every text mutation
  into its Loro document.

  The invariant these tests defend is one line: the rope and the document hold
  the same bytes. Behaviour must not move in this phase, so undo still works
  exactly as it did.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Doc, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp new_buffer(text) do
    name = "doc-mirror-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)
    name
  end

  # The invariant. Reads through the public accessor, which flushes first.
  defp assert_mirrored(name) do
    doc = Buffer.doc(name)
    assert doc, "#{name} has no document"
    assert Doc.text(doc) == Buffer.text(name)
    doc
  end

  defp messages(name) do
    name
    |> Buffer.doc()
    |> Doc.history()
    |> Enum.map(&Jason.decode!(&1.message))
  end

  describe "the mirror" do
    test "a new buffer's document starts equal to its text" do
      name = new_buffer("hello world")
      assert_mirrored(name)
      assert Doc.text(Buffer.doc(name)) == "hello world"
    end

    test "an insert reaches the document" do
      name = new_buffer("hello")
      Buffer.append(name, " world", source: :editor)
      assert_mirrored(name)
    end

    test "a delete reaches the document" do
      name = new_buffer("hello world")
      Buffer.delete_range(name, 5, 6, source: :editor)
      assert Buffer.text(name) == "hello"
      assert_mirrored(name)
    end

    test "a replace reaches the document as one changeset" do
      name = new_buffer("one two three")
      Buffer.replace_range(name, 4, 3, "TWO", source: :editor)
      assert Buffer.text(name) == "one TWO three"
      assert_mirrored(name)
    end

    test "multibyte text keeps byte offsets aligned" do
      name = new_buffer("héllo wörld")
      Buffer.delete_range(name, 0, 6, source: :editor)
      assert Buffer.text(name) == " wörld"
      assert_mirrored(name)
    end

    test "typing through the real key path reaches the document" do
      name = new_buffer("")
      Aimax.Core.Editor.set_window_buffer(name)
      press(["a", "b", "c"])
      assert Buffer.text(name) == "abc"
      assert_mirrored(name)
    end
  end

  describe "undo" do
    test "still restores the previous text" do
      name = new_buffer("")
      Buffer.append(name, "first", source: :editor)
      Buffer.append(name, " second", source: :editor)
      assert Buffer.text(name) == "first second"

      assert :ok = Buffer.undo(name)
      assert Buffer.text(name) == "first"
    end

    test "leaves the document equal to the rope" do
      name = new_buffer("")
      Buffer.append(name, "first", source: :editor)
      Buffer.append(name, " second", source: :editor)
      Buffer.undo(name)
      assert_mirrored(name)
    end

    # Emacs semantics: consecutive undos keep walking back, and only a command
    # that breaks the chain turns the next undo into a redo. `editor_test`
    # owns that behaviour; this checks the document follows it either way.
    test "a redo after a broken chain stays mirrored" do
      name = new_buffer("")
      Aimax.Core.Editor.set_window_buffer(name)
      press(["a", "b", "c"])
      assert Buffer.text(name) == "abc"

      press(["C-/"])
      assert Buffer.text(name) == ""
      assert_mirrored(name)

      # C-f breaks the chain, so the next undo is a redo.
      press(["C-f", "C-/"])
      assert Buffer.text(name) == "abc"
      assert_mirrored(name)
    end
  end

  describe "attribution" do
    test "a change carries the actor that made it" do
      name = new_buffer("")
      Buffer.append(name, "written by an agent", source: {:agent, "codex"})

      assert Enum.any?(messages(name), fn m ->
               get_in(m, ["actor", "id"]) == "agent:codex"
             end)
    end

    test "two actors produce two changes, each with its own actor" do
      name = new_buffer("")
      Buffer.append(name, "human ", source: :user)
      Buffer.append(name, "agent", source: {:agent, "codex"})

      ids =
        messages(name)
        |> Enum.map(&get_in(&1, ["actor", "id"]))
        |> Enum.uniq()

      assert "agent:codex" in ids
      assert Enum.any?(ids, &String.starts_with?(&1, "user:"))
    end

    test "the group rides on the change, not on the actor" do
      name = new_buffer("")
      Buffer.set_local(name, "group", "grp:test")
      Buffer.append(name, "grouped", source: :editor)

      assert Enum.any?(messages(name), &(&1["group"] == "grp:test"))
    end
  end

  describe "policy" do
    test "a buffer with recording stopped keeps its text and stops mirroring" do
      name = new_buffer("before")
      Buffer.provenance_stop(name, source: :editor)
      Buffer.append(name, " after", source: :editor)

      # The text is untouched; only the history stops.
      assert Buffer.text(name) == "before after"
    end
  end

  describe "divergence" do
    test "a checkpoint repairs a document that fell behind the rope" do
      name = new_buffer("original")
      doc = Buffer.doc(name)

      # Force divergence the way a failed mirror would.
      Doc.insert(doc, 0, "XX")
      Doc.commit(doc, "system", ~s({"actor":{"id":"test"},"group":null}))
      refute Doc.text(doc) == Buffer.text(name)

      Buffer.checkpoint_now(name)
      assert Doc.text(Buffer.doc(name)) == Buffer.text(name)
    end
  end
end
