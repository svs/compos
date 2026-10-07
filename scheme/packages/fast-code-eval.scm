;;; fast-code-eval.scm --- a fixed set of requests, run twice each, to measure fast-code.
;;;
;;; Each case is a request and a check on the code it should resolve to;
;;; nothing is run. The first run may write a function; a passing one is
;;; kept, in a store of the eval's own, so the second run of the same
;;; request can call it. That second run is what a person meets every day.
;;; One model at a time, so neither the timings nor the learned functions
;;; of one model reach another.

(domain! 'fast-code)
(effects! '(read external spend))

(define (fast-eval-has code &rest parts)
  (and (string? code) (null? (filter (lambda (p) (not (string-contains? code p))) parts))))

(define (fast-eval-any code &rest parts)
  (and (string? code) (pair? (filter (lambda (p) (string-contains? code p)) parts))))

;; a theme named as the string it is
(define (fast-eval-theme? code names)
  (and (fast-eval-has code "load-theme")
       (pair? (filter (lambda (n) (string-contains? code (format "~s" n))) names))))

(define fast-eval-dark '("crt" "ascii" "zenburn" "tokyo-night" "catppuccin-mocha" "compos-dark" "paper-night"))
(define fast-eval-light '("paper" "paperized" "maharaja" "brut"))

(define fast-eval-cases
  (list
    (list "switch to a dark theme" (lambda (c) (fast-eval-theme? c fast-eval-dark)))
    (list "switch to a light theme" (lambda (c) (fast-eval-theme? c fast-eval-light)))
    (list "switch to the zenburn theme" (lambda (c) (fast-eval-theme? c '("zenburn"))))
    (list "open the groups list" (lambda (c) (fast-eval-any c "run-command \"groups" "groups-mode")))
    (list "filter it for md files" (lambda (c) (and (fast-eval-any c "list-filter-push!" "filter") (fast-eval-has c "md") (not (fast-eval-has c "dired-open")))))
    (list "close every other window" (lambda (c) (fast-eval-has c "delete-other-windows!")))
    (list "split the window side by side" (lambda (c) (fast-eval-any c "split-window! 'h" "split-window! (quote h)" "split-window-right")))
    (list "split the window above and below" (lambda (c) (fast-eval-any c "split-window! 'v" "split-window! (quote v)" "split-window-below")))
    (list "kill the scratch buffer" (lambda (c) (fast-eval-has c "buffer-kill!" "*scratch*")))
    (list "open a dired here" (lambda (c) (fast-eval-has c "dired-open" "(default-directory)")))
    (list "open dired on my home directory" (lambda (c) (fast-eval-has c "dired-open" "~")))
    (list "show the messages buffer beside this one" (lambda (c) (fast-eval-has c "*Messages*")))
    (list "list the open buffers" (lambda (c) (fast-eval-any c "buffer-list" "ibuffer")))
    (list "save this buffer" (lambda (c) (fast-eval-any c "save-buffer" "buffer-save!")))
    (list "go to the end of the buffer" (lambda (c) (fast-eval-has c "end-of-buffer")))
    (list "switch to the previous buffer" (lambda (c) (fast-eval-has c "previous-buffer")))
    (list "open a random md file" (lambda (c) (and (fast-eval-has c "random") (fast-eval-any c "directory-entries" "(ls" "project-files"))))
    (list "close every other window and put the scratch buffer beside this one" (lambda (c) (fast-eval-has c "*scratch*")))
    (list "open my downloads folder showing only pdf files" (lambda (c) (fast-eval-has c "Downloads" "pdf")))
    (list "show me the functions fast-code learned" (lambda (c) (fast-eval-any c "fast-show-learned" "fast-recipes")))))

(define (fast-eval-median xs)
  (if (null? xs) 0 (list-ref (sort xs) (quotient (length xs) 2))))

(define (fast-eval-mean xs)
  (if (null? xs) 0 (quotient (fold + 0 xs) (length xs))))

;; K gets one row a case: (INTENT RUN1 RUN2), a run being (PASS? MS CODE
;; DEFINED TIMING REASON). The model's learned functions live in a store of
;; the eval's own and are forgotten after.
(define (fast-eval-model! model log k)
  (let ((saved-path *fast-learned-path*)
        (saved *fast-learned*))
    (set! *fast-learned-path* "/tmp/fast-eval-learned.scm")
    (set! *fast-learned* '())
    (let loop ((cs fast-eval-cases) (rows '()))
      (if (null? cs)
          (begin
            (for-each fast-forget! (fast-learned-names))
            (set! *fast-learned-path* saved-path)
            (set! *fast-learned* saved)
            (k (reverse rows)))
          (let* ((intent (car (car cs)))
                 (check (car (cdr (car cs))))
                 (run (lambda (then)
                        (let ((t0 (monotonic-ms)))
                          (fast-resolve intent
                            (lambda (r)
                              (let* ((code (plist-get r 'code))
                                     (pass (and code (check code) #t)))
                                ;; a passing function is kept, as a clean run keeps it
                                (if pass (fast-keep-pending! intent) (set! *fast-pending* #f))
                                (then (list pass (- (monotonic-ms) t0) code
                                            (plist-get r 'defined) (plist-get r 'timing)
                                            (plist-get r 'reason)))))
                            model)))))
            (run (lambda (r1)
                   (run (lambda (r2)
                          (fast-eval-record!
                            (list 'model model 'intent intent
                                  'pass1 (car r1) 'ms1 (nth 1 r1) 'code1 (nth 2 r1) 'timing1 (nth 4 r1) 'reason1 (nth 5 r1)
                                  'defined (or (nth 3 r1) (nth 3 r2))
                                  'pass2 (car r2) 'ms2 (nth 1 r2) 'code2 (nth 2 r2) 'timing2 (nth 4 r2) 'reason2 (nth 5 r2)))
                          (log (format "~a | ~a | 1: ~a ~a ms ~s | 2: ~a ~a ms ~s | ~a\n" model intent
                                       (if (car r1) "pass" "FAIL") (nth 1 r1) (nth 4 r1)
                                       (if (car r2) "pass" "FAIL") (nth 1 r2) (nth 4 r2)
                                       (or (nth 2 r2) (nth 5 r2))))
                          (loop (cdr cs) (cons (list intent r1 r2) rows)))))))))))

(define (fast-eval-summary model rows)
  (let* ((r1 (map (lambda (row) (nth 1 row)) rows))
         (r2 (map (lambda (row) (nth 2 row)) rows))
         (passes (lambda (rs) (length (filter car rs))))
         (ms (lambda (rs) (map (lambda (r) (nth 1 r)) rs))))
    (format "~a: run 1 ~a/~a pass, median ~a ms, mean ~a ms | run 2 ~a/~a pass, median ~a ms, mean ~a ms\n"
            model (passes r1) (length rows) (fast-eval-median (ms r1)) (fast-eval-mean (ms r1))
            (passes r2) (length rows) (fast-eval-median (ms r2)) (fast-eval-mean (ms r2)))))

;; Models one after another; each result lands in the *fast-eval* table as it
;; happens, and a line of text in BUF, with the summaries at the end.
(define (fast-eval-run! models &optional buf0)
  (define buf (or buf0 "*fast-eval-log*"))
  (buffer-create buf)
  (let loop ((ms models) (sums '()))
    (if (null? ms)
        (buffer-append! buf (string-append "\n" (apply string-append (reverse sums))))
        (fast-eval-model! (car ms) (lambda (line) (buffer-append! buf line))
          (lambda (rows) (loop (cdr ms) (cons (fast-eval-summary (car ms) rows) sums)))))))

;;; --- The table ---------------------------------------------------------------
;;; *fast-eval* is a list: a summary row a model, then a row a request, run 1
;;; and run 2 green or red, a pass slower than two seconds amber. RET shows the
;;; row's whole record beside it; g draws again.

;; the theme's own ok, alert and warn colours, taken at load: an inherit is
;; not followed here, and a face without a colour draws plain
(defface! 'fast-eval-pass 'fg (or (face-color 'ok 'fg) "#2e6b45") 'weight "600")
(defface! 'fast-eval-fail 'fg (or (face-color 'alert 'fg) "#a83a2b") 'weight "600")
(defface! 'fast-eval-slow 'fg (or (face-color 'warn 'fg) "#7a5a1a"))

(define fast-eval-buffer "*fast-eval*")

;; one plist a model and request; kept across a reload
(define *fast-eval-results* (if (boundp '*fast-eval-results*) *fast-eval-results* '()))

(define (fast-eval-record! rec)
  (set! *fast-eval-results*
        (append (remove (lambda (r) (and (equal? (plist-get r 'model) (plist-get rec 'model))
                                         (equal? (plist-get r 'intent) (plist-get rec 'intent))))
                        *fast-eval-results*)
                (list rec)))
  (when (and (buffer-exists? fast-eval-buffer)
             (equal? (buffer-local fast-eval-buffer 'mode-name) "fast-eval-mode"))
    (list-refresh! fast-eval-buffer)))

(define (fast-eval-short-model m)
  (let ((parts (string-split m "/")))
    (car (reverse (string-split (car (reverse parts)) ":")))))

(define (fast-eval-secs ms)
  (if (number? ms)
      (format "~a.~as" (quotient ms 1000) (quotient (remainder ms 1000) 100))
      ""))

(define (fast-eval-run-cell pass ms)
  (list (string-append (if pass "✓ " "✗ ") (fast-eval-secs ms))
        (cond ((not pass) "fast-eval-fail")
              ((and (number? ms) (> ms 2000)) "fast-eval-slow")
              (else "fast-eval-pass"))))

(define (fast-eval-models)
  (let loop ((rs *fast-eval-results*) (acc '()))
    (cond ((null? rs) (reverse acc))
          ((member (plist-get (car rs) 'model) acc) (loop (cdr rs) acc))
          (else (loop (cdr rs) (cons (plist-get (car rs) 'model) acc))))))

;; a model's summary row, then its requests
(define (fast-eval-rows buf)
  (apply append
    (map (lambda (m)
           (let* ((rs (filter (lambda (r) (equal? (plist-get r 'model) m)) *fast-eval-results*))
                  (sum (lambda (pk mk)
                         (list 'pass (length (filter (lambda (r) (plist-get r pk)) rs))
                               'of (length rs)
                               'median (fast-eval-median (filter number? (map (lambda (r) (plist-get r mk)) rs)))))))
             (cons (list 'kind 'summary 'model m 'run1 (sum 'pass1 'ms1) 'run2 (sum 'pass2 'ms2))
                   rs)))
         (fast-eval-models))))

(define (fast-eval-summary-cell s)
  (list (format "~a/~a · ~a" (plist-get s 'pass) (plist-get s 'of) (fast-eval-secs (plist-get s 'median)))
        (if (= (plist-get s 'pass) (plist-get s 'of)) "fast-eval-pass" "fast-eval-fail")))

(define (fast-eval-cells buf e)
  (if (equal? (plist-get e 'kind) 'summary)
      (list (list (fast-eval-short-model (plist-get e 'model)) "accent")
            (list "all requests (pass · median)" "accent")
            (fast-eval-summary-cell (plist-get e 'run1))
            (fast-eval-summary-cell (plist-get e 'run2))
            (list "" "dim")
            (list "" "dim"))
      (list (list (fast-eval-short-model (plist-get e 'model)) "dim")
            (list (plist-get e 'intent) "default")
            (fast-eval-run-cell (plist-get e 'pass1) (plist-get e 'ms1))
            (fast-eval-run-cell (plist-get e 'pass2) (plist-get e 'ms2))
            (list (or (plist-get e 'defined) "") "dim")
            (let ((code (plist-get e 'code2)))
              (if code (list code "default") (list (or (plist-get e 'reason2) "") "fast-eval-fail"))))))

;; the whole record, beside the table
(define (fast-eval-show)
  (let ((e (list-current fast-eval-buffer)))
    (when (and e (not (equal? (plist-get e 'kind) 'summary)))
      (let ((buf (string-append "*fast-eval: " (plist-get e 'intent) "*"))
            (line (lambda (k) (string-append (symbol->string k) "  " (value->string (plist-get e k)) "\n"))))
        (buffer-create buf)
        (buffer-set-text! buf
          (apply string-append
                 (map line '(model intent pass1 ms1 timing1 code1 reason1 defined pass2 ms2 timing2 code2 reason2))))
        (display-buffer-detail! buf fast-eval-buffer)))))

(define-list-mode! "fast-eval-mode"
  (list
    'doc (string-append
           "The fast-code eval: a summary row a model, then each request with "
           "its first and second run, green when the code passed its check, red "
           "when not, amber for a pass slower than two seconds. `RET` shows the "
           "row's whole record beside the table, `g` draws it again, `q` quits.")
    'buffer fast-eval-buffer
    'transient #f
    'rows fast-eval-rows
    'columns (lambda (buf)
               (list (list "model" 16) (list "request" 40) (list "run 1" 13)
                     (list "run 2" 13) (list "learned" 20) (list "answer" #f)))
    'cells fast-eval-cells
    'title (lambda (buf) "fast-code eval")
    'total (lambda (buf) (length *fast-eval-results*))
    'no-marks #t
    'key (lambda (buf e) (string-append (plist-get e 'model) " " (or (plist-get e 'intent) "")))
    'footer (lambda (buf) '(("RET" "record") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "fast-eval-show") ("g" "fast-eval-refresh") ("q" "quit-window"))))

(define-command "fast-eval-show" "Show the eval row's whole record" (lambda () (fast-eval-show)))
(define-command "fast-eval-refresh" "Draw the eval table again" (lambda () (list-refresh! fast-eval-buffer)))
;;;###autoload
(define-command "fast-eval" "Show the fast-code eval as a table"
  (lambda () (list-mode-show! "fast-eval-mode")))

;; The eval's text log read back into records: a run from before the table,
;; or a log kept elsewhere.
(define (fast-eval-import! text)
  (for-each
    (lambda (line)
      (let ((f (string-split line " | ")))
        (when (>= (length f) 5)
          (let* ((run (lambda (s)
                        (let ((ws (string-split (string-trim s) " ")))
                          (list (equal? (nth 1 ws) "pass") (string->number (nth 2 ws))
                                (let ((i (string-index s "("))) (and i (substring-bytes s i (string-byte-length s))))))))
                 (r1 (run (nth 2 f)))
                 (r2 (run (nth 3 f)))
                 (last (string-join (list-tail f 4) " | "))
                 (code? (string-prefix? "(" last)))
            (fast-eval-record!
              (list 'model (nth 0 f) 'intent (nth 1 f)
                    'pass1 (car r1) 'ms1 (nth 1 r1) 'timing1 (nth 2 r1)
                    'pass2 (car r2) 'ms2 (nth 1 r2) 'timing2 (nth 2 r2)
                    'code2 (and code? last) 'reason2 (and (not code?) last)))))))
    (string-split text "\n")))

(category! 'fast-code)
(public! 'fast-eval-import! "(fast-eval-import! TEXT) -- read eval log lines back into the *fast-eval* table")
(public! 'fast-eval-run! "(fast-eval-run! MODELS [LOG]) -- run the fast-code eval set twice a case for each model, one model at a time; M-x fast-eval shows the table")
