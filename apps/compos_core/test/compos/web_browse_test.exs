defmodule Compos.WebBrowseTest do
  @moduledoc """
  packages/web.scm — the parts Scheme cannot hold.

  The rendering, the tabs, the cache and the pure passes are Scheme policy
  and live in priv/tests/web-browse-test.scm. Three tests here press TAB,
  RET and the M-arrows through KeyDispatch. One reads the minibuffer the
  prompt opened. One waits for an xsltproc conversion to answer.

  The fetch seam is replaced; no test reaches the network.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

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

  # browse returns the tab's buffer name
  defp browse!(url), do: eval!(~s{(browse "#{url}")}) |> String.trim("\"")

  setup do
    eval!(~S"""
    (set! *web-fetch*
      (lambda (url want k)
        (cond
          ((string-contains? url "second")
           (k (list want "# Second page\n\nback home: [home](https://site.test/)\n" #f)))
          (else
           (k (list want
                (string-append
                  "# Front page\n\n"
                  "Read the [second page](/second.html) or the "
                  "[docs](docs/intro.html) or leave via "
                  "[elsewhere](https://other.test/x).\n")
                #f))))))
    """)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      {:ok, _} =
        Session.eval(~S{(begin
          (for-each (lambda (b)
                      (when (equal? (buffer-local b 'mode-name) "browse-mode")
                        (buffer-kill! b)))
                    (buffer-list))
          (write-file! *web-visited-file* "")
          #t)})

      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "s-RET opens the link at point as its own tab; the page stays put" do
    a = browse!("https://site.test/index.html")

    press("TAB")
    press("s-RET")

    b = Editor.current_buffer()
    assert b != a
    assert b =~ "*browse:"
    assert Buffer.text(b) =~ "Second page"
    # the origin tab never moved
    assert Buffer.text(a) =~ "Front page"

    assert eval!(~s{(buffer-local "#{a}" 'browse-url)}) ==
             ~S["https://site.test/index.html"]
  end

  test "TAB walks to a link, RET follows it, M-arrows go back and forward" do
    buf = browse!("https://site.test/index.html")

    press("TAB")
    press("RET")

    assert Buffer.text(buf) =~ "Second page"

    assert eval!(~s{(buffer-local "#{buf}" 'browse-url)}) ==
             ~S["https://site.test/second.html"]

    press("M-<left>")
    assert Buffer.text(buf) =~ "Front page"

    press("M-<right>")
    assert Buffer.text(buf) =~ "Second page"

    # a fresh navigation clears the future
    press("M-<left>")
    browse!("https://site.test/docs/intro.html")
    assert eval!(~s{(buffer-local "#{buf}" 'browse-forward)}) == "()"
  end

  test "back and forward serve the session copy without a second fetch" do
    eval!(~S"""
    (begin
      (define *zz-nav-fetches* 0)
      (set! *web-fetch*
        (lambda (url want k)
          (set! *zz-nav-fetches* (+ *zz-nav-fetches* 1))
          (k (list want "# page\n\ngo [next](https://site.test/second.html)\n" #f)))))
    """)

    buf = browse!("https://site.test/index.html")
    press("TAB")
    press("RET")
    assert eval!("*zz-nav-fetches*") == "2"

    press("M-<left>")
    press("M-<right>")
    press("M-<left>")
    assert eval!("*zz-nav-fetches*") == "2", "back/forward refetched"

    assert eval!(~s{(buffer-local "#{buf}" 'browse-url)}) ==
             ~S["https://site.test/index.html"]
  end

  test "a rendered page joins the visited list, and the prompt completes over it" do
    browse!("https://site.test/index.html")

    visited = eval!("(web--visited)")
    assert visited =~ "https://site.test/index.html"
    assert visited =~ "Front page"

    # the prompt offers it, title beside the URL
    {:ok, _} = Session.eval(~S|(switch-to-buffer! "*scratch*")|)
    eval!(~S|(run-command "browse")|)
    mb = Editor.render_state().minibuffer
    assert mb.prompt == "URL: "
    labels = Enum.map(mb.candidates, & &1.label)
    assert "https://site.test/index.html" in labels
    press("C-g")
  end

  test "Substack keeps feed articles and groups reaction counts" do
    assert eval!(~S{(web--site-parser "https://substack.com/inbox")}) =~ "substack.xsl"
    assert eval!(~S{(web--site-parser "https://example.com")}) == "#f"

    eval!(~S"""
    (begin
      (define *zz-substack-md* #f)
      (define *zz-substack-html*
        "<html><body><nav>Home Subscriptions Chat Activity Explore Dashboard</nav><main><div role='article' aria-label='Note'><img src='https://substackcdn.com/image/fetch/avatar.jpeg' alt='Alice avatar'><a href='/@alice'>Alice</a><a href='/@alice/note/c-1' title='Aug 3, 2026, 9:00 PM'>Aug 3</a><p>This is the first useful feed note. It contains enough text to remain above the parser confidence threshold.</p><img src='https://substackcdn.com/image/fetch/content-image.png' alt='A useful diagram'><p>The second paragraph proves that the selected article body survives conversion with its links and prose intact.</p><p>The third paragraph keeps this fixture representative of a real Substack feed item.</p><a href='https://alice.example/p/clickable-post'><img src='https://substackcdn.com/image/fetch/article-card.png' alt=''><div><a href='https://alice.example'>Alice publication</a><div>Clickable article title</div></div></a><img src='https://substackcdn.com/image/fetch/w_20,h_20/publication.png' sizes='20px' alt='Alice publication'><div class='actions'><button aria-label='Like'><svg></svg><span>34</span></button><button aria-label='Comment'><svg></svg><span>2</span></button><button aria-label='Restack'><svg></svg><span>3</span></button><button aria-label='Share'><svg></svg></button></div></div><div role='article' aria-label='Note'><a href='/@bob'>Bob</a><a href='/@bob/note/c-2'>Aug 4</a><p>This is the second useful feed note. It verifies that one separator appears between two semantic articles.</p></div><section><h2>People to follow</h2><p>Suggested Person</p></section></main></body></html>")
      ;; the reading takes a FILE: one fetch is written once and each
      ;; reading is a command over it
      (let ((f (web--write-html! *zz-substack-html*)))
        (web--read "https://substack.com/" f "calm"
          (lambda (md) (delete-file! f) (set! *zz-substack-md* md)))))
    """)

    md =
      wait_until(
        fn ->
          case eval!("*zz-substack-md*") do
            "#f" -> false
            value -> value
          end
        end,
        5_000
      )

    assert md =~
             "![](https://substackcdn.com/image/fetch/avatar.jpeg#compos-avatar) [Alice](/@alice) · [Aug 3](/@alice/note/c-1) ♥ 34 💬 2 ↻ 3"

    refute md =~ "Aug 3, 2026"
    assert eval!(~S{(web--date-link? (list 0 5 "/@alice/note/c-1"))}) == "#t"

    assert md =~ "first useful feed note"
    assert md =~ "second useful feed note"
    assert md =~ "[Clickable article title](https://alice.example/p/clickable-post)"

    assert md =~
             ~S|\n\n![](https://substackcdn.com/image/fetch/w_20,h_20/publication.png#compos-avatar) Alice publication\n\n|

    assert md =~ "Alice publication"

    assert eval!(~S{(web--parse *zz-substack-md*)}) =~
             "https://alice.example/p/clickable-post"

    assert length(Regex.scan(~r/COMPOS-ARTICLE-SEPARATOR/, md)) == 1

    assert eval!(~S{(web--article-separator-ranges "a\nCOMPOS-ARTICLE-SEPARATOR\nb")}) ==
             ~S[((2 26 "web-separator"))]

    assert md =~ "https://substackcdn.com/image/fetch/content-image.png"
    assert md =~ "![](https://substackcdn.com/image/fetch/avatar.jpeg#compos-avatar)"
    refute md =~ "Alice avatar"
    assert md =~ "♥ 34"
    assert md =~ "💬 2"
    assert md =~ "↻ 3"
    refute md =~ "\n34\n"
    refute md =~ "\n2\n"
    refute md =~ "\n3\n"
    refute md =~ "Home Subscriptions"
    refute md =~ "People to follow"
    refute md =~ "Suggested Person"
  end

end
