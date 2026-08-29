defmodule Compos.BufferFidelityTest do
  @moduledoc """
  Two Emacs rules the buffer keeps: a goal column counts characters, not
  bytes, so line motion never lands inside a multibyte character; and one
  command is one undo step, however many primitives it ran.
  """

  use ExUnit.Case

  alias Compos.Core.Buffer

  defp buffer(text) do
    name = "zz-fidelity-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    on_exit(fn -> if Buffer.exists?(name), do: Compos.Core.kill_buffer(name) end)
    name
  end

  test "line motion keeps a character column across multibyte lines" do
    # "日本語テキスト" is 7 characters of 3 bytes each: 21 bytes, newline at 21
    buf = buffer("日本語テキスト\nab\n日本語テキスト\n")
    # after the 4th character of line 1: byte 12
    Buffer.goto(buf, 12)
    Buffer.next_line(buf)
    # line 2 (bytes 22..24) is shorter: its end
    assert Buffer.point(buf) == 24
    Buffer.next_line(buf)
    # line 3 starts at 25; column 4 begins 12 bytes in, never mid-character
    assert Buffer.point(buf) == 25 + 12
    Buffer.previous_line(buf)
    Buffer.previous_line(buf)
    assert Buffer.point(buf) == 12
  end

  test "a byte column that would split a character lands on its boundary" do
    buf = buffer("abcde\n日本\n")
    # column 4 on line 1; line 2 has two characters, so column 4 is its end
    Buffer.goto(buf, 4)
    Buffer.next_line(buf)
    assert Buffer.point(buf) == 6 + 6
    Buffer.goto(buf, 1)
    Buffer.next_line(buf)
    # column 1 of line 2 is the second character's first byte, not byte 7
    assert Buffer.point(buf) == 6 + 3
  end

  test "an undo group makes several edits one undo step" do
    buf = buffer("abc\n")
    :ok = Buffer.undo_group(buf, true)
    :ok = Buffer.insert(buf, "X", source: :user)
    :ok = Buffer.insert(buf, "Y", source: :user)
    :ok = Buffer.delete_range(buf, 2, 1, source: :user)
    :ok = Buffer.undo_group(buf, false)
    assert Buffer.text(buf) == "XYbc\n"
    Buffer.undo(buf)
    assert Buffer.text(buf) == "abc\n"
  end

  test "without a group, each edit is its own step" do
    buf = buffer("abc\n")
    :ok = Buffer.insert(buf, "X", source: :editor)
    :ok = Buffer.insert(buf, "Y", source: :editor)
    Buffer.undo(buf)
    assert Buffer.text(buf) == "Xabc\n"
  end
end
