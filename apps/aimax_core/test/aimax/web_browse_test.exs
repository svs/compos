defmodule Aimax.WebBrowseTest do
  @moduledoc """
  packages/web.scm — pages read as text, offline. The fetch seam is
  replaced; links render as labels, RET follows, M-<left>/M-<right>
  walk the history, every page is its own tab in the browse group.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # browse returns the tab's buffer name
  defp browse!(url), do: eval!(~s{(browse "#{url}")}) |> String.trim("\"")

  setup do
    eval!(~S"""
    (set! *web-fetch*
      (lambda (url k)
        (cond
          ((string-contains? url "second")
           (k "# Second page\n\nback home: [home](https://site.test/)\n"))
          (else
           (k (string-append
                "# Front page\n\n"
                "Read the [second page](/second.html) or the "
                "[docs](docs/intro.html) or leave via "
                "[elsewhere](https://other.test/x).\n"))))))
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

  test "a page renders as text: labels stay, targets hide, syntax goes" do
    buf = browse!("https://site.test/index.html")

    text = Buffer.text(buf)
    assert text =~ "Front page"
    refute text =~ "# Front page", "the heading mark survived into the text"
    assert text =~ "second page"
    refute text =~ "](/second.html"
    refute text =~ "(docs/intro.html"
    assert eval!(~s{(buffer-local "#{buf}" 'render-mode)}) == "#f"

    # the reading look: centered writing measure, no line numbers
    assert eval!(~s{(buffer-local "#{buf}" 'window-class)}) == ~S["writing"]
    assert eval!(~s{(buffer-local "#{buf}" 'line-numbers)}) == ~S["off"]

    links = eval!(~s{(buffer-local "#{buf}" 'web-links)})
    assert links =~ "/second.html"
    assert links =~ "docs/intro.html"
    assert links =~ "https://other.test/x"
  end

  test "every page is its own tab, in the browse group, navigation stays in place" do
    a = browse!("https://site.test/index.html")

    {:ok, _} = Session.eval(~S|(switch-to-buffer! "*scratch*")|)
    b = browse!("https://site.test/second.html")

    assert a != b
    assert a =~ "*browse:"
    assert eval!(~s{(buffer-local "#{b}" 'group)}) == ~S["browse"]

    # the same url from outside returns to its tab, not a new one
    {:ok, _} = Session.eval(~S|(switch-to-buffer! "*scratch*")|)
    assert browse!("https://site.test/second.html") == b

    # inside a tab, a url navigates IN PLACE
    {:ok, _} = Session.eval(~s{(switch-to-buffer! "#{a}")})
    assert browse!("https://site.test/second.html") == a
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
        (lambda (url k)
          (set! *zz-nav-fetches* (+ *zz-nav-fetches* 1))
          (k (string-append "# page\n\ngo [next](https://site.test/second.html)\n")))))
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

  test "relative links resolve against the page directory and the origin" do
    assert eval!(~S|(web--resolve "/a/b.html" "https://h.test/x/y.html")|) ==
             ~S["https://h.test/a/b.html"]

    assert eval!(~S|(web--resolve "b.html" "https://h.test/x/y.html")|) ==
             ~S["https://h.test/x/b.html"]

    assert eval!(~S|(web--resolve "//cdn.test/z" "https://h.test/x")|) ==
             ~S["https://cdn.test/z"]

    assert eval!(~S|(web--resolve "https://abs.test/" "https://h.test/")|) ==
             ~S["https://abs.test/"]
  end

  test "a wake redraws the saved page without fetching" do
    eval!(~S"""
    (begin
      (define *zz-web-fetches* 0)
      (set! *web-fetch*
        (lambda (url k)
          (set! *zz-web-fetches* (+ *zz-web-fetches* 1))
          (k "hello [x](https://a.test/)\n"))))
    """)

    buf = browse!("https://site.test/")
    assert eval!("*zz-web-fetches*") == "1"

    # the mode setup re-runs on restore and preview — fresh page, no fetch
    eval!(~s{(with-current-buffer "#{buf}" (lambda () (set-mode! "browse-mode")))})
    assert eval!("*zz-web-fetches*") == "1"
    assert Buffer.text(buf) =~ "hello"

    # past the TTL the wake refetches
    eval!(~s{(buffer-set-local! "#{buf}" 'cache-time (- (current-time) 999999))})
    eval!(~s{(with-current-buffer "#{buf}" (lambda () (set-mode! "browse-mode")))})
    assert eval!("*zz-web-fetches*") == "2"
  end

  test "a failed refetch keeps the page: the copy we hold serves" do
    eval!(~S"""
    (begin
      (define *zz-fail-after* 1)
      (set! *web-fetch*
        (lambda (url k)
          (if (> *zz-fail-after* 0)
              (begin (set! *zz-fail-after* (- *zz-fail-after* 1))
                     (k "# alive\n\nstill [here](https://site.test/x)\n"))
              (k #f)))))
    """)

    buf = browse!("https://site.test/index.html")
    assert Buffer.text(buf) =~ "alive"

    # g on the same page: the fetch fails, the copy serves again
    eval!(~s{(begin (buffer-set-local! "#{buf}" 'cache-time #f) (cache-refresh! "#{buf}") #t)})
    assert Buffer.text(buf) =~ "alive"
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

  test "the tidy pass drops heading marks and rules, and unescapes pandoc" do
    assert eval!(~S{(web--tidy "## A title\n\n----\n\nsee \\| this \\[here\\]\n")}) ==
             "\"A title\\n\\nsee | this [here]\\n\""
  end

  test "an image stays as a link; a wrapped pair is one image; icons go" do
    out =
      eval!(
        ~S{(web--tidy "[](https://c.test/a.jpeg)\n![](https://c.test/a-big.jpeg)\n\n[](https://c.test/icon-anchor)\n\ntext\n")}
      )

    assert out =~ "[https://c.test/a.jpeg](https://c.test/a.jpeg)"
    refute out =~ "a-big", "the wrapped pair rendered as two images"
    refute out =~ "icon-anchor"
  end
end
