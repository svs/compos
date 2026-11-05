defmodule Compos.RecentTest do
  @moduledoc "The recent order: one owner, read and written from any process."

  use Compos.Case

  alias Compos.Core.{Editor, Recent}

  setup do
    name = "test-recent-#{System.unique_integer([:positive])}"
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Compos.TestHelpers.one_window!()
    saved = Recent.order()
    on_exit(fn -> Recent.reset(saved) end)
    %{buf: name}
  end

  test "a visit through the Editor is in the order when the call returns", %{buf: buf} do
    pid = Process.whereis(Editor)

    # a window can hold `false` where a buffer name belongs. The history
    # used to take it, and mru-list then raised inside Editor.handle_call:
    # the Editor died and every buffer lost its local keymap
    Recent.reset([false])
    assert is_list(Recent.all())

    # real entries land, in order, in both shapes
    Recent.reset([buf])
    Recent.bump({:group, "g"})
    Editor.set_window_buffer(buf)

    assert Recent.all() == [["buffer", buf], ["group", "g"]]
    assert hd(Recent.buffers()) == buf
    assert Process.whereis(Editor) == pid
  end

  test "a group mark outlives buffer visits and a bury", %{buf: buf} do
    names = for i <- 1..499, do: "zz-ring-#{i}"
    Recent.reset(names ++ [{:group, "g"}])

    # the 500th entry pushes the mark out of the ring the switcher reads
    Editor.set_window_buffer(buf)
    refute ["group", "g"] in Recent.all()
    assert Recent.groups() == ["g"]

    Recent.bump({:group, "h"})
    Recent.bury(buf)
    assert Recent.groups() == ["h", "g"]
    assert List.last(Recent.buffers()) == buf
  end

  test "bumps from many processes at once all land" do
    names = for i <- 1..200, do: "zz-many-#{i}"
    Recent.reset([])

    names
    |> Enum.map(fn n -> Task.async(fn -> Recent.bump(n) end) end)
    |> Enum.each(&Task.await/1)

    assert Enum.sort(Recent.order()) == Enum.sort(names)
  end
end
