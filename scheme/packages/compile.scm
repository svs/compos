;;; compile.scm --- M-x compile: run a build, step through its errors.
;;;
;;; A compilation runs in its own process buffer, *compilation:PROJECT*,
;;; so the editor never waits on it: the output streams in as it comes.
;;; next-error (M-g n) and previous-error (M-g p) visit the FILE:LINE
;;; places the output names, and RET visits the one on its line.
;;;
;;; When the process ends, compilation-finish-functions runs (BUF STATUS)
;;; and the event compile/done goes out, so a chat can wait for a build:
;;;   (agent-listen! '(topic "compile" kind done) "read the build result")

(require 'comint)

(domain! 'code)
(effects! '(pure))

(defcustom 'compile-command #f
  "The command M-x compile offers first. #f guesses from the project: mix compile, cargo build, make -k, npm run build or go build.")

(defvar 'compilation-finish-functions '()
  "Functions run as (BUF STATUS) when a compilation ends; STATUS is the exit code, or killed.")

(define *compile-last-buffer* #f)

;; (REGEXP FILE-GROUP LINE-GROUP COLUMN-GROUP): the shapes a place takes
(define compile--places
  (list (list "File \"([^\"]+)\", line ([0-9]+)" 1 2 #f)
        (list "((?:[A-Za-z]:)?[^\\s:\"'(),\\[\\]{}<>|=]+\\.[A-Za-z0-9]+):([0-9]+)(?::([0-9]+))?" 1 2 3)))

(define compile--header-lines 4)

(define (compile--nth l n) (and n (> (length l) n) (list-ref l n)))

(define (compile--dir d) (if (string-suffix? "/" d) d (string-append d "/")))

(define (compile--root)
  (let ((d (default-directory)))
    (compile--dir (or (git-root d) d))))

(define (compile--guess dir)
  (let ((has (lambda (f) (file-exists? (expand-file-name f dir)))))
    (cond ((has "mix.exs") "mix compile")
          ((has "Cargo.toml") "cargo build")
          ((or (has "Makefile") (has "makefile")) "make -k")
          ((has "package.json") "npm run build")
          ((has "go.mod") "go build ./...")
          (else "make -k"))))

(define (compile--buffer-name dir)
  (let ((parts (filter (lambda (s) (not (equal? s ""))) (string-split dir "/"))))
    (string-append "*compilation:" (if (null? parts) "/" (list-ref parts (- (length parts) 1))) "*")))

(define (compile--local buf key) (and (buffer-exists? buf) (buffer-local-value key buf)))

(define (compile--seconds ms)
  (let* ((cs (quotient ms 10)) (r (remainder cs 100)))
    (string-append (number->string (quotient cs 100)) "." (if (< r 10) "0" "") (number->string r))))

;; the place one output line names, as (PATH LINE COLUMN), or #f; a
;; place counts only when its file exists, so a clock or a URL does not
(define (compile--line-place text dir)
  (let loop ((ps compile--places))
    (if (null? ps)
        #f
        (let* ((p (car ps))
               (m (re-match (car p) text))
               (file (and m (compile--nth m (cadr p))))
               (path (and file (expand-file-name file dir))))
          (if (and path (file-exists? path))
              (list path (string->number (compile--nth m (caddr p)))
                    (let ((c (compile--nth m (cadddr p)))) (and c (string->number c))))
              (loop (cdr ps)))))))

(effects! '(read))

(define (compile-errors buf)
  "(compile-errors BUF) - the places the output in BUF names, in order, as (BUF-LINE PATH LINE COLUMN TEXT)"
  (let ((dir (compile--local buf 'compile-dir)))
    (if (not dir)
        '()
        (let loop ((ls (string-split (buffer-text buf) "\n")) (n 1) (out '()))
          (cond ((null? ls) (reverse out))
                ((<= n compile--header-lines) (loop (cdr ls) (+ n 1) out))
                (else
                 (let ((e (and (< (string-length (car ls)) 2000) (compile--line-place (car ls) dir))))
                   (loop (cdr ls) (+ n 1)
                         (if e (cons (cons n (append e (list (string-trim (car ls))))) out) out)))))))))

(define (compile--errors buf)
  (or (and (not (process-running? buf)) (compile--local buf 'compile-error-cache))
      (let ((es (compile-errors buf)))
        (unless (process-running? buf) (buffer-set-local! buf 'compile-error-cache es))
        es)))

(define (compile-last-buffer)
  "(compile-last-buffer) - the compilation buffer next-error steps through, or #f"
  (and *compile-last-buffer* (buffer-exists? *compile-last-buffer*) *compile-last-buffer*))

;; the compilation to step through: this buffer when it is one, else the last
(define (compile--current)
  (let ((cur (current-buffer)))
    (if (compile--local cur 'compile-command) cur (compile-last-buffer))))

(effects! '(write execute))

(define (compile! cmd &optional dir)
  "(compile! CMD [DIR]) - run CMD in DIR, the project root by default, in the buffer *compilation:PROJECT*, and answer the buffer at once. The output streams in; when CMD ends, compile/done goes out with its exit code and errors."
  (let* ((dir (compile--dir (expand-file-name (or dir (compile--root)) (default-directory))))
         (buf (compile--buffer-name dir)))
    (when (and (buffer-exists? buf) (process-running? buf))
      (process-kill! buf))
    (buffer-set-text! buf (string-append "-*- mode: compilation; default-directory: \"" dir "\" -*-\n"
                                         "Compilation started at " (format-time (current-time) "%a %b %d %H:%M:%S") "\n\n"
                                         cmd "\n"))
    (with-current-buffer buf (lambda () (major-mode-set! "compilation-mode")))
    (for-each (lambda (kv) (buffer-set-local! buf (car kv) (cadr kv)))
              (list (list 'compile-command cmd) (list 'compile-dir dir) (list 'compile-done #f)
                    (list 'compile-error-cache #f) (list 'compile-error-index -1)
                    (list 'compile-started (monotonic-ms))))
    (set! *compile-last-buffer* buf)
    (unless (start-process! buf (string-append "cd " (sh-quote dir) " && " cmd))
      (compile--finished! buf 'failed))
    buf))

;; the end of a run: say how it went, once, in the buffer, the echo area
;; and the event log
(define (compile--finished! buf status)
  (when (and (compile--local buf 'compile-command) (not (compile--local buf 'compile-done)))
    (buffer-set-local! buf 'compile-done #t)
    (buffer-set-local! buf 'compile-error-cache #f)
    (let* ((errs (compile--errors buf))
           (ms (- (monotonic-ms) (or (compile--local buf 'compile-started) (monotonic-ms))))
           (how (cond ((equal? status 0) "finished")
                      ((number? status) (string-append "exited abnormally with code " (number->string status)))
                      ((equal? status 'killed) "was killed")
                      (else "did not start")))
           (n (length errs)))
      (buffer-set-read-only! buf #f)
      (buffer-append! buf (string-append "\nCompilation " how " at " (format-time (current-time) "%a %b %d %H:%M:%S")
                                         ", duration " (compile--seconds ms) " s\n"))
      (buffer-set-read-only! buf #t)
      (message (string-append "Compilation " how
                              (cond ((= n 0) "") ((= n 1) ": 1 error place, M-g n visits it")
                                    (else (string-append ": " (number->string n) " error places, M-g n visits the first")))))
      (run-hook-with-args 'compilation-finish-functions buf status)
      (event-publish! "compile" 'done
                      (list 'buffer buf 'command (compile--local buf 'compile-command)
                            'dir (compile--local buf 'compile-dir)
                            'exit (if (symbol? status) (symbol->string status) status)
                            'ms ms 'errors n
                            'first (map (lambda (e) (list-ref e 4)) (if (> n 10) (list-head errs 10) errs)))))))

;; a process ended: a compilation buffer whose process still runs heard
;; the end of the run before it, so it waits for its own
(add-hook! 'process-exit-hook
  (lambda (buf status)
    (when (and (compile--local buf 'compile-command) (not (process-running? buf)))
      (compile--finished! buf status))))

(effects! '(write display))

(define (compile--show! buf)
  (display-buffer-other-window! buf)
  buf)

(define (compile--visit! buf idx)
  (let* ((errs (compile--errors buf)) (e (list-ref errs idx)))
    (buffer-set-local! buf 'compile-error-index idx)
    (buffer-goto-line! buf (car e))
    (let ((src (find-file-other-window! (list-ref e 1))))
      (when src (buffer-goto-line! src (list-ref e 2))))
    (message (string-append (number->string (+ idx 1)) "/" (number->string (length errs)) "  " (list-ref e 4)))))

(define (compile--step! n)
  (let ((buf (compile--current)))
    (if (not buf)
        (message "No compilation to step through: run M-x compile")
        (let* ((errs (compile--errors buf))
               (i (+ (or (compile--local buf 'compile-error-index) -1) n)))
          (cond ((null? errs) (message "The compilation output names no places"))
                ((< i 0) (message "No error before this one"))
                ((>= i (length errs)) (message "No error after this one"))
                (else (compile--visit! buf i)))))))

;; the index of the first place on LINE or after it, or #f
(define (compile--index-from errs line)
  (let loop ((es errs) (i 0))
    (cond ((null? es) #f) ((>= (car (car es)) line) i) (else (loop (cdr es) (+ i 1))))))

(define (compile--move-point! n)
  (let* ((buf (current-buffer))
         (errs (compile--errors buf))
         (line (car (buffer-line-at-point buf)))
         (hits (if (> n 0)
                   (filter (lambda (e) (> (car e) line)) errs)
                   (reverse (filter (lambda (e) (< (car e) line)) errs)))))
    (if (null? hits)
        (message (if (> n 0) "No error place after this line" "No error place before this line"))
        (buffer-goto-line! buf (car (car hits))))))

;;;###autoload
(define-command "compile" "Run a build command in the project without waiting; its errors become places to visit"
  (lambda ()
    (let* ((dir (compile--root))
           (last (compile-last-buffer))
           (init (or (and last (compile--local last 'compile-command)) compile-command (compile--guess dir))))
      (read-string "Compile command: "
                   (lambda (cmd)
                     (let ((cmd (string-trim cmd)))
                       (unless (equal? cmd "") (compile--show! (compile! cmd dir)))))
                   'initial init 'history 'compile-history))))

;;;###autoload
(define-command "recompile" "Run the last compilation again, in its directory"
  (lambda ()
    (let ((buf (compile--current)))
      (if buf
          (compile--show! (compile! (compile--local buf 'compile-command) (compile--local buf 'compile-dir)))
          (run-command "compile")))))

;;;###autoload
(define-command "next-error" "Visit the next place the compilation output names"
  (lambda () (compile--step! 1)))

;;;###autoload
(define-command "previous-error" "Visit the previous place the compilation output names"
  (lambda () (compile--step! -1)))

(define-command "compile-goto-error" "Visit the place this line of the compilation output names"
  (lambda ()
    (let* ((buf (current-buffer))
           (errs (compile--errors buf))
           (line (car (buffer-line-at-point buf)))
           (i (compile--index-from errs line)))
      (if (and i (= (car (list-ref errs i)) line))
          (compile--visit! buf i)
          (message "This line names no place"))))
  'modes '("compilation-mode"))

(define-command "compilation-next-error" "Move to the next line that names a place"
  (lambda () (compile--move-point! 1))
  'modes '("compilation-mode"))

(define-command "compilation-previous-error" "Move to the previous line that names a place"
  (lambda () (compile--move-point! -1))
  'modes '("compilation-mode"))

(define-command "kill-compilation" "Stop the compilation that runs in this buffer"
  (lambda ()
    (let ((buf (compile--current)))
      (if (and buf (process-running? buf))
          (begin (process-kill! buf) (compile--finished! buf 'killed))
          (message "No compilation runs"))))
  'modes '("compilation-mode"))

(define-mode "compilation-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))

(mode-keys! "compilation-mode"
  '(("RET" "compile-goto-error") ("g" "recompile") ("q" "quit-window")
    ("n" "compilation-next-error") ("p" "compilation-previous-error")
    ("M-n" "compilation-next-error") ("M-p" "compilation-previous-error")
    ("C-c C-k" "kill-compilation")))

(mode-doc! "compilation-mode"
  "The output of a build that M-x compile runs. `RET` visits the place a line names, `n` and `p` move between those lines, `g` runs the build again, `C-c C-k` stops it and `q` quits. From any buffer, `M-g n` and `M-g p` step through the places.")

(define-key "goto-map" "n" "next-error")
(define-key "goto-map" "M-n" "next-error")
(define-key "goto-map" "p" "previous-error")
(define-key "goto-map" "M-p" "previous-error")
(define-key "ctl-x-map" "`" "next-error")

(domain! 'code)
(effects! '(write execute))
(public! 'compile! "(compile! CMD [DIR]) — run CMD in DIR, the project root by default, in *compilation:PROJECT* without waiting; answer the buffer. compile/done goes out when it ends, with buffer, command, dir, exit, ms, errors and first")
(effects! '(read))
(public! 'compile-errors "(compile-errors BUF) — the places the compilation output in BUF names, as (BUF-LINE PATH LINE COLUMN TEXT)")
(public! 'compile-last-buffer "(compile-last-buffer) — the compilation buffer next-error steps through, or #f")

(provide 'compile)
