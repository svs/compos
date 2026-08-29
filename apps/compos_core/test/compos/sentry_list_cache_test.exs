defmodule Compos.SentryListCacheTest do
  @moduledoc """
  The issue list fetches through the buffer cache. One open pays one
  fetch; marks and width changes redraw the cached rows; `g` fetches
  again. Transport seams are replaced; nothing leaves.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp fetches, do: eval!("*zz-sentry-fetches*")

  setup do
    eval!(~S"""
    (begin
      (define *zz-sentry-fetches* 0)
      (set! *sentry-transport*
        (lambda (url)
          (set! *zz-sentry-fetches* (+ *zz-sentry-fetches* 1))
          (if (string-contains? url "/issues/42/")
              "{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"boom\",\"status\":\"unresolved\"}\n200"
              "[{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"boom\",\"level\":\"error\",\"count\":\"3\",\"lastSeen\":\"2026-08-20T10:00:00Z\",\"permalink\":\"https://sentry.io/i/42\"}]\n200")))
      (set! *sentry-async-transport*
        (lambda (url k) (k (*sentry-transport* url)))))
    """)

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Editor.minibuffer_close()
      Compos.Core.kill_buffer("*Sentry issues*")
      Compos.Core.kill_buffer("*Sentry issue: 42*")
      Compos.Core.kill_buffer("*chat:sentry*")
    end)

    :ok
  end

  test "one open is one fetch; marks and width changes reuse the rows; g refetches" do
    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)

    assert fetches() == "1"
    assert Buffer.text("*Sentry issues*") =~ "ATS-42"

    KeyDispatch.handle_key("m")
    assert fetches() == "1"

    eval!(~S"""
    (begin
      (buffer-set-local! "*Sentry issues*" 'list-width 999)
      (list-post-command! "*Sentry issues*"))
    """)
    assert fetches() == "1"
    assert Buffer.text("*Sentry issues*") =~ "ATS-42"

    KeyDispatch.handle_key("g")
    assert fetches() == "2"

    # RET fetches the detail once; RET again serves the cache
    KeyDispatch.handle_key("RET")
    assert fetches() == "3"
    assert Buffer.text("*Sentry issue: 42*") =~ "ATS-42"

    KeyDispatch.handle_key("RET")
    assert fetches() == "3"
  end

  test "the first detail draw comes from the row, before the fetch answers" do
    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)

    # a fetch that never answers: what draws is what the row knew
    eval!("(set! *sentry-async-transport* (lambda (url k) #f))")
    KeyDispatch.handle_key("RET")

    assert Buffer.text("*Sentry issue: 42*") =~ "ATS-42"
    assert Buffer.text("*Sentry issue: 42*") =~ "boom"
  end

  test "a window-configuration change re-lays only the lists on screen" do
    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*scratch*")|)
    eval!(~S|(buffer-set-local! "*Sentry issues*" 'list-width 777)|)
    eval!("(window-config-changed!)")

    # the hidden list keeps its stale width: nothing visited it
    assert eval!(~S|(buffer-local "*Sentry issues*" 'list-width)|) == "777"
    assert fetches() == "1"
  end
end
