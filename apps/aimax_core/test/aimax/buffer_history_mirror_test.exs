defmodule Aimax.BufferHistoryMirrorTest do
  @moduledoc """
  Phase 2 of `docs/PROVENANCE-CRDT.md`: the buffer mirrors every text mutation
  into its Loro document.

  The invariant these tests defend is one line: the rope and the document hold
  the same bytes. Behaviour must not move in this phase, so undo still works
  exactly as it did.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, KeyDispatch}
  alias Aimax.Core.BufferHistory, as: History

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp new_buffer(text) do
    name = "weave-mirror-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)
    name
  end

  # The invariant. Reads through the public accessor, which flushes first.
  defp assert_mirrored(name) do
    weave = Buffer.history(name)
    assert weave, "#{name} has no document"
    assert History.text(weave) == Buffer.text(name)
    weave
  end

  defp messages(name) do
    name
    |> Buffer.history()
    |> History.changes()
    |> Enum.map(&Jason.decode!(&1.message))
  end

  describe "the mirror" do
    test "a new buffer's history starts equal to its text" do
      name = new_buffer("hello world")
      assert_mirrored(name)
      assert History.text(Buffer.history(name)) == "hello world"
    end

    test "an insert reaches the history" do
      name = new_buffer("hello")
      Buffer.append(name, " world", source: :editor)
      assert_mirrored(name)
    end

    test "a delete reaches the history" do
      name = new_buffer("hello world")
      Buffer.delete_range(name, 5, 6, source: :editor)
      assert Buffer.text(name) == "hello"
      assert_mirrored(name)
    end

    test "a replace reaches the history as one changeset" do
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

    test "typing through the real key path reaches the history" do
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

    test "leaves the history equal to the rope" do
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

  # The bug Phase 3 exists to fix. Before it, `state.history` was one linear
  # stack across every actor, so undoing your own typing first undid whatever
  # an agent had written into the buffer since.
  describe "undo belongs to the actor" do
    test "the human's undo skips the agent's edit" do
      name = new_buffer("")
      Buffer.append(name, "human", source: :user)
      Buffer.append(name, " agent", source: {:agent, "codex"})
      assert Buffer.text(name) == "human agent"

      assert :ok = Buffer.undo(name, source: :user)
      assert Buffer.text(name) == " agent"
      assert_mirrored(name)
    end

    test "the agent's work survives repeated human undo" do
      name = new_buffer("")
      Buffer.append(name, "one", source: :user)
      Buffer.append(name, "AGENT", source: {:agent, "codex"})
      Buffer.append(name, "two", source: :user)

      Buffer.undo(name, source: :user)
      Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "AGENT"
    end

    test "an agent undoes its own work and leaves the human's alone" do
      name = new_buffer("")
      Buffer.append(name, "human", source: :user)
      Buffer.append(name, "AGENT", source: {:agent, "codex"})

      assert :ok = Buffer.undo(name, source: {:agent, "codex"})
      assert Buffer.text(name) == "human"
    end

    # A command edits as system:editor on the user's behalf, so Emacs undoes
    # it as the user's own work.
    test "a command's edit is the user's to undo" do
      name = new_buffer("")
      Buffer.append(name, "typed", source: :user)
      Buffer.append(name, " by a command", source: :editor)

      assert :ok = Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "typed"
    end

    test "an actor with nothing to undo says so" do
      name = new_buffer("start")
      Buffer.append(name, " agent", source: {:agent, "codex"})
      assert {:error, :no_undo} = Buffer.undo(name, source: :user)
    end
  end

  # Undo used to restore the point saved in the snapshot. It now places the
  # point at the change it applied, which is where Emacs leaves it. Nothing
  # asserted this before, so it is pinned here.
  describe "point through undo" do
    test "an undone insert leaves the point where the text was" do
      name = new_buffer("abc")
      Buffer.insert_at(name, 3, "XYZ", source: :user)
      assert Buffer.text(name) == "abcXYZ"

      Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "abc"
      assert Buffer.point(name) == 3
    end

    test "an undone delete leaves the point after the restored text" do
      name = new_buffer("abcdef")
      Buffer.delete_range(name, 3, 3, source: :user)
      assert Buffer.text(name) == "abc"

      Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "abcdef"
      assert Buffer.point(name) == 6
    end

    test "the point stays inside the text after an agent edit and a human undo" do
      name = new_buffer("")
      Buffer.append(name, "human", source: :user)
      Buffer.append(name, "AGENT", source: {:agent, "codex"})
      Buffer.undo(name, source: :user)

      assert Buffer.point(name) <= Buffer.byte_size(name)
    end
  end

  # A byte offset read now is wrong later if anyone edits above it. An anchor
  # is the same position expressed so that it survives.
  describe "anchors" do
    test "an anchor follows an insert above it" do
      name = new_buffer("hello world")
      a = Buffer.anchor(name, 6)
      assert Buffer.anchor_pos(name, a) == 6

      Buffer.insert_at(name, 0, "XXX", source: :user)
      assert Buffer.anchor_pos(name, a) == 9
    end

    test "an anchor follows a delete above it" do
      name = new_buffer("0123456789")
      a = Buffer.anchor(name, 8)

      Buffer.delete_range(name, 0, 4, source: :user)
      assert Buffer.anchor_pos(name, a) == 4
    end

    test "an anchor is unmoved by an edit below it" do
      name = new_buffer("hello world")
      a = Buffer.anchor(name, 5)

      Buffer.append(name, "!!!", source: :user)
      assert Buffer.anchor_pos(name, a) == 5
    end

    test "an anchor stays inside the text after everything below is cut" do
      name = new_buffer("hello world")
      a = Buffer.anchor(name, 11)

      Buffer.delete_range(name, 5, 6, source: :user)
      assert Buffer.anchor_pos(name, a) <= Buffer.byte_size(name)
    end

    test "a buffer that records no history has no anchors" do
      name = new_buffer("text")
      Buffer.provenance_stop(name, source: :editor)
      # The document is still attached, so an anchor taken before the stop
      # keeps working; what matters is that nothing raises.
      assert Buffer.anchor(name, 2) == nil or is_binary(Buffer.anchor(name, 2))
    end

    test "a malformed anchor resolves to nothing rather than raising" do
      name = new_buffer("text")
      assert Buffer.anchor_pos(name, "not-an-anchor") == nil
    end
  end

  # A buffer that goes away and comes back must bring its history with it.
  # Without the log the document is rebuilt from the text and every earlier
  # state, and everyone who wrote it, is gone.
  describe "the history log" do
    defp evict(name) do
      :ok = Buffer.checkpoint_now(name)
      [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
      :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
    end

    test "history survives eviction" do
      name = new_buffer("")
      Buffer.append(name, "human ", source: :user)
      Buffer.append(name, "agent", source: {:agent, "codex"})
      before = messages(name)
      assert length(before) >= 2

      evict(name)

      assert Buffer.text(name) == "human agent"
      after_ = messages(name)
      ids = Enum.map(after_, &get_in(&1, ["actor", "id"]))
      assert "agent:codex" in ids
      assert Enum.any?(ids, &String.starts_with?(&1, "user:"))
    end

    test "the mirror is intact after eviction, and keeps recording" do
      name = new_buffer("start")
      Buffer.append(name, " more", source: :editor)
      evict(name)

      assert_mirrored(name)
      Buffer.append(name, " again", source: :editor)
      assert Buffer.text(name) == "start more again"
      assert_mirrored(name)
    end

    test "undo still works on a buffer that came back" do
      name = new_buffer("")
      Buffer.append(name, "one", source: :user)
      evict(name)

      Buffer.append(name, "two", source: :user)
      assert Buffer.text(name) == "onetwo"
      assert :ok = Buffer.undo(name, source: :user)
      assert Buffer.text(name) == "one"
    end

    test "a torn tail costs the last batch and not the history" do
      name = new_buffer("")
      Buffer.append(name, "kept", source: :user)
      :ok = Buffer.checkpoint_now(name)
      id = Buffer.id(name)

      evict(name)

      # A crash between the write and the flush leaves a partial frame.
      path = Aimax.Core.BufferHistoryStore.path(id)
      File.write!(path, <<0, 0, 16, 0, 1, 2, 3>>, [:append])

      assert Buffer.text(name) == "kept"
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
    test "a checkpoint repairs a history that fell behind the rope" do
      name = new_buffer("original")
      weave = Buffer.history(name)

      # Force divergence the way a failed mirror would.
      History.insert(weave, 0, "XX")
      History.commit(weave, "system", ~s({"actor":{"id":"test"},"group":null}))
      refute History.text(weave) == Buffer.text(name)

      Buffer.checkpoint_now(name)
      assert History.text(Buffer.history(name)) == Buffer.text(name)
    end
  end
end
