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
    (jj-sh root (string-append "jj log -r @ --no-graph --ignore-working-copy -T '"
                               field "' 2>/dev/null"))))

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
    ;; #t when @ changed hands, so the save may fold it into the run's change
    (and (not (equal? want have))
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
                (jj-sh root (string-append "jj describe -m 'Agent: " want "' 2>&1")))))
        #t))))

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
  (let ((base (auto-revert-base buf)))
    (or (not (string? base))
        (let ((disk (read-file (buffer-path buf))))
          (or (not (string? disk)) (equal? disk base))))))

(define (jj-save! buf)
  (if (jj-savable? buf)
      (with-current-buffer buf
        (lambda ()
          ;; buffer-save! opens the change and snapshots: jj-save-around
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
;; open change's first line, in the buffer's own status bar. The dashboard
;; pulls the line from a cache by repo root, so a chat or a list that
;; lives in the repo shows it as well as a file does. The cache fills once
;; per root, then a flush or a label refreshes it. A redraw never runs jj.
;; An unlabeled run shows its Agent: line, which is exactly the nudge to
;; call jj-describe!.
(define *jj-lines* '())       ; ((ROOT LINE) ...)
(define *jj-history* '())     ; ((ROOT SECS LINE) ...), newest first
(define *jj-dir-roots* '())   ; ((DIR ROOT) ...); ROOT is #f outside a repo

;; the repo root of DIR, remembered per directory: a redraw asks for it
;; on every command, and git-root is a walk up the tree
(define (jj-dir-root dir)
  (and (string? dir)
       (let ((hit (assoc dir *jj-dir-roots*)))
         (if hit
             (cadr hit)
             (let ((root (jj-root-of-dir dir)))
               (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
               root)))))

;; a file, a directory listing, and a chat live in a repo. A list or a
;; log does not, whatever directory it was born in.
(define (jj-buffer-root buf)
  (let ((p (buffer-path buf)))
    (cond (p (jj-root p))
          ((or (dired-buffer? buf) (chat-buffer? buf))
           (jj-dir-root (buffer-directory buf)))
          (else #f))))

(define (jj-read-line! root)
  (let* ((raw (jj-at root "description.first_line()"))
         (line (if (equal? raw "") "jj: undescribed" raw))
         (hit (assoc root *jj-lines*)))
    ;; the history keeps every line the root showed, once per change
    (unless (and hit (equal? (cadr hit) line))
      (set! *jj-history* (cons (list root (current-time) line) *jj-history*)))
    (set! *jj-lines* (alist-put *jj-lines* root line))
    line))

(public! 'jj-line-history
  "(jj-line-history BUF) -- the lines the repo of BUF showed in the bar, as ((SECS LINE) ...) newest first")
(define (jj-line-history buf)
  (let ((root (jj-buffer-root buf)))
    (if root
        (begin
          (unless (assoc root *jj-lines*) (jj-read-line! root))
          (map cdr (filter (lambda (e) (equal? (car e) root)) *jj-history*)))
        '())))

(public! 'jj-modeline-line
  "(jj-modeline-line BUF) -- the first line of the open jj change of BUF's repo, or #f outside one")
(define (jj-modeline-line buf)
  (let ((root (jj-buffer-root buf)))
    (and root
         (let ((hit (assoc root *jj-lines*)))
           (if hit (cadr hit) (jj-read-line! root))))))

;; after a flush or a label: re-read the line once, then redraw the bars
;; on screen that show this repo. Every other buffer picks the new line
;; up from the cache on its next command.
(define (jj-modeline-update! root &optional slug)
  (jj-read-line! root)
  ;; the chat that caused the commit watches it go by too
  (let ((chat (and slug (boundp 'agent-buf) (agent-buf slug))))
    (let loop ((bufs (append (map cadr (window-list)) (if chat (list chat) '())))
                 (done '()))
        (when (pair? bufs)
          (let ((b (car bufs)))
            (unless (member b done)
              (when (or (equal? b chat) (equal? (jj-buffer-root b) root))
                (dashboard--sync! b)))
            (loop (cdr bufs) (cons b done)))))))

;;; --- the hook -----------------------------------------------------------

;; Every save arrives here, yours and an agent's alike. The bytes belong to
;; whoever last wrote the buffer, which is not always whoever pressed C-x C-s.
;; The change opens before the write and the snapshot closes after it, because
;; jj reads only what is on disk when a command runs.
(define (jj-save-author buf)
  (or (jj-last-author buf) (current-edit-author)))

;; @ just changed hands and took this run's burst. Move the burst into the
;; run's own change below, so parallel runs saving in turn still leave one
;; change each. Only an undescribed change takes it: a described one is
;; finished work. A change between them that touched the same files keeps
;; the burst in @, because moving it under that change would conflict.
(define (jj-fold! root slug)
  (when (and slug (equal? (jj-at root "empty") "false"))
    (let ((x (jj-revs root (string-append "latest(remote_bookmarks()..@- & "
                                          (jj-agent-revset slug)
                                          " & description(regex:\"^Agent: \"))"))))
      (when (pair? x)
        (jj-fold-into! root "@" (car x))))))

;; the files that changed from FROM to TO, as one net diff
(define (jj-diff-files root from to)
  (map (lambda (l) (string-trim (substring l 1 (string-length l))))
       (jj-lines root (string-append "jj diff --from " from " --to " to
                                     " --summary --color never 2>/dev/null"))))

(define (jj-older? root a b)
  (pair? (jj-revs root (string-append a " & ::" b " & ~" b))))

;; Squash FROM into INTO, keeping INTO's message, when no change between
;; them touched FROM's files; moving it past such a change would conflict.
;; #t when it moved.
(define (jj-fold-into! root from into)
  (let* ((older (if (jj-older? root from into) from into))
         (newer (if (equal? older from) into from))
         (files (map cadr (jj-change-files root from)))
         (between (jj-diff-files root older (string-append newer "-"))))
    (and (null? (filter (lambda (f) (member f between)) files))
         (begin (jj-sh root (string-append "jj squash --from " from " --into " into " -u 2>&1"))
                #t))))

;; The repo each run saved into last, by its author slug. A chat's own buffer
;; often sits outside the repo it edits, so jj-describe! looks here when its
;; chat's directory is no repo.
(define *jj-run-roots* (if (boundp '*jj-run-roots*) *jj-run-roots* '()))

(define (jj-note-run-root! slug root)
  (when (and slug root)
    (set! *jj-run-roots* (cons (list slug root) (filter (lambda (e) (not (equal? (car e) slug))) *jj-run-roots*)))))

(define (jj-run-root slug)
  (let ((e (and slug (assoc slug *jj-run-roots*)))) (and e (cadr e))))

;; Every save is a buffer-save!: C-x C-s, an agent's own call, and the end
;; of a burst. The save hooks miss an agent's call, so the save itself is
;; where jj opens the change before the bytes land and snapshots after.
(define (jj-save-around orig &rest args)
  (let* ((buf (current-buffer))
         (path (if (pair? args) (car args) (buffer-path buf)))
         (root (and (string? path) (jj-root path)))
         (author (jj-save-author buf))
         (slug (jj-author-slug author)))
    (if (not (and root jj-autosave))
        (let ((r (apply orig args)))
          (when root (jj-note-run-root! slug root))
          r)
        (begin
          (unless (jj-lock! root)
            (message "jj: flush lock stuck; continuing unlocked"))
          (let* ((opened (jj-open! root author))
                 (r (apply orig args)))
            (jj-note-run-root! slug root)
            (jj-snapshot! root)
            (when opened (jj-fold! root slug))
            (jj-unlock! root)
            (jj-modeline-update! root slug)
            r)))))

(advice-remove! 'buffer-save! 'jj-run-root)
(advice-add! 'buffer-save! 'around 'jj-save jj-save-around)


;; the save hooks once did this; a reload takes them off
(remove-hook! 'before-save-hook 'jj-before-save!)
(remove-hook! 'after-save-hook 'jj-after-save!)

;;; --- the label ----------------------------------------------------------

;; A run can say what it was. The message lands on the caller's own run:
;; every unpushed change carrying its Agent: line and nothing else, found by
;; trailer, else its newest one, so a label survives other sessions flushing
;; past it and no change of the run stays bare. You describe @;
;; an untagged @ is adopted by an agent with no change of its own yet.
;; The Agent: line stays under the message: label and identity are one
;; description.
(define (jj-describe! text &optional path)
  ;; the repo: PATH's, else the chat's own directory, else the one this run
  ;; saved into last
  (let ((root (or (and path (jj-root path))
                  (jj-here)
                  (jj-run-root (jj-author-slug (or (current-edit-author) ""))))))
    (if (not root)
        #f
        (let* ((slug (jj-author-slug (or (current-edit-author) "")))
               (run (and slug (string-append "remote_bookmarks()..@ & " (jj-agent-revset slug))))
               ;; every change of the run still bare, else its newest one
               (bare (if run (jj-revs root (string-append run " & ~empty() & description(regex:\"^Agent: \")")) '()))
               (newest (if run (jj-revs root (string-append "latest(" run ")")) '()))
               (revs (cond ((pair? bare) bare)
                           ((pair? newest) newest)
                           ((not (jj-tag root)) (list "@"))
                           (else '()))))
          (if (null? revs)
              (begin (message "jj: no change of this run's to describe") #f)
              (let ((msg (if slug (string-append text "\n\nAgent: " slug) text)))
                (jj-sh root (string-append "jj describe"
                                           (apply string-append (map (lambda (r) (string-append " -r " r)) revs))
                                           " -m '" (jj-quote msg) "' 2>&1"))
                ;; a described @ is finished work: the run's next save opens
                ;; a change of its own rather than growing this one
                (when (and slug (equal? (jj-tag root) slug)
                           (equal? (jj-at root "empty") "false")
                           (not (string-prefix? "Agent: " (string-trim (jj-at root "description")))))
                  (jj-lock! root)
                  (jj-sh root "jj new 2>&1")
                  (jj-unlock! root))
                (jj-modeline-update! root slug)
                text))))))
(public! 'jj-describe! "(jj-describe! TEXT [PATH]) — describe this run's jj change as TEXT, with its Agent line, in PATH's repo, else the chat's, else the one this run saved into last; TEXT, or #f when there is no repo or no change of this run's")

(define (jj-change-tag root change)
  (let loop ((ls (jj-lines root (string-append "jj log --ignore-working-copy --no-graph --color never -r "
                                               change " -T description 2>/dev/null"))))
    (cond ((null? ls) #f)
          ((string-prefix? "Agent: " (car ls)) (substring (car ls) 7 (string-length (car ls))))
          (else (loop (cdr ls))))))

;; History from before every save went through jj holds bare changes: a run
;; split by other runs' saves, its label on the newest piece only. Fold each
;; bare change into the nearest described change of its run, else into the
;; run's nearest bare one, wherever no change between touched its files.
;; Unpushed changes only, and never @. Answers (CHANGE SLUG INTO-OR-#f) rows.
(define (jj-fold-bare! &optional dir)
  (let* ((root (if dir (jj-root-of-dir dir) (jj-here)))
         (order (if root (jj-revs root "remote_bookmarks()..@- & ~empty()") '()))
         (pos (lambda (c) (let loop ((l order) (i 0)) (cond ((null? l) 0) ((equal? (car l) c) i) (else (loop (cdr l) (+ i 1)))))))
         (nearest (lambda (c cs) (let loop ((cs cs) (best #f))
                                   (cond ((null? cs) best)
                                         ((or (not best) (< (abs (- (pos (car cs)) (pos c))) (abs (- (pos best) (pos c)))))
                                          (loop (cdr cs) (car cs)))
                                         (else (loop (cdr cs) best)))))))
    (if (not root)
        '()
        (jj-with-lock root
          (lambda ()
            (map (lambda (c)
                   (let* ((slug (jj-change-tag root c))
                          (run (string-append "remote_bookmarks()..@- & ~empty() & " (jj-agent-revset slug)))
                          (done (jj-revs root (string-append run " & ~description(regex:\"^Agent: \")")))
                          (bare (filter (lambda (x) (not (equal? x c)))
                                        (jj-revs root (string-append run " & description(regex:\"^Agent: \")"))))
                          (into (or (nearest c done) (nearest c bare))))
                     (list c slug (and into (jj-fold-into! root c into) into))))
                 (jj-revs root "remote_bookmarks()..@- & ~empty() & description(regex:\"^Agent: \")")))))))
(public! 'jj-fold-bare! "(jj-fold-bare! [DIR]) — fold each bare unpushed change into its run's nearest change where nothing between touched its files; (CHANGE SLUG INTO-OR-#f) rows")

(define (jj-with-lock root thunk)
  (jj-lock! root)
  (let ((r (thunk))) (jj-unlock! root) r))

(define (jj-describe-change! change text &optional dir)
  "(jj-describe-change! CHANGE TEXT [DIR]) — describe one unpushed change as TEXT and keep its Agent line"
  (let* ((root (if dir (jj-root-of-dir dir) (jj-here)))
         (slug (and root (jj-change-tag root change))))
    (and root
         (pair? (jj-revs root (string-append change " & remote_bookmarks()..@")))
         (begin (jj-sh root (string-append "jj describe -r " change " -m '"
                                           (jj-quote (if slug (string-append text "\n\nAgent: " slug) text)) "' 2>&1"))
                text))))
(public! 'jj-describe-change! "(jj-describe-change! CHANGE TEXT [DIR]) — describe one unpushed change as TEXT and keep its Agent line")

;;; --- the push -----------------------------------------------------------

;; Identity rides in descriptions, so there is nothing to leak and nothing
;; to squash. A push moves the tracked bookmark to the newest change that
;; holds work, then pushes it; jj still refuses an undescribed change, and
;; that is the only gate left.
(define (jj-tracked-bookmark root)
  ;; No pipe: a piped command leaves the sandbox exemption, and jj needs it.
  (let ((names (filter (lambda (b) (not (equal? b "")))
                       (map string-trim
                            (string-split (jj-sh root
                              "jj bookmark list --tracked --color never -T 'name ++ \"\\n\"' 2>/dev/null")
                                          "\n")))))
    (and (pair? names) (car (sort names)))))

(define-command "jj-push" "Advance the tracked bookmark to the tip and push to git"
  (lambda ()
    (let ((root (jj-here)))
      (if (not root)
          (message "jj: not in a jj repo")
          (let ((bm (jj-tracked-bookmark root))
                (tip (string-trim (jj-sh root
                       "jj log --no-graph --color never -T 'change_id.short()' -r 'latest((remote_bookmarks()..@) ~ empty())' 2>/dev/null"))))
            (cond ((not bm) (message "jj: no bookmark tracks a remote"))
                  ((equal? tip "") (message "jj: nothing to push"))
                  (else
                    (jj-sh root (string-append "jj bookmark set " bm " -r " tip " 2>&1"))
                    (message (string-trim (jj-sh root "jj git push 2>&1"))))))))))

;;; ---------------------------------------------------------------------------
;;; What one chat changed
;;;
;;; A conversation is safe to close when the work is no longer only in it: the
;;; buffers are saved, the changes say what they were, and the changes are past
;;; the bookmark. The Agent: line is the whole link between a chat and the repo,
;;; so every question below is one revset over that line. None of it widens to
;;; the repo. A chat asks about itself.

(define (jj-agent-revset slug)
  ;; anchored to the line, so chat-...-16 does not answer for chat-...-167
  (string-append "description(regex:\"(?m)^Agent: " slug "$\")"))

(define (jj-lines root cmd)
  (filter (lambda (s) (not (equal? s "")))
          (map string-trim (string-split (jj-sh root cmd) "\n"))))

(define (jj-revs root revset)
  (jj-lines root (string-append "jj log --no-graph --color never -r '" revset
                                "' -T 'change_id.short() ++ \"\\n\"' 2>/dev/null")))

(define (jj-change-files root change)
  (map (lambda (l)
         (list (substring l 0 1) (string-trim (substring l 1 (string-length l)))))
       (jj-lines root (string-append "jj diff -r " change
                                     " --summary --color never 2>/dev/null"))))

;; One row per change of SLUG's, oldest first. A change is open while it is @,
;; because a later burst can still amend it; past that it is local, then on the
;; bookmark, then on the bookmark's remote, which is the only state that means
;; the work left this checkout.
(define (jj-agent-changes root slug)
  (let* ((mine (jj-agent-revset slug))
         (bm (jj-tracked-bookmark root))
         (here (let ((r (jj-revs root "@"))) (and (pair? r) (car r))))
         (on-bm (if bm (jj-revs root (string-append mine " & ::" bm)) '()))
         (pushed (if bm
                     (jj-revs root (string-append mine
                                                  " & ::remote_bookmarks(exact:\""
                                                  bm "\")"))
                     '()))
         (rows (jj-lines root (string-append
                 "jj log --no-graph --color never -r '" mine "' "
                 "-T 'change_id.short() ++ \"\\t\" ++ commit_id.short() ++ \"\\t\" "
                 "++ if(empty,\"empty\",\"full\") ++ \"\\t\" "
                 "++ description.first_line() ++ \"\\n\"' 2>/dev/null"))))
    (reverse
      (map (lambda (row)
             (let* ((f (string-split row "\t"))
                    (change (car f))
                    (subject (if (> (length f) 3) (list-ref f 3) "")))
               (list 'change change
                     'commit (cadr f)
                     'state (cond ((equal? change here) 'open)
                                  ((member change pushed) 'pushed)
                                  ((member change on-bm) 'bookmarked)
                                  (else 'local))
                     'empty (equal? (list-ref f 2) "empty")
                     'described (and (not (equal? subject ""))
                                     (not (string-prefix? "Agent: " subject)))
                     'subject subject
                     'files (jj-change-files root change))))
           rows))))

(define (jj-chat-slug buf) (buffer-local buf 'agent-slug))

(public! 'chat-changes
  "(chat-changes [BUF]) -- the jj changes this chat made, oldest first, each with its state")
(define (chat-changes &optional buf0)
  (let* ((buf (or buf0 (current-buffer)))
         (slug (jj-chat-slug buf))
         (root (jj-buffer-root buf)))
    (if (and slug root) (jj-agent-changes root slug) '())))

(public! 'chat-work-state
  "(chat-work-state [BUF]) -- what this chat still holds, and whether closing it loses anything")
(define (chat-work-state &optional buf0)
  (let* ((buf (or buf0 (current-buffer)))
         (slug (jj-chat-slug buf))
         (root (jj-buffer-root buf))
         (changes (if (and slug root) (jj-agent-changes root slug) '()))
         (unsaved (if slug (jj-dirty-by (string-append "agent:" slug)) '()))
         (live (filter (lambda (c) (not (plist-get c 'empty))) changes))
         (unpushed (filter (lambda (c) (not (equal? (plist-get c 'state) 'pushed))) live))
         (unnamed (filter (lambda (c) (not (plist-get c 'described))) live)))
    (list 'slug (or slug #f)
          'root (or root #f)
          'bookmark (if root (or (jj-tracked-bookmark root) #f) #f)
          'changes changes
          'unsaved unsaved
          'unpushed (map (lambda (c) (plist-get c 'change)) unpushed)
          'unnamed (map (lambda (c) (plist-get c 'change)) unnamed)
          'verdict (cond ((not slug) 'not-a-chat)
                         ((not root) 'no-repo)
                         ((pair? unsaved) 'unsaved)
                         ((null? live) 'nothing)
                         ((pair? unpushed) 'unpushed)
                         (else 'in)))))

(define (jj-state-word s)
  (cond ((equal? s 'pushed) "pushed")
        ((equal? s 'bookmarked) "on the bookmark")
        ((equal? s 'open) "open")
        (else "local")))

(define (jj-verdict-line st)
  (let ((v (plist-get st 'verdict))
        (bm (or (plist-get st 'bookmark) "the bookmark"))
        (n (length (plist-get st 'unpushed)))
        (u (length (plist-get st 'unsaved))))
    (cond ((equal? v 'not-a-chat) "Not a chat: this buffer has no agent slug.")
          ((equal? v 'no-repo) "This chat does not stand in a jj repo.")
          ((equal? v 'unsaved)
           (string-append (number->string u)
                          " buffer(s) this chat wrote are still unsaved. Closing loses them."))
          ((equal? v 'nothing) "This chat changed nothing in the repo. Safe to close.")
          ((equal? v 'unpushed)
           (string-append (number->string n) " change(s) have not reached " bm
                          "@remote. Closing keeps them in the repo, but they are not in yet."))
          (else (string-append "Every change is past " bm "@remote. Safe to close.")))))

(public! 'chat-changes-report
  "(chat-changes-report [BUF]) -- this chat's changes and its closing verdict, as text")
(define (chat-changes-report &optional buf0)
  (let* ((buf (or buf0 (current-buffer)))
         (st (chat-work-state buf))
         (out (list (string-append (or (plist-get st 'slug) "(no slug)")
                                   "  " (or (plist-get st 'root) "")))))
    (for-each
      (lambda (c)
        (set! out (cons (string-append "  " (plist-get c 'commit)
                                       "  " (jj-state-word (plist-get c 'state))
                                       (if (plist-get c 'empty) "  empty" "")
                                       "  " (if (plist-get c 'described)
                                                 (plist-get c 'subject)
                                                 "(no description)"))
                        out))
        (for-each (lambda (f)
                    (set! out (cons (string-append "      " (car f) " " (cadr f)) out)))
                  (plist-get c 'files)))
      (plist-get st 'changes))
    (for-each (lambda (b) (set! out (cons (string-append "  unsaved: " b) out)))
              (plist-get st 'unsaved))
    (set! out (cons (string-append "\n" (jj-verdict-line st)) out))
    (string-join (reverse out) "\n")))

(public! 'chat-diff
  "(chat-diff [BUF]) -- the unified diff of every change this chat made, oldest first")
(define (chat-diff &optional buf0)
  (let* ((buf (or buf0 (current-buffer)))
         (root (jj-buffer-root buf))
         (changes (filter (lambda (c) (not (plist-get c 'empty)))
                          (chat-changes buf))))
    (if (not root)
        ""
        (string-join
          (map (lambda (c)
                 (jj-sh root (string-append "jj diff -r " (plist-get c 'change)
                                            " --git --color never 2>/dev/null")))
               changes)
          ""))))

(effects! '(write external execute display))

(define-command "chat-changes" "Show what this chat changed: its jj changes, their state, and its diff"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (or (jj-chat-slug buf) "chat"))
           (name (string-append "*changes: " slug "*"))
           (text (string-append (chat-changes-report buf) "\n\n" (chat-diff buf))))
      (diff-show! name text)
      ;; diff-show! sets the mode on whatever is current, and an agent's
      ;; pop-to-buffer displays nothing, so say which buffer it was
      (with-current-buffer name (lambda () (set-mode! "diff-show")))
      (message (jj-verdict-line (chat-work-state buf))))))

;;; --- reading ------------------------------------------------------------

;; The shell gate refuses jj, so these are how an agent reads history. They
;; never snapshot: a read must not sweep anyone's unsaved bytes into @.
(domain! 'files)
(effects! '(read external execute))

(define (jj-log &optional revset dir)
  "(jj-log [REVSET] [DIR]) — one line per change in REVSET, default the unpushed work: change, time, subject and Agent line"
  (let ((root (if dir (jj-root-of-dir dir) (jj-here))))
    (and root
         (jj-sh root (string-append
           "jj log --ignore-working-copy --no-graph --color never -r '"
           (jj-quote (or revset "remote_bookmarks()..@")) "' -T '"
           "change_id.short() ++ \" \" ++ committer.timestamp().format(\"%m-%d %H:%M\") ++ \" \" "
           "++ description.first_line() ++ \" | \" "
           "++ description.lines().filter(|l| l.starts_with(\"Agent:\")).join(\",\") ++ \"\\n\"' 2>&1")))))
(public! 'jj-log "(jj-log [REVSET] [DIR]) — one line per change in REVSET, default the unpushed work: change, time, subject and Agent line")

(define (jj-show change &optional dir)
  "(jj-show CHANGE [DIR]) — CHANGE's description, files and diff"
  (let ((root (if dir (jj-root-of-dir dir) (jj-here))))
    (and root
         (jj-sh root (string-append "jj show --ignore-working-copy --color never --git -r '"
                                    (jj-quote change) "' 2>&1")))))
(public! 'jj-show "(jj-show CHANGE [DIR]) — CHANGE's description, files and diff")
