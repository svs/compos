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
end
