defmodule Compos.Core.Markdown.Html do
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

  alias Compos.Core.{Markdown, TS}
  alias Compos.Scheme.Text

  @csv_preview_lines 5

  # llm-mode answer overlays ride the parse as private-use sentinels
  @llm_start "\uE002"
  @llm_end "\uE003"
  @llm_meta_end "\uE004"

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
    Process.put(:compos_md_whitespace, opts[:whitespace] == true)
    # An image's source is a path in the document and a URL on the page, and
    # only the caller knows how one becomes the other. A pasted image is an
    # absolute path, which a browser will not load: without this it drew
    # nothing.
    Process.put(:compos_md_image_src, opts[:image_src])
    Process.put(:compos_md_url_embed, opts[:url_embed])
    Process.put(:compos_md_tweet_card, opts[:tweet_card])
    Process.put(:compos_md_csv_source, opts[:csv_source])
    Process.put(:compos_md_hidden_lines, opts[:hidden_lines] || MapSet.new())
    # A transcript wants CommonMark reflow: a newline inside a paragraph
    # folds into a space. The editable page wants the line the author
    # typed. The caller says which page this is.
    Process.put(:compos_md_nobreak, opts[:soft_breaks] == true)
    # The code-block head (language, run and tangle keys) is chrome for a
    # document the reader edits. A read-only page can decline it.
    Process.put(:compos_md_chrome, opts[:chrome] != false)

    marks = Enum.sort_by(marks, &elem(&1, 0))
    {iodata, marks} = tree |> autolinks(text) |> nodes(text, 0, marks)

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
  @containers ~w(root answer list item quote table table_head table_row code)a

  # CommonMark: a backslash before ASCII punctuation escapes it
  @backslash_escape ~r/\\[!-\/:-@\[-`{-~]/

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
            # An llm-mode answer is a document inside the document, and its
            # blank lines are the answer's own.
            parent in [:root, :answer] -> blank_lines(text, at, node.start, marks)
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

  # A backslash escape draws the character it escapes: pandoc writes a
  # literal | as \|. The backslash is markup, so the run splits around it
  # and each part still names its own source byte. Code is verbatim.
  defp run(text, from, to) do
    escapes =
      if Process.get(:compos_md_verbatim),
        do: [],
        else: Regex.scan(@backslash_escape, binary_part(text, from, to - from), return: :index)

    {parts, cursor} =
      Enum.map_reduce(escapes, from, fn [{at, _}], cursor ->
        {span(text, cursor, from + at), from + at + 1}
      end)

    [parts, span(text, cursor, to)]
  end

  defp span(_text, from, to) when from >= to, do: []

  defp span(text, from, to),
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

  # A rule's dashes are markup: the rule draws as the line, and a caret on
  # it still shows.
  defp node(%{kind: :rule} = node, _text, marks),
    do:
      {[~s(<hr data-src="#{node.start}-#{node.stop}">), marks_only(node, marks)],
       drop_marks(node, marks)}

  # A Setext heading holds its text as a paragraph. The text is the
  # heading's own, so it draws bare, as an ATX heading's does.
  defp node(%{kind: :heading, children: kids} = node, text, marks) when kids != [] do
    kids = Enum.map(kids, &if(&1.kind == :paragraph, do: %{&1 | kind: :bare}, else: &1))
    generic_node(%{node | children: kids}, text, marks)
  end

  # An llm-mode answer: the quote the overlay wrote into the parse. It says
  # which bytes of the buffer are the answer, and draws them as a block.
  defp node(%{kind: :quote, llm: {start, finish}} = node, text, marks) do
    {inner, marks} = children(%{node | kind: :answer}, text, marks)

    {[
       ~s(<blockquote class="llm-response" data-start="#{start}" data-end="#{finish}" ),
       ~s(data-src="#{node.start}-#{node.stop}">),
       inner,
       "</blockquote>"
     ], marks}
  end

  # A URL in running text is a link to itself, as it is on every page that
  # reads GitHub Markdown.
  defp node(%{kind: :bare_url} = node, text, marks) do
    url = binary_part(text, node.start, node.stop - node.start)
    {inner, marks} = children(node, text, marks)

    {[~s(<a href="), attr(url), ~s(" data-src="#{node.start}-#{node.stop}">), inner, "</a>"],
     marks}
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

    {[~s(<tr data-src="#{node.start}-#{node.stop}">), drawn, "</tr>"], drop_marks(node, marks)}
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
    case Process.get(:compos_md_image_src) do
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
        {before, marks} =
          {marks_before(node, link_text, marks), drop_before(node, link_text, marks)}

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

    {content, marks} =
      cond do
        String.downcase(lang) == "result-csv" ->
          csv_preview(node, text, marks, csv_preview_lines(args), nil)

        folded_code?(node, text) ->
          {marks_only(node, marks), drop_marks(node, marks)}

        true ->
          # <pre> draws a newline as a line already. A break added inside one
          # would draw the same newline twice and open the block by a line for
          # every line it holds.
          marks = code_marks(node, text, lang, marks)
          {inner, marks} = verbatim(fn -> without_breaks(fn -> children(node, text, marks) end) end)
          class = if lang == "", do: "", else: ~s( class="#{attr(lang)}")

          {[
             ~s(<pre data-src="#{node.start}-#{node.stop}"><code#{class}>),
             inner,
             "</code></pre>"
           ], marks}
      end

    {[~s(<div class="code-block">), code_head(lang, args), content, "</div>"], marks}
  end

  # A caller can upgrade one complete paragraph. The core renderer keeps
  # directive policy outside this module and keeps source marks.
  defp node(%{kind: :paragraph} = node, text, marks) do
    source = binary_part(text, node.start, node.stop - node.start)
    url = String.trim(source)

    embedded =
      case Process.get(:compos_md_url_embed) do
        fun when is_function(fun, 1) -> fun.(url)
        _ -> nil
      end

    cond do
      is_binary(embedded) ->
        {here, marks} = Enum.split_while(marks, fn {off, _} -> off < node.stop end)
        {[embedded, Enum.map(here, &elem(&1, 1))], marks}

      url = lone_url(node, text) ->
        url_paragraph(node, url, text, marks)

      figure = figure_parts(node, text) ->
        figure(node, figure, text, marks)

      true ->
        generic_node(node, text, marks)
    end
  end

  # A paragraph that is one URL and nothing else: the author pasted it to
  # show the thing it names. A picture draws as the picture and an X post as
  # its card. Any other URL is a link.
  defp lone_url(
         %{children: [%{kind: :inline, children: [%{kind: :bare_url} = link]} = inline]},
         text
       ) do
    url = binary_part(text, link.start, link.stop - link.start)
    whole = String.trim(binary_part(text, inline.start, inline.stop - inline.start))
    if whole == url and (image_url?(url) or tweet_url?(url)), do: {url, link}
  end

  defp lone_url(_node, _text), do: nil

  defp url_paragraph(node, {url, link}, text, marks) do
    if image_url?(url) do
      {open, close} = box("p", node)

      {[
         open,
         ~s(<img src="),
         attr(image_src(url)),
         ~s(" alt="" data-src="#{link.start}-#{link.stop}" data-s="#{link.start}">),
         marks_only(node, marks),
         close
       ], drop_marks(node, marks)}
    else
      tweet_paragraph(node, url, text, marks)
    end
  end

  # The card is the caller's: only the client can fetch it. Until it lands
  # the page says so, and a post that cannot be fetched stays a link.
  defp tweet_paragraph(node, url, text, marks) do
    card = Process.get(:compos_md_tweet_card) || fn _ -> :error end
    src = ~s(data-src="#{node.start}-#{node.stop}")

    body =
      case card.(url) do
        # verbatim: the card builder escapes the author's text, and the
        # preview frame runs no scripts
        {:ok, html} ->
          [~s(<div class="tweet" #{src}>), html, "</div>"]

        :pending ->
          [
            ~s(<div class="tweet tweet-pending" #{src}>Loading the post: <a href="),
            attr(url),
            ~s(">),
            escape(url),
            "</a></div>"
          ]

        _ ->
          nil
      end

    if body,
      do: {[body, marks_only(node, marks)], drop_marks(node, marks)},
      else: generic_node(node, text, marks)
  end

  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .avif .bmp)
  # the share sheet appends ?s=20 and friends; a query or fragment after
  # the status id still names the same post
  @tweet_re ~r{\Ahttps?://(?:mobile\.)?(?:twitter|x)\.com/[^/]+/status(?:es)?/\d+(?:[?#]\S*)?\z}

  defp image_url?(url) do
    case URI.parse(url) do
      %URI{scheme: s, path: p} when s in ["http", "https"] and is_binary(p) ->
        (p |> Path.extname() |> String.downcase()) in @image_exts

      _ ->
        false
    end
  end

  defp tweet_url?(url), do: Regex.match?(@tweet_re, url)

  # A bare URL is a node the inline grammar does not make, so the walk adds
  # it: a `bare_url` over the bytes of each URL that stands in the text
  # between the grammar's own nodes. A link, an image or a code span is
  # text of another kind, and nothing inside one is read.
  @url_holders ~w(inline cell emphasis strong strike)a
  @url_opaque ~w(link image code_span autolink code)a

  defp autolinks(nodes, text), do: Enum.map(nodes, &autolink(&1, text))

  defp autolink(%{kind: kind} = node, _text) when kind in @url_opaque, do: node

  defp autolink(%{kind: kind} = node, text) when kind in @url_holders do
    kids = autolinks(node.children, text)

    urls =
      [node.start | Enum.flat_map(kids, &[&1.start, &1.stop])]
      |> Enum.concat([node.stop])
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn [from, to] -> urls_in(text, from, to) end)

    %{node | children: Enum.sort_by(kids ++ urls, & &1.start)}
  end

  defp autolink(node, text), do: %{node | children: autolinks(node.children, text)}

  defp urls_in(text, from, to) when to > from do
    case :binary.match(text, "http", scope: {from, to - from}) do
      :nomatch ->
        []

      _ ->
        ~r{https?://[^\s<>]+}
        |> Regex.scan(binary_part(text, from, to - from), return: :index)
        |> Enum.map(fn [{at, len}] ->
          url = url_end(binary_part(text, from + at, len))
          %{kind: :bare_url, start: from + at, stop: from + at + byte_size(url), children: []}
        end)
    end
  end

  defp urls_in(_text, _from, _to), do: []

  # Punctuation that closes the sentence is not part of the URL. A closing
  # parenthesis is part of it only when the URL opened one.
  defp url_end(url) do
    url = String.replace(url, ~r/[.,;:!?'"*_~]+\z/, "")
    opens = length(:binary.matches(url, "("))

    if String.ends_with?(url, ")") and length(:binary.matches(url, ")")) > opens,
      do: url |> String.slice(0..-2//1) |> url_end(),
      else: url
  end

  # An image on a line of its own, and under it a line that is only
  # emphasis, is a picture with a caption:
  #
  #     ![alt](picture.png)
  #     *The caption.*
  #
  # Markdown has no caption syntax of its own, and this is the shape most
  # renderers agree on. The page draws it as a figure with a figcaption.
  # Anything else in the paragraph - text before the picture, a second
  # line after the caption - keeps the paragraph as it is.
  defp figure_parts(%{children: [%{kind: :inline} = inline]}, text) do
    case inline.children do
      # text before the picture or after the caption is a gap, not a
      # child: the picture must open the line and the caption close it
      [%{kind: :image} = image, %{kind: :emphasis} = caption]
      when image.start == inline.start and caption.stop == inline.stop ->
        if binary_part(text, image.stop, caption.start - image.stop) == "\n",
          do: {image, caption},
          else: nil

      _ ->
        nil
    end
  end

  defp figure_parts(_node, _text), do: nil

  defp figure(node, {image, caption}, text, marks) do
    {open, close} = box("figure", node)
    {picture, marks} = node(image, text, marks)
    # the newline between them is a byte a caret can stand on, drawn
    # without a break: the caption stands under the picture already
    {gap, marks} = without_breaks(fn -> slice(text, image.stop, caption.start, marks) end)
    {caption_open, caption_close} = box("figcaption", caption)
    {words, marks} = children(caption, text, marks)
    {tail, marks} = block_tail(text, caption.stop, node.stop, marks)
    {[open, picture, gap, caption_open, words, caption_close, tail, close], marks}
  end

  # A fence whose language has a grammar draws its code in the theme's
  # f-ts-* faces. The spans go in as marks, so the caret, the line anchors
  # and the byte offsets of the source stay exact. A result block reads as
  # the language that made it. An unknown language stays plain.
  defp code_marks(node, text, lang, marks) do
    with lang when is_binary(lang) <- highlight_lang(lang),
         %{} = child <- Enum.find(node.children, &(&1.kind == :code_text)) do
      body = binary_part(text, child.start, child.stop - child.start)
      sort_marks(marks ++ syntax_marks(lang, body, child.start))
    else
      _ -> marks
    end
  end

  # {offset, html} marks that open and close one f-ts-* span per capture of
  # TEXT, shifted by BASE. The grammar can name one node twice; the later
  # name wins, as it does in the editor.
  defp syntax_marks(lang, text, base) do
    lang
    |> TS.ts_highlight(text)
    |> Enum.reverse()
    |> Enum.uniq_by(fn {start, stop, _} -> {start, stop} end)
    |> Enum.sort_by(fn {start, stop, _} -> {start, -stop} end)
    |> Enum.flat_map(fn {start, stop, scope} ->
      class = "f-ts-" <> attr(scope)
      [{base + start, ~s(<span class="#{class}">)}, {base + stop, "</span>"}]
    end)
  end

  # a close before an open at the same byte, so spans nest
  defp sort_marks(marks) do
    Enum.sort_by(marks, fn {at, html} ->
      {at, if(String.starts_with?(html, "</"), do: 0, else: 1)}
    end)
  end

  @doc """
  TEXT as escaped HTML, with the f-ts-* spans of LANG's grammar. A
  language with no grammar gives the escaped text alone.
  """
  def highlight(lang, text) do
    {html, at} =
      lang
      |> syntax_marks(text, 0)
      |> sort_marks()
      |> Enum.reduce({[], 0}, fn {pos, mark}, {acc, at} ->
        {[mark, html_escape(binary_part(text, at, pos - at)) | acc], pos}
      end)

    [html_escape(binary_part(text, at, byte_size(text) - at)) | html]
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp highlight_lang(lang) do
    lang = lang |> String.downcase() |> String.replace_prefix("result-", "")
    if lang != "" and lang in TS.ts_langs(), do: lang
  end

  defp folded_code?(node, text) do
    hidden = Process.get(:compos_md_hidden_lines, MapSet.new())

    case Enum.find(node.children, &(&1.kind == :code_text)) do
      nil ->
        false

      child ->
        first = Compos.Core.Text.line_index(text, child.start)
        last = Compos.Core.Text.line_index(text, max(child.stop - 1, child.start))
        Enum.any?(first..last, &MapSet.member?(hidden, &1))
    end
  end

  defp csv_preview(node, text, marks, limit, target) do
    rows = csv_source_rows(node, text, target) |> Enum.take(limit)

    case rows do
      [] ->
        {marks_only(node, marks), drop_marks(node, marks)}

      [headers | body] ->
        {head, marks} = csv_html_row(headers, marks, "th")

        {body, marks} =
          Enum.map_reduce(body, marks, fn row, marks -> csv_html_row(row, marks, "td") end)

        tail = marks_only(node, marks)

        {[
           ~s(<table class="csv-preview" data-src="#{node.start}-#{node.stop}"><thead>),
           head,
           "</thead><tbody>",
           body,
           "</tbody></table>",
           tail
         ], drop_marks(node, marks)}
    end
  end

  defp csv_source_rows(node, text, target) do
    first =
      case :binary.match(text, "\n", scope: {node.start, node.stop - node.start}) do
        {at, _} -> at + 1
        :nomatch -> node.stop
      end

    last =
      node.children
      |> Enum.filter(&(&1.kind == :fence))
      |> List.last()
      |> then(&if(&1, do: &1.start, else: node.stop))

    external = if target, do: csv_external_source(target), else: nil

    cond do
      is_binary(external) ->
        external
        |> csv_lines()
        |> Enum.map(&{&1, first, node.stop})

      first >= last ->
        []

      true ->
        text
        |> binary_part(first, last - first)
        |> :binary.split("\n", [:global])
        |> Enum.map_reduce(first, fn line, at ->
          line = String.trim_trailing(line, "\r")
          {{csv_row(line), at, at + byte_size(line) + 1}, at + byte_size(line) + 1}
        end)
        |> elem(0)
        |> Enum.reject(fn {fields, _start, _stop} -> fields == [""] end)
    end
  end

  defp csv_lines(text) do
    text
    |> :binary.split("\n", [:global])
    |> Enum.map(&(&1 |> String.trim_trailing("\r") |> csv_row()))
    |> Enum.reject(&(&1 == [""]))
  end

  defp csv_external_source(target) do
    case Process.get(:compos_md_csv_source) do
      fun when is_function(fun, 1) -> fun.(target)
      _ -> nil
    end
  end

  defp csv_html_row({fields, start, stop}, marks, cell) do
    {here, marks} = Enum.split_while(marks, fn {off, _} -> off < stop end)

    cells =
      fields
      |> Enum.with_index()
      |> Enum.map(fn {field, index} ->
        row_marks = if index == 0, do: Enum.map(here, &elem(&1, 1)), else: []
        [~s(<#{cell} data-s="#{start}">), row_marks, escape(field), "</#{cell}>"]
      end)

    {[~s(<tr data-src="#{start}-#{stop}">), cells, "</tr>"], marks}
  end

  defp csv_preview_lines(args) do
    case Regex.run(~r/:(?:lines|preview)[ \t]+([0-9]+)/i, args, capture: :all_but_first) do
      [count] ->
        case Integer.parse(count) do
          {value, ""} when value > 0 -> value
          _ -> @csv_preview_lines
        end

      _ ->
        @csv_preview_lines
    end
  end

  defp csv_row(line), do: csv_row(line, "", [], false)
  defp csv_row(<<>>, field, fields, _quoted), do: Enum.reverse([field | fields])

  defp csv_row(<<?", ?", rest::binary>>, field, fields, true),
    do: csv_row(rest, field <> "\"", fields, true)

  defp csv_row(<<?", rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field, fields, not quoted)

  defp csv_row(<<?,, rest::binary>>, field, fields, false),
    do: csv_row(rest, "", [field | fields], false)

  defp csv_row(<<char::utf8, rest::binary>>, field, fields, quoted),
    do: csv_row(rest, field <> <<char::utf8>>, fields, quoted)

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
    if Process.get(:compos_md_chrome, true),
      do: code_head_chrome(lang, args),
      else: []
  end

  defp code_head_chrome(lang, args) do
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

  # The languages that run: the fence-kind registry decides, and pushes the
  # list through `preview-run-langs!` on every registration. An empty term
  # means no registry has spoken, and no block offers a dead key.
  defp run_action(lang) do
    if String.downcase(lang) in :persistent_term.get({__MODULE__, :run_langs}, []) do
      ~s(<span class="code-action"><kbd>C-c C-c</kbd> run</span>)
    else
      []
    end
  end

  defp tangle_action(args) do
    case tangle_target(args) do
      nil ->
        []

      target ->
        [
          ~s(<span class="code-action"><kbd>C-c C-x</kbd> tangle &rarr; <code>),
          escape(target),
          "</code></span>"
        ]
    end
  end

  defp tangle_target(args) do
    case Regex.run(~r/:tangle[ \t]+([^ \t]+)/i, args, capture: :all_but_first) do
      [target] -> if(String.downcase(target) == "no", do: nil, else: target)
      _ -> nil
    end
  end

  defp node(%{kind: :code_span} = node, text, marks),
    do: verbatim(fn -> generic_node(node, text, marks) end)

  defp node(node, text, marks), do: generic_node(node, text, marks)

  defp generic_node(node, text, marks) do
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
      if Process.get(:compos_md_whitespace) do
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

    if Process.get(:compos_md_nobreak), do: marked, else: break_lines(marked)
  end

  # A newline the author typed inside a paragraph is a line the reader has
  # to see. HTML folds it into a space, so the paragraph reflowed and every
  # line moved away from the source that drew it. The break is an element,
  # never text, so the page still reports the same byte for a caret.
  defp break_lines(html), do: String.replace(html, "\n", "<br>\n")

  # While the flag stands, a newline draws as itself and not as a break.
  # The old value is put back, so one code block does not silence the
  # breaks of the document below it.
  # Code: a backslash there is the author's, not an escape.
  defp verbatim(fun) do
    was = Process.get(:compos_md_verbatim)
    Process.put(:compos_md_verbatim, true)

    try do
      fun.()
    after
      Process.put(:compos_md_verbatim, was)
    end
  end

  defp without_breaks(fun) do
    was = Process.get(:compos_md_nobreak)
    Process.put(:compos_md_nobreak, true)

    try do
      fun.()
    after
      Process.put(:compos_md_nobreak, was)
    end
  end

  # --- the document ----------------------------------------------------------

  @doc """
  The whole preview page for the Markdown TEXT, with the caret at POINT
  and the mark at MARK. This module owns it: the LiveView only frames it.

  OPTS: `tree` (the answer of `parse/2` for TEXT and the overlays, which
  the caller caches against the buffer version), `overlays`, and the
  hooks `image_src`, `url_embed`, `csv_source`, `local_url`, `tweet_card`,
  `base_dir`, `whitespace`, `hidden_lines`. The Markdown grammars are
  built into the NIF; a parse that still fails draws the escaped source.
  """
  def document(text, point, mark, faces, opts \\ []) do
    overlays = opts[:overlays] || []

    tree =
      case opts[:tree] do
        nil ->
          case parse(text, overlays) do
            {:ok, tree} -> tree
            {:error, _} -> nil
          end

        tree ->
          tree
      end

    if tree do
      {:ok, html} =
        preview_doc_ts(tree, text, point, mark, faces,
          whitespace: opts[:whitespace] == true,
          hidden_lines: opts[:hidden_lines] || MapSet.new(),
          image_src: opts[:image_src] || (&local_image_src(&1, opts)),
          url_embed: opts[:url_embed] || (&youtube_embed_html/1),
          tweet_card: opts[:tweet_card],
          csv_source: opts[:csv_source]
        )

      html
    else
      # the Markdown grammars are built into the NIF, so a parse fails only
      # on input the grammar rejects: draw the source, escaped
      page(~s(<pre class="preview-raw">) <> html_escape(text) <> "</pre>", faces)
    end
  end

  @doc """
  A chat paragraph: CommonMark reflow and no block chrome. One bad block
  must not kill the transcript that holds it, so a failure draws the text.
  OPTS takes the image hooks of `document/5`: `local_url` turns an
  absolute image path into a URL the page can load.
  """
  def prose(md, opts \\ []) do
    case render(md, [], soft_breaks: true, chrome: false, image_src: &local_image_src(&1, opts)) do
      {:ok, html} ->
        html

      {:error, _} ->
        "<pre>" <> html_escape(md) <> "</pre>"
    end
  rescue
    _ -> "<pre>" <> html_escape(md) <> "</pre>"
  end

  @doc """
  Render a Markdown preview through the tree-sitter renderer.

  Every node knows the source it came from, so the caret is cut in at its
  byte rather than placed by a rule about the construct it landed in.
  TREE is the answer of `parse/2`.
  """
  def preview_doc_ts(tree, text, point, mark, faces, opts \\ []) do
    size = byte_size(text)
    p = point |> max(0) |> min(size)
    m = if is_integer(mark), do: mark |> max(0) |> min(size), else: nil

    marks =
      ts_line_marks(text) ++
        [{p, ~s(<span class="pt"></span>)}] ++
        if(m, do: [{m, ~s(<span class="mk"></span>)}], else: [])

    body = render_tree(tree, text, marks, opts)

    {:ok, page(body, faces)}
  end

  defp ts_line_marks(text) do
    [0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)]
    |> Enum.reject(&(&1 > byte_size(text)))
    |> Enum.map(fn at -> {at, ~s(<span class="ln" data-p="#{at}"></span>)} end)
  end

  @doc """
  Parse TEXT with its llm-mode OVERLAYS. Every node in the answer speaks
  TEXT's own byte offsets.

  An answer is parsed as a quote, so the grammar still reads the headings,
  lists and emphasis inside it. The quote markers and the sentinels are
  written into a copy of TEXT for the parse, and the walk then maps every
  node back: a node the insertion made draws nothing, and the quote that
  carries the start sentinel records the answer's range as `llm`.
  """
  def parse(text, overlays \\ []) do
    inserts =
      text
      |> overlay_positions(overlays)
      |> Enum.map(fn {at, s} -> {Text.floor_utf8(text, at), s} end)
      |> Enum.sort_by(&elem(&1, 0))

    if inserts == [] do
      Markdown.parse(text)
    else
      source = inserts |> Enum.reverse() |> Enum.reduce(text, &insert_at/2)

      with {:ok, tree} <- Markdown.parse(source) do
        {spans, _} =
          Enum.map_reduce(inserts, 0, fn {at, s}, shift ->
            {{at + shift, at + shift + byte_size(s), at}, shift + byte_size(s)}
          end)

        {:ok, unshift(tree, source, spans)}
      end
    end
  end

  defp insert_at({at, s}, acc),
    do: binary_part(acc, 0, at) <> s <> binary_part(acc, at, byte_size(acc) - at)

  defp unshift(nodes, source, spans) do
    Enum.flat_map(nodes, fn node ->
      start = to_text(node.start, spans)
      stop = to_text(node.stop, spans)

      if start == stop and node.kind in @silent do
        []
      else
        mapped = %{
          node
          | start: start,
            stop: stop,
            children: unshift(node.children, source, spans)
        }

        case node.kind == :quote and answer_range(source, node.start) do
          {from, to} -> [Map.put(mapped, :llm, {from, to})]
          _ -> [mapped]
        end
      end
    end)
  end

  # An offset in the parsed copy, as an offset in the buffer text. An
  # offset inside an insertion is the byte the insertion stands before.
  defp to_text(at, spans) do
    Enum.reduce_while(spans, at, fn {from, to, orig}, _ ->
      cond do
        at < from -> {:halt, at - (from - orig)}
        at < to -> {:halt, orig}
        true -> {:cont, at - (to - orig)}
      end
    end)
  end

  # The quote the overlay wrote opens with the start sentinel and the
  # answer's range: "> " START ":" FINISH META_END.
  defp answer_range(source, at) do
    head = binary_part(source, at, min(64, byte_size(source) - at))

    case Regex.run(~r/\A> #{@llm_start}(\d+):(\d+)#{@llm_meta_end}/u, head,
           capture: :all_but_first
         ) do
      [from, to] -> {String.to_integer(from), String.to_integer(to)}
      _ -> nil
    end
  end

  # A font face belongs to one document. The preview runs in its own
  # about:blank frame, so the root layout's link does not reach it: the
  # frame rendered Georgia and Menlo while the chrome rendered Spectral
  # and IBM Plex Mono. The frame must ask for the fonts itself.
  @preview_fonts """
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Spectral:ital,wght@0,400;0,500;0,600;0,700;1,400&family=IBM+Plex+Mono:wght@400;500;600&display=swap">
  """

  @doc """
  The page around a rendered BODY: the reader's typography and palette,
  from FACES. The page carries no logic of the renderer; the body is all
  of the renderer's work.
  """
  def page(body, faces) do
    %{bg: bg, fg: fg, accent: accent, link: link, dim: dim, border: border, inset: inset} =
      palette(faces)

    # typography is policy: the 'preview face carries it (appearance.scm
    # defcustoms; themes and init.scm may set it like any face)
    family = face(faces, "preview", "family", "Spectral,Georgia,serif")
    # an empty preview size means the default face's size, as in a buffer
    size =
      case face(faces, "preview", "size", "") do
        "" -> face(faces, "default", "size", "18.7px")
        s -> s
      end

    # the measure is the readability lever. 44em of Spectral ran to 94
    # characters a line; prose reads fastest between 65 and 75.
    measure = face(faces, "preview", "measure", "33em")

    """
    <!DOCTYPE html><html><head><meta charset="utf-8">#{@preview_fonts}<style>
    body{margin:0 auto;padding:30px 34px 70px;max-width:#{measure};overflow-wrap:break-word;
         word-break:normal;font:#{size}/1.7 #{family};color:#{fg};background:#{bg};
         -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    /* The renderer draws block gaps. CSS margins would count them twice. */
    p{margin:0}
    /* a heading must separate the sections, so its space above is much
       larger than the space below it */
    h1,h2,h3,h4{font-family:#{family};line-height:1.2;font-weight:700;letter-spacing:-0.012em}
    /* every size on the page is an em of the body, so the page keeps its
       proportions at any default face size */
    h1{font-size:1.82em;margin:0}
    /* one scale, no rules: a section heading is bigger and sits higher
       above its text than a paragraph; the renderer's gap does the rest */
    h2{font-size:1.39em;margin:0;padding-top:.45em}
    h3{font-size:1.12em;margin:0;padding-top:.3em;color:#{accent}}
    h4{font-size:.76em;margin:0;padding-top:.2em;color:#{dim};font-weight:600;
       text-transform:uppercase;letter-spacing:.06em}
    /* the browser default indents a list 40px and puts no space between
       the items: a list of requirements then reads as one block */
    ul,ol{margin:0;padding-left:1.35em}
    li{margin:0}
    li>ul,li>ol{margin:0}
    li::marker{color:#{dim}}
    code,pre{font-family:"IBM Plex Mono",ui-monospace,Menlo,monospace;font-size:.82em}
    code{background:#{inset};padding:1px 4px;border-radius:2px}
    /* a name in a heading is still the heading: the code span must not
       shrink it to body size, nor box it */
    h1 code,h2 code,h3 code,h4 code{background:none;padding:0;font-size:.92em}
    pre{background:#{inset};padding:10px 12px;border-left:3px solid #{accent};overflow-x:auto}
    pre code{background:none;padding:0}
    /* Plain-text blocks are prose-like payloads such as prompts and logs.
       Wrap them to the page measure; source-code fences keep horizontal scroll. */
    pre:has(> code.text){white-space:pre-wrap;overflow-wrap:anywhere;overflow-x:hidden}
    .code-block{margin:0;border:1px solid #{border};border-radius:6px;overflow:hidden;background:#{inset}}
    .code-block-head{display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:6px 10px;
      border-bottom:1px solid #{border};color:#{dim};font:.73em/1.4 "IBM Plex Mono",ui-monospace,Menlo,monospace}
    .code-lang{margin-right:auto;color:#{accent};font-weight:700;text-transform:uppercase;letter-spacing:.06em}
    .code-action{white-space:nowrap}
    .code-action kbd{padding:1px 4px;border:1px solid #{border};border-radius:3px;color:#{fg};background:#{bg}}
    .code-action code{padding:0;color:#{fg};background:none}
    .code-block pre{margin:0;border:0;border-radius:0}
    a,a:visited{color:#{link};text-decoration-thickness:1px;text-underline-offset:2px;
      text-decoration-color:color-mix(in srgb,currentColor 45%,transparent)}
    a:hover{text-decoration-color:currentColor}
    a:empty{display:none}
    blockquote{margin:0;padding:2px 14px;border-left:3px solid #{border};color:#{dim}}
    blockquote.llm-response{margin:18px 0;padding:12px 16px;border:1px solid #{border};
         border-left:4px solid #{accent};border-radius:7px;background:#{inset};color:#{fg};user-select:text}
    blockquote.llm-response>:first-child{margin-top:0}
    blockquote.llm-response>:last-child{margin-bottom:0}
    table{border-collapse:collapse;font-size:.85em;display:block;overflow-x:auto;
          max-width:100%;margin:0}
    /* rules between rows, none around them: a reference table reads as
       columns, not as a grid of boxes */
    th,td{border:0;border-bottom:1px solid #{border};padding:6px 14px 6px 0;
          vertical-align:top}
    th{background:none;text-align:left;color:#{dim};font:600 .79em/1.7 "IBM Plex Mono",ui-monospace,Menlo,monospace;
       letter-spacing:.09em;text-transform:uppercase}
    tr:last-child td{border-bottom:0}
    img{max-width:100%;height:auto;border-radius:3px}
    figure{margin:1.4em 0}
    figure img{display:block;margin:0 auto}
    figcaption{margin-top:.55em;text-align:center;font-size:.9em;font-style:italic;color:var(--dim-fg,#8a857a)}
    hr{border:0;border-top:1px solid #{border};margin:0}
    .tweet{margin:12px 0;padding:12px 16px;border:1px solid #{border};border-radius:10px;
           max-width:32em;background:#{inset};font-size:.88em}
    .tweet blockquote{margin:0;padding:0;border:0;color:#{fg}}
    .tweet blockquote p{margin:0 0 8px}
    .tweet-pending{color:#{dim}}
    .tw-head{display:flex;align-items:center;gap:10px;margin-bottom:8px}
    .tw-avatar{width:38px;height:38px;border-radius:50%}
    .tw-name{font-weight:600;display:block;line-height:1.2}
    .tw-handle{color:#{dim};text-decoration:none;font-size:.9em}
    .tw-text{margin:0 0 10px}
    .tweet .tw-media{width:100%;border-radius:8px;margin:2px 0 8px}
    .tw-date{color:#{dim};font-size:.9em;text-decoration:none}
    .youtube-card{position:relative;display:block;max-width:40em;margin:12px 0;
      color:white;text-decoration:none;border-radius:8px;overflow:hidden;background:#111}
    .youtube-card img{display:block;width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:0}
    .youtube-play{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);
      display:grid;place-items:center;width:64px;height:44px;border-radius:12px;
      background:#f00;color:white;font:24px/1 sans-serif;box-shadow:0 2px 10px #0008}
    ::highlight(region){background:color-mix(in srgb,#{accent} 32%,transparent)}
    /* The caret is an inline box with a painted left border and no content,
       so it is invisible to line breaking: an inline-block is an atomic
       inline, and the browser may wrap at it, even inside a word, and then
       measure rows the caret itself moved. The negative margin keeps the
       border from pushing the text along. */
    .pt{display:inline;border-left:2px solid #{accent};margin:0 -1px;
        animation:ptb var(--chrome-anim, 0s) step-end infinite}
    /* a zero-width character gives the caret a line box of its own after a
       trailing break: RET at the end of a paragraph shows the new line */
    .pt::after{content:"\\200B"}
    /* The window does not own the keyboard, so the caret stops blinking.
       It still draws: a reader who looks at the page from another window
       must still see where point stands. Emacs draws a hollow box here. */
    .pt.idle{animation:none;opacity:0.45}
    /* whitespace-mode: the newline the author typed, drawn where it is.
       Muted enough to read past, present enough to aim at. */
    /* A blank line the author typed is one line tall, always: a separator
       that grew when point reached it moved every line below it. The
       source shows one blank line between paragraphs, and so does the page. */
    .gap{height:1.7em}
    .bl{height:1.7em}
    /* whitespace-mode. Every mark is a pseudo-element painted over the
       character the author typed, so the text keeps its own bytes and the
       page does not reflow when the marks come on. */
    .ws{position:relative}
    .ws.nl::before{content:"¶";color:#{dim};opacity:.5;font-size:.85em}
    /* a run of spaces, marked along its whole width rather than one span
       per space: the dots repeat, the text keeps its own bytes */
    .ws.sp{background-image:radial-gradient(circle,#{dim} 0.9px,transparent 1px);
           background-size:.32em 100%;background-position:center;
           background-repeat:repeat-x;opacity:.55}
    .ws.tab::before{content:"»";position:absolute;left:0;color:#{dim};opacity:.45;
                    pointer-events:none}
    .mk{display:inline-block;width:0;height:0}
    .ln{display:inline-block;width:0;height:0}
    @keyframes ptb{0%,49%{opacity:1}50%,100%{opacity:0}}
    #{ts_css(faces)}
    </style></head><body>#{body}</body></html>
    """
  end

  @doc """
  An HTML document themed by FACES the way Emacs shr does. AUTHORED true
  draws the document exactly as written.
  """
  def html_document(text, _faces, true), do: text

  # shr-style theming (Emacs eww): authored LAYOUT and typography survive,
  # authored COLORS don't — half-themed documents (authored light panel,
  # themed light text) are unreadable, so colors are all-or-nothing
  def html_document(text, faces, _authored) do
    p = palette(faces)

    style = """
    <style>
    body{background:#{p.bg} !important;color:#{p.fg} !important}
    *,*::before,*::after{background-color:transparent !important;color:inherit !important;border-color:#{p.border} !important}
    a,a:visited{color:#{p.link} !important}
    code,pre,kbd{background-color:#{p.inset} !important}
    blockquote{color:#{p.dim} !important}
    th{background-color:#{p.inset} !important}
    ::highlight(region){background-color:color-mix(in srgb,#{p.link} 32%,transparent) !important}
    </style>
    """

    case String.split(text, ~r{</body>}i, parts: 2) do
      [before, rest] -> before <> style <> "</body>" <> rest
      [_] -> text <> style
    end
  end

  # The page is a sandboxed frame: the editor's stylesheet does not reach
  # it, so the code spans get their ts-* face colours here. A value that
  # names a CSS variable of the editor cannot resolve in the frame.
  defp ts_css(faces) when is_map(faces) do
    for {"ts-" <> _ = name, attrs} when is_map(attrs) <- faces,
        rules = ts_rules(attrs),
        rules != "",
        into: "",
        do: ".f-#{name}{#{rules}}"
  end

  defp ts_css(_faces), do: ""

  defp ts_rules(attrs) do
    [{"fg", "color"}, {"weight", "font-weight"}, {"style", "font-style"}]
    |> Enum.flat_map(fn {key, prop} ->
      case attrs[key] do
        v when is_binary(v) and v != "" ->
          if String.contains?(v, "var(") or String.contains?(v, ";"),
            do: [],
            else: ["#{prop}:#{v}"]

        _ ->
          []
      end
    end)
    |> Enum.join(";")
  end

  defp face(faces, name, attr, fallback),
    do: get_in(faces, [name, attr]) || fallback

  @doc "The page colours, read from FACES, with the paper theme as the default."
  def palette(faces) do
    %{
      bg: face(faces, "window", "bg", "#fdfcf8"),
      fg: face(faces, "default", "fg", "#1b1a17"),
      accent: face(faces, "accent", "fg", "#26356b"),
      link: face(faces, "link", "fg", face(faces, "accent", "fg", "#26356b")),
      dim: face(faces, "dim", "fg", "#8a857a"),
      border: face(faces, "border", "bg", "#cbc4b1"),
      inset: face(faces, "window-inactive", "bg", "#f4f0e6")
    }
  end

  # --- overlays, local images, and embeds -------------------------------------
  # Preview formatting belongs to llm-mode, not to the Markdown document.
  # An llm-mode answer is written into the source as a quote, so the parser
  # still reads headings, lists and emphasis inside it. The private
  # sentinels tell it apart from a quote the author typed.
  def overlay_positions(text, overlays) do
    Enum.flat_map(overlays || [], fn
      {start, finish, face}
      when is_integer(start) and is_integer(finish) and face in ["llm-response", :llm_response] ->
        start = start |> max(0) |> min(byte_size(text))
        finish = finish |> max(start) |> min(byte_size(text))

        continuation_prefixes =
          text
          |> binary_part(start, finish - start)
          |> :binary.matches("\n")
          |> Enum.map(fn {offset, _length} -> start + offset + 1 end)
          # a newline that ends the answer ends the quote: the line after
          # it is the author's again
          |> Enum.filter(&(&1 < finish))
          |> Enum.map(&{&1, "> "})

        metadata = "#{start}:#{finish}"

        [
          {start, "> " <> @llm_start <> metadata <> @llm_meta_end},
          {finish, @llm_end} | continuation_prefixes
        ]

      _ ->
        []
    end)
  end

  # A document's picture is a file path: absolute, or relative to the document
  # itself. A relative link is the one that survives another checkout, so the
  # preview resolves it against the document's directory. A URL is left alone.
  def local_image_src(src, ctx) do
    dir = ctx[:base_dir]
    local_url = ctx[:local_url] || (&Function.identity/1)

    path =
      if String.starts_with?(src, "<") and String.ends_with?(src, ">") do
        binary_part(src, 1, byte_size(src) - 2)
      else
        src
      end

    cond do
      Path.type(path) == :absolute -> local_url.(path)
      not is_nil(URI.parse(path).scheme) -> src
      is_binary(dir) -> local_url.(Path.expand(path, dir))
      true -> src
    end
  end

  defp embed_directive_url(text) do
    case Regex.run(~r/\A#\+embed:[ \t]+(\S+)[ \t]*\z/i, text, capture: :all_but_first) do
      [url] -> url
      _ -> nil
    end
  end

  @doc false
  def youtube_id(url) do
    uri = URI.parse(url)
    host = uri.host && String.downcase(uri.host)
    path = String.split(uri.path || "", "/", trim: true)

    id =
      cond do
        host in ["youtu.be", "www.youtu.be"] ->
          List.first(path)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and path == ["watch"] ->
          youtube_query_id(uri.query)

        host in ["youtube.com", "www.youtube.com", "m.youtube.com"] and
            List.first(path) in ["shorts", "live", "embed"] ->
          Enum.at(path, 1)

        true ->
          nil
      end

    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{11}\z/, id), do: id
  end

  defp youtube_query_id(nil), do: nil

  defp youtube_query_id(query) do
    URI.decode_query(query)["v"]
  rescue
    ArgumentError -> nil
  end

  @doc "A YouTube URL, or an `#+embed:` line naming one, drawn as a card; nil otherwise."
  def youtube_embed_html(source) do
    url = embed_directive_url(source) || String.trim(source)

    case url && youtube_id(url) do
      nil ->
        nil

      id ->
        safe_url = url |> html_escape() |> String.replace("\"", "&quot;")

        ~s(<a class="youtube-card" href="#{safe_url}" target="_blank" rel="noopener noreferrer" aria-label="Watch this video on YouTube"><img src="#{youtube_thumbnail(id)}" alt="YouTube video thumbnail"><span class="youtube-play" aria-hidden="true">▶</span></a>)
    end
  end

  @doc false
  def youtube_thumbnail(id), do: "https://i.ytimg.com/vi/#{id}/hqdefault.jpg"

  @doc false
  def html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
