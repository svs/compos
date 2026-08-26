defmodule Aimax.Core.Markdown.Html do
  @moduledoc """
  Markdown nodes, drawn as HTML, with the source range on every element.

  The emitter walks the source rather than the tree: between one child and
  the next it emits the source that lies between them. So the text a reader
  sees is the author's own bytes, and a mark placed at a byte offset lands
  exactly where that byte was drawn - the caret is not aligned, guessed, or
  seeked for, it is cut in at the offset while the text is being written.

  A node kind that draws nothing - a heading's `#`, a list's bullet, a
  fence's backticks, a link's destination - says so in `@silent`. That is
  the grammar's own vocabulary written down, not a rule about where a
  cursor may stand.
  """

  alias Aimax.Core.Markdown

  # Source that is markup: consumed, never drawn. This is the grammar's own
  # vocabulary written down - the bytes it says are a marker - not a rule
  # about where a cursor may stand.
  @silent ~w(
    atx_h1_marker atx_h2_marker atx_h3_marker atx_h4_marker atx_h5_marker
    atx_h6_marker setext_h1_underline setext_h2_underline
    marker_dot marker_paren marker_bullet task_done task_todo
    quote_marker continuation fence info delimiter
    link_destination link_title link_label table_delimiter
  )a

  @doc """
  Render TEXT as HTML, cutting MARKS into the text at their byte offsets.

  MARKS is a list of `{offset, html}`. Each is written into the output at
  the point its offset is reached, so a caret at byte 20 is drawn between
  the bytes that were 19 and 20 - whatever construct they belong to.

  Answers `{:error, :no_grammar}` when the Markdown grammar is missing.
  """
  def render(text, marks \\ [], opts \\ []) do
    case Markdown.parse(text) do
      {:error, reason} -> {:error, reason}
      {:ok, tree} -> {:ok, render_tree(tree, text, marks, opts)}
    end
  end

  @doc """
  Draw an already-parsed TREE.

  Parsing a document costs a hundred times what drawing it does, and moving
  the caret does not change the tree. So the caller parses once per edit and
  draws once per keystroke.
  """
  def render_tree(tree, text, marks \\ [], opts \\ []) do
    # Whether whitespace draws is one answer for the whole page, and it is
    # read where the text is escaped - the deepest point of the walk. The
    # process holds it rather than every function passing it down.
    Process.put(:aimax_md_whitespace, opts[:whitespace] == true)
    # An image's source is a path in the document and a URL on the page, and
    # only the caller knows how one becomes the other. A pasted image is an
    # absolute path, which a browser will not load: without this it drew
    # nothing.
    Process.put(:aimax_md_image_src, opts[:image_src])

    marks = Enum.sort_by(marks, &elem(&1, 0))
    {iodata, marks} = nodes(tree, text, 0, marks)

    # The blank lines after the last block are lines too, and RET at the end
    # of a document makes one of them. Without this the caret landed after
    # the closing tag of the last block, outside every line on the page.
    last = tree |> List.last() |> then(&if(&1, do: &1.stop, else: 0))
    {tail, marks} = blank_lines(text, last, byte_size(text), marks)

    # a mark past the last byte still has to be drawn
    IO.iodata_to_binary([iodata, tail, Enum.map(marks, &elem(&1, 1))])
  end

  # Between blocks, whitespace is structure: the blank line that separates
  # two paragraphs is not something the author wrote INTO either of them.
  # Drawn as text it puts a stray line between every block - invisible until
  # whitespace-mode drew it, and then three marks stacked on a line of their
  # own. Inside a paragraph or a heading the same bytes ARE content, and a
  # line break there is the author's.
  #
  # A mark in that gap still draws: point can stand on a blank line, and it
  # has to show.
  @containers ~w(root list item quote table table_head table_row code)a

  defp nodes(nodes, text, from, marks, parent \\ :root) do
    content? = parent not in @containers

    {parts, {_at, _after_marker, marks}} =
      Enum.map_reduce(nodes, {from, false, marks}, fn node, {at, after_marker, marks} ->
        {skipped, at, marks} = skip_separator(text, at, node.start, after_marker, marks)

        {gap, marks} =
          cond do
            content? -> slice(text, at, node.start, marks)
            # A blank line is a blank line only between blocks. The newline
            # that separates two table rows, or two list items, separates
            # them - it is not a line the author left empty. Drawn as one,
            # a twenty row table opened a screenful of nothing above itself.
            parent == :root -> blank_lines(text, at, node.start, marks)
            true -> gap_marks(at, node.start, marks)
          end

        {body, marks} = node(node, text, marks)
        {[skipped, gap, body], {node.stop, node.kind in @silent, marks}}
      end)

    {parts, marks}
  end

  # A blank line the author typed is a line, and a reader who presses RET
  # has to see one appear. Between blocks each newline is exactly that: draw
  # it as an empty line of its own, tall enough to stand in, and put any
  # mark that falls on it inside - so point can sit on a blank line and show
  # there.
  defp blank_lines(text, at, stop, marks) when at < stop do
    gap = binary_part(text, at, stop - at)

    {lines, marks} =
      :binary.matches(gap, "\n")
      |> Enum.map(fn {i, _} -> at + i end)
      |> Enum.map_reduce(marks, fn pos, marks ->
        {here, rest} = Enum.split_while(marks, fn {off, _} -> off <= pos end)
        {[~s(<div class="bl" data-s="#{pos}">), Enum.map(here, &elem(&1, 1)), "</div>"], rest}
      end)

    # a mark past the last newline of the gap still belongs to the gap
    {tail, marks} = Enum.split_while(marks, fn {off, _} -> off < stop end)

    {[lines, Enum.map(tail, &elem(&1, 1))], marks}
  end

  defp blank_lines(_text, _at, _stop, marks), do: {[], marks}

  defp gap_marks(at, stop, marks) do
    {here, rest} = Enum.split_while(marks, fn {off, _} -> off >= at and off < stop end)
    {Enum.map(here, &elem(&1, 1)), rest}
  end

  # The space between a marker and what it marks belongs to the marker: the
  # grammar gives "#" its own node and leaves the space after it, which would
  # otherwise draw as an indent on every heading and list item. The byte is
  # skipped in the source, before any mark is cut in - trimming the drawn
  # text instead would trim a caret standing on that very space.
  defp skip_separator(text, at, stop, true, marks) when at < stop do
    case :binary.at(text, at) do
      c when c in [?\s, ?\t] ->
        {here, rest} = Enum.split_while(marks, fn {off, _} -> off <= at end)
        {Enum.map(here, &elem(&1, 1)), at + 1, rest}

      _ ->
        {[], at, marks}
    end
  end

  defp skip_separator(_text, at, _stop, _after_marker, marks), do: {[], at, marks}

  # The source between two offsets, escaped, with any mark that falls
  # inside it cut in at its own byte.
  defp slice(_text, at, stop, marks) when at >= stop, do: {[], marks}

  defp slice(text, at, stop, marks) do
    {here, rest} = Enum.split_while(marks, fn {off, _} -> off < stop end)

    {parts, cursor} =
      Enum.map_reduce(here, at, fn {off, html}, cursor ->
        off = max(off, cursor)
        {[run(text, cursor, off), html], off}
      end)

    {[parts, run(text, cursor, stop)], rest}
  end

  # Every run of drawn text says where in the source it began. A reader
  # moving down a line asks the page where the caret landed, and the page
  # can now answer exactly instead of counting rendered characters back to
  # the nearest line mark - a count that is wrong by every byte of markup
  # the renderer took out, so `**bold**` threw it off by four.
  defp run(_text, from, to) when from >= to, do: []

  defp run(text, from, to),
    do: [
      ~s(<span class="s" data-s="#{from}">),
      escape(binary_part(text, from, to - from)),
      "</span>"
    ]

  # Consumed: its bytes are markup. A mark inside it still draws, or a caret
  # sitting in a heading's "# " would vanish while point was really there.
  defp node(%{kind: kind} = node, _text, marks) when kind in @silent,
    do: {marks_only(node, marks), drop_marks(node, marks)}

  # A list item with one paragraph is a tight item, and its text belongs
  # beside the bullet. Wrapped in a block-level <p> it dropped to the line
  # below, and every bullet stood alone above its own sentence. An item with
  # more than one block is loose, and keeps its paragraphs.
  defp node(%{kind: :item} = node, text, marks) do
    node =
      case Enum.filter(node.children, &(&1.kind == :paragraph)) do
        [only] -> %{node | children: bare(node.children, only)}
        _ -> node
      end

    {inner, marks} = children(node, text, marks)
    {[~s(<li data-src="#{node.start}-#{node.stop}">), inner, "</li>"], marks}
  end

  defp bare(children, target),
    do: Enum.map(children, fn c -> if c == target, do: %{c | kind: :bare}, else: c end)

  # A table row's pipes are anonymous to the grammar, like a link's
  # brackets, so they never become nodes and would fall through as text.
  # In a row, everything that is not a cell is markup.
  defp node(%{kind: kind} = node, text, marks) when kind in [:table_head, :table_row] do
    cell = if kind == :table_head, do: "th", else: "td"

    cells = Enum.filter(node.children, &(&1.kind == :cell))
    last = List.last(cells)

    {drawn, marks} =
      Enum.map_reduce(cells, marks, fn child, marks ->
        # A mark standing on a pipe belongs to the cell beside it, or it
        # would be consumed with the markup and the caret would vanish. It
        # goes INSIDE a cell that already exists: a cell of its own would
        # change the table, and the page must not change when point moves.
        {ahead, marks} = Enum.split_while(marks, fn {off, _} -> off < child.start end)
        {inner, marks} = children(child, text, marks)

        {tail, marks} =
          if child == last,
            do: Enum.split_while(marks, fn {off, _} -> off < node.stop end),
            else: {[], marks}

        {[
           ~s(<#{cell} data-src="#{child.start}-#{child.stop}">),
           Enum.map(ahead, &elem(&1, 1)),
           inner,
           Enum.map(tail, &elem(&1, 1)),
           "</#{cell}>"
         ], marks}
      end)

    {[~s(<tr data-src="#{node.start}-#{node.stop}">), drawn, "</tr>"],
     drop_marks(node, marks)}
  end

  # A link's brackets and parentheses are anonymous to the grammar, so they
  # never become nodes and would otherwise fall through as text. Draw the
  # label alone, and let the destination become the attribute it always was.
  defp node(%{kind: :link} = node, text, marks) do
    href = child_text(node, text, :link_destination)
    {inner, marks} = label(node, text, marks)
    {[~s(<a href="), escape(href), ~s(" data-src="#{node.start}-#{node.stop}">), inner, "</a>"],
     marks}
  end

  defp node(%{kind: :image} = node, text, marks) do
    src = node |> child_text(text, :link_destination) |> image_src()
    alt = child_text(node, text, :link_text)
    {_inner, marks} = label(node, text, marks)
    {[~s(<img src="), escape(src), ~s(" alt="), escape(alt), ~s(">)], marks}
  end

  defp image_src(src) do
    case Process.get(:aimax_md_image_src) do
      fun when is_function(fun, 1) -> fun.(src)
      _ -> src
    end
  end

  # The label's own text, with every mark that fell anywhere in the link
  # still drawn: point may be standing in the destination, and it has to
  # show somewhere.
  defp label(node, text, marks) do
    case Enum.find(node.children, &(&1.kind == :link_text)) do
      nil ->
        {marks_only(node, marks), drop_marks(node, marks)}

      link_text ->
        {before, marks} = {marks_before(node, link_text, marks), drop_before(node, link_text, marks)}
        {inner, marks} = children(link_text, text, marks)
        {[before, inner, marks_only(node, marks)], drop_marks(node, marks)}
    end
  end

  defp marks_before(node, child, marks),
    do:
      marks
      |> Enum.filter(fn {off, _} -> off >= node.start and off < child.start end)
      |> Enum.map(&elem(&1, 1))

  defp drop_before(node, child, marks),
    do: Enum.reject(marks, fn {off, _} -> off >= node.start and off < child.start end)

  defp node(%{kind: :code} = node, text, marks) do
    lang = child_text(node, text, :info)
    {inner, marks} = children(node, text, marks)
    class = if lang == "", do: "", else: ~s( class="#{escape(lang)}")

    {[~s(<pre data-src="#{node.start}-#{node.stop}"><code#{class}>), inner, "</code></pre>"],
     marks}
  end

  defp node(node, text, marks) do
    case tag(node, text) do
      nil ->
        children(node, text, marks)

      {open, close} ->
        {inner, marks} = children(node, text, marks)
        {[open, inner, close], marks}
    end
  end

  defp children(node, text, marks) do
    {inner, marks} = nodes(node.children, text, node.start, marks, node.kind)

    {tail, marks} =
      if node.kind in @containers,
        do: gap_marks(last_stop(node), node.stop, marks),
        else: slice(text, last_stop(node), node.stop, marks)

    {[inner, tail], marks}
  end

  defp last_stop(%{children: []} = node), do: node.start
  defp last_stop(%{children: kids}), do: kids |> List.last() |> Map.get(:stop)

  defp marks_only(node, marks) do
    marks
    |> Enum.filter(fn {off, _} -> off >= node.start and off < node.stop end)
    |> Enum.map(&elem(&1, 1))
  end

  defp drop_marks(node, marks),
    do: Enum.reject(marks, fn {off, _} -> off >= node.start and off < node.stop end)

  defp child_text(node, text, kind) do
    case Enum.find(node.children, &(&1.kind == kind)) do
      nil -> ""
      child -> binary_part(text, child.start, child.stop - child.start)
    end
  end

  defp tag(%{kind: :heading} = node, _text) do
    level =
      Enum.find_value(node.children, 1, fn child ->
        case Atom.to_string(child.kind) do
          "atx_h" <> <<n, "_marker">> -> n - ?0
          _ -> nil
        end
      end)

    box("h#{level}", node)
  end

  defp tag(%{kind: :paragraph} = node, _), do: box("p", node)
  defp tag(%{kind: :quote} = node, _), do: box("blockquote", node)
  defp tag(%{kind: :item} = node, _), do: box("li", node)
  defp tag(%{kind: :table} = node, _), do: box("table", node)
  defp tag(%{kind: :table_head} = node, _), do: box("tr", node)
  defp tag(%{kind: :table_row} = node, _), do: box("tr", node)
  defp tag(%{kind: :cell} = node, _), do: box("td", node)
  defp tag(%{kind: :strong} = node, _), do: box("strong", node)
  defp tag(%{kind: :emphasis} = node, _), do: box("em", node)
  defp tag(%{kind: :strike} = node, _), do: box("del", node)
  defp tag(%{kind: :code_span} = node, _), do: box("code", node)
  defp tag(%{kind: :rule, start: s, stop: e}, _), do: {~s(<hr data-src="#{s}-#{e}">), ""}
  defp tag(%{kind: :list} = node, _), do: box(list_tag(node), node)
  defp tag(_node, _text), do: nil

  defp list_tag(node) do
    ordered? =
      Enum.any?(node.children, fn item ->
        Enum.any?(item.children, &(&1.kind in [:marker_dot, :marker_paren]))
      end)

    if ordered?, do: "ol", else: "ul"
  end

  # Every element names the source it was built from, so the client can map
  # a click back without searching the page for matching text.
  defp box(name, %{start: s, stop: e}),
    do: {~s(<#{name} data-src="#{s}-#{e}">), "</#{name}>"}

  defp escape(text) do
    escaped =
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    if Process.get(:aimax_md_whitespace) do
      # Every mark is drawn by CSS, not written into the text: the space and
      # the newline stay exactly as the author typed them. A glyph written
      # as text would be counted as source when the page says where a caret
      # landed, and every space would move point along by one.
      # One pass, or the second replacement rewrites the markup the first
      # one just wrote: a "ws nl" span is full of spaces.
      #
      # A mark for EVERY space cost a span per space: 8697 of them in one
      # document, two thirds of the page, redrawn on every keystroke, and
      # the judder was the cost. Emacs does not mark every space either.
      # These are the spaces that carry something a reader cannot otherwise
      # see: a run of two or more, and a space before a line break.
      Regex.replace(~r/\n|\t|  +|[ ](?=\n)|[ ]$/, escaped, fn
        "\n" -> ~s(<span class="ws nl"></span>\n)
        "\t" -> ~s(<span class="ws tab">\t</span>)
        spaces -> ~s(<span class="ws sp">#{spaces}</span>)
      end)
    else
      escaped
    end
  end
end
