;;; --- text scale (Emacs text-scale-mode, on the Cmd chords) ---------------
;;; Two scales. Each is a ladder of factors 1.2^N (text-scale-mode-step).
;;;
;;; The application scale: Cmd-= / Cmd-- / Cmd-0. It sets the zoom of the
;;; 'ui face. The page applies that root variable as `zoom` on the editor
;;; root, so every window, the modeline, the minibuffer, and every rendered
;;; page grow together. It persists in custom.scm like a setting.
;;;
;;; The buffer scale: Cmd-Shift-= / Cmd-Shift-- / Cmd-Shift-0. Shift rides
;;; the character, so the chords arrive as s-+, s-_, and s-). The scale
;;; writes a factor into the buffer's face remap. A text window multiplies
;;; its default size by the factor. A rendered page is an iframe, a separate
;;; document that inherits no variable, so the page zooms by the factor.
;;; The remap MERGES: a buffer's own family, size, and line-height stay.

(define *scale-factors*
  '((-4 "0.482") (-3 "0.579") (-2 "0.694") (-1 "0.833") (0 "1")
    (1 "1.2") (2 "1.44") (3 "1.728") (4 "2.074") (5 "2.488") (6 "2.986")))

(define (scale-clamp n) (max -4 (min 6 n)))
(define (scale-factor n) (cadr (assoc (scale-clamp n) *scale-factors*)))
(define (scale-label what n)
  (if (= n 0)
      (string-append what " scale reset")
      (string-append what " scale " (if (> n 0) "+" "") (number->string n))))

;; The 'text-scale local is the truth. It rides the buffer's checkpoint,
;; so the scale survives a restart and a wake. The remap and the window
;; style derive from it: sync writes them again after a mode restores a
;; remap it saved before the scale was set.
(define (text-scale-sync! buf)
  (let ((n (scale-clamp (or (buffer-local buf 'text-scale) 0))))
    (face-remap-in! buf 'text-scale
      (if (= n 0) '() (list 'factor (scale-factor n))))))

(define (text-scale-apply! buf n0)
  (let ((n (scale-clamp n0)))
    (buffer-set-local! buf 'text-scale n)
    (text-scale-sync! buf)
    (message (scale-label "text" n))))

(define (text-scale-step! d)
  (let ((buf (current-buffer)))
    (text-scale-apply! buf (+ (or (buffer-local buf 'text-scale) 0) d))))

(define-command "text-scale-increase" "Make this buffer's text larger"
  (lambda () (text-scale-step! 1)))
(define-command "text-scale-decrease" "Make this buffer's text smaller"
  (lambda () (text-scale-step! -1)))
(define-command "text-scale-reset" "Give this buffer the normal text size"
  (lambda () (text-scale-apply! (current-buffer) 0)))

(defcustom 'ui-scale 0
  "Text scale of the whole application: a step on the 1.2 ladder. 0 is normal."
  'group 'appearance
  'set (lambda (n) (set-face-attribute! 'ui 'zoom (scale-factor n))))

;; defcustom stores the value; the face must say it too, on load and
;; after a restart
(set-face-attribute! 'ui 'zoom (scale-factor ui-scale))

;; The frame echo area can sit at the top or bottom of the frame.
;; The CSS order is a face variable, so the choice persists with custom.scm.
(defcustom 'echo-area-position 'top
  "Position of the frame echo area: 'top or 'bottom."
  'group 'appearance
  'type 'choice
  'set (lambda (position)
         (set-face-attribute! 'ui 'echo-order
           (if (equal? position 'bottom) "10" "-1"))))

(set-face-attribute! 'ui 'echo-order
  (if (equal? echo-area-position 'bottom) "10" "-1"))

;; The size of buffer text is the default face's size. 13px was the
;; design size; the reading size stands two steps up the same 1.2 ladder
;; (13 x 1.44). A defface! default survives a theme load, because no
;; theme names a size on the default face.
(defcustom 'default-font-size "20.8px"
  "The size of buffer text: the default face's size, as CSS. Two steps up the 1.2 ladder from 13px."
  'group 'appearance
  'set (lambda (size) (defface! 'default 'size size)))

(defface! 'default 'size default-font-size)

(define (ui-scale-apply! n0)
  (let ((n (scale-clamp n0)))
    (customize-save! 'ui-scale n)
    (message (scale-label "ui" n))))

(define (ui-scale-step! d)
  (ui-scale-apply! (+ (or ui-scale 0) d)))

(define-command "ui-scale-increase" "Make the whole application's text larger"
  (lambda () (ui-scale-step! 1)))
(define-command "ui-scale-decrease" "Make the whole application's text smaller"
  (lambda () (ui-scale-step! -1)))
(define-command "ui-scale-reset" "Give the whole application the normal text size"
  (lambda () (ui-scale-apply! 0)))

(global-set-key "s-=" "ui-scale-increase")
(global-set-key "s--" "ui-scale-decrease")
(global-set-key "s-0" "ui-scale-reset")

(global-set-key "s-+" "text-scale-increase")
(global-set-key "s-_" "text-scale-decrease")
(global-set-key "s-)" "text-scale-reset")

;; the Ctrl shapes of the buffer chords: Ctrl-Shift-+ and Ctrl-Shift--
;; arrive as C-+ and C-_. Undo keeps C-/ and C-x u; C-_ joins the scale.
(global-set-key "C-+" "text-scale-increase")
(global-set-key "C-_" "text-scale-decrease")

(category! 'ui)
(public! 'text-scale-apply!
  "(text-scale-apply! BUF N) — set BUF's text scale to step N on the 1.2 ladder; 0 is normal")
(public! 'text-scale-sync!
  "(text-scale-sync! BUF) — write BUF's remap again from its 'text-scale local")
(public! 'ui-scale-apply!
  "(ui-scale-apply! N) — set the whole application's text scale to step N; 0 is normal")
