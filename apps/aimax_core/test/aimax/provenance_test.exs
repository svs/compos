defmodule Aimax.ProvenanceTest do
  @moduledoc """
  What the record says about how a buffer's text came to exist.

  The record is the buffer's history, so these read `Buffer.change_log/1` and,
  where durability is the question, the log file itself. The store keeps the
  cell, the actors and the recording policy; it no longer keeps revisions.

  A buffer that started empty has no root change. There was no text to record,
  and a commit with no operations makes no change, so the first thing written
  into it is the first change there is.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, BufferHistory, BufferHistoryStore, Editor, Session}

  defp unique(label), do: "*provenance-#{label}-#{System.unique_integer([:positive])}*"

  defp new_buffer(label, text \\ "") do
    name = unique(label)
    {:ok, ^name} = Aimax.Core.create_buffer(name, text: text)

    on_exit(fn ->
      Editor.set_window_buffer("*scratch*")
      Aimax.Core.kill_buffer(name)
    end)

    name
  end

  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
  end

  # The history the buffer will report, flushing anything it still holds.
  defp changes(name), do: Buffer.change_log(name)

  # The history on disk, read past the buffer: what is durable right now, not
  # what the buffer would write if asked.
  defp durable(name) do
    case BufferHistoryStore.load(Buffer.id(name)) do
      nil -> []
      weave -> BufferHistory.changes(weave)
    end
  end

  defp actor_of(change), do: Jason.decode!(change.message)["actor"]

  # The opaque id groups.scm gave this buffer's group, which is what a record
  # keeps: a name can be edited, an id cannot.
  defp group_id(name) do
    {:ok, printed} = Session.eval(~s{(buffer-group "#{name}")})
    String.trim(printed, "\"")
  end
  # A raw change carries its operations directly; a shaped row nests them.
  defp inserted(%{ops: ops}), do: Enum.map_join(ops, & &1.inserted)
  defp inserted(%{operation: %{ops: ops}}), do: Enum.map_join(ops, & &1.inserted)

  test "a buffer starts with a root change naming where its text came from" do
    name = new_buffer("root", "base")

    status = Buffer.provenance(name)
    assert status.enabled
    assert status.policy_source == "default"
    assert status.retention == "durable"

    assert [%{kind: "root", parent_id: nil, actor: actor} = root] = changes(name)
    assert actor["id"] == "system:buffer"
    assert actor["kind"] == "system"
    assert Enum.map_join(root.operation.ops, & &1.inserted) == "base"
  end

  test "an agent edit records a structured actor and the exact operation" do
    name = new_buffer("actor", "base")
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})

    assert [_root, change] = changes(name)
    assert change.kind == "edit"
    assert change.actor["id"] == "agent:run-7"
    assert change.actor["kind"] == "agent"
    assert change.actor["run_id"] == "run-7"
    assert [%{kind: "insert", pos: 4, inserted: "!"}] = change.operation.ops
    assert change.parent_id != nil
  end

  test "a change names the change it followed" do
    name = new_buffer("dag", "a")
    :ok = Buffer.insert_at(name, 1, "b", source: {:agent, "run-1"})
    :ok = Buffer.insert_at(name, 2, "c", source: {:agent, "run-2"})

    assert [root, first, second] = changes(name)
    assert first.parent_id == root.id
    assert second.parent_id == first.id
  end

  test "stop preserves the history and start bridges the unrecorded edits" do
    name = new_buffer("gap", "base")

    :ok =
      Buffer.provenance_stop(
        name,
        source: :editor,
        author: "mode:test",
        reason: "mode-policy",
        policy_source: "mode"
      )

    before = changes(name)
    refute Buffer.provenance(name).enabled

    :ok = Buffer.append(name, " untracked", source: :editor)
    assert changes(name) == before
    assert Buffer.provenance(name).gap

    :ok =
      Buffer.provenance_start(
        name,
        source: :user,
        author: "user:local",
        reason: "explicit",
        policy_source: "user"
      )

    status = Buffer.provenance(name)
    assert status.enabled
    assert status.policy_source == "user"
    refute status.gap
    assert Buffer.text(name) == "base untracked"
  end

  test "chat-mode opts out but an explicit user start wins" do
    name = new_buffer("chat")

    assert {:ok, _} =
             Session.eval(~s{(with-current-buffer "#{name}" (lambda () (set-mode! "chat-mode")))})

    refute Buffer.provenance(name).enabled
    assert Buffer.provenance(name).policy_source == "mode"

    :ok =
      Buffer.provenance_start(
        name,
        source: :user,
        author: "user:local",
        reason: "explicit",
        policy_source: "user"
      )

    assert {:ok, _} =
             Session.eval(~s{(with-current-buffer "#{name}" (lambda () (set-mode! "chat-mode")))})

    assert Buffer.provenance(name).enabled
    assert Buffer.provenance(name).policy_source == "user"
  end

  test "eviction restores the text and every change behind it" do
    name = new_buffer("restore", "a")
    :ok = Buffer.append(name, "b", source: :editor)
    before = changes(name)

    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)

    assert Buffer.text(name) == "ab"
    assert Enum.map(changes(name), & &1.id) == Enum.map(before, & &1.id)
    assert Enum.map(changes(name), & &1.actor) == Enum.map(before, & &1.actor)
  end

  describe "the typing path" do
    test "typing batches into one change at the checkpoint boundary" do
      name = new_buffer("batch", "")

      for {c, i} <- Enum.with_index(["a", "b", "c", "d", "e"]) do
        :ok = Buffer.insert_at(name, i, c, source: :user)
      end

      # Nothing reached the log yet: five keystrokes, one open change.
      assert durable(name) == []

      :ok = Buffer.checkpoint_now(name)

      assert [typed] = durable(name)
      assert actor_of(typed)["kind"] == "user"
      assert inserted(typed) == "abcde"
      assert Buffer.text(name) == "abcde"
    end

    test "an agent edit is durable before its caller hears that it worked" do
      name = new_buffer("atomic", "base")
      :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})

      # No checkpoint and no read through the buffer: it is already on disk.
      assert [_root, change] = durable(name)
      assert actor_of(change)["id"] == "agent:run-7"
      assert inserted(change) == "!"
    end

    test "a second actor closes the first actor's change before its own" do
      name = new_buffer("actors", "")
      :ok = Buffer.insert_at(name, 0, "h", source: :user)
      :ok = Buffer.insert_at(name, 1, "i", source: :user)

      # The agent's arrival closes the typing, then records its own work.
      :ok = Buffer.insert_at(name, 2, "!", source: {:agent, "run-9"})

      assert [typed, agent] = changes(name)
      assert typed.actor["kind"] == "user"
      assert inserted(typed) == "hi"
      assert agent.actor["id"] == "agent:run-9"
      assert agent.parent_id == typed.id
      assert typed.parent_id == nil
    end

    # Through groups.scm, the way a buffer really joins one. Setting the old
    # `group` local by hand was how this test passed while the buffers people
    # actually use recorded nothing.
    test "a change records the group the work happened in" do
      name = new_buffer("group", "")
      {:ok, _} = Session.eval(~s{(buffer-add-group! "#{name}" "inbox")})
      :ok = Buffer.insert_at(name, 0, "a", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert [change] = changes(name)
      assert change.metadata.group == group_id(name)
      assert is_binary(change.metadata.group)
    end

    test "a chat records the group that owns it" do
      name = new_buffer("chatgroup", "")
      :ok = Buffer.set_local(name, "group-id", "grp:7")
      :ok = Buffer.insert_at(name, 0, "a", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert [change] = changes(name)
      assert change.metadata.group == "grp:7"
    end

    test "a move to another group closes the change behind it" do
      name = new_buffer("regroup", "")
      {:ok, _} = Session.eval(~s{(buffer-add-group! "#{name}" "inbox")})
      first_group = group_id(name)
      :ok = Buffer.insert_at(name, 0, "a", source: :user)

      {:ok, _} = Session.eval(~s{(buffer-remove-group! "#{name}" "inbox")})
      {:ok, _} = Session.eval(~s{(buffer-add-group! "#{name}" "archive")})
      :ok = Buffer.insert_at(name, 1, "b", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert [first, second] = changes(name)
      assert first.metadata.group == first_group
      assert second.metadata.group == group_id(name)
      refute first.metadata.group == second.metadata.group
      assert second.parent_id == first.id
    end

    test "a buffer in no group records no group" do
      name = new_buffer("groupless", "")
      :ok = Buffer.insert_at(name, 0, "a", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert [change] = changes(name)
      assert change.metadata.group == nil
    end

    test "a save makes the typing behind it durable" do
      path = Path.join(System.tmp_dir!(), "prov-save-#{System.unique_integer([:positive])}.txt")
      name = new_buffer("save", "")
      on_exit(fn -> File.rm(path) end)

      :ok = Buffer.insert_at(name, 0, "x", source: :user)
      assert durable(name) == []

      assert {:ok, ^path} = Buffer.save(name, path)
      assert [typed] = durable(name)
      assert actor_of(typed)["kind"] == "user"
    end

    test "a stopped buffer records nothing and says it has a gap" do
      name = new_buffer("stopped", "")

      :ok = Buffer.provenance_stop(name, source: :editor, reason: "test", policy_source: "user")

      :ok = Buffer.insert_at(name, 0, "x", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert changes(name) == []
      assert Buffer.provenance(name).gap
      assert Buffer.text(name) == "x"
    end
  end

  test "checkpoint records only while recording is active" do
    name = new_buffer("checkpoint")
    assert :ok = Buffer.provenance_checkpoint(name, source: :editor)

    :ok =
      Buffer.provenance_stop(
        name,
        source: :editor,
        reason: "test",
        policy_source: "user"
      )

    assert {:error, :not_recording} =
             Buffer.provenance_checkpoint(name, source: :editor)
  end
end
