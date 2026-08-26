;;; notmuch-test.scm --- the mail client, against a stub notmuch.
;;;
;;; The test builds its own fixture: a shell script that answers the
;;; queries notmuch would, and the JSON it prints. notmuch-program is a
;;; Scheme seam, so nothing here needs Elixir — write-file! makes the
;;; stub, shell-command->string makes it executable and removes it after.
;;;
;;; Nothing here presses a key. A prompt is answered with
;;; minibuffer-change! and minibuffer-confirm, which is the path a typed
;;; answer takes, and every row verb is a named command.

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

(deftest 'the-index-gives-each-thread-two-lines
  "the subject owns the first line; the author and the tags share the second"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (let* ((lines (string-split (buffer-text "*notmuch*") "\n"))
           (subj (filter (lambda (l) (string-contains? l "Hello world")) lines))
           (auth (filter (lambda (l) (string-contains? l "Alice")) lines)))
      (check-equal! (length subj) 1 "the subject is on one line")
      (check-equal! (length auth) 1 "the author is on another")
      (check-false! (string-contains? (car subj) "Alice") "the two do not share a line")
      (check-contains! (car subj) "Today 06:50" "the date rides with the subject")
      ;; "unread" is six characters, so the column shows it as "unr.."
      (check-contains! (car auth) "inbox unr.." "the tags ride with the author"))
    ;; a row is two lines, and one move is one thread
    (t--nm-run! "notmuch-next")
    (check-equal! (nm--th-subject (nm--thread-at "*notmuch*")) "Quarterly report"
                  "one move goes to the next thread")
    (t--nm-done!)))

(deftest 'every-tag-shows-and-a-long-one-keeps-three-letters
  "which tags a thread carries is what the column is for"
  (lambda ()
    (check-equal! (nm--short-tag "attachment") "att.." "a long tag keeps three letters")
    (check-equal! (nm--short-tag "inbox") "inbox" "five characters still fit")
    (check-equal! (nm--short-tag "sent") "sent" "and a short one is itself")
    (let ((tags '("attachment" "important" "inbox" "personal" "sent")))
      (check-equal! (nm--tags-text (list "0001" "s" "a" tags "d"))
                    "att.. imp.. inbox per.. sent"
                    "every tag reads, none of them goes")
      ;; the column takes what the busiest row needs
      (check-equal! (nm--fit-tags "att.. imp.. inbox per.. sent" 28)
                    "att.. imp.. inbox per.. sent"
                    "the short forms stand when the column holds them")
      ;; too narrow even for those: one letter each, and the count reads
      (check-equal! (nm--fit-tags "attachment important inbox personal sent" 6)
                    "aiips" "no room: the initials, all five of them"))
    (check-equal! (nm--fit-tags "" 24) "" "no tags, no text")))

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
    (t--nm-run! "notmuch-next")
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


;;; --- the prompts ----------------------------------------------------------------

(define (t--nm-answer! text)
  (minibuffer-change! text)
  (run-command "minibuffer-confirm"))

(deftest 'jump-goes-to-a-saved-search-by-name
  "the mailbox names are the completion set"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-jump")
    (t--nm-answer! "unread")
    (check-equal! (nm--query-of "*notmuch*") "tag:unread" "the saved search opened")
    (t--nm-done!)))

(deftest 'filter-narrows-the-current-search
  "the base query and the filter stack, never a derived string"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    ;; the old derived local cannot bypass the base and filter stack
    (buffer-set-local! "*notmuch*" 'notmuch-query "from:bob")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox" "the local is ignored")

    (run-command "notmuch-filter")
    (t--nm-answer! "from:alice")
    (check-equal! (nm--query-of "*notmuch*") "( tag:inbox ) and from:alice"
                  "the filter rides on the base")
    (t--nm-done!)))

(deftest 'tag-filter-menu-adds-a-filter-inside-the-inbox
  "the menu offers tags from the current result and preserves the inbox base"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-filter-by-tag")
    (check-equal! (minibuffer-selected) "important"
                  "the menu contains a tag from the inbox result")
    (t--nm-answer! "unread")
    (check-equal! (nm--query-of "*notmuch*") "( tag:inbox ) and tag:unread"
                  "the selected tag narrows the inbox")

    (run-command "notmuch-unfilter-last")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox"
                  "removing the filter restores the inbox")
    (t--nm-done!)))

(deftest 'add-tag-completes-from-the-database
  "the tags come from notmuch, not from a list we keep"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-add-tag")
    (t--nm-answer! "important")
    (let ((log (t--nm-calls)))
      (check-contains! log "search --output=tags" "it asked the database")
      (check-contains! log "tag +important -- thread:0001" "and tagged the thread"))
    (t--nm-done!)))

