defmodule Compos.Core.GroupIndexTest do
  # The group index files buffers by the group, mode and flag locals their
  # read-model rows hold. These drive it through BufferView, the one door
  # every row goes through, with names no real buffer has.
  use ExUnit.Case, async: false

  alias Compos.Core.{BufferView, GroupIndex}

  defp row(name, locals), do: %{name: name, id: "id-" <> name, locals: locals}

  setup do
    BufferView.ensure_group_index()
    names = for i <- 1..4, do: "*zz-gidx-#{System.unique_integer([:positive])}-#{i}*"
    on_exit(fn -> Enum.each(names, &BufferView.forget/1) end)
    {:ok, names: names}
  end

  test "a buffer is filed under the one group its locals name", %{names: [a, b | _]} do
    BufferView.put(row(a, %{"mode-name" => "text-mode", "group-ids" => ["grp:zz:1"]}))
    BufferView.put(row(b, %{"mode-name" => "chat-mode", "group-id" => "grp:zz:1", "group-ids" => ["grp:zz:2"]}))

    assert GroupIndex.select([b, a], ["grp:zz:1"]) == [b, a]
    # a chat is filed by its group-id alone
    assert GroupIndex.select([a, b], ["grp:zz:2"]) == []
  end

  test "a change of locals moves the buffer, and forget drops it", %{names: [a | _]} do
    BufferView.put(row(a, %{"group-ids" => ["grp:zz:1"]}))
    BufferView.put(row(a, %{"group-ids" => ["grp:zz:2"]}))

    assert GroupIndex.select([a], ["grp:zz:1"]) == []
    assert GroupIndex.select([a], ["grp:zz:2"]) == [a]

    BufferView.forget(a)
    assert GroupIndex.select([a], ["grp:zz:2"]) == []
  end

  test "several ids or a legacy local need the slow path", %{names: [a, b, c | _]} do
    BufferView.put(row(a, %{"group-ids" => ["grp:zz:1", "grp:zz:2"]}))
    BufferView.put(row(b, %{"group" => "old name"}))
    BufferView.put(row(c, %{"group-ids" => []}))

    # every reader of any group sees the slow rows
    assert GroupIndex.select([a, b, c], ["grp:zz:9"]) == [a, b]
  end

  test "buckets leave out context-only buffers and keep the given order", %{names: [a, b, c | _]} do
    BufferView.put(row(a, %{"group-ids" => ["grp:zz:1"]}))
    BufferView.put(row(b, %{"group-ids" => ["grp:zz:1"], "context-only" => true}))
    BufferView.put(row(c, %{"group-ids" => ["grp:zz:1"]}))

    assert {"grp:zz:1", [c, a]} in GroupIndex.buckets([c, b, a, c])
  end

  test "modes and flags are lookups too", %{names: [a, b, c | _]} do
    BufferView.put(row(a, %{"mode-name" => "zz-gidx-mode"}))
    BufferView.put(row(b, %{"mode-name" => "zz-other-mode", "agent-slug" => "s1"}))
    BufferView.put(row(c, %{"mode-name" => "zz-gidx-mode"}))

    assert {"zz-gidx-mode", [c, a]} in GroupIndex.modes([c, b, a])
    assert GroupIndex.filed([a, b, c], [{:mode, "zz-gidx-mode"}, {:has, "agent-slug"}]) == [a, b, c]
    assert {"zz-gidx-mode", 2} in GroupIndex.mode_counts()
  end
end
