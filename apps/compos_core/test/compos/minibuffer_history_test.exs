defmodule Compos.MinibufferHistoryTest do
  @moduledoc "Vertico-style: previously chosen candidates lead the list."

  use ExUnit.Case

  alias Compos.Core.{Editor, KeyDispatch}

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

  # A mode command takes the mode's name verbatim, and a plain sort is
  # ASCII — so "Dired" sat above every lowercase command at the top of the
  # list, ahead of anything the reader had actually used.
  test "commands sort by name, not by case" do
    names = Compos.Core.Session.command_names()

    assert names == Enum.sort_by(names, &String.downcase/1)
    assert "Dired" in names

    # and the prompt shows that order: with no history, the first candidate
    # is a real "a" command, not the one mode whose name is capitalised
    press(["M-x"])
    mb = Editor.render_state().minibuffer
    refute hd(mb.candidates).label == "Dired"
    press(["C-g"])
  end
end
