defmodule Aimax.AppPreviewTest do
  @moduledoc "C-c C-a runs a buffer as an app; a save reloads it."

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Aimax.Core.kill_buffer("*zz-app*")
      Editor.delete_other_windows()
    end)

    eval!(~s{(begin (buffer-create "*zz-app*") (switch-to-buffer! "*zz-app*"))})
    :ok
  end

  test "C-c C-a runs the buffer as an app and C-c C-a again stops it" do
    press(["C-c", "C-a"])
    assert eval!(~s{(buffer-local "*zz-app*" 'render-mode)}) == ~s{"app"}

    press(["C-c", "C-a"])
    assert eval!(~s{(buffer-local "*zz-app*" 'render-mode)}) == "#f"
  end

  test "C-c C-v and C-c C-a are different modes of the same buffer" do
    press(["C-c", "C-v"])
    # a buffer with no extension and no renderer local stays source
    assert eval!(~s{(buffer-local "*zz-app*" 'render-mode)}) == "#f"

    press(["C-c", "C-a"])
    assert eval!(~s{(buffer-local "*zz-app*" 'render-mode)}) == ~s{"app"}
  end

  test "a save reloads every running app" do
    press(["C-c", "C-a"])
    gen = eval!(~s{(buffer-local "*zz-app*" 'app-generation)})

    eval!(~s{(run-hooks 'after-save-hook)})
    after_save = eval!(~s{(buffer-local "*zz-app*" 'app-generation)})

    assert String.to_integer(after_save) == String.to_integer(gen) + 1
  end

  test "app-reload bumps the generation, and only for apps" do
    press(["C-c", "C-a"])
    before = String.to_integer(eval!(~s{(buffer-local "*zz-app*" 'app-generation)}))

    eval!(~s{(run-command "app-reload")})
    assert String.to_integer(eval!(~s{(buffer-local "*zz-app*" 'app-generation)})) == before + 1

    # a buffer that is not an app keeps no generation at all
    eval!(~s{(begin (buffer-create "*zz-plain*") (run-command "app-reload"))})
    assert eval!(~s{(buffer-local "*zz-plain*" 'app-generation)}) == "#f"
    Aimax.Core.kill_buffer("*zz-plain*")
  end

  test "the motion keys scroll an app window, they do not move point" do
    eval!(~s{(begin (insert! "one\\ntwo\\nthree\\nfour\\nfive\\n") (goto-char! 0))})
    press(["C-c", "C-a"])

    press("C-n")
    assert eval!("(point)") == "0"
  end
end
