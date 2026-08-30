defmodule Compos.PopupMoveTest do
  @moduledoc "The popup opens on the right and M-<arrows> move it: the Scheme tests, in this daemon."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "the popup's side and its move keys" do
    for name <- [
          "the-popup-opens-on-the-right-and-moves-to-the-edge-you-name",
          "a-move-outside-the-popup-does-nothing",
          "dismissing-a-popup-brings-back-the-one-under-it"
        ] do
      assert {:ok, "()"} = Session.eval("(begin (load-tests!) (run-test '#{name}))"), name
    end
  end
end
