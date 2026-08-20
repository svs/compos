defmodule Aimax.PareditTest do
  @moduledoc """
  paredit.scm driven through KeyDispatch.handle_key/1 — the same path
  the GUI uses. The scanner tests call the pure functions directly.
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

  test "par-scan-forward walks lists, atoms, strings, and char literals" do
    assert eval!(~S{(par-scan-forward "(foo bar) baz" 0)}) == "9"
    assert eval!(~S{(par-scan-forward "(foo bar) baz" 9)}) == "13"
    assert eval!(~S{(par-scan-forward "'(a b) c" 0)}) == "6"
    assert eval!(~S{(par-scan-forward "\"a\\\"b\" c" 0)}) == "6"
    assert eval!(~S{(par-scan-forward "#\\( x" 0)}) == "3"
    assert eval!(~S{(par-scan-forward "; c\nfoo" 0)}) == "7"
    assert eval!(~S{(par-scan-forward "#|x (|# foo" 0)}) == "11"
  end

  test "par-scan-forward answers #f at a closer or at end of text" do
    assert eval!(~S{(par-scan-forward "(a) " 3)}) == "#f"
    assert eval!(~S{(par-scan-forward "(a b)" 4)}) == "#f"
  end

  test "par-scan-backward finds the previous sibling start" do
    assert eval!(~S{(par-scan-backward "(a bb)" 5)}) == "3"
    assert eval!(~S{(par-scan-backward "(a bb)" 3)}) == "1"
    assert eval!(~S{(par-scan-backward "(a bb)" 1)}) == "#f"
    assert eval!(~S{(par-scan-backward "(a) (b) x" 8)}) == "4"
  end

  test "par-up and par-close see the enclosing list through strings and comments" do
    assert eval!(~S{(par-up "(a (b c) d)" 5)}) == "3"
    assert eval!(~S{(par-up "(a (b c) d)" 2)}) == "0"
    assert eval!(~S{(par-up "x y" 2)}) == "#f"
    assert eval!(~S{(par-close "(a (b c) d)" 5)}) == "7"
    assert eval!(~S{(par-up "(a \"))\" b)" 8)}) == "0"
    assert eval!(~S{(par-close "(a ;)
 b)" 3)}) == "8"
  end

  # --- motion through keys ---------------------------------------------------

  test "C-M-f and C-M-b step over expressions and out of lists" do
    buf = fresh_buffer("(foo bar) baz\n")

    press(["C-M-f"])
    assert Buffer.point(buf) == 9
    press(["C-M-f"])
    assert Buffer.point(buf) == 13

    press(["C-M-b"])
    assert Buffer.point(buf) == 10
    press(["C-M-b"])
    assert Buffer.point(buf) == 0

    # inside a list, at its end, C-M-f exits past the closer
    Buffer.goto(buf, 8)
    press(["C-M-f"])
    assert Buffer.point(buf) == 9
  end

  test "C-M-u climbs to the opener; C-M-d dives into the next list" do
    buf = fresh_buffer("(a (b c) d)\n")

    Buffer.goto(buf, 5)
    press(["C-M-u"])
    assert Buffer.point(buf) == 3
    press(["C-M-u"])
    assert Buffer.point(buf) == 0

    press(["C-M-d"])
    assert Buffer.point(buf) == 1
    press(["C-M-d"])
    assert Buffer.point(buf) == 4
  end

  test "C-M-k kills one expression onto the kill ring" do
    buf = fresh_buffer("(foo) bar\n")

    press(["C-M-k"])
    assert Buffer.text(buf) == " bar\n"
    assert eval!("(kill-top)") == ~S{"(foo)"}
  end

  test "C-M-SPC marks the expression after point" do
    buf = fresh_buffer("(a b) c\n")

    press(["C-M-SPC"])
    assert eval!("(mark)") == "5"
    assert Buffer.point(buf) == 0
  end

  test "motion works inside strings: out to the quote ends" do
    buf = fresh_buffer(~S{(a "x y" b)} <> "\n")

    Buffer.goto(buf, 5)
    press(["C-M-f"])
    assert Buffer.point(buf) == 8
    Buffer.goto(buf, 5)
    press(["C-M-b"])
    assert Buffer.point(buf) == 3
  end

  # --- pair insertion --------------------------------------------------------

  test "typing a form end-to-end keeps the text balanced" do
    buf = fresh_buffer("")

    press(["(", "f", "o", "o", ")"])
    assert Buffer.text(buf) == "(foo)"
    assert Buffer.point(buf) == 5
  end

  test "( after an atom inserts a separating space" do
    buf = fresh_buffer("ab\n")

    Buffer.goto(buf, 2)
    press(["("])
    assert Buffer.text(buf) == "ab ()\n"
    assert Buffer.point(buf) == 4
  end

  test ") with no enclosing list inserts nothing" do
    buf = fresh_buffer("x\n")

    Buffer.goto(buf, 1)
    press([")"])
    assert Buffer.text(buf) == "x\n"
    assert echo() =~ "No enclosing list"
  end

  test ") removes blank space before the closer" do
    buf = fresh_buffer("(a  )\n")

    Buffer.goto(buf, 2)
    press([")"])
    assert Buffer.text(buf) == "(a)\n"
    assert Buffer.point(buf) == 3
  end

  test ") does not pull the closer into a line comment" do
    buf = fresh_buffer("(a ;x\n)\n")

    Buffer.goto(buf, 2)
    press([")"])
    assert Buffer.text(buf) == "(a ;x\n)\n"
    assert Buffer.point(buf) == 7
  end

  test "double quote pairs, escapes inside, and exits at the closer" do
    buf = fresh_buffer("")

    press(["\""])
    assert Buffer.text(buf) == "\"\""
    assert Buffer.point(buf) == 1

    press(["\""])
    assert Buffer.text(buf) == "\"\""
    assert Buffer.point(buf) == 2

    # inside a string a quote arrives escaped
    buf2 = fresh_buffer("\"ab\"\n")
    Buffer.goto(buf2, 2)
    press(["\""])
    assert Buffer.text(buf2) == "\"a\\\"b\"\n"
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

  test "DEL deletes an empty pair whole and refuses to break a full one" do
    buf = fresh_buffer("()\n")
    Buffer.goto(buf, 2)
    press(["DEL"])
    assert Buffer.text(buf) == "\n"

    buf2 = fresh_buffer("(a)\n")
    Buffer.goto(buf2, 3)
    press(["DEL"])
    assert Buffer.text(buf2) == "(a)\n"
    assert Buffer.point(buf2) == 2

    Buffer.goto(buf2, 1)
    press(["DEL"])
    assert Buffer.text(buf2) == "(a)\n"
    assert Buffer.point(buf2) == 0
  end

  test "DEL between a pair deletes both delimiters" do
    buf = fresh_buffer("()\n")
    Buffer.goto(buf, 1)
    press(["DEL"])
    assert Buffer.text(buf) == "\n"

    buf2 = fresh_buffer("\"\"\n")
    Buffer.goto(buf2, 1)
    press(["DEL"])
    assert Buffer.text(buf2) == "\n"
  end

  test "DEL inside a string deletes text but guards the opening quote" do
    buf = fresh_buffer("\"ab\"\n")

    Buffer.goto(buf, 2)
    press(["DEL"])
    assert Buffer.text(buf) == "\"b\"\n"

    press(["DEL"])
    assert Buffer.text(buf) == "\"b\"\n"
    assert Buffer.point(buf) == 0
  end

  test "C-d mirrors: empty pair goes whole, a full one is entered" do
    buf = fresh_buffer("()\n")
    press(["C-d"])
    assert Buffer.text(buf) == "\n"

    buf2 = fresh_buffer("(a)\n")
    press(["C-d"])
    assert Buffer.text(buf2) == "(a)\n"
    assert Buffer.point(buf2) == 1
    press(["C-d"])
    assert Buffer.text(buf2) == "()\n"
  end

  test "one DEL is one undo step for a pair" do
    buf = fresh_buffer("()\n")
    Buffer.goto(buf, 2)
    press(["DEL"])
    assert Buffer.text(buf) == "\n"
    Buffer.undo(buf)
    assert Buffer.text(buf) == "()\n"
  end

  # --- balanced kill-line ----------------------------------------------------

  test "C-k kills to the end of line but never a closer" do
    buf = fresh_buffer("(a b) c\n")
    Buffer.goto(buf, 1)
    press(["C-k"])
    assert Buffer.text(buf) == "() c\n"
    assert eval!("(kill-top)") == ~S{"a b"}
  end

  test "C-k reaches past eol to finish a datum that starts before it" do
    buf = fresh_buffer("(a (b\n c) d)\n")
    Buffer.goto(buf, 1)
    press(["C-k"])
    assert Buffer.text(buf) == "( d)\n"
  end

  test "C-k in a string stops at the closing quote" do
    buf = fresh_buffer("\"ab cd\" x\n")
    Buffer.goto(buf, 1)
    press(["C-k"])
    assert Buffer.text(buf) == "\"\" x\n"
  end

  test "C-k at eol kills the newline; before a lone closer it kills nothing" do
    buf = fresh_buffer("a\nb\n")
    Buffer.goto(buf, 1)
    press(["C-k"])
    assert Buffer.text(buf) == "ab\n"

    buf2 = fresh_buffer("(a)\n")
    Buffer.goto(buf2, 2)
    press(["C-k"])
    assert Buffer.text(buf2) == "(a)\n"
  end

  test "C-k kills a trailing comment with the datums" do
    buf = fresh_buffer("(a b ;x\n)\n")
    Buffer.goto(buf, 1)
    press(["C-k"])
    assert Buffer.text(buf) == "(\n)\n"
  end

  # --- structure -------------------------------------------------------------

  test "slurp forward pulls the next datum in; one undo restores" do
    buf = fresh_buffer("(foo) bar\n")
    Buffer.goto(buf, 4)
    press(["C-<right>"])
    assert Buffer.text(buf) == "(foo bar)\n"
    assert Buffer.point(buf) == 4

    Buffer.undo(buf)
    assert Buffer.text(buf) == "(foo) bar\n"
  end

  test "barf forward pushes the last datum out; one undo restores" do
    buf = fresh_buffer("(foo bar)\n")
    Buffer.goto(buf, 8)
    press(["C-<left>"])
    assert Buffer.text(buf) == "(foo) bar\n"
    assert Buffer.point(buf) == 4

    Buffer.undo(buf)
    assert Buffer.text(buf) == "(foo bar)\n"
  end

  test "slurp and barf backward mirror" do
    buf = fresh_buffer("a (b)\n")
    Buffer.goto(buf, 3)
    eval!(~s{(run-command "paredit-slurp-backward")})
    assert Buffer.text(buf) == "(a b)\n"

    buf2 = fresh_buffer("(a b)\n")
    Buffer.goto(buf2, 3)
    eval!(~s{(run-command "paredit-barf-backward")})
    assert Buffer.text(buf2) == "a (b)\n"
    assert Buffer.point(buf2) == 3
  end

  test "splice removes the enclosing delimiters" do
    buf = fresh_buffer("(a (b c) d)\n")
    Buffer.goto(buf, 5)
    press(["M-s"])
    assert Buffer.text(buf) == "(a b c d)\n"
    assert Buffer.point(buf) == 4
  end

  test "raise replaces the list with the datum at point" do
    buf = fresh_buffer("(a (b c) d)\n")
    Buffer.goto(buf, 4)
    press(["M-r"])
    assert Buffer.text(buf) == "(a b d)\n"
    assert Buffer.point(buf) == 3
  end

  test "wrap puts the next datum in a fresh pair" do
    buf = fresh_buffer("foo bar\n")
    press(["M-("])
    assert Buffer.text(buf) == "(foo) bar\n"
    assert Buffer.point(buf) == 1
  end

  test "structure ops touch nothing without a target" do
    buf = fresh_buffer("x\n")
    Buffer.goto(buf, 1)
    press(["C-<right>"])
    assert Buffer.text(buf) == "x\n"
    assert echo() =~ "No enclosing list"

    buf2 = fresh_buffer("(a) \n")
    Buffer.goto(buf2, 1)
    press(["C-<right>"])
    assert Buffer.text(buf2) == "(a) \n"
    assert echo() =~ "Nothing to slurp"
  end

  test "structure ops refuse a read-only buffer" do
    buf = fresh_buffer("(a) b\n")
    :ok = Buffer.set_read_only(buf, true)
    Buffer.goto(buf, 1)
    press(["C-<right>"])
    assert Buffer.text(buf) == "(a) b\n"
    assert echo() =~ "read-only"
  end

  test "slurp keeps byte offsets straight around multibyte text" do
    buf = fresh_buffer("(é) x\n")
    Buffer.goto(buf, 1)
    press(["C-<right>"])
    assert Buffer.text(buf) == "(é x)\n"
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

  test "the keys pass through only when another paredit buffer installed them" do
    # the dispatcher commands are global; a plain buffer only reaches
    # them when its own keymap binds them, so this asserts the local map
    buf = fresh_buffer("(a)\n", plain: true)
    assert eval!(~s{(local-keys "#{buf}")}) == "()"
  end
end
