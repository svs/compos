defmodule Compos.Ui.PreviewCursorTest do
  use ExUnit.Case, async: true

  import Compos.Ui.PreviewMarkup
  alias Compos.Ui.EditorLive

  @faces %{}
  @pt ~s(<span class="pt"></span>)

  defp strip_anchors(html),
    do: String.replace(html, ~r/<span class="ln"[^>]*><\/span>/, "")

  test "the caret is painted, not just present" do
    # It once carried width:0. The span was in the page, in the right place,
    # in the right colour, painting nothing - and every check of visibility
    # and opacity said it was fine.
    css = preview("hi\n", 0)

    assert [rule] = Regex.run(~r/\.pt\{[^}]*\}/, css)
    assert rule =~ ~r/(?:width|border-left):\s*(?!0[;\s}])/, "the caret has no width: #{rule}"
    assert rule =~ ~r/(?:height:\s*(?!0[;\s}])|display:\s*inline)/, "the caret has no height: #{rule}"
  end

  test "the cursor span sits at point in rendered markdown" do
    html = preview("hello world", 5)
    assert html =~ "hello#{@pt} world"
  end

  test "the cursor lands inside a fenced code block" do
    html = preview("```\ncode here\n```\n", 6)
    assert html =~ "co#{@pt}de here"
  end

  test "point at end of buffer still shows a cursor" do
    html = preview("abc", 3)
    assert html =~ @pt
  end

  test "an active region renders point and mark anchors" do
    html = preview("hello world", 2, 8)
    assert html =~ @pt
    assert html =~ ~s(<span class="mk"></span>)
  end

  test "point past end of buffer clamps instead of crashing" do
    html = preview("abc", 99)
    assert html =~ @pt
  end

  test "no sentinel character leaks into the page" do
    html = preview("abc", 1)
    refute html =~ "\uE000"
  end

  test "an html preview gets no cursor injected" do
    html = EditorLive.preview_doc("html", "<p>hi</p>", 2, @faces, false)
    refute html =~ @pt
  end

  test "point at file top keeps the heading a heading" do
    html = preview("# Title\n\nbody\n", 0)
    assert html =~ "<h1>"
    assert html =~ "#{@pt}Title"
  end

  test "a heading after a paragraph renders as a heading" do
    html = preview("body\n\n## Next section\n", 0)

    assert html =~ "<p>"
    assert html =~ "body"
    assert html =~ "<h2>"
    assert html =~ "Next section"
  end

  test "an unmatched inline backtick does not hide later headings" do
    text = "A `broken code span.\n\n## Next section\n"
    html = preview(text, 0)

    assert html =~ "<h2>"
    assert html =~ "Next section"
  end

  test "point inside the heading marker keeps the heading" do
    html = preview("# Title\n", 1)
    assert html =~ "<h1>"
  end

  test "point inside a list marker keeps the list" do
    html = preview("- one\n- two\n", 7)
    assert html =~ "<ul>"
    assert html =~ "#{@pt}two"
  end

  test "point on the opening fence shows the cursor in the code" do
    html = preview("```\ncode\n```\n", 1)
    assert html =~ "<code"
    assert strip_anchors(html) =~ "#{@pt}code"
  end

  test "point on the closing fence shows the cursor at the end of the code block" do
    text = "```\ncode\n```\n"
    at = (:binary.match(text, "```\n", scope: {5, byte_size(text) - 5}) |> elem(0)) + 1
    html = preview(text, at)

    assert html =~ "<code"
    assert strip_anchors(html) =~ "code\n#{@pt}</code>"
  end

  test "a table inside a code fence keeps the cursor where point is" do
    text = "```\n| a | b |\n```\n"
    html = preview(text, 4)

    assert html =~ "#{@pt}| a | b |"
  end

  @table """
  intro

  | keys | command |
  | --- | --- |
  | `a` | `one` |
  | `b` | `two` |
  """

  test "point at the start of a table row keeps every row of the table" do
    start = :binary.match(@table, "| `a`") |> elem(0)
    html = preview(@table, start)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point at the end of a table row keeps the table" do
    stop = (:binary.match(@table, "| `a` | `one` |") |> elem(0)) + byte_size("| `a` | `one` |")
    html = preview(@table, stop)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on the header row keeps the table" do
    for at <- 0..byte_size("| keys | command |") do
      start = (:binary.match(@table, "| keys") |> elem(0)) + at
      html = preview(@table, start)

      assert length(Regex.scan(~r/<tr>/, html)) == 3,
             "point #{at} of the header row broke the table"
    end
  end

  test "point on the alignment row shows the cursor in the first body row" do
    start = :binary.match(@table, "| --- |") |> elem(0)
    html = preview(@table, start + 3)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on the blank line above a table keeps every row of the table" do
    start = (:binary.match(@table, "intro") |> elem(0)) + byte_size("intro") + 1
    html = preview(@table, start)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on a rule line keeps the rule and shows the cursor at it" do
    html = preview("one\n\n---\n\ntwo\n", 6)

    # the dashes are markup: the rule draws them as the line, never as text
    assert strip_anchors(html) =~ "<hr>#{@pt}"
    refute html =~ "---"
  end

  test "point on a Setext underline keeps the heading and shows the cursor in it" do
    html = preview("Title\n=====\n\nbody\n", 8)

    assert strip_anchors(html) =~ ~r/<h1>Title\n#{Regex.escape(@pt)}\n<\/h1>/
  end

  test "point inside a link target shows the cursor at the end of the label" do
    text = "see [the docs](http://example.com/page) here\n"
    at = (:binary.match(text, "http://") |> elem(0)) + 4
    html = preview(text, at)

    assert html =~ ~s(<a href="http://example.com/page")
    assert html =~ "docs#{@pt}"
  end

  test "point inside a character renders the page instead of raising" do
    text = "a \u00b7 b\n"
    html = preview(text, 3)

    assert html =~ @pt
  end

  test "every source line that draws text carries its byte offset" do
    text = "# Title\n\nbody line\n\n| a | b |\n| --- | --- |\n| c | d |\n"
    html = preview(text, 0)

    at = Regex.scan(~r/<span class="ln" data-p="(\d+)"[^>]*><\/span>/, html) |> Enum.map(&List.last/1)

    # every line start, the blank lines and the alignment row included: a
    # key in the page reads the line it moved to from the nearest anchor
    assert at == ["0", "8", "9", "19", "20", "30", "44", "54"]
  end

  test "a rendered line's anchor sits in the line it names" do
    text = "one\n\ntwo\n"
    html = preview(text, 0)

    # the anchor stands at the head of its line, the cursor inside it
    assert html =~ ~r/<span class="ln" data-p="0"[^>]*><\/span><span class="pt"><\/span>one/
    assert html =~ ~r/<span class="ln" data-p="5"[^>]*><\/span>two/
  end

  test "the code block head is chrome, not source" do
    text = "```elixir\ncode\n```\n"
    html = preview(text, 0)

    assert html =~ ~s(data-chrome="1")
  end

  test "Morg header arguments keep a fenced block in the Markdown preview" do
    text = """
    ```scheme :tangle examples/group-noise.scm
    (define (group-noise-next noise)
      noise)
    ```
    """

    html = preview(text, 0)

    assert html =~ ~s(<div class="code-block-head" data-chrome="1">)
    assert html =~ ~r/<span class="code-lang">\s*scheme\s*<\/span>/
    assert html =~ ~r/<kbd>\s*C-c C-c\s*<\/kbd>\s*run/

    assert html =~
             ~r/<kbd>\s*C-c C-x\s*<\/kbd>\s*tangle &rarr; <code>examples\/group-noise.scm<\/code>/

    assert html =~ ~s(<pre><code class="scheme">)
    # every source line carries its anchor, code lines included
    assert strip_anchors(html) =~ "(define (group-noise-next noise)\n  noise)"
    refute html =~ ~s(class="inline")
  end

  test "a result CSV block previews five rows with a header" do
    text = """
    ```result-csv
    name,note
    Ada,"math, engines"
    Grace,compilers
    Margaret,software
    Barbara,hardware
    Carol,networks
    ```
    """

    html = preview(text, 0)
    plain = html |> strip_anchors() |> String.replace(@pt, "")

    assert plain =~ ~s(<table class="csv-preview">)
    assert plain =~ ~r/<th>\s*name\s*<\/th>/
    assert plain =~ ~r/<th>\s*note\s*<\/th>/
    assert plain =~ "math, engines"
    assert plain =~ "Barbara"
    refute plain =~ "Carol"
    refute plain =~ ~s(<pre><code class="csv">)
  end

  test "a result CSV preview line limit is configurable" do
    text = "```result-csv :lines 2\nname,value\none,1\ntwo,2\n```\n"
    body = text |> preview(byte_size(text)) |> blocks()

    assert body =~ "one"
    refute body =~ "two"
  end

  test "a tangled CSV source ignores the preview file reader" do
    text = "```csv :tangle data.csv\nstale_header,value\nstale_row,1\n```\n"

    html =
      EditorLive.preview_doc("markdown", text, 0, nil, @faces, false, [],
        csv_source: fn "data.csv" -> "fresh,value\nfile,2\n" end
      )

    assert html =~ "stale_header"
    assert html =~ "stale_row"
    refute html =~ "fresh"
    refute html =~ ~s(class="csv-preview")
  end

  test "a tangled CSV source remains code when its file is empty" do
    text = "```csv :tangle data.csv\nstale_header,value\nstale_row,1\n```\n"

    html =
      EditorLive.preview_doc("markdown", text, 0, nil, @faces, false, [],
        csv_source: fn "data.csv" -> "" end
      )

    assert html =~ "stale_header"
    assert html =~ "stale_row"
    refute html =~ ~s(class="csv-preview")
  end

  test "a CSV fence without a tangle target remains code" do
    html =
      preview("```csv\nname,value\none,1\n```\n", 0)

    assert html =~ ~s(<pre><code class="csv">)
    refute html =~ ~s(class="csv-preview")
  end

  test "shared Markdown page wraps plain-text fences" do
    text = "```text\n" <> String.duplicate("long prompt text ", 20) <> "\n```\n"
    html = preview(text, 0)

    assert html =~ ~s(<code class="text">)

    assert html =~
             "pre:has(> code.text){white-space:pre-wrap;overflow-wrap:anywhere;overflow-x:hidden}"
  end

  test "a plain fenced block names its language without Morg actions" do
    # json does not run, and the fence names no tangle target
    html = preview("```json\n{}\n```\n", 0)

    assert html =~ ~r/<span class="code-lang">\s*json\s*<\/span>/
    refute html =~ "C-c C-c"
    refute html =~ "C-c C-x"
  end

  test "llm-mode response overlays render as their own formatted blocks" do
    text = "Prompt\n\nAn **answer** here.\nWith another line.\n"
    start = byte_size("Prompt\n\n")
    finish = byte_size(text) - 1

    html =
      preview(text, byte_size("Prompt"), nil, [{start, finish, "llm-response"}])

    assert html =~ ~s(<blockquote class="llm-response")
    assert html =~ ~s(data-start="#{start}")
    assert html =~ ~s(data-end="#{finish}")
    assert html =~ "<strong>answer</strong>"
    assert html =~ "With another line."
    refute html =~ "\uE002"
    refute html =~ "\uE003"
  end

  # RET on a full line leaves point on a blank line. The blank line draws no
  # Markdown node, so the cursor used to move to the next line that draws
  # text: the caret stood in front of another block's words while the typing
  # went to the blank line. Every blank line now draws as a row of its own,
  # and the caret stands in it.

  defp blocks(html) do
    html
    |> String.split("<body>")
    |> List.last()
    |> String.replace(~r/<span class="ln"[^>]*><\/span>/, "")
    |> String.replace("\n", "")
  end

  test "RET between two paragraphs puts the cursor on its own line" do
    html = preview("para1\n\npara2\n", 6)

    assert blocks(html) =~ ~s(<p>para1</p><div class="gap">#{@pt}</div><p>para2</p>)
  end

  test "RET at the end of the document draws a new empty line" do
    html = preview("para1\n", 6)

    # after the last block: the caret opens a line of its own
    assert blocks(html) =~ "<p>para1</p>#{@pt}</body>"
  end

  test "the cursor above a table stays out of the table" do
    text = "intro\n\n| a | b |\n| - | - |\n"
    html = preview(text, 6)

    assert blocks(html) =~ ~s(<p>intro</p><div class="gap">#{@pt}</div><table>)
    refute html =~ ~r/<t[hd][^>]*>\s*#{Regex.escape(@pt)}/
  end

  test "the cursor above a heading stays out of the heading" do
    html = preview("intro\n\n# Head\n", 6)

    assert blocks(html) =~ ~s(<div class="gap">#{@pt}</div><h1>Head</h1>)
  end

  test "a blank line at the top of the document draws the cursor" do
    html = preview("\npara\n", 0)

    assert blocks(html) =~ ~s(<div class="gap">#{@pt}</div><p>para</p>)
  end

  test "one of several blank lines draws the cursor and keeps the rest apart" do
    html = preview("a\n\n\n\nb\n", 3)

    assert blocks(html) =~
             ~s(<p>a</p><div class="gap"></div><div class="bl">#{@pt}</div><div class="bl"></div><p>b</p>)
  end

  test "an empty document draws the cursor" do
    html = preview("", 0)

    assert blocks(html) == "#{@pt}</body></html>"
  end

  test "a blank line inside a fence keeps the cursor in the code" do
    html = preview("```\na\n\nb\n```\n", 6)

    assert html =~ "<pre><code>"
    assert strip_anchors(html) =~ "a\n#{@pt}\nb"
  end

  test "the point's blank line names its own byte offset" do
    html = preview("para1\n\npara2\n", 6)

    assert html =~ ~r/<span class="ln" data-p="6"[^>]*><\/span>#{Regex.escape(@pt)}/
  end

  test "an llm overlay keeps the blank lines it quotes" do
    text = "Prompt\n\nAn answer.\n\nMore answer.\n"
    start = byte_size("Prompt\n\n")
    finish = byte_size(text) - 1
    blank = byte_size("Prompt\n\nAn answer.\n")

    html =
      preview(text, blank, nil, [{start, finish, "llm-response"}])

    assert html =~ ~s(<blockquote class="llm-response")
    assert html =~ "More answer."
    assert html =~ @pt
  end

  test "a fenced block stays where the author put it" do
    text = "# Title\n\nbody one\n\n```text\ncode\n```\n\n## Later\n\nbody two\n"
    html = preview(text, 0)
    seen = strip_anchors(html)

    # the fence used to be rebuilt ahead of the text above it: it landed on
    # the first heading and the whole page rendered as the code it opened
    assert seen =~ "<h1>"
    assert seen =~ "<h2>"
    assert seen =~ "body one"
    assert seen =~ "body two"
    assert seen =~ "<pre><code class=\"text\">code\n</code></pre>"
  end

  test "a document with many fences keeps every block in order" do
    text =
      "one\n\n```a\nA\n```\n\ntwo\n\n```b\nB\n```\n\nthree\n"

    html = preview(text, 0)
    # the body alone: a word in a stylesheet comment is not a block, and
    # searching the whole page once made "two" turn up inside the CSS
    seen = html |> String.split("<body>") |> List.last() |> strip_anchors()

    order = fn needle -> :binary.match(seen, needle) |> elem(0) end

    assert order.("one") < order.("<code class=\"a\">")
    assert order.("<code class=\"a\">") < order.("two")
    assert order.("two") < order.("<code class=\"b\">")
    assert order.("<code class=\"b\">") < order.("three")
  end
end
