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

  defp render!(text, marks \\ []) do
    {:ok, html} = Html.render(text, marks)
    html
  end

  test "markup is consumed, and what it marked is drawn" do
    assert render!("# Title\n") =~ ~r{<h1 data-src="0-8">Title}
    assert render!("a **bold** b\n") =~ "<strong data-src=\"2-10\">bold</strong>"
    assert render!("a `code` b\n") =~ "<code data-src=\"2-8\">code</code>"
    assert render!("- one\n") =~ ~r{<ul[^>]*><li[^>]*><p[^>]*>one}
  end

  test "a link draws its label and keeps its destination as an attribute" do
    html = render!("see [docs](http://x.com) here\n")

    assert html =~ ~s(<a href="http://x.com")
    assert html =~ ">docs</a>"
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

    assert html =~ "bo#{@pt}ld"
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
    assert html =~ "&lt;script&gt;"
    assert html =~ "&amp;"
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

      assert String.replace(drawn, @pt, "") == base,
             "the page changed with the caret at byte #{point}"

      assert drawn =~ @pt, "the caret vanished at byte #{point}"
    end
  end
end
