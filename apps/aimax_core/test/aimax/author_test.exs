defmodule Aimax.AuthorTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Session}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp new_buf(text \\ "") do
    name = uniq("au")
    {:ok, ^name} = Core.create_buffer(name)
    if text != "", do: :ok = Buffer.append(name, text, source: :editor, author: :none)
    name
  end

  test "an insert stamps the author derived from the source" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor)
    :ok = Buffer.append(b, "def", source: {:agent, "claude-1"})
    :ok = Buffer.insert(b, "xy")

    assert Buffer.authors(b) == [
             {0, 3, "editor"},
             {3, 6, "agent:claude-1"},
             {6, 8, "user"}
           ]
  end

  test "an explicit author option wins over the source" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "review-bot")
    assert Buffer.authors(b) == [{0, 3, "review-bot"}]
  end

  test "author :none adjusts the spans but stamps nothing" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.insert_at(b, 3, "restored", source: :editor, author: :none)
    assert Buffer.authors(b) == [{0, 3, "a1"}]
  end

  test "an insert inside a span splits it; the inserted text keeps its own author" do
    b = new_buf()
    :ok = Buffer.append(b, "abcdef", source: :editor, author: "a1")
    :ok = Buffer.insert_at(b, 3, "XY", source: :editor, author: "a2")

    assert Buffer.authors(b) == [{0, 3, "a1"}, {3, 5, "a2"}, {5, 8, "a1"}]
  end

  test "adjacent spans by one author merge" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.append(b, "def", source: :editor, author: "a1")
    assert Buffer.authors(b) == [{0, 6, "a1"}]
  end

  test "a delete shifts and truncates spans" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.append(b, "def", source: :editor, author: "a2")

    # delete "cd" — one byte from each span
    :ok = Buffer.delete_range(b, 2, 2, source: :editor, author: "a2")
    assert Buffer.authors(b) == [{0, 2, "a1"}, {2, 4, "a2"}]

    # a delete that swallows a whole span drops it
    :ok = Buffer.delete_range(b, 0, 2, source: :editor, author: "a1")
    assert Buffer.authors(b) == [{0, 2, "a2"}]
  end

  test "undo restores the spans with the rope" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.append(b, "def", source: :editor, author: "a2")

    :ok = Buffer.undo(b)
    assert Buffer.text(b) == "abc"
    assert Buffer.authors(b) == [{0, 3, "a1"}]
  end

  test "the edit log records every mutation, newest first" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor)
    :ok = Buffer.delete_range(b, 0, 1, source: :editor, author: "a1")

    assert [{v2, "a1", 0, 0, 1}, {v1, "editor", 0, 3, 0}] = Buffer.edit_log(b)
    assert v2 > v1
  end

  test "the caller process's :aimax_edit_author is picked up" do
    b = new_buf()
    Process.put(:aimax_edit_author, "agent:x")
    :ok = Buffer.append(b, "abc", source: :editor)
    Process.delete(:aimax_edit_author)
    :ok = Buffer.append(b, "def", source: :editor)

    assert Buffer.authors(b) == [{0, 3, "agent:x"}, {3, 6, "editor"}]
  end

  test "with-edit-author attributes edits made by the thunk" do
    b = new_buf()

    {:ok, _} =
      Session.eval(~s{
        (with-edit-author "agent:t1"
          (lambda () (buffer-append! "#{b}" "hello")))})

    {:ok, _} = Session.eval(~s{(buffer-append! "#{b}" " world")})

    assert Buffer.authors(b) == [{0, 5, "agent:t1"}, {5, 11, "editor"}]
  end

  test "with-edit-author restores the previous author when the thunk raises" do
    b = new_buf()

    {:error, _} =
      Session.eval(~s{
        (with-edit-author "agent:t1"
          (lambda () (no-such-function)))})

    {:ok, _} = Session.eval(~s{(buffer-append! "#{b}" "after")})
    assert Buffer.authors(b) == [{0, 5, "editor"}]
  end

  test "buffer-authors and buffer-edit-log read from Scheme" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: {:agent, "c1"})

    assert {:ok, ~s{((0 3 "agent:c1"))}} = Session.eval(~s{(buffer-authors "#{b}")})
    assert {:ok, log} = Session.eval(~s{(buffer-edit-log "#{b}")})
    assert log =~ ~s{"agent:c1" 0 3 0}
  end
end
