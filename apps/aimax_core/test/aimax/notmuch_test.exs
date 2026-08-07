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

  @show_html_json ~S"""
  [[[{"id": "m2", "match": true, "excluded": false, "filename": ["/Users/svs/Mail/svsrecruiting/mail/cur/def:2,S"], "timestamp": 1786037671, "date_relative": "Yest. 23:04", "tags": ["inbox"], "duplicate": 1, "body": [{"id": 1, "content-type": "text/html", "content": "<p>Hello <b>HTML</b> world</p>"}], "headers": {"Subject": "Quarterly report", "From": "Bob <bob@example.com>", "To": "svs@svsrecruiting.com", "Date": "Wed, 06 Aug 2026 23:04:31 +0530"}}, []]]]
  """

  @reply_json ~S"""
  {"reply-headers": {"Subject": "Re: Hello world", "From": "SVS <svs@svsrecruiting.com>", "To": "Alice <alice@example.com>", "In-reply-to": "<m1>", "References": "<m1>"}, "original": {"id": "m1", "match": false, "excluded": false, "filename": ["/Users/svs/Mail/svsrecruiting/mail/cur/abc:2,S"], "timestamp": 1786065644, "date_relative": "Today 06:50", "tags": ["inbox"], "body": [{"id": 1, "content-type": "multipart/alternative", "content": [{"id": 2, "content-type": "text/plain", "content": "Hi there, this is the body.\n"}, {"id": 3, "content-type": "text/html", "content-length": 100}]}], "headers": {"Subject": "Hello world", "From": "Alice <alice@example.com>", "To": "svs@svsrecruiting.com", "Date": "Thu, 07 Aug 2026 06:50:44 +0530"}}}
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "nm-stub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "search.json"), @search_json)
    File.write!(Path.join(dir, "show.json"), @show_json)
    File.write!(Path.join(dir, "reply.json"), @reply_json)

    stub = Path.join(dir, "notmuch")

    File.write!(Path.join(dir, "show-html.json"), @show_html_json)

    File.write!(stub, """
    #!/bin/sh
    dir="$(dirname "$0")"
    echo "$@" >> "$dir/calls.log"
    case "$1" in
      search)
        case "$*" in
          *--output=messages*) echo "id:m1";;
          *) cat "$dir/search.json";;
        esac;;
      show)
        case "$*" in
          *thread:0002*) cat "$dir/show-html.json";;
          *) cat "$dir/show.json";;
        esac;;
      reply) cat "$dir/reply.json";;
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
      (set! notmuch-auto-preview #f)
      (set! notmuch-html-renderer "cat")
      (switch-to-buffer! "*scratch*")
      (for-each (lambda (b)
                  (when (or (equal? b "*notmuch*")
                            (string-prefix? "*mail" b)
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

    assert eval!("(current-buffer)") == ~s{"*mail*"}
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
    assert eval!("(current-buffer)") == ~s{"*mail*"}
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

  test "reply is a message-mode buffer: headers, separator, quote, point at body", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("RET")
    press("r")

    assert eval!("(current-buffer)") == ~s{"*compose*"}
    text = eval!(~s{(buffer-text "*compose*")})
    assert text =~ "From: SVS <svs@svsrecruiting.com>"
    assert text =~ "To: Alice <alice@example.com>"
    assert text =~ "Subject: Re: Hello world"
    assert text =~ "In-Reply-To: <m1>"
    assert text =~ "--text follows this line--"
    assert text =~ "Alice <alice@example.com> writes:"
    assert text =~ "> Hi there, this is the body."
    assert calls(dir) =~ "reply --format=json id:"

    # point sits on the empty line right after the separator
    before = eval!(~s{(substring-bytes (buffer-text "*compose*") 0 (point))})
    assert String.ends_with?(before, ~S(line--\n") <> "")

    # header names and separator carry faces
    ovs = eval!(~s{(buffer-overlays "*compose*")})
    assert ovs =~ "nm-hdr"
    assert ovs =~ "nm-sep"

    # sending turns the separator into the RFC822 blank line
    eval!(~s{(set! notmuch-send-routes (list (list "" "cat > #{dir}/sent.eml")))})
    press(["C-c", "C-c"])
    assert Editor.snapshot().echo == "Sent"
    sent = File.read!("#{dir}/sent.eml")
    refute sent =~ "text follows this line"
    assert sent =~ "Subject: Re: Hello world"
    assert sent =~ "In-Reply-To: <m1>"
    assert sent =~ "References: <m1>\n\n"
  end

  test "an HTML message renders as an HTML document; v toggles text", %{dir: _} do
    eval!(~s{(begin (run-command "notmuch") (next-line!) (beginning-of-line!))})
    press("RET")

    assert eval!("(current-buffer)") == ~s{"*mail*"}
    assert eval!(~s{(buffer-local (current-buffer) 'render-mode)}) == ~s{"html"}
    text = eval!(~s{(buffer-text (current-buffer))})
    assert text =~ "<!doctype html"
    assert text =~ "Hello <b>HTML</b> world"
    assert text =~ "Quarterly report"

    press("v")
    assert eval!(~s{(buffer-local (current-buffer) 'render-mode)}) == "#f"
    # renderer is stubbed to cat, so the text view carries the raw html
    assert eval!(~s{(buffer-text (current-buffer))}) =~ "Hello <b>HTML"

    press("v")
    assert eval!(~s{(buffer-local (current-buffer) 'render-mode)}) == ~s{"html"}
  end

  test "moving the highlight updates the shown mail and marks it read", %{dir: dir} do
    eval!(~s{(set! notmuch-auto-preview #t)})
    eval!(~s{(run-command "notmuch")})
    press("n")
    assert calls(dir) =~ "show --format=json --include-html thread:0002"
    assert calls(dir) =~ "tag -unread -- thread:0002"
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    assert eval!("(length (window-list))") == "2"
    eval!(~s{(set! notmuch-auto-preview #f)})
  end

  test "r in the index replies to the thread's newest message", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("r")
    assert eval!("(current-buffer)") == ~s{"*compose*"}
    assert calls(dir) =~ "search --output=messages --limit=1 -- thread:0001"
    assert eval!(~s{(buffer-text "*compose*")}) =~ "Subject: Re: Hello world"
  end

  test "SPC previews in the other window, focus stays", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("SPC")
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    assert eval!("(length (window-list))") == "2"
    assert calls(dir) =~ "show --format=json --include-html thread:0001"
  end

  test "u smart-untags on a simple tag search", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("u")
    assert calls(dir) =~ "tag -inbox -- thread:0001"
  end

  test "m toggles the mark tag", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("m")
    assert calls(dir) =~ "tag +m -- thread:0001"
  end

  test "@ narrows the search to the sender", %{dir: dir} do
    eval!(~s{(run-command "notmuch")})
    press("@")
    assert calls(dir) =~ "show --format=json --body=false thread:0001"
    assert eval!(~s{(buffer-text "*notmuch*")}) =~ "from:alice@example.com"
  end

  test "the search buffer carries column and status overlays" do
    eval!(~s{(run-command "notmuch")})
    ovs = eval!(~s{(buffer-overlays "*notmuch*")})
    assert ovs =~ "nm-date"
    assert ovs =~ "nm-author"
    # thread 0001 is unread, 0002 is not
    assert ovs =~ "nm-unread"
    assert ovs =~ "nm-subject"
  end

  test "one *mail* buffer is reused; its derived content is transient" do
    eval!(~s{(run-command "notmuch")})
    press("RET")
    assert eval!("(current-buffer)") == ~s{"*mail*"}
    assert eval!(~s{(buffer-text "*mail*")}) =~ "Hi there, this is the body."

    eval!(~s{(begin (switch-to-buffer! "*notmuch*") (goto-char! 0)
                    (next-line!) (next-line!) (beginning-of-line!))})
    press("RET")
    assert eval!(~s{(buffer-text "*mail*")}) =~ "Quarterly report"
    refute eval!(~s{(buffer-text "*mail*")}) =~ "Hi there"

    # exactly one mail view exists, and desktop-save skips its content
    assert eval!(~s{(length (filter (lambda (b) (string-prefix? "*mail" b)) (buffer-list)))}) == "1"
    assert eval!(~s{(buffer-local "*mail*" 'transient)}) == "#t"
    assert eval!(~s{(buffer-local "*notmuch*" 'transient)}) == "#t"
  end

  test "a config-level three-pane scene: index | message | chat" do
    # the scene lives in the user's init.scm — same code, defined here,
    # proving the layout is buildable from config alone
    eval!(~s{(define-command "test-mail-scene" "index | message | chat"
      (lambda ()
        (delete-other-windows!)
        (run-command "notmuch")
        (split-window! 'h 0.32)
        (let ((idx (active-window)))
          (other-window!)
          (split-window! 'h 0.55)
          (other-window!)
          (run-command "chat")
          (select-window! idx)
          (nm--preview! (current-buffer)))))})

    eval!(~s{(run-command "test-mail-scene")})

    assert eval!("(length (window-list))") == "3"
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    bufs = eval!("(map cadr (window-list))")
    assert bufs =~ "*notmuch*"
    assert bufs =~ "*mail*"

    # the chat pane's context carries the index selection and the open mail
    ctx = eval!(~s{(editor-context "*chat*")})
    assert ctx =~ "selected in the mail list"
    assert ctx =~ "open email thread"
  end

  test "M-< and M-> jump to the first and last thread" do
    eval!(~s{(run-command "notmuch")})
    press("M->")
    assert eval!(~s{(nm--thread-at (current-buffer))}) =~ "0002"
    press("M-<")
    assert eval!(~s{(nm--thread-at (current-buffer))}) =~ "0001"
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
