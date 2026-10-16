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

;;; --- tests that need a disposable editor ---------------------------------------
;;; Some packages own fixed global buffer names: notmuch's index is
;;; *notmuch* and its message view is *mail*, in a test and in a person's
;;; editor alike. A test of those must reset them, and resetting them in a
;;; live editor throws away real work. It happened: a notmuch test killed a
;;; live *mail*, *notmuch* and the chat beside them.
;;;
;;; Such a file says so at the top, and the suite refuses to run it unless
;;; the editor is a throwaway one.

(define *test-file-needs-disposable* #f)
(define *disposable-only-tests* '())

;; The test env and COMPOS_VERIFY both put the home under /tmp; a person's
;; editor keeps it in ~/.compos. Nothing else distinguishes them, and
;; guessing wrong in this direction destroys buffers.
(define (editor-is-disposable?) (string-prefix? "/tmp/" (compos-home)))

(define (tests-need-a-disposable-editor! why)
  (set! *test-file-needs-disposable* why)
  why)

(define (test-needs-disposable? name) (assoc name *disposable-only-tests*))

;; what run-scheme-tests may run HERE
(define (test-names-here)
  (if (editor-is-disposable?)
      (test-names)
      (remove test-needs-disposable? (test-names))))

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
  (when *test-file-needs-disposable*
    (set! *disposable-only-tests*
      (cons (list name *test-file-needs-disposable*) *disposable-only-tests*)))
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
  (catalog-forget! (string->symbol kind) name))
;;; --- fixtures ----------------------------------------------------------------
;;; A test that changes shared state puts it back, also when a check raises
;;; half way: the next test reads the same globals, and the live editor
;;; reaches the world through them. Each fixture wraps THUNK in
;;; unwind-protect, so the undo runs on an error too and the error goes on.

;; NAME is a global, quoted; VALUE replaces it for the thunk. A name that
;; had no binding is unbound again after.
(define (with-stub name value thunk)
  (let ((bound (boundp name))
        (old (and (boundp name) (symbol-value name))))
    (set-symbol-value! name value)
    (unwind-protect thunk
      (lambda ()
        (if bound (set-symbol-value! name old) (unbind-global! name))))))

;; PAIRS is ((NAME VALUE) ...), each as with-stub takes them
(define (with-stubs pairs thunk)
  (if (null? pairs)
      (thunk)
      (with-stub (car (car pairs)) (cadr (car pairs))
        (lambda () (with-stubs (cdr pairs) thunk)))))

;; a customize variable: the setter runs on the way in and on the way out,
;; so a setting with side effects undoes them too
(define (with-custom name value thunk)
  (let ((old (symbol-value name)))
    (customize-set! name value)
    (unwind-protect thunk (lambda () (customize-set! name old)))))

(define (with-customs pairs thunk)
  (if (null? pairs)
      (thunk)
      (with-custom (car (car pairs)) (cadr (car pairs))
        (lambda () (with-customs (cdr pairs) thunk)))))

;; a group record NAME that no earlier run left behind; FN gets its id, and
;; the record goes when FN returns, even when FN dissolved it already
(define (with-fresh-group name fn)
  (let ((stale (group-resolve-id name)))
    (when stale (group-record-delete! stale)))
  (let ((id (group-record-create! name)))
    (unwind-protect (lambda () (fn id))
      (lambda () (group-record-delete! id)))))

;; a frame of the test's own, selected while FN runs with its id; the
;; frame the test stood in is selected again after, and the new one goes
(define (with-frame fn)
  (let ((home (selected-frame))
        (frame (make-frame!)))
    (select-frame! frame)
    (unwind-protect (lambda () (fn frame))
      (lambda ()
        (select-frame! home)
        (delete-frame! frame)))))

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
    (cond
      ((not t) (list (string-append "no such test: " (symbol->string name))))
      ;; the guard sits HERE, not only in the listing: a person who runs
      ;; one test by hand must not lose their buffers to it either
      ((and (test-needs-disposable? name) (not (editor-is-disposable?)))
       (list (string-append (symbol->string name)
                            " needs a disposable editor — it "
                            (cadr (test-needs-disposable? name))
                            ". Run it with mix test.")))
      (else
        (begin
          (set! *test-failures* '())
          ((car (cdr (cdr t))))
          (let ((out *test-failures*))
            (set! *test-failures* '())
            out))))))

;; Two suites, as in Emacs. The kernel's tests live in priv/tests. A
;; package's tests live beside it: scheme/packages/NAME-test.scm, or
;; NAME-test.scm inside a package's own directory. The kernel run does not
;; load the package tests; `run-package-tests' and the package run of
;; mix test do. The package loader never reaches a test file: a test is
;; not a package, and the catalog should not carry one.
(define (test-dir) (string-append (compos-priv-dir) "/tests"))

(define (test-files--in dir pred)
  (map (lambda (name) (string-append dir "/" name))
       (filter pred (if (file-exists? dir) (list-dir dir) '()))))

(define (test-file? name) (string-suffix? "-test.scm" name))

(define (package-test-dir)
  (let ((root (compos-project-dir)))
    (and root (string-append root "/scheme/packages"))))

;; KIND is 'core or 'packages
(define (test-files kind)
  (if (equal? kind 'core)
      (test-files--in (test-dir) (lambda (n) (string-suffix? ".scm" n)))
      (let ((dir (package-test-dir)))
        (if (not dir)
            '()
            (append
              (test-files--in dir test-file?)
              (apply append
                (map (lambda (sub) (test-files--in (string-append dir "/" sub) test-file?))
                     (filter (lambda (n) (file-directory? (string-append dir "/" n)))
                             (list-dir dir)))))))))

(define (load-test-files! files)
  (for-each
    (lambda (path)
      ;; the declaration is per file, so it must not leak to the next
      (set! *test-file-needs-disposable* #f)
      (load path))
    files)
  (set! *test-file-needs-disposable* #f)
  (length *tests*))

;; the names each suite registered, so each command runs its own
(defvar '*core-test-names* '())
(defvar '*package-test-names* '())

(define (load-test-files--names! files)
  (let ((before (test-names)))
    (load-test-files! files)
    (filter (lambda (n) (not (member n before))) (test-names))))

(define (load-tests!)
  (set! *disposable-only-tests* '())
  (set! *core-test-names* (load-test-files--names! (test-files 'core)))
  (length *tests*))

(define (package-test-names) *package-test-names*)

(define (load-package-tests!)
  (set! *package-test-names* (load-test-files--names! (test-files 'packages)))
  (length *tests*))

;; The suite is 124 files. Loading it costs most of an eval's heap budget, so
;; an eval that loads AND runs a test passed the 1024 MB limit and died. This
;; loads once per daemon: the first caller pays, every caller after it pays
;; nothing, and the run has the whole budget to itself.
(defvar '*tests-loaded* #f)

(define (load-tests-once!)
  (unless *tests-loaded*
    (load-tests!)
    (set! *tests-loaded* #t))
  (length *tests*))

(defvar '*package-tests-loaded* #f)

(define (load-package-tests-once!)
  (unless *package-tests-loaded*
    (load-package-tests!)
    (set! *package-tests-loaded* #t))
  (length *tests*))

;; A reload of a test file must be visible to the next run.
(define (reload-tests!)
  (set! *tests-loaded* #f)
  (load-tests-once!))

(define (run-tests--report! names skipped)
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
      names)
    (test-buffer! buf
      (string-append
        (number->string (length names)) " tests, "
        (number->string failed) " failing"
        (if (> skipped 0)
            (string-append ", " (number->string skipped)
                           " skipped — they reset buffer names this editor uses;"
                           " run them with mix test")
            "")
        "\n\n"
        (string-join lines "\n") "\n"))
    (display-buffer buf)
    (message (string-append (number->string failed) " failing"))))

(define-command "run-scheme-tests"
  "Run the kernel's Scheme tests and report them in *test-results*"
  (lambda ()
    (load-tests-once!)
    (let* ((here (test-names-here))
           (names (filter (lambda (n) (member n here)) *core-test-names*)))
      (run-tests--report! names (- (length *core-test-names*) (length names))))))

(define-command "run-package-tests"
  "Run the tests that live beside the packages and report them in *test-results*"
  (lambda ()
    (load-package-tests-once!)
    (let* ((here (test-names-here))
           (names (filter (lambda (n) (member n here)) *package-test-names*)))
      (run-tests--report! names (- (length *package-test-names*) (length names))))))

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
(public! 'test-names-here
  "(test-names-here) — the tests this editor may run; a live one skips those needing a disposable editor")
(public! 'tests-need-a-disposable-editor!
  "(tests-need-a-disposable-editor! WHY) — declare that this file's tests reset shared buffer names")
(public! 'editor-is-disposable?
  "(editor-is-disposable?) — #t when the home is a throwaway one, so a test may reset shared names")
(public! 'run-test "(run-test 'name) — run one test; () means it passed")
(public! 'test-buffer!
  "(test-buffer! NAME TEXT) — make or empty a buffer and give it TEXT; answers NAME")
(public! 'test-self-check
  "(test-self-check) — prove the checks can fail; answers the failures three bad assertions record")
(public! 'test-forget-catalog!
  "(test-forget-catalog! KIND NAME) — drop a test's catalog entry; the M-x name stays until a restart")
(public! 'with-stub
  "(with-stub 'NAME VALUE THUNK) — run THUNK with the global NAME set to VALUE; the old value comes back after, also on an error")
(public! 'with-stubs
  "(with-stubs ((NAME VALUE) ...) THUNK) — with-stub for several globals at once")
(public! 'with-custom
  "(with-custom 'NAME VALUE THUNK) — run THUNK with the customize variable NAME set to VALUE through its setter; the old value comes back after, also on an error")
(public! 'with-customs
  "(with-customs ((NAME VALUE) ...) THUNK) — with-custom for several settings at once")
(public! 'with-fresh-group
  "(with-fresh-group NAME FN) — make a group record NAME, stale copies deleted first, and call (FN ID); the record goes after, also on an error")
(public! 'with-frame
  "(with-frame FN) — make and select a frame, call (FN ID), then come back to the old frame and delete the new one, also on an error")
(public! 'load-tests-once! "(load-tests-once!) — load every test file the first time only; answers the test count")
(public! 'reload-tests! "(reload-tests!) — forget the loaded kernel suite and read priv/tests again")
(public! 'load-tests! "(load-tests!) — load the kernel's tests, every .scm under priv/tests; answers the test count")
(public! 'load-package-tests-once! "(load-package-tests-once!) — load the package tests (scheme/packages/**/NAME-test.scm) the first time only")
(public! 'package-test-names "(package-test-names) — the names the package tests registered")
(public! 'test-files "(test-files KIND) — the test files of KIND, 'core (priv/tests) or 'packages (beside each package)")

(message "test.scm loaded")
