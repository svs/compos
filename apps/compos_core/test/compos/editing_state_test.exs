defmodule Compos.EditingStateTest do
  @moduledoc """
  The movement and editing states through KeyDispatch, the path a key
  takes from the client. The tests bind dummy keys under <f9> to the
  commands they need; no test names a production key.
  """

  use Compos.Case

  alias Compos.Core.{Buffer, Editor, Session}

  @buf "zz-editing-state.txt"

  defp editing?, do: eval!(~s{(editing-state? "#{@buf}")}) == "#t"

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Compos.TestHelpers.one_window!()

    eval!("""
    (begin
      (buffer-create "#{@buf}")
      (switch-to-buffer! "#{@buf}")
      (buffer-insert! "#{@buf}" 0 "hello world\\n")
      (goto-char! 0)
      (editing--check-landing!)
      (global-set-key "<f9> e" "forward-char")
      (global-set-key "<f9> q" "keyboard-quit")
      (global-set-key "<f9> w" "focus-up")
      (define-command "zz-es-quit-by-proxy" "Run keyboard-quit from inside another command"
        (lambda () (run-command "keyboard-quit")))
      (global-set-key "<f9> g" "zz-es-quit-by-proxy")
      (global-set-key "<f9> s" "split-window-right"))
    """)

    on_exit(fn ->
      Editor.set_pending([])

      Session.eval("""
      (begin
        (global-unset-key "<f9> e")
        (global-unset-key "<f9> q")
        (global-unset-key "<f9> w")
        (global-unset-key "<f9> g")
        (global-unset-key "<f9> s"))
      """)

      if Buffer.exists?(@buf), do: Compos.Core.kill_buffer(@buf)
    end)

    :ok
  end

  test "a landing is the movement state; a command enters the editing state; keyboard-quit leaves it" do
    refute editing?()
    press(["<f9>", "e"])
    assert editing?()
    press(["<f9>", "q"])
    refute editing?()
  end

  test "a command that runs keyboard-quit inside itself leaves the editing state" do
    press(["<f9>", "e"])
    assert editing?()
    press(["<f9>", "g"])
    refute editing?()
  end

  test "a window command returns the buffer to the movement state" do
    press(["<f9>", "e"])
    assert editing?()
    press(["<f9>", "s"])
    refute editing?()
    Compos.TestHelpers.one_window!()
  end

  test "a focus command after a landing keeps the movement state" do
    press(["<f9>", "w"])
    refute editing?()
  end

  test "typing enters the editing state" do
    press(["x"])
    assert editing?()
    assert Buffer.text(@buf) == "xhello world\n"
  end
end
