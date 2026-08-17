defmodule Aimax.CodeStructureTest do
  @moduledoc """
  The structural code surface an agent reaches through eval-scheme.

  code-outline / code-find / code-read / code-replace! address a definition
  by the LINE it starts on, so an agent never matches a string or counts a
  byte. Tree-sitter answers where the buffer has a grammar (the elixir
  grammar is compiled in), and indentation answers everywhere else.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  @elixir """
  defmodule Zz do
    def one(x) do
      x + 1
    end

    def two(x) do
      x + 2
    end
  end
  """

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp ts_buffer(text) do
    name = "zz-code-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    Buffer.set_local(name, "ts-lang", "elixir")
    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)
    name
  end

  test "code-outline names every definition with the line it starts on" do
    buf = ts_buffer(@elixir)

    outline = eval!(~s{(code-outline "#{buf}")})

    # the defmodule wraps the file, so the level that folds is its defs
    assert outline =~ ~s{(2 "call" "def one(x) do")}
    assert outline =~ ~s{(6 "call" "def two(x) do")}
    assert eval!(~s{(buffer-local "#{buf}" 'code-backend)}) == ~s{"ts"}
  end

  test "code-find selects a definition by what its first line says" do
    buf = ts_buffer(@elixir)

    assert eval!(~s{(code-find "#{buf}" "def two")}) == ~s{((6 "call" "def two(x) do"))}
    assert eval!(~s{(code-find "#{buf}" "def zzz")}) == "()"
  end

  test "code-read returns exactly one definition" do
    buf = ts_buffer(@elixir)

    text = eval!(~s{(code-read "#{buf}" 6)})
    assert text =~ "def two(x) do"
    assert text =~ "x + 2"
    refute text =~ "def one"
  end

  test "code-replace! swaps a whole definition and leaves the rest alone" do
    buf = ts_buffer(@elixir)

    assert eval!(~s{(code-replace! "#{buf}" 6 "def two(x) do\\n    x * 2\\n  end")}) ==
             ~s{"replaced the call at line 6"}

    assert Buffer.text(buf) == """
           defmodule Zz do
             def one(x) do
               x + 1
             end

             def two(x) do
               x * 2
             end
           end
           """

    # and the file is still parseable structure: the outline still finds both
    assert eval!(~s{(length (code-outline "#{buf}"))}) == "2"
  end

  test "a line outside the buffer is an error, not a quiet edit of the last definition" do
    buf = ts_buffer(@elixir)

    assert eval!(~s{(code-read "#{buf}" 9999)}) =~ "is outside the buffer — it has"
    assert eval!(~s{(code-replace! "#{buf}" 0 "x")}) =~ "is outside the buffer"
    assert eval!(~s{(code-outline "zz-no-such-buffer")}) =~ "no such buffer"

    # the failed replace changed nothing
    assert Buffer.text(buf) == @elixir
  end

  test "a buffer with no grammar still has an outline, by indentation" do
    buf = "zz-plain-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Aimax.Core.create_buffer(buf, text: "first:\n  a\n  b\nsecond:\n  c\n")

    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    outline = eval!(~s{(code-outline "#{buf}")})
    assert outline =~ ~s{(1 "block" "first:")}
    assert outline =~ ~s{(4 "block" "second:")}
    assert eval!(~s{(buffer-local "#{buf}" 'code-backend)}) == ~s{"indent"}
    assert eval!(~s{(code-read "#{buf}" 4)}) =~ "second:"
  end

  test "the structural API is public, so apropos finds it" do
    assert eval!(~s{(apropos "definition line")}) =~ "code-read"
    assert eval!(~s{(catalog-entry 'function "code-replace!")}) =~ ~s{effects ("write")}
    assert eval!(~s{(catalog-entry 'function "code-outline")}) =~ ~s{effects ("read")}
  end
end
