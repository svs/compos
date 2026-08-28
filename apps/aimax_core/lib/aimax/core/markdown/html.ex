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

  # The first blank line between blocks is Markdown structure, so it draws a
  # compact gap. Each additional blank line is content and keeps full height.
  # A gap expands while point stands there, so RET always has a visible line.
  defp blank_lines(text, at, stop, marks) when at < stop do
    gap = binary_part(text, at, stop - at)

    {lines, marks} =
      :binary.matches(gap, "\n")
      |> Enum.map(fn {i, _} -> at + i end)
      |> Enum.with_index()
      |> Enum.map_reduce(marks, fn {pos, index}, marks ->
        {here, rest} = Enum.split_while(marks, fn {off, _} -> off <= pos end)

        class = if index == 0, do: "gap", else: "bl"

        {[~s(<div class="#{class}" data-s="#{pos}">), Enum.map(here, &elem(&1, 1)), "</div>"],
         rest}
      end)

    # At the end of the document, point after the final newline belongs to
    # that line. Put its mark inside the line, where it has visible height.
    terminal? = stop == byte_size(text)

    {tail, marks} =
      Enum.split_while(marks, fn {off, _} -> off < stop or (terminal? and off == stop) end)

    lines =
      case {lines, tail} do
        {[], _} ->
          lines

        {_, []} ->
          lines

        {lines, tail} ->
          List.update_at(lines, -1, fn line ->
            [
              String.replace_suffix(IO.iodata_to_binary(line), "</div>", ""),
              Enum.map(tail, &elem(&1, 1)),
              "</div>"
            ]
          end)
      end

    {lines, marks}
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

  # The picture says the byte it was drawn from, like every other element.
  # Without it the page had a row the source did not own: a move down landed
  # on the image, found no text to measure, and fell back to a move by
  # source line, which dragged point to the end of the `![alt](url)` line.
  defp node(%{kind: :image} = node, text, marks) do
    src = node |> child_text(text, :link_destination) |> image_src()
    alt = child_text(node, text, :link_text)
    {_inner, marks} = label(node, text, marks)

    {[
       ~s(<img data-src="#{node.start}-#{node.stop}" data-s="#{node.start}" src="),
       attr(src),
       ~s(" alt="),
       attr(alt),
       ~s(">)
     ], marks}
  end

  # An attribute holds a value, never markup: a break drawn into one would
  # be read as part of the value.
  defp attr(text), do: without_breaks(fn -> escape(text) end)

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
    # The fence names the language, and a Morg fence adds arguments after
    # it. Only the first word is the language: the whole info string as a
    # class made ":tangle" and its target into classes of their own.
    {lang, args} = fence_info(child_text(node, text, :info))

    # <pre> draws a newline as a line already. A break added inside one
    # would draw the same newline twice and open the block by a line for
    # every line it holds.
    {inner, marks} = without_breaks(fn -> children(node, text, marks) end)
    class = if lang == "", do: "", else: ~s( class="#{attr(lang)}")

    pre = [~s(<pre data-src="#{node.start}-#{node.stop}"><code#{class}>), inner, "</code></pre>"]

    {[~s(<div class="code-block">), code_head(lang, args), pre, "</div>"], marks}
  end

  # The language is the first word of the info string; the rest are the
  # block's arguments.
  defp fence_info(info) do
    case String.split(String.trim(info), ~r/\s+/, parts: 2) do
      [""] -> {"", ""}
      [lang] -> {lang, ""}
      [lang, args] -> {lang, args}
    end
  end

  # The head names the language and the keys that act on the block. It
  # draws no source, so it is marked as chrome and carries no byte a caret
  # can land on.
  defp code_head("", _args), do: []

  defp code_head(lang, args) do
    [
      ~s(<div class="code-block-head" data-chrome="1">),
      ~s(<span class="code-lang">),
      escape(lang),
      "</span>",
      code_actions(lang, args),
      "</div>"
    ]
  end

  # morg-babel runs a block by its language alone, so the key is offered by
  # language alone. It asks for no argument, and a block that carries none
  # still runs.
  defp code_actions(lang, args), do: [run_action(lang), tangle_action(args)]

  # The languages morg-babel runs: scheme, which it evaluates in the editor
  # itself, and every language `*morg-babel-runners*` gives a shell runner.
  # This repeats morg/morg-babel.scm, which is the one that decides. Keep
  # the two the same, or the head offers a key that does nothing.
  @runnable ~w(scheme sh bash zsh shell python py elixir exs js javascript node ruby)

  defp run_action(lang) do
    if String.downcase(lang) in @runnable do
      ~s(<span class="code-action"><kbd>C-c C-c</kbd> run</span>)
    else
      []
    end
  end

  defp tangle_action(args) do
    case Regex.run(~r/:tangle[ \t]+([^ \t]+)/i, args, capture: :all_but_first) do
      [target] ->
        if String.downcase(target) == "no" do
          []
        else
          [
            ~s(<span class="code-action"><kbd>C-c C-x</kbd> tangle &rarr; <code>),
            escape(target),
            "</code></span>"
          ]
        end

      _ ->
        []
    end
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
        else: block_tail(text, last_stop(node), node.stop, marks)

    {[inner, tail], marks}
  end

  # The newline that ends a block is the end of the block, not a line inside
  # it. Drawn as a break it opened an empty line under every paragraph and
  # every list item. The byte is still drawn, so a caret can stand on it.
  defp block_tail(text, from, stop, marks) do
    if stop > from and binary_part(text, stop - 1, 1) == "\n" do
      {head, marks} = slice(text, from, stop - 1, marks)
      {last, marks} = without_breaks(fn -> slice(text, stop - 1, stop, marks) end)
      {[head, last], marks}
    else
      slice(text, from, stop, marks)
    end
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

    marked =
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

    if Process.get(:aimax_md_nobreak), do: marked, else: break_lines(marked)
  end

  # A newline the author typed inside a paragraph is a line the reader has
  # to see. HTML folds it into a space, so the paragraph reflowed and every
  # line moved away from the source that drew it. The break is an element,
  # never text, so the page still reports the same byte for a caret.
  defp break_lines(html), do: String.replace(html, "\n", "<br>\n")

  # While the flag stands, a newline draws as itself and not as a break.
  # The old value is put back, so one code block does not silence the
  # breaks of the document below it.
  defp without_breaks(fun) do
    was = Process.get(:aimax_md_nobreak)
    Process.put(:aimax_md_nobreak, true)

    try do
      fun.()
    after
      Process.put(:aimax_md_nobreak, was)
    end
  end
end
