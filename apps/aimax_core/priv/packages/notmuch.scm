;;; notmuch.scm --- email client over the notmuch CLI, userland Scheme.
;;;
;;; No Elixir knows what email is. Sync is external (lieer/mbsync cron);
;;; this package reads the local database with `notmuch ... --format=json`,
;;; renders search and thread buffers, tags, replies, and sends. The
;;; extensibility bar, same as dired: primitives + shell + json-parse.
;;;
;;; HTML first — we are in a browser. When a message carries a text/html
;;; part the thread buffer becomes an HTML document rendered by the UI's
;;; sandboxed iframe (render-mode "html" + preview-authored); v toggles the
;;; text view. Tools always read text, through notmuch-html-renderer when
;;; a message has no text/plain part.
;;;
;;; Search buffer keys (ported from the user's Emacs config):
;;;   n/p next/prev (n marks read; both auto-preview) · RET open · SPC preview
;;;   a archive · d trash · u smart-untag · . toggle unread · @ by sender
;;;   m mark+advance · M mark all · U unmark all · F show marked
;;;   A archive marked · D trash marked · t tag marked · T tag this thread
;;;   / add a tag filter · \ remove the last filter · l raw filter
;;;   s new search · g refresh · q quit
;;; Thread buffer keys:  v html/text view · a archive · r reply · q quit
;;; Compose buffer keys: C-c C-c send · C-c C-k abort
;;;
;;; Chat integration: context providers tell chat/agent what "this" means
;;; (the selected search line, or the thread being read), and tools let
;;; the model search and read mail itself.

(defgroup 'notmuch "Email: notmuch search, reading, and sending.")

(defcustom 'notmuch-program "notmuch"
  "The notmuch executable." 'group 'notmuch)
(defcustom 'notmuch-profile ""
  "NOTMUCH_PROFILE for every call; \"\" uses the default database."
  'group 'notmuch)
(defcustom 'notmuch-search-limit 50
  "How many threads a search buffer shows." 'group 'notmuch)
(defcustom 'notmuch-default-query "tag:inbox"
  "The query the notmuch command opens with." 'group 'notmuch)
(defcustom 'notmuch-prefer-html #t
  "Render threads as HTML when a message has an HTML part (v toggles text)."
  'group 'notmuch)
(defcustom 'notmuch-html-original-colors #f
  "Render emails with their authored colors on a white canvas. Off, the
theme repaints them (shr-style: layout survives, colors follow the theme
— readable in dark mode)." 'group 'notmuch)
(defcustom 'notmuch-html-renderer "w3m -dump -O utf-8 -T text/html"
  "Command that turns HTML into text, for the text view and the mail tools
when a message has no text/plain part." 'group 'notmuch)
(defcustom 'notmuch-show-newest-first #t
  "Show the newest message of a thread first." 'group 'notmuch)
(defcustom 'notmuch-auto-preview #t
  "n/p in the search buffer preview the thread in the other window."
  'group 'notmuch)

;; (substring-of-From-or-filename  send-command) — first match wins,
;; "" is the fallback route. set! your accounts' routes in init.scm.
(define notmuch-send-routes
  '(("" "msmtp -t")))

(define *notmuch-search-buffer* "*notmuch*")

;; A search has one base and a stack of added terms. Commands change only
;; these two locals. The effective query is derived, so no command can leave
;; the rows and the filter stack describing different searches.
(define (nm--query-with-filters base filters)
  (if (null? filters)
      base
      (let ((filter (car filters)))
        (if (and (pair? filter) (equal? (car filter) "only"))
            (cadr filter)
            (string-append "( "
                           (nm--query-with-filters base (cdr filters))
                           " ) and " filter)))))

(define (nm--query-base-of buf)
  (let ((base (buffer-local buf 'notmuch-query-base)))
    (if base
        base
        ;; Migrate a buffer saved before the query stack became authoritative.
        (let ((legacy (or (buffer-local buf 'notmuch-query)
                          notmuch-default-query)))
          (buffer-set-local! buf 'notmuch-query-base legacy)
          (buffer-set-local! buf 'notmuch-query-filters '())
          (buffer-set-local! buf 'notmuch-query #f)
          legacy))))

(define (nm--query-filters-of buf)
  (or (buffer-local buf 'notmuch-query-filters) '()))

(define (nm--query-of buf)
  (nm--query-with-filters (nm--query-base-of buf)
                          (nm--query-filters-of buf)))

(define (nm--query-reset! buf query)
  (buffer-set-local! buf 'notmuch-query-base query)
  (buffer-set-local! buf 'notmuch-query-filters '())
  ;; Keep a restored legacy local inert. The stack now owns the query.
  (buffer-set-local! buf 'notmuch-query #f))

(define (nm--query-push! buf term)
  (nm--query-base-of buf)
  (buffer-set-local! buf 'notmuch-query-filters
    (cons term (nm--query-filters-of buf))))

(define (nm--query-push-only! buf term)
  (nm--query-base-of buf)
  (buffer-set-local! buf 'notmuch-query-filters
    (cons (list "only" term) (nm--query-filters-of buf))))

(define (nm--query-pop! buf)
  (let ((filters (nm--query-filters-of buf)))
    (if (null? filters)
        #f
        (begin
          (buffer-set-local! buf 'notmuch-query-filters (cdr filters))
          #t))))

;;; --- CLI plumbing -------------------------------------------------------------

(define (nm--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (nm--cmd args)
  (string-append
    (if (equal? notmuch-profile "")
        ""
        (string-append "NOTMUCH_PROFILE=" (nm--quote notmuch-profile) " "))
    notmuch-program " " args))

(define (nm--run args)
  (shell-command->string (nm--cmd args)))

(define (nm--json args)
  (json-parse (nm--run args)))

(define (nm--get pl key) (custom--plist-get pl key))

(define (nm--fit s n)
  (let ((s (or s "")))
    (if (> (string-length s) n)
        (substring s 0 n)
        (string-pad-right s n))))

(define (nm--trunc s n)
  (let ((s (or s "")))
    (if (> (string-length s) n) (substring s 0 n) s)))

(define (nm--html-escape s)
  (let* ((s (string-join (string-split s "&") "&amp;"))
         (s (string-join (string-split s "<") "&lt;"))
         (s (string-join (string-split s ">") "&gt;")))
    s))

(define (nm--html->text html)
  (let ((tmp (string-append (expand-path "~") "/.aimax/mail-part.html")))
    (write-file! tmp html)
    (shell-command->string
      (string-append notmuch-html-renderer " < " (nm--quote tmp)))))

;;; --- search buffer ------------------------------------------------------------

(defface! 'nm-date 'fg "#8a8a8a")
(defface! 'nm-author 'fg "#26356b")
(defface! 'nm-unread 'weight "700")
(defface! 'nm-tags 'fg "#9a9a72")
(defface! 'nm-marked 'fg "#a03020" 'weight "700")
(defface! 'nm-bar 'fg "#26356b")

(define (nm--search-json query limit)
  (or (nm--json (string-append "search --format=json --limit="
                               (number->string limit) " -- " (nm--quote query)))
      '()))

;; stored per row: (thread-id subject authors tags date)
(define (nm--th-id th) (car th))
(define (nm--th-subject th) (cadr th))
(define (nm--th-authors th) (caddr th))
(define (nm--th-tags th) (list-ref th 3))
(define (nm--th-date th) (list-ref th 4))

(define (nm--search-rows buf)
  (let ((rows (map (lambda (th) (list (nm--get th 'thread)
                                      (or (nm--get th 'subject) "")
                                      (or (nm--get th 'authors) "")
                                      (or (nm--get th 'tags) '())
                                      (or (nm--get th 'date_relative) "")))
                   (nm--search-json (nm--query-of buf) notmuch-search-limit))))
    ;; the tag column measures itself against the threads this search
    ;; found. It reads the number here, and not from the entries: a draw
    ;; lays the columns out while the entries it replaces are still the
    ;; ones on the buffer.
    (buffer-set-local! buf 'nm-tags-need
      (fold (lambda (acc th) (max acc (string-length (nm--tags-text th)))) 6 rows))
    rows))

;; Two lines per thread. The subject owns the first line, so a narrow
;; window never truncates it; the date sits at the right of that line,
;; where a compressed date still reads. The author and the tags share
;; the second line, and the bar in front of the row says the tag you
;; read first: unread.
;;
;; The reader sees EVERY tag a thread carries. A tag longer than five
;; characters keeps its first three letters and says the rest is
;; missing: "attachment" reads "att..". The author is what gives way
;; when the window narrows.
(define nm-tag-width 5)

(define (nm--short-tag t)
  (if (> (string-length t) nm-tag-width)
      (string-append (substring t 0 3) "..")
      t))

(define (nm--fit-tags s w)
  (let* ((tags (filter (lambda (t) (not (equal? t ""))) (string-split s " ")))
         (short (string-join (map nm--short-tag tags) " ")))
    (cond ((null? tags) "")
          ((<= (string-length short) w) short)
          ;; not even the short forms fit: one letter per tag, and the
          ;; reader still counts them
          (else (string-join (map (lambda (t) (substring t 0 1)) tags) "")))))

(define (nm--tags-text th)
  (string-join (map nm--short-tag (nm--th-tags th)) " "))

;; The tag column is as wide as the busiest thread of this search needs,
;; so every thread shows every tag it has. It stops at half the window:
;; past that the author has nothing left to say, and a thread with that
;; many tags falls back to the initials.
(define (nm--tags-width buf)
  (let ((need (or (buffer-local buf 'nm-tags-need) 6)))
    (min need (max 10 (quotient (list-view-width buf) 2)))))

(define (nm--search-columns buf)
  (list (list (list "" 1) (list "subject" #f 'left 'end) (list "date" 13 'right))
        (list (list "" 1) (list "author" #f)
              (list "tags" (nm--tags-width buf) 'right nm--fit-tags))))

(define (nm--subject-face tags)
  (cond ((member "m" tags) "nm-marked")
        ((member "unread" tags) "nm-unread")
        (else "nm-subject")))

(define (nm--search-cells buf th)
  (let* ((tags (nm--th-tags th))
         (bar (if (member "unread" tags) "▌" " ")))
    (list (list (list bar "nm-bar")
                (list (nm--th-subject th) (nm--subject-face tags))
                (list (nm--th-date th) "nm-date"))
          (list " "
                (list (nm--th-authors th) "nm-author")
                (list (nm--tags-text th) "nm-tags")))))

(define (nm--search-meta buf)
  (string-append (number->string (length (list-entries buf)))
                 " threads · " (nm--query-of buf)))

;; the list machinery owns the refresh, the row lookup and the header
;; offset (R8); these names stay for the commands and tests that call them
(define (nm--refresh! buf) (list-refresh! buf))
(define (nm--index-at buf) (list-index buf))
(define (nm--thread-at buf) (list-current buf))

(mode-icon! "notmuch-mode" "")

(define-list-mode! "notmuch-mode"
  (list
    'doc (string-append
           "One notmuch search as a list of threads. `RET` opens, `SPC` "
           "previews, `a`/`d`/`t` tag, `m` marks and the capital keys act "
           "on every marked thread. `/` adds a tag filter; `\\` removes it. "
           "`s` starts a new search; `q` goes back "
           "to the mailboxes.")
    'rows nm--search-rows
    'row-columns nm--search-columns
    'row-cells nm--search-cells
    'title (lambda (buf) "Mail")
    'meta nm--search-meta
    'total (lambda (buf) (length (list-entries buf)))
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "open") ("SPC" "preview") ("m" "mark")
                ("a" "archive") ("d" "trash") ("t" "tag")
                ("s" "search") ("/" "tag filter") ("\\" "unfilter")
                ("g" "refresh")
                ("q" "mailboxes")))
    'keys '(("n" "notmuch-next") ("p" "notmuch-prev")
            ("RET" "notmuch-open-thread") ("SPC" "notmuch-preview")
            ("M-<" "notmuch-first-thread") ("M->" "notmuch-last-thread")
            ("r" "notmuch-reply") ("a" "notmuch-archive") ("d" "notmuch-trash")
            ("u" "notmuch-smart-untag") ("." "notmuch-toggle-unread")
            ("@" "notmuch-filter-by-sender")
            ("m" "notmuch-mark-toggle") ("M" "notmuch-mark-all")
            ("*" "notmuch-mark-all") ("U" "notmuch-unmark-all")
            ("F" "notmuch-filter-marked") ("A" "notmuch-archive-marked")
            ("D" "notmuch-trash-marked") ("t" "notmuch-tag-marked")
            ("T" "notmuch-edit-tags") ("+" "notmuch-add-tag")
            ("-" "notmuch-remove-tag") ("j" "notmuch-jump")
            ("/" "notmuch-filter-by-tag")
            ("\\" "notmuch-unfilter-last") ("l" "notmuch-filter")
            ("s" "notmuch-search") ("g" "notmuch-refresh")
            ;; like notmuch-emacs: q in the index goes back to the mailboxes
            ("q" "notmuch"))
    'remap '(("next-line" "notmuch-next") ("previous-line" "notmuch-prev"))))

(define (nm--open-index! query)
  (let* ((buf *notmuch-search-buffer*)
         (cached? (and (buffer-exists? buf)
                       (pair? (buffer-local buf 'list-entries)))))
    (unless (buffer-exists? buf) (buffer-create buf))
    (nm--query-reset! buf query)
    (switch-to-buffer! buf)
    (set-mode! "notmuch-mode")
    ;; The mode setup can reuse cached rows. A mailbox selection requests
    ;; current rows for its new base query.
    (when cached? (nm--refresh! buf))
    (list-goto-first-entry buf)))

(define-command "notmuch-inbox" "Open the mail index on the default query"
  (lambda () (nm--open-index! notmuch-default-query)))

;;; --- mailboxes (notmuch-hello): saved searches with counts -----------------------

(define *notmuch-hello-buffer* "*mailboxes*")

;; query.NAME.query=Q entries from the notmuch config
(define (nm--saved-searches)
  (let loop ((ls (string-split (nm--run "config list") "\n")) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let ((line (car ls)))
          (if (string-prefix? "query." line)
              (let* ((name (car (string-split
                                  (substring line 6 (string-length line)) ".")))
                     (parts (string-split line "="))
                     (q (if (pair? (cdr parts)) (string-join (cdr parts) "=") "")))
                (loop (cdr ls) (cons (list name q) acc)))
              (loop (cdr ls) acc))))))

;; one notmuch invocation for all counts
(define (nm--batch-count queries)
  (if (null? queries)
      '()
      (map (lambda (s) (or (string->number s) 0))
           (string-split
             (string-trim
               (shell-command->string
                 (string-append "printf '%s\\n' "
                                (string-join (map nm--quote queries) " ")
                                " | " (nm--cmd "count --batch"))))
             "\n"))))

;; one row: (name query total unread)
(define (nm--hello-rows buf)
  (let* ((searches (nm--saved-searches))
         (queries (map cadr searches))
         (totals (nm--batch-count queries))
         (unreads (nm--batch-count
                    (map (lambda (q) (string-append "( " q " ) and tag:unread"))
                         queries))))
    (let loop ((ss searches) (ts totals) (us unreads) (acc '()))
      (if (or (null? ss) (null? ts) (null? us))
          (reverse acc)
          (loop (cdr ss) (cdr ts) (cdr us)
                (cons (list (car (car ss)) (cadr (car ss)) (car ts) (car us))
                      acc))))))

(define (nm--hello-cols row)
  (list (nm--fit (car row) 16)
        (string-append
          (string-pad-left (number->string (list-ref row 3)) 6) " / "
          (string-pad-left (number->string (list-ref row 2)) 6))))

(define (nm--hello-line row)
  (let ((c (nm--hello-cols row)))
    (string-append "  " (car c) (cadr c) "   " (cadr row))))

(define (nm--hello-overlays buf row off)
  (let* ((c (nm--hello-cols row))
         (n-start (+ off 2))
         (n-end (+ n-start (string-byte-length (car c))))
         (c-end (+ n-end (string-byte-length (cadr c))))
         (l-end (+ off (string-byte-length (nm--hello-line row)))))
    (list (list n-start n-end
                (if (> (list-ref row 3) 0) "nm-unread" "nm-author"))
          (list n-end c-end "nm-date")
          (list c-end l-end "nm-tags"))))

(define (nm--hello-cells buf row)
  (list (list (car row) (if (> (list-ref row 3) 0) "nm-unread" "nm-author"))
        (list (number->string (list-ref row 3)) "nm-date")
        (list (number->string (list-ref row 2)) "nm-date")
        (list (cadr row) "nm-tags")))

(define (nm--hello-at buf) (list-current buf))

(mode-icon! "notmuch-hello-mode" "")

(define-list-mode! "notmuch-hello-mode"
  (list
    'doc (string-append
           "The mailboxes: every saved search with its unread and total "
           "counts. `RET` opens one as a thread list; `s` runs a free-form "
           "search.")
    'buffer *notmuch-hello-buffer*
    'rows nm--hello-rows
    'columns (lambda (buf)
               (list (list "mailbox" 16) (list "unread" 7 'right)
                     (list "total" 7 'right) (list "query" #f)))
    'cells nm--hello-cells
    'title (lambda (buf) "Mailboxes")
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf))) " saved searches"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "open") ("s" "search") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("n" "next-line") ("p" "previous-line")
            ("RET" "notmuch-hello-open") ("g" "notmuch-hello-refresh")
            ("j" "notmuch-jump") ("s" "notmuch-search")
            ("q" "quit-window"))))

(define-command "notmuch" "Open the mailboxes (saved searches)"
  (lambda ()
    (let ((buf *notmuch-hello-buffer*))
      (unless (buffer-exists? buf) (buffer-create buf))
      (switch-to-buffer! buf)
      (set-mode! "notmuch-hello-mode")
      (list-goto-first-entry buf))))

(define-command "notmuch-hello-open" "Open the saved search at point"
  (lambda ()
    (let ((s (nm--hello-at (current-buffer))))
      (if s
          (nm--open-index! (cadr s))
          (message "No mailbox on this line")))))

(define-command "notmuch-hello-refresh" "Refresh the mailbox counts"
  (lambda () (list-refresh! (current-buffer)) (message "Refreshed")))

;; the mail views are derived state — killing them loses nothing. The
;; chat survives (it holds a conversation); a scene toggle in init.scm
;; can lean on this for teardown.
(define (nm--view-buffers)
  (filter (lambda (b) (member b (list *notmuch-search-buffer*
                                      *notmuch-hello-buffer*
                                      *notmuch-show-buffer*)))
          (buffer-list)))

(define-command "notmuch-quit" "Close mail: kill the view buffers, back to work"
  (lambda ()
    ;; land on real work: not a mail view, and not a member of whatever
    ;; group the mail scene lives in. That group is the index's own — the
    ;; name is the user's to choose, and buffer-group answers with an id,
    ;; so neither one can be compared against a literal here.
    (let* ((mail-ids (if (buffer-exists? *notmuch-search-buffer*)
                         (buffer-group-ids *notmuch-search-buffer*)
                         '()))
           (others (filter (lambda (b)
                             (and (not (member b (nm--view-buffers)))
                                  (not (fold (lambda (hit id)
                                               (or hit (buffer-in-group? b id)))
                                             #f mail-ids))))
                           (buffer-list-mru))))
      (delete-other-windows!)
      (switch-to-buffer! (if (null? others) "*scratch*" (car others)))
      (for-each buffer-kill! (nm--view-buffers))
      (message "Mail closed"))))

;; the preview helpers target the *next* window in cyclic order, so any
;; window arrangement works: put the index left of where you want mail
;; shown and SPC/n/p keep filling that pane. Personal scenes (three-pane
;; layouts, per-account profile commands, keybindings) belong in init.scm.

;;; --- preview: thread in the other window, focus stays --------------------------

;; Render into the mail pane. A window already showing the mail view IS
;; that pane — reuse it. other-window! only means "the mail pane" in a
;; two-window frame; in a three-pane scene it can be the chat, and the
;; preview would then evict the chat and leave the frame a window short.
;; Only when no pane shows the mail view does this fall back to making
;; one, and it always puts focus back where it started.
(define (nm--in-other-window! thunk)
  (cond
    ;; the layout engine is mid-build: it places every declared pane
    ;; itself, so render the mail view and touch no windows at all. A
    ;; split here lands between the engine's own splits and leaves the
    ;; frame in neither arrangement.
    ((layout-arranging?) (thunk))
    (else
      (let ((back (active-window))
            (pane (or (scene-window 'show)
                      (window-showing *notmuch-show-buffer*))))
        (if pane
            (select-window! pane)
            (begin
              (when (null? (cdr (window-list))) (split-window! 'h 0.45))
              (other-window!)))
        (thunk)
        (select-window! back)))))

(define (nm--preview! buf)
  (let ((th (nm--thread-at buf)))
    (when th
      (nm--in-other-window!
        (lambda () (nm--open-thread! (nm--th-id th) (nm--th-subject th))))
      ;; opening marked it read — show that in the index right away
      (when (member "unread" (nm--th-tags th))
        (nm--refresh! buf)))))

(define-command "notmuch-preview" "Preview the thread at point in the other window"
  (lambda () (nm--preview! (current-buffer))))

;; The pane-builder form of the same thing. A scene declares its panes as
;; (ensure "*mail*" "notmuch-show-current"), and an ensure command has one
;; job: make that buffer exist. So it reads the index by name and never
;; consults the current buffer, point, or the windows — none of which mean
;; anything while a layout is being built.
(define-command "notmuch-show-current"
  "Make the mail pane, showing the index's current thread if there is one"
  (lambda ()
    (let ((th (and (buffer-exists? *notmuch-search-buffer*)
                   (with-current-buffer *notmuch-search-buffer*
                     (lambda () (nm--thread-at *notmuch-search-buffer*))))))
      (if th
          (nm--open-thread! (nm--th-id th) (nm--th-subject th))
          ;; The index fetches its rows off this lane, so a freshly built
          ;; index has none yet and there is no thread to open. The pane is
          ;; part of the declared shape all the same: make it now and let
          ;; the first move in the index fill it. An ensure command that
          ;; only sometimes makes its buffer is not an ensure command.
          (unless (buffer-exists? *notmuch-show-buffer*)
            (buffer-create *notmuch-show-buffer*)
            (buffer-set-local! *notmuch-show-buffer* 'transient #t)
            (buffer-append! *notmuch-show-buffer* "No message selected.\n"))))))

(define (nm--maybe-preview! buf)
  (when notmuch-auto-preview (nm--preview! buf)))

;; the shown mail follows the highlight: every move previews, and opening
;; a thread marks it read (the open itself tags -unread)
;; a thread is a ROW, and a row is two lines — the list moves by rows,
;; so every move here goes through the list and none of them counts
;; lines
(define (nm--move! step)
  (let ((buf (current-buffer)))
    (list-move-in! buf step)
    (nm--maybe-preview! buf)))

(define-command "notmuch-next" "Move down; the shown mail follows"
  (lambda () (nm--move! 1)))

(define-command "notmuch-prev" "Move up; the shown mail follows"
  (lambda () (nm--move! -1)))

(define-command "notmuch-first-thread" "Jump to the newest thread"
  (lambda ()
    (let ((buf (current-buffer)))
      (list-goto-first-entry buf)
      (nm--maybe-preview! buf))))

(define-command "notmuch-last-thread" "Jump to the oldest listed thread"
  (lambda ()
    (let* ((buf (current-buffer)) (n (length (list-entries buf))))
      (when (> n 0) (list-goto-index! buf (- n 1)))
      (nm--maybe-preview! buf))))

(define-command "notmuch-refresh" "Re-run the search and refresh the listing"
  (lambda () (nm--refresh! (current-buffer)) (message "Refreshed")))

(define-command "notmuch-search" "Prompt for a notmuch query and show it"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Notmuch search: " '()
        (lambda (q)
          (nm--query-reset! buf q)
          (nm--refresh! buf)
          (list-goto-first-entry buf))))))

;;; --- tagging ------------------------------------------------------------------

(define (nm--goto-index! buf i) (list-goto-index! buf i))

;; tag, refresh, stay at the same list INDEX — when the change removes the
;; row (archive/trash on an inbox view) that index IS the next thread —
;; then the shown mail follows
(define (nm--tag! buf changes)
  (let ((th (nm--thread-at buf)) (i (nm--index-at buf)))
    (if th
        (begin
          (nm--run (string-append "tag " changes " -- thread:" (nm--th-id th)))
          (nm--refresh! buf)
          (let ((n (length (list-entries buf))))
            (when (and i (> n 0)) (nm--goto-index! buf (min i (- n 1)))))
          (nm--maybe-preview! buf)
          (message changes))
        (message "No thread on this line"))))

(define-command "notmuch-archive" "Archive the thread at point (-inbox)"
  (lambda () (nm--tag! (current-buffer) "-inbox")))
(define-command "notmuch-trash" "Trash the thread at point (+trash -inbox -unread)"
  (lambda () (nm--tag! (current-buffer) "+trash -inbox -unread")))
(catalog-meta! 'command "notmuch-trash" 'domain 'mail 'effects '(destroy))

(define-command "notmuch-toggle-unread" "Toggle the unread tag on the thread at point"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if th
          (nm--tag! buf (if (member "unread" (nm--th-tags th)) "-unread" "+unread"))
          (message "No thread on this line")))))

;; on a plain tag:X search, u strips that tag from the thread — inbox zero
;; as a single keystroke on any tag view
(define-command "notmuch-smart-untag" "Remove the searched-for tag from this thread"
  (lambda ()
    (let* ((buf (current-buffer))
           (query (nm--query-of buf))
           (th (nm--thread-at buf)))
      (cond ((not th) (message "No thread on this line"))
            ((and (string-prefix? "tag:" query)
                  (not (string-contains? query " ")))
             (nm--tag! buf (string-append "-" (substring query 4 (string-length query)))))
            (else (message "Not a simple tag: search"))))))

(define-command "notmuch-edit-tags" "Edit tags of the thread at point (+tag -tag ...)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--thread-at buf)
          (minibuffer-read "Tags (+add -remove): " '()
            (lambda (changes) (nm--tag! buf changes)))
          (message "No thread on this line")))))

;; every tag in the database — the completion source for +
(define (nm--all-tags)
  (filter (lambda (t) (not (equal? t "")))
          (string-split (string-trim (nm--run "search --output=tags '*'")) "\n")))

;; Only offer tags that occur in the current result. The menu cannot lead
;; from a useful inbox view to an empty result through an unrelated tag.
(define (nm--query-tags buf)
  (filter (lambda (t) (not (equal? t "")))
          (string-split
            (string-trim
              (nm--run (string-append "search --output=tags -- "
                                      (nm--quote (nm--query-of buf)))))
            "\n")))

(define-command "notmuch-add-tag" "Add a tag to the thread at point (completes)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--thread-at buf)
          (minibuffer-read "Add tag: " (nm--all-tags)
            (lambda (tag)
              (unless (equal? (string-trim tag) "")
                (nm--tag! buf (string-append "+" (string-trim tag))))))
          (message "No thread on this line")))))

(define-command "notmuch-remove-tag" "Remove a tag from the thread at point (completes)"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if th
          (minibuffer-read "Remove tag: " (nm--th-tags th)
            (lambda (tag)
              (unless (equal? (string-trim tag) "")
                (nm--tag! buf (string-append "-" (string-trim tag))))))
          (message "No thread on this line")))))

;;; --- jump & filter ---------------------------------------------------------------

;; ((key name query) ...) — personal jump table, set in init.scm; empty
;; falls back to the saved searches by name
(define notmuch-jump-searches '())

(define-command "notmuch-jump" "Jump to a saved search (j, then its key)"
  (lambda ()
    (if (null? notmuch-jump-searches)
        (let ((ss (nm--saved-searches)))
          (minibuffer-read "Jump: "
            (map (lambda (s) (list (car s) (cadr s))) ss)
            (lambda (name)
              (let ((e (assoc name ss)))
                (when e (nm--open-index! (cadr e)))))))
        (minibuffer-read "Jump: "
          (map (lambda (s) (list (car s) (string-append (cadr s) " · " (caddr s))))
               notmuch-jump-searches)
          (lambda (key)
            (let ((e (assoc key notmuch-jump-searches)))
              (when e (nm--open-index! (caddr e)))))))))

(define-command "notmuch-filter" "Narrow this search with more terms (and)"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Filter (and): " '()
        (lambda (terms)
          (let ((term (string-trim terms)))
            (unless (equal? term "")
              (nm--query-push! buf term)
              (nm--refresh! buf)
              (list-goto-first-entry buf))))))))

(domain! 'mail)
(effects! '(write external execute))

(define-command "notmuch-filter-by-tag"
  "Choose a tag from the current results and add it to this search"
  (lambda ()
    (let* ((buf (current-buffer))
           (tags (nm--query-tags buf)))
      (if (null? tags)
          (message "No tags occur in this search")
          (minibuffer-read "Add tag filter: " tags
            (lambda (choice)
              (let ((tag (string-trim choice)))
                (unless (equal? tag "")
                  (nm--query-push! buf (string-append "tag:" tag))
                  (nm--refresh! buf)
                  (list-goto-first-entry buf)
                  (message (string-append "Added tag filter: " tag))))))))))

(effects! '(unknown))

(define-command "notmuch-unfilter-last" "Remove the most recently added notmuch filter"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (nm--query-pop! buf))
          (message "No structured notmuch filters to remove")
          (begin
            (nm--refresh! buf)
            (message "Removed last notmuch filter"))))))

(define-command "notmuch-filter-by-sender" "Narrow the search to this thread's sender"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if (not th)
          (message "No thread on this line")
          (let* ((msgs (nm--flatten-msgs
                         (or (nm--json (string-append "show --format=json --body=false thread:"
                                                      (nm--th-id th)))
                             '())))
                 (from (if (null? msgs)
                           ""
                           (or (nm--get (nm--get (car msgs) 'headers) 'From) "")))
                 (email (let ((parts (string-split from "<")))
                          (if (null? (cdr parts))
                              (string-trim from)
                              (car (string-split (cadr parts) ">"))))))
            (if (equal? email "")
                (message "Could not extract the sender")
                (begin
                  (nm--query-push-only! buf (string-append "from:" email))
                  (nm--refresh! buf)
                  (list-goto-first-entry buf)
                  (message (string-append "from:" email)))))))))

;;; --- marks: dired-style bulk operations via the m tag ---------------------------

;; bulk queries carry parens — shell syntax unless quoted as one argument
(define (nm--tag-marked! buf changes)
  (nm--run (string-append "tag " changes " -- "
                          (nm--quote (string-append "( " (nm--query-of buf)
                                                    " ) and tag:m"))))
  (nm--refresh! buf))

(define-command "notmuch-mark-toggle" "Toggle the m tag on this thread, move down"
  (lambda ()
    (let* ((buf (current-buffer)) (th (nm--thread-at buf)))
      (if th
          (begin
            (nm--tag! buf (if (member "m" (nm--th-tags th)) "-m" "+m"))
            ;; marking keeps the row — advance past it, dired-style
            (list-move-in! buf 1))
          (message "No thread on this line")))))

(define-command "notmuch-mark-all" "Mark every thread in this search"
  (lambda ()
    (let ((buf (current-buffer)))
      (nm--run (string-append "tag +m -- "
                              (nm--quote (string-append "( " (nm--query-of buf) " )"))))
      (nm--refresh! buf)
      (message "Marked all"))))

(define-command "notmuch-unmark-all" "Unmark every thread in this search"
  (lambda ()
    (let ((buf (current-buffer)))
      (nm--run (string-append "tag -m -- "
                              (nm--quote (string-append "( " (nm--query-of buf) " )"))))
      (nm--refresh! buf)
      (message "Unmarked all"))))

(define-command "notmuch-filter-marked" "Show only the marked threads"
  (lambda ()
    (let ((buf (current-buffer)))
      (nm--query-push-only! buf "tag:m")
      (nm--refresh! buf)
      (list-goto-first-entry buf))))

(define (nm--confirm-marked buf verb changes)
  (minibuffer-read (string-append verb " all marked threads? ")
    (list "yes" "no")
    (lambda (ans)
      (if (equal? ans "yes")
          (begin (nm--tag-marked! buf changes) (message "Done"))
          (message "Cancelled")))))

(define-command "notmuch-archive-marked" "Archive all marked threads"
  (lambda () (nm--confirm-marked (current-buffer) "Archive" "-inbox -m")))
(define-command "notmuch-trash-marked" "Trash all marked threads"
  (lambda () (nm--confirm-marked (current-buffer) "Trash" "+trash -inbox -unread -m")))

(define-command "notmuch-tag-marked" "Apply tag changes to all marked threads"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Tag marked (+add -remove): " '()
        (lambda (changes) (nm--tag-marked! buf changes) (message changes))))))

;;; --- thread (show) buffer -------------------------------------------------------

;; body part -> displayable text: text/plain passes, multipart/alternative
;; prefers its text/plain child, attachments become a marker line
(define (nm--part-text part)
  (let ((ct (or (nm--get part 'content-type) ""))
        (content (nm--get part 'content)))
    (cond ((and (string-prefix? "multipart/alternative" ct) (pair? content))
           (let ((plains (filter (lambda (p)
                                   (string-prefix? "text/plain"
                                     (or (nm--get p 'content-type) "")))
                                 content)))
             (if (null? plains)
                 (nm--parts-text content)
                 (nm--part-text (car plains)))))
          ((pair? content) (nm--parts-text content))
          ((and (string-prefix? "text/plain" ct) (string? content)) content)
          ((and (string-prefix? "text/html" ct)) "")
          ((nm--get part 'filename)
           (string-append "[attachment: " (nm--get part 'filename) "]\n"))
          (else ""))))

(define (nm--parts-text parts)
  (fold (lambda (acc p) (string-append acc (nm--part-text p))) "" parts))

;; first text/html part's content, or #f
(define (nm--part-html part)
  (let ((ct (or (nm--get part 'content-type) ""))
        (content (nm--get part 'content)))
    (cond ((and (string-prefix? "text/html" ct) (string? content)) content)
          ((pair? content) (nm--parts-html content))
          (else #f))))

(define (nm--parts-html parts)
  (let loop ((ps parts))
    (if (null? ps)
        #f
        (let ((h (nm--part-html (car ps))))
          (if h h (loop (cdr ps)))))))

;; notmuch show nests messages as [msg, [replies...]] pairs — flatten
(define (nm--flatten-msgs forest)
  (if (null? forest)
      '()
      (append
        (let ((entry (car forest)))
          (if (and (pair? entry) (nm--get (car entry) 'id))
              (cons (car entry) (nm--flatten-msgs (cadr entry)))
              (nm--flatten-msgs entry)))
        (nm--flatten-msgs (cdr forest)))))

(define (nm--show-msgs thread-id)
  (let ((msgs (nm--flatten-msgs
                (or (nm--json (string-append
                                "show --format=json --include-html thread:" thread-id))
                    '()))))
    (if notmuch-show-newest-first (reverse msgs) msgs)))

;; text body of one message; falls back to the html part through
;; notmuch-html-renderer when there is no text/plain
(define (nm--msg-body-text msg)
  (let ((plain (nm--parts-text (nm--get msg 'body))))
    (if (equal? (string-trim plain) "")
        (let ((html (nm--parts-html (nm--get msg 'body))))
          (if html (nm--html->text html) plain))
        plain)))

(define (nm--msg-render msg)
  (let ((h (nm--get msg 'headers)))
    (string-append
      "From: " (or (nm--get h 'From) "") "\n"
      "Date: " (or (nm--get h 'Date) "") "\n"
      (let ((to (nm--get h 'To)))
        (if to (string-append "To: " to "\n") ""))
      "\n"
      (nm--msg-body-text msg)
      "\n")))

;; -> (text ((byte-offset id filename) ...))
(define (nm--render-text subject msgs)
  (if (null? msgs)
      (list "" '())
      (let loop ((ms msgs) (n 1)
                 (text (string-append subject "\n"))
                 (offsets '()))
        (if (null? ms)
            (list text (reverse offsets))
            (let ((header (string-append
                            "\n── message " (number->string n) " of "
                            (number->string (length msgs)) " ──\n")))
              (loop (cdr ms) (+ n 1)
                    (string-append text header (nm--msg-render (car ms)))
                    (cons (list (string-byte-length text)
                                (nm--get (car ms) 'id)
                                (nm--get (car ms) 'filename))
                          offsets)))))))

;; the whole thread as one HTML document for the sandboxed iframe:
;; our headers, their bodies (plain text becomes <pre>)
(define (nm--msg-html msg)
  (let* ((h (nm--get msg 'headers))
         (html (nm--parts-html (nm--get msg 'body)))
         (body (or html
                   (string-append "<pre style=\"white-space:pre-wrap;font:13px/1.5 ui-monospace,monospace\">"
                                  (nm--html-escape (nm--parts-text (nm--get msg 'body)))
                                  "</pre>"))))
    (string-append
      "<div style=\"border-top:1px solid #d0c8b8;margin-top:14px;padding:6px 0;"
      "font:12px system-ui;color:#666\"><b>"
      (nm--html-escape (or (nm--get h 'From) "")) "</b> · "
      (nm--html-escape (or (nm--get h 'Date) ""))
      (let ((to (nm--get h 'To)))
        (if to (string-append " · to " (nm--html-escape to)) ""))
      "</div>" body)))

(define (nm--thread-html subject msgs)
  (string-append
    "<!doctype html><meta charset=\"utf-8\"><title>"
    (nm--html-escape subject)
    "</title><body style=\"margin:14px;font-family:system-ui\">"
    "<div style=\"font:600 15px system-ui\">" (nm--html-escape subject) "</div>"
    (fold (lambda (acc m) (string-append acc (nm--msg-html m))) "" msgs)
    "</body>"))

(define (nm--any-html? msgs)
  (let loop ((ms msgs))
    (cond ((null? ms) #f)
          ((nm--parts-html (nm--get (car ms) 'body)) #t)
          (else (loop (cdr ms))))))

(mode-doc! "notmuch-show-mode"
  "One mail thread, read. `a` archives it and `r` starts a reply. `v` changes between the HTML and the plain text. `q` goes back to the search.")

(mode-icon! "notmuch-show-mode" "")

(define-mode "notmuch-show-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (local-set-key "a" "notmuch-show-archive")
      (local-set-key "r" "notmuch-show-reply")
      (local-set-key "v" "notmuch-show-toggle-view")
      (local-set-key "j" "notmuch-jump")
      (local-set-key "q" "quit-window")
      (let ((th (buffer-local buf 'notmuch-thread)))
        (when th
          (let* ((subject (or (buffer-local buf 'notmuch-subject) ""))
                 (msgs (nm--show-msgs th))
                 (html? (and notmuch-prefer-html
                             (not (equal? (buffer-local buf 'notmuch-view) "text"))
                             (nm--any-html? msgs))))
            (buffer-delete-range! buf 0 (buffer-size buf))
            (if html?
                (begin
                  (buffer-append! buf (nm--thread-html subject msgs))
                  (buffer-set-local! buf 'render-mode "html")
                  ;; authored colors assume a white canvas — by default the
                  ;; theme repaints the document instead (dark mode stays
                  ;; readable); customize notmuch-html-original-colors to
                  ;; get the untouched rendering back
                  (buffer-set-local! buf 'preview-authored
                    notmuch-html-original-colors)
                  ;; fake ascending offsets: point stays 0 in the html view,
                  ;; so "message at point" means the first (newest) message
                  (buffer-set-local! buf 'notmuch-msgs
                    (let loop ((ms msgs) (i 0) (acc '()))
                      (if (null? ms)
                          (reverse acc)
                          (loop (cdr ms) (+ i 1)
                                (cons (list i (nm--get (car ms) 'id)
                                            (nm--get (car ms) 'filename))
                                      acc))))))
                (let ((rendered (nm--render-text subject msgs)))
                  (buffer-append! buf (car rendered))
                  (buffer-set-local! buf 'render-mode #f)
                  (buffer-set-local! buf 'notmuch-msgs (cadr rendered))))
            (goto-char! 0)))))))

;; ONE show buffer, reused — it is a view, not a document. The subject
;; lives in the modeline; 'transient keeps its derived content out of the
;; desktop file (the mode re-renders from 'notmuch-thread on restore).
(define *notmuch-show-buffer* "*mail*")

(define (nm--open-thread! thread-id subject)
  (let ((buf *notmuch-show-buffer*))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'notmuch-thread thread-id)
    (buffer-set-local! buf 'notmuch-subject subject)
    (buffer-set-local! buf 'transient #t)
    ;; a view inherits its index's groups, so a grouped mail scene keeps
    ;; the open message inside the group (group-docs, chat read-doc, ⊞).
    ;; Membership is 'group-ids and joining is buffer-add-group!: writing
    ;; the legacy 'group local here left the view ungrouped, because the
    ;; reader clears that local the moment a buffer has real memberships.
    (when (buffer-exists? *notmuch-search-buffer*)
      (for-each (lambda (id) (buffer-add-group! buf id))
                (buffer-group-ids *notmuch-search-buffer*)))
    (switch-to-buffer! buf)
    (set-mode! "notmuch-show-mode")
    ;; reading marks read, like every mail client
    (nm--run (string-append "tag -unread -- thread:" thread-id))
    buf))

(define-command "notmuch-open-thread" "Open the thread at point"
  (lambda ()
    (let ((buf (current-buffer))
          (th (nm--thread-at (current-buffer)))
          ;; A scene names semantics, not coordinates. RET fills its `show`
          ;; pane without moving focus from `index`. Outside a scene it keeps
          ;; the traditional behavior of opening in the current window.
          (pane (scene-window 'show)))
      (if th
          (if pane
              (nm--preview! buf)
              (nm--open-thread! (nm--th-id th) (nm--th-subject th)))
          (message "No thread on this line")))))

(define-command "notmuch-show-toggle-view" "Switch between the HTML and text views"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'notmuch-view
        (if (equal? (buffer-local buf 'notmuch-view) "text") "html" "text"))
      (set-mode! "notmuch-show-mode"))))

(define-command "notmuch-show-archive" "Archive this thread and go back"
  (lambda ()
    (let ((th (buffer-local (current-buffer) 'notmuch-thread)))
      (when th
        (nm--run (string-append "tag -inbox -- thread:" th))
        (run-command "quit-window")
        (when (buffer-exists? *notmuch-search-buffer*)
          (nm--refresh! *notmuch-search-buffer*))
        (message "Archived")))))

;; the message the point is in: last offset <= point (above the first
;; message — on the subject line — it means the first message)
(define (nm--msg-at buf)
  (let ((ms (or (buffer-local buf 'notmuch-msgs) '())))
    (let loop ((rest ms) (found (if (null? ms) #f (car ms))))
      (cond ((null? rest) found)
            ((<= (car (car rest)) (buffer-point buf)) (loop (cdr rest) (car rest)))
            (else found)))))

;;; --- compose / reply ------------------------------------------------------------

(mode-icon! "mail-compose-mode" "")

(define-mode "mail-compose-mode"
  (lambda ()
    (local-set-key "C-c C-c" "mail-send")
    (local-set-key "C-c C-k" "mail-abort")))

(mode-doc! "mail-compose-mode"
  "A message you are writing. The headers sit above the separator line and the body below it. `C-c C-c` sends the message, and `C-c C-k` abandons it.")

;; message-mode layout: headers, the separator, an empty line for the
;; reply (point lands there), attribution, the original quoted as text
(define *mail-header-separator* "--text follows this line--")

(defface! 'nm-hdr 'fg "#26356b" 'weight "600")
(defface! 'nm-sep 'fg "#9a9a72")

(define (nm--quote-text text)
  (string-append "> "
    (string-join (string-split (string-trim text) "\n") "\n> ")
    "\n"))

;; face the header names and the separator — they sit above point, so
;; typing in the body never shifts them
(define (nm--compose-overlays! buf head)
  (let loop ((lines (string-split head "\n")) (off 0) (ovs '()))
    (if (null? lines)
        (overlay-set! buf 'compose (reverse ovs))
        (let* ((line (car lines))
               (len (string-byte-length line))
               (parts (string-split line ": ")))
          (loop (cdr lines) (+ off len 1)
                (cond ((equal? line *mail-header-separator*)
                       (cons (list off (+ off len) "nm-sep") ovs))
                      ((and (> len 0) (pair? (cdr parts)))
                       (cons (list off (+ off (string-byte-length (car parts)) 1) "nm-hdr")
                             ovs))
                      (else ovs)))))))

(define (nm--compose-reply! msg-id)
  (let* ((j (nm--json (string-append "reply --format=json id:" (nm--quote msg-id))))
         (rh (and j (nm--get j 'reply-headers)))
         (orig (and j (nm--get j 'original))))
    (if (not rh)
        (message "notmuch reply failed")
        (let* ((buf "*compose*")
               (hdr (lambda (name key)
                      (let ((v (nm--get rh key)))
                        (if v (string-append name ": " v "\n") ""))))
               (head (string-append
                       (hdr "From" 'From) (hdr "To" 'To) (hdr "Cc" 'Cc)
                       (hdr "Subject" 'Subject)
                       (hdr "In-Reply-To" 'In-reply-to)
                       (hdr "References" 'References)
                       *mail-header-separator* "\n"))
               (attrib (let ((h (and orig (nm--get orig 'headers))))
                         (if (and h (nm--get h 'From))
                             (string-append (nm--get h 'From) " writes:\n\n")
                             "")))
               ;; quote the RENDERED text (nm--msg-body-text goes through the
               ;; html renderer when there is no text/plain) — never raw html
               (quoted (if orig (nm--quote-text (nm--msg-body-text orig)) "")))
          (unless (buffer-exists? buf) (buffer-create buf))
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf (string-append head "\n" attrib quoted))
          (switch-to-buffer! buf)
          (set-mode! "mail-compose-mode")
          (nm--compose-overlays! buf head)
          (goto-char! (string-byte-length head))
          (message "C-c C-c sends, C-c C-k aborts")))))

(define-command "notmuch-show-reply" "Reply to the message at point"
  (lambda ()
    (let ((msg (nm--msg-at (current-buffer))))
      (if msg
          (nm--compose-reply! (cadr msg))
          (message "No message at point")))))

;; newest message id of a thread (search sorts newest-first)
(define (nm--newest-msg-id thread-id)
  (let ((out (string-trim
               (nm--run (string-append "search --output=messages --limit=1 -- thread:"
                                       thread-id)))))
    (and (string-prefix? "id:" out)
         (substring out 3 (string-length out)))))

(define-command "notmuch-reply" "Reply to the newest message of the thread at point"
  (lambda ()
    (let ((th (nm--thread-at (current-buffer))))
      (if (not th)
          (message "No thread on this line")
          (let ((id (nm--newest-msg-id (nm--th-id th))))
            (if id
                (nm--compose-reply! id)
                (message "No message found in thread")))))))

(define (nm--send-route text)
  (let loop ((rs notmuch-send-routes))
    (cond ((null? rs) #f)
          ((or (equal? (car (car rs)) "")
               (string-contains? text (car (car rs))))
           (cadr (car rs)))
          (else (loop (cdr rs))))))

(define-command "mail-send" "Send this buffer as an email"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; the separator line becomes the RFC822 blank line
           (text (string-join
                   (string-split (buffer-text buf)
                                 (string-append "\n" *mail-header-separator* "\n"))
                   "\n\n"))
           (route (nm--send-route text))
           (tmp (string-append (expand-path "~") "/.aimax/outgoing.eml")))
      (if (not route)
          (message "No send route matches — set notmuch-send-routes")
          (begin
            (write-file! tmp text)
            (let ((out (shell-command->string
                         (string-append "cat " (nm--quote tmp) " | " route
                                        " && echo SENT-OK"))))
              (if (string-contains? out "SENT-OK")
                  (begin (run-command "quit-window") (message "Sent"))
                  (message (string-append "Send failed: " (string-trim out))))))))))

(define-command "mail-abort" "Abandon this compose buffer"
  (lambda ()
    (let* ((buf (current-buffer))
           (others (filter (lambda (b) (not (equal? b buf))) (buffer-list-mru))))
      (buffer-kill! buf)
      (switch-to-buffer! (if (null? others) "*scratch*" (car others)))
      (message "Aborted"))))

;;; --- targets & actions: the email at point, embark-style -------------------------

;; C-. and the model's act tool both land here — one real tag-and-verify
;; (mail-tag!), not a second copy that discards nm--run's outcome the way
;; this used to (echoing CHANGES back via message regardless of whether
;; anything was actually tagged)
(define (nm--email-tag-act changes)
  (lambda (id)
    (let ((result (mail-tag! id changes)))
      (message result)
      result)))

(register-target-provider! "notmuch-mode"
  (lambda (buf)
    (let ((th (nm--thread-at buf)))
      (and th (list 'email (nm--th-id th) (nm--th-subject th))))))

(register-target-provider! "notmuch-show-mode"
  (lambda (buf)
    (let ((th (buffer-local buf 'notmuch-thread)))
      (and th (list 'email th (or (buffer-local buf 'notmuch-subject) ""))))))

(register-actions! 'email
  (list (list "archive"  (nm--email-tag-act "-inbox"))
        (list "trash"    (nm--email-tag-act "+trash -inbox -unread"))
        (list "unread"   (nm--email-tag-act "+unread"))
        (list "mark"     (nm--email-tag-act "+m"))
        (list "read"     (lambda (id)
                           (nm--open-thread! id
                             (let ((th (nm--thread-at (current-buffer))))
                               (if th (nm--th-subject th) "")))))
        (list "reply"    (lambda (id)
                           (let ((mid (nm--newest-msg-id id)))
                             (if mid
                                 (nm--compose-reply! mid)
                                 (message "no message in thread")))))))

;;; --- context: "this" in a chat means the selected email --------------------------

(register-context-provider! "notmuch-mode"
  (lambda (buf)
    (let ((th (nm--thread-at buf)))
      (and th
           (string-append "the email thread selected in the mail list: \""
                          (nm--th-subject th) "\" from " (nm--th-authors th)
                          " (notmuch thread:" (nm--th-id th) ")")))))

(register-context-provider! "notmuch-show-mode"
  (lambda (buf)
    (let ((th (buffer-local buf 'notmuch-thread))
          (msg (nm--msg-at buf)))
      (and th
           (string-append "the open email thread \""
                          (or (buffer-local buf 'notmuch-subject) "") "\""
                          " (notmuch thread:" th ")"
                          (if msg (string-append ", message id:" (cadr msg)) ""))))))

;;; --- mail for the model -------------------------------------------------------
;;; No per-domain tools: mail is reached through eval-scheme + act. Search
;;; and read are public functions over the same code the UI uses.

(define (mail-search query)
  (let ((threads (nm--search-json query 20)))
    (if (null? threads)
        "no matches"
        (fold (lambda (acc th)
                (string-append acc
                  (nm--get th 'date_relative) " | "
                  (nm--get th 'authors) " | "
                  (nm--get th 'subject) " | "
                  (string-join (nm--get th 'tags) ",") " | thread:"
                  (nm--get th 'thread) "\n"))
              "" threads))))

(define (mail-read-thread raw)
  (let* ((id (if (string-prefix? "thread:" raw)
                 (substring raw 7 (string-length raw))
                 raw))
         (msgs (nm--show-msgs id))
         (text (car (nm--render-text "" msgs))))
    (cond ((equal? (string-trim text) "") "no such thread")
          ;; char-based cut — a byte cut could split utf-8 and poison
          ;; the json encoder
          ((> (string-length text) 8000)
           (string-append (substring text 0 8000) "\n[...truncated]"))
          (else text))))

;; how many messages match QUERY — ground truth for whether a tag change
;; actually landed, instead of trusting a shell call whose exit status
;; nm--run already throws away. #f (NOT 0) when notmuch's output can't be
;; parsed as a number — a genuinely empty result and a surprising one
;; (a warning line, a hiccup) must not collapse into the same "zero", or
;; a parse failure reads as "no such thread" for one that exists: the
;; same blind-trust shape mail-tag! exists to fix, one level down.
(define (nm--count query)
  (string->number
    (string-trim (nm--run (string-append "count -- " (nm--quote query))))))

(define (mail-tag! raw changes)
  (let* ((id (if (string-prefix? "thread:" raw)
                 (substring raw 7 (string-length raw))
                 raw))
         (n (nm--count (string-append "thread:" id))))
    (cond
      ((not n)
       (string-append "couldn't verify thread " id
                      " — notmuch count gave an unexpected answer"))
      ((= n 0) (string-append "no such thread: " id))
      (else
        (nm--run (string-append "tag " changes " -- thread:" id))
        (when (buffer-exists? *notmuch-search-buffer*)
          (nm--refresh! *notmuch-search-buffer*))
          (string-append "tagged " (number->string n) " message"
                         (if (= n 1) "" "s") " in thread " id
                         " (" changes ")")))))

;; the raw CLI, for whatever mail-search/mail-tag! don't cover — bulk
;; tag/archive by QUERY ("tag -inbox -- from:luma.com") in one call
;; instead of enumerating thread ids and tagging them one at a time, or
;; "count -- QUERY" to check a result instead of trusting a blind "done".
;; notmuch's own syntax is public, stable, and already in every model's
;; training data — better to let it speak that directly than force
;; everything through a bespoke per-thread wrapper. Same shell nm--run
;; always used; refreshes the search buffer since ARGS may have mutated
;; tags, same as mail-tag!.
(define (notmuch args)
  (let ((out (nm--run args)))
    (when (buffer-exists? *notmuch-search-buffer*)
      (nm--refresh! *notmuch-search-buffer*))
    (if (equal? (string-trim out) "") "(no output)" out)))

(category! 'mail)
(public! 'mail-search
  "(mail-search QUERY) — notmuch search (from:, to:, subject:, tag:, dates, free text); one thread per line with its thread:ID")
(public! 'mail-read-thread
  "(mail-read-thread THREAD-ID) — full text of an email thread, thread: prefix optional")
(public! 'mail-tag!
  "(mail-tag! THREAD-ID CHANGES) — apply space-separated +tag/-tag changes to a thread; returns how many messages it actually matched (a real count, not a blind \"done\") — 0 means the thread id was wrong")
(public! 'notmuch
  "(notmuch ARGS) — the raw notmuch CLI, ARGS is everything after `notmuch` as one string, e.g. \"tag -inbox -- from:luma.com\" or \"count -- tag:inbox from:luma.com\"; prefer this for bulk ops by query (archive/tag many at once) and for verifying a change actually happened, instead of enumerating thread ids one at a time")
