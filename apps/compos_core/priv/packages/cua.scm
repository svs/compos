;;; cua.scm --- CUA selection: Shift extends the region.
;;;
;;; The shared mechanism behind Emacs's cua-mode and shift-select-mode: a
;;; motion with Shift held starts a region at point when there is none and
;;; extends it. The commands here move by the same primitives as the plain
;;; motions, so a mode that changes what a line or a word is changes them
;;; too. writing-mode binds them in its own buffers; cua-mode binds them
;;; everywhere.

(domain! 'editing)
(effects! '(write))

(define (cua--select! mover)
  (unless (mark) (set-mark! (point)))
  (mover))

(define-command "cua-select-backward" "Extend the region one character left"
  (lambda () (cua--select! backward-char!)))
(define-command "cua-select-forward" "Extend the region one character right"
  (lambda () (cua--select! forward-char!)))
(define-command "cua-select-backward-word" "Extend the region one word left"
  (lambda () (cua--select! backward-word!)))
(define-command "cua-select-forward-word" "Extend the region one word right"
  (lambda () (cua--select! forward-word!)))
(define-command "cua-select-up" "Extend the region one visual line up"
  (lambda () (visual-previous-line! #t)))
(define-command "cua-select-down" "Extend the region one visual line down"
  (lambda () (visual-next-line! #t)))
(define-command "cua-select-line-start" "Extend the region to the start of the line"
  (lambda () (visual-beginning-of-line! #t)))
(define-command "cua-select-line-end" "Extend the region to the end of the line"
  (lambda () (visual-end-of-line! #t)))
(define-command "cua-select-buffer-start" "Extend the region to the start of the buffer"
  (lambda () (cua--select! beginning-of-buffer!)))
(define-command "cua-select-buffer-end" "Extend the region to the end of the buffer"
  (lambda () (cua--select! end-of-buffer!)))
(define-command "cua-select-all" "Select the entire buffer"
  (lambda ()
    (set-mark! (buffer-size (current-buffer)))
    (goto-char! 0)))

;; the bindings cua-mode installs everywhere; a local map still wins
(define cua--keys
  '(("S-<left>" "cua-select-backward")
    ("S-<right>" "cua-select-forward")
    ("S-<up>" "cua-select-up")
    ("S-<down>" "cua-select-down")
    ("S-<home>" "cua-select-line-start")
    ("S-<end>" "cua-select-line-end")
    ("M-S-<left>" "cua-select-backward-word")
    ("M-S-<right>" "cua-select-forward-word")
    ("C-S-<left>" "cua-select-backward-word")
    ("C-S-<right>" "cua-select-forward-word")
    ("s-S-<left>" "cua-select-line-start")
    ("s-S-<right>" "cua-select-line-end")
    ("s-S-<up>" "cua-select-buffer-start")
    ("s-S-<down>" "cua-select-buffer-end")))

(define *cua-mode* #f)

(define (cua-mode-on?) *cua-mode*)

(define (cua--enable!)
  (for-each (lambda (k) (global-set-key (car k) (cadr k))) cua--keys)
  (set! *cua-mode* #t))

(define (cua--disable!)
  (for-each (lambda (k) (global-unset-key (car k))) cua--keys)
  (set! *cua-mode* #f))

(define-command "cua-mode" "Toggle Shift-selection in every buffer"
  (lambda ()
    (if *cua-mode*
        (begin (cua--disable!) (message "CUA mode disabled"))
        (begin (cua--enable!) (message "CUA mode enabled")))))

(mode-doc! "cua-mode"
  "Shift with a motion key extends the region, in every buffer. The commands are cua-select-*; writing-mode binds the same commands in its own buffers.")

(catalog-meta! 'command "cua-mode" 'domain 'editing 'effects '(write))
(public! 'cua-mode-on? "(cua-mode-on?) — #t when cua-mode binds the Shift selections globally")
