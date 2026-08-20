defmodule Aimax.SentryTest do
  @moduledoc """
  packages/sentry.scm — the read-only Sentry client, offline.

  Tests replace the transport seam. No test reads Doppler or reaches Sentry.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    eval!("(set! *sentry-transport* sentry--curl)")
    eval!("(set! *sentry-write-transport* sentry--curl-write)")
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

  test "the defaults point at the production ATS project" do
    assert eval!("(list sentry-org sentry-project sentry-environment)") ==
             ~S{("svs-recruiting" "ats-ash" "prod")}
  end

  test "an issue search encodes filters and caps its limit" do
    eval!(~S"""
    (begin
      (define *sentry-test-url* "")
      (set! *sentry-transport*
        (lambda (url)
          (set! *sentry-test-url* url)
          "[]\n200"))
      (sentry-list-issues "is:unresolved assigned:me" "prod" "7d" 500))
    """)

    url = eval!("*sentry-test-url*")

    assert url =~ "/api/0/projects/svs-recruiting/ats-ash/issues/"
    assert url =~ "query=is%3Aunresolved%20assigned%3Ame"
    assert url =~ "environment=prod"
    assert url =~ "statsPeriod=7d"
    assert url =~ "per_page=50"
  end

  test "HTTP failures have one safe result shape" do
    eval!(~S|(set! *sentry-transport* (lambda (url) "private response body\n403"))|)

    reply = eval!("(sentry-list-issues)")

    assert reply =~ "errors"
    assert reply =~ "HTTP 403"
    refute reply =~ "private response body"
  end

  test "the client enforces its row limit when Sentry returns more" do
    eval!(
      ~S|(set! *sentry-transport* (lambda (url) "[{\"id\":\"1\"},{\"id\":\"2\"},{\"id\":\"3\"}]\n200"))|
    )

    reply = eval!(~S|(sentry-list-issues "" "prod" "24h" 2)|)
    assert reply =~ ~s{(id "1"}
    assert reply =~ ~s{(id "2"}
    refute reply =~ ~s{(id "3"}
  end

  test "the issue detail puts the exception first and keeps complete raw JSON" do
    text =
      eval!("""
      (sentry--issue-text
        (list 'shortId "ATS-1"
              'title ""
              'status "unresolved"
              'metadata
              (list 'type "RuntimeError"
                    'value "credits exhausted"
                    'secret "visible-in-raw")))
      """)

    assert text =~ "ATS-1  RuntimeError"
    assert text =~ "Exception\\ncredits exhausted"
    assert text =~ "Raw issue JSON"
    assert text =~ "visible-in-raw"
    refute text =~ "<!doctype html>"
  end

  test "the public API declares its domain and effects" do
    entry = eval!(~S|(catalog-entry 'function "sentry-list-issues")|)

    assert entry =~ ~s{domain "sentry"}
    assert entry =~ ~s{effects ("read" "external")}

    command = eval!(~S|(catalog-entry 'command "sentry")|)
    assert command =~ ~s{effects ("write" "external")}
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
    assert eval!(~S|(buffer-group "*Sentry issues*")|) == ~s{"sentry"}
    assert eval!(~S|(buffer-group (group-chat "sentry"))|) == ~s{"sentry"}

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
    assert eval!(~S|(buffer-group "*Sentry issue: 42*")|) == ~s{"sentry"}

    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    KeyDispatch.handle_key("n")
    KeyDispatch.handle_key("RET")

    assert Buffer.exists?("*Sentry issue: 43*")
    assert Buffer.text("*Sentry issue: 43*") =~ "ATS-43"
    assert eval!(~S|(buffer-group "*Sentry issue: 43*")|) == ~s{"sentry"}

    eval!(
      ~S|(set! *sentry-transport* (lambda (url) "{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"downloaded twice\"}\n200"))|
    )
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    KeyDispatch.handle_key("p")
    KeyDispatch.handle_key("RET")

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
