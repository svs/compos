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

;; the buffer-local is the durable copy: locals ride desktop.etf, so a
;; restored dired knows its directory before its mode setup re-renders
(define (dired-dir buf) (buffer-local buf 'dired-dir))

(define (dired-directory? e) (string-suffix? "/" e))

(define (dired-stat buf e)
  (file-stat (string-append (dired-dir buf) "/" e)))

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
  (cond ((>= b 1048576) (string-append (number->string (quotient b 1048576)) " MB"))
        ((>= b 1024) (string-append (number->string (quotient b 1024)) " kB"))
        (else (string-append (number->string b) " B"))))

;; how big this file is against the biggest one here. The bar is five
;; cells, and a file that has any bytes at all fills one of them.
(define (dired-bar b top)
  (let loop ((i 1) (n 0))
    (if (> i 5)
        (string-append (string-repeat "█" n) (string-repeat "░" (- 5 n)))
        (loop (+ i 1) (if (and (> b 0) (>= (* b 5) (* top i))) i n)))))

(define (dired-top-size buf)
  (or (buffer-local buf 'dired-top) 1))

;;; --- what git says ------------------------------------------------------------
;;; One `git status` when the listing opens, kept on the buffer. A refresh
;;; redraws from the map: `/` narrows on every keystroke, and a git call
;;; per keystroke is a git call per keystroke.

(define (dired-vc-label code)
  (cond ((equal? code "??") "untracked")
        ((string-prefix? " " code) "modified")
        (else "staged")))

;; the entry this path belongs to: git answers with paths under the
;; directory, and a directory row says what its contents did
(define (dired-vc-entry path)
  (let ((i (string-index path "/")))
    (if i (substring path 0 (+ i 1)) path)))

(define (dired-vc-parse out)
  (fold (lambda (acc line)
          (if (< (string-length line) 4)
              acc
              (let* ((code (substring line 0 2))
                     (path (string-trim (substring line 3 (string-length line))))
                     (e (dired-vc-entry path)))
                (if (assoc e acc)
                    acc
                    (cons (list e (dired-vc-label code)) acc)))))
        '() (string-split out "\n")))

(define (dired-vc-scan! buf dir)
  (let ((out (shell-command->string
               "git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git status --porcelain ." dir)))
    (buffer-set-local! buf 'dired-vc (dired-vc-parse out))
    (buffer-set-local! buf 'dired-repo?
      (equal? "true" (string-trim
                       (shell-command->string
                         "git rev-parse --is-inside-work-tree 2>/dev/null" dir))))
    (buffer-set-local! buf 'dired-branch
      (string-trim (shell-command->string "git branch --show-current 2>/dev/null" dir)))
    (buffer-set-local! buf 'dired-free
      (string-trim (shell-command->string "df -h . | tail -1 | awk '{print $4}'" dir)))))

(define (dired-vc buf e)
  (let ((m (assoc e (or (buffer-local buf 'dired-vc) '()))))
    (cond (m (car (cdr m)))
          ((buffer-local buf 'dired-repo?) "tracked")
          (else ""))))

(define (dired-vc-face label)
  (cond ((equal? label "untracked") "alert")
        ((equal? label "modified") "warn")
        ((equal? label "staged") "ok")
        (else "faint")))

;;; --- the row ------------------------------------------------------------------

(define (dired-cells buf e)
  (if (equal? e "..")
      (list (list "▲" "accent") (list ".." "accent") "" "" "" "" "")
      (let* ((st (dired-stat buf e))
             (dir? (dired-directory? e))
             (b (dired-bytes (cadr st)))
             (vc (dired-vc buf e)))
        (list (if dir? (list "▸" "accent") (list "·" "faint"))
              (list e (if dir? "accent" #f))
              (if dir? "" (list (dired-bar b (dired-top-size buf)) "faint"))
              (if dir? (list "—" "faint") (list (cadr st) "dim"))
              (list (caddr st) "dim")
              (list (car st) "faint")
              (list vc (dired-vc-face vc))))))

;;; --- filters ------------------------------------------------------------------
;;; `/` narrows and `\` widens, and both are list-mode's: the stack, the
;;; label and the matching all live there, and `/` already reads the
;;; perms, the size, the date, the name and the mode. Dired adds the two
;;; kinds that text cannot say:
;;;   ("dot" "on")                     hide the dotfiles
;;;   ("type" dir|file|link|exec)      what the entry IS
;;; A person reaches the first with `.`; an agent pushes either one.

(define (dired-filter-match? dir e f)
  (let ((kind (car f)) (arg (car (cdr f))))
    (cond ((equal? kind "dot") (not (string-prefix? "." e)))
          ((equal? kind "type")
           (let ((perms (car (file-stat (string-append dir "/" e)))))
             (cond ((equal? arg "dir") (string-prefix? "d" perms))
                   ((equal? arg "link") (string-prefix? "l" perms))
                   ((equal? arg "exec") (if (string-index perms "x") #t #f))
                   (else (string-prefix? "-" perms)))))
          (else #t))))

;; the file annotator stats a bare name, so it must know which directory
;; this listing came from — the contract every file listing keeps
(define (dired-visible buf dir)
  (set! *marginalia-file-dir* (string-append dir "/"))
  (list-keep buf (list-dir dir)))

;; the whole directory, before the filters: the biggest file sets the
;; scale of the size bars, and the header counts what the narrowing hid
(define (dired-measure! buf dir)
  (let ((all (list-dir dir)))
    (buffer-set-local! buf 'dired-total (length all))
    (buffer-set-local! buf 'dired-top
      (fold (lambda (top e)
              (if (dired-directory? e)
                  top
                  (max top (dired-bytes (cadr (dired-stat buf e))))))
            1 all))
    (buffer-set-local! buf 'dired-used
      (fold (lambda (sum e)
              (if (dired-directory? e)
                  sum
                  (+ sum (dired-bytes (cadr (dired-stat buf e))))))
            0 all))))

;; git, df and the sizes answer once, when the listing opens or reverts.
;; A refresh redraws from what they left: `/` narrows on every keystroke,
;; and a scan per keystroke is a scan per keystroke. A restored dired
;; scans on its first refresh, because its locals came back empty.
(define (dired-scan-once! buf dir)
  (unless (buffer-local buf 'dired-vc)
    (dired-vc-scan! buf dir)
    (dired-measure! buf dir)))

(define (dired-rescan! buf)
  (buffer-set-local! buf 'dired-vc #f))

;; the title reads like a path a person says: home is "~"
(define (abbreviate-home p)
  (let ((home (expand-path "~")))
    (if (string-prefix? home p)
        (string-append "~" (substring p (string-length home) (string-length p)))
        p)))

(define (dired-title buf)
  (string-append (abbreviate-home (or (dired-dir buf) "")) "/"))

;; ".." is a way out of the directory, not a thing in it
(define (dired-meta buf)
  (let* ((n (list-count buf))
         (branch (buffer-local buf 'dired-branch))
         (free (buffer-local buf 'dired-free)))
    (string-join
      (append
        (list (string-append (number->string n) " "
                             (if (= n 1) "item" "items"))
              (string-append (dired-human (or (buffer-local buf 'dired-used) 0)) " used"))
        (if (and free (not (equal? free ""))) (list (string-append free " free")) '())
        (if (and branch (not (equal? branch ""))) (list (string-append "⎇ " branch)) '()))
      " · ")))

(define (dired-filter-push! f)
  (list-filter-push! (current-buffer) f)
  (dired-goto-first-entry))

;; the one filter you toggle rather than type: a dotfile is hidden by
;; being a dotfile, and no text you type says "not this kind of name"
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
(define-list-mode! "Dired"
  (list
    'doc (string-append
           "One directory as a table: name, size, modified, perms and what "
           "git says. Mark files with `m` and the whole listing with `*`; "
           "`x` deletes what you marked, and `d` flags a file for the same "
           "`x`. `RET` "
           "visits, `^` goes up. `/` narrows as you type — it matches the "
           "perms, the size, the date, the name and the mode the file would "
           "open in. `\\` widens by one and `.` hides the dotfiles. The "
           "filters persist with the buffer.")
    ;; a file name is a file name: `/` matches the same annotation
    ;; C-x C-f shows beside one
    'category 'file
    'filter (lambda (buf e f) (dired-filter-match? (dired-dir buf) e f))
    'rows (lambda (buf)
            (let ((dir (dired-dir buf)))
              (if (not dir)
                  '()
                  (begin (dired-scan-once! buf dir)
                         (cons ".." (dired-visible buf dir))))))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "name" #f)
                     (list "" 5)
                     (list "size" 7 'right)
                     (list "modified" 12)
                     (list "perms" 10)
                     (list "vc" 9)))
    'cells dired-cells
    'title dired-title
    'meta dired-meta
    'total (lambda (buf) (or (buffer-local buf 'dired-total) 0))
    'footer (lambda (buf)
              '(("RET" "visit") ("m" "mark") ("*" "all") ("d" "flag")
                ("x" "delete") ("R" "rename") ("/" "filter") ("." "dotfiles")
                ("^" "up") ("g" "revert") ("q" "quit")))
    ;; delete asks first — the one flag in the editor that cannot be undone
    'flags (list (list "d" "D" "delete"
                       (lambda (buf e)
                         (delete-file! (string-append (dired-dir buf) "/" e))
                         #t)
                       #t))
    'noun "file"
    'markable? (lambda (buf e) (not (equal? e "..")))
    'keys '(("RET" "dired-visit") ("g" "dired-revert") ("^" "dired-up")
            ("+" "dired-mkdir") ("R" "dired-rename") ("q" "quit-window")
            ("." "dired-filter-dotfiles"))))

(define (dired-open dir0)
  (let ((dir (expand-path dir0)))
    (let ((buf dir))
      (buffer-create buf)
      ;; the dir local first: the mode setup's refresh reads it
      (buffer-set-local! buf 'dired-dir dir)
      ;; re-opening a directory re-reads what git and the sizes say
      (dired-rescan! buf)
      (switch-to-buffer! buf)
      (set-mode! "Dired")
      (dired-goto-first-entry)
      buf)))

;; the entry on the current line: a name, the ".." token, or #f above them
(define (dired-entry) (list-current (current-buffer)))

(define (dired-path-at-point)
  (let ((e (dired-entry))
        (dir (dired-dir (current-buffer))))
    (if (and e dir)
        (if (equal? e "..")
            (expand-path (string-append dir "/.."))
            (string-append dir "/" e))
        #f)))

;; default-directory: dired's dir, else the file's dir, else a path-shaped
;; buffer name, else the dir the buffer was born in (buffer-create copies
;; it from the creating buffer), else ~
(define (path-directory p)
  (let ((i (string-rindex p "/")))
    (if i (substring p 0 (+ i 1)) p)))

(define (default-directory) (buffer-directory (current-buffer)))

(define (buffer-directory buf)
  (let ((dd (dired-dir buf))
        (p (buffer-path buf))
        (born (buffer-local buf 'default-directory)))
    (cond (dd (string-append dd "/"))
          (p (path-directory p))
          ((string-prefix? "/" buf) (path-directory buf))
          (born born)
          (else (string-append (expand-path "~") "/")))))

(define-command "dired" "Prompt for a directory and open it in Dired"
  (lambda ()
    (read-file-name "Dired (directory): "
      (lambda (d) (dired-open (normalize-file-input d))))))

;; movement is list-mode's — these names stay for the bindings and the
;; tests that call them
(define-command "dired-next" "Move down to the next line in the Dired buffer"
  (lambda () (list-move! 1)))

(define-command "dired-prev" "Move up to the previous line in the Dired buffer"
  (lambda () (list-move! -1)))

(define-command "dired-visit" "Visit the file or directory named on this line"
  (lambda ()
    (let ((p (dired-path-at-point)))
      (if p
          ;; visit handles dirs (dired) AND files (auto-mode + find-file-hook)
          (visit p)
          (message "No file on this line")))))

(define-command "dired-up" "Open the parent directory in Dired"
  (lambda ()
    (dired-open (expand-path (string-append (dired-dir (current-buffer)) "/..")))))

(define-command "dired-revert" "Re-read the directory and refresh the listing"
  (lambda ()
    (dired-rescan! (current-buffer))
    (list-refresh! (current-buffer))
    (message "Reverted")))

(define-command "dired-rename" "Rename or move the file at point"
  (lambda ()
    (let ((source (dired-path-at-point))
          (buf (current-buffer)))
      (if (not source)
          (message "No file on this line")
          (read-file-name "Rename to: "
            (lambda (destination)
              (let ((target (expand-path (normalize-file-input destination))))
                (rename-file! source target)
                (with-current-buffer buf
                  (dired-rescan! buf)
                  (list-refresh! buf))
                (message (string-append "Renamed to " target)))))))))

;; m, u, U, d and x are list-mode's: dired declares the delete flag in its
;; mode above and keeps no marking code of its own

(define-command "dired-mkdir" "Prompt for a name and create a directory here"
  (lambda ()
    (minibuffer-read "Create directory: " '()
      (lambda (name)
        (make-directory! (string-append (dired-dir (current-buffer)) "/" name))
        (list-refresh! (current-buffer))
        (message "Created")))))

(global-set-key "C-x d" "dired")

;;; --- the public surface -------------------------------------------------------
;;; Dired's callable surface is mostly its M-x commands, which apropos
;;; searches with their docstrings. These are the entry points an agent
;;; calls directly from eval-scheme.

(define (dired-marks buf) (list-marks buf))

(category! 'files)
(public! 'dired-open "(dired-open PATH) — open PATH in a Dired buffer; returns the buffer name")
(public! 'dired-dir "(dired-dir BUF) — the directory a Dired buffer is showing")
(public! 'dired-visible "(dired-visible BUF DIR) — the entries a Dired buffer is showing, after its filters")
(public! 'dired-marks "(dired-marks BUF) — the marked entries, as (name mark-char) pairs")
