;;; run-block.scm --- execute a fenced block, off the editor lane.
;;;
;;; C-c C-c runs the block at point. Output goes to a result fence below
;;; the source block. A later run replaces that result fence.
;;;
;;; A shell block runs off the editor lane. Its result fence says
;;; `running` while the command works, and the output replaces that word
;;; when the command ends. You keep typing, and you can start more blocks
;;; while the first one runs. Add `:sync` after the language to hold the
;;; editor until the block ends. A Scheme block also runs off the editor
;;; lane. Add `:sync` when it must run on the calling lane.
;;;
;;; The document can change while a block runs, so the block's place is
;;; not its byte offset. A tracking overlay (block.scm) follows the rope,
;;; and the result lands where it says.

(define morg-babel-parent-package *loading-package*)
(define morg-babel-parent-namespace *loading-namespace*)
(define morg-babel-parent-domain *catalog-domain*)
(define morg-babel-parent-effects *catalog-effects*)

(package! 'morg-babel 'morg)
(domain! 'writing)
(effects! '(write execute))

(defcustom 'morg-babel-csv-preview-lines 5
  "The default number of CSV lines that morg-babel previews."
  'group 'writing 'type 'number)

(defcustom 'morg-babel-scheme-result-width 88
  "The maximum line width for a Scheme Babel result when a list can wrap."
  'group 'writing 'type 'number)

;; Markdown language -> the interpreter that runs the temporary file, and
;; the tree-sitter language that paints the body. Each row becomes one
;; fence-kind registration below.
(define *morg-babel-runners*
  '(("sh" "sh" "bash") ("bash" "bash" "bash") ("zsh" "zsh" "bash")
    ("shell" "sh" "bash")
    ("python" "python3" "python") ("py" "python3" "python")
    ("elixir" "elixir" "elixir") ("exs" "elixir" "elixir")
    ("js" "node" "javascript") ("javascript" "node" "javascript")
    ("node" "node" "javascript")
    ("ruby" "ruby" "ruby")))

;; What a result fence holds while its command runs.
(define morg-babel-running-text "running")

(define (morg-babel-runner lang)
  (fence-kind-get lang 'interpreter #f))

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

(define (morg-babel-output value)
  (if (string? value) value (value->string value)))

;; A property list is the common result shape for discovery APIs. Keep each
;; key beside its value when the value must wrap across lines.
(define (morg-babel-scheme-plist? value)
  (and (pair? value)
       (= (modulo (length value) 2) 0)
       (let loop ((xs value))
         (or (null? xs)
             (and (symbol? (car xs))
                  (loop (cdr (cdr xs))))))))

(define (morg-babel-scheme-pretty-plist value indent)
  (let ((child (+ indent 1)))
    (string-append
      "("
      (let loop ((xs value) (first #t) (out ""))
        (if (null? xs)
            out
            (let* ((key (symbol->string (car xs)))
                   (rendered
                     (string-append
                       key " "
                       (morg-babel-scheme-pretty
                         (cadr xs) (+ child (string-length key) 1))))
                   (prefix (if first ""
                               (string-append "\n" (string-repeat " " child)))))
              (loop (cdr (cdr xs)) #f
                    (string-append out prefix rendered)))))
      ")")))

(define (morg-babel-scheme-pretty-list value indent)
  (let ((child (+ indent 1)))
    (string-append
      "("
      (let loop ((xs value) (first #t) (out ""))
        (if (null? xs)
            out
            (let ((prefix (if first ""
                              (string-append "\n" (string-repeat " " child)))))
              (loop (cdr xs) #f
                    (string-append
                      out prefix
                      (morg-babel-scheme-pretty (car xs) child))))))
      ")")))

(define (morg-babel-scheme-pretty value &optional indent)
  (let* ((at (or indent 0))
         (plain (value->string value)))
    (if (or (not (pair? value))
            (null? value)
            (<= (+ at (string-length plain)) morg-babel-scheme-result-width))
        plain
        (if (morg-babel-scheme-plist? value)
            (morg-babel-scheme-pretty-plist value at)
            (morg-babel-scheme-pretty-list value at)))))

;; The seam every asynchronous block runs through. K receives the output.
;; A test replaces this to answer without a shell.
(define (morg-babel-shell-async runner body k)
  (shell-command->string (morg-babel-script runner body) k))

(define *morg-babel-shell* morg-babel-shell-async)

;; Scheme evaluation uses a shared-world task. K gets the task status and
;; the (ok VALUE) or (error MESSAGE) result from eval-string-safe.
(define (morg-babel-scheme-async body k)
  (task-run! (lambda () (eval-string-safe body)) k))

;; A test replaces this to control when a Scheme task answers.
(define *morg-babel-scheme* morg-babel-scheme-async)

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

;;; --- running -----------------------------------------------------------------

;; `:sync` after the language holds the editor until the block ends.
(define (morg-babel-sync? info)
  (re-match ":[Ss][Yy][Nn][Cc]([ \t]|$)" info))

(define (morg-babel-csv-limit info)
  (let ((g (re-groups ":[Ll][Ii][Nn][Ee][Ss][ \t]+([0-9]+)" info 0)))
    (if g
        (let* ((r (nth 1 g))
               (n (string->number (substring-bytes info (car r) (cadr r)))))
          (if (and n (> n 0)) n morg-babel-csv-preview-lines))
        morg-babel-csv-preview-lines)))

(define (morg-babel-csv-first-lines text n)
  (let loop ((lines (split-lines text)) (left n) (out '()))
    (if (or (= left 0) (null? lines))
        (string-join (reverse out) "\n")
        (loop (cdr lines) (- left 1) (cons (car lines) out)))))

(define (morg-babel-csv-source buf info body)
  ;; morg-tangle-target reads an entry's line; the info string is that line
  ;; without its backticks, which the regex never needed
  (let ((target (morg-tangle-target (list 0 info))))
    (if target
        (let ((path (morg-tangle-path buf target)))
          (if (file-exists? path) (read-file path) body))
        body)))

(define (morg-babel-preview-csv! buf b body)
  (result-block-insert! buf (nth 0 b)
    (morg-babel-csv-first-lines
      (morg-babel-csv-source buf (nth 2 b) body)
      (morg-babel-csv-limit (nth 2 b)))
    "result-csv"))

;;; --- finding the block again -------------------------------------------------
;;; The document can change while a block runs, so the block's place is
;;; not its byte offset. A tracking overlay from block.scm follows the
;;; rope through every edit, and the result lands where it says.

(define *morg-babel-track-n* 0)

;; the live tracks, read back from the overlays so every range carries
;; the rope's own adjustment — never a remembered offset
(define (morg-babel--track-ranges buf)
  (filter (lambda (o) (string-prefix? "run-block:" (caddr o)))
          (buffer-overlays buf)))

(define (morg-babel-track! buf b)
  (set! *morg-babel-track-n* (+ *morg-babel-track-n* 1))
  (let ((id (string-append "run-block:" (number->string *morg-babel-track-n*))))
    (overlay-set! buf 'run-block
      (cons (list (nth 0 b) (nth 1 b) id) (morg-babel--track-ranges buf)))
    id))

(define (morg-babel-untrack! buf id)
  (overlay-set! buf 'run-block
    (filter (lambda (r) (not (equal? (caddr r) id)))
            (morg-babel--track-ranges buf))))

;; the tracked block's open-fence start right now, or #f when it is gone
(define (morg-babel-locate buf id)
  (let ((span (block-overlay-span buf id)))
    (and span (car span))))

;; The command ended. Release the claim, find the block, write the result.
(define (morg-babel-finish! buf id lang body out &optional result-lang)
  (morg-babel-release! buf (list lang body))
  (if (not (buffer-exists? buf))
      (message (string-append "The " lang " block's buffer is gone: " out))
      (let ((fstart (morg-babel-locate buf id)))
        (morg-babel-untrack! buf id)
        (if fstart
            (begin
              (result-block-insert! buf fstart out result-lang)
              (message (string-append "Executed " lang " block")))
            (message (string-append "The " lang " block is gone: " out))))))

(define (morg-babel-start! buf b lang body)
  (let ((id (morg-babel-track! buf b))
        (key (list lang body))
        (runner (morg-babel-runner lang)))
    (morg-babel-claim! buf key)
    (result-block-insert! buf (nth 0 b) morg-babel-running-text)
    (*morg-babel-shell* runner body
      (lambda (out) (morg-babel-finish! buf id lang body out)))
    (list 'pending lang)))

(define (morg-babel-finish-scheme! buf id lang body task-ok evaluated)
  (cond
    ((not task-ok)
     (morg-babel-finish! buf id lang body (morg-babel-output evaluated)))
    ((equal? (car evaluated) 'error)
     (morg-babel-finish! buf id lang body (cadr evaluated)))
    (else
      (morg-babel-finish! buf id lang body
        (morg-babel-scheme-pretty (cadr evaluated)) "result-scheme"))))

(define (morg-babel-start-scheme! buf b lang body)
  (let ((id (morg-babel-track! buf b))
        (key (list lang body)))
    (morg-babel-claim! buf key)
    (result-block-insert! buf (nth 0 b) morg-babel-running-text)
    (*morg-babel-scheme* body
      (lambda (ok evaluated)
        (morg-babel-finish-scheme! buf id lang body ok evaluated)))
    (list 'pending lang)))

;;; --- the model ----------------------------------------------------------------
;;; The LLM is one more block language. An `llm` block sends its body as the
;;; prompt, and the answer arrives in the block's result like every other
;;; result. The block asks its buffer which model it belongs to, so a scratch
;;; that inherited its owner's model keeps that model here.

(define morg-babel-llm-languages '("llm" "ask" "chat"))

(define (morg-babel-llm? lang)
  (and (member (string-downcase lang) morg-babel-llm-languages) #t))

(define (morg-babel-buffer-model buf)
  (let ((m (buffer-local buf 'llm-model)))
    (and (string? m) (not (equal? m "")) m)))

;; The seam every LLM block runs through. K receives the answer text.
(define (morg-babel-llm-async prompt model k)
  (if model (llm-with-model prompt model k) (llm prompt k)))

;; A test replaces this to answer without a network.
(define *morg-babel-llm* morg-babel-llm-async)

;; What the result fence holds while the model works. It names the model, so
;; the wait says who is thinking.
(define (morg-babel-thinking-text model)
  (if model (string-append "thinking: " model) "thinking"))

(define (morg-babel-start-llm! buf b lang body)
  (let ((id (morg-babel-track! buf b))
        (key (list lang body))
        (model (morg-babel-buffer-model buf)))
    (morg-babel-claim! buf key)
    (result-block-insert! buf (nth 0 b) (morg-babel-thinking-text model))
    (*morg-babel-llm* body model
      (lambda (answer) (morg-babel-finish! buf id lang body answer)))
    (list 'pending lang)))

;;; --- the kind runners --------------------------------------------------------
;;; Each runner is the 'run of a fence-kind registration. The contract:
;;; (RUN BUF SCAN FSTART ENTRY LANG BODY) -> (ok LANG), (pending LANG),
;;; or (error MSG).

(define (morg-babel--shell-run buf b lang body)
  (cond
    ((morg-babel-sync? (nth 2 b))
     (result-block-insert! buf (nth 0 b)
       (morg-babel-run-shell (morg-babel-runner lang) body))
     (list 'ok lang))
    ((member (list lang body) (morg-babel-inflight buf))
     (list 'error (string-append "The " lang " block already runs")))
    (else (morg-babel-start! buf b lang body))))

(define (morg-babel--scheme-run buf b lang body)
  (cond
    ((morg-babel-sync? (nth 2 b))
     (result-block-insert! buf (nth 0 b)
       (morg-babel-scheme-pretty (eval-string body)) "result-scheme")
     (list 'ok lang))
    ((member (list lang body) (morg-babel-inflight buf))
     (list 'error "The scheme block already runs"))
    (else (morg-babel-start-scheme! buf b lang body))))

(define (morg-babel--llm-run buf b lang body)
  (if (member (list lang body) (morg-babel-inflight buf))
      (list 'error (string-append "The " lang " block already asks"))
      (morg-babel-start-llm! buf b lang body)))

(define (morg-babel--csv-run buf b lang body)
  (morg-babel-preview-csv! buf b body)
  (list 'ok lang))

;;; --- the bundled runner kinds ------------------------------------------------

(for-each
  (lambda (row)
    (define-fence-kind! (car row)
      (string-append "Runs the body through " (cadr row)
                     " and lands the output in a result fence.")
      'interpreter (cadr row) 'ts-lang (caddr row)
      'run morg-babel--shell-run))
  *morg-babel-runners*)

(define-fence-kind! "scheme"
  "Runs the body as editor Scheme in a shared-world task. Add :sync to hold the editor."
  'run morg-babel--scheme-run)

(for-each
  (lambda (name)
    (define-fence-kind! name
      "Sends the body to the buffer's model. The answer lands in the result fence."
      'run morg-babel--llm-run))
  morg-babel-llm-languages)

(define-fence-kind! "csv"
  "Previews the first body lines as a result-csv fence. :lines N sets the count."
  'run morg-babel--csv-run)

;;; --- runners by argument -----------------------------------------------------
;;; An argument on the fence can own the run before the language does. A
;;; block marked `:show-source` fetches its body instead of running it,
;;; whatever language paints it. (fence-arg-run! ARG FN): FN takes
;;; (BUF BLOCK LANG BODY) and answers like a kind's runner.

(define *fence-arg-runners* '())

(define (fence-arg-run! arg fn)
  (set! *fence-arg-runners*
    (cons (list arg fn)
          (remove (lambda (e) (equal? (car e) arg)) *fence-arg-runners*))))

;; the runner of the first registered argument that INFO carries as a
;; word, or #f
(define (fence-arg-runner info)
  (let ((words (string-split info " ")))
    (let loop ((rs *fence-arg-runners*))
      (cond ((null? rs) #f)
            ((member (car (car rs)) words) (cadr (car rs)))
            (else (loop (cdr rs)))))))

(define (morg-babel-execute buf pos)
  (let ((b (block-at buf pos)))
    (if (not b)
        (list 'error "Point is not in a code block")
        (let ((lang (block-lang b))
              (by-arg (fence-arg-runner (nth 2 b))))
          (cond
            (by-arg (by-arg buf b lang (or (block-text-at buf (nth 3 b) (nth 4 b)) "")))
            ((equal? lang "") (list 'error "The block names no language"))
            ((not (fence-kind-runnable? lang))
             (list 'error (string-append "A " lang " block does not run")))
            (else
              (let ((body (or (block-text-at buf (nth 3 b) (nth 4 b)) ""))
                    (run (fence-kind-run lang)))
                (if run
                    (run buf b lang body)
                    (list 'error (string-append "No runner for " lang))))))))))

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
  "(morg-babel-execute BUF POS) — run the Morg block at POS and update its result fence; an asynchronous block returns (pending LANG)")
(public! 'fence-arg-run!
  "(fence-arg-run! ARG FN) — FN (BUF BLOCK LANG BODY) runs a block whose fence carries the word ARG, ahead of the language's runner")

;; Do not leak this extension's catalog context into the next package.
(package! morg-babel-parent-package morg-babel-parent-namespace)
(domain! morg-babel-parent-domain)
(effects! morg-babel-parent-effects)
