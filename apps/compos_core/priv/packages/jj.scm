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
;;; That identity is worth nothing after the session, and it does not need
;;; to be: agent changes live between @- and @ and collapse into your own
;;; commit when you squash before a push. jj-agent-changes is what makes that
;;; a rule instead of a habit. A directory lock under .jj serializes every
;;; flush across processes, so two authors' snapshots cannot interleave.

(domain! 'files)
(effects! '(write external execute))

(defcustom 'jj-autosave #f
  "Save a file buffer when its author stops writing, and snapshot it into jj."
  'group 'buffers 'type 'boolean)

(defcustom 'jj-agent-domain "agents.compos.local"
  "The email domain that marks a jj change as an agent's. jj-push reads it."
  'group 'buffers 'type 'string)

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

;; A name that cannot survive a shell word is not worth escaping: the slug is
;; machine-made and always safe, so an odd chat name falls back to it.
(define (jj-plain-word name fallback)
  (if (and (string? name)
           (not (string-index name "'"))
           (not (string-index name "\\")))
      name
      fallback))

;; The chat's display name reads better in jj log than the slug does.
(define (jj-chat-name slug)
  (let ((buf (and (boundp 'agent-buf) (agent-buf slug))))
    (if (and (string? buf) (string-prefix? "*chat:" buf))
        (jj-plain-word (substring buf 6 (- (string-length buf) 1)) slug)
        slug)))

;; (NAME EMAIL) for an agent, #f for you: you keep the jj config identity.
(define (jj-identity author)
  (let ((slug (jj-author-slug author)))
    (and slug
         (list (jj-chat-name slug)
               (string-append slug "@" jj-agent-domain)))))

;;; --- the snapshot -------------------------------------------------------

(define (jj-env id)
  (if id
      (string-append "JJ_USER='" (car id) "' JJ_EMAIL='" (cadr id) "' ")
      ""))

;; Open the change this author's writes belong in. This has to happen BEFORE
;; the write, never after: jj folds the working copy into @ at the start of
;; almost every command, so a change opened afterwards leaves the work sitting
;; in the previous author's change and attributes it to them.
;;
;; A new change opens only on a handover, so one author's whole run stays one
;; change however many times it reached disk. An untouched @ takes the new
;; author instead of forking, so a quiet handover leaves no empty change.
(define (jj-open! root author)
  (let* ((id (jj-identity author))
         (want (if id
                   (cadr id)
                   (string-trim (jj-sh root "jj config get user.email 2>/dev/null")))))
    (unless (equal? (jj-at root "author.email()") want)
      (jj-sh root (string-append (jj-env id)
                                 (if (equal? (jj-at root "empty") "true")
                                     "jj metaedit --update-author"
                                     "jj new")
                                 " 2>&1")))))

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
        (jj-unlock! root)))))

;; Appended, so auto-revert's guard runs first: a save it refuses must not
;; leave an opened change behind.
(add-hook! 'before-save-hook 'jj-before-save! #t)
(add-hook! 'after-save-hook 'jj-after-save!)

;;; --- the guard ----------------------------------------------------------

;; What a push would add, narrowed to what an agent authored. A revset asks
;; this without a template, so nothing here has to escape a shell word twice.
(define (jj-agent-changes root)
  (string-trim
    (jj-sh root (string-append
                  "jj log -r 'remote_bookmarks()..@ & author_email(substring:\"@"
                  jj-agent-domain
                  "\")' --no-graph --color never 2>&1"))))

;; Agent identity is worth nothing outside the session and must not reach a
;; remote. Squash first; this is the check that says when you have not.
(define-command "jj-agent-changes" "List agent-authored changes not yet pushed"
  (lambda ()
    (let ((root (jj-here)))
      (if (not root)
          (message "jj: not in a jj repo")
          (let ((agents (jj-agent-changes root)))
            (message (if (equal? agents "")
                         "jj: no agent-authored changes in the stack"
                         agents)))))))

;; Push is the boundary where agent identity would leak into public history.
;; A synthetic agents.compos.local address must never reach the remote, so
;; the push refuses while any change in the stack carries one; squash those
;; into your own change first.
(define-command "jj-push" "Push to git; refuse while agent-authored changes remain"
  (lambda ()
    (let ((root (jj-here)))
      (if (not root)
          (message "jj: not in a jj repo")
          (let ((agents (jj-agent-changes root)))
            (if (equal? agents "")
                (message (string-trim (jj-sh root "jj git push 2>&1")))
                (message (string-append "jj: not pushing; agent-authored changes in the stack:\n"
                                        agents))))))))
