defmodule Compos.CheckpointStoreTest do
  @moduledoc """
  The log is the text. A checkpoint carries the text only when the log
  cannot answer for it, and a checkpoint from before that rule (version
  1) still restores.
  """
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferHistoryStore, BufferStore}

  defp unique(label), do: "*#{label}-#{System.unique_integer([:positive])}*"

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  defp checkpoint(id), do: id |> BufferStore.checkpoint_path() |> File.read!() |> :erlang.binary_to_term()

  defp write_checkpoint(id, term),
    do: BufferStore.atomic_write(BufferStore.checkpoint_path(id), :erlang.term_to_binary(term))

  test "a recording buffer keeps its text in the log, not in the checkpoint" do
    name = unique("log-text")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Buffer.append(name, "the log holds this", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    assert cp.version == 2
    refute Map.has_key?(cp, :text)
    assert cp.size == 18
    assert BufferHistoryStore.size(id) > 0

    # dormant: the facts from the row, the text from the log
    assert Buffer.byte_size(name) == 18
    assert Buffer.text(name) == "the log holds this"
    refute Buffer.exists?(name)

    # awake: the text and the history come back from the log
    Buffer.append(name, "!", source: :user)
    assert Buffer.exists?(name)
    assert Buffer.text(name) == "the log holds this!"
    assert Enum.any?(Buffer.change_log(name), &(&1.actor["id"] =~ "user"))

    Compos.Core.kill_buffer(name)
  end

  test "a buffer that stopped recording keeps its text in the checkpoint" do
    name = unique("stopped-text")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    :ok = Buffer.provenance_stop(name)
    Buffer.append(name, "unrecorded", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    assert cp.version == 2
    assert cp.text == "unrecorded"
    assert Buffer.text(name) == "unrecorded"

    Compos.Core.kill_buffer(name)
  end

  test "a version 1 checkpoint still restores, text and all" do
    name = unique("v1")
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Buffer.append(name, "from before", source: :user)
    id = Buffer.id(name)
    evict(name)

    cp = checkpoint(id)
    write_checkpoint(id, cp |> Map.delete(:size) |> Map.merge(%{version: 1, text: "from before"}))
    Compos.Core.BufferStore.reindex()

    assert Buffer.text(name) == "from before"
    Buffer.append(name, " and after", source: :user)
    assert Buffer.text(name) == "from before and after"
    evict(name)
    assert checkpoint(id).version == 2
    refute Map.has_key?(checkpoint(id), :text)
    assert Buffer.text(name) == "from before and after"

    Compos.Core.kill_buffer(name)
  end

  test "the migration strips the text of a version 1 checkpoint only when the log agrees" do
    agreed = unique("migrate-agreed")
    {:ok, ^agreed} = Compos.Core.create_buffer(agreed)
    Buffer.append(agreed, "same bytes", source: :user)
    agreed_id = Buffer.id(agreed)
    evict(agreed)
    write_checkpoint(agreed_id, checkpoint(agreed_id) |> Map.delete(:size) |> Map.merge(%{version: 1, text: "same bytes"}))

    stale = unique("migrate-stale")
    {:ok, ^stale} = Compos.Core.create_buffer(stale)
    Buffer.append(stale, "log bytes", source: :user)
    stale_id = Buffer.id(stale)
    evict(stale)
    write_checkpoint(stale_id, checkpoint(stale_id) |> Map.delete(:size) |> Map.merge(%{version: 1, text: "other bytes"}))

    File.rm(Path.join(BufferStore.dir(), ".checkpoints-v2"))
    :ok = BufferStore.migrate([BufferStore.checkpoint_path(agreed_id), BufferStore.checkpoint_path(stale_id)])
    assert File.exists?(Path.join(BufferStore.dir(), ".checkpoints-v2"))

    assert checkpoint(agreed_id).version == 2
    refute Map.has_key?(checkpoint(agreed_id), :text)
    assert checkpoint(agreed_id).size == 10
    assert checkpoint(stale_id).version == 1
    assert checkpoint(stale_id).text == "other bytes"

    BufferStore.reindex()
    assert Buffer.text(agreed) == "same bytes"
    assert Buffer.text(stale) == "other bytes"

    Compos.Core.kill_buffer(agreed)
    Compos.Core.kill_buffer(stale)
  end

  describe "a checkpoint with no text and a log that cannot answer" do
    # a recording buffer asleep with a v2 checkpoint; answers the name, the id
    # and the two paths
    defp asleep_without_text(label) do
      name = unique(label)
      {:ok, ^name} = Compos.Core.create_buffer(name)
      Buffer.append(name, "only the log holds this", source: :user)
      id = Buffer.id(name)
      evict(name)
      assert eventually(fn -> match?({:ok, %{live: false}}, Compos.Core.BufferView.fetch(name)) end)
      refute Map.has_key?(checkpoint(id), :text)
      on_exit(fn -> Compos.Core.kill_buffer(name) end)
      {name, id, BufferStore.checkpoint_path(id), BufferHistoryStore.path(id)}
    end

    defp files(paths), do: Enum.map(paths, &File.read/1)

    defp refuses_to_start(name, id, cp_path, log_path) do
      before = files([cp_path, log_path])
      row = Compos.Core.BufferView.fetch(name)

      assert {:error, {:unrestorable, ^name, reason}} = Compos.Core.wake(name)
      assert Buffer.describe_unrestorable(reason) =~ log_path
      assert {:error, {:unrestorable, ^name, _}} = Compos.Core.ensure_buffer(name)
      assert {:error, {:unrestorable, ^name, _}} = Compos.Core.create_buffer(name)

      # no process, no fresh empty buffer under the name
      refute Buffer.exists?(name)
      assert Registry.lookup(Compos.Core.BufferRegistry, name) == []
      assert Registry.lookup(Compos.Core.BufferRegistry, {:id, id}) == []

      # a write and a dormant text read answer the error, naming the log
      err = assert_raise Buffer.Unrestorable, fn -> Buffer.text(name) end
      assert Exception.message(err) =~ name and Exception.message(err) =~ log_path
      assert_raise Buffer.Unrestorable, fn -> Buffer.append(name, "x", source: :user) end
      refute Buffer.exists?(name)

      # the editor keeps its window. What switch-to-buffer! answers is
      # Scheme behavior, and its test belongs in a Scheme suite.
      assert {:error, {:unrestorable, ^name, _}} = Compos.Core.Editor.set_window_buffer(name)
      refute Compos.Core.Editor.current_buffer() == name
      refute Buffer.exists?(name)

      # the row and both files are exactly as they were
      assert Compos.Core.BufferView.fetch(name) == row
      assert files([cp_path, log_path]) == before
    end

    test "a deleted log: the wake errors and nothing is written" do
      {name, id, cp_path, log_path} = asleep_without_text("no-log")
      File.rm!(log_path)
      refuses_to_start(name, id, cp_path, log_path)
      refute File.exists?(log_path)
    end

    test "a corrupt log: the wake errors and nothing is written" do
      {name, id, cp_path, log_path} = asleep_without_text("bad-log")
      garbage = :crypto.strong_rand_bytes(64)
      File.write!(log_path, <<byte_size(garbage)::size(32), garbage::binary>>)
      refuses_to_start(name, id, cp_path, log_path)
    end

    test "a log with no whole frame: the wake errors" do
      {name, id, cp_path, log_path} = asleep_without_text("torn-log")
      File.write!(log_path, <<0, 0, 16, 0, 1, 2, 3>>)
      refuses_to_start(name, id, cp_path, log_path)
    end

    test "the log comes back, and so does the buffer" do
      {name, _id, _cp, log_path} = asleep_without_text("log-back")
      saved = File.read!(log_path)
      File.rm!(log_path)
      assert {:error, _} = Compos.Core.wake(name)
      File.write!(log_path, saved)
      assert {:ok, ^name} = Compos.Core.wake(name, restore: false)
      assert Buffer.text(name) == "only the log holds this"
    end
  end

  test "a compaction replaces the log by a rename, never in place" do
    id = "compact-atomic-#{System.unique_integer([:positive])}"
    on_exit(fn -> BufferHistoryStore.forget(id) end)
    BufferHistoryStore.append(id, "first")
    {:ok, %{inode: before}} = File.stat(BufferHistoryStore.path(id))
    assert BufferHistoryStore.compact(id, "snapshot") > 0
    {:ok, %{inode: after_}} = File.stat(BufferHistoryStore.path(id))
    assert before != after_
    assert BufferHistoryStore.read(id) == ["snapshot"]
    assert Path.wildcard(BufferHistoryStore.path(id) <> ".tmp-*") == []
  end
end
