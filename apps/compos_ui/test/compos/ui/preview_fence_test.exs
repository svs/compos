defmodule Compos.Ui.PreviewFenceTest do
  use ExUnit.Case, async: true

  alias Compos.Ui.EditorLive

  @faces %{}

  test "the text before a fence stays before the fence" do
    text = "# Title\n\nIntro line.\n\n```scheme\n(+ 1 2)\n```\n\nAfter.\n"

    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ "<h1>"
    assert html =~ "Intro line."
    assert [_, body] = String.split(html, "<body>")
    assert String.contains?(body, "Intro line.")
    intro = :binary.match(body, "Intro line.") |> elem(0)
    code = :binary.match(body, "(+ 1 2)") |> elem(0)
    assert intro < code
  end

  test "an unmatched inline backtick does not eat the rest of the page" do
    text = "A `broken span here.\n\nSecond paragraph.\n\n```sh\necho hi\n```\n\nTail.\n"

    html = EditorLive.preview_doc("markdown", text, 0, @faces, false)

    assert html =~ "Second paragraph."
    assert html =~ "Tail."
    assert html =~ "echo hi"
  end
end
