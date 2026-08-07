defmodule Aimax.NotmuchTest do
  @moduledoc """
  notmuch mail client: search buffer, thread view, tags, reply/send,
  context providers, and the mail tools — all against a stub notmuch
  binary, driven through the same paths the GUI uses.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp calls(dir) do
    case File.read(Path.join(dir, "calls.log")) do
      {:ok, log} -> log
      _ -> ""
    end
  end

  @search_json ~S"""
  [{"thread": "0001", "timestamp": 1786065644, "date_relative": "Today 06:50", "matched": 1, "total": 1, "authors": "Alice", "subject": "Hello world", "query": ["id:m1", null], "tags": ["inbox", "unread"]},
  {"thread": "0002", "timestamp": 1786037671, "date_relative": "Yest. 23:04", "matched": 1, "total": 2, "authors": "Bob| Carol", "subject": "Quarterly report", "query": ["id:m2", "id:m3"], "tags": ["inbox"]}]
  """

  @show_json ~S"""
  [[[{"id": "m1", "match": true, "excluded": false, "filename": ["/Users/svs/Mail/svsrecruiting/mail/cur/abc:2,S"], "timestamp": 1786065644, "date_relative": "Today 06:50", "tags": ["inbox", "unread"], "duplicate": 1, "body": [{"id": 1, "content-type": "multipart/alternative", "content": [{"id": 2, "content-type": "text/plain", "content": "Hi there, this is the body.\n"}, {"id": 3, "content-type": "text/html", "content-charset": "utf-8", "content-length": 100}]}], "headers": {"Subject": "Hello world", "From": "Alice <alice@example.com>", "To": "svs@svsrecruiting.com", "Date": "Thu, 07 Aug 2026 06:50:44 +0530"}}, []]]]
  """

  @reply_template """
  From: svs@svsrecruiting.com
  To: Alice <alice@example.com>
  Subject: Re: Hello world
  In-Reply-To: <m1>

  On Thu, Alice wrote:
  > Hi there, this is the body.
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "nm-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "search.json"), @search_json)
    File.write!(Path.join(dir, "show.json"), @show_json)
    File.write!(Path.join(dir, "reply.txt"), @reply_template)

    stub = Path.join(dir, "notmuch")

    File.write!(stub, """
    #!/bin/sh
    dir="$(dirname "$0")"
    echo "$@" >> "$dir/calls.log"
    case "$1" in
      search) cat "$dir/search.json";;
      show) cat "$dir/show.json";;
      reply) cat "$dir/reply.txt";;
    esac
    """)

    File.chmod!(stub, 0o755)

    # reset editor state and any mail buffers a failed test left behind
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!(~s{(begin
      (set! notmuch-program "#{stub}")
      (switch-to-buffer! "*scratch*")
      (for-each (lambda (b)
                  (when (or (equal? b "*notmuch*")
                            (string-prefix? "*mail:" b)
                            (equal? b "*compose*"))
                    (buffer-kill! b)))
                (buffer-list))
      #t)})

    {:ok, dir: dir}
  end

  test "notmuch opens a search listing of threads" do
    eval!(~s{(run-command "notmuch")})
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}

    text = eval!(~s{(buffer-text "*notmuch*")})
    assert text =~ "notmuch: tag:inbox (2)"
    assert text =~ "Hello world"
    assert text =~ "Quarterly report"
    assert text =~ "Alice"
  end

  test "RET opens the thread, renders text/plain only, marks it read", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("RET")

    assert eval!("(current-buffer)") == ~s{"*mail: Hello world*"}
    text = eval!(~s{(buffer-text (current-buffer))})
    assert text =~ "From: Alice <alice@example.com>"
    assert text =~ "Hi there, this is the body."
    refute text =~ "content-length"

    log = calls(dir)
    assert log =~ "show --format=json"
    assert log =~ "tag -unread -- thread:0001"
  end

  test "a archives the thread at point", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("a")
    assert calls(dir) =~ "tag -inbox -- thread:0001"
  end

  test "the search buffer survives a mode re-setup (desktop restore path)" do
    eval!(~s{(run-command "notmuch")})
    # restore re-runs set-mode! with locals already down — same path
    eval!(~s{(set-mode! "notmuch-mode")})
    text = eval!(~s{(buffer-text "*notmuch*")})
    assert text =~ "Hello world"
    press("RET")
    assert eval!("(current-buffer)") == ~s{"*mail: Hello world*"}
  end

  test "context providers explain the selection to chat and agents" do
    eval!(~s{(run-command "notmuch")})

    ctx = eval!(~s{(editor-context "*some-chat*")})
    assert ctx =~ "Hello world"
    assert ctx =~ "thread:0001"

    pre = eval!(~s{(editor-context-preamble "*some-chat*")})
    assert pre =~ "Editor context"
    assert pre =~ ~S{says \"this\"}

    # in the thread buffer the provider names the open thread + message
    press("RET")
    ctx2 = eval!(~s{(editor-context "*some-chat*")})
    assert ctx2 =~ "thread:0001"
    assert ctx2 =~ "id:m1"

    # a buffer with no provider contributes nothing
    eval!(~s{(switch-to-buffer! "*scratch*")})
    assert eval!(~s{(editor-context-preamble "*some-chat*")}) == ~s{""}
  end

  test "reply composes from the notmuch template and C-c C-c sends", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("RET")
    press("r")

    assert eval!("(current-buffer)") == ~s{"*compose*"}
    text = eval!(~s{(buffer-text "*compose*")})
    assert text =~ "Subject: Re: Hello world"
    assert text =~ "> Hi there"
    assert calls(dir) =~ "reply id:"

    # route the send through a harmless command
    eval!(~s{(set! notmuch-send-routes (list (list "" "cat > /dev/null")))})
    press(["C-c", "C-c"])
    assert Editor.snapshot().echo == "Sent"
    assert eval!(~s{(buffer-exists? "*compose*")}) == "#t"
  end

  test "mail tools search and read through the same renderer" do
    out = eval!(~s{(llm-tool-call "notmuch-search" (list 'query "tag:inbox"))})
    assert out =~ "thread:0001"
    assert out =~ "Hello world"
    assert out =~ "Alice"

    out = eval!(~s{(llm-tool-call "read-email-thread" (list 'thread "thread:0001"))})
    assert out =~ "Hi there, this is the body."

    out = eval!(~s{(llm-tool-call "notmuch-tag" (list 'thread "0002" 'changes "+important"))})
    assert out =~ "done"
  end
end
