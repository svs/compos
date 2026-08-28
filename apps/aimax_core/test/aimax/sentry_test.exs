defmodule Aimax.SentryTest do
  @moduledoc """
  The Sentry tests that drive keys.

  The client itself is Scheme policy and lives in
  priv/tests/sentry-test.scm. These three stay here: they press RET, n, p,
  a, R and y through KeyDispatch, which is the path the GUI uses.

  Tests replace the transport seam. No test reads Doppler or reaches Sentry.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    # the frame's group and the last one visited are global editor state:
    # a module that entered a group leaves the next one starting inside it
    Aimax.Core.Session.eval(
      "(begin (set-frame-local! 'current-group #f) (set-frame-local! 'previous-group #f))"
    )
    eval!("(set! *sentry-transport* sentry--curl)")
    eval!("(set! *sentry-write-transport* sentry--curl-write)")
    # the list fetches through the async seam; a synchronous delegate
    # keeps each test's per-URL transport stub authoritative
    eval!("(set! *sentry-async-transport* (lambda (url k) (k (*sentry-transport* url))))")
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      for buffer <- [
            "*Sentry issues*",
            "*Sentry issue: 42*",
            "*Sentry issue: 43*",
            "*Sentry issue: 99*",
            "*chat:sentry*"
          ],
          do: Aimax.Core.kill_buffer(buffer)
    end)

    :ok
  end

  test "RET opens distinct grouped detail buffers through the real key path" do
    eval!(~S"""
    (set! *sentry-transport*
      (lambda (url)
        (cond
          ((string-contains? url "/issues/42/")
           "{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"failure for jane@example.com\",\"status\":\"unresolved\",\"metadata\":{\"secret\":\"hidden\"}}\n200")
          ((string-contains? url "/issues/43/")
           "{\"id\":\"43\",\"shortId\":\"ATS-43\",\"title\":\"another failure\",\"status\":\"unresolved\"}\n200")
          (else
           "[{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"failure for jane@example.com\",\"level\":\"error\",\"count\":\"3\",\"lastSeen\":\"2026-08-18T10:00:00Z\"},{\"id\":\"43\",\"shortId\":\"ATS-43\",\"title\":\"another failure\",\"level\":\"error\",\"count\":\"1\",\"lastSeen\":\"2026-08-18T11:00:00Z\"}]\n200"))))
    """)

    eval!(~S|(run-command "sentry")|)
    assert eval!(~S|(group-name (buffer-group "*Sentry issues*"))|) == ~s{"sentry"}
    assert eval!(~S|(group-name (buffer-group (group-chat "sentry")))|) == ~s{"sentry"}

    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)
    KeyDispatch.handle_key("RET")

    assert Buffer.exists?("*Sentry issue: 42*")
    text = Buffer.text("*Sentry issue: 42*")
    assert text =~ "ATS-42"
    assert text =~ "[redacted-email]"
    assert text =~ "Raw issue JSON"
    assert text =~ "hidden"
    refute text =~ "<!doctype html>"
    assert eval!(~S|(buffer-local "*Sentry issue: 42*" 'render-mode)|) == ~s{"blocks"}
    assert eval!(~S|(group-name (buffer-group "*Sentry issue: 42*"))|) == ~s{"sentry"}

    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    KeyDispatch.handle_key("n")
    KeyDispatch.handle_key("RET")

    assert Buffer.exists?("*Sentry issue: 43*")
    assert Buffer.text("*Sentry issue: 43*") =~ "ATS-43"
    assert eval!(~S|(group-name (buffer-group "*Sentry issue: 43*"))|) == ~s{"sentry"}

    eval!(
      ~S|(set! *sentry-transport* (lambda (url) "{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"downloaded twice\"}\n200"))|
    )
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    KeyDispatch.handle_key("p")
    KeyDispatch.handle_key("RET")

    # RET on the same row serves the cache inside the TTL
    refute Buffer.text("*Sentry issue: 42*") =~ "downloaded twice"

    # `g` in the detail is the explicit refetch
    eval!(~S|(switch-to-buffer! "*Sentry issue: 42*")|)
    KeyDispatch.handle_key("g")
    assert Buffer.text("*Sentry issue: 42*") =~ "downloaded twice"
  end

  test "the detail action bar sends the issue to its group agent" do
    eval!(~S"""
    (begin
      (define *sentry-test-agent-prompt* "")
      (set! *sentry-agent-send*
        (lambda (chat prompt)
          (set! *sentry-test-agent-prompt* prompt)))
      (set! *sentry-transport*
        (lambda (url)
          "{\"id\":\"99\",\"shortId\":\"ATS-99\",\"title\":\"worker failed\",\"status\":\"unresolved\",\"priority\":\"high\",\"permalink\":\"https://example.sentry.io/issues/99/\",\"metadata\":{\"type\":\"RuntimeError\",\"value\":\"boom\"}}\n200")))
    """)

    eval!(~S|(buffer-create "*Sentry issue: 99*")|)
    eval!(~S|(buffer-set-local! "*Sentry issue: 99*" 'sentry-issue-id "99")|)
    eval!(~S|(switch-to-buffer! "*Sentry issue: 99*")|)
    eval!(~S|(set-mode! "sentry-detail-mode")|)
    eval!(~S|(run-command "sentry-detail-refresh")|)

    actions = eval!(~S|(value->string sentry--detail-actions)|)
    assert actions =~ "Ask agent"
    assert actions =~ "Open in Sentry"
    assert actions =~ "Resolve"
    assert eval!(~S|(buffer-local "*Sentry issue: 99*" 'render-mode)|) == ~s{"blocks"}

    KeyDispatch.handle_key("a")

    prompt = eval!("*sentry-test-agent-prompt*")
    assert prompt =~ "ATS-99"
    assert prompt =~ "*Sentry issue: 99*"
    assert eval!(~S|(current-buffer)|) == ~s{"*chat:sentry*"}
  end

  test "resolve asks first and sends the Sentry update after y" do
    eval!(~S"""
    (begin
      (define *sentry-test-write-url* "")
      (define *sentry-test-write-body* "")
      (set! *sentry-transport*
        (lambda (url)
          (if (string-contains? url "/issues/99/")
              "{\"id\":\"99\",\"shortId\":\"ATS-99\",\"title\":\"worker failed\",\"status\":\"unresolved\",\"priority\":\"high\",\"permalink\":\"https://example.sentry.io/issues/99/\",\"metadata\":{\"type\":\"RuntimeError\",\"value\":\"boom\"}}\n200"
              "[]\n200")))
      (set! *sentry-write-transport*
        (lambda (url body)
          (set! *sentry-test-write-url* url)
          (set! *sentry-test-write-body* body)
          "{\"status\":\"resolved\"}\n200")))
    """)

    eval!(~S|(buffer-create "*Sentry issue: 99*")|)
    eval!(~S|(buffer-set-local! "*Sentry issue: 99*" 'sentry-issue-id "99")|)
    eval!(~S|(switch-to-buffer! "*Sentry issue: 99*")|)
    eval!(~S|(set-mode! "sentry-detail-mode")|)

    KeyDispatch.handle_key("R")
    assert eval!("*sentry-test-write-url*") == ~s{""}

    KeyDispatch.handle_key("y")

    assert eval!("*sentry-test-write-url*") =~
             "/api/0/organizations/svs-recruiting/issues/99/"
    assert eval!("*sentry-test-write-body*") =~ "resolved"
  end
end
