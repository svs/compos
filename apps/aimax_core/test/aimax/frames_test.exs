defmodule Aimax.FramesTest do
  @moduledoc "Frame lifecycle + independence: each client its own tree, buffers shared."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor}

  # every other test assumes the single default frame — leave none behind
  setup do
    on_exit(fn ->
      for fid <- Editor.frame_list(), fid != "f-main", do: Editor.delete_frame(fid)
      Editor.select_frame("f-main")
    end)

    :ok
  end

  test "attach nil creates a fresh one-window frame; known id reattaches" do
    {:ok, fid} = Editor.attach_frame(nil)
    assert fid != "f-main"
    assert [{_id, _buf}] = Editor.list_windows(fid)

    # reattach: same frame, layout intact
    Editor.split(:h, 0.5, fid)
    {:ok, ^fid} = Editor.attach_frame(fid)
    assert length(Editor.list_windows(fid)) == 2
  end

  test "attach with an unknown well-formed id keeps it (localStorage survives a wipe)" do
    {:ok, "f-keepme"} = Editor.attach_frame("f-keepme")
    assert "f-keepme" in Editor.frame_list()
  end

  test "attach with a malformed id generates a fresh one" do
    {:ok, fid} = Editor.attach_frame("junk")
    assert String.starts_with?(fid, "f-")
    refute fid == "junk"
  end

  test "delete_frame refuses the last frame, removes others" do
    assert {:error, :last_frame} = Editor.delete_frame("f-main")

    {:ok, fid} = Editor.attach_frame(nil)
    assert {:ok, _mb} = Editor.delete_frame(fid)
    refute fid in Editor.frame_list()
    assert {:error, :no_frame} = Editor.delete_frame(fid)
  end

  test "frames have independent trees; window ids are globally unique" do
    {:ok, fid} = Editor.attach_frame(nil)
    before = Editor.list_windows("f-main")

    Editor.split(:h, 0.5, fid)
    assert length(Editor.list_windows(fid)) == 2
    assert Editor.list_windows("f-main") == before

    all = Editor.list_windows("f-main") ++ Editor.list_windows(fid)
    ids = Enum.map(all, fn {id, _} -> id end)
    assert ids == Enum.uniq(ids)
  end

  test "same buffer in two frames shares text" do
    buf = "frames-shared-#{System.unique_integer([:positive])}"
    {:ok, fid} = Editor.attach_frame(nil)
    Editor.set_window_buffer(buf, "f-main")
    Editor.set_window_buffer(buf, fid)

    Buffer.insert(buf, "hello")
    assert {_, ^buf} = List.first(Editor.list_windows(fid))
    assert Buffer.text(buf) == "hello"
  end

  test "selecting another frame's window selects that frame" do
    {:ok, fid} = Editor.attach_frame(nil)
    {win, _buf} = List.first(Editor.list_windows(fid))

    Editor.select_frame("f-main")
    assert Editor.last_active_frame() == "f-main"

    :ok = Editor.set_active(win)
    assert Editor.last_active_frame() == fid
    assert Editor.active_window(fid) == win
  end

  test "old-arity calls follow the last-active frame" do
    {:ok, fid} = Editor.attach_frame(nil)
    buf = "frames-mru-#{System.unique_integer([:positive])}"

    Editor.select_frame(fid)
    Editor.set_window_buffer(buf)
    assert Editor.current_buffer() == buf

    Editor.select_frame("f-main")
    refute Editor.current_buffer() == buf
  end

  test "echo and pending are per frame" do
    {:ok, fid} = Editor.attach_frame(nil)
    Editor.set_echo("", "f-main")
    Editor.set_pending([], "f-main")
    Editor.set_echo("over here", fid)
    Editor.set_pending(["C-x"], fid)

    assert Editor.snapshot(fid).echo == "over here"
    assert Editor.snapshot(fid).pending == ["C-x"]
    assert Editor.snapshot("f-main").echo == ""
    assert Editor.snapshot("f-main").pending == []
  end
end
