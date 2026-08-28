defmodule Aimax.WindowHealTest do
  @moduledoc """
  Killing a displayed buffer must never leave a window pointing at the
  dead — and a stale interaction must never crash the Editor (its crash
  wipes the keymap: 'everything is undefined' until a daemon restart).
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor}

  test "killing a displayed buffer heals the window tree" do
    Editor.delete_other_windows()
    {:ok, _} = Aimax.Core.create_buffer("heal-victim")
    Buffer.append("heal-victim", "hello\n", source: :editor)
    Editor.set_window_buffer("heal-victim")
    assert Editor.current_buffer() == "heal-victim"

    Aimax.Core.kill_buffer("heal-victim")

    # the window moved on; no window shows the dead buffer
    refute Editor.current_buffer() == "heal-victim"
    refute Enum.any?(Editor.list_windows(), fn {_id, b} -> b == "heal-victim" end)
  end

  test "killing a buffer removes its window instead of duplicating another buffer" do
    Editor.delete_other_windows()
    {:ok, _} = Aimax.Core.create_buffer("heal-survivor")
    {:ok, _} = Aimax.Core.create_buffer("heal-layout-victim")
    Editor.set_window_buffer("heal-survivor")
    Editor.split(:h, 0.5)
    Editor.set_window_buffer("heal-layout-victim")
    assert length(Editor.list_windows()) == 2

    Aimax.Core.kill_buffer("heal-layout-victim")

    assert Editor.list_windows() |> Enum.map(&elem(&1, 1)) == ["heal-survivor"]
    Aimax.Core.kill_buffer("heal-survivor")
  end

  test "killing a buffer shown in every window collapses duplicate windows" do
    Editor.delete_other_windows()
    {:ok, _} = Aimax.Core.create_buffer("heal-duplicate-victim")
    Editor.set_window_buffer("heal-duplicate-victim")
    Editor.split(:h, 0.5)
    assert length(Editor.list_windows()) == 2

    Aimax.Core.kill_buffer("heal-duplicate-victim")

    assert length(Editor.list_windows()) == 1
    refute Editor.current_buffer() == "heal-duplicate-victim"
  end

  test "killing a hidden buffer leaves the layout unchanged" do
    Editor.delete_other_windows()
    {:ok, _} = Aimax.Core.create_buffer("heal-hidden-victim")
    before = Editor.list_windows()

    Aimax.Core.kill_buffer("heal-hidden-victim")

    assert Editor.list_windows() == before
  end

  test "a click racing a buffer kill cannot crash the Editor" do
    Editor.delete_other_windows()
    {:ok, _} = Aimax.Core.create_buffer("heal-race")
    Buffer.append("heal-race", "hello\n", source: :editor)
    Editor.set_window_buffer("heal-race")
    [{id, _} | _] = Editor.list_windows()

    # kill WITHOUT healing (simulates the race window: tree still points
    # at the dead buffer when the click lands)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, "heal-race")
    DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)

    assert {:error, _} = Editor.mouse_goto(id, 1, 1)
    # the Editor lived through it — keymap intact
    assert is_pid(Process.whereis(Aimax.Core.Editor))
    Editor.set_window_buffer("*scratch*")
  end

  test "an invalid programmatic delete cannot crash its buffer" do
    name = "heal-delete-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "still here", source: :editor)

    assert {:error, :out_of_bounds} = Buffer.delete_range(name, 10, 8, source: :editor)
    assert Buffer.exists?(name)
    assert Buffer.text(name) == "still here"

    Aimax.Core.kill_buffer(name)
  end
end
