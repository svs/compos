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
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      for buffer <- [
            "*Sentry issues*",
            "*Sentry issue: 42*",
            "*Sentry issue: 43*",
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

  test "the safe issue summary redacts addresses and omits raw fields" do
    text =
      eval!("""
      (sentry--issue-text
        (list 'shortId "ATS-1"
              'title "failed for jane@example.com from 10.2.3.4"
              'status "unresolved"
              'metadata (list 'secret "do-not-print")
              'user (list 'email "jane@example.com")))
      """)

    assert text =~ "[redacted-email]"
    assert text =~ "[redacted-ip]"
    refute text =~ "do-not-print"
    refute text =~ "metadata"
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
    assert text =~ "omits user data"
    refute text =~ "hidden"
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

    assert Buffer.text("*Sentry issue: 42*") == text
  end
end
