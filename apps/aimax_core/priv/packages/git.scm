;;; git.scm --- the live git diff buffer, in userland Scheme.
;;;
;;; M-x git-diff opens *git: ROOT*. The client draws it as file cards with
;;; side-by-side panes and intra-line word diff.
;;;
;;; THE LOAD-BEARING DECISION: the buffer text is the plain unified diff.
;;; It is the byte-addressable source of truth, so point motion, RET, folds,
;;; and desktop restore all work on it. The card view is a projection: the
;;; client parses the same bytes and draws blocks. There is no second state
;;; store, so the two views can never disagree.
;;;
;;; OFFSET RULE: point is a BYTE offset. This file works in LINE numbers and
;;; converts with line-start-position, which is O(log n) on the rope.
;;;
;;; Locals — the mode setup rebuilds presentation from all of them, so a
;;; daemon restart brings the buffer back as it was:
;;;   'git-root         the work tree this buffer shows
;;;   'git-watch        #t when the buffer follows the filesystem
;;;   'diff-open-cards  the file names whose card is open
;;;   'diff-files       the file list of the last render
;;;   'diff-status      (FILE "XY") pairs from git status
;;;   'diff-index       (HUNK-LINE FILE NEW-START) per hunk, built at render
;;;
;;; Keys: n/p hunk · N/P file · TAB fold the card · RET visit the source
;;;       g refresh · w watch · q quit · C-c C-v the plain unified view

;;; --- plists ------------------------------------------------------------------

