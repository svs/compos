defmodule Compos.BufferHistoryStoreTest do
  @moduledoc """
  The log a buffer's history lives in, and the compaction that stops it growing
  without bound.

  Compaction rewrites the log as one snapshot once it outgrows four times the
  text. It is the only place in this subsystem where being wrong loses the
  past rather than costing effort, so these check what survives it rather than
  that it ran.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, BufferHistory, BufferHistoryStore}

  defp new_id, do: "zz-store-#{System.unique_integer([:positive])}"

  defp buffer(text) do
    name = "zz-compact-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    name
  end

  defp on_disk(name) do
    case BufferHistoryStore.load(Buffer.id(name)) do
      nil -> nil
      weave -> weave
    end
  end

  describe "the log file" do
    test "blobs come back in the order they went in" do
      id = new_id()
      on_exit(fn -> BufferHistoryStore.forget(id) end)

      BufferHistoryStore.append(id, "one")
      BufferHistoryStore.append(id, "two")
      BufferHistoryStore.append(id, "three")

      assert BufferHistoryStore.read(id) == ["one", "two", "three"]
    end

    test "an absent log reads as nothing rather than raising" do
      assert BufferHistoryStore.read(new_id()) == []
      assert BufferHistoryStore.load(new_id()) == nil
      assert BufferHistoryStore.size(new_id()) == 0
    end

    test "an empty blob is not written" do
      id = new_id()
      on_exit(fn -> BufferHistoryStore.forget(id) end)

      assert BufferHistoryStore.append(id, "") == 0
      assert BufferHistoryStore.read(id) == []
    end

    # A crash between the write and the flush leaves a partial frame. The
    # reader keeps everything before it, so a crash costs the last batch.
    test "a torn tail is dropped and the frames before it survive" do
      id = new_id()
      on_exit(fn -> BufferHistoryStore.forget(id) end)

      BufferHistoryStore.append(id, "whole")
      File.write!(BufferHistoryStore.path(id), <<0, 0, 4, 0, 1>>, [:append])

      assert BufferHistoryStore.read(id) == ["whole"]
    end

    test "a frame claiming more than the file holds is not trusted" do
      id = new_id()
      on_exit(fn -> BufferHistoryStore.forget(id) end)

      File.mkdir_p!(BufferHistoryStore.dir())
      File.write!(BufferHistoryStore.path(id), <<255, 255, 255, 255, "short">>)

      assert BufferHistoryStore.read(id) == []
    end

    test "compaction replaces the log with one blob" do
      id = new_id()
      on_exit(fn -> BufferHistoryStore.forget(id) end)

      BufferHistoryStore.append(id, "old one")
      BufferHistoryStore.append(id, "old two")
      BufferHistoryStore.compact(id, "everything")

      assert BufferHistoryStore.read(id) == ["everything"]
    end

    test "forget removes the log" do
      id = new_id()
      BufferHistoryStore.append(id, "here")
      assert BufferHistoryStore.size(id) > 0

      BufferHistoryStore.forget(id)
      assert BufferHistoryStore.size(id) == 0
    end
  end

  describe "compaction under churn" do
    # Enough separate changes to cross the 64 KB floor several times. Each is
    # an agent edit, which settles on its own, so each one appends a frame.
    defp actors(name) do
      name
      |> Buffer.change_log()
      |> Enum.map(& &1.actor["id"])
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp churn(name, pairs) do
      Enum.reduce(1..pairs, [], fn i, sizes ->
        Buffer.insert_at(name, 0, "x", source: {:agent, "a#{rem(i, 4)}"})
        Buffer.delete_range(name, 0, 1, source: {:agent, "a#{rem(i, 4)}"})
        [BufferHistoryStore.size(Buffer.id(name)) | sizes]
      end)
    end

    test "the log stops growing" do
      name = buffer("seed")
      sizes = churn(name, 300)

      # It compacted if the log was ever smaller than it had been before.
      assert Enum.max(sizes) > List.first(sizes),
             "the log never shrank, so compaction never ran"

      assert List.first(sizes) < 64 * 1024
    end

    test "the text survives every compaction" do
      name = buffer("seed")
      churn(name, 300)

      assert Buffer.text(name) == "seed"
      assert BufferHistory.text(on_disk(name)) == "seed"
    end

    # The version vector is what says two documents hold the same operations.
    # Change count does not: Loro merges adjacent changes by one peer when they
    # carry the same message, and where it puts that boundary depends on
    # whether the operations arrived live or through an import. Counting them
    # across a reload is off by one and means nothing.
    test "the changes survive every compaction" do
      name = buffer("seed")
      churn(name, 300)

      live = Buffer.change_log(name)
      assert length(live) > 100, "the churn should have made many changes"
      assert BufferHistory.version(on_disk(name)) == BufferHistory.version(Buffer.history(name))
    end

    test "who wrote what survives every compaction" do
      name = buffer("seed")
      churn(name, 300)

      assert "agent:a0" in actors(name)
      assert "agent:a3" in actors(name)
    end

    test "a buffer evicted after compaction comes back whole" do
      name = buffer("seed")
      churn(name, 300)
      before = BufferHistory.version(Buffer.history(name))
      actors_before = actors(name)

      :ok = Buffer.checkpoint_now(name)
      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
      :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)

      assert Buffer.text(name) == "seed"
      assert BufferHistory.version(Buffer.history(name)) == before
      assert actors(name) == actors_before
      assert BufferHistory.text(Buffer.history(name)) == Buffer.text(name)
    end

    test "a quiet buffer is left alone" do
      name = buffer("nothing much happens here")
      Buffer.append(name, " a little", source: :user)
      :ok = Buffer.checkpoint_now(name)

      assert BufferHistoryStore.size(Buffer.id(name)) < 64 * 1024
      assert length(BufferHistoryStore.read(Buffer.id(name))) >= 1
    end
  end
end
