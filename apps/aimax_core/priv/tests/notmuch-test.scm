;;; notmuch-test.scm --- the mail client, against a stub notmuch.
;;;
;;; The test builds its own fixture: a shell script that answers the
;;; queries notmuch would, and the JSON it prints. notmuch-program is a
;;; Scheme seam, so nothing here needs Elixir — write-file! makes the
;;; stub, shell-command->string makes it executable and removes it after.
;;;
;;; Eleven tests stay in ExUnit. Nine drive a PROMPT: typing a saved-search
;;; name, a filter query, a tag, or answering a confirmation — dispatch,
;;; and the minibuffer is the path the GUI uses. Two assert the two-pane
;;; layout, and how a window splits depends on the frame: in a live editor
;;; notmuch-preview reuses the window this suite runs in.

(domain! 'testing)
(effects! '(write))

;; *notmuch*, *mail*, *mailboxes* and *compose* are the package's own
;; names, in a test and in a person's editor alike. The setup below resets
;; them, so this file must never run against a live one: it already cost
;; somebody their open mail and the chat beside it.
(tests-need-a-disposable-editor!
  "resets *notmuch*, *mail*, *mailboxes* and *compose*, which a live editor is using")

(define t--nm-dir (string-append (aimax-home) "/zz-nm-stub"))
(define t--nm-program (string-append t--nm-dir "/notmuch"))

;; the JSON the stub prints, and the script that chooses between them
(define t--nm-files
  (list
    (list "search.json" "  [{\"thread\": \"0001\", \"timestamp\": 1786065644, \"date_relative\": \"Today 06:50\", \"matched\": 1, \"total\": 1, \"authors\": \"Alice\", \"subject\": \"Hello world\", \"query\": [\"id:m1\", null], \"tags\": [\"inbox\", \"unread\"]},\n  {\"thread\": \"0002\", \"timestamp\": 1786037671, \"date_relative\": \"Yest. 23:04\", \"matched\": 1, \"total\": 2, \"authors\": \"Bob| Carol\", \"subject\": \"Quarterly report\", \"query\": [\"id:m2\", \"id:m3\"], \"tags\": [\"inbox\"]}]")
    (list "sender-search.json" "  [{\"thread\": \"0001\", \"timestamp\": 1786065644, \"date_relative\": \"Today 06:50\", \"matched\": 1, \"total\": 1, \"authors\": \"Alice\", \"subject\": \"Hello world\", \"query\": [\"id:m1\", null], \"tags\": [\"inbox\", \"unread\"]}]")
    (list "show.json" "  [[[{\"id\": \"m1\", \"match\": true, \"excluded\": false, \"filename\": [\"/Users/svs/Mail/svsrecruiting/mail/cur/abc:2,S\"], \"timestamp\": 1786065644, \"date_relative\": \"Today 06:50\", \"tags\": [\"inbox\", \"unread\"], \"duplicate\": 1, \"body\": [{\"id\": 1, \"content-type\": \"multipart/alternative\", \"content\": [{\"id\": 2, \"content-type\": \"text/plain\", \"content\": \"Hi there, this is the body.\\n\"}, {\"id\": 3, \"content-type\": \"text/html\", \"content-charset\": \"utf-8\", \"content-length\": 100}]}], \"headers\": {\"Subject\": \"Hello world\", \"From\": \"Alice <alice@example.com>\", \"To\": \"svs@svsrecruiting.com\", \"Date\": \"Thu, 07 Aug 2026 06:50:44 +0530\"}}, []]]]")
    (list "show-html.json" "  [[[{\"id\": \"m2\", \"match\": true, \"excluded\": false, \"filename\": [\"/Users/svs/Mail/svsrecruiting/mail/cur/def:2,S\"], \"timestamp\": 1786037671, \"date_relative\": \"Yest. 23:04\", \"tags\": [\"inbox\"], \"duplicate\": 1, \"body\": [{\"id\": 1, \"content-type\": \"text/html\", \"content\": \"<p>Hello <b>HTML</b> world</p>\"}], \"headers\": {\"Subject\": \"Quarterly report\", \"From\": \"Bob <bob@example.com>\", \"To\": \"svs@svsrecruiting.com\", \"Date\": \"Wed, 06 Aug 2026 23:04:31 +0530\"}}, []]]]")
    (list "reply.json" "  {\"reply-headers\": {\"Subject\": \"Re: Hello world\", \"From\": \"SVS <svs@svsrecruiting.com>\", \"To\": \"Alice <alice@example.com>\", \"In-reply-to\": \"<m1>\", \"References\": \"<m1>\"}, \"original\": {\"id\": \"m1\", \"match\": false, \"excluded\": false, \"filename\": [\"/Users/svs/Mail/svsrecruiting/mail/cur/abc:2,S\"], \"timestamp\": 1786065644, \"date_relative\": \"Today 06:50\", \"tags\": [\"inbox\"], \"body\": [{\"id\": 1, \"content-type\": \"multipart/alternative\", \"content\": [{\"id\": 2, \"content-type\": \"text/plain\", \"content\": \"Hi there, this is the body.\\n\"}, {\"id\": 3, \"content-type\": \"text/html\", \"content-length\": 100}]}], \"headers\": {\"Subject\": \"Hello world\", \"From\": \"Alice <alice@example.com>\", \"To\": \"svs@svsrecruiting.com\", \"Date\": \"Thu, 07 Aug 2026 06:50:44 +0530\"}}}")))

(define t--nm-script "#!/bin/sh\ndir=\"$(dirname \"$0\")\"\necho \"$@\" >> \"$dir/calls.log\"\ncase \"$1\" in\n  search)\n    case \"$*\" in\n      *thread:{from:alice@example.com}*) printf '[]\\n';;\n      *from:alice@example.com*) cat \"$dir/sender-search.json\";;\n      *--output=messages*) echo \"id:m1\";;\n      *--output=tags*) printf 'important\\ninbox\\nunread\\n';;\n      *) cat \"$dir/search.json\";;\n    esac;;\n  show)\n    case \"$*\" in\n      *thread:0002*) cat \"$dir/show-html.json\";;\n      *) cat \"$dir/show.json\";;\n    esac;;\n  reply) cat \"$dir/reply.json\";;\n  config) printf 'query.inbox.query=tag:inbox\\nquery.unread.query=tag:unread\\n';;\n  # two different shapes: `count --batch` reads queries on stdin and\n  # answers one line each (the mailbox list), while a plain `count`\n  # must NOT touch stdin — draining a pipe nobody writes to blocks\n  # forever and wedges the Session for every later eval.\n  count)\n    case \"$*\" in\n      *--batch*)\n        while read -r q; do\n          case \"$q\" in *unread*) printf '2\\n';; *) printf '5\\n';; esac\n        done;;\n      *no-such*) printf '0\\n';;\n      *) printf '5\\n';;\n    esac;;\nesac")

;; Every test starts from a clean stub and a clean editor: the call log is
;; what most of them read, and a stale one answers for the wrong test.
(define (t--nm-setup!)
  (shell-command->string (string-append "rm -rf " t--nm-dir))
  (make-directory! t--nm-dir)
  (for-each (lambda (f) (write-file! (string-append t--nm-dir "/" (car f)) (cadr f)))
            t--nm-files)
  (write-file! t--nm-program t--nm-script)
  (shell-command->string (string-append "chmod +x " t--nm-program))
  (set! notmuch-program t--nm-program)
  (set! notmuch-auto-preview #f)
  (set! notmuch-html-renderer "cat")
  (switch-to-buffer! "*scratch*")
  (for-each (lambda (b)
              (when (or (equal? b "*notmuch*")
                        (string-prefix? "*mail" b)
                        (equal? b "*compose*"))
                (buffer-kill! b)))
            (buffer-list))
  ;; the suite runs in a live editor, whose frame may already be split;
  ;; the window assertions below count what these commands opened
  (delete-other-windows!)
  t--nm-dir)

(define (t--nm-calls) (or (read-file (string-append t--nm-dir "/calls.log")) ""))

(define (t--nm-done!)
  (for-each (lambda (b)
              (when (or (equal? b "*notmuch*") (equal? b "*mailboxes*")
                        (string-prefix? "*mail" b) (equal? b "*compose*"))
                (buffer-kill! b)))
            (buffer-list))
  (shell-command->string (string-append "rm -rf " t--nm-dir)))

;; The row verbs, by the command each key runs. NOT wrapped in
;; with-current-buffer: that restores the buffer when the thunk exits, and
;; half of these commands are meant to leave you somewhere else.
(define (t--nm-run! cmd) (run-command cmd))

;;; --- the search listing --------------------------------------------------------

(deftest 'notmuch-opens-a-search-listing-of-threads
  "the query, the count, and one row per thread"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (check-equal! (current-buffer) "*notmuch*" "the listing is current")
    (let ((text (buffer-text "*notmuch*")))
      (check-contains! text "Mail" "the title")
      (check-contains! text "2 threads · tag:inbox" "the count and the query")
      (check-contains! text "Hello world" "the first subject")
      (check-contains! text "Quarterly report" "the second")
      (check-contains! text "Alice" "and an author"))
    (t--nm-done!)))

(deftest 'the-search-buffer-carries-column-and-status-overlays
  "the columns are faces, so a theme can move them"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (let ((faces (value->string (buffer-overlays "*notmuch*"))))
      (check-contains! faces "nm-date" "the date column")
      (check-contains! faces "nm-author" "the author column")
      (check-contains! faces "nm-subject" "the subject column")
      ;; thread 0001 is unread, 0002 is not
      (check-contains! faces "nm-unread" "and the unread mark"))
    (t--nm-done!)))

(deftest 'opening-a-thread-renders-text-plain-only-and-marks-it-read
  "the HTML alternative is not the one a reader wants"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-open-thread")
    (check-equal! (current-buffer) "*mail*" "the mail view is current")
    (let ((text (buffer-text (current-buffer))))
      (check-contains! text "From: Alice <alice@example.com>" "the header")
      (check-contains! text "Hi there, this is the body." "the text/plain body")
      (check-false! (string-contains? text "content-length") "and not the html part"))
    (let ((log (t--nm-calls)))
      (check-contains! log "show --format=json" "it asked for the thread")
      (check-contains! log "tag -unread -- thread:0001" "and marked it read"))
    (t--nm-done!)))

