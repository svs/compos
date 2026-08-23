defmodule Aimax.AuthorTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.{Buffer, ProvenanceStore, Session}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
  end

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

  # The fold is the durable form: a span names the changeset that wrote its
  # bytes, and the changeset holds the actor. The label view is a read of it.
  test "a span names the changeset that wrote it, and the origin holds the actor" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: {:agent, "c1"})

    %{spans: [{0, 3, id}], origins: origins} = Buffer.author_fold(b)

    assert is_binary(id)
    assert %{actor: actor} = origins[id]
    assert actor.id == "agent:c1"
    assert actor.kind == "agent"
    assert actor.run_id == "c1"
  end

  test "the changeset a span names is the revision the store recorded" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: {:agent, "c1"})

    %{spans: [{0, 3, id}]} = Buffer.author_fold(b)

    assert id in Enum.map(ProvenanceStore.history(Buffer.id(b)), & &1.id)
  end

  test "two runs by one author are two changesets, and one span to read" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.append(b, "def", source: :editor, author: "a1")

    %{spans: [{0, 3, first}, {3, 6, second}]} = Buffer.author_fold(b)

    refute first == second
    assert Buffer.authors(b) == [{0, 6, "a1"}]
  end

  test "attribution survives the buffer process dying" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: {:agent, "c1"})
    :ok = Buffer.append(b, "def", source: :editor, author: "a1")

    %{spans: before} = Buffer.author_fold(b)
    evict(b)

    assert Buffer.authors(b) == [{0, 3, "agent:c1"}, {3, 6, "a1"}]
    assert %{spans: ^before} = Buffer.author_fold(b)
  end

  test "a restored fold keeps only the origins its spans still name" do
    b = new_buf()
    :ok = Buffer.append(b, "abc", source: :editor, author: "a1")
    :ok = Buffer.append(b, "def", source: :editor, author: "a2")
    :ok = Buffer.delete_range(b, 0, 3)

    evict(b)

    %{spans: [{0, 3, id}], origins: origins} = Buffer.author_fold(b)

    assert Map.keys(origins) == [id]
    assert Buffer.authors(b) == [{0, 3, "a2"}]
  end

  # git speaks lines, the buffer speaks bytes. The line view is where the two
  # meet, so an agent can stage its own work and leave the rest alone.
  test "a span that crosses a newline attributes both lines" do
    b = new_buf()
    :ok = Buffer.append(b, "one\ntwo\n", source: :editor, author: "a1")

    # a line's bytes are its text; the newline that ends it is not part of it
    assert Buffer.author_lines(b) == [{1, "a1", 3}, {2, "a1", 3}]
  end

  test "a line two actors touched names both, the larger share first" do
    b = new_buf()
    :ok = Buffer.append(b, "def render(buf) do\n", source: :editor, author: "human")
    :ok = Buffer.insert_at(b, 11, "fer", source: :editor, author: "agent:x")

    assert [{1, "human", 18}, {1, "agent:x", 3}] = Buffer.author_lines(b)
  end

  test "the line view answers from a dormant buffer too" do
    b = new_buf()
    :ok = Buffer.append(b, "one\ntwo\n", source: {:agent, "c1"})
    evict(b)

    assert Buffer.author_lines(b) == [{1, "agent:c1", 3}, {2, "agent:c1", 3}]
  end

  test "Scheme can produce line-numbered source without a core primitive" do
    path = Path.join(System.tmp_dir!(), "aimax-numbered-#{System.unique_integer([:positive])}")
    File.write!(path, "alpha\nbeta\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, out} = Session.eval(~s{(read-file-numbered "#{path}")})
    assert out =~ ~S{1\talpha\n2\tbeta}
  end
end
