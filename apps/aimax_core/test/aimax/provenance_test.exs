defmodule Aimax.ProvenanceTest do
  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, Session}

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

  test "all buffers start with a durable root revision" do
    name = new_buffer("root", "base")

    status = Buffer.provenance(name)
    assert status.enabled
    assert status.policy_source == "default"
    assert status.retention == "durable"
    assert is_binary(status.head_id)
    assert is_binary(status.head_hash)

    assert [
             %{
               id: head,
               parent_id: nil,
               kind: "root",
               snapshot: "base",
               actor: %{id: "system:buffer", kind: "system"}
             }
           ] = Buffer.provenance_history(name)

    assert head == status.head_id
  end

  test "an agent edit records a structured actor and exact operation" do
    name = new_buffer("actor", "base")
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})

    assert [_, revision] = Buffer.provenance_history(name)
    assert revision.kind == "edit"
    assert revision.actor.id == "agent:run-7"
    assert revision.actor.kind == "agent"
    assert revision.actor.run_id == "run-7"
    assert revision.operation == %{pos: 4, inserted: "!", deleted: ""}
    assert revision.parent_id != nil
    assert revision.content_hash == Buffer.provenance(name).head_hash
  end

  test "stop preserves history and start bridges unrecorded edits" do
    name = new_buffer("gap", "base")

    :ok =
      Buffer.provenance_stop(
        name,
        source: :editor,
        author: "mode:test",
        reason: "mode-policy",
        policy_source: "mode"
      )

    before = Buffer.provenance_history(name)
    refute Buffer.provenance(name).enabled

    :ok = Buffer.append(name, " untracked", source: :editor)
    assert Buffer.provenance_history(name) == before
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

    assert %{kind: "gap", snapshot: "base untracked", actor: actor, metadata: metadata} =
             List.last(Buffer.provenance_history(name))

    assert actor.id == "user:local"
    assert metadata.attribution == "incomplete"
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

  test "eviction restores the accepted head and history" do
    name = new_buffer("restore", "a")
    :ok = Buffer.append(name, "b", source: :editor)
    status = Buffer.provenance(name)
    history = Buffer.provenance_history(name)

    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)

    assert Buffer.provenance(name).head_id == status.head_id
    assert Buffer.provenance(name).head_hash == status.head_hash
    assert Buffer.provenance_history(name) == history
    assert Buffer.text(name) == "ab"
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
