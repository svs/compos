;;; test-browser.scm --- browse a project's tests as a tree and run them.
;;;
;;; One listing per project root: its test files, the groups in them and
;;; their tests, read with tree-sitter, each with its last result. Moving
;;; the point shows the row's source and output beside the list.
;;;
;;; A backend knows one kind of project: whether a root is one, which
;;; files hold its tests, how to read the tree out of one, and how to run
;;; a scope. mix and the editor's own Scheme tests ship here;
;;; test-browser-define-backend! adds another.

(domain! 'testing)
(effects! '(pure))

(define (tb--line-of text byte)
  "the 1-based line BYTE sits on in TEXT"
  (length (string-split (substring-bytes text 0 byte) "\n")))

(define (tb--unquote s)
  (let* ((s (if (string-prefix? "'" s) (substring s 1 (string-length s)) s))
         (n (string-length s)))
    (if (and (>= n 2) (string-prefix? "\"" s) (string-suffix? "\"" s))
        (substring s 1 (- n 1))
        s)))

(define (tb--indent n) (apply string-append (map (lambda (_) "  ") (iota n))))

(effects! '(read))

(define (tb--matches lang text query)
  "((start S end E fn TEXT name TEXT) ...), one per match of QUERY; QUERY
captures @call, then @fn and @name inside it"
  (let ((out '()) (cur #f))
    (for-each
      (lambda (c)
        (let ((cap (car c)) (s (cadr c)) (e (caddr c)))
          (cond
            ((equal? cap "call")
             (when cur (set! out (cons cur out)))
             (set! cur (list 'start s 'end e)))
            (cur (set! cur (append cur (list (string->symbol cap)
                                             (substring-bytes text s e))))))))
      (ts-query-string lang text query))
    (when cur (set! out (cons cur out)))
    (reverse out)))

(define (tb--tree path rel text lang query kinds)
  "the rows of one file: the file, then its groups and tests in source
order. KINDS maps a call's name to 'group or 'test; other calls drop."
  (let ((rows '()) (stack '()))
    (for-each
      (lambda (m)
        (let ((kind (assoc (plist-get m 'fn) kinds)))
          (when (and kind (plist-get m 'name))
            (let* ((start (plist-get m 'start)) (end (plist-get m 'end))
                   (line (tb--line-of text start)))
              (set! stack (filter (lambda (g) (> (cadr g) start)) stack))
              (let ((id (string-append rel ":" (number->string line))))
                (set! rows
                  (cons (list 'id id 'kind (cadr kind)
                              'name (tb--unquote (plist-get m 'name))
                              'path path 'rel rel 'line line
                              'end-line (tb--line-of text end)
                              'depth (+ 1 (length stack))
                              'groups (map car stack))
                        rows))
                (when (eq? (cadr kind) 'group)
                  (set! stack (cons (list id end) stack))))))))
      (tb--matches lang text query))
    (if (null? rows)
        '()
        (cons (list 'id rel 'kind 'file 'name rel 'path path 'rel rel
                    'line 1 'end-line #f 'depth 0 'groups '())
              (reverse rows)))))

;;; ---------------------------------------------------------------- backends

(effects! '(write))

(define *test-browser-backends* '())

(define (test-browser-define-backend! name spec)
  "SPEC: 'detect (ROOT) -> bool, 'files (ROOT) -> relative paths,
'discover (ROOT REL) -> rows, 'run (ROOT SCOPE TESTS K) where SCOPE is the
row run (#f for all) and K gets (complete BOOL output TEXT failures
((ID TEXT) ...) skipped (ID ...) times ((ID MS) ...))"
  (set! *test-browser-backends*
    (append (filter (lambda (b) (not (eq? (car b) name))) *test-browser-backends*)
            (list (cons name spec))))
  name)

(define (tb--backends-for root)
  "the names of every backend that knows ROOT"
  (map car (filter (lambda (b) ((plist-get (cdr b) 'detect) root)) *test-browser-backends*)))

;;; mix: the tree from tree-sitter, the results from mix test's own report.
;;; A test that ran and is not among the failures passed; mix does not
;;; name the tests a tag excluded, so those read as passed too.

(define tb--elixir-query
  "(call target: (identifier) @fn (arguments . (string) @name)) @call")

(define (tb--mix-parse output)
  "what mix test said: the failures by location and whether it finished"
  (let ((fails '()) (cur #f) (loc #f) (complete #f))
    (define (flush!)
      (when (and cur loc)
        (set! fails (cons (list loc (string-join (reverse cur) "\n")) fails)))
      (set! cur #f)
      (set! loc #f))
    (for-each
      (lambda (line)
        (let ((t (string-trim line)))
          (cond
            ((re-find "^ +[0-9]+[)] (test|doctest|property) " line 0)
             (flush!)
             (set! cur (list line)))
            ((re-find "^Finished in " t 0) (flush!))
            ((and (re-find "[0-9]+ failures?" t 0) (re-find "[0-9]+ (tests?|doctests?|propert)" t 0))
             (set! complete #t))
            ((and cur (not loc) (re-find "^[^ ]+_test[.]exs:[0-9]+$" t 0))
             (set! loc t)
             (set! cur (cons line cur)))
            (cur (set! cur (cons line cur))))))
      (string-split output "\n"))
    (flush!)
    (list 'complete complete 'output output 'failures fails 'skipped '() 'times '())))

(define (tb--mix-run root scope tests k)
  (let ((arg (cond ((not scope) "")
                   ((eq? (plist-get scope 'kind) 'file) (string-append " " (plist-get scope 'rel)))
                   (else (string-append " " (plist-get scope 'id))))))
    (shell-command->string (string-append "mix test --no-color" arg " 2>&1") root
      (lambda (out) (k (tb--mix-parse (if (string? out) out "")))))))

(test-browser-define-backend! 'mix
  (list 'detect (lambda (root) (file-exists? (string-append root "/mix.exs")))
        'files (lambda (root)
                 (filter (lambda (f) (string-suffix? "_test.exs" f)) (project-files root)))
        'discover (lambda (root rel)
                    (let ((path (string-append root "/" rel)))
                      (tb--tree path rel (read-file path) "elixir" tb--elixir-query
                                '(("describe" group) ("test" test)))))
        'run tb--mix-run))

;;; the editor's own Scheme tests: deftest forms, run in this editor

(define tb--scheme-query "(list . (symbol) @fn . (quote) @name) @call")

(define (tb--scheme-files root)
  (let* ((pre (string-append root "/")) (n (string-length pre)))
    (map (lambda (p)
           (let ((p (string-replace p "/_build/dev/lib/compos_core/" "/apps/compos_core/")))
             (if (string-prefix? pre p) (substring p n (string-length p)) p)))
         (append (test-files 'core) (test-files 'packages)))))

(define (tb--scheme-run root scope tests k)
  "run TESTS one at a time, yielding to the editor between them; a file
loads once, before its first test"
  (let ((loaded '()) (fails '()) (skipped '()) (times '()) (lines '()))
    (define (step rest)
      (if (null? rest)
          (k (list 'complete #t 'output (string-join (reverse lines) "\n")
                   'failures fails 'skipped skipped 'times times))
          (let* ((t (car rest)) (id (plist-get t 'id)) (rel (plist-get t 'rel))
                 (name (string->symbol (plist-get t 'name))))
            (unless (member rel loaded)
              (set! loaded (cons rel loaded))
              (ignore-errors (lambda () (load-test-files! (list (plist-get t 'path))))))
            (let* ((t0 (monotonic-ms))
                   (fs (if (and (test-needs-disposable? name) (not (editor-is-disposable?)))
                           'skip
                           (ignore-errors (lambda () (run-test name)))))
                   (ms (- (monotonic-ms) t0)))
              (set! times (cons (list id ms) times))
              (cond
                ((eq? fs 'skip)
                 (set! skipped (cons id skipped))
                 (set! lines (cons (string-append "  skip  " (plist-get t 'name)) lines)))
                ((null? fs)
                 (set! lines (cons (string-append "  ok    " (plist-get t 'name)) lines)))
                (else
                 (let ((text (if fs (string-join fs "\n") "the test raised an error")))
                   (set! fails (cons (list id text) fails))
                   (set! lines (cons (string-append "  FAIL  " (plist-get t 'name) "\n" text) lines))))))
            (debounce! (string-append "test-browser-run:" root) 0 step (cdr rest)))))
    (step tests)))

(test-browser-define-backend! 'scheme
  (list 'detect (lambda (root) (file-exists? (string-append root "/scheme/packages/test.scm")))
        'files tb--scheme-files
        'discover (lambda (root rel)
                    (let ((path (string-append root "/" rel)))
                      (tb--tree path rel (read-file path) "scheme" tb--scheme-query
                                '(("deftest" test)))))
        'run tb--scheme-run))

;;; ---------------------------------------------------------------- state

(define (tb--root buf) (buffer-local buf 'test-browser-root))
(define (tb--backend name) (cdr (assq name *test-browser-backends*)))
(define (tb--all-rows buf) (or (buffer-local buf 'test-browser-tree) '()))
(define (tb--results buf) (or (buffer-local buf 'test-browser-results) '()))

(define (tb--result buf id)
  (let ((r (assoc id (tb--results buf)))) (if r (cdr r) '())))

(define (tb--set-results! buf pairs)
  "PAIRS ((ID . PLIST) ...) replace those ids' results"
  (let ((ids (map car pairs)))
    (buffer-set-local! buf 'test-browser-results
      (append pairs (filter (lambda (r) (not (member (car r) ids))) (tb--results buf))))))

(define (tb--tests-under rows row)
  "the tests ROW stands for: itself, a group's or a file's, or every test"
  (filter (lambda (r)
            (and (eq? (plist-get r 'kind) 'test)
                 (cond ((not row) #t)
                       ((eq? (plist-get row 'kind) 'file) (equal? (plist-get r 'rel) (plist-get row 'rel)))
                       ((eq? (plist-get row 'kind) 'group) (member (plist-get row 'id) (plist-get r 'groups)))
                       (else (equal? (plist-get r 'id) (plist-get row 'id))))))
          rows))

(define (tb--status buf row)
  "a test's own status; a group's or a file's from its tests"
  (if (eq? (plist-get row 'kind) 'test)
      (or (plist-get (tb--result buf (plist-get row 'id)) 'status) 'none)
      (let ((ss (map (lambda (t) (tb--status buf t)) (tb--tests-under (tb--all-rows buf) row))))
        (cond ((member 'running ss) 'running)
              ((member 'error ss) 'error)
              ((member 'fail ss) 'fail)
              ((member 'none ss) (if (or (member 'pass ss) (member 'skip ss)) 'partial 'none))
              ((member 'pass ss) 'pass)
              ((null? ss) 'none)
              (else 'skip)))))

(define (tb--glyph status)
  (cond ((eq? status 'pass) "✓") ((eq? status 'fail) "✗") ((eq? status 'error) "!")
        ((eq? status 'running) "…") ((eq? status 'skip) "-") ((eq? status 'partial) "◐")
        (else "·")))

;;; ---------------------------------------------------------------- listing

(define (tb--listing-name root)
  (string-append "*test-browser:" (file-name-nondirectory root) "*"))

(define (tb--rows buf) (tb--all-rows buf))

(define (tb--cells buf row)
  (let ((ms (plist-get (tb--result buf (plist-get row 'id)) 'ms)))
    (list (tb--glyph (tb--status buf row))
          (string-append (tb--indent (plist-get row 'depth))
                         (if (eq? (plist-get row 'kind) 'group) "▸ " "")
                         (plist-get row 'name))
          (if ms (string-append (number->string ms) "ms") ""))))

(define (tb--discover! buf)
  "read the tree off the UI lane, then draw it"
  (let ((root (tb--root buf)) (names (buffer-local buf 'test-browser-backends)) (t0 (monotonic-ms)))
    (message "test-browser: reading tests…")
    (task-run!
      (lambda ()
        (apply append
          (map (lambda (name)
                 (let ((be (tb--backend name)))
                   (apply append
                     (map (lambda (rel)
                            (map (lambda (r) (plist-put r 'backend name))
                                 (or (ignore-errors (lambda () ((plist-get be 'discover) root rel))) '())))
                          ((plist-get be 'files) root)))))
               names)))
      (lambda (ok? rows)
        (if (not ok?)
            (message (string-append "test-browser: reading failed: " (format "~a" rows)))
            (begin
              (buffer-set-local! buf 'test-browser-tree rows)
              (list-refresh! buf)
              (message (string-append "test-browser: "
                         (number->string (length (tb--tests-under rows #f))) " tests in "
                         (number->string (- (monotonic-ms) t0)) "ms")))))
      120000)))

(define (test-browser-open! root)
  "the listing for ROOT, made, moded and filled; shows nothing"
  (let ((names (tb--backends-for root)) (buf (tb--listing-name root)))
    (when (null? names) (error (string-append "test-browser: no backend knows " root)))
    (buffer-create buf)
    (unless (buffer-local buf 'group) (buffer-set-local! buf 'group (frame-group)))
    (buffer-set-local! buf 'test-browser-root root)
    (buffer-set-local! buf 'test-browser-backends names)
    (with-current-buffer buf (lambda () (set-mode! "test-browser-mode")))
    (unless (buffer-local buf 'test-browser-tree) (tb--discover! buf))
    buf))

;;; ---------------------------------------------------------------- detail

(define (tb--detail-name buf row)
  (string-append "*test-browser:" (file-name-nondirectory (tb--root buf)) ":" (plist-get row 'id) "*"))

(define (tb--source row)
  (let* ((lines (string-split (read-file (plist-get row 'path)) "\n"))
         (from (- (plist-get row 'line) 1))
         (to (min (or (plist-get row 'end-line) (length lines)) (length lines))))
    (string-join (take (list-tail lines from) (max 0 (- to from))) "\n")))

(define (tb--detail-text buf row)
  (let* ((status (tb--status buf row)) (res (tb--result buf (plist-get row 'id)))
         (tests (tb--tests-under (tb--all-rows buf) row))
         (failing (filter (lambda (t) (memq (tb--status buf t) '(fail error))) tests)))
    (string-append
      (tb--glyph status) " " (symbol->string status) "   "
      (symbol->string (plist-get row 'kind)) " " (plist-get row 'name) "\n"
      (plist-get row 'rel) ":" (number->string (plist-get row 'line))
      (if (plist-get res 'ms) (string-append "   " (number->string (plist-get res 'ms)) "ms") "")
      "\n\n"
      (if (eq? (plist-get row 'kind) 'test)
          (string-append "── source\n\n" (tb--source row) "\n\n── output\n\n"
                         (or (plist-get res 'output) "not run yet") "\n")
          (string-append
            (number->string (length tests)) " tests, "
            (number->string (length failing)) " failing\n\n"
            (if (null? failing) ""
                (string-append "── failing\n\n"
                  (string-join (map (lambda (t) (string-append (tb--glyph (tb--status buf t)) " "
                                                   (plist-get t 'name) "  " (plist-get t 'id)))
                                    failing) "\n")
                  "\n\n"))
            "── last run output\n\n"
            (or (plist-get res 'output) "not run yet") "\n")))))

(define (tb--render-detail! buf row)
  (let ((d (tb--detail-name buf row)))
    (buffer-create d)
    (buffer-set-text! d (tb--detail-text buf row) #t)
    (buffer-set-local! d 'group (buffer-local buf 'group))
    (buffer-set-local! d 'test-browser-listing buf)
    (buffer-set-local! d 'test-browser-row row)
    (unless (equal? (buffer-local d 'mode-name) "test-browser-detail-mode")
      (with-current-buffer d (lambda () (set-mode! "test-browser-detail-mode"))))
    d))

(define (tb--redraw-details! buf)
  (for-each (lambda (d)
              (when (equal? (buffer-local d 'test-browser-listing) buf)
                (buffer-set-text! d (tb--detail-text buf (buffer-local d 'test-browser-row)) #t)))
            (buffer-list)))

(effects! '(write display))

(define (test-browser-show-detail! buf row)
  "show ROW's source and last result beside the listing BUF"
  (when row
    (display-buffer-detail! (tb--render-detail! buf row) buf)))

;;; ---------------------------------------------------------------- running

(effects! '(write execute))

(define (tb--run-backend! buf name scope tests t0)
  "run TESTS, all of backend NAME, and record each result"
  ((plist-get (tb--backend name) 'run) (tb--root buf) scope tests
    (lambda (res)
      (let* ((fails (plist-get res 'failures)) (complete (plist-get res 'complete))
             (ms (- (monotonic-ms) t0))
             (pairs (map (lambda (t)
                           (let* ((id (plist-get t 'id)) (f (assoc id fails))
                                  (tm (assoc id (plist-get res 'times))))
                             (cons id
                               (append
                                 (cond (f (list 'status 'fail 'output (cadr f)))
                                       ((member id (plist-get res 'skipped)) (list 'status 'skip))
                                       (complete (list 'status 'pass))
                                       (else (list 'status 'error 'output (plist-get res 'output))))
                                 (if tm (list 'ms (cadr tm)) '())))))
                         tests))
             (failed (length (filter (lambda (p) (memq (plist-get (cdr p) 'status) '(fail error))) pairs))))
        (tb--set-results! buf pairs)
        (when (and scope (not (eq? (plist-get scope 'kind) 'test)))
          (tb--set-results! buf (list (cons (plist-get scope 'id)
                                            (list 'ms ms 'output (plist-get res 'output))))))
        (list-refresh! buf)
        (tb--redraw-details! buf)
        (message (string-append "test-browser: " (symbol->string name) ": "
                   (number->string (length tests)) " tests, "
                   (number->string failed) " failing"
                   (if complete "" " — the run did not finish; see the output")
                   " (" (number->string ms) "ms)"))))))

(define (test-browser-run! buf scope)
  "run the tests SCOPE stands for (#f for all) and record each result;
each backend runs its own share"
  (let ((tests (tb--tests-under (tb--all-rows buf) scope)) (t0 (monotonic-ms)))
    (if (null? tests)
        (message "test-browser: nothing to run")
        (begin
          (tb--set-results! buf (map (lambda (t) (cons (plist-get t 'id) (list 'status 'running))) tests))
          (list-refresh! buf)
          (message (string-append "test-browser: running " (number->string (length tests)) " tests…"))
          (for-each
            (lambda (name)
              (let ((mine (filter (lambda (t) (eq? (plist-get t 'backend) name)) tests)))
                (unless (null? mine) (tb--run-backend! buf name scope mine t0))))
            (buffer-local buf 'test-browser-backends))))))

(define (tb--here)
  "the listing and the row at point, from the listing or a detail"
  (let* ((cur (current-buffer)) (listing (buffer-local cur 'test-browser-listing)))
    (if listing
        (cons listing (buffer-local cur 'test-browser-row))
        (cons cur (list-current cur)))))

(define-command "test-browser-run" "Run the test, group or file at point"
  (lambda () (let ((h (tb--here))) (test-browser-run! (car h) (cdr h)))))

(define-command "test-browser-run-all" "Run every test of the project"
  (lambda () (test-browser-run! (car (tb--here)) #f)))

(define-command "test-browser-run-failed" "Run again the tests that failed last time"
  (lambda ()
    (let* ((buf (car (tb--here)))
           (failed (filter (lambda (t) (memq (tb--status buf t) '(fail error)))
                           (tb--tests-under (tb--all-rows buf) #f))))
      (if (null? failed)
          (message "test-browser: nothing failed")
          (for-each (lambda (t) (test-browser-run! buf t)) failed)))))

(define-command "test-browser-visit" "Open the source of the row at point in the other window"
  (lambda ()
    (let ((row (cdr (tb--here))))
      (when row
        (let ((b (find-file-other-window! (plist-get row 'path))))
          (when b
            (buffer-goto-line! b (plist-get row 'line))
            (buffer-windows-follow-point! b)))))))

(define-command "test-browser-show" "Show the row at point beside the list"
  (lambda () (let ((h (tb--here))) (test-browser-show-detail! (car h) (cdr h)))))

(define-command "test-browser-refresh" "Read the test tree again"
  (lambda () (tb--discover! (car (tb--here)))))

(define-list-mode! "test-browser-mode"
  (list
    'doc (string-append
           "A project's tests as a tree: files, their groups and tests, each with its last result "
           "(✓ pass, ✗ fail, ! error, - skipped, … running, ◐ partly run, · not run). "
           "Moving the point shows the row's source and output beside the list, and RET shows it too. "
           "r runs the test, group or file at point, R runs everything, F runs the failures again. "
           "o opens the source in the other window. / narrows the rows; is:fail keeps the failures. "
           "g reads the tree again, and q quits.")
    'transient #f
    'rows tb--rows
    'key (lambda (buf row) (plist-get row 'id))
    'no-marks #t
    'columns (lambda (buf) (list (list "" 2) (list "test" #f) (list "time" 9 'right)))
    'cells tb--cells
    'filters (list (list "is:" (lambda (buf row) (symbol->string (tb--status buf row))) "status"))
    'preview (lambda (buf row) (test-browser-show-detail! buf row))
    'title (lambda (buf) (string-append "Tests: " (file-name-nondirectory (or (tb--root buf) ""))))
    'total (lambda (buf) (length (tb--tests-under (tb--all-rows buf) #f)))
    'noun "row"
    'footer (lambda (buf)
              '(("r" "run") ("R" "run all") ("F" "failed") ("o" "source")
                ("/" "filter") ("g" "reread") ("q" "quit")))
    'keys '(("RET" "test-browser-show") ("r" "test-browser-run") ("R" "test-browser-run-all")
            ("F" "test-browser-run-failed") ("o" "test-browser-visit") ("g" "test-browser-refresh")
            ("q" "quit-window"))))

(define-mode "test-browser-detail-mode" (lambda () #t))

(mode-keys! "test-browser-detail-mode"
  '(("r" "test-browser-run") ("R" "test-browser-run-all") ("F" "test-browser-run-failed")
    ("o" "test-browser-visit") ("q" "quit-window")))

(mode-doc! "test-browser-detail-mode"
  "One row of the test browser: its status, source and last output. r runs it, R runs everything, F runs the failures again, o opens the source, q quits.")

(define (tb--strip-slash p)
  (if (string-suffix? "/" p) (substring p 0 (- (string-length p) 1)) p))

(define-command "test-browser" "Browse and run the tests of this project"
  (lambda ()
    (app-open! (test-browser-open! (tb--strip-slash (git-root (default-directory)))))))

(effects! '(write))
(public! 'test-browser-define-backend!
  "(test-browser-define-backend! NAME SPEC) — teach the test browser a kind of project: 'detect, 'files, 'discover and 'run")
(public! 'test-browser-open!
  "(test-browser-open! ROOT) — the test listing of ROOT, made and filled; shows nothing")
(effects! '(write execute))
(public! 'test-browser-run!
  "(test-browser-run! LISTING ROW) — run the tests ROW stands for, #f for all, and record each result")
(effects! '(write display))
(public! 'test-browser-show-detail!
  "(test-browser-show-detail! LISTING ROW) — show ROW's source and last result beside the listing")
