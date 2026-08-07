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
;;;
;;; Line format:  <mark> <perms>  <size>  <date>  <name>

(define *dired-dirs* '())
(define *dired-marks* '())          ; ((buf . ((name . mark-char) ...)) ...)
(define *dired-name-col* 37)        ; 1 mark + 1 sp + 10 perms + 2 + 8 size + 2 + 12 date + 1

(define (dired-dir buf)
  (let ((e (assoc buf *dired-dirs*)))
    (if e (cadr e) #f)))

(define (dired-remember buf dir)
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

(define (dired-refresh buf dir)
  (let ((old-point (point)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf (string-append dir ":\n"))
    (buffer-append! buf "  ..\n")
    (for-each
      (lambda (e) (buffer-append! buf (dired-line buf dir e)))
      (list-dir dir))
    (goto-char! old-point)))

(define (dired-goto-first-entry)
  (goto-char! 0)
  (next-line!)
  (beginning-of-line!))

(define (dired-open dir0)
  (let ((dir (expand-path dir0)))
    (let ((buf dir))
      (buffer-create buf)
      (dired-remember buf dir)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'mode-name "Dired")
      (switch-to-buffer! buf)
      (dired-refresh buf dir)
      (dired-goto-first-entry)
      (local-set-key "n" "dired-next")
      (local-set-key "p" "dired-prev")
      (local-set-key "RET" "dired-visit")
      (local-set-key "g" "dired-revert")
      (local-set-key "^" "dired-up")
      (local-set-key "m" "dired-mark")
      (local-set-key "u" "dired-unmark")
      (local-set-key "d" "dired-flag-delete")
      (local-set-key "x" "dired-do-flagged-delete")
      (local-set-key "+" "dired-mkdir")
      (local-set-key "q" "quit-window")
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