(deftest 'structured-filters-are-removed-without-parsing-query-text
  "the stack is data, so a pop needs no parser"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-search")
    (t--nm-answer! "tag:inbox and from:alice")
    (run-command "notmuch-filter")
    (t--nm-answer! "subject:report")
    (check-equal! (nm--query-of "*notmuch*") "( tag:inbox and from:alice ) and subject:report"
                  "the filter rides on the search")

    (run-command "notmuch-unfilter-last")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox and from:alice"
                  "and popping leaves the search alone")
    (t--nm-done!)))

(deftest 'replacement-filters-are-removed-in-order
  "by-sender and by-marked replace each other; backslash walks back"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-filter-by-sender")
    (check-contains! (t--nm-calls) "show --format=json --body=false thread:0001"
                     "it read the sender off the thread")
    (check-equal! (length (list-entries "*notmuch*")) 1 "one row matches")
    (check-equal! (nm--query-of "*notmuch*") "from:alice@example.com" "the sender filter")

    (run-command "notmuch-filter-marked")
    (check-equal! (nm--query-of "*notmuch*") "tag:m" "the marked filter replaced it")

    (run-command "notmuch-unfilter-last")
    (check-equal! (nm--query-of "*notmuch*") "from:alice@example.com" "and back to the sender")
    (run-command "notmuch-unfilter-last")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox" "and back to the mailbox")
    (check-equal! (length (list-entries "*notmuch*")) 2 "with every row again")
    (t--nm-done!)))

(deftest 'opening-a-mailbox-refreshes-rows-cached-by-a-filter
  "the cached rows are the filter's, not the mailbox's"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-filter-by-sender")
    (check-equal! (length (list-entries "*notmuch*")) 1 "the filter cut the rows")

    (run-command "notmuch")
    (run-command "notmuch-hello-open")
    (check-equal! (nm--query-of "*notmuch*") "tag:inbox" "the mailbox query is back")
    (check-equal! (length (list-entries "*notmuch*")) 2 "and all its rows")
    (t--nm-done!)))

(deftest 'mark-all-then-archive-marked-asks-before-it-acts
  "a bulk change over a whole query takes a confirmation"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-mark-all")
    (check-contains! (t--nm-calls) "tag +m -- ( tag:inbox )" "every thread in the query is marked")

    (run-command "notmuch-archive-marked")
    (t--nm-answer! "yes")
    (check-contains! (t--nm-calls) "tag -inbox -m -- ( tag:inbox ) and tag:m"
                     "and the archive names the marked set")
    (t--nm-done!)))

