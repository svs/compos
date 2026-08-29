defmodule Compos.BufferViewTest do
  @moduledoc """
  The buffer read model (`Compos.Core.BufferView`).

  A live buffer publishes one public ETS row, and every reader takes that row
  instead of sending the buffer a message. The tests here hold the two facts
  that make the row safe to trust: it never lags the process that owns it,
  and a reader gets an answer even when that process cannot reply.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferStore, BufferView, Editor}

  setup do
    name = "*view-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name, text: "hello\nworld\n")
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    %{name: name}
  end

  defp view!(name) do
    {:ok, view} = BufferView.fetch(name)
    view
  end

  describe "the row follows the buffer" do
    test "a new buffer publishes before anyone can ask", %{name: name} do
      view = view!(name)
      assert BufferView.text(view) == "hello\nworld\n"
      assert view.size == 12
      assert view.version == 0
    end

    test "an insert lands in the row", %{name: name} do
      Buffer.goto(name, 0)
      Buffer.insert(name, "say ")

      view = view!(name)
      assert BufferView.text(view) == "say hello\nworld\n"
      assert view.size == 16
      assert view.point == 4
      assert view.version == Buffer.version(name)
    end

    test "a delete lands in the row", %{name: name} do
      Buffer.delete_range(name, 0, 6)
      assert BufferView.text(view!(name)) == "world\n"
      assert view!(name).size == 6
    end

    test "point, mark, and read-only land in the row", %{name: name} do
      Buffer.goto(name, 3)
      Buffer.set_mark(name, 7)
      Buffer.set_read_only(name, true)

      view = view!(name)
      assert view.point == 3
      assert view.mark == 7
      assert view.read_only
    end

    test "locals, overlays, and folds land in the row", %{name: name} do
      Buffer.set_local(name, "mode-name", "Fundamental")
      Buffer.set_overlays(name, "test", [{0, 5, "f-keyword"}])
      Buffer.set_hidden(name, "test", [1])

      view = view!(name)
      assert view.locals["mode-name"] == "Fundamental"
      assert view.overlay_gen == Buffer.overlay_gen(name)

      # the row keeps the per-tag maps; the reader flattens them
      assert view.overlays == %{"test" => [{0, 5, "f-keyword"}]}
      assert BufferView.overlays(view) == [{0, 5, "f-keyword"}]
      assert BufferView.hidden(view) == [1]
      assert Buffer.overlays(name) == [{0, 5, "f-keyword"}]
      assert Buffer.hidden(name) == [1]
    end

    test "narrowing lands in the row and old hot-loaded rows stay wide", %{name: name} do
      old_view = name |> view!() |> Map.delete(:narrow_range)
      assert BufferView.snapshot_of(old_view, nil).narrow_range == nil

      :ok = Buffer.narrow(name, 6, 11)
      assert view!(name).narrow_range == {6, 11}
      assert Buffer.render_snapshot(name).narrow_range == {6, 11}
    end

    test "the row is written before the write is answered", %{name: name} do
      # A caller that writes and then reads must never see the state it
      # replaced. The publish runs inside the callback, so the ETS row is
      # current by the time `insert` returns.
      for i <- 1..50 do
        Buffer.append(name, "#{i}\n")
        assert BufferView.text(view!(name)) == Buffer.text(name)
      end
    end

    test "the row is current before the change event announces it", %{name: name} do
      # A subscriber wakes on the event and reads the row without asking the
      # buffer. If the row were written after the send, a client could paint
      # one edit behind and stay there, because no further event would come.
      Compos.Core.Events.subscribe(name)

      writer = spawn_link(fn -> for i <- 1..200, do: Buffer.append(name, "#{i}\n") end)

      for _ <- 1..200 do
        assert_receive {:buffer_change, ^name, %{version: announced}}, 2_000
        {:ok, view} = BufferView.fetch(name)

        assert view.version >= announced,
               "row is at version #{view.version}, behind the announced #{announced}"
      end

      Compos.Core.Events.unsubscribe(name)
      Process.unlink(writer)
    end

    test "a save clears modified in the row", %{name: name} do
      path = Path.join(System.tmp_dir!(), "view-save-#{System.unique_integer([:positive])}.txt")
      on_exit(fn -> File.rm(path) end)

      Buffer.append(name, "x")
      assert view!(name).modified

      {:ok, ^path} = Buffer.save(name, path)
      refute view!(name).modified
      assert view!(name).path == path
    end
  end

  describe "reads do not need the process" do
    test "a suspended buffer still renders", %{name: name} do
      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)

      # This is the whole point of the read model. A buffer busy with a
      # reparse, a checkpoint or a save cannot answer, and before the row
      # existed every reader waited on it - including the Editor, which
      # holds the entire editor while it renders.
      :sys.suspend(pid)

      try do
        assert Buffer.text(name) == "hello\nworld\n"
        assert Buffer.point(name) == 0
        assert Buffer.byte_size(name) == 12
        assert Buffer.locals(name)["mode-name"] == nil
        assert Buffer.render_snapshot(name).text == "hello\nworld\n"

        # and the process really is unable to answer
        catch_exit(GenServer.call(pid, :text, 50))
      after
        :sys.resume(pid)
      end
    end

    test "a suspended buffer does not stall the editor", %{name: name} do
      Editor.set_window_buffer(name)
      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
      :sys.suspend(pid)

      try do
        state = Editor.render_state()
        assert render_text(state.tree, name) == "hello\nworld\n"
      after
        :sys.resume(pid)
        Editor.set_window_buffer("*scratch*")
      end
    end
  end

  describe "the row matches the process" do
    test "render_snapshot reads the same either way", %{name: name} do
      Buffer.goto(name, 8)
      Buffer.set_local(name, "mode-name", "Text")
      Buffer.set_overlays(name, "t", [{0, 3, "f-string"}])

      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
      from_row = Buffer.render_snapshot(name)
      from_process = GenServer.call(pid, {:render_snapshot, nil})

      assert from_row == from_process
    end

    test "a per-window point wins over the buffer point", %{name: name} do
      Buffer.set_win_point(name, 77, 6)

      assert Buffer.render_snapshot(name, 77).point == 6
      assert Buffer.render_snapshot(name, 77).line == 2
      assert Buffer.render_snapshot(name).point == Buffer.point(name)
    end

    test "a stored point past the end is clamped on read", %{name: name} do
      Buffer.set_win_point(name, 78, 11)
      Buffer.delete_range(name, 0, 10)

      assert Buffer.render_snapshot(name, 78).point <= Buffer.byte_size(name)
    end
  end

  describe "the row's lifetime" do
    test "a rename moves the row and leaves nothing behind", %{name: name} do
      renamed = name <> "-renamed"
      :ok = Buffer.rename(name, renamed, nil)
      on_exit(fn -> Compos.Core.kill_buffer(renamed) end)

      assert BufferView.fetch(name) == :error
      assert BufferView.text(view!(renamed)) == "hello\nworld\n"
      assert view!(renamed).name == renamed
    end

    test "a dead buffer keeps no row, and reads fall back to its checkpoint" do
      name = "*view-dormant-#{System.unique_integer([:positive])}*"
      {:ok, ^name} = Compos.Core.create_buffer(name, text: "persisted")
      on_exit(fn -> BufferStore.forget(name) end)

      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
      ref = Process.monitor(pid)
      Buffer.checkpoint_now(name)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # the registry drops its own entry on its own monitor, so a moment
      # after ours; the row and the entry both go, in whichever order
      wait_until(fn -> BufferView.fetch(name) == :error and not Buffer.exists?(name) end)
      assert Buffer.text(name) == "persisted"
    end

    test "a crash of the model heals, and no buffer dies with it", %{name: name} do
      [{buffer, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
      view = Process.whereis(BufferView)
      ref = Process.monitor(view)
      Process.exit(view, :kill)
      assert_receive {:DOWN, ^ref, :process, ^view, :killed}

      # the buffer that owned a row is still alive and still answering
      assert Process.alive?(buffer)
      assert Buffer.text(name) == "hello\nworld\n"

      # and the row comes back without waiting for the next edit
      wait_until(fn -> match?({:ok, _}, BufferView.fetch(name)) end)
      assert BufferView.text(view!(name)) == "hello\nworld\n"

      # the adopted buffer is watched again, so its row still goes when it does
      other = "*view-adopted-#{System.unique_integer([:positive])}*"
      {:ok, ^other} = Compos.Core.create_buffer(other, text: "x")
      Compos.Core.kill_buffer(other)
      wait_until(fn -> BufferView.fetch(other) == :error end)
    end

    test "a Ref reads through the row", %{name: name} do
      ref = Buffer.ref(name)
      assert {:ok, view} = BufferView.fetch(ref)
      assert view.name == name
      assert Buffer.text(ref) == "hello\nworld\n"
    end

    test "a Ref follows a rename through the row", %{name: name} do
      ref = Buffer.ref(name)
      renamed = name <> "-moved"
      :ok = Buffer.rename(name, renamed, nil)
      on_exit(fn -> Compos.Core.kill_buffer(renamed) end)

      assert {:ok, view} = BufferView.fetch(ref)
      assert view.name == renamed
    end
  end

  defp render_text(%{type: :split, children: children}, name),
    do: Enum.find_value(children, &render_text(&1, name))

  defp render_text(%{type: :leaf, buffer: buffer, text: text}, name),
    do: if(buffer == name, do: text)

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
