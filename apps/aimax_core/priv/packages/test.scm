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
      (unless (buffer-exists? buf) (buffer-create buf))
      (buffer-set-text! buf
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
(public! 'load-tests! "(load-tests!) — load every .scm under priv/tests; answers the test count")

(message "test.scm loaded")
