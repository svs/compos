defmodule Aimax.BufferCaretTest do
  @moduledoc """
  The buffer reports where its caret stands. A display draws that answer and
  works nothing out for itself.
  """
  use ExUnit.Case, async: false

  alias Aimax.Core.Buffer

  setup do
    name = "zz-caret-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: "one\ntwo\nthree\n")
    %{name: name}
  end

  test "the caret names the point, the line, and the column", %{name: name} do
    Buffer.goto(name, 5)

    assert %{point: 5, line: 2, column: 1} = Buffer.caret(name)
  end

  test "the caret at the start of the buffer is line one, column zero", %{name: name} do
    Buffer.goto(name, 0)

    assert %{point: 0, line: 1, column: 0} = Buffer.caret(name)
  end

  test "a point past the end clamps instead of raising", %{name: name} do
    Buffer.goto(name, 9_999)

    assert Buffer.caret(name).point <= Buffer.byte_size(name)
  end

  test "a buffer that shows no caret answers nil", %{name: name} do
    Buffer.goto(name, 5)
    assert Buffer.caret(name)

    Buffer.set_local(name, "caret", false)
    assert Buffer.caret(name) == nil
  end

  test "the column is a byte column on the line the point falls on", %{name: name} do
    at = byte_size("one\ntwo\n") + 2
    Buffer.goto(name, at)

    assert %{line: 3, column: 2} = Buffer.caret(name)
  end
end
