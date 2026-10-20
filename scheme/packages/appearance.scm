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

;; A buffer keeps its own size, so a size set once in a buffer you no
;; longer remember stays set. This is the one door back to normal for
;; every buffer at once. It touches only the buffers that carry a
;; scale, so a dormant buffer at the normal size is never woken.
(define (text-scale-reset-all!)
  (let loop ((bs (buffer-list)) (n 0))
    (if (null? bs)
        n
        (let* ((b (car bs))
               (s (buffer-local b 'text-scale)))
          (if (and s (not (= s 0)))
              (begin (buffer-set-local! b 'text-scale 0)
                     (text-scale-sync! b)
                     (loop (cdr bs) (+ n 1)))
              (loop (cdr bs) n))))))

(define-command "text-scale-reset-all" "Give every buffer the normal text size"
  (lambda ()
    (let ((n (text-scale-reset-all!)))
      (message (if (= n 0)
                   "every buffer already has the normal text size"
                   (string-append "normal text size in "
                                  (number->string n)
                                  (if (= n 1) " buffer" " buffers")))))))

;; How a buffer writes its name. editor.scm owns the grammar and the
;; default; this declares it, so a name reads the same way after a restart.
;; *strong* ~dim~ `mono` :icon:, and :mode: is the buffer's own icon.
;; groups.scm declares group-name-format, the same grammar for a group.
(defcustom 'buffer-name-format ":mode: %n"
  "How a buffer names itself: %n the compact name, %N the buffer name, %m the mode, %p the project. *strong*, ~dim~, `mono`, :icon:."
  'group 'appearance)

(defcustom 'ui-scale 0
  "Text scale of the whole application: a step on the 1.2 ladder. 0 is normal."
  'group 'appearance
  'set (lambda (n) (set-face-attribute! 'ui 'zoom (scale-factor n))))

;; defcustom stores the value; the face must say it too, on load and
;; after a restart
(set-face-attribute! 'ui 'zoom (scale-factor ui-scale))

;; The frame echo area can sit at the top or bottom of the frame.
;; The CSS order is a face variable, so the choice persists with custom.scm.
(defcustom 'echo-area-position 'bottom
  "Position of the frame echo area: 'top or 'bottom. The design puts it at the bottom, under every window."
  'group 'appearance
  'type 'choice
  'set (lambda (position)
         (set-face-attribute! 'ui 'echo-order
           (if (equal? position 'bottom) "10" "-1"))))

(set-face-attribute! 'ui 'echo-order
  (if (equal? echo-area-position 'bottom) "10" "-1"))

;; The which-key panel waits before it shows, so a fast prefix chord
;; never draws it (Emacs which-key-idle-delay). The delay is a 'ui face
;; variable; the page reads it as the panel's animation delay.
(define (which-key-delay-css seconds)
  (string-append (number->string seconds) "s"))

(defcustom 'which-key-idle-delay 0.5
  "Seconds a prefix key waits before the which-key panel shows."
  'group 'appearance
  'set (lambda (seconds)
         (set-face-attribute! 'ui 'which-key-delay (which-key-delay-css seconds))))

(set-face-attribute! 'ui 'which-key-delay (which-key-delay-css which-key-idle-delay))

;; Motion is a setting, not a constant. Every duration the page animates
;; over reads --chrome-anim, which is the 'chrome face's anim attribute:
;; FaceCSS publishes every face attribute as a :root variable, so one
;; Scheme value moves them all. Zero is off, and off is the default: a
;; zero-length transition lands its element at the new value in the same
;; frame, and a zero-length animation draws the unanimated state.
(define (animation-css on) (if on "140ms" "0ms"))

(defcustom 'ui-animation #f
  "Whether editor chrome moves: panes resizing, spinners, the caret blink."
  'group 'appearance 'type 'boolean
  'set (lambda (on)
         (set-face-attribute! 'chrome 'anim (animation-css on))))

;; A theme load clears every face attribute it is about to set, and this
;; one is set by hand rather than from *face-defaults*, so it was cleared
;; and never restored: --chrome-anim went missing and every
;; var(--chrome-anim, DURATION) fell back to its duration. Motion came
;; back on with the theme, whatever the setting said. Re-apply it after a
;; theme, and keep every fallback in the stylesheets at zero, so a
;; missing variable can only ever mean no motion.
(define (appearance--anim-apply!)
  (set-face-attribute! 'chrome 'anim (animation-css ui-animation)))
(add-hook! 'theme-change-hook 'appearance--anim-apply!)
(appearance--anim-apply!)

;; The motion of the desk: a split, a delete, a swap, a buffer that takes
;; a window, a strip scroll and a group switch move on screen, so the
;; user sees what went where (window-motion.js, strip-slide.js). It reads
;; --chrome-motion, the 'chrome face's motion attribute. It is apart from
;; ui-animation: that one is the decoration, this one is the map. Zero is
;; off, and the system's reduced-motion setting turns it off too.
(define (motion-css ms) (string-append (number->string ms) "ms"))

(defcustom 'window-motion-duration 180
  "Milliseconds a window, a buffer or a group takes to move to its new place. 0 turns the motion off."
  'group 'appearance 'type 'integer
  'set (lambda (ms)
         (set-face-attribute! 'chrome 'motion (motion-css ms))))

(define (appearance--motion-apply!)
  (set-face-attribute! 'chrome 'motion (motion-css window-motion-duration)))
(add-hook! 'theme-change-hook 'appearance--motion-apply!)
(appearance--motion-apply!)

;; The size of buffer text is the default face's size. 13px was the
;; design size and 20.8px was the reading size, which was too large: every
;; buffer that wanted to be read carried a negative text-scale to undo it.
;; 14px is the size chosen by measuring the rendered page. A defface!
;; default survives a theme load, because no theme names a size on the
;; default face.
(defcustom 'default-font-size "14px"
  "The size of buffer text: the default face's size, as CSS."
  'group 'appearance
  'set (lambda (size) (defface! 'default 'size size)))

(defface! 'default 'size default-font-size)

;; The application has three font slots: mono, sans, and serif. Each slot
;; is the family attribute of a face, and the page reads that face
;; variable as the fallback of --font-mono, --font-sans and --font-serif.
;; An empty value writes no variable, so the page keeps its own stack.
;; Buffer text follows the mono slot, because the default face names no
;; family of its own.
(defcustom 'mono-font-family ""
  "The monospace font of the application, as a CSS font stack. Empty means the built-in stack."
  'group 'appearance
  'set (lambda (stack) (defface! 'mono 'family stack)))

(defcustom 'sans-font-family ""
  "The sans-serif font of the application, as a CSS font stack. Empty means the built-in stack."
  'group 'appearance
  'set (lambda (stack) (defface! 'sans 'family stack)))

(defcustom 'serif-font-family ""
  "The serif font of the application, as a CSS font stack. Empty means the built-in stack."
  'group 'appearance
  'set (lambda (stack) (defface! 'serif 'family stack)))

;; the face must say the saved value again on load and after a restart
(defface! 'mono 'family mono-font-family)
(defface! 'sans 'family sans-font-family)
(defface! 'serif 'family serif-font-family)

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
(public! 'text-scale-reset-all!
  "(text-scale-reset-all!) — give every buffer the normal text size; answer how many changed")
(public! 'ui-scale-apply!
  "(ui-scale-apply! N) — set the whole application's text scale to step N; 0 is normal")

;;; --- the frame chrome ---------------------------------------------------------
;;; Scheme composes the chrome that every frame draws, and publishes each
;;; value with frame-chrome-set!. The view draws what it gets and fills in
;;; only what it alone knows: the line, the column, the size, the scroll
;;; position. A setting set later publishes again.

(domain! 'ui)
(effects! '(write))

(define (chrome-publisher key)
  (lambda (value) (frame-chrome-set! key value)))

(defcustom 'echo-key-hints
  '(("C-x C-f" "") ("C-x b" "") ("C-x d" "") ("C-c a" "agent") ("M-x" "") ("C-g" ""))
  "The key hints in the echo area, as (KEY VERB) pairs. An empty verb draws the key alone."
  'group 'appearance
  'set (chrome-publisher "echo-hints"))

;; Emacs's mode-line-format, as constructs in order. (position SEGS
;; PTY-SEGS) draws (CLASS TEXT) segments, the PTY ones in a terminal; the
;; view fills %I (size), %l (line), %c (column), %p (Top, Bot, All, N%).
;; (text CLASS TEXT) draws literal text. A buffer-local mode-line-format
;; overrides this one for its buffer.
(defcustom 'mode-line-format
  '(("dot") ("project") ("selected" "● selected") ("preview" "preview") ("info") ("facts")
    ("spacer")
    ("position" (("ml-pos-size" "%I · ") ("" "L%l:C%c") ("ml-pos-pct" " · %p"))
                (("" "PTY · ") ("ml-pos-size" "transcript %I"))))
  "The window mode line, as a list of constructs: dot, project, selected, preview, info, facts, spacer, position, text."
  'group 'appearance
  'set (chrome-publisher "mode-line-format"))

(define workspace-bar-help "M-x workspaces new tab · C-x d switch daemon")
(define frame-tabs-more-title "every group (C-x C-g l)")

(frame-chrome-set! "echo-hints" echo-key-hints)
(frame-chrome-set! "mode-line-format" mode-line-format)
(frame-chrome-set! "workspace-help" workspace-bar-help)
(frame-chrome-set! "tabs-more-title" frame-tabs-more-title)

(domain! 'unknown)
(effects! '(unknown))
