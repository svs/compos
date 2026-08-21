;;; morg-babel.scm --- execute Morg fenced code blocks.
;;;
;;; C-c C-c runs the block at point. Output goes to a result fence below
;;; the source block. A later run replaces that result fence.

(define morg-babel-parent-package *loading-package*)
(define morg-babel-parent-namespace *loading-namespace*)
(define morg-babel-parent-domain *catalog-domain*)
(define morg-babel-parent-effects *catalog-effects*)

(package! 'morg-babel 'morg)
(domain! 'writing)
(effects! '(write execute))

;; Markdown language -> the interpreter that runs the temporary file.
(define *morg-babel-runners*
  '(("sh" "sh") ("bash" "bash") ("zsh" "zsh") ("shell" "sh")
    ("python" "python3") ("py" "python3")
    ("elixir" "elixir") ("exs" "elixir")
    ("js" "node") ("javascript" "node") ("node" "node")
    ("ruby" "ruby")))

;; Run BODY through RUNNER. The shell folds stderr into the returned text.
(define (morg-babel-run-shell runner body)
  (shell-command->string
    (string-append
      "t=$(mktemp); cat >\"$t\" <<'MORG_EOF'\n"
      body
      (if (string-suffix? "\n" body) "" "\n")
      "MORG_EOF\n"
      runner " \"$t\"; rm -f \"$t\"")))

;; Return output, or #f when LANG has no runner.
(define (morg-babel-run lang body)
  (if (equal? (string-downcase lang) "scheme")
      (value->string (eval-string body))
      (let ((r (assoc (string-downcase lang) *morg-babel-runners*)))
        (if r (morg-babel-run-shell (cadr r) body) #f))))

;; Return the result block after CLOSE-END, or #f.
(define (morg-babel-result-block scan buf close-end)
  (let loop ((es scan))
    (cond ((null? es) #f)
          ((<= (car (car es)) close-end) (loop (cdr es)))
          (else
            (let* ((e (car es)) (k (morg-kind e)))
              (cond ((and (equal? k 'text) (equal? (string-trim (cadr e)) ""))
                     (loop (cdr es)))
                    ((and (equal? k 'open) (equal? (morg-info e) "result"))
                     (list (car e) (morg-block-close-end scan buf (car e))))
                    (else #f)))))))

(define (morg-babel-insert-result! buf scan fstart out)
  (let* ((close-end (morg-block-close-end scan buf fstart))
         (existing (morg-babel-result-block scan buf close-end))
         (norm (if (or (equal? out "") (string-suffix? "\n" out))
                   out
                   (string-append out "\n")))
         (res (string-append "```result\n" norm "```\n")))
    (if existing
        (let* ((rs (car existing))
               (re (min (buffer-size buf) (+ (cadr existing) 1))))
          (buffer-delete-range! buf rs (- re rs))
          (buffer-insert! buf rs res))
        (let* ((size (buffer-size buf))
               (at (min (+ close-end 1) size)))
          (buffer-insert! buf at
            (string-append (if (>= close-end size) "\n" "") res))))))

(define (morg-babel-execute buf pos)
  (let* ((scan (morg-scan buf))
         (a (morg-block-open scan pos)))
    (if (not a)
        (list 'error "Point is not in a code block")
        (let* ((e (morg-entry-at scan a))
               (lang (morg-info e)))
          (cond
            ((equal? lang "result") (list 'error "A result block does not run"))
            ((equal? lang "") (list 'error "The block names no language"))
            (else
              (let* ((body-r (morg-block-body scan buf a))
                     (body (substring-bytes (buffer-text buf)
                                            (car body-r) (cadr body-r)))
                     (out (morg-babel-run lang body)))
                (if (not out)
                    (list 'error (string-append "No runner for " lang))
                    (begin
                      (morg-babel-insert-result! buf scan a out)
                      (list 'ok lang))))))))))

(define-command "morg-babel" "Run the Morg code block at point and replace its result block"
  (lambda ()
    (let ((r (morg-babel-execute (current-buffer) (point))))
      (message
        (if (equal? (car r) 'ok)
            (string-append "Executed " (cadr r) " block")
            (cadr r))))))

;; Keep the old command name for init files and restored keymaps.
(define-command "morg-execute-block" "Run the Morg code block at point"
  (lambda () (run-command "morg-babel")))

(public! 'morg-babel-execute
  "(morg-babel-execute BUF POS) — run the Morg block at POS and update its result fence")

;; Do not leak this extension's catalog context into the next package.
(package! morg-babel-parent-package morg-babel-parent-namespace)
(domain! morg-babel-parent-domain)
(effects! morg-babel-parent-effects)
