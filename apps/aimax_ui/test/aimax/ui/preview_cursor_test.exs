defmodule Aimax.Ui.PreviewCursorTest do
  use ExUnit.Case, async: true

  alias Aimax.Ui.EditorLive

  @faces %{}
  @pt ~s(<span class="pt"></span>)

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

  test "point inside the heading marker snaps past it" do
    html = EditorLive.preview_doc("markdown", "# Title\n", 1, @faces, false)
    assert html =~ "<h1>"
  end

  test "point inside a list marker keeps the list" do
    html = EditorLive.preview_doc("markdown", "- one\n- two\n", 7, @faces, false)
    assert html =~ "<ul>"
    assert html =~ "#{@pt}two"
  end

  test "point on a fence line hides the cursor instead of breaking the fence" do
    html = EditorLive.preview_doc("markdown", "```\ncode\n```\n", 1, @faces, false)
    refute html =~ @pt
    assert html =~ "<code"
  end

  test "Morg header arguments keep a fenced block in the Markdown preview" do
    text = """
    ```scheme :tangle examples/group-noise.scm
    (define (group-noise-next noise)
      noise)
    ```
    """

    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ ~s(<div class="code-block-head">)
    assert html =~ ~r/<span class="code-lang">\s*scheme\s*<\/span>/
    assert html =~ ~r/<kbd>\s*C-c C-c\s*<\/kbd>\s*run/

    assert html =~
             ~r/<kbd>\s*C-c C-x\s*<\/kbd>\s*tangle → <code>examples\/group-noise.scm<\/code>/

    assert html =~ ~s(<pre><code class="scheme">)
    assert html =~ "(define (group-noise-next noise)\n  noise)"
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
end
