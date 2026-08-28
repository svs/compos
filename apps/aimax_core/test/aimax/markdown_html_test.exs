defmodule Aimax.MarkdownHtmlTest do
  @moduledoc """
  Markdown drawn as HTML, with the source range on every element.

  The test that matters most is the last one: the page a reader sees does
  not change when the caret moves. That was the whole bug class - a caret
  put into the source could change how the source parsed, and a table, a
  heading or a whole document would collapse around it.
  """
  use ExUnit.Case, async: true

  @moduletag :markdown_grammar

  alias Aimax.Core.Markdown.Html

  @pt ~s(<span class="pt"></span>)

  # Every run of drawn text is wrapped in a span naming its source byte, and
  # whitespace-mode adds more. None of that is structure: strip the spans and
  # what is left is the blocks and the text.
  defp bare(html), do: String.replace(html, ~r{</?span[^>]*>}, "")

  defp render!(text, marks \\ []) do
    {:ok, html} = Html.render(text, marks)
    html
  end

  test "markup is consumed, and what it marked is drawn" do
    assert bare(render!("# Title\n")) =~ ~r{<h1 data-src="0-8">Title}
    assert bare(render!("a **bold** b\n")) =~ "<strong data-src=\"2-10\">bold</strong>"
    assert bare(render!("a `code` b\n")) =~ "<code data-src=\"2-8\">code</code>"
    assert bare(render!("- one\n")) =~ ~r{<ul[^>]*><li[^>]*>one}
  end

  test "a tight item's text stands beside its bullet" do
    # wrapped in a block-level <p>, every bullet sat alone on a line above
    # its own sentence
    html = render!("- one item\n- two item\n")

    refute html =~ "<p"
    assert bare(html) =~ ~r{<li[^>]*>one item}
  end

  test "a loose item keeps its paragraphs" do
    html = render!("- one\n\n  more of one\n")

    assert html =~ "<p"
  end

  test "a link draws its label and keeps its destination as an attribute" do
    html = render!("see [docs](http://x.com) here\n")

    assert html =~ ~s(<a href="http://x.com")
    assert bare(html) =~ ">docs</a>"
    refute html =~ "[docs]"
    refute html =~ ">http://x.com<"
  end

  test "a heading's level comes from its own marker" do
    assert render!("### Three\n") =~ "<h3"
    assert render!("###### Six\n") =~ "<h6"
  end

  test "an ordered list is an ol and a bulleted one is a ul" do
    assert render!("1. one\n2. two\n") =~ "<ol"
    assert render!("- one\n- two\n") =~ "<ul"
  end

  test "a fence keeps its content and names its language" do
    html = render!("```elixir\n:ok\n```\n")

    assert html =~ ~s(<code class="elixir">)
    assert html =~ ":ok"
    refute html =~ "```"
  end

  test "every element names the source it was built from" do
    html = render!("# Title\n\nbody\n")

    for range <- ~w(0-8 9-14) do
      assert html =~ ~s(data-src="#{range}")
    end
  end

  test "a mark is cut in at its own byte, inside a word" do
    # byte 18 falls between the "o" and the "l" of bold
    html = render!("# Title\n\nbody **bold** here\n", [{18, @pt}])

    assert html =~ ~r{>bo</span>#{Regex.escape(@pt)}<span[^>]*>ld}
  end

  test "a mark inside markup still draws" do
    # point standing on the "#" of a heading has to show somewhere
    assert render!("# Title\n", [{0, @pt}]) =~ @pt
    # ...and so does point inside a link's destination
    assert render!("[a](http://x)\n", [{6, @pt}]) =~ @pt
  end

  test "text is escaped, so a document cannot write the page's markup" do
    html = render!("a <script>x</script> & b\n")

    refute html =~ "<script>"
    assert bare(html) =~ "&lt;script&gt;"
    assert bare(html) =~ "&amp;"
  end

  test "every run of drawn text names the source byte it began at" do
    # This is what makes motion exact. The page used to answer "which line,
    # and how many rendered characters along" - a count wrong by every byte
    # of markup taken out, so `**bold**` threw it off by four and the caret
    # landed somewhere else on every move down.
    text = "a **bold** and [docs](http://x) end\n"
    html = render!(text)

    runs =
      Regex.scan(~r{<span class="s" data-s="(\d+)">([^<]*)</span>}, html)
      |> Enum.map(fn [_, at, body] -> {String.to_integer(at), body} end)

    assert runs != []

    for {at, body} <- runs do
      assert binary_part(text, at, byte_size(body)) == body,
             "a run said byte #{at}, but the source there is not #{inspect(body)}"
    end
  end

  test "whitespace marks add no text, so an offset stays true" do
    text = "one two\nthree\n"
    {:ok, plain} = Html.render(text)
    {:ok, marked} = Html.render(text, [], whitespace: true)

    # the marks are drawn by CSS: the bytes between the tags do not move
    assert bare(marked) == bare(plain)
    assert marked =~ ~s(<span class="ws nl"></span>)
  end

  test "only the spaces a reader cannot otherwise see are marked" do
    # A span per space cost 8697 elements in one document, two thirds of the
    # page, redrawn on every keystroke. A single space between words shows
    # itself; a run of them does not.
    {:ok, single} = Html.render("one two three\n", [], whitespace: true)
    refute single =~ ~s(class="ws sp")

    {:ok, run} = Html.render("one  two\n", [], whitespace: true)
    assert run =~ ~s(<span class="ws sp">  </span>)

    # and the bytes still do not move
    {:ok, plain} = Html.render("one  two\n")
    assert bare(run) == bare(plain)
  end

  test "the page does not change when the caret moves" do
    text = """
    # Title

    body with `code` and **bold** and [a link](http://example.com/x)

    | a | b |
    | --- | --- |
    | 1 | 2 |

    - one
    - two

    ```elixir
    :ok
    ```

    last
    """

    base = render!(text)

    for point <- 0..byte_size(text)//1 do
      drawn = render!(text, [{point, @pt}])

      assert bare(drawn) == bare(base),
             "the page changed with the caret at byte #{point}"

      assert drawn =~ @pt, "the caret vanished at byte #{point}"
    end
  end
  test "a newline inside a paragraph draws as a line break" do
    # the author hard-wraps a paragraph; every line the author typed is a
    # line the reader sees, so the text never reflows away from its source
    html = render!("One line\nsecond line\n")

    assert bare(html) =~ "One line<br>"
    assert bare(html) =~ "second line"
  end

  test "the newline that ends a block draws no break" do
    # a break there opened an empty line under every paragraph
    html = render!("only line\n")

    refute bare(html) =~ ~r{<br>\s*</p>}
  end

  test "one block separator is compact and extra blank lines stay full height" do
    compact = render!("# Head\n\n- item\n")
    spaced = render!("# Head\n\n\n- item\n")

    assert compact =~ ~s(class="gap")
    refute compact =~ ~s(class="bl")
    assert spaced =~ ~s(class="gap")
    assert spaced =~ ~s(class="bl")
  end

  test "point after a trailing blank line stays inside that visible line" do
    text = "body\n\n"
    html = render!(text, [{byte_size(text), @pt}])

    assert html =~ ~r{<div class="gap"[^>]*>.*#{Regex.escape(@pt)}.*</div>}
  end

  test "a fenced code block draws its own lines and gains no break" do
    html = render!("```sh\necho one\necho two\n```\n")

    [_, code] = String.split(html, "<pre")
    refute code =~ "<br>"
    assert bare(code) =~ "echo one"
    assert bare(code) =~ "echo two"
  end

  test "a list item keeps its own line and breaks nowhere" do
    html = render!("- first\n- second\n")

    refute html =~ "<br>"
    assert length(Regex.scan(~r/<li[ >]/, html)) == 2
  end

  test "a fenced block wears a head naming its language" do
    html = render!("```sh\necho hi\n```\n")

    assert html =~ ~s(<div class="code-block">)
    assert html =~ ~s(<span class="code-lang">sh</span>)
    # the head draws no source, so a caret never lands in it
    assert html =~ ~s(data-chrome="1")
  end

  test "the language is the first word of the info string, not the whole of it" do
    # the whole string as a class made ":tangle" and its target classes too
    html = render!("```scheme :tangle out.scm\n(+ 1 2)\n```\n")

    assert html =~ ~s(<code class="scheme">)
    refute html =~ ~s(class="scheme :tangle out.scm")
  end

  test "a block offers every key that acts on it" do
    html = render!("```sh :tangle out.sh\necho hi\n```\n")

    assert html =~ "C-c C-c"
    assert html =~ "C-c C-x"
    assert html =~ "out.sh"
  end

  test "a scheme block offers the run key" do
    # morg-babel evaluates scheme in the editor itself, ahead of the shell
    # runners, so it runs even though it has no runner of its own
    html = render!("```scheme\n(+ 1 1)\n```\n")

    assert html =~ "C-c C-c"
  end

  test "a block tangles even when its language does not run" do
    html = render!("```json :tangle out.json\n{}\n```\n")

    refute html =~ "C-c C-c"
    assert html =~ "C-c C-x"
    assert html =~ "out.json"
  end

  test "a runnable block offers the run key with no argument" do
    # morg-babel runs a block by its language alone
    html = render!("```sh\necho hi\n```\n")

    assert html =~ "C-c C-c"
  end

  test "a language morg cannot run offers no run key" do
    # the head must not name a key that does nothing
    html = render!("```json\n{}\n```\n")

    refute html =~ "C-c C-c"
  end

  test "a block that tangles to no offers no tangle" do
    html = render!("```python :tangle no\nx = 1\n```\n")

    assert html =~ "C-c C-c"
    refute html =~ "C-c C-x"
  end

  test "a block with no language wears no head" do
    html = render!("```\nbare\n```\n")

    refute html =~ "code-block-head"
    assert html =~ "<pre"
  end

  test "a picture says the byte it was drawn from" do
    # without an anchor a move down found no text on the image's row and
    # fell back to a move by source line, which dragged point to the end
    html = render!("![a](/tmp/x.png)\n")

    assert html =~ ~s(data-s="0")
    assert html =~ ~s(<img )
  end

  test "an attribute holds a value, never a break" do
    html = render!("![a](/tmp/x.png)\n")

    refute html =~ ~s(src="<br>)
    refute html =~ ~s(alt="<br>)
  end

end
