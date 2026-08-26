;;; morg-babel.scm --- execute Morg fenced code blocks.
;;;
;;; C-c C-c runs the block at point. Output goes to a result fence below
;;; the source block. A later run replaces that result fence.
;;;
;;; A shell block runs off the editor lane. Its result fence says
;;; `running` while the command works, and the output replaces that word
;;; when the command ends. You keep typing, and you can start more blocks
;;; while the first one runs. Add `:sync` after the language to hold the
;;; editor until the block ends. A `scheme` block is always synchronous,
;;; because it runs in the editor's own interpreter.
;;;
;;; The document can change while a block runs, so the block's place is
;;; not its byte offset. morg-babel-relocate finds the block again by its
;;; language and its body.

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

;; What a result fence holds while its command runs.
(define morg-babel-running-text "running")

(define (morg-babel-runner lang)
  (let ((r (assoc (string-downcase lang) *morg-babel-runners*)))
    (and r (cadr r))))

;; BODY as one shell command. The shell folds stderr into the output.
(define (morg-babel-script runner body)
  (string-append
    "t=$(mktemp); cat >\"$t\" <<'MORG_EOF'\n"
    body
    (if (string-suffix? "\n" body) "" "\n")
    "MORG_EOF\n"
    runner " \"$t\"; rm -f \"$t\""))

(define (morg-babel-run-shell runner body)
  (shell-command->string (morg-babel-script runner body)))

;; The seam every asynchronous block runs through. K receives the output.
;; A test replaces this to answer without a shell.
(define (morg-babel-shell-async runner body k)
  (shell-command->string (morg-babel-script runner body) k))

(define *morg-babel-shell* morg-babel-shell-async)

;;; --- what is running now -----------------------------------------------------
;;; Runtime state: the (lang body) pairs this buffer runs at this moment.
;;; It is meaningless after a restart, so the desktop must not save it.

(define (morg-babel-inflight buf)
  (or (buffer-local buf 'morg-babel-inflight) '()))

(define (morg-babel-inflight! buf rows)
  (desktop-skip! buf 'morg-babel-inflight)
  (buffer-set-local! buf 'morg-babel-inflight rows))

(define (morg-babel-claim! buf key)
  (morg-babel-inflight! buf (cons key (morg-babel-inflight buf))))

(define (morg-babel-release! buf key)
  (morg-babel-inflight! buf
    (filter (lambda (row) (not (equal? row key)))
            (morg-babel-inflight buf))))

;;; --- finding the block again -------------------------------------------------

;; the block's position among every block in BUF, in document order
(define (morg-babel-index scan buf fstart)
  (let loop ((bs (morg-blocks scan buf)) (i 0))
    (cond ((null? bs) 0)
          ((= (car (car bs)) fstart) i)
          (else (loop (cdr bs) (+ i 1))))))

;; The open-fence start of the block that ran, or #f when the block is
;; gone. Identity is the language and the body. The ordinal breaks a tie
;; between two blocks that hold the same text.
(define (morg-babel-relocate buf idx lang body)
  (let* ((scan (morg-scan buf))
         (blocks (morg-blocks scan buf))
         (text (buffer-text buf))
         (same?
           (lambda (b)
             (and (equal? (nth 1 b) lang)
                  (equal? (substring-bytes text (nth 2 b) (nth 3 b)) body)))))
    (let loop ((bs blocks) (i 0) (best #f) (bestd #f))
      (cond ((null? bs) best)
            ((same? (car bs))
             (let ((d (abs (- i idx))))
               (if (or (not bestd) (< d bestd))
                   (loop (cdr bs) (+ i 1) (car (car bs)) d)
                   (loop (cdr bs) (+ i 1) best bestd))))
            (else (loop (cdr bs) (+ i 1) best bestd))))))

;;; --- the result fence --------------------------------------------------------

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

;; The scan is read here, not passed in: a result written when a command
;; ends describes a document that moved since the command started.
(define (morg-babel-insert-result! buf fstart out)
  (let* ((scan (morg-scan buf))
         (close-end (morg-block-close-end scan buf fstart))
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

;;; --- running -----------------------------------------------------------------

;; `:sync` after the language holds the editor until the block ends.
(define (morg-babel-sync? entry)
  (re-match ":[Ss][Yy][Nn][Cc]([ \t]|$)" (cadr entry)))

;; The command ended. Release the claim, find the block, write the result.
(define (morg-babel-finish! buf idx lang body out)
  (morg-babel-release! buf (list lang body))
  (if (not (buffer-exists? buf))
      (message (string-append "The " lang " block's buffer is gone: " out))
      (let ((fstart (morg-babel-relocate buf idx lang body)))
        (if fstart
            (begin
              (morg-babel-insert-result! buf fstart out)
              (message (string-append "Executed " lang " block")))
            (message (string-append "The " lang " block is gone: " out))))))

(define (morg-babel-start! buf scan fstart lang body)
  (let ((idx (morg-babel-index scan buf fstart))
        (key (list lang body))
        (runner (morg-babel-runner lang)))
    (morg-babel-claim! buf key)
    (morg-babel-insert-result! buf fstart morg-babel-running-text)
    (*morg-babel-shell* runner body
      (lambda (out) (morg-babel-finish! buf idx lang body out)))
    (list 'pending lang)))

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
                                            (car body-r) (cadr body-r))))
                (cond
                  ((equal? (string-downcase lang) "scheme")
                   (morg-babel-insert-result! buf a
                     (value->string (eval-string body)))
                   (list 'ok lang))
                  ((not (morg-babel-runner lang))
                   (list 'error (string-append "No runner for " lang)))
                  ((morg-babel-sync? e)
                   (morg-babel-insert-result! buf a
                     (morg-babel-run-shell (morg-babel-runner lang) body))
                   (list 'ok lang))
                  ((member (list lang body) (morg-babel-inflight buf))
                   (list 'error (string-append "The " lang " block already runs")))
                  (else (morg-babel-start! buf scan a lang body))))))))))

(define-command "morg-babel" "Run the Morg code block at point and replace its result block"
  (lambda ()
    (let ((r (morg-babel-execute (current-buffer) (point))))
      (message
        (cond ((equal? (car r) 'ok)
               (string-append "Executed " (cadr r) " block"))
              ((equal? (car r) 'pending)
               (string-append "Running " (cadr r) " block"))
              (else (cadr r)))))))

;; Keep the old command name for init files and restored keymaps.
(define-command "morg-execute-block" "Run the Morg code block at point"
  (lambda () (run-command "morg-babel")))

(public! 'morg-babel-execute
  "(morg-babel-execute BUF POS) — run the Morg block at POS and update its result fence; a shell block runs off the lane and returns (pending LANG)")

;; Do not leak this extension's catalog context into the next package.
(package! morg-babel-parent-package morg-babel-parent-namespace)
(domain! morg-babel-parent-domain)
(effects! morg-babel-parent-effects)
