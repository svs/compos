;;; dired.scm --- directory editor, written entirely in userland Scheme.
;;;
;;; The extensibility bar: no Elixir knows what dired is. Built from
;;; primitives: list-dir, file-stat, buffer ops, read-only buffers,
;;; local keymaps, the minibuffer.
;;;
;;; Keys (buffer-local):
;;;   n/p move · RET visit · ^ up · g revert
;;;   m mark · u unmark · d flag for deletion · x execute flags
;;;   + mkdir
;;;   / n name-regex · / e extension · / t type (dir/file/link/exec)
;;;   / . hide dotfiles · / p pop filter · / / clear filters
;;;
;;; Line format:  <mark> <perms>  <size>  <date>  <name>

(define *dired-dirs* '())
(define *dired-marks* '())          ; ((buf . ((name . mark-char) ...)) ...)
(define *dired-name-col* 37)        ; 1 mark + 1 sp + 10 perms + 2 + 8 size + 2 + 12 date + 1

(define (dired-dir buf)
  (let ((e (assoc buf *dired-dirs*)))
    (if e (cadr e) (buffer-local buf 'dired-dir))))

(define (dired-remember buf dir)
  ;; the buffer-local is the durable copy — the alist dies with the daemon,
  ;; locals ride desktop.etf so a restored dired knows its directory
  (buffer-set-local! buf 'dired-dir dir)
  (set! *dired-dirs* (cons (list buf dir) *dired-dirs*)))

(define (dired-marks buf)
  (let ((e (assoc buf *dired-marks*)))
    (if e (cadr e) '())))

(define (dired-set-mark buf name ch)
  (let ((marks (filter (lambda (m) (not (equal? (car m) name))) (dired-marks buf))))
    (set! *dired-marks*
      (cons (list buf (if ch (cons (list name ch) marks) marks))
            (filter (lambda (e) (not (equal? (car e) buf))) *dired-marks*)))))

(define (dired-mark-of buf name)
  (let ((m (assoc name (dired-marks buf))))
    (if m (cadr m) " ")))

(define (dired-line buf dir e)
  (let ((st (file-stat (string-append dir "/" e))))
    (string-append
      (dired-mark-of buf e) " "
      (car st) "  "
      (string-pad-left (cadr st) 8) "  "
      (caddr st) " "
      e "\n")))

;;; --- filters (dired-filter style) ---------------------------------------------
;;; A stack of narrowings in the 'dired-filters buffer-local — persists with
;;; the buffer, so a restored dired keeps its view. Entries:
;;;   ("name" REGEX) ("ext" EXT) ("type" dir|file|link|exec) ("dot" hide)

(define (dired-filters buf) (or (buffer-local buf 'dired-filters) '()))

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
  (let ((fs (dired-filters buf)))
    (filter (lambda (e)
              (let loop ((l fs))
                (cond ((null? l) #t)
                      ((dired-filter-match? dir e (car l)) (loop (cdr l)))
                      (else #f))))
            (list-dir dir))))

(define (dired-filters-label buf)
  (let ((fs (dired-filters buf)))
    (if (null? fs)
        ""
        (fold (lambda (acc f)
                (string-append acc "  " (car f) ":"
                  (let ((a (car (cdr f)))) (if (string? a) a "on"))))
              "   ·" (reverse fs)))))

(define (dired-filter-push! f)
  (let ((buf (current-buffer)))
    (buffer-set-local! buf 'dired-filters (cons f (dired-filters buf)))
    (dired-refresh buf (dired-dir buf))
    (dired-goto-first-entry)))

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
           (fs (dired-filters buf))
           (had (assoc "dot" fs)))
      (buffer-set-local! buf 'dired-filters
        (if had (filter (lambda (f) (not (equal? (car f) "dot"))) fs) fs))
      (if had
          (begin (dired-refresh buf (dired-dir buf)) (dired-goto-first-entry))
          (dired-filter-push! (list "dot" #t))))))

(define-command "dired-filter-pop" "Drop the most recent dired filter"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'dired-filters
        (let ((fs (dired-filters buf))) (if (null? fs) '() (cdr fs))))
      (dired-refresh buf (dired-dir buf))
      (dired-goto-first-entry))))

(define-command "dired-filter-clear" "Drop every dired filter"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'dired-filters '())
      (dired-refresh buf (dired-dir buf))
      (dired-goto-first-entry))))

(define (dired-refresh buf dir)
  (let ((old-point (point)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (string-append dir ":" (dired-filters-label buf) "\n"))
    (buffer-append! buf "  ..\n")
    (for-each
      (lambda (e) (buffer-append! buf (dired-line buf dir e)))
      (dired-visible buf dir))
    (goto-char! old-point)))

(define (dired-goto-first-entry)
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!))

(define (dired-install-keys!)
  (local-set-key "n" "dired-next")
  (local-set-key "p" "dired-prev")
  ;; the standard: remap line movement so arrows/C-n/C-p behave like n/p
  (local-remap! "next-line" "dired-next")
  (local-remap! "previous-line" "dired-prev")
  (local-set-key "RET" "dired-visit")
  (local-set-key "g" "dired-revert")
  (local-set-key "^" "dired-up")
  (local-set-key "m" "dired-mark")
  (local-set-key "u" "dired-unmark")
  (local-set-key "d" "dired-flag-delete")
  (local-set-key "x" "dired-do-flagged-delete")
  (local-set-key "+" "dired-mkdir")
  (local-set-key "q" "quit-window")
  ;; dired-filter style narrowing under the / prefix
  (local-set-key "/ n" "dired-filter-name")
  (local-set-key "/ m" "dired-filter-mode")
  (local-set-key "/ e" "dired-filter-ext")
  (local-set-key "/ t" "dired-filter-type")
  (local-set-key "/ ." "dired-filter-dotfiles")
  (local-set-key "/ p" "dired-filter-pop")
  (local-set-key "/ /" "dired-filter-clear"))

;; a registered mode so desktop restore can re-run the setup — without it
;; a restored dired came back as a plain editable buffer (no keymap, no
;; read-only: RET inserted newlines instead of visiting)
(define-mode "Dired"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'mode-name "Dired")
      (dired-install-keys!)
      (let ((dir (dired-dir buf)))
        (when dir (dired-refresh buf dir)))
      (buffer-set-read-only! buf #t))))

(define (dired-open dir0)
  (let ((dir (expand-path dir0)))
    (let ((buf dir))
      (buffer-create buf)
      (dired-remember buf dir)
      (switch-to-buffer! buf)
      (set-mode! "Dired")
      (dired-goto-first-entry)
      buf)))

;; The entry named on the current line, or #f (header/.. lines return the
;; ".." token so navigation still works).
(define (dired-entry)
  (let ((line (line-text)))
    (if (equal? line "  ..")
        ".."
        (if (> (string-length line) *dired-name-col*)
            (substring line *dired-name-col* (string-length line))
            #f))))

(define (dired-path-at-point)
  (let ((e (dired-entry))
        (dir (dired-dir (current-buffer))))
    (if (and e dir)
        (if (equal? e "..")
            (expand-path (string-append dir "/.."))
            (string-append dir "/" e))
        #f)))

;; default-directory: dired's dir, else the file's dir, else ~
(define (path-directory p)
  (let ((i (string-rindex p "/")))
    (if i (substring p 0 (+ i 1)) p)))

(define (default-directory)
  (let ((dd (dired-dir (current-buffer))))
    (if dd
        (string-append dd "/")
        (let ((p (buffer-path (current-buffer))))
          (if p
              (path-directory p)
              (string-append (expand-path "~") "/"))))))

(define-command "dired" "Prompt for a directory and open it in Dired"
  (lambda ()
    (let ((dd (default-directory)))
      (set! *file-nav-dir* dd)
      (minibuffer-read* "Dired (directory): " (list-dir dd)
        (list (list 'complete file-complete)
              (list 'change file-nav-change)
              (list 'initial dd)
              (list 'confirm (lambda (d) (dired-open (normalize-file-input d)))))))))

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
    (dired-refresh (current-buffer) (dired-dir (current-buffer)))
    (message "Reverted")))

(define (dired-mark-and-advance ch)
  (let ((e (dired-entry)))
    (if (and e (not (equal? e "..")))
        (begin
          (dired-set-mark (current-buffer) e ch)
          (dired-refresh (current-buffer) (dired-dir (current-buffer)))
          (next-line!)
          (beginning-of-line!))
        (message "No file on this line"))))

(define-command "dired-mark" "Mark the file at point and move to the next line"
  (lambda () (dired-mark-and-advance "*")))
(define-command "dired-unmark" "Unmark the file at point and move to the next line"
  (lambda () (dired-mark-and-advance #f)))
(define-command "dired-flag-delete" "Flag the file at point for deletion"
  (lambda () (dired-mark-and-advance "D")))

(define (dired-flagged buf)
  (map car (filter (lambda (m) (equal? (cadr m) "D")) (dired-marks buf))))

(define-command "dired-do-flagged-delete" "Delete the files flagged for deletion"
  (lambda ()
    (let ((buf (current-buffer)))
      (let ((flagged (dired-flagged buf)))
        (if (null? flagged)
            (message "No files flagged for deletion")
            (minibuffer-read
              (string-append "Delete " (number->string (length flagged))
                             " file(s) [" (string-join flagged " ") "]? ")
              (list "yes" "no")
              (lambda (ans)
                (if (equal? ans "yes")
                    (begin
                      (for-each
                        (lambda (name)
                          (delete-file! (string-append (dired-dir buf) "/" name))
                          (dired-set-mark buf name #f))
                        flagged)
                      (dired-refresh buf (dired-dir buf))
                      (message (string-append "Deleted "
                                              (number->string (length flagged)) " file(s)")))
                    (message "Cancelled")))))))))

(define-command "dired-mkdir" "Prompt for a name and create a directory here"
  (lambda ()
    (minibuffer-read "Create directory: " '()
      (lambda (name)
        (make-directory! (string-append (dired-dir (current-buffer)) "/" name))
        (dired-refresh (current-buffer) (dired-dir (current-buffer)))
        (message "Created")))))

(global-set-key "C-x d" "dired")
