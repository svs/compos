defmodule Aimax.NotmuchTest do
  @moduledoc """
  The notmuch tests that need a prompt or a second window.

  The client itself — the listing, the row verbs, the mail view, the
  context providers and the mail functions — is Scheme and lives in
  priv/tests/notmuch-test.scm, which builds the same stub from Scheme.

  Nine of these drive the minibuffer: a saved-search name, a filter query,
  a tag, a confirmation. Two assert the two-pane layout, and how a window
  splits depends on the frame.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

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

  @sender_search_json ~S"""
  [{"thread": "0001", "timestamp": 1786065644, "date_relative": "Today 06:50", "matched": 1, "total": 1, "authors": "Alice", "subject": "Hello world", "query": ["id:m1", null], "tags": ["inbox", "unread"]}]
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
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "search.json"), @search_json)
    File.write!(Path.join(dir, "sender-search.json"), @sender_search_json)
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
          *thread:{from:alice@example.com}*) printf '[]\n';;
          *from:alice@example.com*) cat "$dir/sender-search.json";;
          *--output=messages*) echo "id:m1";;
          *--output=tags*) printf 'important\ninbox\nunread\n';;
          *) cat "$dir/search.json";;
        esac;;
      show)
        case "$*" in
          *thread:0002*) cat "$dir/show-html.json";;
          *) cat "$dir/show.json";;
        esac;;
      reply) cat "$dir/reply.json";;
      config) printf 'query.inbox.query=tag:inbox\nquery.unread.query=tag:unread\n';;
      # two different shapes: `count --batch` reads queries on stdin and
      # answers one line each (the mailbox list), while a plain `count`
      # must NOT touch stdin — draining a pipe nobody writes to blocks
      # forever and wedges the Session for every later eval.
      count)
        case "$*" in
          *--batch*)
            while read -r q; do
              case "$q" in *unread*) printf '2\n';; *) printf '5\n';; esac
            done;;
          *no-such*) printf '0\n';;
          *) printf '5\n';;
        esac;;
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

  test "reply is a message-mode buffer: headers, separator, quote, point at body", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})
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


  test "moving the highlight updates the shown mail and marks it read", %{dir: dir} do
    eval!(~s{(set! notmuch-auto-preview #t)})
    eval!(~s{(run-command "notmuch-inbox")})
    press("n")
    assert calls(dir) =~ "show --format=json --include-html thread:0002"
    assert calls(dir) =~ "tag -unread -- thread:0002"
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    assert eval!("(length (window-list))") == "2"
    eval!(~s{(set! notmuch-auto-preview #f)})
  end


  test "SPC previews in the other window, focus stays", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})
    press("SPC")
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    assert eval!("(length (window-list))") == "2"
    assert calls(dir) =~ "show --format=json --include-html thread:0001"
  end


  test "* marks every thread in the search", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})
    assert eval!("(current-buffer)") == ~s{"*notmuch*"}
    press("*")
    echo = Editor.snapshot().echo
    assert calls(dir) =~ "tag +m -- ( tag:inbox )", "echo was: #{inspect(echo)}"

    # the bulk flow: archive everything marked, with confirmation
    press("A")
    Enum.each(String.graphemes("yes"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")
    assert calls(dir) =~ "tag -inbox -m -- ( tag:inbox ) and tag:m"
  end


  test "@ and F push replacement filters that backslash removes in order", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})
    press("@")
    assert calls(dir) =~ "show --format=json --body=false thread:0001"
    assert eval!(~s{(length (list-entries "*notmuch*"))}) == "1"

    assert eval!(~s{(nm--query-of "*notmuch*")}) ==
             ~s{"from:alice@example.com"}

    press("F")

    assert eval!(~s{(nm--query-of "*notmuch*")}) == ~s{"tag:m"}

    press("\\")

    assert eval!(~s{(nm--query-of "*notmuch*")}) ==
             ~s{"from:alice@example.com"}

    press("\\")
    assert eval!(~s{(nm--query-of "*notmuch*")}) == ~s{"tag:inbox"}
    assert eval!(~s{(length (list-entries "*notmuch*"))}) == "2"
  end


  test "opening a mailbox refreshes rows cached by a filter" do
    eval!(~s{(run-command "notmuch-inbox")})
    press("@")
    assert eval!(~s{(length (list-entries "*notmuch*"))}) == "1"

    press("q")
    press("RET")
    assert eval!(~s{(nm--query-of "*notmuch*")}) == ~s{"tag:inbox"}
    assert eval!(~s{(length (list-entries "*notmuch*"))}) == "2"
  end


  test "j jumps to a saved search by name", %{dir: _} do
    eval!(~s{(run-command "notmuch-inbox")})
    press("j")
    type("unread")
    press("RET")
    assert eval!(~s{(nm--query-of "*notmuch*")}) == ~s{"tag:unread"}
  end


  test "/ narrows the current search", %{dir: _} do
    eval!(~s{(run-command "notmuch-inbox")})
    # The old derived local cannot bypass the base and filter stack.
    eval!(~s{(buffer-set-local! "*notmuch*" 'notmuch-query "from:bob")})
    assert eval!(~s{(nm--query-of "*notmuch*")}) == ~s{"tag:inbox"}

    press("/")
    type("from:alice")
    press("RET")

    assert eval!(~s{(nm--query-of "*notmuch*")}) ==
             ~s{"( tag:inbox ) and from:alice"}
  end


  test "+ adds a tag with completion from the database", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})
    press("+")
    type("important")
    press("RET")
    assert calls(dir) =~ "search --output=tags"
    assert calls(dir) =~ "tag +important -- thread:0001"
  end


  test "C-. acts on the email at point; the act tool drives the same table", %{dir: dir} do
    eval!(~s{(run-command "notmuch-inbox")})

    assert eval!(~s{(target-at "*notmuch*")}) =~ "email"
    assert eval!(~s{(target-at "*notmuch*")}) =~ "0001"

    press("C-.")
    Enum.each(String.graphemes("archive"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")
    assert calls(dir) =~ "tag -inbox -- thread:0001"

    # the tool reports what the ACTION did, never a blind "done" — a model
    # that is told an archive succeeded when it didn't will keep going
    out = eval!(~s{(llm-tool-call "act" (list 'type "email" 'id "thread:0002" 'action "trash"))})
    assert out =~ "0002"
    assert out =~ "+trash -inbox -unread"
    assert calls(dir) =~ "tag +trash -inbox -unread -- thread:0002"

    # a thread that isn't there says so, instead of claiming success
    out = eval!(~s{(llm-tool-call "act" (list 'type "email" 'id "no-such-thread" 'action "trash"))})
    assert out =~ "no such thread"

    out = eval!(~s{(llm-tool-call "act" (list 'type "email" 'id "0002" 'action "explode"))})
    assert out =~ "no such action"
    assert out =~ "archive"
  end


  test "structured filters can be removed without parsing query text", %{dir: _} do
    eval!(~s{(run-command "notmuch-inbox")})
    press("s")
    type("tag:inbox and from:alice")
    press("RET")
    press("/")
    type("subject:report")
    press("RET")

    assert eval!(~s{(nm--query-of "*notmuch*")}) ==
             ~s{"( tag:inbox and from:alice ) and subject:report"}

    press("\\")

    assert eval!(~s{(nm--query-of "*notmuch*")}) ==
             ~s{"tag:inbox and from:alice"}
  end

end
