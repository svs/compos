defmodule Compos.TermFocusTest do
  @moduledoc "The focus key of a terminal gives the keyboard back and closes nothing."
  use Compos.Case

  alias Compos.Core.{Buffer, Editor, Session, Terminal}

  # The key comes from the mode's own declaration, so the test names no binding.
  test "the focus key of a terminal keeps its window and its buffer" do
    name = "*zz-term-focus-#{System.unique_integer([:positive])}*"

    on_exit(fn ->
      Terminal.kill(name)
      if Buffer.exists?(name), do: Compos.Core.kill_buffer(name)
    end)

    {:ok, _} =
      Session.eval("""
      (begin
        (delete-other-windows!)
        (buffer-create "#{name}")
        (buffer-set-local! "#{name}" 'terminal-command "cat")
        (switch-to-buffer! "#{name}")
        (set-mode! "term-mode"))
      """)

    wait_until(fn -> Terminal.running?(name) end)
    press(["a"])
    assert {:ok, "#t"} = Session.eval(~s{(editing-state? "#{name}")})

    {:ok, key} = Session.eval(~s{(focus-key "#{name}")})
    press([String.trim(key, "\"")])

    assert Buffer.exists?(name), "the terminal buffer stays"
    assert Editor.current_buffer() == name, "the window still shows the terminal"
    assert Terminal.running?(name), "the process still runs"
    assert {:ok, "#f"} = Session.eval(~s{(editing-state? "#{name}")})
  end
end
