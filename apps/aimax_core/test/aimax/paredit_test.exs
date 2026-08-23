defmodule Aimax.PareditTest do
  @moduledoc """
  What paredit does with a KEY, driven through KeyDispatch.handle_key/1 —
  the same path the GUI uses.

  The editing itself is Scheme: every behaviour is a named command, and
  priv/tests/paredit-test.scm runs the command and reads the buffer. What
  is left here is dispatch — self-insert interleaved with paredit, the
  fallback when the mode is off, undo batching, arrow-chord precedence,
  and show-paren, which hangs off the key path and does not fire on
  run-command.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp echo, do: Editor.snapshot().echo

  defp fresh_buffer(text, opts \\ []) do
    name = "paredit-#{System.unique_integer([:positive])}"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    Buffer.goto(name, 0)

    unless opts[:plain],
      do: eval!(~s{(enable-minor-mode! "#{name}" "paredit-mode")})

    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)
    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  # --- scanner ---------------------------------------------------------------

  # --- motion through keys ---------------------------------------------------

  # --- pair insertion --------------------------------------------------------

  test "typing a form end-to-end keeps the text balanced" do
    buf = fresh_buffer("")

    press(["(", "f", "o", "o", ")"])
    assert Buffer.text(buf) == "(foo)"
    assert Buffer.point(buf) == 5
  end


  test "( inside a string or comment self-inserts" do
    buf = fresh_buffer("\"a\" ;c\n")

    Buffer.goto(buf, 2)
    press(["("])
    assert Buffer.text(buf) == "\"a(\" ;c\n"

    Buffer.goto(buf, 7)
    press(["("])
    assert Buffer.text(buf) == "\"a(\" ;c(\n"
  end


  # --- balanced deletion -----------------------------------------------------

  test "one DEL is one undo step for a pair" do
    buf = fresh_buffer("()\n")
    Buffer.goto(buf, 2)
    press(["DEL"])
    assert Buffer.text(buf) == "\n"
    Buffer.undo(buf)
    assert Buffer.text(buf) == "()\n"
  end


  # --- balanced kill-line ----------------------------------------------------

  # --- structure -------------------------------------------------------------

  test "the canonical chords slurp and barf: C-) C-( C-} C-{" do
    buf = fresh_buffer("(foo) bar\n")
    Buffer.goto(buf, 4)
    press(["C-)"])
    assert Buffer.text(buf) == "(foo bar)\n"
    press(["C-}"])
    assert Buffer.text(buf) == "(foo) bar\n"

    buf2 = fresh_buffer("a (b)\n")
    Buffer.goto(buf2, 3)
    press(["C-("])
    assert Buffer.text(buf2) == "(a b)\n"
    press(["C-{"])
    assert Buffer.text(buf2) == "a (b)\n"
  end


  # --- passthrough -----------------------------------------------------------

  test "without paredit-mode the keys keep their default behavior" do
    buf = fresh_buffer("(foo) bar\n", plain: true)

    # C-M-k has no fallback command: a quiet no-op
    press(["C-M-k"])
    assert Buffer.text(buf) == "(foo) bar\n"

    # C-M-f falls through to forward-sexp (no tree-sitter here)
    press(["C-M-f"])
    assert Buffer.point(buf) == 0
    assert echo() =~ "No structural navigation"
  end


  # --- word motion and show-paren --------------------------------------------

  test "the arrow chords move by word; paredit keeps C-arrows, M-arrows pass through" do
    buf = fresh_buffer("foo bar\n", plain: true)
    press(["C-<right>"])
    assert Buffer.point(buf) == 3
    press(["M-<right>"])
    assert Buffer.point(buf) == 7

    buf2 = fresh_buffer("(foo bar)\n")
    Buffer.goto(buf2, 1)
    press(["M-<right>"])
    assert Buffer.point(buf2) == 4
  end


  test "point beside a delimiter lights the pair; elsewhere it goes dark" do
    buf = fresh_buffer("(ab)x\n")

    press(["<right>", "<right>", "<right>", "<right>"])
    assert Buffer.point(buf) == 4
    assert eval!(~s{(buffer-overlays "#{buf}")}) =~ ~S{(0 1 "paren-match")}
    assert eval!(~s{(buffer-overlays "#{buf}")}) =~ ~S{(3 4 "paren-match")}

    press(["<right>"])
    refute eval!(~s{(buffer-overlays "#{buf}")}) =~ "paren-match"
  end


  test "a delimiter inside a string does not light" do
    buf = fresh_buffer(~S{"a)" b} <> "\n")
    Buffer.goto(buf, 2)
    press(["<right>"])
    refute eval!(~s{(buffer-overlays "#{buf}")}) =~ "paren-match"
  end


  # --- enablement ------------------------------------------------------------

  test "scheme-mode enables paredit by default; the defcustom turns it off" do
    buf = fresh_buffer("", plain: true)
    eval!(~s{(with-current-buffer "#{buf}" (lambda () (set-mode! "scheme-mode")))})
    assert eval!(~s{(minor-mode-on? "#{buf}" "paredit-mode")}) == "#t"
    press(["("])
    assert Buffer.text(buf) == "()"

    eval!("(set! paredit-in-scheme-mode #f)")

    buf2 = fresh_buffer("", plain: true)
    eval!(~s{(with-current-buffer "#{buf2}" (lambda () (set-mode! "scheme-mode")))})
    assert eval!(~s{(minor-mode-on? "#{buf2}" "paredit-mode")}) == "#f"

    eval!("(set! paredit-in-scheme-mode #t)")
  end


end