(deftest 'an-html-message-renders-as-an-html-document-and-toggles-to-text
  "a message with no text/plain is shown as the document it is"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (next-line!)
    (beginning-of-line!)
    (t--nm-run! "notmuch-open-thread")

    (check-equal! (current-buffer) "*mail*" "the mail view is current")
    (check-equal! (buffer-local (current-buffer) 'render-mode) "html" "rendered as html")
    (let ((text (buffer-text (current-buffer))))
      (check-contains! text "<!doctype html" "a whole document")
      (check-contains! text "Hello <b>HTML</b> world" "with the body")
      (check-contains! text "Quarterly report" "and the subject"))

    (t--nm-run! "notmuch-show-toggle-view")
    (check-false! (buffer-local (current-buffer) 'render-mode) "the toggle drops to text")
    ;; the renderer is stubbed to cat, so the text view carries the raw html
    (check-contains! (buffer-text (current-buffer)) "Hello <b>HTML" "which is the raw html here")

    (t--nm-run! "notmuch-show-toggle-view")
    (check-equal! (buffer-local (current-buffer) 'render-mode) "html" "and back again")
    (t--nm-done!)))

(deftest 'one-mail-buffer-is-reused-and-its-content-is-transient
  "the mail view is derived, so the desktop saves the query and not the text"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-open-thread")
    (check-contains! (buffer-text "*mail*") "Hi there, this is the body." "the first thread")

    (switch-to-buffer! "*notmuch*")
    (list-goto-first-entry "*notmuch*")
    (t--nm-run! "notmuch-next")
    (t--nm-run! "notmuch-open-thread")
    (check-contains! (buffer-text "*mail*") "Quarterly report" "the second thread")
    (check-false! (string-contains? (buffer-text "*mail*") "Hi there") "and not the first")

    (check-equal! (length (filter (lambda (b) (string-prefix? "*mail" b)) (buffer-list))) 1
                  "exactly one mail view")
    (check-true! (buffer-local "*mail*" 'transient) "the mail view is transient")
    (check-true! (buffer-local "*notmuch*" 'transient) "and so is the listing")
    (t--nm-done!)))

(deftest 'the-search-buffer-survives-a-mode-re-setup
  "the desktop restore path: set-mode! again with the locals already down"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (with-current-buffer "*notmuch*" (lambda () (set-mode! "notmuch-mode")))
    (check-contains! (buffer-text "*notmuch*") "Hello world" "the rows came back")
    (switch-to-buffer! "*notmuch*")
    (t--nm-run! "notmuch-open-thread")
    (check-equal! (current-buffer) "*mail*" "and the verbs still work")
    (t--nm-done!)))

;;; --- the row verbs -------------------------------------------------------------

(deftest 'archive-tags-the-thread-at-point
  "one row, one thread, one tag change"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-archive")
    (check-contains! (t--nm-calls) "tag -inbox -- thread:0001" "the archive call")
    (t--nm-done!)))

(deftest 'smart-untag-removes-the-tag-the-search-is-on
  "on a simple tag search, u means -that-tag"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-smart-untag")
    (check-contains! (t--nm-calls) "tag -inbox -- thread:0001" "the untag call")
    (t--nm-done!)))

(deftest 'mark-toggles-the-mark-tag
  "the mark is a tag, so it survives a refresh"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-mark-toggle")
    (check-contains! (t--nm-calls) "tag +m -- thread:0001" "the mark call")
    (t--nm-done!)))

(deftest 'reply-composes-from-the-threads-newest-message
  "the index replies to the thread, not to whatever is open"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-reply")
    (check-equal! (current-buffer) "*compose*" "a compose buffer")
    (check-contains! (t--nm-calls) "search --output=messages --limit=1 -- thread:0001"
                     "it asked for the newest message")
    (check-contains! (buffer-text "*compose*") "Subject: Re: Hello world" "with the reply headers")
    (t--nm-done!)))

(deftest 'first-and-last-thread-jump-to-the-ends-of-the-list
  "the ends are rows, not buffer positions"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (t--nm-run! "notmuch-last-thread")
    (check-equal! (car (nm--thread-at (current-buffer))) "0002" "the last thread")
    (t--nm-run! "notmuch-first-thread")
    (check-equal! (car (nm--thread-at (current-buffer))) "0001" "and the first")
    (t--nm-done!)))

;;; --- the mailboxes and quitting -------------------------------------------------

(deftest 'notmuch-starts-at-the-mailboxes-and-a-row-opens-its-search
  "the counts come from one batched call, not one per mailbox"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch")
    (check-equal! (current-buffer) "*mailboxes*" "the mailbox list")
    (let ((text (buffer-text "*mailboxes*")))
      (check-contains! text "Mailboxes" "the title")
      (check-contains! text "inbox" "a mailbox")
      (check-contains! text "5" "and its count"))
    (check-contains! (t--nm-calls) "count --batch" "one batched count")

    (t--nm-run! "notmuch-hello-open")
    (check-equal! (current-buffer) "*notmuch*" "the row opened its search")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox" "on that mailbox's query")

    (t--nm-run! "notmuch")
    (check-equal! (current-buffer) "*mailboxes*" "and back to the mailboxes")
    (t--nm-done!)))

(deftest 'notmuch-quit-kills-the-mail-views-and-lands-on-work
  "leaving mail returns you to what you were doing"
  (lambda ()
    (t--nm-setup!)
    (let ((work (string-append (aimax-home) "/zz-nm-work.txt")))
      (write-file! work "work\n")
      (visit work)
      (run-command "notmuch")
      (run-command "notmuch-inbox")
      (t--nm-run! "notmuch-open-thread")

      (run-command "notmuch-quit")
      (check-false! (buffer-exists? "*notmuch*") "the listing is gone")
      (check-false! (buffer-exists? "*mailboxes*") "the mailboxes are gone")
      (check-false! (buffer-exists? "*mail*") "the mail view is gone")
      (check-equal! (current-buffer) work "and the work buffer is current")

      (when (buffer-known? work) (buffer-kill! work))
      (delete-file! work))
    (t--nm-done!)))

;;; --- what a chat is told --------------------------------------------------------

(deftest 'context-providers-explain-the-selection-to-chat-and-agents
  "the list says what is selected; the thread view says what is open"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")

    (let ((ctx (editor-context "*zz-nm-chat*")))
      (check-contains! ctx "Hello world" "the selected subject")
      (check-contains! ctx "thread:0001" "and its id"))
    (check-contains! (editor-context-preamble "*zz-nm-chat*") "Editor context" "the preamble")

    (t--nm-run! "notmuch-open-thread")
    (let ((ctx (editor-context "*zz-nm-chat*")))
      (check-contains! ctx "thread:0001" "the open thread")
      (check-contains! ctx "id:m1" "and the message in it"))

    ;; a buffer with no provider contributes nothing
    (switch-to-buffer! "*scratch*")
    (check-equal! (editor-context-preamble "*zz-nm-chat*") "" "no provider, no preamble")
    (t--nm-done!)))

