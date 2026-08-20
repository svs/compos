defmodule Aimax.SwitcherSleepTest do
  @moduledoc """
  The modal switcher previews a dormant candidate by waking it. When the
  switcher closes, every woken buffer nobody picked goes back to sleep —
  and a dormant row stays a row: RET wakes it, C-k kills it.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, BufferStore, Editor, KeyDispatch, Session}

  @switch "*switch*"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

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

  setup do
    stand = fresh_window()

    on_exit(fn ->
      Aimax.Core.kill_buffer(@switch)
      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    {:ok, stand: stand}
  end

  test "narrowing to a dormant candidate wakes it; ESC puts it back to sleep" do
    dorm = dormant_buffer("doze")

    press(["C-x", "b"])
    assert Editor.current_buffer() == @switch
    type(String.trim(dorm, "*"))

    assert eventually(fn -> Buffer.exists?(dorm) end), "the preview did not wake the sleeper"

    press(["ESC"])
    assert eventually(fn -> not Buffer.exists?(dorm) end), "ESC left the sleeper awake"
    assert BufferStore.known?(dorm)
  end

  test "RET keeps the pick awake and sleeps the other woken candidate" do
    pick = dormant_buffer("pick")
    other = dormant_buffer("other")

    press(["C-x", "b"])
    type(String.trim(other, "*"))
    assert eventually(fn -> Buffer.exists?(other) end)

    press(List.duplicate("DEL", String.length(String.trim(other, "*"))))
    type(String.trim(pick, "*"))
    assert eventually(fn -> Buffer.exists?(pick) end)
    press(["RET"])

    assert Buffer.exists?(pick)
    assert Editor.current_buffer() == pick
    assert eventually(fn -> not Buffer.exists?(other) end)
    assert BufferStore.known?(other)
    Aimax.Core.kill_buffer(pick)
  end

  test "C-k kills the dormant buffer the row names" do
    dorm = dormant_buffer("kill")

    press(["C-x", "b"])
    type(String.trim(dorm, "*"))
    press(["C-k"])

    refute BufferStore.known?(dorm), "C-k left the dormant buffer in the store"
    assert Buffer.text("*messages*") =~ "killed 1 buffer"
    press(["ESC"])
  end

  test "a verb acts on the nearest row when point sits in the chrome" do
    dorm = dormant_buffer("chrome")

    press(["C-x", "b"])
    type(String.trim(dorm, "*"))

    # point below every row: on the key bar
    {:ok, _} = Session.eval(~s{(buffer-goto! "#{@switch}" (- (buffer-size "#{@switch}") 3))})
    assert eval!(~s{(car (list-current "#{@switch}"))}) == ~s{"#{dorm}"}

    press(["RET"])
    assert Buffer.exists?(dorm), "RET did not visit the nearest row"
    assert Editor.current_buffer() == dorm
    Aimax.Core.kill_buffer(dorm)
  end

  test "a row for a buffer killed elsewhere leaves the list on the next command" do
    victim = unique("gone")
    {:ok, ^victim} = Aimax.Core.create_buffer(victim)
    Buffer.touch(victim)

    press(["C-x", "b"])
    assert eval!(~s{(map car (list-entries "#{@switch}"))}) =~ victim

    Aimax.Core.kill_buffer(victim)
    refute Buffer.exists?(victim)

    # any command re-renders the list: the stamp moved
    press(["C-n"])
    refute eval!(~s{(map car (list-entries "#{@switch}"))}) =~ victim
    press(["ESC"])
  end

  test "sleep_buffer guards: displayed refuses, dormant is ok, unknown errors", %{stand: stand} do
    assert {:error, :displayed} = Aimax.Core.sleep_buffer(stand)

    dorm = dormant_buffer("already")
    assert :ok = Aimax.Core.sleep_buffer(dorm)

    assert {:error, :not_found} = Aimax.Core.sleep_buffer(unique("nobody"))
  end
end
