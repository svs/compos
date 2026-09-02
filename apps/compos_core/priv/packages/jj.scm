;;; jj.scm --- the working copy follows the buffers, and keeps the writer.
;;;
;;; A buffer edit and a disk write run on two different clocks. The weave
;;; records every edit with its author as it happens. Disk needs whole
;;; files, because the hot-reload watcher compiles whatever it finds. And
;;; jj sees only disk, never the buffer. So a save fires at the end of one
;;; author's burst, and a new jj change opens only when the author changes:
;;; one change per author-run, not one per save.
;;;
;;; An agent needs no identity of its own. chat.scm already dispatches every
;;; tool call inside (with-edit-author "agent:SLUG" ...), so the author
;;; rides on the edit before it reaches the buffer, and the tool call is
;;; itself the burst: its end is the boundary, with no change hook and no
;;; debounce. buffer-edit-log then answers who wrote a buffer last, so
;;; nothing here keeps state the weave already holds.
;;;
;;; Identity is something a change says, not something it is: every change
;;; carries the jj config author, and a run's session rides in an Agent:
;;; line in the description, written when the run's change opens and kept
;;; when jj-describe! labels it. Nothing synthetic reaches public history,
;;; so a push needs no guard and no squash ceremony. Byte-level attribution
;;; stays in the weave. A directory lock under .jj serializes every flush
;;; across processes, so two runs' snapshots cannot interleave.

