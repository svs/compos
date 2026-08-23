;;; test.scm --- Scheme tests for Scheme policy.
;;;
;;; Most of what this editor decides is Scheme: membership, resolution,
;;; naming, matching, ranking. A test of that policy does not need a
;;; keystroke, a window, or a frame. It needs the function and a value.
;;;
;;; A test is a thunk under a name:
;;;
;;;   (deftest 'group-rename-keeps-the-id
;;;     "a rename moves the name and leaves the id alone"
;;;     (lambda ()
;;;       (let ((id (group-record-create! "t-a")))
;;;         (group-rename! id "t-b")
;;;         (check-equal! (group-name id) "t-b" "the name follows")
;;;         (check-equal! (group-resolve-id "t-b") id "the id is stable")
;;;         (group-record-delete! id))))
;;;
;;; A check records its failure and returns; it does not raise. One bad
;;; assertion reports every other assertion in the same test.
;;;
;;; (run-test 'name) answers () when the test passes, or a list of the
;;; failures it found. The ExUnit bridge runs one eval per test, so a
;;; test that raises fails alone and the rest still run.
;;;
;;; Keep a test hermetic: make what it needs, and delete it at the end.
;;; Tests share one live editor.

(domain! 'testing)
(effects! '(read))

(define *tests* '())

;; failures for the test running now. run-test owns it.
(define *test-failures* '())

(effects! '(write))

;; A test is not part of the editor's vocabulary, so it stays out of the
;; catalog: apropos answers what a person can call, and nobody calls a
;; test by hand. Re-registering a name replaces it, so a reload of a test
;; file does not double the suite.
(define (deftest name doc thunk)
  (set! *tests*
    (append (remove (lambda (t) (equal? (car t) name)) *tests*)
            (list (list name doc thunk))))
  name)

;; There is no buffer-set-text! primitive: replace the whole range.
(define (test-buffer! name text)
  (unless (buffer-exists? name) (buffer-create name))
  (buffer-delete-range! name 0 (buffer-size name))
  (when (and text (not (equal? text ""))) (buffer-insert! name 0 text))
  name)

;; A test that registers a name must take it out again. define-command,
;; public!, define-tool! and catalog-register! all write registries with
;; no removal call, so a test clears the Scheme half by hand. The M-x
;; command table is Elixir and has none, so that name stays until the next
;; restart.
(define (test-forget-catalog! kind name)
  (let ((e (catalog-entry (string->symbol kind) name)))
    (when e
      (set! *catalog-keys*
        (remove (lambda (k)
                  (equal? k (catalog--key kind name (plist-get e 'qualified-name))))
                *catalog-keys*))
      (set! *catalog*
        (remove (lambda (x) (and (equal? (plist-get x 'kind) kind)
                                 (equal? (plist-get x 'name) name)))
                *catalog*))))
  name)

(define (test-fail! text)
  (set! *test-failures* (append *test-failures* (list text))))

;; ACTUAL and EXPECTED print into the failure, because a test that only
;; says "not equal" makes the reader run it again to learn anything.
(define (check-equal! actual expected label)
  (if (equal? actual expected)
      #t
      (begin
        (test-fail!
          (string-append label
                         ": expected " (value->string expected)
                         ", got " (value->string actual)))
        #f)))

(define (check-true! value label)
  (if value
      #t
      (begin (test-fail! (string-append label ": expected a true value, got #f"))
             #f)))

(define (check-false! value label)
  (if value
      (begin (test-fail!
               (string-append label ": expected #f, got " (value->string value)))
             #f)
      #t))

(define (check-contains! haystack needle label)
  (if (and (string? haystack) (string-contains? haystack needle))
      #t
      (begin
        (test-fail!
          (string-append label ": " (value->string haystack)
                         " does not contain " (value->string needle)))
        #f)))

;; The harness must be able to fail. A check that recorded nothing, or a
;; run-test that always answered (), would let every test below pass
;; while proving nothing — and the bridge could not tell the difference.
;; This runs one assertion that must fail and one that must pass, and
;; answers what it recorded. Elixir asserts the shape, so the proof that
;; Scheme can report a failure does not itself rest on Scheme.
(define (test-self-check)
  (let ((saved *test-failures*))
    (set! *test-failures* '())
    (check-equal! 1 2 "canary-must-fail")
    (check-equal! 1 1 "canary-must-pass")
    (check-true! #f "canary-true-must-fail")
    (check-false! #t "canary-false-must-fail")
    (let ((out *test-failures*))
      (set! *test-failures* saved)
      out)))

(effects! '(read))

(define (test-names) (map car *tests*))

(define (test-doc name)
  (let ((t (assoc name *tests*)))
    (and t (car (cdr t)))))

(effects! '(write))

;; -> () when the test passes, else the failures it recorded
(define (run-test name)
  (let ((t (assoc name *tests*)))
    (if (not t)
        (list (string-append "no such test: " (symbol->string name)))
        (begin
          (set! *test-failures* '())
          ((car (cdr (cdr t))))
          (let ((out *test-failures*))
            (set! *test-failures* '())
            out)))))

;; Load every .scm under priv/tests. The package loader does not reach
;; them: a test is not a package, and the catalog should not carry one
;; unless somebody asked for it.
(define (test-dir) (string-append (aimax-priv-dir) "/tests"))

(define (load-tests!)
  (let ((dir (test-dir)))
    (for-each
      (lambda (name)
        (when (string-suffix? ".scm" name)
          (load (string-append dir "/" name))))
      (list-dir dir))
    (length *tests*)))

(define-command "run-scheme-tests"
  "Run the Scheme test suite and report it in *test-results*"
  (lambda ()
    (load-tests!)
    (let ((buf "*test-results*")
          (failed 0)
          (lines '()))
      (for-each
        (lambda (name)
          (let ((fs (run-test name)))
            (if (null? fs)
                (set! lines (append lines (list (string-append "  ok    "
                                                  (symbol->string name)))))
                (begin
                  (set! failed (+ failed 1))
                  (set! lines
                    (append lines
                      (list (string-append "  FAIL  " (symbol->string name)))
                      (map (lambda (f) (string-append "          " f)) fs)))))))
        (test-names))
      (test-buffer! buf
        (string-append
          (number->string (length (test-names))) " tests, "
          (number->string failed) " failing\n\n"
          (string-join lines "\n") "\n"))
      (display-buffer buf)
      (message (string-append (number->string failed) " failing")))))

(effects! '(read))

(public! 'deftest
  "(deftest 'name DOC THUNK) — register a Scheme test; the thunk calls the check- functions")
(public! 'check-equal!
  "(check-equal! ACTUAL EXPECTED LABEL) — record a failure unless the two are equal?")
(public! 'check-true! "(check-true! VALUE LABEL) — record a failure when VALUE is #f")
(public! 'check-false! "(check-false! VALUE LABEL) — record a failure unless VALUE is #f")
(public! 'check-contains!
  "(check-contains! HAYSTACK NEEDLE LABEL) — record a failure unless HAYSTACK holds NEEDLE")
(public! 'test-names "(test-names) — every registered test name")
(public! 'run-test "(run-test 'name) — run one test; () means it passed")
(public! 'test-buffer!
  "(test-buffer! NAME TEXT) — make or empty a buffer and give it TEXT; answers NAME")
(public! 'test-self-check
  "(test-self-check) — prove the checks can fail; answers the failures three bad assertions record")
(public! 'test-forget-catalog!
  "(test-forget-catalog! KIND NAME) — drop a test's catalog entry; the M-x name stays until a restart")
(public! 'load-tests! "(load-tests!) — load every .scm under priv/tests; answers the test count")

(message "test.scm loaded")
