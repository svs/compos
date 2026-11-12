defmodule Compos.AfterInitTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Session

  test "the boot runs after-init-hook once the interpreter is published" do
    # the hook runs on a task after Session.init returns; wait for it
    done =
      Enum.find_value(1..100, fn _ ->
        case Session.eval("*after-init-done*") do
          {:ok, "#t"} -> true
          _ -> Process.sleep(50) && nil
        end
      end)

    assert done, "after-init-hook did not run"
  end
end
