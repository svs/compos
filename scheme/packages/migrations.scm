;;; migrations.scm --- every old-to-new conversion, run once.
;;;
;;; A saved desktop or a home directory can carry a shape the code no
;;; longer writes: an old local, marker bytes in the text, a mode under
;;; its old name, a file under its old name. Each such shape gets ONE
;;; migration here, named and dated, and the reader in its package sees
;;; only the current shape.
;;;
;;; A buffer migration runs on restore, before the mode setup, and stamps
;;; the buffer ('migrations, a persisted local), so it runs once per
;;; buffer and never again. A migration checks the old shape itself: a
;;; buffer made in this process has no stamp, and the pass runs every
;;; migration on it after the next restart.
;;;
;;; A home migration runs once per home, on the first restore of a
;;; process, when every package has loaded; <compos-home>/migrations
;;; holds the names that ran.
;;;
;;; The cut-off: a migration lives 90 days from its SINCE date. After
;;; that the code, its registration and its test go; a desktop older than
;;; the cut-off is restored as it is. M-x list-migrations shows the dates.
;;;
;;; A body names its package's functions and globals at run time, never
;;; at load: this file loads before the packages, and a reload must
;;; reach the new definitions.

(domain! 'desktop)
(effects! '(write))

;;; --- the registries --------------------------------------------------------------

;; ((NAME SINCE FN) ...) in registration order
(define *buffer-migrations* '())

(public! 'define-buffer-migration!
  "(define-buffer-migration! NAME SINCE FN) - register FN as the one-shot migration NAME; SINCE is its date, YYYY-MM-DD; FN takes the buffer")
(define (define-buffer-migration! name since fn)
  (set! *buffer-migrations*
    (append (filter (lambda (m) (not (equal? (car m) name))) *buffer-migrations*)
            (list (list name since fn)))))

(public! 'buffer-migrations-done
  "(buffer-migrations-done BUF) - the names of the migrations that ran on BUF")
(define (buffer-migrations-done buf)
  (or (buffer-local buf 'migrations) '()))

;; one migration that throws does not stop the restore or the others
(define (migration--run! m buf)
  (unless (ignore-errors (lambda () ((car (cdr (cdr m))) buf) #t))
    (message (string-append "migration " (symbol->string (car m))
                            " failed on " buf))))

(public! 'migrate-buffer!
  "(migrate-buffer! BUF) - run every registered migration BUF has not seen, and stamp it; return the names that ran")
(define (migrate-buffer! buf)
  (migrate-home-once!)
  (let* ((done (buffer-migrations-done buf))
         (due (filter (lambda (m) (not (member (car m) done))) *buffer-migrations*)))
    (when (pair? due)
      (for-each (lambda (m) (migration--run! m buf)) due)
      (buffer-set-local! buf 'migrations (append done (map car due))))
    (map car due)))

(add-hook! 'buffer-restore-hook 'migrate-buffer!)

;; ((NAME SINCE FN) ...) in registration order; FN takes nothing
(define *home-migrations* '())

;; the stamp file; a test points it at a directory of its own
(define *home-migrations-file* #f)
(define (home-migrations-file)
  (or *home-migrations-file* (string-append (compos-home) "/migrations")))

(public! 'define-home-migration!
  "(define-home-migration! NAME SINCE FN) - register FN as the one-shot migration NAME of the home directory; SINCE is its date, YYYY-MM-DD")
(define (define-home-migration! name since fn)
  (set! *home-migrations*
    (append (filter (lambda (m) (not (equal? (car m) name))) *home-migrations*)
            (list (list name since fn)))))

(public! 'home-migrations-done
  "(home-migrations-done) - the names of the migrations that ran on this home")
(define (home-migrations-done)
  (let ((text (read-file (home-migrations-file))))
    (if (string? text)
        (map string->symbol
             (filter (lambda (l) (not (equal? l "")))
                     (map string-trim (string-split text "\n"))))
        '())))

(define (home-migration--run! m)
  (unless (ignore-errors (lambda () ((car (cdr (cdr m)))) #t))
    (message (string-append "migration " (symbol->string (car m)) " failed"))))

(public! 'migrate-home!
  "(migrate-home!) - run every registered home migration this home has not seen, and stamp it; return the names that ran")
(define (migrate-home!)
  (let* ((done (home-migrations-done))
         (due (filter (lambda (m) (not (member (car m) done))) *home-migrations*)))
    (when (pair? due)
      (for-each home-migration--run! due)
      (write-file! (home-migrations-file)
        (string-append
          (string-join (map symbol->string (append done (map car due))) "\n")
          "\n")))
    (map car due)))

;; once per process, on the first restore: every package has loaded by then
(define *home-migrated?* #f)
(define (migrate-home-once!)
  (unless *home-migrated?*
    (set! *home-migrated?* #t)
    (migrate-home!)))

;;; --- the chat ----------------------------------------------------------------------

;; a chat saved before the record existed carries (role text) pairs: read
;; them once, as text turns, and drop the old local
(define-buffer-migration! 'chat-record "2026-08-20"
  (lambda (buf)
    (let ((old (buffer-local buf 'chat-turns)))
      (when (and old (null? (chat-record buf)))
        (buffer-set-local! buf 'chat-wire-turns
          (map (lambda (t) (list 'role (car t) 'blocks (list (list "text" (car (cdr t))))))
               old))
        (buffer-set-local! buf 'chat-turns #f)))))

;; pre-group companions carried a 'companion-of pointer: both ends get the
;; 'group tag, which groups.scm folds into a record on its first read
(define-buffer-migration! 'chat-companion-group "2026-08-20"
  (lambda (buf)
    (let ((doc (buffer-local buf 'companion-of)))
      (when (and doc (not (buffer-local buf 'group)))
        (let ((g (or (and (buffer-exists? doc) (buffer-local doc 'group))
                     doc)))
          (buffer-set-local! buf 'group g)
          (when (and (buffer-exists? doc)
                     (not (buffer-local doc 'group)))
            (buffer-set-local! doc 'group g)))))))

;; a transcript from before the mark was a buffer-local: the mark sits at
;; the marker's last occurrence
(define (migration--chat-marker-mark buf)
  (let loop ((ms (re-find* *chat-input-marker* (buffer-text buf)))
             (last (buffer-size buf)))
    (if (null? ms) last (loop (cdr ms) (car (car ms))))))

;; a chat from before the marker left the live input still carries the
;; marker bytes at its mark: remove them, keep the draft after them, and
;; record that the input starts at the mark. A chat with the marker in
;; its text and no mark gets its mark from the last marker first. A chat
;; in the new layout is left as it is.
(define-buffer-migration! 'chat-input-marker "2026-09-05"
  (lambda (buf)
    (let ((mb (string-byte-length *chat-input-marker*)))
      (when (and (not (buffer-local buf 'agent-saved-mark))
                 (pair? (re-find* *chat-input-marker* (buffer-text buf))))
        (buffer-set-local! buf 'agent-saved-mark (migration--chat-marker-mark buf)))
      (when (buffer-local buf 'agent-saved-mark)
        (let ((size (buffer-size buf))
              (m (chat-mark buf)))
          (when (and (<= (+ m mb) size)
                     (equal? (substring-bytes (buffer-text buf) m (+ m mb))
                             *chat-input-marker*))
            (buffer-delete-range! buf m mb))
          ;; the local cannot sit past the end after the delete
          (buffer-set-local! buf 'agent-saved-mark (chat-mark buf))
          (buffer-set-local! buf 'agent-marker-bytes 0))))))

;;; --- the terminal ------------------------------------------------------------------

;; an old desktop names a terminal buffer's mode shell-mode; term-mode is
;; the one name
(define-buffer-migration! 'shell-mode-name "2026-09-01"
  (lambda (buf)
    (when (equal? (buffer-local buf 'mode-name) "shell-mode")
      (buffer-set-local! buf 'mode-name "term-mode"))))

;;; --- the groups --------------------------------------------------------------------

;; a desktop from the days a buffer held several groups carries a
;; 'group-ids list: its first id becomes the buffer's one group
(define-buffer-migration! 'group-ids-to-group-id "2026-10-16"
  (lambda (buf)
    (let ((ids (buffer-local buf 'group-ids)))
      (when (pair? ids)
        (unless (buffer-local buf 'group-id)
          (buffer-set-local! buf 'group-id (car ids)))
        (buffer-set-local! buf 'group-ids #f)))))

;;; --- the diff ----------------------------------------------------------------------

;; a diff saved before the backend split names its mode git-diff or
;; git-show and carries 'git-* locals: the git backend and its 'diff-*
;; locals take over, and the mode takes its current name
(define-buffer-migration! 'git-diff-backend "2026-10-16"
  (lambda (buf)
    (let ((mode (buffer-local buf 'mode-name)))
      (when (member mode '("git-diff" "git-show"))
        (unless (buffer-local buf 'diff-backend)
          (buffer-set-local! buf 'diff-backend "git")
          (when (buffer-local buf 'git-root)
            (buffer-set-local! buf 'diff-root (buffer-local buf 'git-root)))
          (buffer-set-local! buf 'diff-scope (or (buffer-local buf 'git-prefix) ""))
          (when (buffer-local buf 'git-watch)
            (buffer-set-local! buf 'diff-watch #t)))
        (buffer-set-local! buf 'git-root #f)
        (buffer-set-local! buf 'git-prefix #f)
        (buffer-set-local! buf 'git-watch #f)
        (buffer-set-local! buf 'mode-name
          (if (equal? mode "git-diff") "diff-mode" "diff-show"))))))

;;; --- the mail ----------------------------------------------------------------------

;; a search saved before the query stack carries one derived
;; 'notmuch-query: it becomes the base with no filters
(define-buffer-migration! 'notmuch-query-stack "2026-10-16"
  (lambda (buf)
    (let ((old (buffer-local buf 'notmuch-query)))
      (when old
        (unless (buffer-local buf 'notmuch-query-base)
          (buffer-set-local! buf 'notmuch-query-base old)
          (buffer-set-local! buf 'notmuch-query-filters '()))
        (buffer-set-local! buf 'notmuch-query #f)))))

;;; --- the inline LLM ----------------------------------------------------------------

;; a document saved before addressable blocks carries its M-o responses as
;; (START END) ranges: 'llm-responses mirrored the painted overlays, and
;; 'llm-legacy-responses froze that mirror at the first addressable send.
;; Each range becomes one complete llm-response block, so the block
;; records are the one place a response lives. A range over a block that
;; already exists is stale and goes; the mirror stays, written from the
;; blocks from now on.
(define-buffer-migration! 'llm-responses-to-blocks "2026-10-16"
  (lambda (buf)
    (let* ((blocks (llm-mode--addressable-kind buf 'llm-response))
           (turns (llm-mode--addressable-turn-ranges buf))
           (ranges (or (buffer-local buf 'llm-legacy-responses)
                       (if (null? blocks) (buffer-local buf 'llm-responses) '())))
           (size (buffer-size buf)))
      (when (pair? ranges)
        (for-each
          (lambda (range)
            (when (and (pair? range)
                       (number? (car range)) (number? (cadr range))
                       (<= 0 (car range)) (< (car range) (cadr range))
                       (<= (cadr range) size)
                       (not (llm-mode--range-overlaps-any? range turns)))
              (ignore-errors
                (lambda ()
                  (block-close-end! buf
                    (block-create! buf 'llm-response (car range) (cadr range)
                                   #f 'complete '()))))))
          ranges))
      (buffer-set-local! buf 'llm-legacy-responses #f))))
