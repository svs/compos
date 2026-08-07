defmodule Aimax.FramesTest do
  @moduledoc "Frame lifecycle + independence: each client its own tree, buffers shared."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Desktop, Editor, KeyDispatch, Session}

  # every other test assumes the single default frame — leave none behind
  setup do
    on_exit(fn ->
      for fid <- Editor.frame_list(), fid != "f-main", do: Editor.delete_frame(fid)
      Editor.select_frame("f-main")
      File.rm(Desktop.path())
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

  test "keys dispatch to their frame: text, prefix and echo stay put" do
    {:ok, fa} = Editor.attach_frame(nil)
    {:ok, fb} = Editor.attach_frame(nil)
    bufa = "frames-ka-#{System.unique_integer([:positive])}"
    bufb = "frames-kb-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(bufa, fa)
    Editor.set_window_buffer(bufb, fb)

    KeyDispatch.handle_key(fa, "h")
    KeyDispatch.handle_key(fb, "x")
    KeyDispatch.handle_key(fa, "i")

    assert Buffer.text(bufa) == "hi"
    assert Buffer.text(bufb) == "x"

    # a prefix in one frame leaves the other's pending untouched
    KeyDispatch.handle_key(fa, "C-x")
    assert Editor.snapshot(fa).pending == ["C-x"]
    assert Editor.snapshot(fb).pending == []
    KeyDispatch.handle_key(fa, "C-g")
  end

  test "scheme commands run against the dispatching frame" do
    {:ok, fa} = Editor.attach_frame(nil)
    {:ok, fb} = Editor.attach_frame(nil)

    assert {:ok, _} = Session.eval("(split-window! 'h)", fb)
    assert length(Editor.list_windows(fb)) == 2
    assert length(Editor.list_windows(fa)) == 1

    assert {:ok, fid} = Session.eval("(selected-frame)", fb)
    assert fid == inspect(fb) or fid == fb or fid =~ fb
  end

  test "delete-frame! from scheme; sole frame refused" do
    {:ok, fid} = Editor.attach_frame(nil)
    assert {:ok, _} = Session.eval("(delete-frame!)", fid)
    refute fid in Editor.frame_list()

    assert {:error, msg} = Session.eval("(delete-frame!)", "f-main")
    assert msg =~ "sole frame"
  end

  test "desktop v2 round-trips every frame's layout" do
    buf = "frames-dt-#{System.unique_integer([:positive])}"
    {:ok, fid} = Editor.attach_frame(nil)
    Editor.set_window_buffer(buf, fid)
    Editor.split(:h, 0.5, fid)

    assert :ok = Desktop.save_now()

    # wreck the layout, then restore over it
    Editor.delete_other_windows(fid)
    assert :ok = Desktop.restore_now()

    assert fid in Editor.frame_list()
    windows = Editor.list_windows(fid)
    assert length(windows) == 2
    assert Enum.all?(windows, fn {_id, b} -> b == buf end)
  end

  test "a v1 desktop (single tree) restores into the default frame" do
    buf = "frames-v1-#{System.unique_integer([:positive])}"
    Aimax.Core.create_buffer(buf)

    v1 = %{
      buffers: [],
      scratch: [],
      tree: {:split, :h, 0.5, {:leaf, buf, 0}, {:leaf, buf, 0}},
      active_buffer: buf,
      faces: %{}
    }

    File.write!(Desktop.path(), :erlang.term_to_binary(v1))
    assert :ok = Desktop.restore_now()

    windows = Editor.list_windows("f-main")
    assert length(windows) == 2
    assert Enum.all?(windows, fn {_id, b} -> b == buf end)
  end

  test "two frames prompt at once; keys and C-g stay in their own prompt" do
    {:ok, fa} = Editor.attach_frame(nil)
    {:ok, fb} = Editor.attach_frame(nil)

    KeyDispatch.handle_key(fa, "M-x")
    KeyDispatch.handle_key(fb, "M-x")
    assert Editor.snapshot(fa).minibuffer
    assert Editor.snapshot(fb).minibuffer

    # typing lands in the dispatching frame's prompt only
    for k <- ["f", "o", "r"], do: KeyDispatch.handle_key(fa, k)
    assert Editor.render_state(fa).minibuffer.input == "for"
    assert Editor.render_state(fb).minibuffer.input == ""

    # C-g cancels one prompt, not the other
    KeyDispatch.handle_key(fb, "C-g")
    assert Editor.snapshot(fb).minibuffer == nil
    assert Editor.render_state(fa).minibuffer.input == "for"
    assert Editor.snapshot(fa).echo != "Quit"

    KeyDispatch.handle_key(fa, "C-g")
    assert Editor.snapshot(fa).minibuffer == nil
  end

  test "each frame has its own minibuffer buffer; deleting the frame kills it" do
    {:ok, fid} = Editor.attach_frame(nil)
    name = Editor.minibuf_name(fid)
    assert name =~ fid
    refute name == Editor.minibuf_name("f-main")

    KeyDispatch.handle_key(fid, "M-x")
    assert Buffer.exists?(name)
    KeyDispatch.handle_key(fid, "C-g")

    Editor.delete_frame(fid)
    # Registry entries clear asynchronously after the buffer process dies
    Enum.find(1..100, fn _ -> Process.sleep(5) && not Buffer.exists?(name) end)
    refute Buffer.exists?(name)
  end

  # --- per-window points -----------------------------------------------------

  defp type(fid, str), do: for(k <- String.graphemes(str), do: KeyDispatch.handle_key(fid, k))

  test "two windows on one buffer in one frame keep independent points" do
    {:ok, fid} = Editor.attach_frame(nil)
    buf = "wp-one-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buf, fid)
    type(fid, "one two")

    Editor.split(:h, 0.5, fid)
    [{w1, _}, {w2, _}] = Editor.list_windows(fid)
    assert Editor.active_window(fid) == w1

    Editor.other_window(fid)
    Buffer.goto(buf, 0)

    # the deselected window kept its spot; the selected one moved
    assert Buffer.win_point(buf, w1) == 7
    assert Buffer.win_point(buf, w2) == 0

    points = for %{type: :leaf} = l <- Editor.render_state(fid).tree.children, do: l.point
    assert Enum.sort(points) == [0, 7]
  end

  test "two frames on one buffer: typing in one never moves the other's point" do
    {:ok, fa} = Editor.attach_frame(nil)
    {:ok, fb} = Editor.attach_frame(nil)
    buf = "wp-two-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buf, fa)
    Editor.set_window_buffer(buf, fb)
    [{wa, _}] = Editor.list_windows(fa)
    [{wb, _}] = Editor.list_windows(fb)

    type(fa, "hello")
    # fb still at 0; typing there prepends
    type(fb, "X")

    assert Buffer.text(buf) == "Xhello"
    # fa's point rode the insertion above it: end of its "hello"
    assert Buffer.win_point(buf, wa) == 6
    assert Buffer.win_point(buf, wb) == 1
  end

  test "marker semantics: insert above shifts, insert AT stays before, delete across collapses" do
    {:ok, fa} = Editor.attach_frame(nil)
    {:ok, fb} = Editor.attach_frame(nil)
    buf = "wp-marker-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buf, fa)
    Editor.set_window_buffer(buf, fb)
    [{wa, _}] = Editor.list_windows(fa)

    type(fa, "abcd")
    Buffer.goto(buf, 2)
    # deselect fa's window so its point (2) is a stored entry
    KeyDispatch.handle_key(fb, "C-g")
    assert Buffer.win_point(buf, wa) == 2

    # insertion exactly at the stored point leaves it before the new text
    Buffer.insert_at(buf, 2, "ZZ", source: :editor)
    assert Buffer.win_point(buf, wa) == 2

    # insertion strictly above shifts it
    Buffer.insert_at(buf, 0, "Y", source: :editor)
    assert Buffer.win_point(buf, wa) == 3

    # delete spanning the point collapses it to the delete start
    Buffer.delete_range(buf, 1, 4, source: :editor)
    assert Buffer.win_point(buf, wa) == 1
  end

  test "switching a window away from a buffer and back restores its point" do
    {:ok, fid} = Editor.attach_frame(nil)
    buf1 = "wp-back1-#{System.unique_integer([:positive])}"
    buf2 = "wp-back2-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buf1, fid)
    type(fid, "some text")
    Buffer.goto(buf1, 4)

    Editor.set_window_buffer(buf2, fid)
    # someone else moves buf1's plain point meanwhile
    Buffer.goto(buf1, 0)

    Editor.set_window_buffer(buf1, fid)
    assert Buffer.point(buf1) == 4
  end

  test "desktop round-trips per-window points" do
    {:ok, fid} = Editor.attach_frame(nil)
    buf = "wp-dt-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buf, fid)
    type(fid, "line one\nline two")

    Editor.split(:v, 0.5, fid)
    Editor.other_window(fid)
    Buffer.goto(buf, 3)
    # windows now at 3 (active) and 17 (stored)

    assert :ok = Desktop.save_now()
    Editor.delete_other_windows(fid)
    assert :ok = Desktop.restore_now()

    points =
      for %{type: :leaf} = l <- Editor.render_state(fid).tree.children, do: {l.point, l.buffer}

    assert Enum.sort(points) == [{3, buf}, {17, buf}]
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
