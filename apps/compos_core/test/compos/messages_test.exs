defmodule Compos.MessagesTest do
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])

    eval!(~S"""
    (begin
      (messages-clear!)
      (message "visible error" 'error)
      (message "hidden detail" 'debug)
      (run-command "view-messages")
      (global-set-key "<f9> m" "messages-filter-level"))
    """)

    on_exit(fn ->
      Editor.minibuffer_close()
      Session.eval("(messages-clear!)")
    end)

    :ok
  end

  test "the level filter runs through the editor key path" do
    KeyDispatch.handle_key("<f9>")
    KeyDispatch.handle_key("m")
    Editor.minibuffer_set_input("error")
    KeyDispatch.handle_key("RET")

    assert Buffer.text("*Messages*") =~ "visible error"
    refute Buffer.text("*Messages*") =~ "hidden detail"
    assert eval!(~S|(list-filters "*Messages*")|) =~ ~s{("level" "error")}
  end
end
