defmodule Compos.Core.Markdown do
  @moduledoc """
  Markdown, parsed into nodes that know where they came from.

  Every node carries the byte range of the source it was built from. That
  one fact is what the preview needed and never had: the caret, the mark,
  and a line's anchor are placed by asking where a source offset is, not by
  guessing which construct point is standing in.

  The parse is tree-sitter's, through the grammar the reader installs with
  `M-x ts-install-grammar markdown`. Markdown needs two grammars, and the
  split is the useful one: the block grammar reads the document's skeleton
  and leaves each paragraph's contents as one opaque `inline` node, and the
  inline grammar reads those. This module runs the second over each range
  the first handed it, and shifts the answer back into the document's own
  offsets.

  The query names one capture per node kind, because a capture name is how
  a kind reaches Elixir. The nesting comes back from the ranges: tree-sitter
  hands its captures out in document order, and a node's range contains its
  children's.
  """

  alias Compos.Core.TS

  # One capture per node kind, because a capture name is how a kind reaches
  # Elixir. The marker kinds are named too: their bytes are markup, and a
  # renderer has to know which bytes those are in order to leave them out.
  @block_query """
  (atx_heading) @heading
  (setext_heading) @heading
  (atx_h1_marker) @atx_h1_marker
  (atx_h2_marker) @atx_h2_marker
  (atx_h3_marker) @atx_h3_marker
  (atx_h4_marker) @atx_h4_marker
  (atx_h5_marker) @atx_h5_marker
  (atx_h6_marker) @atx_h6_marker
  (setext_h1_underline) @setext_h1_underline
  (setext_h2_underline) @setext_h2_underline
  (paragraph) @paragraph
  (fenced_code_block) @code
  (indented_code_block) @code
  (fenced_code_block_delimiter) @fence
  (info_string) @info
  (code_fence_content) @code_text
  (block_quote) @quote
  (block_quote_marker) @quote_marker
  (block_continuation) @continuation
  (list) @list
  (list_item) @item
  (list_marker_dot) @marker_dot
  (list_marker_parenthesis) @marker_paren
  (list_marker_minus) @marker_bullet
  (list_marker_star) @marker_bullet
  (list_marker_plus) @marker_bullet
  (task_list_marker_checked) @task_done
  (task_list_marker_unchecked) @task_todo
  (thematic_break) @rule
  (pipe_table) @table
  (pipe_table_header) @table_head
  (pipe_table_row) @table_row
  (pipe_table_cell) @cell
  (pipe_table_delimiter_row) @table_delimiter
  (inline) @inline
  """

  @inline_query """
  (emphasis) @emphasis
  (strong_emphasis) @strong
  (strikethrough) @strike
  (code_span) @code_span
  (emphasis_delimiter) @delimiter
  (code_span_delimiter) @delimiter
  (inline_link) @link
  (image) @image
  (link_text) @link_text
  (image_description) @link_text
  (link_destination) @link_destination
  (link_title) @link_title
  (link_label) @link_label
  (uri_autolink) @autolink
  (hard_line_break) @break
  """

  @doc """
  Parse TEXT into a list of root nodes.

  A node is `%{kind: atom, start: integer, stop: integer, children: [node]}`.
  Answers `{:error, :no_grammar}` when the Markdown grammar is not
  installed, so a caller can fall back rather than render nothing.
  """
  def parse(text) when is_binary(text) do
    langs = TS.ts_langs()

    if "markdown" in langs do
      {:ok, text |> block_nodes() |> expand_inlines(text, "markdown-inline" in langs)}
    else
      {:error, :no_grammar}
    end
  end

  defp block_nodes(text) do
    "markdown"
    |> TS.ts_query_nif(text, @block_query)
    |> nest()
  end

  # Each `inline` node names a range the block grammar did not read into.
  # Run the inline grammar over exactly that range and shift its offsets
  # back, so every node in the tree speaks the document's own coordinates.
  defp expand_inlines(nodes, _text, false), do: nodes

  # A table cell holds its text directly: the block grammar gives it no
  # `inline` child to stand for the contents. Read a cell the same way, or
  # emphasis in a table stays as the author's asterisks.
  @inline_holders [:inline, :cell]

  defp expand_inlines(nodes, text, true) do
    Enum.map(nodes, fn node ->
      if node.kind in @inline_holders and node.children == [] do
        %{node | children: inline_nodes(text, node.start, node.stop)}
      else
        %{node | children: expand_inlines(node.children, text, true)}
      end
    end)
  end

  defp inline_nodes(text, start, stop) do
    "markdown-inline"
    |> TS.ts_query_nif(binary_part(text, start, stop - start), @inline_query)
    |> Enum.map(fn {kind, from, to} -> {kind, from + start, to + start} end)
    |> nest()
  end

  @doc false
  # Captures arrive in document order and a parent's range contains its
  # children's, so one pass with a stack rebuilds the tree. A node that
  # repeats a range its parent already covers is the grammar naming the same
  # span twice; it nests, which costs nothing and keeps the walk simple.
  def nest(captures) do
    captures
    |> Enum.map(fn {name, start, stop} ->
      %{kind: String.to_atom(name), start: start, stop: stop, children: []}
    end)
    |> Enum.sort_by(&{&1.start, -&1.stop})
    |> build()
  end

  # Sorted by start, and by the wider range first where two start together.
  # So the head of the list is the parent, everything after it that begins
  # before it ends is inside it, and the first node that begins at or after
  # its end is its next sibling.
  defp build([]), do: []

  defp build([parent | rest]) do
    {inside, after_it} = Enum.split_while(rest, &(&1.start < parent.stop))

    [%{parent | children: build(inside)} | build(after_it)]
  end
end
