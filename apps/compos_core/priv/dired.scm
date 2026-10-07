;;; dired.scm --- directory editor, written entirely in userland Scheme.
;;;
;;; The extensibility bar: no Elixir knows what dired is. Built from
;;; primitives: list-dir, file-stat, buffer ops, read-only buffers,
;;; local keymaps, the minibuffer — and define-list-mode!, which owns
;;; the rows, the marks, the filter stack and the refresh (R8). Dired
;;; is the per-buffer case: one buffer PER DIRECTORY, so every callback
;;; reads the buffer's own 'dired-dir local.
;;;
;;; Keys (buffer-local):
;;;   n/p move · RET visit · ^ up · g revert
;;;   m mark · u unmark · U unmark all · * mark all
;;;   d flag for deletion · x execute · R rename/move · + mkdir
;;;   / narrow (type; it matches the line and the mode beside it)
;;;   \ widen by one · . hide dotfiles
;;;
;;; Columns:  <mark> <kind> <name> <bar> <size> <modified> <perms> <vc>

(domain! 'files)
(effects! '(read))

;; the buffer-local is the durable copy: locals ride desktop.etf, so a
;; restored dired knows its directory before its mode setup re-renders
(define (dired-dir buf) (buffer-local buf 'dired-dir))

(define (dired-directory? e) (string-suffix? "/" e))

(define (dired-normalize-dir p)
  (if (remote-path? p) (remote-dir-key p) (expand-path p)))

(define (dired-remote-path-key p)
  (if (equal? p "/") p (remote-dir-key p)))

(define (dired-parent dir)
  (if (remote-path? dir)
      (let* ((hp (remote-parse dir))
             (path (dired-remote-path-key (cadr hp)))
             (parent (path-directory path)))
        (string-append "/ssh:" (car hp) ":" (dired-remote-path-key parent)))
      (expand-path (string-append dir "/.."))))

(define (dired-stat buf e)
  (let ((info (dired-info buf e)))
    (if info
        (list (or (plist-get info 'perms) "??????????")
              (or (plist-get info 'size) "?")
              (or (plist-get info 'date) "?"))
        (file-stat (string-append (dired-dir buf) "/" e)))))

;;; --- the draw's copy of the lists ---------------------------------------------
;;; A draw asks for the info of every entry, and every ask read the whole
;;; info list out of the buffer: 250 rows, four reads each, one copy of
;;; 250 plists per read, eight seconds for a home directory. The scan
;;; leaves a copy here, and the rows read from it. The buffer-locals stay
;;; the durable record; this is the draw's working copy.
(define *dired-lists* '())

(define (dired-lists-prime! buf)
  (set! *dired-lists*
    (cons (list buf
                (or (buffer-local buf 'dired-info) '())
                (or (buffer-local buf 'dired-vc) '()))
          (filter (lambda (entry)
                    (and (not (equal? (car entry) buf))
                         (buffer-exists? (car entry))))
                  *dired-lists*))))

(define (dired-lists buf)
  (let ((entry (assoc buf *dired-lists*)))
    (if entry
        (cdr entry)
        (begin (dired-lists-prime! buf) (dired-lists buf)))))

(define (dired-info buf e)
  (let ((found (assoc e (car (dired-lists buf)))))
    (if found (cadr found) #f)))

;;; --- sizes --------------------------------------------------------------------
;;; file-stat formats a size for reading ("12.4k"); the bar and the total
;;; need the number it formatted, so they read it back.

(define (dired-num s)
  (let ((v (string->number s)))
    (if (number? v) v 0)))

(define (dired-scale s)
  (cond ((string-suffix? "M" s) 1048576)
        ((string-suffix? "k" s) 1024)
        (else 1)))

(define (dired-bytes s)
  (let* ((k (dired-scale s))
         (n (if (= k 1) s (substring s 0 (- (string-length s) 1))))
         (parts (string-split n "."))
         (tenths (if (null? (cdr parts)) 0 (dired-num (car (cdr parts))))))
    (+ (* (dired-num (car parts)) k) (quotient (* tenths k) 10))))

(define (dired-human b)
  (cond ((>= b 1099511627776)
         (string-append (number->string (quotient b 1099511627776)) " TB"))
        ((>= b 1073741824)
         (string-append (number->string (quotient b 1073741824)) " GB"))
        ((>= b 1048576) (string-append (number->string (quotient b 1048576)) " MB"))
        ((>= b 1024) (string-append (number->string (quotient b 1024)) " kB"))
        (else (string-append (number->string b) " B"))))

;; how big this file is against the biggest one here. The bar is five
;; cells, and a file that has any bytes at all fills one of them.
(define (dired-bar b top)
  (let ((n (if (= b 0)
               0
               (max 1 (min 5 (quotient (+ (* b 5) (- top 1)) top))))))
    (string-append (string-repeat "█" n) (string-repeat "░" (- 5 n)))))

(define (dired-top-size buf)
  (or (buffer-local buf 'dired-top) 1))

;;; --- what git says ------------------------------------------------------------
;;; One `git status` when the listing opens, kept on the buffer. A refresh
;;; redraws from the map: `/` narrows on every keystroke, and a git call
;;; per keystroke is a git call per keystroke.

(define (dired-vc-label status)
  (let ((index (plist-get status 'index))
        (worktree (plist-get status 'worktree)))
    (cond ((and (equal? index "?") (equal? worktree "?")) "untracked")
          ((or (equal? index "U") (equal? worktree "U")
               (and (equal? index "A") (equal? worktree "A"))
               (and (equal? index "D") (equal? worktree "D"))) "conflict")
          ((or (equal? index "D") (equal? worktree "D")) "deleted")
          ((equal? index "R") "renamed")
          ((equal? index "C") "copied")
          ((and (not (equal? index " ")) (not (equal? worktree " "))) "mixed")
          ((not (equal? worktree " ")) "modified")
          ((not (equal? index " ")) "staged")
          (else ""))))

;; the entry this path belongs to: git answers with paths under the
;; directory, and a directory row says what its contents did
(define (dired-vc-entry path)
  (let ((i (string-index path "/")))
    (if i (substring-bytes path 0 (+ i 1)) path)))

(define (dired-vc-rank label)
  (cond ((equal? label "conflict") 8)
        ((equal? label "deleted") 7)
        ((equal? label "mixed") 6)
        ((equal? label "modified") 5)
        ((equal? label "staged") 4)
        ((equal? label "renamed") 3)
        ((equal? label "copied") 2)
        ((equal? label "untracked") 1)
        (else 0)))

(define (dired-vc-put acc entry label)
  (let ((old (assoc entry acc)))
    (if (and old (>= (dired-vc-rank (cadr old)) (dired-vc-rank label)))
        acc
        (cons (list entry label)
              (filter (lambda (e) (not (equal? (car e) entry))) acc)))))

(define (dired-vc-parse statuses)
  (fold (lambda (acc status)
          (let ((label (dired-vc-label status)))
            (if (or (not label) (equal? label ""))
                acc
                (dired-vc-put acc
                              (dired-vc-entry (plist-get status 'path))
                              label))))
        '() statuses))

(define (dired-vc-scan! buf dir)
  (if (remote-path? dir)
      (begin
        (buffer-set-local! buf 'dired-vc '())
        (buffer-set-local! buf 'dired-branch #f)
        (buffer-set-local! buf 'dired-free #f))
      (let ((inside?
              (equal? "true"
                (string-trim
                  (shell-command->string
                    "git rev-parse --is-inside-work-tree 2>/dev/null" dir)))))
        (if (not inside?)
            (begin
              (buffer-set-local! buf 'dired-vc '())
              (buffer-set-local! buf 'dired-branch #f))
            (let ((statuses (git-status dir ".")))
              (buffer-set-local! buf 'dired-vc
                (if (and (pair? statuses) (equal? (car statuses) 'error))
                    '()
                    (dired-vc-parse statuses)))
              (buffer-set-local! buf 'dired-branch
                 (string-trim
                   (shell-command->string "git branch --show-current 2>/dev/null" dir)))))
        (buffer-set-local! buf 'dired-free
          (string-trim
            (shell-command->string "df -h . | tail -1 | awk '{print $4}'" dir))))))

(define (dired-vc buf e)
  (let ((m (assoc e (cadr (dired-lists buf)))))
    (if m (cadr m) "")))

(define (dired-vc-face label)
  (cond ((or (equal? label "untracked") (equal? label "deleted")
             (equal? label "conflict")) "alert")
        ((or (equal? label "modified") (equal? label "mixed")) "warn")
        ((or (equal? label "staged") (equal? label "renamed")
             (equal? label "copied")) "ok")
        (else "faint")))

;;; --- the row ------------------------------------------------------------------

(define (dired-cells buf e)
  (if (equal? e "..")
      (list (list (mode-icon "Dired") "accent") (list ".." "accent") "" "" "" "" "")
      (let* ((info (dired-info buf e))
             (st (dired-stat buf e))
             (kind (and info (plist-get info 'type)))
             (dir? (equal? kind "directory"))
             (link? (equal? kind "symlink"))
             (b (or (and info (plist-get info 'bytes)) 0))
             (vc (dired-vc buf e)))
        ;; the icon says what the row opens in: a directory wears Dired's,
        ;; a file wears its own mode's
        (list (if dir? (list (mode-icon "Dired") "accent") (list (file-icon e) "faint"))
              (list e (cond (dir? "accent") (link? "warn") (else #f)))
              (if dir? "" (list (dired-bar b (dired-top-size buf)) "faint"))
              (if dir? (list "—" "faint") (list (or (and info (plist-get info 'size))
                                                       (cadr st)) "dim"))
              (list (caddr st) "dim")
              (list (car st) "faint")
              (list vc (dired-vc-face vc))))))

(define (dired-composml-record buf entry)
  (let* ((parent? (equal? entry ".."))
         (info (and (not parent?) (dired-info buf entry)))
         (path (if parent? (dired-parent (dired-dir buf))
                   (string-append (dired-dir buf) "/" entry))))
    (list 'tag "file" 'layout "columns"
          'attrs (append
            (list (list "path" path) (list "name" entry)
                  (list "kind" (if parent? "directory" (or (and info (plist-get info 'type)) "unknown")))
                  (list "mark" (or (cadr (or (assoc entry (list-marks buf)) (list entry ""))) "")))
            (if info (list
              (list "bytes" (or (plist-get info 'bytes) 0))
              (list "mtime" (or (plist-get info 'mtime) 0))
              (list "permissions" (or (plist-get info 'perms) ""))) '())))))

(define (dired-composml-fields buf entry)
  (let ((info (and (not (equal? entry "..")) (dired-info buf entry))))
    (let loop ((cols (list-columns buf)) (i 0) (out '()))
      (if (null? cols) (reverse out)
        (let* ((name (car (car cols)))
               (tag (cond ((equal? name "name") "filename")
                          ((equal? name "size") "size")
                          ((equal? name "modified") "modified")
                          ((equal? name "perms") "permissions")
                          ((equal? name "vc") "vcs-status")
                          ((= i 0) "icon")
                          (else "size-bar"))))
          (loop (cdr cols) (+ i 1)
            (cons (list 'tag tag 'attrs
              (cond ((equal? name "size")
                     (list (list "bytes" (or (and info (plist-get info 'bytes)) 0))))
                    ((equal? name "modified")
                     (list (list "mtime" (or (and info (plist-get info 'mtime)) 0))))
                    ((equal? name "name") (list (list "name" entry)))
                    (else '()))) out)))))))

;;; --- narrow windows -----------------------------------------------------------
;;; The same row with fewer columns. Dired's furniture (bar, size, date,
;;; perms, vc) costs about 58 characters before the name gets one, so a
;;; narrow window keeps what names the file and what git says about it.
;;; The widths where these turn belong to list-mode, not to dired.

(define (dired-cells-pick buf e keep)
  (let ((all (dired-cells buf e)))
    (map (lambda (i) (list-ref all i)) keep)))

(define (dired-narrow-columns buf)
  (list (list "" 1) (list "name" #f) (list "vc" 9)))

(define (dired-narrow-cells buf e) (dired-cells-pick buf e '(0 1 6)))

(define (dired-compact-columns buf)
  (list (list "" 1) (list "name" #f) (list "size" 7 'right)
        (list "modified" 12) (list "vc" 9)))

(define (dired-compact-cells buf e) (dired-cells-pick buf e '(0 1 3 4 6)))

(define (dired-narrow-footer buf)
  '(("RET" "peek") ("SPC" "select") ("x" "trash")
    ("/" "filter") ("^" "up") ("q" "quit")))

;;; --- filters ------------------------------------------------------------------
;;; `/` narrows and `\` widens, and both are list-mode's: the stack, the
;;; label and the matching all live there, and `/` already reads the
;;; perms, the size, the date, the name and the mode. Dired adds the two
;;; kinds that text cannot say:
;;;   ("dot" "on")                     hide the dotfiles
;;;   ("type" dir|file|link|exec)      what the entry IS
;;; A person reaches the first with `.`; an agent pushes either one.

(define (dired-filter-match? buf e f)
  (let ((kind (car f)) (arg (car (cdr f))))
    (cond ((equal? e "..") #t)
          ((equal? kind "dot") (not (string-prefix? "." e)))
          ((equal? kind "type")
           (let* ((info (dired-info buf e))
                  (type (and info (plist-get info 'type)))
                  (perms (or (and info (plist-get info 'perms)) "")))
             (cond ((equal? arg "dir") (equal? type "directory"))
                   ((equal? arg "link") (equal? type "symlink"))
                   ((equal? arg "exec")
                    (and (equal? type "regular")
                         (if (string-index perms "x") #t #f)))
                   (else (equal? type "regular")))))
          (else #t))))

(define (dired-match? buf e input)
  (or (equal? e "..")
      (let* ((info (dired-info buf e))
             (opens (if (and info (equal? (plist-get info 'type) "directory"))
                        " Dired"
                        "")))
        (re-match? input (string-append (list-row-text buf e) opens)))))

;; the file annotator stats a bare name, so it must know which directory
;; this listing came from — the contract every file listing keeps
(define (dired-visible buf dir)
  (set! *marginalia-file-dir* (string-append dir "/"))
  (dired-scan-once! buf dir)
  (list-keep buf (or (buffer-local buf 'dired-all) '())))

;; the whole directory, before the filters: the biggest file sets the
;; scale of the size bars, and the header counts what the narrowing hid
;; ls is the name a person reaches for, so the editor answers to it. Dired
;; itself has no path-to-files call — every listing it owns hangs off a
;; buffer and applies that buffer's filters, sort and marks. This is the
;; layer under the mode: the same entries dired reads, before any of its
;; opinions, as (name type bytes mtime size date perms) plists. A bad path
;; comes back as (error REASON), the way directory-entries reports it.
(define (ls &optional dir)
  (directory-entries (or dir (default-directory))))

(define (dired-read-directory! buf dir)
  (let ((entries (directory-entries dir)))
    (if (and (pair? entries) (equal? (car entries) 'error))
        (begin
          (buffer-set-local! buf 'dired-error (cadr entries))
          (buffer-set-local! buf 'dired-info '())
          (buffer-set-local! buf 'dired-all '())
          (buffer-set-local! buf 'dired-total 0)
          (buffer-set-local! buf 'dired-top 1)
          (buffer-set-local! buf 'dired-used 0))
        (begin
          (buffer-set-local! buf 'dired-error #f)
          (buffer-set-local! buf 'dired-info
            (map (lambda (info) (list (plist-get info 'name) info)) entries))
          (buffer-set-local! buf 'dired-all (map (lambda (info) (plist-get info 'name)) entries))
          (buffer-set-local! buf 'dired-total (length entries))
    (buffer-set-local! buf 'dired-top
            (fold (lambda (top info)
              (if (equal? (plist-get info 'type) "directory")
                  top
                  (max top (or (plist-get info 'bytes) 0))))
                  1 entries))
    (buffer-set-local! buf 'dired-used
            (fold (lambda (sum info)
              (if (equal? (plist-get info 'type) "directory")
                  sum
                  (+ sum (or (plist-get info 'bytes) 0))))
                  0 entries))))))

;; git, df and the sizes answer once, when the listing opens or reverts.
;; A refresh redraws from what they left: `/` narrows on every keystroke,
;; and a scan per keystroke is a scan per keystroke. A restored dired
;; scans on its first refresh, because its locals came back empty.
(define (dired-scan-once! buf dir)
  (unless (buffer-local buf 'dired-scanned)
    (dired-read-directory! buf dir)
    (unless (buffer-local buf 'dired-error) (dired-vc-scan! buf dir))
    (buffer-set-local! buf 'dired-scanned #t))
  ;; the draw that follows reads the lists this scan (or a restore) left
  (dired-lists-prime! buf))

(define (dired-rescan! buf)
  (buffer-set-local! buf 'dired-scanned #f)
  (buffer-set-local! buf 'dired-vc '())
  (buffer-set-local! buf 'list-source-entries #f)
  (dired-lists-prime! buf))

(define (dired-skip-derived! buf)
  (for-each (lambda (key) (desktop-skip! buf key))
            '(dired-scanned dired-info dired-all dired-vc dired-branch
              dired-free dired-error dired-total dired-top dired-used
              dired-watch-armed dired-stale list-source-entries)))

(define (dired-sort-field buf)
  (or (buffer-local buf 'dired-sort-field) "name"))

(define (dired-sort-value buf e)
  (let* ((info (dired-info buf e))
         (field (dired-sort-field buf)))
    (cond ((equal? field "size") (or (and info (plist-get info 'bytes)) 0))
          ((equal? field "modified") (or (and info (plist-get info 'mtime)) 0))
          ((equal? field "type") (or (and info (plist-get info 'type)) ""))
          ((equal? field "vc") (dired-vc buf e))
          (else (string-downcase e)))))

(define (dired-sort-one buf entries)
  (let ((sorted
          (map (lambda (row) (caddr row))
               (sort (map (lambda (e)
                            (list (dired-sort-value buf e) (string-downcase e) e))
                          entries)))))
    (if (buffer-local buf 'dired-sort-reverse) (reverse sorted) sorted)))

(define (dired-sorted buf entries)
  (if (buffer-local buf 'dired-dirs-first)
      (append
        (dired-sort-one buf
          (filter (lambda (e)
                    (equal? (plist-get (dired-info buf e) 'type) "directory"))
                  entries))
        (dired-sort-one buf
          (filter (lambda (e)
                    (not (equal? (plist-get (dired-info buf e) 'type) "directory")))
                  entries)))
      (dired-sort-one buf entries)))

(define (dired-resort! buf)
  (buffer-set-local! buf 'list-source-entries
    (cons ".." (dired-sorted buf (or (buffer-local buf 'dired-all) '()))))
  (list-redraw! buf))

(define (dired-title buf)
  (string-append (abbreviate-file-name (or (dired-dir buf) "")) "/"))

;; ".." is a way out of the directory, not a thing in it
(define (dired-meta buf)
  (let* ((failure (buffer-local buf 'dired-error))
         (n (list-count buf))
         (branch (buffer-local buf 'dired-branch))
         (free (buffer-local buf 'dired-free)))
    (if failure
        (string-append "error: " failure)
        (string-join
      (append
        (list (string-append (number->string n) " "
                             (if (= n 1) "item" "items"))
              (string-append (dired-human (or (buffer-local buf 'dired-used) 0)) " used"))
        (if (and free (not (equal? free ""))) (list (string-append free " free")) '())
        (if (and branch (not (equal? branch ""))) (list (string-append "⎇ " branch)) '()))
          " · "))))

(define (dired-filter-push! f)
  (list-filter-push! (current-buffer) f)
  (dired-goto-first-entry))

;; the one filter you toggle rather than type: a dotfile is hidden by
;; being a dotfile, and no text you type says "not this kind of name"
(effects! '(write))

(define-command "dired-filter-dotfiles" "Toggle hiding dotfiles"
  (lambda ()
    (let* ((buf (current-buffer))
           (fs (list-filters buf))
           (had (assoc "dot" fs)))
      (if had
          (begin
            (buffer-set-local! buf 'list-filters
              (filter (lambda (f) (not (equal? (car f) "dot"))) fs))
            (list-refresh! buf)
            (dired-goto-first-entry))
          (dired-filter-push! (list "dot" "on"))))))

(define (dired-goto-first-entry)
  (list-goto-first-entry (current-buffer)))

;; ".." is entry zero, so RET on it works through the same list-current
;; path as every real row; marks skip it
;; The peek opens on RET. While a peek shows, the highlight drives it:
;; rest on a file and the peek shows that file instead, so RET on it
;; opens. Held down, the arrows move faster than a file opens, so the
;; look waits for the highlight to rest. With no peek showing, moving
;; the highlight shows nothing.
;; plain defines: dired loads before custom.scm, so defcustom is not
;; here yet. Set them in init.scm.
(define dired-peek-on-move #t)   ; a shown peek follows the highlight
(define dired-peek-ms 120)       ; how long the highlight rests first, in ms

;; the look the rest scheduled: only if the reader is still where the
;; highlight rested. The rest fires later, and a reader who moved to
;; another window or buffer must not be pulled back.
(define (dired--peek-now! args)
  (let ((p (car args)) (g (cadr args)) (me (caddr args)) (here (nth 3 args)))
    (when (and (equal? (active-window) me) (equal? (current-buffer) here)
               (not (and (peek-buffer? p) (window-showing p))))
      (peek! p (lambda () (visit-quietly p g))))))

(define (dired--preview buf entry)
  (when (and dired-peek-on-move (equal? (current-buffer) buf)
             ;; only a peek already on screen follows
             (pair? (filter window-showing (peek-buffers))))
    (let ((p (dired-path-at-point)))
      (when (and p (string? entry) (not (equal? entry ".."))
                 (not (dired-directory? entry)))
        (debounce! "dired-peek" dired-peek-ms dired--peek-now!
                   (list p (buffer-group buf) (active-window) buf))))))

(define-list-mode! "Dired"
  (list
    'composml-root (lambda (buf) (list 'tag "directory" 'attrs (list (list "path" (dired-dir buf)))))
    'composml-record (lambda (buf entry) (dired-composml-record buf entry))
    'composml-fields (lambda (buf entry) (dired-composml-fields buf entry))
    'preview dired--preview
    'doc (string-append
           "One directory as a table: name, size, modified, perms and what "
           "git says. Select files with `SPC` (or `m`) and the whole listing with `* s`; "
           "`x` trashes what you marked, and `d` flags a file for the same "
           "`x`. `D` flags permanent deletion. `RET` on a file peeks it in the other window, "
           "read-only; `RET` again or `M-RET` opens it here as your own; `q` dismisses "
           "the peek, and with none showing leaves dired. "
           "`RET` on a directory opens it here. `^` goes up. `/` narrows as you type — it matches the "
           "perms, the size, the date, the name and the mode the file would "
           "open in. The arrows move the rows while you type, and `RET` "
           "keeps the narrowing and the row you chose. `\\` widens by one "
           "and `.` hides the dotfiles. `s` changes sorting, `S` reverses it, "
           "and `G` groups directories first. The filters and sorting persist. "
           "`% m` marks and `% d` flags by regexp, `~` flags backups, `t` toggles "
           "the marks, `% R` renames by regexp. `!` runs a shell command on the "
           "marked files. `C-x C-q` edits the names as text. With a Dired in "
           "another window, `C` and `R` offer its directory. `*` is the marking "
           "prefix: `* /` directories, `* *` executables, `* @` links, `* .` an "
           "extension, `* c` changes a mark, `* !` drops them all, `* C-n` and "
           "`* C-p` go to the next and previous mark.")
    ;; a file name is a file name: `/` matches the same annotation
    ;; C-x C-f shows beside one
    'category 'file
    'local-filter #t
    'filter (lambda (buf e q) (dired-filter-match? buf e q))
    'match (lambda (buf e q) (dired-match? buf e q))
    'rows (lambda (buf)
            (let ((dir (dired-dir buf)))
              (if (not dir)
                  '()
                  (begin
                    (set! *marginalia-file-dir* (string-append dir "/"))
                    (dired-scan-once! buf dir)
                         (cons ".."
                               (dired-sorted buf
                                 (or (buffer-local buf 'dired-all) '())))))))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "name" #f)
                     (list "" 5)
                     (list "size" 7 'right)
                     (list "modified" 12)
                     (list "perms" 10)
                     (list "vc" 9)))
    'cells (lambda (buf e) (dired-cells buf e))
    'layouts
      (list
        (list 'name 'narrow
              'columns (lambda (buf) (dired-narrow-columns buf))
              'cells (lambda (buf e) (dired-narrow-cells buf e))
              'footer (lambda (buf) (dired-narrow-footer buf))
              'compact #t)
        (list 'name 'compact
              'columns (lambda (buf) (dired-compact-columns buf))
              'cells (lambda (buf e) (dired-compact-cells buf e))
              'footer (lambda (buf) (dired-narrow-footer buf)))
        (list 'name 'wide 'default #t))
    'title (lambda (buf) (dired-title buf))
    'meta (lambda (buf) (dired-meta buf))
    'total (lambda (buf) (or (buffer-local buf 'dired-total) 0))
    'footer (lambda (buf)
              '(("RET" "peek, again opens") ("M-RET" "open") ("SPC" "select") ("* s" "all") ("d" "flag")
                ("x" "trash") ("C" "copy") ("R" "rename") ("s" "sort")
                ("/" "filter") ("." "dotfiles") ("% m" "mark regexp") ("t" "toggle")
                ("!" "shell") ("C-x C-q" "edit names")
                ("^" "up") ("g" "revert") ("q" "quit peek, then dired")))
    ;; Marked rows go to trash by default. Permanent deletion uses `D`.
    'flags (list (list "d" "D" "trash"
                       (lambda (buf e)
                         (let ((acted (trash-file!
                                       (string-append (dired-dir buf) "/" e))))
                           (when acted (dired-rescan! buf))
                           acted))
                       #t)
                 (list "D" "!" "delete permanently"
                       (lambda (buf e)
                         (delete-file! (string-append (dired-dir buf) "/" e))
                         (dired-rescan! buf)
                         #t)
                       #t))
    'noun "file"
    'markable? (lambda (buf e) (not (equal? e "..")))
    'keys '(("RET" "dired-visit") ("M-RET" "dired-open") ("q" "dired-quit") ("C-RET" "dired-visit-in-group")
            ;; space selects the row: the mark m sets, on the thumb
            ("SPC" "list-mark")
            ("g" "dired-revert") ("^" "dired-up")
            ("+" "dired-mkdir") ("R" "dired-rename")
            ("C" "dired-copy") ("M" "dired-chmod") ("T" "dired-touch")
            ("L" "dired-symlink") ("s" "dired-sort-cycle")
            ("S" "dired-sort-reverse") ("G" "dired-dirs-first")
            ("." "dired-filter-dotfiles")
            ("% m" "dired-mark-files-regexp") ("% d" "dired-flag-files-regexp")
            ("% R" "dired-do-rename-regexp") ("t" "dired-toggle-marks")
            ("~" "dired-flag-backup-files") ("!" "dired-do-shell-command")
            ("&" "dired-do-shell-command") ("C-x C-q" "dired-toggle-read-only")
            ;; `*` is the marking prefix, as in Emacs; `* s` or `t` marks all
            ("* m" "list-mark") ("* u" "list-unmark") ("* !" "list-unmark-all")
            ("* s" "dired-mark-subdir-files") ("* /" "dired-mark-directories")
            ("* *" "dired-mark-executables") ("* @" "dired-mark-symlinks")
            ("* ." "dired-mark-extension") ("* %" "dired-mark-files-regexp")
            ("* t" "dired-toggle-marks") ("* c" "dired-change-marks")
            ("* C-n" "dired-next-marked-file") ("* C-p" "dired-prev-marked-file")
            ("M-}" "dired-next-marked-file") ("M-{" "dired-prev-marked-file"))))

(define (dired-arm-watch! buf)
  (let ((dir (dired-dir buf)))
    (when (and dir (not (remote-path? dir))
               (not (buffer-local buf 'dired-watch-armed)))
      (let ((answer (watch-path! dir)))
        (unless (and (pair? answer) (equal? (car answer) 'error))
          (buffer-set-local! buf 'dired-watch-armed #t))))))

;; A Dired buffer is a buffer that wears the mode. `dired-dir` alone is not
;; enough: a mode change leaves the local behind, and the hooks below must
;; not repaint a buffer that another mode now owns.
(define (dired-buffer? buf)
  (and (dired-dir buf) (equal? (buffer-local buf 'mode-name) "Dired")))

(define (dired-refresh-buffer! buf)
  (when (and (buffer-exists? buf) (dired-buffer? buf))
    (dired-rescan! buf)
    (list-refresh! buf)))

(add-hook! 'fs-change-hook
  (lambda (root)
    (for-each
      (lambda (buf)
        (when (and (dired-buffer? buf)
                   (equal? (dired-dir buf) root)
                   (buffer-local buf 'dired-watch-armed))
          (if (window-showing buf)
              (begin
                (buffer-set-local! buf 'dired-stale #f)
                (dired-refresh-buffer! buf))
              (buffer-set-local! buf 'dired-stale #t))))
      (buffer-list))))

(add-hook! 'buffer-shown-hook
  (lambda (buf)
    (when (dired-buffer? buf)
      (dired-skip-derived! buf)
      (dired-arm-watch! buf)
      (when (buffer-local buf 'dired-stale)
        (buffer-set-local! buf 'dired-stale #f)
        (dired-refresh-buffer! buf)))))

;; A Dired buffer takes the directory path as its buffer name. A file path
;; therefore takes the file's own buffer name, and the file can never open
;; again. Emacs answers a file name with the parent listing, at that file.
(define (dired-open-file-parent path)
  (let* ((name (cadr (path-split path)))
         (buf (dired-open (dired-parent path)))
         (i (list-index-of buf (list-entries buf) name)))
    (when i (list-goto-index! buf i))
    buf))

;; up from DIR: the parent listing, where it was. The point belongs to
;; the reader: a listing you came down from remembers the row you left
;; it on, which is the directory you went into, and no computation is
;; needed to put it there. A parent never opened starts on its first
;; entry.
(define (dired-open-parent! dir0)
  (dired-open (dired-parent (dired-normalize-dir dir0))))

(define (dired-open dir0)
  (let ((dir (dired-normalize-dir dir0)))
    (if (and (not (remote-path? dir))
             (file-exists? dir)
             (not (file-directory? dir)))
        (dired-open-file-parent dir)
        (dired-open-directory dir))))

;; The point in a listing is the reader's: it moves only when the
;; reader moves it. A listing opened for the first time starts on its
;; first entry; a listing opened again keeps the row it was on.
(define (dired-open-directory dir)
  (let* ((buf dir)
         (fresh (not (buffer-known? buf))))
    (buffer-create buf)
    ;; the dir local first: the mode setup's refresh reads it
    (buffer-set-local! buf 'dired-dir dir)
    (dired-skip-derived! buf)
    ;; re-opening a directory re-reads what git and the sizes say
    (dired-rescan! buf)
    (switch-to-buffer-here! buf)
    (set-mode! "Dired")
    (dired-arm-watch! buf)
    (when fresh (dired-goto-first-entry))
    buf))

;; the entry on the current line: a name, the ".." token, or #f above them
(define (dired-entry) (list-current (current-buffer)))

(define (dired-path-at-point)
  (let ((e (dired-entry))
        (dir (dired-dir (current-buffer))))
    (if (and e dir)
        (if (equal? e "..")
            (dired-parent dir)
            (string-append dir "/" e))
        #f)))

;; default-directory: dired's dir, else the chat's companion project, else
;; the file's dir, else a path-shaped buffer name, else the dir the buffer
;; was born in (buffer-create copies it from the creating buffer), else ~
(define (path-directory p)
  (let ((i (string-rindex p "/")))
    (if i (substring-bytes p 0 (+ i 1)) p)))

;; A chat works in its companion's project. The companion directory is
;; chat identity: chat-stamp-directory! writes it once, when the chat is
;; born, from the directory of the buffer that started the chat. Nothing
;; derives it again, so a group of any size costs a chat nothing per
;; command. An explicit spawn directory (a worktree, a foreign repo) is
;; the same local, written by the spawner.
(define (buffer-companion-directory buf)
  (buffer-local buf 'chat-directory))

(define (default-directory) (buffer-directory (current-buffer)))

(define (buffer-directory buf)
  (let ((dd (and (dired-buffer? buf) (dired-dir buf)))
        (companion (buffer-companion-directory buf))
        (p (buffer-path buf))
        (born (buffer-local buf 'default-directory)))
    (cond (dd (string-append dd "/"))
          (companion companion)
          (p (path-directory p))
          ((string-prefix? "/" buf) (path-directory buf))
          (born born)
          (else (string-append (expand-path "~") "/")))))

(define-command "dired" "Prompt for a directory and open it in Dired"
  (lambda ()
    (read-file-name "Dired (directory): "
      (lambda (d) (dired-open (normalize-file-input d))))))

(define (dired-sort-next field)
  (cond ((equal? field "name") "size")
        ((equal? field "size") "modified")
        ((equal? field "modified") "type")
        ((equal? field "type") "vc")
        (else "name")))

(define-command "dired-sort-cycle" "Sort by the next field: name, size, modified, type, or VC"
  (lambda ()
    (let* ((buf (current-buffer))
           (field (dired-sort-next (dired-sort-field buf))))
      (buffer-set-local! buf 'dired-sort-field field)
      (dired-resort! buf)
      (message (string-append "Sort: " field)))))

(define-command "dired-sort-reverse" "Reverse the current Dired sort"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'dired-sort-reverse
        (not (buffer-local buf 'dired-sort-reverse)))
      (dired-resort! buf)
      (message "Sort reversed"))))

(define-command "dired-dirs-first" "Toggle directory grouping before other entries"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'dired-dirs-first
        (not (buffer-local buf 'dired-dirs-first)))
      (dired-resort! buf)
      (message (if (buffer-local buf 'dired-dirs-first)
                   "Directories first"
                   "Directories mixed")))))

;; movement is list-mode's — these names stay for the bindings and the
;; tests that call them
(define-command "dired-next" "Move down to the next line in the Dired buffer"
  (lambda () (list-move! 1)))

(define-command "dired-prev" "Move up to the previous line in the Dired buffer"
  (lambda () (list-move! -1)))

;; A directory opens in place: a listing is yours. A file is a PEEK: RET
;; shows it in the other window, read-only, and M-RET opens it as your own,
;; here. A file that already had a buffer is only shown.
(define (dired-visit-with-group group)
  (let ((p (dired-path-at-point))
        (entry (dired-entry)))
    (if p
        (cond ((equal? entry "..")
               (dired-open-parent! (dired-dir (current-buffer))))
              ((dired-directory? entry) (visit p group))
              ;; a file opens in another window by the display chain, so it
              ;; replaces the window of its own mode; Dired keeps the focus
              (else
               (let ((buf (visit-quietly p group)))
                 (when buf (display-buffer-other-window! buf)))
               p))
        (message "No file on this line"))))

(define-command "dired-visit" "Open the file on this line in another window, the one of its own mode first. A directory opens here"
  (lambda ()
    ;; The Dired buffer's group is more specific than a frame or project
    ;; fallback. An explicit visit also replaces inherited placement.
    (dired-visit-with-group (buffer-group (current-buffer)))))

(define-command "dired-quit" "Dismiss the peek, otherwise return through this window's directory history"
  (lambda ()
    (unless (peek-dismiss!)
      (let* ((win (active-window)) (cur (current-buffer))
             (history (window-eligible-history win)))
        (if (pair? history)
            (begin
              (switch-to-buffer-here! (car history))
              ;; Switching normally pushes CUR; popping must consume that entry
              ;; so q q walks back instead of toggling between two directories.
              (set-window-prev-buffers! win (cdr history)))
            (run-command "quit-window"))))))

(define-command "dired-open" "Open the file on this line as your own, here: a peek is kept"
  (lambda ()
    (let ((p (dired-path-at-point))
          (entry (dired-entry))
          (group (buffer-group (current-buffer))))
      (if p
          (if (or (equal? entry "..") (dired-directory? entry))
              (visit p group)
              (peek-open! p (lambda () (visit p group))))
          (message "No file on this line")))))

(define-command "dired-visit-in-group"
  "Visit this entry in the current group, or the Dired buffer's group"
  (lambda ()
    (let ((dired-buffer (current-buffer)))
      (dired-visit-with-group
        (or (frame-group) (buffer-group dired-buffer))))))

(define-command "dired-up" "Open the parent directory in Dired, where it was"
  (lambda ()
    (dired-open-parent! (dired-dir (current-buffer)))))

(define-command "dired-revert" "Re-read the directory and refresh the listing"
  (lambda ()
    (dired-refresh-buffer! (current-buffer))
    (message "Reverted")))

(define (dired-action-entry)
  (let ((e (dired-entry)))
    (if (or (not e) (equal? e "..")) #f e)))

(define (dired-action-targets buf)
  (filter (lambda (e) (not (equal? e ".."))) (list-targets buf)))

(define (dired-entry-base e)
  (if (string-suffix? "/" e)
      (substring e 0 (- (string-length e) 1))
      e))

(define-command "dired-rename" "Rename or move the file at point"
  (lambda ()
    (let ((entry (dired-action-entry))
          (buf (current-buffer)))
      (if (not entry)
          (message "Select a file, not the parent row")
          (dired-read-target "Rename to: " buf
            (lambda (destination)
              (let* ((source (string-append (dired-dir buf) "/" entry))
                     (target (expand-path (normalize-file-input destination)))
                     (moved (rename-file! source target)))
                (when moved
                  (with-current-buffer buf (dired-refresh-buffer! buf))
                  (message (string-append "Renamed to " target))))))))))

(define-command "dired-copy" "Copy the file at point, or all marked files"
  (lambda ()
    (let* ((buf (current-buffer))
           (entries (dired-action-targets buf)))
      (if (null? entries)
          (message "Select a file, not the parent row")
          (dired-read-target (if (= (length entries) 1) "Copy to: " "Copy into directory: ") buf
            (lambda (destination)
              (let* ((raw (normalize-file-input destination))
                     (dest (expand-path raw))
                     (as-dir? (or (> (length entries) 1)
                                  (string-suffix? "/" raw)
                                  (file-directory? dest))))
                (if (and (> (length entries) 1) (not as-dir?))
                    (message "Copy marked files into a directory")
                    (begin
                      (for-each
                        (lambda (e)
                          (let ((source (string-append (dired-dir buf) "/" e))
                                (target (if as-dir?
                                            (string-append dest "/" (dired-entry-base e))
                                            dest)))
                            (copy-file! source target)))
                        entries)
                      (with-current-buffer buf (dired-refresh-buffer! buf))
                      (message (string-append "Copied "
                                              (number->string (length entries))
                                              " file(s)")))))))))))

(define-command "dired-chmod" "Set the octal mode of the file at point or marked files"
  (lambda ()
    (let* ((buf (current-buffer))
           (entries (dired-action-targets buf)))
      (if (null? entries)
          (message "Select a file, not the parent row")
          (minibuffer-read "Mode (octal): " '()
            (lambda (mode)
              (for-each
                (lambda (e)
                  (set-file-mode! (string-append (dired-dir buf) "/" e) mode))
                entries)
              (with-current-buffer buf (dired-refresh-buffer! buf))
              (message "Mode changed")))))))

(define-command "dired-touch" "Touch the file at point or marked files"
  (lambda ()
    (let* ((buf (current-buffer))
           (entries (dired-action-targets buf)))
      (if (null? entries)
          (message "Select a file, not the parent row")
          (begin
            (for-each
              (lambda (e) (touch-file! (string-append (dired-dir buf) "/" e)))
              entries)
            (dired-refresh-buffer! buf)
            (message "Touched"))))))

(define-command "dired-symlink" "Create a symbolic link to the file at point"
  (lambda ()
    (let ((entry (dired-action-entry))
          (buf (current-buffer)))
      (if (not entry)
          (message "Select a file, not the parent row")
          (read-file-name "Link name: "
            (lambda (link)
              (let ((made (make-symlink!
                            (string-append (dired-dir buf) "/" entry)
                            (expand-path (normalize-file-input link)))))
                (when made
                  (with-current-buffer buf (dired-refresh-buffer! buf))
                  (message "Link created")))))))))

;; m, u, U, d and x are list-mode's: dired declares the delete flag in its
;; mode above and keeps no marking code of its own

(define-command "dired-mkdir" "Prompt for a name and create a directory here"
  (lambda ()
    (minibuffer-read "Create directory: " '()
      (lambda (name)
        (make-directory! (string-append (dired-dir (current-buffer)) "/" name))
        (dired-refresh-buffer! (current-buffer))
        (message "Created")))))

;; --- the rest of Emacs Dired: regexp marks, wdired, dwim target, shell ------

;; copy and rename offer the directory of a Dired in another window
(define dired-dwim-target #t)

;; a remote provider lists its own files; these verbs act on local paths
(define (dired-local? buf)
  (if (dired-provider buf)
      (begin (message "This operation is not supported by this directory provider.") #f)
      #t))

(define (dired-path buf name)
  (if (string-prefix? "/" name) name (string-append (dired-dir buf) "/" name)))

;; the directory of a Dired in another window of this frame, as the
;; dired-dwim-target of Emacs offers it
(define (dired-dwim-dir buf)
  (and dired-dwim-target
       (let loop ((ws (window-list)))
         (if (null? ws)
             #f
             (let ((other (cadr (car ws))))
               (if (and (not (equal? other buf))
                        (buffer-exists? other)
                        (dired-buffer? other))
                   (string-append (dired-dir other) "/")
                   (loop (cdr ws))))))))

(define (dired-read-target prompt buf k)
  (let ((dir (dired-dwim-dir buf)))
    (if dir (read-file-name-initial prompt dir k) (read-file-name prompt k))))

(define (dired-shown-files buf)
  (filter (lambda (e) (list-markable? buf e)) (list-entries buf)))

(define (dired-mark-matching! buf pat ch verb)
  (let ((hits (filter (lambda (e) (re-find pat (dired-entry-base e) 0))
                      (dired-shown-files buf))))
    (for-each (lambda (e) (list-mark! buf e ch)) hits)
    (list-redraw! buf)
    (message (string-append verb " " (number->string (length hits)) " file(s)"))))

(define-command "dired-mark-files-regexp" "Mark every shown file whose name matches a regexp"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Mark files (regexp): " '()
        (lambda (pat) (dired-mark-matching! buf pat *list-mark-char* "Marked"))))))

(define-command "dired-flag-files-regexp" "Flag every shown file whose name matches a regexp for trash"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Flag for trash (regexp): " '()
        (lambda (pat) (dired-mark-matching! buf pat "D" "Flagged"))))))

(define-command "dired-flag-backup-files" "Flag backup and auto-save files for trash"
  (lambda ()
    (dired-mark-matching! (current-buffer) "(~|^#.*#)$" "D" "Flagged")))

(define-command "dired-toggle-marks" "Mark the unmarked files and unmark the marked ones"
  (lambda ()
    (let* ((buf (current-buffer))
           (i (list-index buf)))
      (for-each
        (lambda (e)
          (let ((m (list-mark-of buf e)))
            (cond ((equal? m " ") (list-mark! buf e *list-mark-char*))
                  ((equal? m *list-mark-char*) (list-mark! buf e #f)))))
        (dired-shown-files buf))
      (list-redraw! buf)
      (when i (list-goto-index! buf i)))))

(define (dired-zip as bs)
  (if (or (null? as) (null? bs))
      '()
      (cons (list (car as) (car bs)) (dired-zip (cdr as) (cdr bs)))))

(define (dired-duplicate names)
  (cond ((null? names) #f)
        ((member (car names) (cdr names)) (car names))
        (else (dired-duplicate (cdr names)))))

;; PAIRS is ((OLD NEW) ...). Every file moves to a temporary name first,
;; so a swap or a rotation of names works. Answers the count, or #f.
(define (dired-rename-all! buf pairs)
  (let* ((olds (map car pairs))
         (news (map cadr pairs))
         (twice (dired-duplicate news))
         (clash (filter (lambda (n) (and (not (member n olds))
                                         (file-exists? (dired-path buf n))))
                        news)))
    (cond ((null? pairs) 0)
          (twice (message (string-append "Two files would be named " twice)) #f)
          ((pair? clash) (message (string-append "Already exists: " (car clash))) #f)
          (else
            (let* ((stamp (number->string (monotonic-ms)))
                   (moves (map (lambda (p)
                                 (list (car p) (string-append (car p) ".dired-" stamp) (cadr p)))
                               pairs)))
              (for-each (lambda (m) (rename-file! (dired-path buf (car m)) (dired-path buf (cadr m))))
                        moves)
              (for-each (lambda (m) (rename-file! (dired-path buf (cadr m)) (dired-path buf (caddr m))))
                        moves)
              (dired-refresh-buffer! buf)
              (length pairs))))))

(define-command "dired-do-rename-regexp" "Rename the marked files by a regexp replacement; \\1 is a group"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (map dired-entry-base (dired-action-targets buf))))
      (cond ((null? names) (message "Select a file, not the parent row"))
            ((dired-local? buf)
             (minibuffer-read "Rename from (regexp): " '()
               (lambda (pat)
                 (minibuffer-read (string-append "Rename " pat " to: ") '()
                   (lambda (repl)
                     (let ((n (dired-rename-all! buf
                                (filter (lambda (p) (not (equal? (car p) (cadr p))))
                                        (map (lambda (b) (list b (re-replace pat b repl))) names)))))
                       (when n
                         (message (string-append "Renamed " (number->string n) " file(s)")))))))))))))

;; wdired: the names as text. Change a line to rename that file; the
;; line count must stay. C-c C-c renames, C-c C-k leaves.
(define-command "dired-toggle-read-only" "Edit the file names as text: C-c C-c renames, C-c C-k cancels"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (map dired-entry-base (dired-shown-files buf)))
           (ed (string-append "*wdired:" (or (dired-dir buf) "") "*")))
      (when (dired-local? buf)
        (buffer-set-text! ed (string-append (string-join names "\n") "\n") #f)
        (buffer-set-local! ed 'wdired-dired buf)
        (buffer-set-local! ed 'wdired-names names)
        (buffer-set-local! ed 'mode-name "wdired-mode")
        (buffer-mark-saved! ed)
        (switch-to-buffer! ed)
        (set-mode! "wdired-mode")
        (message "Edit the names. C-c C-c renames, C-c C-k cancels")))))

(define (wdired-lines text)
  (let ((ls (map string-trim (string-split text "\n"))))
    (filter (lambda (l) (not (equal? l ""))) ls)))

(define (wdired-leave! ed)
  (let ((buf (buffer-local ed 'wdired-dired)))
    (buffer-mark-saved! ed)
    (if (and buf (buffer-exists? buf))
        (switch-to-buffer! buf)
        (run-command "quit-window"))
    (buffer-kill! ed)))

(define-command "wdired-finish-edit" "Rename the files whose names you changed"
  (lambda ()
    (let* ((ed (current-buffer))
           (buf (buffer-local ed 'wdired-dired))
           (olds (or (buffer-local ed 'wdired-names) '()))
           (news (wdired-lines (buffer-text ed))))
      (cond ((not (and buf (buffer-exists? buf)))
             (message "The Dired buffer is gone"))
            ((not (= (length olds) (length news)))
             (message "Keep one line for each file: do not add or remove lines"))
            (else
              (let ((n (dired-rename-all! buf
                         (filter (lambda (p) (not (equal? (car p) (cadr p))))
                                 (dired-zip olds news)))))
                (when n
                  (wdired-leave! ed)
                  (message (string-append "Renamed " (number->string n) " file(s)")))))))))

(define-command "wdired-abort-changes" "Leave the name edit and rename nothing"
  (lambda ()
    (wdired-leave! (current-buffer))
    (message "No files renamed")))

(define-mode "wdired-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #f)))

(mode-keys! "wdired-mode"
  '(("C-c C-c" "wdired-finish-edit") ("C-x C-s" "wdired-finish-edit")
    ("C-c C-k" "wdired-abort-changes")))

;; --- the * prefix: marking as Emacs Dired does it --------------------------

(define (dired-mark-where! buf pred verb)
  (let ((hits (filter (lambda (e) (pred (dired-info buf e) e)) (dired-shown-files buf))))
    (for-each (lambda (e) (list-mark! buf e *list-mark-char*)) hits)
    (list-redraw! buf)
    (message (string-append verb " " (number->string (length hits)) " file(s)"))))

(define (dired-type? info type) (and info (equal? (plist-get info 'type) type)))

(define-command "dired-mark-subdir-files" "Mark every file this listing shows"
  (lambda ()
    (dired-mark-where! (current-buffer) (lambda (info e) #t) "Marked")))

(define-command "dired-mark-directories" "Mark every directory this listing shows"
  (lambda ()
    (dired-mark-where! (current-buffer)
      (lambda (info e) (or (dired-directory? e) (dired-type? info "directory")))
      "Marked")))

(define-command "dired-mark-executables" "Mark every executable file this listing shows"
  (lambda ()
    (dired-mark-where! (current-buffer)
      (lambda (info e)
        (and (dired-type? info "regular")
             (re-find "^-(..x|.....x|........x)" (or (plist-get info 'perms) "") 0)))
      "Marked")))

(define-command "dired-mark-symlinks" "Mark every symbolic link this listing shows"
  (lambda ()
    (dired-mark-where! (current-buffer) (lambda (info e) (dired-type? info "symlink")) "Marked")))

(define-command "dired-mark-extension" "Mark every file with an extension"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Mark extension: " '()
        (lambda (ext)
          (let ((bare (if (string-prefix? "." ext) (substring ext 1 (string-length ext)) ext)))
            (dired-mark-matching! buf (string-append "[.]" (regexp-quote bare) "$")
                                  *list-mark-char* "Marked")))))))

(define-command "dired-change-marks" "Change one mark character to another"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Change mark: " '()
        (lambda (old)
          (minibuffer-read (string-append "Change " old " to: ") '()
            (lambda (new)
              (let ((hits (filter (lambda (e) (equal? (list-mark-of buf e) old))
                                  (dired-shown-files buf))))
                (for-each (lambda (e) (list-mark! buf e (if (equal? new " ") #f new))) hits)
                (list-redraw! buf)
                (message (string-append "Changed " (number->string (length hits)) " mark(s)"))))))))))

;; the next row with any mark or flag, around the end as Emacs goes
(define (dired-goto-marked! step)
  (let* ((buf (current-buffer))
         (rows (list-entries buf))
         (n (length rows))
         (i (or (list-index buf) 0)))
    (let loop ((k 1))
      (if (> k n)
          (message "No marked files")
          (let ((j (modulo (+ i (* step k)) n)))
            (if (equal? (list-mark-of buf (list-ref rows j)) " ")
                (loop (+ k 1))
                (list-goto-index! buf j)))))))

(define-command "dired-next-marked-file" "Move to the next marked file"
  (lambda () (dired-goto-marked! 1)))

(define-command "dired-prev-marked-file" "Move to the previous marked file"
  (lambda () (dired-goto-marked! -1)))

;; `*` in the command stands for every file, `?` runs it once for each
;; file; otherwise the files go at the end
(define (dired-shell-line cmd files)
  (let ((words (string-split cmd " "))
        (quoted (map sh-quote files)))
    (cond ((member "*" words)
           (string-join (map (lambda (w) (if (equal? w "*") (string-join quoted " ") w)) words) " "))
          ((member "?" words)
           (string-join
             (map (lambda (q) (string-join (map (lambda (w) (if (equal? w "?") q w)) words) " "))
                  quoted)
             "; "))
          (else (string-append cmd " " (string-join quoted " "))))))

(effects! '(write execute))
(define-command "dired-do-shell-command" "Run a shell command on the marked files: * is all of them, ? is each one"
  (lambda ()
    (let* ((buf (current-buffer))
           (files (map dired-entry-base (dired-action-targets buf))))
      (cond ((null? files) (message "Select a file, not the parent row"))
            ((dired-local? buf)
             (minibuffer-read
               (string-append "! on " (if (= (length files) 1)
                                            (car files)
                                            (string-append (number->string (length files)) " files"))
                              ": ")
               '()
               (lambda (cmd)
                 (let ((line (dired-shell-line cmd files))
                       (out "*Shell Command Output*"))
                   (message (string-append "Running: " line))
                   (shell-command->string line (string-append (dired-dir buf) "/")
                     (lambda (text)
                       (dired-refresh-buffer! buf)
                       (if (and (string? text) (not (equal? (string-trim text) "")))
                           (begin (buffer-set-text! out text #t)
                                  (display-buffer out))
                           (message (string-append "Done: " line)))))))))))))
(effects! '(write))

(define-key "ctl-x-map" "d" "dired")
(define-key "ctl-x-map" "C-d" "dired")

;;; --- the public surface -------------------------------------------------------
;;; Dired's callable surface is mostly its M-x commands, which apropos
;;; searches with their docstrings. These are the entry points an agent
;;; calls directly from eval-scheme.

(define (dired-marks buf) (list-marks buf))

(effects! '(read))
(category! 'files)
(public! 'default-directory
  "(default-directory) — current buffer's absolute working directory, including task chats")
(public! 'dired-open "(dired-open PATH) — open PATH in a Dired buffer; returns the buffer name")
(public! 'dired-dir "(dired-dir BUF) — the directory a Dired buffer is showing")
(public! 'dired-visible "(dired-visible BUF DIR) — the entries a Dired buffer is showing, after its filters")
(public! 'dired-marks "(dired-marks BUF) — the marked entries, as (name mark-char) pairs")
(public! 'ls "(ls [DIR]) — the files in DIR as (name type bytes mtime size date perms) plists; DIR defaults to this buffer's directory")
(catalog-meta! 'function "ls" 'domain 'files 'effects '(read))
(catalog-meta! 'function "dired-open" 'effects '(write))

(domain! 'files)
(effects! '(write))
;;; Directory providers reuse the real Dired mode and commands. The provider name
;;; is durable; its functions/specification are registered by the owning package.
(define *dired-providers* (if (boundp '*dired-providers*) *dired-providers* '()))
(define (dired-register-provider! name list-mode commands)
  (set! *dired-providers*
    (cons (list name list-mode commands)
      (filter (lambda (entry) (not (equal? (car entry) name))) *dired-providers*))))
(define (dired-provider buf)
  (assoc (buffer-local buf 'dired-provider) *dired-providers*))
(define-mode "Dired"
  (lambda ()
    (let* ((buf (current-buffer)) (provider (dired-provider buf)))
      (if provider
          (begin
            (list-mode-init! buf (cadr provider))
            ;; Provider-specific actions such as remote pagination augment Dired.
            (for-each (lambda (binding) (local-set-key (car binding) (cadr binding)))
              (or (plist-get (list-mode-opts (cadr provider)) 'keys) '())))
          (list-mode-init! buf "Dired")))))
(define (dired--provider-command! command)
  (let ((local (command-function command)) (doc (plist-get (catalog-entry 'command command) 'doc)))
    (define-command command (or doc command)
      (lambda ()
        (let ((provider (dired-provider (current-buffer))))
          (if provider
              (let ((target (assoc command (caddr provider))))
                (if target (run-command (cadr target))
                    (message "This operation is not supported by this directory provider.")))
              (local)))))))
(for-each dired--provider-command!
  '("dired-visit" "dired-open" "dired-visit-in-group" "dired-up" "dired-revert"
    "dired-rename" "dired-copy" "dired-mkdir" "dired-chmod" "dired-touch"
    "dired-symlink" "dired-sort-cycle" "dired-sort-reverse" "dired-dirs-first" "dired-filter-dotfiles"))
(public! 'dired-register-provider! "(dired-register-provider! NAME LIST-MODE COMMANDS) — register a directory listing and Dired-command dispatch map; set buffer-local dired-provider before applying Dired.")

(define-style! 'dired-semantic-list "
directory > file.semantic-direct.line {
  display: grid; grid-template-columns: none; grid-auto-columns: 1ch;
  column-gap: 0; align-items: baseline; white-space: nowrap;
}
directory > file.semantic-direct > [data-col] {
  grid-row: 1; grid-column: var(--field-column) / span var(--field-width);
  min-width: 0; white-space: pre; overflow: hidden;
}
directory > file.semantic-direct[mark]:not([mark='']):not([mark=' ']) {
  box-shadow: inset 3px 0 var(--accent-fg, #7aa2f7);
}
")
