defmodule Aimax.SwitcherSleepTest do
  @moduledoc """
  C-x b previews a dormant candidate by waking it. When the prompt closes,
  every woken buffer nobody picked goes back to sleep.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, BufferStore, Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  defp unique(label), do: "*#{label}-#{System.unique_integer([:positive])}*"

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  # a buffer with history presence, then made dormant — the shape most of
  # the switcher pool has
  defp dormant_buffer(label) do
    name = unique(label)
    {:ok, ^name} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "asleep", source: :editor)
    Buffer.touch(name)
    evict(name)
    name
  end

  defp fresh_window do
    name = unique("stand")
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    name
  end

  defp clear_minibuffer do
    press(List.duplicate("DEL", String.length(Editor.snapshot().minibuffer.input)))
  end

  setup do
    {:ok, stand: fresh_window()}
  end

  test "highlighting a dormant candidate wakes it; C-g puts it back to sleep" do
    dorm = dormant_buffer("doze")

    press(["C-x", "b"])
    assert Editor.render_state().minibuffer
    type(String.trim(dorm, "*"))

    assert eventually(fn -> Buffer.exists?(dorm) end)

    press("C-g")
    assert eventually(fn -> not Buffer.exists?(dorm) end)
    assert BufferStore.known?(dorm)
  end

  test "RET keeps the pick awake and sleeps the other woken candidate" do
    pick = dormant_buffer("pick")
    other = dormant_buffer("other")

    press(["C-x", "b"])
    type(String.trim(other, "*"))
    assert eventually(fn -> Buffer.exists?(other) end)

    clear_minibuffer()
    type(String.trim(pick, "*"))
    assert eventually(fn -> Buffer.exists?(pick) end)
    press("RET")

    assert eventually(fn -> Editor.snapshot().minibuffer == nil end)
    assert Buffer.exists?(pick)
    assert Editor.current_buffer() == pick
    assert eventually(fn -> not Buffer.exists?(other) end)
    assert BufferStore.known?(other)
  end

  test "sleep_buffer guards: displayed refuses, dormant is ok, unknown errors", %{stand: stand} do
    assert {:error, :displayed} = Aimax.Core.sleep_buffer(stand)

    dorm = dormant_buffer("already")
    assert :ok = Aimax.Core.sleep_buffer(dorm)

    assert {:error, :not_found} = Aimax.Core.sleep_buffer(unique("nobody"))
  end
end
