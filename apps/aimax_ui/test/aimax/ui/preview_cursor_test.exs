defmodule Aimax.Ui.PreviewCursorTest do
  use ExUnit.Case, async: true

  alias Aimax.Ui.EditorLive

  @faces %{}
  @pt ~s(<span class="pt"></span>)

  defp strip_anchors(html),
    do: String.replace(html, ~r/<span class="ln" data-p="\d+"><\/span>/, "")

  test "the caret is painted, not just present" do
    # It once carried width:0. The span was in the page, in the right place,
    # in the right colour, painting nothing - and every check of visibility
    # and opacity said it was fine.
    css = EditorLive.preview_doc("markdown", "hi\n", 0, @faces, false)

    assert [rule] = Regex.run(~r/\.pt\{[^}]*\}/, css)
    assert rule =~ ~r/width:\s*(?!0[;\s}])/, "the caret has no width: #{rule}"
    assert rule =~ ~r/height:\s*(?!0[;\s}])/, "the caret has no height: #{rule}"
  end

  test "the cursor span sits at point in rendered markdown" do
    html = EditorLive.preview_doc("markdown", "hello world", 5, @faces, false)
    assert html =~ "hello#{@pt} world"
  end

  test "the cursor lands inside a fenced code block" do
    html = EditorLive.preview_doc("markdown", "```\ncode here\n```\n", 6, @faces, false)
    assert html =~ "co#{@pt}de here"
  end

  test "point at end of buffer still shows a cursor" do
    html = EditorLive.preview_doc("markdown", "abc", 3, @faces, false)
    assert html =~ @pt
  end

  test "an active region renders point and mark anchors" do
    html = EditorLive.preview_doc("markdown", "hello world", 2, 8, @faces, false)
    assert html =~ @pt
    assert html =~ ~s(<span class="mk"></span>)
  end

  test "point past end of buffer clamps instead of crashing" do
    html = EditorLive.preview_doc("markdown", "abc", 99, @faces, false)
    assert html =~ @pt
  end

  test "no sentinel character leaks into the page" do
    html = EditorLive.preview_doc("markdown", "abc", 1, @faces, false)
    refute html =~ "\uE000"
  end

  test "an html preview gets no cursor injected" do
    html = EditorLive.preview_doc("html", "<p>hi</p>", 2, @faces, false)
    refute html =~ @pt
  end

  test "point at file top keeps the heading a heading" do
    html = EditorLive.preview_doc("markdown", "# Title\n\nbody\n", 0, @faces, false)
    assert html =~ "<h1>"
    assert html =~ "#{@pt}Title"
  end

  test "a heading after a paragraph renders as a heading" do
    html = EditorLive.preview_doc("markdown", "body\n\n## Next section\n", 0, @faces, false)

    assert html =~ "<p>"
    assert html =~ "body"
    assert html =~ "<h2>"
    assert html =~ "Next section"
  end

  test "an unmatched inline backtick does not hide later headings" do
    text = "A `broken code span.\n\n## Next section\n"
    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ "<h2>"
    assert html =~ "Next section"
  end

  test "point inside the heading marker snaps past it" do
    html = EditorLive.preview_doc("markdown", "# Title\n", 1, @faces, false)
    assert html =~ "<h1>"
  end

  test "point inside a list marker keeps the list" do
    html = EditorLive.preview_doc("markdown", "- one\n- two\n", 7, @faces, false)
    assert html =~ "<ul>"
    assert html =~ "#{@pt}two"
  end

  test "point on the opening fence shows the cursor in the code" do
    html = EditorLive.preview_doc("markdown", "```\ncode\n```\n", 1, @faces, false)
    assert html =~ "<code"
    assert html =~ "#{@pt}code"
  end

  test "point on the closing fence shows the cursor at the end of the code" do
    text = "```\ncode\n```\n"
    at = (:binary.match(text, "```\n", scope: {5, byte_size(text) - 5}) |> elem(0)) + 1
    html = EditorLive.preview_doc("markdown", text, at, @faces, false)

    assert html =~ "<code"
    assert html =~ "code#{@pt}"
  end

  test "a table inside a code fence keeps the cursor where point is" do
    text = "```\n| a | b |\n```\n"
    html = EditorLive.preview_doc("markdown", text, 4, @faces, false)

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
    html = EditorLive.preview_doc("markdown", @table, start, @faces, false)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point at the end of a table row keeps the table" do
    stop = (:binary.match(@table, "| `a` | `one` |") |> elem(0)) + byte_size("| `a` | `one` |")
    html = EditorLive.preview_doc("markdown", @table, stop, @faces, false)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on the header row keeps the table" do
    for at <- 0..byte_size("| keys | command |") do
      start = (:binary.match(@table, "| keys") |> elem(0)) + at
      html = EditorLive.preview_doc("markdown", @table, start, @faces, false)

      assert length(Regex.scan(~r/<tr>/, html)) == 3, "point #{at} of the header row broke the table"
    end
  end

  test "point on the alignment row shows the cursor in the first body row" do
    start = :binary.match(@table, "| --- |") |> elem(0)
    html = EditorLive.preview_doc("markdown", @table, start + 3, @faces, false)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on the blank line above a table keeps every row of the table" do
    start = (:binary.match(@table, "intro") |> elem(0)) + byte_size("intro") + 1
    html = EditorLive.preview_doc("markdown", @table, start, @faces, false)

    assert length(Regex.scan(~r/<tr>/, html)) == 3
    assert html =~ @pt
  end

  test "point on a rule line keeps the rule and shows the cursor below it" do
    html = EditorLive.preview_doc("markdown", "one\n\n---\n\ntwo\n", 6, @faces, false)

    assert html =~ "<hr"
    assert html =~ "#{@pt}two"
  end

  test "point on a Setext underline keeps the heading and shows the cursor in it" do
    html = EditorLive.preview_doc("markdown", "Title\n=====\n\nbody\n", 8, @faces, false)

    assert html =~ "<h1>"
    assert html =~ "Title#{@pt}"
  end

  test "point inside a link target shows the cursor at the end of the label" do
    text = "see [the docs](http://example.com/page) here\n"
    at = (:binary.match(text, "http://") |> elem(0)) + 4
    html = EditorLive.preview_doc("markdown", text, at, @faces, false)

    assert html =~ ~s(<a href="http://example.com/page")
    assert html =~ "docs#{@pt}"
  end

  test "point inside a character renders the page instead of raising" do
    text = "a \u00b7 b\n"
    html = EditorLive.preview_doc("markdown", text, 3, @faces, false)

    assert html =~ @pt
  end

  test "every source line that draws text carries its byte offset" do
    text = "# Title\n\nbody line\n\n| a | b |\n| --- | --- |\n| c | d |\n"
    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    at = Regex.scan(~r/<span class="ln" data-p="(\d+)"><\/span>/, html) |> Enum.map(&List.last/1)

    # the heading (past its marker), the body line, the header row, and the
    # body row — the blank lines and the alignment row draw nothing, so they
    # name nothing
    assert at == ["2", "9", "22", "46"]
  end

  test "a rendered line's anchor sits in the line it names" do
    text = "one\n\ntwo\n"
    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    # the anchor stands at the head of its line, the cursor inside it
    assert html =~ ~s(<span class="ln" data-p="0"></span><span class="pt"></span>one)
    assert html =~ ~s(<span class="ln" data-p="5"></span>two)
  end

  test "the code block head is chrome, not source" do
    text = "```elixir\ncode\n```\n"
    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ ~s(data-chrome="1")
  end

  test "Morg header arguments keep a fenced block in the Markdown preview" do
    text = """
    ```scheme :tangle examples/group-noise.scm
    (define (group-noise-next noise)
      noise)
    ```
    """

    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ ~s(<div class="code-block-head" data-chrome="1">)
    assert html =~ ~r/<span class="code-lang">\s*scheme\s*<\/span>/
    assert html =~ ~r/<kbd>\s*C-c C-c\s*<\/kbd>\s*run/

    assert html =~
             ~r/<kbd>\s*C-c C-x\s*<\/kbd>\s*tangle → <code>examples\/group-noise.scm<\/code>/

    assert html =~ ~s(<pre><code class="scheme">)
    # every source line carries its anchor, code lines included
    assert strip_anchors(html) =~ "(define (group-noise-next noise)\n  noise)"
    refute html =~ ~s(class="inline")
  end

  test "a plain fenced block names its language without Morg actions" do
    html = EditorLive.preview_doc("markdown", "```elixir\n:ok\n```\n", 0, @faces, false)

    assert html =~ ~r/<span class="code-lang">\s*elixir\s*<\/span>/
    refute html =~ "C-c C-c"
    refute html =~ "C-c C-x"
  end

  test "llm-mode response overlays render as their own formatted blocks" do
    text = "Prompt\n\nAn **answer** here.\nWith another line.\n"
    start = byte_size("Prompt\n\n")
    finish = byte_size(text) - 1

    html =
      EditorLive.preview_doc(
        "markdown",
        text,
        byte_size("Prompt"),
        nil,
        @faces,
        false,
        [{start, finish, "llm-response"}]
      )

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
  # went to the blank line. The blank line the point stands on now draws an
  # empty paragraph of its own.

  defp blocks(html) do
    html
    |> String.split("<body>")
    |> List.last()
    |> String.replace(~r/<span class="ln" data-p="\d+"><\/span>/, "")
    |> String.replace("\n", "")
  end

  test "RET between two paragraphs puts the cursor on its own line" do
    html = EditorLive.preview_doc("markdown", "para1\n\npara2\n", 6, @faces, false)

    assert blocks(html) =~ "<p>para1</p><p>#{@pt}</p><p>para2</p>"
  end

  test "RET at the end of the document draws a new empty line" do
    html = EditorLive.preview_doc("markdown", "para1\n", 6, @faces, false)

    assert blocks(html) =~ "<p>para1</p><p>#{@pt}</p>"
  end

  test "the cursor above a table stays out of the table" do
    text = "intro\n\n| a | b |\n| - | - |\n"
    html = EditorLive.preview_doc("markdown", text, 6, @faces, false)

    assert blocks(html) =~ "<p>intro</p><p>#{@pt}</p><table>"
    refute html =~ ~r/<t[hd][^>]*>\s*#{Regex.escape(@pt)}/
  end

  test "the cursor above a heading stays out of the heading" do
    html = EditorLive.preview_doc("markdown", "intro\n\n# Head\n", 6, @faces, false)

    assert blocks(html) =~ "<p>#{@pt}</p><h1>Head</h1>"
  end

  test "a blank line at the top of the document draws the cursor" do
    html = EditorLive.preview_doc("markdown", "\npara\n", 0, @faces, false)

    assert blocks(html) =~ "<p>#{@pt}</p><p>para</p>"
  end

  test "one of several blank lines draws the cursor and keeps the rest apart" do
    html = EditorLive.preview_doc("markdown", "a\n\n\n\nb\n", 3, @faces, false)

    assert blocks(html) =~ "<p>a</p><p>#{@pt}</p><p>b</p>"
  end

  test "an empty document draws the cursor" do
    html = EditorLive.preview_doc("markdown", "", 0, @faces, false)

    assert blocks(html) =~ "<p>#{@pt}</p>"
  end

  test "a blank line inside a fence keeps the cursor in the code" do
    html = EditorLive.preview_doc("markdown", "```\na\n\nb\n```\n", 6, @faces, false)

    assert html =~ "<pre><code>"
    assert strip_anchors(html) =~ "a\n#{@pt}\nb"
  end

  test "the point's blank line names its own byte offset" do
    html = EditorLive.preview_doc("markdown", "para1\n\npara2\n", 6, @faces, false)

    assert html =~ ~s(<span class="ln" data-p="6"></span>#{@pt})
  end

  test "a blank line the point has left names nothing" do
    html = EditorLive.preview_doc("markdown", "para1\n\npara2\n", 8, @faces, false)

    at = Regex.scan(~r/<span class="ln" data-p="(\d+)"><\/span>/, html) |> Enum.map(&List.last/1)

    assert at == ["0", "7"]
  end

  test "an llm overlay keeps the blank lines it quotes" do
    text = "Prompt\n\nAn answer.\n\nMore answer.\n"
    start = byte_size("Prompt\n\n")
    finish = byte_size(text) - 1
    blank = byte_size("Prompt\n\nAn answer.\n")

    html =
      EditorLive.preview_doc(
        "markdown",
        text,
        blank,
        nil,
        @faces,
        false,
        [{start, finish, "llm-response"}]
      )

    assert html =~ ~s(<blockquote class="llm-response")
    assert html =~ "More answer."
    assert html =~ @pt
  end

  test "a fenced block stays where the author put it" do
    text = "# Title\n\nbody one\n\n```text\ncode\n```\n\n## Later\n\nbody two\n"
    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)
    seen = strip_anchors(html)

    # the fence used to be rebuilt ahead of the text above it: it landed on
    # the first heading and the whole page rendered as the code it opened
    assert seen =~ "<h1>"
    assert seen =~ "<h2>"
    assert seen =~ "body one"
    assert seen =~ "body two"
    assert seen =~ "<pre><code class=\"text\">code</code></pre>"
  end

  test "a document with many fences keeps every block in order" do
    text =
      "one\n\n```a\nA\n```\n\ntwo\n\n```b\nB\n```\n\nthree\n"

    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)
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
