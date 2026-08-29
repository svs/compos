defmodule Compos.Ui.PreviewNewlineTest do
  use ExUnit.Case, async: true

  alias Compos.Ui.EditorLive

  @faces %{}

  defp body(text), do: EditorLive.preview_doc("markdown", text, 0, @faces, false)

  test "a newline inside a paragraph draws as a line break" do
    html = body("One line\nsecond line\n")

    assert html =~ "<br>"
    assert html =~ "One line"
    assert html =~ "second line"
  end

  test "every newline of a hard-wrapped paragraph draws" do
    html = body("alpha\nbeta\ngamma\ndelta\n")

    # three newlines join four lines, so the paragraph carries three breaks
    assert length(String.split(html, "<br>")) - 1 == 3
  end

  test "a blank line still separates two paragraphs" do
    html = body("first para\n\nsecond para\n")

    assert length(Regex.scan(~r/<p[ >]/, html)) == 2
  end

  test "a fenced code block keeps its own lines and gains no breaks" do
    html = body("text above\n\n```sh\necho one\necho two\n```\n")

    [_, code] = String.split(html, "<pre")
    refute code =~ "<br>"
    assert code =~ "echo one"
    assert code =~ "echo two"
  end

  test "a list keeps one item per line without breaking inside the item" do
    html = body("- first item\n- second item\n")

    assert length(Regex.scan(~r/<li[ >]/, html)) == 2
  end
end
