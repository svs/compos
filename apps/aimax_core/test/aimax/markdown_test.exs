defmodule Aimax.MarkdownTest do
  @moduledoc """
  Markdown parsed into nodes that know where they came from.

  Every assertion here reads a byte range back against the source, because
  the range is the whole point: it is what lets a caret be placed by asking
  rather than by guessing which construct point is standing in.
  """
  use ExUnit.Case, async: true

  alias Aimax.Core.Markdown

  defp kinds(nodes), do: Enum.map(nodes, & &1.kind)

  defp find(nodes, kind) do
    Enum.find_value(nodes, fn node ->
      if node.kind == kind, do: node, else: find(node.children, kind)
    end)
  end

  defp slice(text, node), do: binary_part(text, node.start, node.stop - node.start)

  describe "nesting from ranges" do
    test "a node's children are the captures its range contains" do
      tree =
        Markdown.nest([
          {"list", 0, 20},
          {"item", 0, 10},
          {"paragraph", 2, 10},
          {"item", 10, 20},
          {"paragraph", 12, 20}
        ])

      assert [%{kind: :list, start: 0, stop: 20} = list] = tree
      assert kinds(list.children) == [:item, :item]

      [first, second] = list.children
      assert kinds(first.children) == [:paragraph]
      assert kinds(second.children) == [:paragraph]
    end

    test "captures that do not overlap stay siblings" do
      tree = Markdown.nest([{"paragraph", 0, 5}, {"paragraph", 6, 11}])

      assert kinds(tree) == [:paragraph, :paragraph]
      assert Enum.all?(tree, &(&1.children == []))
    end

    test "the wider range is the parent when two begin together" do
      tree = Markdown.nest([{"item", 0, 10}, {"list", 0, 20}])

      assert [%{kind: :list} = list] = tree
      assert kinds(list.children) == [:item]
    end
  end

  describe "parsing" do
    # Excluded where the grammar is missing, never skipped in silence: the
    # setup below fails loudly rather than letting these pass on nothing.
    @describetag :markdown_grammar

    setup do
      assert {:ok, _} = Markdown.parse("# Title\n")
      :ok
    end

    test "a node's range is the source it was built from" do
      text = "# Title\n\nbody one\n"
      {:ok, tree} = Markdown.parse(text)

      assert slice(text, find(tree, :heading)) == "# Title\n"
      assert slice(text, find(tree, :paragraph)) == "body one\n"
    end

    test "inline nodes carry the document's own offsets" do
      text = "see [the docs](http://x.com/p) here\n"
      {:ok, tree} = Markdown.parse(text)

      assert slice(text, find(tree, :link)) == "[the docs](http://x.com/p)"
      assert slice(text, find(tree, :link_text)) == "the docs"
      assert slice(text, find(tree, :link_destination)) == "http://x.com/p"
    end

    test "emphasis and code spans keep their exact ranges" do
      text = "a **bold** and `code` here\n"
      {:ok, tree} = Markdown.parse(text)

      assert slice(text, find(tree, :strong)) == "**bold**"
      assert slice(text, find(tree, :code_span)) == "`code`"
    end

    test "a table names itself and its cells" do
      text = "| a | b |\n| - | - |\n| 1 | 2 |\n"
      {:ok, tree} = Markdown.parse(text)

      assert slice(text, find(tree, :table)) == text
      assert find(tree, :cell)
    end

    test "a fenced block keeps its content apart from its fence" do
      text = "```elixir\n:ok\n```\n"
      {:ok, tree} = Markdown.parse(text)

      assert slice(text, find(tree, :info)) == "elixir"
      assert slice(text, find(tree, :code_text)) == ":ok\n"
    end

    test "every node's range slices cleanly out of the source" do
      text = File.read!(Path.join(__DIR__, "../../../../docs/groups.md")) |> binary_part(0, 4000)
      {:ok, tree} = Markdown.parse(text)

      walk = fn walk, nodes ->
        Enum.each(nodes, fn node ->
          assert node.start >= 0
          assert node.stop <= byte_size(text)
          assert node.start <= node.stop
          # a child never reaches outside its parent
          Enum.each(node.children, fn kid ->
            assert kid.start >= node.start and kid.stop <= node.stop
          end)

          walk.(walk, node.children)
        end)
      end

      walk.(walk, tree)
    end
  end
end
