defmodule Aimax.EscMetaTest do
  @moduledoc """
  ESC is Meta, the Emacs way: an unbound ESC pends, and ESC k resolves
  as M-k. A map that binds ESC itself (evil, the completion popup) still
  wins, because the plain sequence resolves first.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @buf "zz-esc-meta.txt"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(code) do
    {:ok, v} = Session.eval(code)
    v
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!("""
    (begin
      (buffer-create "#{@buf}")
      (switch-to-buffer! "#{@buf}")
      (buffer-insert! "#{@buf}" 0 "hello world\\n")
      (goto-char! 0))
    """)

    on_exit(fn ->
      Editor.set_pending([])
      if Buffer.exists?(@buf), do: Aimax.Core.kill_buffer(@buf)
    end)

    :ok
  end

  test "ESC f runs M-f (forward-word)" do
    press(["ESC", "f"])
    assert Buffer.point(@buf) == 5
  end

  test "ESC C-9 runs C-M-9 (the meta joins the modifiers)" do
    eval!(~s{(define-command "zz-esc-cmf" (lambda () (goto-char! 7)))})
    eval!(~s{(global-set-key "C-M-9" "zz-esc-cmf")})
    press(["ESC", "C-9"])
    assert Buffer.point(@buf) == 7
  end

  test "a bare ESC pends instead of self-inserting" do
    press(["ESC"])
    assert Editor.snapshot().pending == ["ESC"]
    # ...and an unbound continuation clears it without inserting
    press(["q"])
    assert Editor.snapshot().pending == []
    assert Buffer.text(@buf) == "hello world\n"
  end

  test "ESC ESC quits" do
    press(["ESC", "ESC"])
    assert Editor.snapshot().pending == []
  end

  test "a local ESC binding beats the meta translation" do
    eval!(~s{(local-set-key* "#{@buf}" "ESC" "end-of-buffer")})
    # local keymaps persist by NAME past the kill — clean up for the
    # other tests in this file
    on_exit(fn -> Session.eval(~s{(local-unset-key* "#{@buf}" "ESC")}) end)

    press(["ESC"])
    assert Buffer.point(@buf) == byte_size("hello world\n")
  end
end
