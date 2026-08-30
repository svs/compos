defmodule Compos.WindowFillTest do
  @moduledoc "One pool answers which buffers may fill a window: the Scheme tests, in this daemon."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "the pool" do
    for name <- [
          "the-pool-is-the-groups-members-and-nothing-from-elsewhere",
          "a-peek-and-a-popup-are-not-fill-candidates"
        ] do
      {:ok, out} = Session.eval("(begin (load-tests!) (run-test '#{name}))")
      assert out == "()", "#{name}: #{out}"
    end
  end
end
