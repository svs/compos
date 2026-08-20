;;; appearance.scm --- the chrome the user sets: rendered-page typography.
;;;
;;; The client reads the 'preview face for every rendered page — browse,
;;; markdown previews, help. The values live HERE, as settings: these
;;; defaults are one taste, and customize-save! or init.scm replaces
;;; them like any other setting. M-x preview-font-toggle flips between
;;; the serif and the monospace stacks.

(domain! 'ui)
(effects! '(write))

(define *preview-serif* "Spectral,Georgia,serif")
(define *preview-mono* "'IBM Plex Mono',ui-monospace,Menlo,monospace")

(defcustom 'preview-font-family *preview-serif*
  "Font family for rendered pages: previews, browse, help."
  'group 'appearance
  'set (lambda (v) (set-face-attribute! 'preview 'family v)))

(defcustom 'preview-font-size "16.5px"
  "Font size for rendered pages."
  'group 'appearance
  'set (lambda (v) (set-face-attribute! 'preview 'size v)))

;; defcustom stores the value; the face must say it too, on load and
;; after a restart
(set-face-attribute! 'preview
  'family preview-font-family
  'size preview-font-size)

(define-command "preview-font-toggle"
  "Switch rendered pages between the serif and the monospace stacks"
  (lambda ()
    (let ((mono? (string-contains? preview-font-family "Mono")))
      (customize-set! 'preview-font-family
                      (if mono? *preview-serif* *preview-mono*))
      (customize-set! 'preview-font-size (if mono? "16.5px" "14.5px"))
      (message (if mono? "rendered pages: serif" "rendered pages: monospace")))))

;;; --- text scale (Emacs C-x C-+, on the Cmd chords) ----------------------------
;;; Per-buffer: the default face's size walks a ladder through the same
;;; face remap writing-mode uses, so line height and wrapping follow.
;;; The remap MERGES — a buffer's own family and line-height stay.

(define *text-scale-sizes*
  '("9px" "10px" "11px" "12px" "13px" "15px" "17px" "20px" "23px" "27px" "31px"))
(define *text-scale-base* 4)

(define (text-scale--without-size kvs)
  (let loop ((ks kvs) (out '()))
    (cond ((null? ks) (reverse out))
          ((equal? (car ks) 'size) (loop (cdr (cdr ks)) out))
          (else (loop (cdr (cdr ks))
                      (cons (car (cdr ks)) (cons (car ks) out)))))))

(define (text-scale-apply! buf n0)
  (let* ((i (max 0 (min (- (length *text-scale-sizes*) 1)
                        (+ *text-scale-base* n0))))
         (n (- i *text-scale-base*))
         (old (let ((e (assoc 'default (or (buffer-local buf 'face-remap) '()))))
                (if e (car (cdr e)) '())))
         (rest (text-scale--without-size old)))
    (buffer-set-local! buf 'text-scale n)
    (face-remap-in! buf 'default
      (if (= n 0)
          rest
          (append rest (list 'size (nth i *text-scale-sizes*)))))
    (message (if (= n 0)
                 "text scale reset"
                 (string-append "text scale "
                                (if (> n 0) "+" "") (number->string n))))))

(define (text-scale-step! d)
  (let ((buf (current-buffer)))
    (text-scale-apply! buf (+ (or (buffer-local buf 'text-scale) 0) d))))

(define-command "text-scale-increase" "Make this buffer's text larger"
  (lambda () (text-scale-step! 1)))
(define-command "text-scale-decrease" "Make this buffer's text smaller"
  (lambda () (text-scale-step! -1)))
(define-command "text-scale-reset" "Give this buffer the normal text size"
  (lambda () (text-scale-apply! (current-buffer) 0)))

(global-set-key "s-+" "text-scale-increase")
(global-set-key "s-=" "text-scale-increase")
(global-set-key "s--" "text-scale-decrease")
(global-set-key "s-0" "text-scale-reset")

;; the Ctrl shapes of the same chords: Ctrl-Shift-+ and Ctrl-Shift--
;; arrive as C-+ and C-_, because shift rides the character. Undo
;; keeps C-/ and C-x u; C-_ joins the scale.
(global-set-key "C-+" "text-scale-increase")
(global-set-key "C-_" "text-scale-decrease")

(category! 'ui)
(public! 'preview-font-toggle
  "(run-command \"preview-font-toggle\") — flip rendered pages between serif and monospace")
(public! 'text-scale-apply!
  "(text-scale-apply! BUF N) — set BUF's text scale to step N; 0 is normal")
