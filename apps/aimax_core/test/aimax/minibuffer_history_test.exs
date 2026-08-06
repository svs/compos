defmodule Aimax.MinibufferHistoryTest do
  @moduledoc "Vertico-style: previously chosen candidates lead the list."

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("hist-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  test "M-x orders by last used" do
    # run an obscure command via M-x
    press(["M-x"])
    type("transpose-chars")
    press(["RET"])

    # reopen: it leads the unfiltered list
    press(["M-x"])
    mb = Editor.render_state().minibuffer
    assert [%{label: "transpose-chars"} | _] = mb.candidates
    press(["C-g"])

    # run another; recency order updates
    press(["M-x"])
    type("delete-other-windows")
    press(["RET"])

    press(["M-x"])
    mb = Editor.render_state().minibuffer
    assert [%{label: "delete-other-windows"}, %{label: "transpose-chars"} | _] = mb.candidates
    press(["C-g"])
  end
end
