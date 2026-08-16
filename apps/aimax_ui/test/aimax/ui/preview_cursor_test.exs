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
end
