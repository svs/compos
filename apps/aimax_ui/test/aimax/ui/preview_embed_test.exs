defmodule Aimax.Ui.PreviewEmbedTest do
  use ExUnit.Case, async: true

  alias Aimax.Ui.EditorLive
  alias Aimax.Ui.Oembed

  @faces %{}
  @pt ~s(<span class="pt"></span>)

  test "a bare image URL renders as an inline image" do
    html =
      EditorLive.preview_doc("markdown", "look:\n\nhttps://pics.example/cat.png\n", 0, @faces, false)

    assert html =~ ~s(<img src="https://pics.example/cat.png")
  end

  test "the image survives a query string" do
    html =
      EditorLive.preview_doc("markdown", "https://pics.example/cat.jpeg?w=800\n", 0, @faces, false)

    assert html =~ ~s(<img src="https://pics.example/cat.jpeg?w=800")
  end

  test "point at the end of a pasted image URL keeps the image and the cursor" do
    text = "https://pics.example/cat.png"
    html = EditorLive.preview_doc("markdown", text, byte_size(text), @faces, false)

    assert html =~ ~s(<img src="https://pics.example/cat.png")
    assert html =~ @pt
  end

  test "a written link stays a link" do
    html =
      EditorLive.preview_doc("markdown", "[cat](https://pics.example/cat.png)\n", 0, @faces, false)

    refute html =~ "<img"
    assert html =~ ~s(<a href="https://pics.example/cat.png">cat</a>)
  end

  test "a non-image URL stays a link" do
    html = EditorLive.preview_doc("markdown", "https://example.com/page\n", 0, @faces, false)

    refute html =~ "<img"
    assert html =~ ~s(<a href="https://example.com/page")
  end

  test "an uncached tweet URL renders a pending card" do
    html =
      EditorLive.preview_doc(
        "markdown",
        "https://x.com/pending_user/status/990\n",
        0,
        @faces,
        false
      )

    assert html =~ "tweet-pending"
    assert html =~ ~s(<a href="https://x.com/pending_user/status/990")
  end

  test "a cached tweet URL renders the card verbatim" do
    url = "https://twitter.com/jack/status/20"
    Oembed.put(url, {:ok, ~s(<blockquote class="twitter-tweet"><p>just setting up</p></blockquote>)})

    html = EditorLive.preview_doc("markdown", url <> "\n", 0, @faces, false)

    assert html =~ ~s(<div class="tweet">)
    assert html =~ "just setting up"
    refute html =~ "&lt;blockquote"
  end

  test "a failed tweet fetch falls back to a link" do
    url = "https://x.com/gone/status/404123"
    Oembed.put(url, :error)

    html = EditorLive.preview_doc("markdown", url <> "\n", 0, @faces, false)

    refute html =~ ~s(<div class="tweet)
    assert html =~ ~s(<a href="#{url}")
  end

  test "the generation counter moves when a result lands" do
    g = Oembed.generation()
    Oembed.put("https://x.com/a/status/#{g + 1}", :error)
    assert Oembed.generation() > g
  end
end
