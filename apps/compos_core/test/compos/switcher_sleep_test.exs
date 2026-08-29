defmodule Compos.SwitcherSleepTest do
  @moduledoc """
  One test: the sleep_buffer guards, which are the Elixir API.

  The switcher behaviour is Scheme and lives in
  priv/tests/switcher-sleep-test.scm. Those five were failing because they
  pressed C-x b, which named the modal switcher until groups.scm took that
  key for the group-aware prompt. They now open the switcher by its own
  command and pass.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferStore, Editor, KeyDispatch, Session}

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
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  # a buffer with history presence, then made dormant — the shape most of
  # the switcher pool has
  defp dormant_buffer(label) do
    name = unique(label)
    {:ok, ^name} = Compos.Core.create_buffer(name)
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
      Compos.Core.kill_buffer(@switch)
      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    {:ok, stand: stand}
  end

  test "sleep_buffer guards: displayed refuses, dormant is ok, unknown errors", %{stand: stand} do
    assert {:error, :displayed} = Compos.Core.sleep_buffer(stand)

    dorm = dormant_buffer("already")
    assert :ok = Compos.Core.sleep_buffer(dorm)

    assert {:error, :not_found} = Compos.Core.sleep_buffer(unique("nobody"))
  end

end
