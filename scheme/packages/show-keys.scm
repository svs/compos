;;; show-keys.scm --- show the keys you press, for the people who watch.
;;;
;;; show-keys-mode is global. After each command, the right of the frame
;;; modeline shows the last few keys and the command each one ran, newest
;;; first. A command that repeats shows a count, and typed text joins into
;;; one entry.

(namespace! 'show-keys)
(domain! 'interaction)
(effects! '(write display))

(defgroup 'show-keys "Show the keys you press in the frame modeline.")

(defcustom 'show-keys-mode #f
  "Show the keys you press, and their commands, at the right of the frame modeline."
  'group 'show-keys 'type 'boolean)

(defcustom 'show-keys-count 4
  "How many keys the modeline shows."
  'group 'show-keys)

(defcustom 'show-keys-command-names #t
  "Show the command name after each key."
  'group 'show-keys 'type 'boolean)

;; ((KEYS COMMAND COUNT) ...), newest first
(define show-keys--ring '())

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

(define (show-keys--entry-text e)
  (let ((keys (car e)) (cmd (cadr e)) (n (caddr e)))
    (string-append
      (if (show-keys--typed? cmd) (string-append "\"" keys "\"") keys)
      (if (and show-keys-command-names (not (show-keys--typed? cmd)) cmd)
          (string-append " " cmd)
          "")
      (if (> n 1) (string-append " x" (number->string n)) ""))))

(define (show-keys-text)
  "the keys the modeline shows now, newest first"
  (string-join (map show-keys--entry-text show-keys--ring) "  ·  "))

(public! 'show-keys-text "(show-keys-text) — the keys show-keys-mode shows now, newest first")

(define (show-keys--draw!)
  (if (and show-keys-mode (pair? show-keys--ring))
      (global-mode-string-set! 'show-keys (list "ml-segment ml-strong" (show-keys-text)))
      (global-mode-string-remove! 'show-keys)))

(define (show-keys--post-command! &optional cmd)
  (when show-keys-mode
    (let ((keys (last-keys)) (cmd (or cmd (last-command))))
      (when (and (pair? keys) cmd)
        (show-keys--record! (string-join keys " ") cmd)
        (show-keys--draw!)))))

(add-hook! 'post-command-hook 'show-keys--post-command! #t)

(define-command "show-keys-mode" "Toggle the keys you press in the frame modeline, for screencasts"
  (lambda ()
    (customize-set! 'show-keys-mode (not show-keys-mode))
    (set! show-keys--ring '())
    (show-keys--draw!)
    (message (if show-keys-mode "show-keys-mode on" "show-keys-mode off"))))
