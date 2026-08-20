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
