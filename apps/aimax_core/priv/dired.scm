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
;;;   m mark · u unmark · U unmark all · d flag for deletion · x execute
;;;   + mkdir
;;;   / n name-regex · / e extension · / t type (dir/file/link/exec)
;;;   / . hide dotfiles · / p pop filter · / / clear filters
;;;
;;; Line format:  <mark> <perms>  <size>  <date>  <name>

;; the buffer-local is the durable copy: locals ride desktop.etf, so a
;; restored dired knows its directory before its mode setup re-renders
(define (dired-dir buf) (buffer-local buf 'dired-dir))

(define (dired-line buf dir e)
  (let ((st (file-stat (string-append dir "/" e))))
    (string-append
      " " (car st) "  "
      (string-pad-left (cadr st) 8) "  "
      (caddr st) " "
      e)))

;;; --- filters (dired-filter style) ---------------------------------------------
;;; The stack and its label are list-mode's ('list-filters, per buffer,
;;; persists with the desktop); only the matching language is dired's:
;;;   ("name" REGEX) ("ext" EXT) ("type" dir|file|link|exec)
;;;   ("dot" "on") ("mode" MAJOR-MODE)

(define (dired-filter-match? dir e f)
  (let ((kind (car f)) (arg (car (cdr f))))
    (cond ((equal? kind "name") (re-match? arg e))
          ((equal? kind "ext") (string-suffix? (string-append "." arg) e))
          ((equal? kind "dot") (not (string-prefix? "." e)))
          ((equal? kind "type")
           (let ((perms (car (file-stat (string-append dir "/" e)))))
             (cond ((equal? arg "dir") (string-prefix? "d" perms))
                   ((equal? arg "link") (string-prefix? "l" perms))
                   ((equal? arg "exec") (if (string-index perms "x") #t #f))
                   (else (string-prefix? "-" perms)))))
          ;; major mode the file would open in (auto-mode-alist); directories
          ;; stay visible so the tree remains navigable while narrowed
          ((equal? kind "mode")
           (or (string-suffix? "/" e)
               (equal? (auto-mode-for e) arg)))
          (else #t))))

(define (dired-visible buf dir)
  (let ((fs (list-filters buf)))
    (filter (lambda (e)
              (let loop ((l fs))
                (cond ((null? l) #t)
                      ((dired-filter-match? dir e (car l)) (loop (cdr l)))
                      (else #f))))
            (list-dir dir))))

(define (dired-filter-push! f)
  (list-filter-push! (current-buffer) f)
  (dired-goto-first-entry))

(define-command "dired-filter-name" "Narrow dired to names matching a regex"
  (lambda ()
    (minibuffer-read "Filter names (regex): " '()
      (lambda (pat) (unless (equal? pat "") (dired-filter-push! (list "name" pat)))))))

(define-command "dired-filter-ext" "Narrow dired to one extension"
  (lambda ()
    (minibuffer-read "Filter extension: " '()
      (lambda (e) (unless (equal? e "") (dired-filter-push! (list "ext" e)))))))

(define (dired-mode-candidates)
  (let loop ((es *auto-mode-alist*) (acc '()))
    (if (null? es)
        (reverse acc)
        (loop (cdr es)
              (let ((m (car (cdr (car es)))))
                (if (member m acc) acc (cons m acc)))))))

(define-command "dired-filter-mode" "Narrow dired to files opening in one major mode"
  (lambda ()
    (minibuffer-read "Filter by mode: "
      (dired-mode-candidates)
      (lambda (m) (unless (equal? m "") (dired-filter-push! (list "mode" m)))))))

(define-command "dired-filter-type" "Narrow dired by entry type (file mode)"
  (lambda ()
    (minibuffer-read "Type: "
      (list (list "dir" "directories only")
            (list "file" "regular files only")
            (list "link" "symlinks only")
            (list "exec" "anything executable"))
      (lambda (t) (unless (equal? t "") (dired-filter-push! (list "type" t)))))))

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

(define-command "dired-filter-pop" "Drop the most recent dired filter"
  (lambda ()
    (list-filter-pop! (current-buffer))
    (dired-goto-first-entry)))

(define-command "dired-filter-clear" "Drop every dired filter"
  (lambda ()
    (list-filter-clear! (current-buffer))
    (dired-goto-first-entry)))

(define (dired-goto-first-entry)
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!))

;; ".." is entry zero, so RET on it works through the same list-current
;; path as every real row; marks skip it
(define-list-mode! "Dired"
  (list
    'doc (string-append
           "One directory as a list: mark files with `m`, flag them with `d`, "
           "delete the flagged ones with `x`. `RET` visits, `^` goes up. "
           "Narrow the listing with the `/` filters; the filters persist "
           "with the buffer.")
    'rows (lambda (buf)
            (let ((dir (dired-dir buf)))
              (if dir (cons ".." (dired-visible buf dir)) '())))
    'render (lambda (buf e)
              (if (equal? e "..")
                  " .."
                  (dired-line buf (dired-dir buf) e)))
    ;; delete asks first — the one flag in the editor that cannot be undone
    'flags (list (list "d" "D" "delete"
                       (lambda (buf e)
                         (delete-file! (string-append (dired-dir buf) "/" e))
                         #t)
                       #t))
    'noun "file"
    'markable? (lambda (buf e) (not (equal? e "..")))
    'header (lambda (buf)
              (string-append (or (dired-dir buf) "") ":"
                             (list-filters-label buf)))
    'keys '(("RET" "dired-visit") ("g" "dired-revert") ("^" "dired-up")
            ("n" "dired-next") ("p" "dired-prev")
            ("+" "dired-mkdir") ("q" "quit-window")
            ("/ n" "dired-filter-name") ("/ m" "dired-filter-mode")
            ("/ e" "dired-filter-ext") ("/ t" "dired-filter-type")
            ("/ ." "dired-filter-dotfiles") ("/ p" "dired-filter-pop")
            ("/ /" "dired-filter-clear"))
    'remap '(("next-line" "dired-next") ("previous-line" "dired-prev"))))

(define (dired-open dir0)
  (let ((dir (expand-path dir0)))
    (let ((buf dir))
      (buffer-create buf)
      ;; the dir local first: the mode setup's refresh reads it
      (buffer-set-local! buf 'dired-dir dir)
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

(define-command "dired-next" "Move down to the next line in the Dired buffer"
  (lambda () (next-line!) (beginning-of-line!)))

(define-command "dired-prev" "Move up to the previous line in the Dired buffer"
  (lambda () (previous-line!) (beginning-of-line!)))

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
    (list-refresh! (current-buffer))
    (message "Reverted")))

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