(deftest 'the-provider-reads-the-list-buffers-own-point
  "not the current buffer's, which may sit far past the end of the list"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")

    ;; agent-send's path: the CURRENT buffer is the chat, and its point
    ;; sits past the end of the small list buffer. line-index-at must
    ;; slice *notmuch* with *notmuch*'s point, or substring-bytes throws.
    (test-buffer! "*zz-nm-big-chat*" "")
    (buffer-append! "*zz-nm-big-chat*" (string-repeat "x" 100000))
    (switch-to-buffer! "*zz-nm-big-chat*")
    (end-of-buffer!)

    (check-contains! (buffer-context "*notmuch*") "thread:0001" "the list's own row")
    (buffer-kill! "*zz-nm-big-chat*")
    (t--nm-done!)))

;;; --- the eval-scheme surface ----------------------------------------------------

(deftest 'the-mail-functions-search-and-read-through-the-same-renderer
  "what an agent calls is what the buffers show"
  (lambda ()
    (t--nm-setup!)
    (let ((out (mail-search "tag:inbox")))
      (check-contains! out "thread:0001" "the thread id")
      (check-contains! out "Hello world" "the subject")
      (check-contains! out "Alice" "and the author"))
    (check-contains! (mail-read-thread "thread:0001") "Hi there, this is the body." "the body")
    (let ((out (mail-tag! "0002" "+important")))
      (check-contains! out "tagged" "it reports the change")
      (check-contains! out "0002" "on the thread")
      (check-contains! out "+important" "with the tag"))
    (t--nm-done!)))
