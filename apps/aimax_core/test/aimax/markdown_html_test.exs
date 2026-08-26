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
    assert marked =~ ~s(<span class="ws sp"> </span>)
    assert marked =~ ~s(<span class="ws nl"></span>)
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
end
