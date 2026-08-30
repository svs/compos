defmodule Compos.Ui.PreviewEmbedTest do
  use ExUnit.Case, async: true

  alias Compos.Ui.EditorLive
  alias Compos.Ui.Oembed
  alias Compos.Core.Markdown.Html

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

  test "a bare YouTube watch URL renders as a video card" do
    url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=43"
    html = EditorLive.preview_doc("markdown", url <> "\n", 0, @faces, false)

    assert html =~ ~s(class="youtube-card")
    assert html =~ ~s(src="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    assert html =~ ~s(href="#{url}")
  end

  test "YouTube short, live, embed, and share URLs render as video cards" do
    for url <- [
          "https://youtube.com/shorts/dQw4w9WgXcQ",
          "https://youtube.com/live/dQw4w9WgXcQ?feature=share",
          "https://youtube.com/embed/dQw4w9WgXcQ",
          "https://youtu.be/dQw4w9WgXcQ?t=43"
        ] do
      html = EditorLive.preview_doc("markdown", url <> "\n", 0, @faces, false)
      assert html =~ ~s(class="youtube-card")
    end
  end

  test "a written YouTube link stays a link" do
    html =
      EditorLive.preview_doc(
        "markdown",
        "[video](https://youtu.be/dQw4w9WgXcQ)\n",
        0,
        @faces,
        false
      )

    refute html =~ ~s(class="youtube-card")
    assert html =~ ">video</a>"
  end

  test "a malformed YouTube video id stays a link" do
    url = "https://youtu.be/too-short"
    html = EditorLive.preview_doc("markdown", url <> "\n", 0, @faces, false)

    refute html =~ ~s(class="youtube-card")
    assert html =~ ~s(href="#{url}")
  end

  test "the tree-sitter renderer accepts a bare URL card" do
    url = "https://youtu.be/dQw4w9WgXcQ"
    tree = [%{kind: :paragraph, start: 0, stop: byte_size(url), children: []}]

    html = Html.render_tree(tree, url, [], url_embed: fn ^url -> "<youtube-card>" end)

    assert html =~ "<youtube-card>"
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

  test "a share-sheet query string still makes a tweet card" do
    html =
      EditorLive.preview_doc(
        "markdown",
        "https://x.com/paulfinneyx/status/2087738406403215769?s=20\n",
        0,
        @faces,
        false
      )

    assert html =~ ~s(<div class="tweet)
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

  @tweet_json %{
    "text" => "@_svs_ can confirm 🤝 https://t.co/8jmza5XQRS",
    "display_text_range" => [7, 21],
    "created_at" => "2026-08-13T03:09:59.000Z",
    "user" => %{
      "name" => "Paul <Finney>",
      "screen_name" => "paulfinneyx",
      "profile_image_url_https" => "https://pbs.twimg.com/profile_images/x_normal.jpg"
    },
    "mediaDetails" => [
      %{"type" => "photo", "media_url_https" => "https://pbs.twimg.com/media/HPk.jpg"}
    ]
  }

  test "the built card carries the tweet image" do
    html = Oembed.build_card(@tweet_json, "https://x.com/paulfinneyx/status/2087738406403215769")

    assert html =~ ~s(<img class="tw-media" src="https://pbs.twimg.com/media/HPk.jpg")
    assert html =~ "Aug 13, 2026"
  end

  test "the card hides reply mentions and the media link" do
    html = Oembed.build_card(@tweet_json, "https://x.com/p/status/1")

    assert html =~ ~s(<p class="tw-text">can confirm 🤝</p>)
    refute html =~ "t.co"
  end

  test "the card escapes author text" do
    html = Oembed.build_card(@tweet_json, "https://x.com/p/status/1")
    assert html =~ "Paul &lt;Finney&gt;"
  end

  test "the syndication token matches the reference value" do
    assert Oembed.token(2_087_738_406_403_215_769) == "526tnfr7p4fhfer"
  end

  test "the generation counter moves when a result lands" do
    g = Oembed.generation()
    Oembed.put("https://x.com/a/status/#{g + 1}", :error)
    assert Oembed.generation() > g
  end
end