(define (git--get pl key)
  (cond ((null? pl) #f)
        ((null? (cdr pl)) #f)
        ((equal? (car pl) key) (cadr pl))
        (else (git--get (cdr (cdr pl)) key))))

;; every primitive answers (error "message") on failure, and a real result
;; never starts with that symbol
(define (git--error? v)
  (and (pair? v) (equal? (car v) 'error)))

(define (git--buf-name root) (string-append "*git: " root "*"))

(define (git--count-lines s) (- (length (string-split s "\n")) 1))

;;; --- the unified text --------------------------------------------------------
;;; Regenerated from the structured diff, in the form the parser reads back.

(define (git--name f)
  (let ((b (git--get f 'file-b))
        (a (git--get f 'file-a)))
    (cond ((and b (not (equal? b "/dev/null"))) b)
          ((and a (not (equal? a "/dev/null"))) a)
          (else "?"))))

(define (git--side prefix p)
  (if (or (not p) (equal? p "/dev/null"))
      "/dev/null"
      (string-append prefix p)))

(define (git--file-header f)
  (let ((n (git--name f)))
    (string-append
      "diff --git a/" n " b/" n "\n"
      "--- " (git--side "a/" (git--get f 'file-a)) "\n"
      "+++ " (git--side "b/" (git--get f 'file-b)) "\n"
      (if (git--get f 'binary?)
          (string-append "Binary files a/" n " and b/" n " differ\n")
          ""))))

(define (git--line-text l)
  (string-append
    (cond ((equal? (car l) 'add) "+")
          ((equal? (car l) 'del) "-")
          (else " "))
    (cadr l)
    "\n"))

(define (git--hunk-text h)
  (string-append
    (git--get h 'header) "\n"
    (string-join (map git--line-text (git--get h 'lines)) "")))

;; -> (TEXT INDEX). INDEX is (HUNK-LINE FILE NEW-START) per hunk, in buffer
;; order, built while the text is built — never by re-reading it back.
(define (git--build files)
  (let loop ((fs files) (line 1) (chunks '()) (index '()))
    (if (null? fs)
        (list (string-join (reverse chunks) "") (reverse index))
        (let* ((f (car fs))
               (name (git--name f))
               (head (git--file-header f)))
          (let hloop ((hs (git--get f 'hunks))
                      (line (+ line (git--count-lines head)))
                      (chunks (cons head chunks))
                      (index index))
            (if (or (not hs) (null? hs))
                (loop (cdr fs) line chunks index)
                (let* ((h (car hs))
                       (t (git--hunk-text h)))
                  (hloop (cdr hs)
                         (+ line (git--count-lines t))
                         (cons t chunks)
                         (cons (list line name (git--get h 'new-start)) index)))))))))

;;; --- status ------------------------------------------------------------------

;; untracked files never appear in a diff against HEAD, and they are exactly
;; what an agent just wrote. Show them as empty cards.
(define (git--status-pairs status)
  (if (git--error? status)
      '()
      (map (lambda (e)
             (list (git--get e 'path)
                   (string-append (git--get e 'index) (git--get e 'worktree))))
           status)))

(define (git--untracked status names)
  (if (git--error? status)
      '()
      (let loop ((es status) (acc '()))
        (cond ((null? es) (reverse acc))
              ((and (equal? (git--get (car es) 'index) "?")
                    (not (member (git--get (car es) 'path) names)))
               (loop (cdr es)
                     (cons (list 'file-a #f
                                 'file-b (git--get (car es) 'path)
                                 'binary? #f
                                 'hunks '())
                           acc)))
              (else (loop (cdr es) acc))))))

;;; --- render ------------------------------------------------------------------

(define (git--apply! buf files status)
  (when (buffer-exists? buf)
    (let* ((all (append files (git--untracked status (map git--name files))))
           (names (map git--name all))
           (old-files (or (buffer-local buf 'diff-files) '()))
           (old-open (or (buffer-local buf 'diff-open-cards) '()))
           ;; controlled state: a card the reader closed stays closed across a
           ;; refresh, and a file we have never shown opens
           (open (filter (lambda (n) (if (member n old-files) (member n old-open) #t))
                         names))
           (built (git--build all))
           (text (car built))
           (old-point (buffer-point buf)))
      (buffer-set-local! buf 'diff-files names)
      (buffer-set-local! buf 'diff-open-cards open)
      (buffer-set-local! buf 'diff-status (git--status-pairs status))
      (buffer-set-local! buf 'diff-index (cadr built))
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-append! buf (if (equal? text "") "No changes.\n" text))
      ;; refresh keeps the reader where they were, clamped to the new text
      (buffer-goto! buf (min old-point (buffer-size buf)))
      (git--fontify! buf)
      (git--apply-folds! buf))))

(define (git-diff-refresh buf)
  (let ((root (buffer-local buf 'git-root)))
    (when root
      ;; never inline: the Session draws the editor, and git answers in its
      ;; own time. status first, then the diff, then one render.
      (git-status root
        (lambda (status)
          (git-diff root (list 'base "HEAD")
            (lambda (files)
              (git--apply! buf (if (git--error? files) '() files) status))))))))

;;; --- fontification (the plain view) -------------------------------------------

(define (git--fontify! buf)
  (let loop ((ls (split-lines (buffer-text buf))) (pos 0) (acc '()))
    (if (null? ls)
        (overlay-set! buf 'diff (reverse acc))
        (let* ((l (car ls))
               (len (string-byte-length l))
               (face (git--line-face l)))
          (loop (cdr ls)
                (+ pos len 1)
                (if face (cons (list pos (+ pos len) face) acc) acc))))))

(define (git--line-face l)
  (cond ((string-prefix? "diff --git " l) 'diff-file)
        ((string-prefix? "--- " l) 'diff-file)
        ((string-prefix? "+++ " l) 'diff-file)
        ((string-prefix? "Binary files " l) 'diff-file)
        ((string-prefix? "@@" l) 'diff-hunk)
        ((string-prefix? "+" l) 'diff-add)
        ((string-prefix? "-" l) 'diff-del)
        (else #f)))

;;; --- folds --------------------------------------------------------------------
;;; One state, two projections. 'diff-open-cards drives the card view; the
;;; same list becomes hidden byte ranges under the 'diff tag for the plain
;;; view, so TAB means the same thing in both.

;; -> ((FILE START-LINE END-LINE) ...) over the rendered text
(define (git--card-lines buf)
  (let loop ((ls (split-lines (buffer-text buf))) (n 1) (cur #f) (acc '()))
    (cond ((null? ls)
           (reverse (if cur (cons (append cur (list (- n 1))) acc) acc)))
          ((string-prefix? "diff --git a/" (car ls))
           (loop (cdr ls) (+ n 1)
                 (list (git--header-file (car ls)) n)
                 (if cur (cons (append cur (list (- n 1))) acc) acc)))
          (else (loop (cdr ls) (+ n 1) cur acc)))))

(define (git--header-file l)
  (let ((m (re-match "^diff --git a/(.*) b/" l)))
    (if m (cadr m) "?")))

(define (git--apply-folds! buf)
  (let ((open (or (buffer-local buf 'diff-open-cards) '())))
    (fold-set! buf 'diff
      (let loop ((cs (git--card-lines buf)) (acc '()))
        (cond ((null? cs) (reverse acc))
              ((member (car (car cs)) open) (loop (cdr cs) acc))
              (else
                ;; hide the body, keep the header line visible
                (let* ((c (car cs))
                       (start (+ (line-start-position (cadr c))
                                 (string-byte-length (git--line-at-n buf (cadr c)))))
                       (end (git--line-end buf (caddr c))))
                  (loop (cdr cs)
                        (if (> end start) (cons (list start end) acc) acc)))))))))

(define (git--line-at-n buf n)
  (let ((ls (split-lines (buffer-text buf))))
    (if (<= n (length ls)) (list-ref ls (- n 1)) "")))

(define (git--line-end buf n)
  (min (buffer-size buf)
       (+ (line-start-position n) (string-byte-length (git--line-at-n buf n)))))

;;; --- where point is -----------------------------------------------------------

(define (git--line-number buf pos)
  (let loop ((ls (split-lines (buffer-text buf))) (n 1) (at 0))
    (cond ((null? ls) n)
          ((> (+ at (string-byte-length (car ls))) pos) n)
          (else (loop (cdr ls) (+ n 1) (+ at (string-byte-length (car ls)) 1))))))

;; the card containing LINE, as (FILE START-LINE END-LINE), or #f
(define (git--card-at buf line)
  (let loop ((cs (git--card-lines buf)))
    (cond ((null? cs) #f)
          ((and (>= line (cadr (car cs))) (<= line (caddr (car cs)))) (car cs))
          (else (loop (cdr cs))))))

;; the hunk index entry at or before LINE, or #f
(define (git--hunk-at buf line)
  (let loop ((idx (or (buffer-local buf 'diff-index) '())) (best #f))
    (cond ((null? idx) best)
          ((> (car (car idx)) line) best)
          (else (loop (cdr idx) (car idx))))))

;;; --- navigation ---------------------------------------------------------------

(define (git--goto-line! n)
  (goto-char! (line-start-position n)))

;; the lines that start a hunk, and the lines that start a file card
(define (git--hunk-lines buf)
  (map car (or (buffer-local buf 'diff-index) '())))

(define (git--file-lines buf) (map cadr (git--card-lines buf)))

(define (git--next-in lines cur)
  (let loop ((ls lines))
    (cond ((null? ls) #f)
          ((> (car ls) cur) (car ls))
          (else (loop (cdr ls))))))

(define (git--prev-in lines cur)
  (let loop ((ls lines) (best #f))
    (cond ((null? ls) best)
          ((>= (car ls) cur) best)
          (else (loop (cdr ls) (car ls))))))

(define-command "git-diff-next-hunk" "Move to the next hunk"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (git--next-in (git--hunk-lines buf) (git--line-number buf (point)))))
      (if n (git--goto-line! n) (message "no next hunk")))))

(define-command "git-diff-prev-hunk" "Move to the previous hunk"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (git--prev-in (git--hunk-lines buf) (git--line-number buf (point)))))
      (if n (git--goto-line! n) (message "no previous hunk")))))

(define-command "git-diff-next-file" "Move to the next file"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (git--next-in (git--file-lines buf) (git--line-number buf (point)))))
      (if n (git--goto-line! n) (message "no next file")))))

(define-command "git-diff-prev-file" "Move to the previous file"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (git--prev-in (git--file-lines buf) (git--line-number buf (point)))))
      (if n (git--goto-line! n) (message "no previous file")))))

;;; --- browsing -----------------------------------------------------------------
;;; A file you reach from the code browser opens READ-ONLY. You came to read
;;; it, and a stray keystroke in a file you are only passing through is an
;;; edit you did not mean. C-x C-q makes it writable, like Emacs.
;;;
;;; Set *browse-read-only* to #f in your init.scm to open writable instead.
;;; code.scm (CB7) visits through the same helper.

(define *browse-read-only* #t)

(define (browse-visit path)
  (visit path)
  (when *browse-read-only*
    (buffer-set-read-only! (current-buffer) #t)))

;;; --- visiting the source ------------------------------------------------------
;;; The target line is the hunk's new-start plus the context and added rows
;;; between the hunk header and point. Deleted rows do not exist in the new
;;; file, so they do not count.

(define (git--target-line buf line)
  (let ((h (git--hunk-at buf line)))
    (if (not h)
        #f
        (let loop ((n (+ (car h) 1)) (out (caddr h)))
          (if (>= n line)
              (list (cadr h) out)
              (let ((l (git--line-at-n buf n)))
                (loop (+ n 1)
                      (if (string-prefix? "-" l) out (+ out 1)))))))))

(define-command "git-diff-visit" "Open the file this row belongs to, at its line"
  (lambda ()
    (let* ((buf (current-buffer))
           (root (buffer-local buf 'git-root))
           (line (git--line-number buf (point)))
           (card (git--card-at buf line))
           (target (git--target-line buf line)))
      (cond ((not card) (message "no file here"))
            (else
              (let ((path (string-append root "/" (car card))))
                (if (file-exists? path)
                    (begin
                      (browse-visit path)
                      (when target (git--goto-line! (max 1 (cadr target)))))
                    (message (string-append "gone: " (car card))))))))))

;;; --- folding ------------------------------------------------------------------

(define-command "git-diff-toggle-card" "Fold or unfold the file at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (card (git--card-at buf (git--line-number buf (point)))))
      (if (not card)
          (message "no file here")
          (begin (git-diff-toggle-card! buf (car card))
                 (git--goto-line! (cadr card)))))))

;; also the click target: the card header in the rich view calls this
(define (git-diff-toggle-card! buf file)
  (let ((open (or (buffer-local buf 'diff-open-cards) '())))
    (buffer-set-local! buf 'diff-open-cards
      (if (member file open)
          (filter (lambda (f) (not (equal? f file))) open)
          (cons file open)))
    (git--apply-folds! buf)))

(diff-on-card-click! (lambda (buf file) (git-diff-toggle-card! buf file)))

;;; --- watching -----------------------------------------------------------------

(define-command "git-diff-toggle-watch" "Follow the filesystem, or stop"
  (lambda ()
    (let* ((buf (current-buffer))
           (root (buffer-local buf 'git-root))
           (on? (buffer-local buf 'git-watch)))
      (if on?
          (begin (unwatch-path! root)
                 (buffer-set-local! buf 'git-watch #f)
                 (message "watch off"))
          (begin (watch-path! root)
                 (buffer-set-local! buf 'git-watch #t)
                 (message "watch on"))))))

;; One handler for every diff buffer. It stays small: it refreshes the
;; buffers that watch this root and does nothing else.
(on-fs-change!
  (lambda (root)
    (for-each
      (lambda (b)
        (when (and (equal? (buffer-local b 'git-root) root)
                   (buffer-local b 'git-watch))
          (git-diff-refresh b)))
      (buffer-list))))

;;; --- the plain view -----------------------------------------------------------

(define-command "git-diff-toggle-view" "Toggle between the cards and the plain diff"
  (lambda ()
    (let* ((buf (current-buffer))
           (rich? (equal? (buffer-local buf 'render-mode) "diff")))
      (buffer-set-local! buf 'render-mode (if rich? #f "diff"))
      (message (if rich? "plain diff" "diff cards")))))

;;; --- the mode -----------------------------------------------------------------

(define (git--install-keys!)
  (local-set-key "n" "git-diff-next-hunk")
  (local-set-key "p" "git-diff-prev-hunk")
  (local-remap! "next-line" "git-diff-next-hunk")
  (local-remap! "previous-line" "git-diff-prev-hunk")
  (local-set-key "N" "git-diff-next-file")
  (local-set-key "P" "git-diff-prev-file")
  (local-set-key "TAB" "git-diff-toggle-card")
  (local-set-key "RET" "git-diff-visit")
  (local-set-key "g" "git-diff-revert")
  (local-set-key "w" "git-diff-toggle-watch")
  (local-set-key "q" "quit-window")
  (local-set-key "C-c C-v" "git-diff-toggle-view"))

(define-command "git-diff-revert" "Re-read the diff from git"
  (lambda () (git-diff-refresh (current-buffer))))

(define-mode "git-diff"
  (lambda ()
    (let ((buf (current-buffer)))
      (git--install-keys!)
      (buffer-set-read-only! buf #t)
      ;; the text regenerates from git, so the desktop saves the locals and
      ;; not the content
      (buffer-set-local! buf 'transient #t)
      (buffer-set-local! buf 'render-mode "diff")
      ;; Restore lands here with 'git-root, 'git-watch and 'diff-open-cards
      ;; and no text. Re-arm the watch and re-read; the open cards survive
      ;; because git--apply! only opens files it has not shown before.
      (when (buffer-local buf 'git-watch)
        (watch-path! (buffer-local buf 'git-root)))
      (git-diff-refresh buf))))

(define-command "git-diff" "Show the working tree diff for this repository"
  (lambda ()
    (let ((root (git-root (default-directory))))
      (if (not (string? root))
          (message "not a git repository")
          (let ((buf (git--buf-name root)))
            (buffer-create buf)
            (buffer-set-local! buf 'git-root root)
            (switch-to-buffer! buf)
            (set-mode! "git-diff"))))))

(global-set-key "C-x g" "git-diff")

(public! 'browse-visit "(browse-visit PATH) — open a file the way the code browser does: read-only unless *browse-read-only* is #f. C-x C-q makes it writable")
(public! 'git-diff-refresh "(git-diff-refresh BUF) — re-read the diff into a git-diff buffer, off the Session")
(public! 'git-diff-toggle-card! "(git-diff-toggle-card! BUF FILE) — fold or unfold one file's card")
