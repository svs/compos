defmodule Compos.EvilTest do
  @moduledoc """
  evil.scm: Vim emulation driven through KeyDispatch.handle_key/1 — the
  same path the GUI uses. Covers states, motions, operators, counts,
  visual, registers, undo boundaries, search, ex, and passthrough.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_evil_buffer(text) do
    name = "evil-#{System.unique_integer([:positive])}"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    Buffer.goto(name, 0)
    eval!(~s{(enable-minor-mode! "#{name}" "evil-local-mode")})
    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  # --- states ----------------------------------------------------------------

  test "starts in normal mode; i enters insert, ESC returns to normal" do
    buf = fresh_evil_buffer("abc\n")
    assert Buffer.get_local(buf, "evil-state") == "normal"
    assert Buffer.get_local(buf, "modeline-info") == "NORMAL"

    press(["i"])
    assert Buffer.get_local(buf, "evil-state") == "insert"
    assert Buffer.get_local(buf, "modeline-info") == "INSERT"

    type("xy")
    assert Buffer.text(buf) == "xyabc\n"

    press(["ESC"])
    assert Buffer.get_local(buf, "evil-state") == "normal"
    # vim: ESC moves back onto the last inserted char
    assert Buffer.point(buf) == 1
  end

  test "normal-mode letters do not self-insert" do
    buf = fresh_evil_buffer("abc\n")
    type("zq")
    assert Buffer.text(buf) == "abc\n"
  end

  test "a appends after the cursor, A at end of line, o opens below" do
    buf = fresh_evil_buffer("ab\ncd\n")
    press(["a"])
    type("X")
    press(["ESC"])
    assert Buffer.text(buf) == "aXb\ncd\n"

    press(["A"])
    type("Y")
    press(["ESC"])
    assert Buffer.text(buf) == "aXbY\ncd\n"

    press(["o"])
    type("new")
    press(["ESC"])
    assert Buffer.text(buf) == "aXbY\nnew\ncd\n"
  end

  # --- motions ---------------------------------------------------------------

  test "h l 0 $ ^ move within the line, hjkl with counts" do
    buf = fresh_evil_buffer("  hello world\nsecond line\n")
    type("$")
    assert Buffer.point(buf) == 13
    type("0")
    assert Buffer.point(buf) == 0
    type("^")
    assert Buffer.point(buf) == 2
    type("3l")
    assert Buffer.point(buf) == 5
    type("2h")
    assert Buffer.point(buf) == 3
    type("j0")
    assert Buffer.point(buf) == 14
  end

  test "w b e word motions with vim semantics" do
    buf = fresh_evil_buffer("foo bar-baz qux\n")
    type("w")
    assert Buffer.point(buf) == 4
    type("w")
    # bar|-baz: punctuation is its own word
    assert Buffer.point(buf) == 7
    type("2w")
    assert Buffer.point(buf) == 12
    type("b")
    assert Buffer.point(buf) == 8
    type("0e")
    # end of "foo" — inclusive: cursor on the last char
    assert Buffer.point(buf) == 2
  end

  test "gg and G with counts go to lines" do
    buf = fresh_evil_buffer("one\ntwo\nthree\nfour\n")
    type("G")
    assert Buffer.point(buf) >= 18
    type("gg")
    assert Buffer.point(buf) == 0
    type("3G")
    assert Buffer.point(buf) == 8
    type("2gg")
    assert Buffer.point(buf) == 4
  end

  test "f t and ; find chars on the line" do
    buf = fresh_evil_buffer("abcabca\n")
    type("fa")
    assert Buffer.point(buf) == 3
    type(";")
    assert Buffer.point(buf) == 6
    type("0tc")
    assert Buffer.point(buf) == 1
    type("02fa")
    assert Buffer.point(buf) == 6
  end

  # --- operators & registers ---------------------------------------------------

  test "dw deletes a word into the register" do
    buf = fresh_evil_buffer("foo bar\n")
    type("dw")
    assert Buffer.text(buf) == "bar\n"
    assert eval!("*evil-reg*") == "\"foo \""
  end

  test "dd deletes the line; p pastes it below (linewise)" do
    buf = fresh_evil_buffer("one\ntwo\nthree\n")
    type("dd")
    assert Buffer.text(buf) == "two\nthree\n"
    type("p")
    assert Buffer.text(buf) == "two\none\nthree\n"
    assert Buffer.point(buf) == 4
  end

  test "2dd deletes two lines; P pastes them above" do
    buf = fresh_evil_buffer("one\ntwo\nthree\n")
    type("2dd")
    assert Buffer.text(buf) == "three\n"
    type("P")
    assert Buffer.text(buf) == "one\ntwo\nthree\n"
  end

  test "cw changes to end of word and enters insert (vim cw = ce)" do
    buf = fresh_evil_buffer("foo bar\n")
    type("cw")
    assert Buffer.get_local(buf, "evil-state") == "insert"
    type("zap")
    press(["ESC"])
    assert Buffer.text(buf) == "zap bar\n"
  end

  test "d$ via D, dG deletes to end of buffer" do
    buf = fresh_evil_buffer("hello there\nrest\nmore\n")
    type("3l")
    press(["D"])
    assert Buffer.text(buf) == "hel\nrest\nmore\n"
    type("j")
    type("dG")
    assert Buffer.text(buf) == "hel\n"
  end

  test "x deletes chars with count; yy p duplicates a line" do
    buf = fresh_evil_buffer("abcdef\n")
    type("3x")
    assert Buffer.text(buf) == "def\n"
    type("yyp")
    assert Buffer.text(buf) == "def\ndef\n"
  end

  test "diw and daw text objects" do
    buf = fresh_evil_buffer("foo bar baz\n")
    type("5l")
    type("diw")
    assert Buffer.text(buf) == "foo  baz\n"

    eval!(~s{(buffer-delete-range! "#{buf}" 0 (buffer-size "#{buf}"))})
    :ok = Buffer.append(buf, "foo bar baz\n", source: :editor)
    Buffer.goto(buf, 5)
    type("daw")
    assert Buffer.text(buf) == "foo baz\n"
  end

  test "r replaces a char; ~ toggles case; J joins lines" do
    buf = fresh_evil_buffer("cat\ndog\n")
    type("rb")
    assert Buffer.text(buf) == "bat\ndog\n"
    type("~")
    assert Buffer.text(buf) == "Bat\ndog\n"
    type("J")
    assert Buffer.text(buf) == "Bat dog\n"
  end

  # --- undo boundaries (the mechanism the core grew for evil) -------------------

  test "repeated u walks history instead of toggling into redo" do
    buf = fresh_evil_buffer("one two three\n")
    type("dw")
    assert Buffer.text(buf) == "two three\n"
    type("dw")
    assert Buffer.text(buf) == "three\n"
    type("u")
    assert Buffer.text(buf) == "two three\n"
    type("u")
    assert Buffer.text(buf) == "one two three\n"
  end

  test "an insert run undoes as one unit" do
    buf = fresh_evil_buffer("start\n")
    press(["A"])
    type(" and more")
    press(["ESC"])
    assert Buffer.text(buf) == "start and more\n"
    type("u")
    assert Buffer.text(buf) == "start\n"
  end

  # --- visual ------------------------------------------------------------------

  test "v with motion then d deletes the inclusive selection" do
    buf = fresh_evil_buffer("hello world\n")
    type("ve")
    assert Buffer.get_local(buf, "evil-state") == "visual"
    type("d")
    assert Buffer.text(buf) == " world\n"
    assert Buffer.get_local(buf, "evil-state") == "normal"
  end

  test "V j d deletes two whole lines" do
    buf = fresh_evil_buffer("one\ntwo\nthree\n")
    type("Vjd")
    assert Buffer.text(buf) == "three\n"
  end

  test "v y yanks charwise and p pastes after the cursor" do
    buf = fresh_evil_buffer("abc\n")
    type("vly")
    assert eval!("*evil-reg*") == "\"ab\""
    type("$p")
    assert Buffer.text(buf) == "abcab\n"
  end

  # --- search & ex ---------------------------------------------------------------

  test "/ jumps to the match, n repeats" do
    buf = fresh_evil_buffer("alpha beta\ngamma beta\n")
    press(["/"])
    type("beta")
    press(["RET"])
    assert Buffer.point(buf) == 6
    type("n")
    assert Buffer.point(buf) == 17
    # wraps
    type("n")
    assert Buffer.point(buf) == 6
  end

  test "? searches backward and wraps at the top" do
    buf = fresh_evil_buffer("alpha beta\ngamma beta\n")
    # nothing before point 0: the engine retries from the buffer end
    press(["?"])
    type("beta")
    press(["RET"])
    assert Buffer.point(buf) == 17
  end

  test ": with a number goes to that line, and any M-x name runs" do
    buf = fresh_evil_buffer("one\ntwo\nthree\n")
    press([":"])
    type("3")
    press(["RET"])
    assert Buffer.point(buf) == 8

    press([":"])
    type("beginning-of-buffer")
    press(["RET"])
    assert Buffer.point(buf) == 0
  end

  # --- toggling ------------------------------------------------------------------

  test "evil-local-mode off makes keys self-insert again (passthrough)" do
    buf = fresh_evil_buffer("\n")
    eval!(~s{(disable-minor-mode! "#{buf}" "evil-local-mode")})
    type("hi")
    assert Buffer.text(buf) == "hi\n"
    refute Buffer.get_local(buf, "modeline-info")
  end

  test "restore-minor-modes! re-runs setup and keeps the saved state" do
    buf = fresh_evil_buffer("text\n")
    press(["i"])
    assert Buffer.get_local(buf, "evil-state") == "insert"
    eval!(~s{(restore-minor-modes! "#{buf}")})
    assert Buffer.get_local(buf, "evil-state") == "insert"
    assert Buffer.get_local(buf, "modeline-info") == "INSERT"
    press(["ESC"])
    assert Buffer.get_local(buf, "evil-state") == "normal"
  end
end
