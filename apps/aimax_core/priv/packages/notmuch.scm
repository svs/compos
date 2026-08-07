;;; notmuch.scm --- email client over the notmuch CLI, userland Scheme.
;;;
;;; No Elixir knows what email is. Sync is external (lieer/mbsync cron);
;;; this package reads the local database with `notmuch ... --format=json`,
;;; renders search and thread buffers, tags, replies, and sends. The
;;; extensibility bar, same as dired: primitives + shell + json-parse.
;;;
;;; Search buffer keys:  n/p move · RET open thread · a archive · d trash
;;;                      t edit tags · s new search · g refresh · q quit
;;; Thread buffer keys:  a archive · r reply · q quit
;;; Compose buffer keys: C-c C-c send · C-c C-k abort
;;;
;;; Chat integration: context providers tell chat/agent what "this" means
;;; (the selected search line, or the thread being read), and tools let
;;; the model search and read mail itself.

(defgroup 'notmuch "Email: notmuch search, reading, and sending.")

(defcustom 'notmuch-program "notmuch"
  "The notmuch executable." 'group 'notmuch)
(defcustom 'notmuch-search-limit 50
  "How many threads a search buffer shows." 'group 'notmuch)
(defcustom 'notmuch-default-query "tag:inbox"
  "The query the notmuch command opens with." 'group 'notmuch)

;; (substring-of-From-or-filename  send-command) — first match wins,
;; "" is the fallback route. Override in init.scm for other accounts.
(define notmuch-send-routes
  '(("svsrecruiting" "gmi send -t -C ~/Mail/svsrecruiting")
    ("" "msmtp -t")))

(define *notmuch-search-buffer* "*notmuch*")

;;; --- CLI plumbing -------------------------------------------------------------

