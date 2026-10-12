;;; show-keys.scm --- cast the keys you press, large, for the people who watch.
;;;
;;; show-keys-mode is global. After each command, a stack of large keys
;;; shows in the top right corner of every frame, the newest at the
;;; bottom, with Mac symbols for the modifiers. A key that repeats shows a
;;; count, typed text joins into one entry, and the stack leaves after
;;; show-keys-seconds without a key. The page draws the stack from the
;;; show-keys chrome value, a pending prefix (C-x) after it, and the
;;; labels from show-keys-labels; this file ships its CSS.

(namespace! 'show-keys)
(domain! 'interaction)
(effects! '(write display))

(defgroup 'show-keys "Cast the keys you press, large, for screencasts.")

(defcustom 'show-keys-mode #f
  "Show the keys you press, large, in the top right corner of the frame."
  'group 'show-keys 'type 'boolean)

(defcustom 'show-keys-count 3
  "How many keys the stack shows."
  'group 'show-keys)

(defcustom 'show-keys-seconds 2
  "How many seconds without a key before the stack leaves."
  'group 'show-keys)

(defcustom 'show-keys-modifiers-only #t
  "Show only the keys that hold a modifier: C-, M-, s-, H-, A- or S-."
  'group 'show-keys 'type 'boolean)

(defcustom 'show-keys-labels
  '(("C-" "⌃") ("M-" "⌥") ("S-" "⇧") ("s-" "⌘") ("H-" "✦") ("A-" "⌥")
    ("RET" "⏎") ("SPC" "␣") ("TAB" "⇥") ("DEL" "⌫") ("ESC" "⎋")
    ("<backtab>" "⇤") ("<delete>" "⌦") ("<return>" "⏎") ("<tab>" "⇥")
    ("<left>" "←") ("<right>" "→") ("<up>" "↑") ("<down>" "↓")
    ("<home>" "↖") ("<end>" "↘") ("<prior>" "⇞") ("<next>" "⇟"))
  "How the stack draws each modifier and named key, as (KEY LABEL) pairs. A KEY that ends in - is a modifier."
  'group 'show-keys)

(define-style! "show-keys" "
.keycast { position: fixed; top: 3.5rem; right: 1.5rem;
  z-index: 60; display: flex; flex-direction: column; align-items: flex-end; gap: 0.5em;
  pointer-events: none; }
.keycast-entry { display: flex; align-items: baseline; gap: 0.6em; padding: 0.35em 0.8em;
  border-radius: 0.5em; background: #111114; color: #fff; border: 1px solid #3a3a42;
  box-shadow: 0 0.3em 1.2em rgba(0, 0, 0, 0.45); opacity: 0.8; font-size: 1.6rem; }
.keycast-entry:last-child { opacity: 1; font-size: 2.6rem; }
.keycast .keycast-keys { color: #fff; font-family: var(--font-mono, monospace); font-weight: 700; white-space: pre; }
.keycast-pending { border-color: #ffd166; }
.keycast .keycast-count { font-size: 0.55em; font-weight: 700; color: #ffd166; }
")

;; ((KEYS COMMAND COUNT) ...), newest first; COMMAND only tells a repeat
(define show-keys--ring '())

(define (show-keys--modified? keys)
  "#t when one chord of KEYS, a list of key strings, holds a modifier"
  (pair? (filter (lambda (k)
         (and (>= (string-length k) 2)
              (equal? (substring k 1 2) "-")
              (member (substring k 0 1) '("C" "M" "s" "H" "A" "S"))))
       keys)))

(define (show-keys--typed? cmd) (equal? cmd "self-insert-command"))

(define (show-keys--typed-text keys)
  (if (equal? keys "SPC") " " keys))

(define (show-keys--record! keys cmd)
  "put KEYS and the COMMAND they ran first in the ring"
  (let ((top (and (pair? show-keys--ring) (car show-keys--ring))))
    (set! show-keys--ring
      (cond ((and top (show-keys--typed? cmd) (show-keys--typed? (cadr top)))
             (cons (list (string-append (car top) (show-keys--typed-text keys)) cmd 1)
                   (cdr show-keys--ring)))
            ((and top (equal? (car top) keys) (equal? (cadr top) cmd))
             (cons (list keys cmd (+ 1 (caddr top))) (cdr show-keys--ring)))
            (else
             (take (cons (list (if (show-keys--typed? cmd) (show-keys--typed-text keys) keys) cmd 1)
                         show-keys--ring)
                   (max 1 show-keys-count)))))))

(define (show-keys--row e)
  "(KEYS COUNT KIND) as the three strings the page draws; KIND text is typed text"
  (let ((keys (car e)) (cmd (cadr e)) (n (caddr e)))
    (list (if (show-keys--typed? cmd) (string-append "\"" keys "\"") keys)
          (if (> n 1) (string-append "x" (number->string n)) "")
          (if (show-keys--typed? cmd) "text" "keys"))))


(define (show-keys-rows)
  "the rows the stack shows now, oldest first"
  (map show-keys--row (reverse show-keys--ring)))

(public! 'show-keys-rows "(show-keys-rows) — the (KEYS COUNT KIND) rows show-keys-mode casts now, oldest first")

(define (show-keys--draw!)
  ;; show-keys-on lets the page draw a pending prefix, such as C-x, which
  ;; runs no command and so never reaches the post-command hook
  (frame-chrome-set! "show-keys-on"
    (cond ((not show-keys-mode) #f) (show-keys-modifiers-only "modifiers") (else "all")))
  (frame-chrome-set! "show-keys-labels" show-keys-labels)
  (frame-chrome-set! "show-keys" (if show-keys-mode (show-keys-rows) '())))

(define (show-keys--clear! _)
  (set! show-keys--ring '())
  (show-keys--draw!))

(define (show-keys--post-command! &optional cmd)
  (when show-keys-mode
    (let ((keys (last-keys)) (cmd (or cmd (last-command))))
      (when (and (pair? keys) cmd
                 (or (not show-keys-modifiers-only) (show-keys--modified? keys)))
        (show-keys--record! (string-join keys " ") cmd)
        (show-keys--draw!)
        (debounce! 'show-keys (* 1000 (max 1 show-keys-seconds)) show-keys--clear! #f)))))

(add-hook! 'post-command-hook 'show-keys--post-command! #t)

(define-command "show-keys-mode" "Toggle the large keys you press, for screencasts"
  (lambda ()
    (customize-set! 'show-keys-mode (not show-keys-mode))
    (show-keys--clear! #f)
    (message (if show-keys-mode "show-keys-mode on" "show-keys-mode off"))))
