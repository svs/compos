defmodule Compos.Ui.IslandTest do
  @moduledoc """
  An island draws in the text's place and is one character to the caret:
  the picture for an image URL or a card for a media URL. It says how many
  source bytes it stands for, so the client's byte mapping walks it.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  defp fresh_buffer(name, text) do
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  test "an image URL draws as a picture island", %{conn: conn} do
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", "see https://example.org/p.png here\n")
    # "see " is 4 bytes; the URL is 25
    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((4 29 "img-embed")))})
    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(<img src="https://example.org/p.png" class="img-embed")
    assert html =~ ~s(contenteditable="false" data-len="25")
  end

  test "a relative image path resolves beside the buffer's file", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "island-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    buf = fresh_buffer(Path.join(dir, "doc.md"), "![alt](pic.png)\n")
    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((7 14 "img-embed")))})
    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(<img src="/local-image/)
    assert html =~ ~s(data-len="7")
  end

  test "a bare path with no file beside it stays text", %{conn: conn} do
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", "pic.png\n")
    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((0 7 "img-embed")))})
    {:ok, view, _} = live(conn, "/")
    refute render(view) =~ "<img"
  end

  test "whitespace-mode marks spaces and tabs as faces and flags the surface", %{conn: conn} do
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", "a  b\tc\n")
    {:ok, view, _} = live(conn, "/")
    refute render(view) =~ "f-ws-space"
    Buffer.set_local(buf, "whitespace-mode", true)
    html = render(view)
    assert html =~ ~s(data-ws="true")
    # the test renderer collapses whitespace-only text; the class is the fact
    assert html =~ ~r{<span class="f-ws-space">\s*</span><span class="">b}
    assert html =~ ~r{<span class="f-ws-tab">\s*</span><span class="">c}
    Buffer.set_local(buf, "whitespace-mode", false)
  end

  test "a row face shapes the row", %{conn: conn} do
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", "> said\nplain\n")
    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((0 6 "row-quote")))})
    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(class="line row-quote)
    refute html =~ ~s(class="line row-quote hl-line" data-s="7")
  end

  test "an X post URL draws as a card island, pending until the fetch lands", %{conn: conn} do
    url = "https://x.com/svs/status/1234567890"
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", url <> "\n")
    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((0 #{byte_size(url)} "x-embed")))})
    {:ok, view, _} = live(conn, "/")
    html = render(view)
    assert html =~ ~s(class="x-card" contenteditable="false" data-len="#{byte_size(url)}")
    assert html =~ "x-pending"
  end

  test "a standalone YouTube URL draws as a video card island", %{conn: conn} do
    url = "https://youtu.be/dQw4w9WgXcQ?t=43"
    buf = fresh_buffer("island-#{System.unique_integer([:positive])}", url <> "\n")

    Session.eval(~s{(overlay-set! "#{buf}" 'markdown '((0 #{byte_size(url)} "youtube-embed")))})

    {:ok, view, _} = live(conn, "/")
    html = render(view)

    assert html =~ ~s(class="youtube-card youtube-island")
    assert html =~ ~s(contenteditable="false" data-len="#{byte_size(url)}")
    assert html =~ "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
  end
end