(domain! 'files)
(effects! '(write external execute))

(defcustom 'jj-autosave #f
  "Save a file buffer when its author stops writing, and snapshot it into jj."
  'group 'buffers 'type 'boolean)

;;; --- the repo -----------------------------------------------------------

;; Two ordinary absences. jj may not be installed, and this checkout may never
;; have been jj-initialised. The binary is asked for once a session and says so
;; once, because otherwise every save would fail four shell calls in silence.
;; The checkout is the .jj test below and stays quiet: most repos are not jj
;; repos, and that is not a thing to be told about.
(define *jj-available* (quote unknown))

(define (jj-available?)
  (when (equal? *jj-available* (quote unknown))
    (set! *jj-available*
          (not (equal? (string-trim (shell-command->string "command -v jj 2>/dev/null" "/"))
                       "")))
    (unless *jj-available*
      (message "jj: not installed, so jj-autosave is doing nothing")))
  *jj-available*)

(define-command "jj-recheck" "Look for the jj binary again"
  (lambda ()
    (set! *jj-available* (quote unknown))
    (message (if (jj-available?) "jj: found" "jj: still not installed"))))

;; git-root answers (error MSG) rather than raising, so string? is the test.
(define (jj-root-of-dir dir)
  (and (jj-available?)
       (string? dir)
       (let ((root (git-root dir)))
         (and (string? root)
              (file-exists? (string-append root "/.jj"))
              root))))

;; The colocated jj repo holding PATH, or #f. Everything below is a no-op
;; outside one, so a buffer from another tree costs one git-root call.
(define (jj-root path)
  (and (string? path) (jj-root-of-dir (path-directory path))))

(define (jj-here)
  (or (jj-root (buffer-path (current-buffer)))
      (jj-root-of-dir (buffer-directory (current-buffer)))))

(define (jj-sh root cmd) (shell-command->string cmd root))

(define (jj-at root field)
  (string-trim
    (jj-sh root (string-append "jj log -r @ --no-graph -T '" field "' 2>/dev/null"))))

;;; --- who wrote it -------------------------------------------------------

(define (jj-author-slug author)
  (and (string? author)
       (string-prefix? "agent:" author)
       (substring author 6 (string-length author))))

;; A description travels through one shell single-quoted word: close it,
;; escape the quote, and reopen.
(define (jj-quote s)
  (string-join (string-split s "'") "'\\''"))

;;; --- the snapshot -------------------------------------------------------

;; The run's tag is the Agent: line in @'s description; #f means yours.
(define (jj-tag root)
  (let loop ((ls (string-split (jj-at root "description") "\n")))
    (cond ((null? ls) #f)
          ((string-prefix? "Agent: " (car ls))
           (substring (car ls) 7 (string-length (car ls))))
          (else (loop (cdr ls))))))

;; Open the change this run's writes belong in. This has to happen BEFORE
;; the write, never after: jj folds the working copy into @ at the start of
;; almost every command, so a change opened afterwards leaves the work
;; sitting in the previous run's change.
;;
;; A new change opens only on a handover, so one run stays one change
;; however many times it reached disk. An untouched @ with nothing to say
;; takes the new tag instead of forking, so a quiet handover leaves no
;; empty change behind.
(define (jj-open! root author)
  (let ((want (jj-author-slug author))
        (have (jj-tag root)))
    (unless (equal? want have)
      (let* ((d (string-trim (jj-at root "description")))
             (retag (and (equal? (jj-at root "empty") "true")
                         (or (equal? d "") (string-prefix? "Agent: " d)))))
        (if retag
            (jj-sh root (string-append "jj describe -m '"
                                       (if want (string-append "Agent: " want) "")
                                       "' 2>&1"))
            (begin
              (jj-sh root "jj new 2>&1")
              (when want
                (jj-sh root (string-append "jj describe -m 'Agent: " want "' 2>&1")))))))))

(define (jj-snapshot! root)
  (jj-sh root "jj util snapshot 2>&1"))

;;; --- the lock -----------------------------------------------------------

;; Two authors' flushes must not interleave: A opens its change, B runs
;; jj new before A's snapshot, and A's bytes land in B's change. One mkdir
;; is atomic for every process on this machine, another daemon included,
;; so the lock is a directory beside the repo's own store, held from open
;; to snapshot and never across user time. A holder that died leaves the
;; directory behind, so a waiter steals it after eight quiet seconds: a
;; flush is sub-second, and nothing alive holds the lock that long.
(define (jj-lock-dir root) (string-append root "/.jj/compos-flush-lock"))

(define (jj-lock! root)
  (equal? "ok"
    (string-trim
      (jj-sh root (string-append
        "i=0; until mkdir '" (jj-lock-dir root) "' 2>/dev/null; do "
        "i=$((i+1)); [ $i -ge 160 ] && rmdir '" (jj-lock-dir root) "' 2>/dev/null; "
        "[ $i -ge 200 ] && { echo stuck; exit 0; }; sleep 0.05; done; echo ok")))))

(define (jj-unlock! root)
  (jj-sh root (string-append "rmdir '" (jj-lock-dir root) "' 2>/dev/null; true")))

;;; --- the flush ----------------------------------------------------------

;; The weave already records who touched a buffer last.
(define (jj-last-author buf)
  (let ((log (buffer-edit-log buf)))
    (and (pair? log) (car (cdr (car log))))))

;; auto-revert's clobber guard lives on before-save-hook and stops a save by
;; raising, which this Scheme has no form to catch, and an agent flush should
;; not be taking the merge decision anyway. Ask the guard's question directly
;; and decline: the buffer stays dirty and the message says why.
(define (jj-savable? buf)
  (let ((base (and (boundp 'auto-revert-base) (auto-revert-base buf))))
    (or (not (string? base))
        (let ((disk (read-file (buffer-path buf))))
          (or (not (string? disk)) (equal? disk base))))))

(define (jj-save! buf)
  (if (jj-savable? buf)
      (with-current-buffer buf
        (lambda ()
          ;; open the change before the bytes land, not after
          (jj-before-save!)
          (let ((path (buffer-save!)))
            (when path (run-hooks 'after-save-hook))
            path)))
      (begin
        (message (string-append "jj: " (abbreviate-file-name (buffer-path buf))
                                " changed on disk; not saved"))
        #f)))

(define (jj-dirty-by author)
  (filter (lambda (b)
            (and (buffer-path b)
                 (buffer-modified? b)
                 (equal? (jj-last-author b) author)))
          (buffer-list)))

(define (jj-flush-author! author)
  (when jj-autosave (for-each jj-save! (jj-dirty-by author))))

;; A tool call is already an author-scoped dynamic extent, so its end is the
;; burst boundary. chat.scm and tools.scm wrap their dispatch in this.
(define (jj-with-burst author thunk)
  (let ((r (thunk)))
    (jj-flush-author! author)
    r))

;;; --- the modeline -------------------------------------------------------

;; Every buffer of the repo says which change its save would amend: the
;; open change's first line, in the buffer's own status bar. It is re-read
;; once after each flush and each label, never during a redraw, and a
;; buffer whose line is already right is left alone so a redraw costs
;; nothing. An unlabeled run shows its Agent: line, which is exactly the
;; nudge to call jj-describe!.
(define (jj-modeline-update! root &optional slug)
  (let* ((raw (jj-at root "description.first_line()"))
         (line (if (equal? raw "") "jj: undescribed" raw))
         (prefix (string-append root "/"))
         ;; the chat that caused the commit watches it go by too
         (chat (and slug (boundp 'agent-buf) (agent-buf slug))))
    (for-each
      (lambda (b)
        (let ((p (buffer-path b)))
          (when (and (or (and p (string-prefix? prefix p))
                         (and chat (equal? b chat)))
                     (not (equal? (buffer-local b 'modeline-vcs) line)))
            (buffer-set-local! b 'modeline-vcs line)
            (when (boundp 'dashboard--sync!) (dashboard--sync! b)))))
      (buffer-list))))

;;; --- the hook -----------------------------------------------------------

;; Every save arrives here, yours and an agent's alike. The bytes belong to
;; whoever last wrote the buffer, which is not always whoever pressed C-x C-s.
;; The change opens before the write and the snapshot closes after it, because
;; jj reads only what is on disk when a command runs.
(define (jj-before-save!)
  (when jj-autosave
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (root (and path (jj-root path))))
      (when root
        (unless (jj-lock! root)
          (message "jj: flush lock stuck; continuing unlocked"))
        (jj-open! root (or (jj-last-author buf) (current-edit-author)))))))

(define (jj-after-save!)
  (when jj-autosave
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (root (and path (jj-root path))))
      (when root
        (jj-snapshot! root)
        (jj-unlock! root)
        (jj-modeline-update! root
          (jj-author-slug (or (jj-last-author buf) (current-edit-author))))))))

;; Appended, so auto-revert's guard runs first: a save it refuses must not
;; leave an opened change behind.
(add-hook! 'before-save-hook 'jj-before-save! #t)
(add-hook! 'after-save-hook 'jj-after-save!)

;;; --- the label ----------------------------------------------------------

;; A run can say what it was. The message lands on the caller's own run:
;; the newest unpushed change carrying its Agent: line, found by trailer,
;; so a label survives other sessions flushing past it. You describe @;
;; an untagged @ is adopted by an agent with no change of its own yet.
;; The Agent: line stays under the message: label and identity are one
;; description.
(define (jj-describe! text)
  (let ((root (jj-here)))
    (if (not root)
        #f
        (let* ((slug (jj-author-slug (or (current-edit-author) "")))
               (mine (and slug
                          (let ((r (string-trim (jj-sh root (string-append
                                     "jj log --no-graph --color never -T 'change_id.short()' "
                                     "-r 'latest(remote_bookmarks()..@ & description(substring:\"Agent: "
                                     slug "\"))' 2>/dev/null")))))
                            (and (not (equal? r "")) r))))
               (rev (or mine (and (not (jj-tag root)) "@"))))
          (if (not rev)
              (begin (message "jj: no change of this run's to describe") #f)
              (let ((msg (if slug (string-append text "\n\nAgent: " slug) text)))
                (jj-sh root (string-append "jj describe -r " rev " -m '" (jj-quote msg) "' 2>&1"))
                (jj-modeline-update! root slug)
                text))))))

;;; --- the push -----------------------------------------------------------

;; Identity rides in descriptions, so there is nothing to leak and nothing
;; to squash: a push is a push. jj still refuses an undescribed change, and
;; that is the only gate left.
(define-command "jj-push" "Push to git"
  (lambda ()
    (let ((root (jj-here)))
      (if (not root)
          (message "jj: not in a jj repo")
          (message (string-trim (jj-sh root "jj git push 2>&1")))))))