(deftest 'embark-acts-on-the-email-at-point
  "the target is the row, and the act tool drives the same table"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (let ((target (value->string (target-at "*notmuch*"))))
      (check-contains! target "email" "the target is an email")
      (check-contains! target "0001" "and names the thread"))

    (run-command "embark-act")
    (t--nm-answer! "archive")
    (check-contains! (t--nm-calls) "tag -inbox -- thread:0001" "the action ran")

    ;; the tool reports what the ACTION did, never a blind "done" — a model
    ;; told an archive succeeded when it did not will keep going
    (let ((out (llm-tool-call "act" (list 'type "email" 'id "thread:0002" 'action "trash"))))
      (check-contains! out "0002" "it names the thread")
      (check-contains! out "+trash -inbox -unread" "and the tags it set"))
    (check-contains! (t--nm-calls) "tag +trash -inbox -unread -- thread:0002" "which really ran")

    (check-contains! (llm-tool-call "act" (list 'type "email" 'id "no-such-thread" 'action "trash"))
                     "no such thread" "a thread that is not there says so")
    (let ((out (llm-tool-call "act" (list 'type "email" 'id "0002" 'action "explode"))))
      (check-contains! out "no such action" "and an action that is not there")
      (check-contains! out "archive" "naming the ones there are"))
    (t--nm-done!)))

;;; --- the two-pane reading flow ---------------------------------------------------

(deftest 'preview-opens-the-other-window-and-keeps-the-focus
  "reading down a list must not move the point out of it"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-preview")
    (check-equal! (current-buffer) "*notmuch*" "focus stayed on the list")
    (check-equal! (length (window-list)) 2 "and the preview opened beside it")
    (check-contains! (t--nm-calls) "show --format=json --include-html thread:0001" "the fetch")
    (t--nm-done!)))

(deftest 'a-scene-role-routes-open-to-show-without-evicting-chat
  "index, show and chat are semantic panes, not positions guessed by a command"
  (lambda ()
    (t--nm-setup!)
    (define-scene! "zz-nm-role-scene"
      '(h 0.32 (as index (ensure "*notmuch*" "notmuch-inbox"))
               (as show (ensure "*mail*" "notmuch-show-current"))
               (as chat group-chat)))
    (scene-open! "zz-nm-role-scene")
    (let* ((id (group-resolve-id "zz-nm-role-scene"))
           (index-window (group-window-as id 'index))
           (show-window (group-window-as id 'show))
           (chat-window (group-window-as id 'chat))
           (chat (group-buffer-as id 'chat)))
      (check-equal! (window-buffer index-window) "*notmuch*" "index names the inbox pane")
      (check-equal! (window-buffer show-window) "*mail*" "show names the message pane")
      (check-equal! (window-buffer chat-window) chat "chat names the companion pane")
      (select-window! index-window)
      (run-command "notmuch-open-thread")
      (check-equal! (active-window) index-window "open kept focus in the index")
      (check-equal! (window-buffer index-window) "*notmuch*" "the index stayed put")
      (check-contains! (buffer-text "*mail*") "Hi there" "the show pane opened the mail")
      (check-equal! (window-buffer chat-window) chat "the chat stayed put")
      (group-dissolve! id))
    (set! *scenes*
      (remove (lambda (entry) (equal? (car entry) "zz-nm-role-scene")) *scenes*))
    (t--nm-done!)))

(deftest 'moving-the-highlight-updates-the-shown-mail-and-marks-it-read
  "with auto-preview on, the next row is fetched and read"
  (lambda ()
    (t--nm-setup!)
    (let ((saved notmuch-auto-preview))
      (set! notmuch-auto-preview #t)
      (run-command "notmuch-inbox")
      (run-command "notmuch-next")
      (let ((log (t--nm-calls)))
        (check-contains! log "show --format=json --include-html thread:0002" "the second thread")
        (check-contains! log "tag -unread -- thread:0002" "and it was marked read"))
      (check-equal! (current-buffer) "*notmuch*" "focus stayed on the list")
      (check-equal! (length (window-list)) 2 "the preview is beside it")
      (set! notmuch-auto-preview saved))
    (t--nm-done!)))

;;; --- composing a reply -----------------------------------------------------------

(deftest 'reply-is-a-message-mode-buffer-that-sends
  "headers, a separator, the quote, and point on the body"
  (lambda ()
    (t--nm-setup!)
    (run-command "notmuch-inbox")
    (run-command "notmuch-open-thread")
    ;; the message view has its own reply: the index replies to the
    ;; thread's newest message, this one to the message on screen
    (run-command "notmuch-show-reply")
    (check-equal! (current-buffer) "*compose*" "a compose buffer")

    (let ((text (buffer-text "*compose*")))
      (check-contains! text "From: SVS <svs@svsrecruiting.com>" "the From header")
      (check-contains! text "To: Alice <alice@example.com>" "the To header")
      (check-contains! text "Subject: Re: Hello world" "the Subject")
      (check-contains! text "In-Reply-To: <m1>" "the In-Reply-To")
      (check-contains! text "--text follows this line--" "the separator")
      (check-contains! text "Alice <alice@example.com> writes:" "the attribution")
      (check-contains! text "> Hi there, this is the body." "and the quote"))
    (check-contains! (t--nm-calls) "reply --format=json id:" "it asked notmuch for the reply")

    ;; point sits on the empty line right after the separator
    (check-contains! (substring-bytes (buffer-text "*compose*") 0
                                      (with-current-buffer "*compose*" (lambda () (point))))
                     "line--\n" "point is past the separator")

    ;; header names and the separator carry faces
    (let ((faces (value->string (buffer-overlays "*compose*"))))
      (check-contains! faces "nm-hdr" "the header face")
      (check-contains! faces "nm-sep" "and the separator face"))

    ;; sending turns the separator into the RFC822 blank line
    (let ((sent (string-append t--nm-dir "/sent.eml"))
          (saved notmuch-send-routes))
      (set! notmuch-send-routes (list (list "" (string-append "cat > " sent))))
      (with-current-buffer "*compose*" (lambda () (run-command "mail-send")))
      (let ((body (or (read-file sent) "")))
        (check-false! (string-contains? body "text follows this line") "the separator is gone")
        (check-contains! body "Subject: Re: Hello world" "the headers survived")
        (check-contains! body "References: <m1>\n\n" "and a blank line divides them"))
      (set! notmuch-send-routes saved))
    (t--nm-done!)))
