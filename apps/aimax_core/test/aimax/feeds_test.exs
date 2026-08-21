defmodule Aimax.FeedsTest do
  @moduledoc """
  packages/feeds.scm — RSS/Atom subscriptions as a list buffer. The
  fetch and discover seams are replaced; items sort newest first, RET
  reads one in the browse reader and marks it read, subscribe finds a
  page's feed link, and feed.xsl turns real feed XML into item lines.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case fun.() do
        false ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("condition not met within #{timeout_ms}ms")
          end

          Process.sleep(25)
          false

        value ->
          value
      end
    end)
    |> Enum.find(& &1)
  end

  setup do
    eval!(~S"""
    (begin
      (write-file! *feeds-file* "https://site.test/feed.xml\n")
      (write-file! *feeds-read-file* "")
      (set! *feeds--read* #f)
      (set! *feeds-fetch*
        (lambda (urls k)
          (k (feeds--parse-lines (string-append
               "Ars\tTue, 19 Aug 2026 10:00:05 GMT\thttps://site.test/a\tAlpha article\n"
               "Blog\t2026-08-20T09:30:00Z\thttps://site.test/b\tBeta post\n"
               "Blog\t\thttps://site.test/c\tUndated post\n")))))
      (set! *web-fetch*
        (lambda (url k) (k "# An article\n\nbody text\n"))))
    """)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      {:ok, _} =
        Session.eval(~S{(begin
          (for-each (lambda (b)
                      (when (or (equal? b "*feeds*")
                                (equal? (buffer-local b 'mode-name) "browse-mode"))
                        (buffer-kill! b)))
                    (buffer-list))
          (write-file! *feeds-file* "")
          (write-file! *feeds-read-file* "")
          (write-file! *web-visited-file* "")
          (set! *feeds--read* #f)
          #t)})

      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    :ok
  end

  defp show_feeds! do
    eval!(~S{(list-mode-show! "feeds-mode")})
    wait_until(fn -> Buffer.text("*feeds*") =~ "Beta post" end, 2_000)
  end

  test "feed dates, both readings, become one sortable key" do
    assert eval!(~S{(feeds--date-key "Tue, 19 Aug 2026 10:00:05 GMT")}) ==
             ~S["20260819100005"]

    assert eval!(~S{(feeds--date-key "19 Aug 2026 10:00 +0200")}) ==
             ~S["20260819100000"]

    assert eval!(~S{(feeds--date-key "2026-08-20T09:30:00Z")}) ==
             ~S["20260820093000"]

    assert eval!(~S{(feeds--date-key "2026-08-20")}) == ~S["20260820000000"]
    assert eval!(~S{(feeds--date-key "not a date")}) == ~S["00000000000000"]
    assert eval!(~S{(feeds--date-label "20260820093000")}) == ~S["2026-08-20"]
  end

  test "items render newest first with normalized dates" do
    show_feeds!()
    text = Buffer.text("*feeds*")

    beta = :binary.match(text, "Beta post") |> elem(0)
    alpha = :binary.match(text, "Alpha article") |> elem(0)
    undated = :binary.match(text, "Undated post") |> elem(0)

    assert beta < alpha, "the newer item must come first"
    assert alpha < undated, "an undated item sorts last"
    assert text =~ "2026-08-20"
    assert text =~ "2026-08-19"
  end

  test "RET reads the item in the browse reader and marks it read" do
    show_feeds!()

    # the first row is the newest item — Beta at https://site.test/b
    press("RET")

    browse_buf = "*browse:site.test/b*"
    wait_until(fn -> Buffer.text(browse_buf) =~ "An article" end, 2_000)

    assert eval!(~s{(buffer-local "#{browse_buf}" 'browse-url)}) ==
             ~S["https://site.test/b"]

    assert eval!(~S{(feeds--read? "https://site.test/b")}) == "#t"
    assert eval!(~S{(feeds--read? "https://site.test/a")}) == "#f"
  end

  test "subscribe finds a page's feed link; unsubscribe removes the line" do
    eval!(~S{(set! *feeds-discover* (lambda (url k) (k "/blog/feed.xml")))})
    eval!(~S{(feeds--subscribe! "https://ex.test/blog/post")})

    assert eval!(~S{(feeds--subscriptions)}) ==
             ~S[("https://site.test/feed.xml" "https://ex.test/blog/feed.xml")]

    # a body that already is a feed subscribes as given, once
    eval!(~S{(set! *feeds-discover* (lambda (url k) (k url)))})
    eval!(~S{(feeds--subscribe! "https://ex.test/blog/feed.xml")})

    assert eval!(~S{(feeds--subscriptions)}) ==
             ~S[("https://site.test/feed.xml" "https://ex.test/blog/feed.xml")]

    eval!(~S{(feeds--save-subscriptions!
               (filter (lambda (u) (not (equal? u "https://ex.test/blog/feed.xml")))
                       (feeds--subscriptions)))})

    assert eval!(~S{(feeds--subscriptions)}) == ~S[("https://site.test/feed.xml")]
  end

  @rss ~S"""
  <?xml version="1.0"?>
  <rss version="2.0"><channel>
    <title>The RSS Blog</title>
    <item>
      <title>First &amp; foremost</title>
      <link>https://rss.test/one</link>
      <pubDate>Tue, 19 Aug 2026 10:00:05 GMT</pubDate>
    </item>
  </channel></rss>
  """

  @atom ~S"""
  <?xml version="1.0"?>
  <feed xmlns="http://www.w3.org/2005/Atom">
    <title>The Atom Blog</title>
    <entry>
      <title>Atom entry</title>
      <link rel="alternate" type="text/html" href="https://atom.test/one"/>
      <link rel="self" href="https://atom.test/feed"/>
      <updated>2026-08-20T09:30:00Z</updated>
    </entry>
  </feed>
  """

  test "feed.xsl turns RSS and Atom XML into item lines" do
    if System.find_executable("xsltproc") do
      xsl =
        Path.join(
          Application.app_dir(:aimax_core, "priv"),
          "packages/web/parsers/feed.xsl"
        )

      dir = System.tmp_dir!()

      for {name, xml, expect} <- [
            {"rss.xml", @rss,
             "The RSS Blog\tTue, 19 Aug 2026 10:00:05 GMT\thttps://rss.test/one\tFirst & foremost"},
            {"atom.xml", @atom,
             "The Atom Blog\t2026-08-20T09:30:00Z\thttps://atom.test/one\tAtom entry"}
          ] do
        path = Path.join(dir, "aimax-feeds-test-#{name}")
        File.write!(path, xml)
        {out, 0} = System.cmd("xsltproc", ["--novalid", xsl, path])
        File.rm(path)
        assert String.trim(out) == expect
      end
    end
  end
end
