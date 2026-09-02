defmodule Compos.WindowHealTest do
  @moduledoc """
  Killing a displayed buffer must never leave a window pointing at the
  dead — and a stale interaction must never crash the Editor (its crash
  wipes the keymap: 'everything is undefined' until a daemon restart).
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor}

  test "killing a displayed buffer heals the window tree" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-victim")
    Buffer.append("heal-victim", "hello\n", source: :editor)
    Editor.set_window_buffer("heal-victim")
    assert Editor.current_buffer() == "heal-victim"

    Compos.Core.kill_buffer("heal-victim")

    # the window moved on; no window shows the dead buffer
    refute Editor.current_buffer() == "heal-victim"
    refute Enum.any?(Editor.list_windows(), fn {_id, b} -> b == "heal-victim" end)
  end

  # Emacs: kill-buffer keeps the window and shows another buffer in it.
  # A split the person made is not undone by a kill.
  test "killing a buffer keeps its window and fills it from the window's history" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-survivor")
    {:ok, _} = Compos.Core.create_buffer("heal-before")
    {:ok, _} = Compos.Core.create_buffer("heal-layout-victim")
    Editor.set_window_buffer("heal-survivor")
    Editor.split(:h, 0.5)
    Editor.set_window_buffer("heal-before")
    Editor.set_window_buffer("heal-layout-victim")
    assert length(Editor.list_windows()) == 2

    Compos.Core.kill_buffer("heal-layout-victim")

    assert length(Editor.list_windows()) == 2
    assert Editor.list_windows() |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             ["heal-before", "heal-survivor"]

    assert Editor.current_buffer() == "heal-before"
    Enum.each(["heal-survivor", "heal-before"], &Compos.Core.kill_buffer/1)
  end

  test "a window with no history falls back to a buffer no window shows" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-survivor")
    {:ok, _} = Compos.Core.create_buffer("heal-elsewhere")
    {:ok, _} = Compos.Core.create_buffer("heal-fresh-victim")
    Editor.set_window_buffer("heal-elsewhere")
    Editor.set_window_buffer("heal-survivor")
    Editor.split(:h, 0.5)
    Editor.set_window_buffer("heal-fresh-victim")

    Compos.Core.kill_buffer("heal-fresh-victim")

    assert length(Editor.list_windows()) == 2
    refute Enum.any?(Editor.list_windows(), fn {_id, b} -> b == "heal-fresh-victim" end)
    Enum.each(["heal-survivor", "heal-elsewhere"], &Compos.Core.kill_buffer/1)
  end

  test "killing a buffer shown in every window keeps every window" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-duplicate-victim")
    Editor.set_window_buffer("heal-duplicate-victim")
    Editor.split(:h, 0.5)
    assert length(Editor.list_windows()) == 2

    Compos.Core.kill_buffer("heal-duplicate-victim")

    assert length(Editor.list_windows()) == 2
    refute Enum.any?(Editor.list_windows(), fn {_id, b} -> b == "heal-duplicate-victim" end)
  end

  test "killing a hidden buffer leaves the layout unchanged" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-hidden-victim")
    before = Editor.list_windows()

    Compos.Core.kill_buffer("heal-hidden-victim")

    assert Editor.list_windows() == before
  end

  test "a click racing a buffer kill cannot crash the Editor" do
    Editor.delete_other_windows()
    {:ok, _} = Compos.Core.create_buffer("heal-race")
    Buffer.append("heal-race", "hello\n", source: :editor)
    Editor.set_window_buffer("heal-race")
    [{id, _} | _] = Editor.list_windows()

    # kill WITHOUT healing (simulates the race window: tree still points
    # at the dead buffer when the click lands)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, "heal-race")
    DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)

    assert {:error, _} = Editor.mouse_goto(id, 1, 1)
    # the Editor lived through it — keymap intact
    assert is_pid(Process.whereis(Compos.Core.Editor))
    Editor.set_window_buffer("*scratch*")
  end

  test "an invalid programmatic delete cannot crash its buffer" do
    name = "heal-delete-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, "still here", source: :editor)

    assert {:error, :out_of_bounds} = Buffer.delete_range(name, 10, 8, source: :editor)
    assert Buffer.exists?(name)
    assert Buffer.text(name) == "still here"

    Compos.Core.kill_buffer(name)
  end
end
