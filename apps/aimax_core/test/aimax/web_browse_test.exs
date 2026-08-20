defmodule Aimax.WebBrowseTest do
  @moduledoc """
  packages/web.scm — a web page as readable text, offline. The fetch
  seam is replaced; links render as labels, RET follows, l goes back.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

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
      Aimax.Core.kill_buffer("*browse*")
      Editor.minibuffer_close()
    end)

    :ok
  end

  test "a page renders labels, hides targets, and records the link ranges" do
    eval!(~S|(browse "https://site.test/index.html")|)

    text = Buffer.text("*browse*")
    assert text =~ "Front page"
    assert text =~ "second page"
    refute text =~ "](/second.html"
    refute text =~ "(docs/intro.html"

    links = eval!(~S|(buffer-local "*browse*" 'web-links)|)
    assert links =~ "/second.html"
    assert links =~ "docs/intro.html"
    assert links =~ "https://other.test/x"
  end

  test "TAB walks to a link and RET follows it with the URL resolved" do
    eval!(~S|(browse "https://site.test/index.html")|)
    eval!(~S|(switch-to-buffer! "*browse*")|)

    press("TAB")
    press("RET")

    assert Buffer.text("*browse*") =~ "Second page"
    assert eval!(~S|(buffer-local "*browse*" 'browse-url)|) ==
             ~S["https://site.test/second.html"]

    # l returns to the front page
    press("l")
    assert Buffer.text("*browse*") =~ "Front page"
    assert eval!(~S|(buffer-local "*browse*" 'browse-url)|) ==
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

    eval!(~S|(browse "https://site.test/")|)
    assert eval!("*zz-web-fetches*") == "1"

    # the mode setup re-runs on restore and preview — fresh page, no fetch
    eval!(~S|(with-current-buffer "*browse*" (lambda () (set-mode! "browse-mode")))|)
    assert eval!("*zz-web-fetches*") == "1"
    assert Buffer.text("*browse*") =~ "hello"

    # past the TTL the wake refetches
    eval!(~S|(buffer-set-local! "*browse*" 'cache-time (- (current-time) 999999))|)
    eval!(~S|(with-current-buffer "*browse*" (lambda () (set-mode! "browse-mode")))|)
    assert eval!("*zz-web-fetches*") == "2"
  end
end