(define (nm--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (nm--run args)
  (shell-command->string (string-append notmuch-program " " args)))

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

;;; --- search buffer ------------------------------------------------------------

(define (nm--search-json query limit)
  (or (nm--json (string-append "search --format=json --limit="
                               (number->string limit) " -- " (nm--quote query)))
      '()))

(define (nm--search-line th)
  (string-append
    (nm--fit (nm--get th 'date_relative) 13) " "
    (nm--fit (nm--get th 'authors) 24) " "
    (nm--get th 'subject)
    "  (" (string-join (nm--get th 'tags) " ") ")\n"))

(define (nm--refresh! buf)
  (let* ((query (or (buffer-local buf 'notmuch-query) notmuch-default-query))
         (threads (nm--search-json query notmuch-search-limit))
         (old-point (buffer-point buf)))
    (buffer-set-local! buf 'notmuch-threads
      (map (lambda (th) (list (nm--get th 'thread)
                              (nm--get th 'subject)
                              (nm--get th 'authors)))
           threads))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (string-append "notmuch: " query
                                       " (" (number->string (length threads)) ")\n"))
    (for-each (lambda (th) (buffer-append! buf (nm--search-line th))) threads)
    (when (equal? buf (current-buffer))
      (goto-char! (min old-point (buffer-size buf))))))

;; the entry index of BUF's point: line number - 1 (line 0 is the header),
;; #f off the listing
(define (nm--index-at buf)
  (let* ((before (substring-bytes (buffer-text buf) 0 (buffer-point buf)))
         (line (- (length (string-split before "\n")) 1))
         (n (length (or (buffer-local buf 'notmuch-threads) '()))))
    (and (>= line 1) (<= line n) (- line 1))))

;; (thread-id subject authors) under BUF's point, or #f
(define (nm--thread-at buf)
  (let ((i (nm--index-at buf)))
    (and i (list-ref (buffer-local buf 'notmuch-threads) i))))

(define-mode "notmuch-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (local-set-key "n" "notmuch-next")
      (local-set-key "p" "notmuch-prev")
      (local-set-key "RET" "notmuch-open-thread")
      (local-set-key "a" "notmuch-archive")
      (local-set-key "d" "notmuch-trash")
      (local-set-key "t" "notmuch-edit-tags")
      (local-set-key "s" "notmuch-search")
      (local-set-key "g" "notmuch-refresh")
      (local-set-key "q" "quit-window")
      ;; fresh open and desktop restore take the same path: rebuild the
      ;; listing from the 'notmuch-query local (live data beats stale text)
      (nm--refresh! buf))))

(define-command "notmuch" "Open the notmuch mail search buffer"
  (lambda ()
    (let ((buf *notmuch-search-buffer*))
      (unless (buffer-exists? buf) (buffer-create buf))
      (switch-to-buffer! buf)
      (unless (buffer-local buf 'notmuch-query)
        (buffer-set-local! buf 'notmuch-query notmuch-default-query))
      (set-mode! "notmuch-mode")
      (goto-char! 0) (next-line!) (beginning-of-line!))))

(define-command "notmuch-next" "Move to the next thread"
  (lambda () (next-line!) (beginning-of-line!)))
(define-command "notmuch-prev" "Move to the previous thread"
  (lambda () (previous-line!) (beginning-of-line!)))

(define-command "notmuch-refresh" "Re-run the search and refresh the listing"
  (lambda () (nm--refresh! (current-buffer)) (message "Refreshed")))

(define-command "notmuch-search" "Prompt for a notmuch query and show it"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Notmuch search: " '()
        (lambda (q)
          (buffer-set-local! buf 'notmuch-query q)
          (nm--refresh! buf)
          (goto-char! 0) (next-line!) (beginning-of-line!))))))

(define (nm--tag! buf changes)
  (let ((th (nm--thread-at buf)))
    (if th
        (begin
          (nm--run (string-append "tag " changes " -- thread:" (car th)))
          (nm--refresh! buf)
          (next-line!) (beginning-of-line!)
          (message changes))
        (message "No thread on this line"))))

(define-command "notmuch-archive" "Archive the thread at point (-inbox)"
  (lambda () (nm--tag! (current-buffer) "-inbox")))
(define-command "notmuch-trash" "Trash the thread at point (+trash -inbox)"
  (lambda () (nm--tag! (current-buffer) "+trash -inbox")))

(define-command "notmuch-edit-tags" "Edit tags of the thread at point (+tag -tag ...)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (nm--thread-at buf)
          (minibuffer-read "Tags (+add -remove): " '()
            (lambda (changes) (nm--tag! buf changes)))
          (message "No thread on this line")))))

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
          ((nm--get part 'filename)
           (string-append "[attachment: " (nm--get part 'filename) "]\n"))
          (else ""))))

(define (nm--parts-text parts)
  (fold (lambda (acc p) (string-append acc (nm--part-text p))) "" parts))

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

(define (nm--msg-render msg)
  (let ((h (nm--get msg 'headers)))
    (string-append
      "From: " (or (nm--get h 'From) "") "\n"
      "Date: " (or (nm--get h 'Date) "") "\n"
      (let ((to (nm--get h 'To)))
        (if to (string-append "To: " to "\n") ""))
      "\n"
      (nm--parts-text (nm--get msg 'body))
      "\n")))

(define (nm--show-render thread-id)
  (let* ((forest (or (nm--json (string-append
                                 "show --format=json --include-html=false thread:"
                                 thread-id))
                     '()))
         (msgs (nm--flatten-msgs forest)))
    (if (null? msgs)
        (list "" '())
        (let loop ((ms msgs) (n 1) (text (string-append
                                           (or (nm--get (nm--get (car msgs) 'headers) 'Subject) "")
                                           "\n"))
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
                            offsets))))))))

(define-mode "notmuch-show-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (local-set-key "a" "notmuch-show-archive")
      (local-set-key "r" "notmuch-show-reply")
      (local-set-key "q" "quit-window")
      (let ((th (buffer-local buf 'notmuch-thread)))
        (when th
          (let ((rendered (nm--show-render th)))
            (buffer-delete-range! buf 0 (buffer-size buf))
            (buffer-append! buf (car rendered))
            (buffer-set-local! buf 'notmuch-msgs (cadr rendered))
            (goto-char! 0)))))))

(define (nm--open-thread! thread-id subject)
  (let ((buf (string-append "*mail: " (nm--trunc subject 48) "*")))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'notmuch-thread thread-id)
    (buffer-set-local! buf 'notmuch-subject subject)
    (switch-to-buffer! buf)
    (set-mode! "notmuch-show-mode")
    ;; reading marks read, like every mail client
    (nm--run (string-append "tag -unread -- thread:" thread-id))
    buf))

(define-command "notmuch-open-thread" "Open the thread at point"
  (lambda ()
    (let ((th (nm--thread-at (current-buffer))))
      (if th
          (nm--open-thread! (car th) (cadr th))
          (message "No thread on this line")))))

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

(define-mode "mail-compose-mode"
  (lambda ()
    (local-set-key "C-c C-c" "mail-send")
    (local-set-key "C-c C-k" "mail-abort")))

(define-command "notmuch-show-reply" "Reply to the message at point"
  (lambda ()
    (let ((msg (nm--msg-at (current-buffer))))
      (if (not msg)
          (message "No message at point")
          (let ((template (nm--run (string-append "reply id:" (nm--quote (cadr msg)))))
                (buf "*compose*"))
            (unless (buffer-exists? buf) (buffer-create buf))
            (buffer-delete-range! buf 0 (buffer-size buf))
            (buffer-append! buf template)
            (switch-to-buffer! buf)
            (set-mode! "mail-compose-mode")
            (end-of-buffer!)
            (message "C-c C-c sends, C-c C-k aborts"))))))

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
           (text (buffer-text buf))
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

;;; --- context: "this" in a chat means the selected email --------------------------

(register-context-provider! "notmuch-mode"
  (lambda (buf)
    (let ((th (nm--thread-at buf)))
      (and th
           (string-append "the email thread selected in the mail list: \""
                          (cadr th) "\" from " (caddr th)
                          " (notmuch thread:" (car th) ")")))))

(register-context-provider! "notmuch-show-mode"
  (lambda (buf)
    (let ((th (buffer-local buf 'notmuch-thread))
          (msg (nm--msg-at buf)))
      (and th
           (string-append "the open email thread \""
                          (or (buffer-local buf 'notmuch-subject) "") "\""
                          " (notmuch thread:" th ")"
                          (if msg (string-append ", message id:" (cadr msg)) ""))))))

;;; --- tools: the model reads mail through the same code the UI uses ---------------

(define-tool! 'notmuch-search
  (string-append
    "Search the user's local email with notmuch. Query syntax: from:, to:, "
    "subject:, tag: (inbox, unread, important...), date:since..until, plus "
    "bare words for full-text. Returns one thread per line with its "
    "thread:ID for read-email-thread.")
  (list (list 'query "string" "notmuch query string"))
  (lambda (args)
    (let ((threads (nm--search-json (custom--plist-get args 'query) 20)))
      (if (null? threads)
          "no matches"
          (fold (lambda (acc th)
                  (string-append acc
                    (nm--get th 'date_relative) " | "
                    (nm--get th 'authors) " | "
                    (nm--get th 'subject) " | "
                    (string-join (nm--get th 'tags) ",") " | thread:"
                    (nm--get th 'thread) "\n"))
                "" threads)))))

(define-tool! 'read-email-thread
  (string-append
    "Read a full email thread. THREAD is a notmuch thread id — from a "
    "notmuch-search result (thread:...) or from the editor context when the "
    "user has an email selected.")
  (list (list 'thread "string" "thread id, with or without the thread: prefix"))
  (lambda (args)
    (let* ((raw (custom--plist-get args 'thread))
           (id (if (string-prefix? "thread:" raw)
                   (substring raw 7 (string-length raw))
                   raw))
           (text (car (nm--show-render id))))
      (cond ((equal? text "") "no such thread")
            ;; char-based cut — a byte cut could split utf-8 and poison
            ;; the json encoder (see agent-transcript-tail)
            ((> (string-length text) 8000)
             (string-append (substring text 0 8000) "\n[...truncated]"))
            (else text)))))

(define-tool! 'notmuch-tag
  "Change tags on a notmuch thread, e.g. \"-inbox\" to archive or \"+important\". Ask before destructive changes."
  (list (list 'thread "string" "thread id")
        (list 'changes "string" "space-separated +tag/-tag changes"))
  (lambda (args)
    (let* ((raw (custom--plist-get args 'thread))
           (id (if (string-prefix? "thread:" raw)
                   (substring raw 7 (string-length raw))
                   raw)))
      (nm--run (string-append "tag " (custom--plist-get args 'changes)
                              " -- thread:" id))
      (when (buffer-exists? *notmuch-search-buffer*)
        (nm--refresh! *notmuch-search-buffer*))
      "done")))

(global-set-key "C-c n" "notmuch")
