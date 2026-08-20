defmodule Aimax.SentryListVerbsTest do
  @moduledoc """
  The detail workspace's verbs — ask the agent, open in Sentry, resolve —
  act from the issue list on the marked rows, or the row at point.
  Transport, agent, and browser seams are replaced; nothing leaves.
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
    (set! *sentry-transport*
      (lambda (url)
        (cond
          ((string-contains? url "/issues/42/")
           "{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"boom\",\"status\":\"unresolved\",\"permalink\":\"https://sentry.io/i/42\"}\n200")
          ((string-contains? url "/issues/43/")
           "{\"id\":\"43\",\"shortId\":\"ATS-43\",\"title\":\"crash\",\"status\":\"unresolved\",\"permalink\":\"https://sentry.io/i/43\"}\n200")
          (else
           "[{\"id\":\"42\",\"shortId\":\"ATS-42\",\"title\":\"boom\",\"level\":\"error\",\"count\":\"3\",\"lastSeen\":\"2026-08-20T10:00:00Z\",\"permalink\":\"https://sentry.io/i/42\"},{\"id\":\"43\",\"shortId\":\"ATS-43\",\"title\":\"crash\",\"level\":\"error\",\"count\":\"1\",\"lastSeen\":\"2026-08-20T11:00:00Z\",\"permalink\":\"https://sentry.io/i/43\"}]\n200"))))
    """)

    # the list fetches through the async seam; a synchronous delegate
    # keeps the per-URL transport stub above authoritative
    eval!("(set! *sentry-async-transport* (lambda (url k) (k (*sentry-transport* url))))")

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Editor.minibuffer_close()

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

  defp open_list_and_mark_both do
    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)
    press(["m", "m"])
  end

  test "R resolves every marked row after one confirmation" do
    eval!(~S"""
    (begin
      (define *zz-resolved-urls* '())
      (set! *sentry-write-transport*
        (lambda (url payload)
          (set! *zz-resolved-urls* (cons url *zz-resolved-urls*))
          "\n200")))
    """)

    open_list_and_mark_both()
    press("R")

    # one question for both rows
    assert eval!("(minibuffer-state)") =~ "Resolve ATS-42, ATS-43 in Sentry?"
    press("y")

    urls = eval!("*zz-resolved-urls*")
    assert urls =~ "/issues/42/"
    assert urls =~ "/issues/43/"
  end

  test "o opens every marked row's permalink" do
    eval!(~S"""
    (begin
      (define *zz-opened-urls* '())
      (set! *sentry-open-url*
        (lambda (url) (set! *zz-opened-urls* (cons url *zz-opened-urls*)))))
    """)

    open_list_and_mark_both()
    press("o")

    urls = eval!("*zz-opened-urls*")
    assert urls =~ "https://sentry.io/i/42"
    assert urls =~ "https://sentry.io/i/43"
  end

  test "a sends one prompt naming every marked issue and its detail buffer" do
    eval!(~S"""
    (begin
      (define *zz-agent-prompt* "")
      (set! *sentry-agent-send*
        (lambda (chat prompt) (set! *zz-agent-prompt* prompt))))
    """)

    open_list_and_mark_both()
    press("a")

    prompt = eval!("*zz-agent-prompt*")
    assert prompt =~ "ATS-42"
    assert prompt =~ "ATS-43"
    assert prompt =~ "*Sentry issue: 42*"
    assert prompt =~ "*Sentry issue: 43*"

    # the detail buffers exist and hold the fetched issues
    assert Buffer.text("*Sentry issue: 42*") =~ "ATS-42"
    assert Buffer.text("*Sentry issue: 43*") =~ "ATS-43"
  end

  test "resolving the shown row advances its detail to the next row" do
    eval!(~S"""
    (set! *sentry-write-transport* (lambda (url payload) "\n200"))
    """)

    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)

    # RET shows ATS-42's detail in the other window; focus stays in the list
    press("RET")
    assert eval!("(map cadr (window-list))") =~ "*Sentry issue: 42*"

    press("R")
    press("y")

    # the highlight lands on ATS-43 and the detail window follows it;
    # the resolved issue's detail buffer is gone
    assert eval!("(map cadr (window-list))") =~ "*Sentry issue: 43*"
    assert eval!(~S|(buffer-exists? "*Sentry issue: 42*")|) == "#f"
  end

  test "with nothing marked the verbs act on the row at point" do
    eval!(~S"""
    (begin
      (define *zz-opened-urls* '())
      (set! *sentry-open-url*
        (lambda (url) (set! *zz-opened-urls* (cons url *zz-opened-urls*)))))
    """)

    eval!(~S|(run-command "sentry")|)
    eval!(~S|(switch-to-buffer! "*Sentry issues*")|)
    eval!(~S|(list-goto-first-entry "*Sentry issues*")|)
    press("o")

    urls = eval!("*zz-opened-urls*")
    assert urls =~ "https://sentry.io/i/42"
    refute urls =~ "https://sentry.io/i/43"
  end
end
