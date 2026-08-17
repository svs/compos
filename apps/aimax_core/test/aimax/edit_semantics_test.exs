defmodule Aimax.EditSemanticsTest do
  @moduledoc """
  The edit surface an agent reaches through eval-scheme.

  buffer-replace! was the only edit an agent could make without byte
  arithmetic. These are the rest of it, and the errors they answer with —
  the error text is the feature: a model that reads "occurs 3 times" fixes
  its own next call.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp buffer(text) do
    name = "zz-edit-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)
    name
  end

  test "buffer-replace-all! replaces every occurrence and says how many" do
    buf = buffer("a b a b a\n")

    assert eval!(~s{(buffer-replace-all! "#{buf}" "a" "X")}) == ~s{"replaced 3 occurrences"}
    assert Buffer.text(buf) == "X b X b X\n"

    assert eval!(~s{(buffer-replace-all! "#{buf}" "b" "Y")}) == ~s{"replaced 2 occurrences"}
    assert Buffer.text(buf) == "X Y X Y X\n"
  end

  test "buffer-replace-all! is one pass, not one edit per occurrence" do
    buf = buffer("a a a\n")

    eval!(~s{(buffer-replace-all! "#{buf}" "a" "X")})
    assert Buffer.text(buf) == "X X X\n"

    # one delete plus one insert, whatever the number of hits — the shape
    # buffer-replace! already has, so two undos put the text back
    Buffer.undo(buf)
    Buffer.undo(buf)
    assert Buffer.text(buf) == "a a a\n"
  end

  test "insert-before! and insert-after! place text around an anchor" do
    buf = buffer("def two do\n  2\nend\n")

    assert eval!(~s{(buffer-insert-before! "#{buf}" "def two" "@doc false\\n")}) == ~s{"inserted"}
    assert Buffer.text(buf) == "@doc false\ndef two do\n  2\nend\n"

    assert eval!(~s{(buffer-insert-after! "#{buf}" "end\\n" "\\ndef three do\\n  3\\nend\\n")}) ==
             ~s{"inserted"}

    assert Buffer.text(buf) =~ "def three do"
  end

  test "buffer-delete-text! deletes exact, unique text" do
    buf = buffer("keep\ndrop this line\nkeep\n")

    assert eval!(~s{(buffer-delete-text! "#{buf}" "drop this line\\n")}) == ~s{"deleted"}
    assert Buffer.text(buf) == "keep\nkeep\n"
  end

  test "every helper answers the same three errors, and changes nothing" do
    buf = buffer("a b a\n")

    missing = ~s{"error: old text not found — read the buffer and copy it exactly"}
    assert eval!(~s{(buffer-replace! "#{buf}" "zzz" "x")}) == missing
    assert eval!(~s{(buffer-replace-all! "#{buf}" "zzz" "x")}) == missing

    assert eval!(~s{(buffer-replace! "#{buf}" "a" "x")}) =~
             "old text occurs 2 times — include surrounding text"

    assert eval!(~s{(buffer-insert-after! "#{buf}" "a" "x")}) =~
             "anchor occurs 2 times — include surrounding text"

    assert eval!(~s{(buffer-delete-text! "#{buf}" "a")}) =~ "text occurs 2 times"
    assert eval!(~s{(buffer-insert-before! "#{buf}" "" "x")}) =~ "anchor must be non-empty"
    assert eval!(~s{(buffer-replace! "zz-no-such-buffer" "a" "b")}) =~ "no such buffer"

    # not one of those errors touched the buffer
    assert Buffer.text(buf) == "a b a\n"
  end

  test "the helpers are public, so apropos finds them with their effects" do
    hits = eval!(~s{(apropos "insert after anchor")})
    assert hits =~ "buffer-insert-after!"

    assert eval!(~s{(catalog-entry 'function "buffer-delete-text!")}) =~ ~s{effects ("write")}
  end
end
