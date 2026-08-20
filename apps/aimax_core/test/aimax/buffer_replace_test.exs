defmodule Aimax.BufferReplaceTest do
  @moduledoc """
  Buffer.replace_range/5 — one contiguous span replacement, one undo step.

  Paredit builds every structural edit (slurp, barf, splice, wrap) on this
  primitive, so one command must equal one undo.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp buffer(text) do
    name = "zz-replace-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)
    name
  end

  test "replace_range swaps the span" do
    buf = buffer("(foo bar) baz\n")

    assert :ok = Buffer.replace_range(buf, 5, 3, "quux", source: :editor)
    assert Buffer.text(buf) == "(foo quux) baz\n"
  end

  test "one undo restores the text" do
    buf = buffer("(foo bar) baz\n")

    :ok = Buffer.replace_range(buf, 0, 13, "(foo bar baz)", source: :editor)
    assert Buffer.text(buf) == "(foo bar baz)\n"

    Buffer.undo(buf)
    assert Buffer.text(buf) == "(foo bar) baz\n"
  end

  test "pure insert and pure delete are still one undo step each" do
    buf = buffer("ab\n")

    :ok = Buffer.replace_range(buf, 1, 0, "XY", source: :editor)
    assert Buffer.text(buf) == "aXYb\n"

    :ok = Buffer.replace_range(buf, 1, 2, "", source: :editor)
    assert Buffer.text(buf) == "ab\n"

    Buffer.undo(buf)
    assert Buffer.text(buf) == "aXYb\n"
    Buffer.undo(buf)
    assert Buffer.text(buf) == "ab\n"
  end

  test "out of bounds fails without changing the buffer" do
    buf = buffer("abc\n")

    assert {:error, :out_of_bounds} = Buffer.replace_range(buf, 2, 10, "x", source: :editor)
    assert {:error, :out_of_bounds} = Buffer.replace_range(buf, -1, 1, "x", source: :editor)
    assert Buffer.text(buf) == "abc\n"
  end

  test "point after the span shifts by the length delta" do
    buf = buffer("(a) tail\n")
    :ok = Buffer.goto(buf, 5)

    :ok = Buffer.replace_range(buf, 1, 1, "abc", source: :editor)
    assert Buffer.text(buf) == "(abc) tail\n"
    assert Buffer.point(buf) == 7
  end

  test "read-only blocks :user, admits :editor" do
    buf = buffer("abc\n")
    :ok = Buffer.set_read_only(buf, true)

    assert {:error, :read_only} = Buffer.replace_range(buf, 0, 1, "x", source: :user)
    assert :ok = Buffer.replace_range(buf, 0, 1, "x", source: :editor)
    assert Buffer.text(buf) == "xbc\n"
  end

  test "buffer-replace-range! reaches the primitive from Scheme" do
    buf = buffer("hello world\n")

    eval!(~s{(buffer-replace-range! "#{buf}" 6 5 "scheme")})
    assert Buffer.text(buf) == "hello scheme\n"

    Buffer.undo(buf)
    assert Buffer.text(buf) == "hello world\n"
  end
end
