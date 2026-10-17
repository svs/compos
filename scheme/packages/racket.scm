;;; racket.scm --- Racket files, a Racket REPL, and DrRacket.
;;;
;;; racket-mode reads .rkt files with the scheme grammar. The REPL is a
;;; racket process in *racket*, line-oriented like comint-shell-mode.
;;;
;;;   C-c C-c, F5  racket-run — like DrRacket's Run: a fresh REPL inside
;;;                the file's module, so its definitions are at hand
;;;   C-c C-z      racket-repl — the REPL, started when there is none
;;;   C-c C-e      racket-send-definition — the definition at point
;;;   C-c C-r      racket-send-region
;;;   C-c C-o      drracket — open this file in DrRacket
;;;
;;; Loaded from init.scm.

(require 'comint)
(require 'treesit)

(domain! 'code)
(effects! '(write execute))

;; The racket binary; override in init.scm when it is not on PATH.
(define *racket-command* "racket")
(define *racket-repl-buffer* "*racket*")

(define-derived-mode "racket-mode" "prog-mode" (ts-mode "scheme"))

(mode-doc! "racket-mode"
  "Racket. `C-c C-c` or `F5` runs the file the way DrRacket's Run does: a fresh REPL in `*racket*`, inside the module, with its definitions at hand. `C-c C-z` goes to the REPL, `C-c C-e` sends the definition at point and `C-c C-r` the region. `C-c C-o` opens the file in DrRacket. HtDP files saved by DrRacket in a teaching language run too.")

(set! *auto-mode-alist*
  (append *auto-mode-alist*
          '((".rkt" "racket-mode") (".rktl" "racket-mode") (".rktd" "racket-mode"))))

(effects! '(pure))

(define (racket--repl-command path)
  "the shell command for a racket REPL, inside the module at PATH when it is a string"
  (if (string? path)
      (string-append "exec " *racket-command* " -i -e "
                     (sh-quote (string-append "(enter! (file \"" path "\"))")))
      (string-append "exec " *racket-command* " -i")))

(effects! '(write execute))

(define-mode "racket-repl-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (process-running? buf)
        (start-process! buf (racket--repl-command #f))))))

(mode-doc! "racket-repl-mode"
  "A racket REPL. `RET` sends the text after the prompt. `C-c C-z` in a Racket file comes here.")

(define (racket--repl! path)
  "*racket*, running racket inside PATH's module, or bare when PATH is #f"
  (let ((buf *racket-repl-buffer*))
    (when (process-running? buf) (process-kill! buf))
    (start-process! buf (racket--repl-command path))
    (buffer-set-local! buf 'mode-name "racket-repl-mode")
    buf))

(define (racket--repl-buffer)
  "*racket*, with a racket running in it"
  (if (process-running? *racket-repl-buffer*)
      *racket-repl-buffer*
      (racket--repl! #f)))

(define (racket--send! text)
  (let ((buf (racket--repl-buffer)))
    (process-send! buf (string-append (string-trim text) "\n"))
    (display-buffer-other-window! buf)))

(define-command "racket-run" "Run this Racket file in a fresh REPL, like DrRacket's Run"
  (lambda ()
    (let ((path (buffer-path (current-buffer))))
      (if (not path)
          (message "racket-run: this buffer has no file")
          (begin
            (when (buffer-modified? (current-buffer)) (buffer-save!))
            (display-buffer-other-window! (racket--repl! path)))))))

(define-command "racket-repl" "Go to the Racket REPL, starting one when there is none"
  (lambda ()
    (pop-to-buffer (racket--repl-buffer))
    (end-of-buffer!)))

(define-command "racket-send-definition" "Send the definition at point to the Racket REPL"
  (lambda ()
    (let* ((here (current-buffer))
           (src (code-read here (car (buffer-line-at-point here)))))
      (if (and (string? src) (not (equal? (string-trim src) "")))
          (racket--send! src)
          (message "No definition at point")))))

(define-command "racket-send-region" "Send the region to the Racket REPL"
  (lambda ()
    (let ((text (and (mark) (region-text))))
      (if (and (string? text) (not (equal? (string-trim text) "")))
          (racket--send! text)
          (message "No region")))))

(effects! '(write external execute))

(define-command "drracket" "Open this file in DrRacket"
  (lambda ()
    (let ((path (buffer-path (current-buffer))))
      (if (not path)
          (message "drracket: this buffer has no file")
          (let ((out (shell-command->string
                      (string-append "open -a DrRacket " (sh-quote path)
                                     " 2>/dev/null || (drracket " (sh-quote path) " >/dev/null 2>&1 &)")
                      (default-directory))))
            (message (if (equal? (string-trim out) "")
                         (string-append "DrRacket: " path)
                         (string-trim out))))))))

(mode-keys! "racket-mode"
  '(("C-c C-c" "racket-run")
    ("<f5>" "racket-run")
    ("C-c C-z" "racket-repl")
    ("C-c C-e" "racket-send-definition")
    ("C-c C-r" "racket-send-region")
    ("C-c C-o" "drracket")))

(category! 'code)
(effects! '(pure))
(public! 'racket--repl-command
  "(racket--repl-command PATH) — the shell command for a racket REPL inside PATH's module, or bare when PATH is #f")
