;;; hook-test.scm --- hooks are named lists: once, ordered, local, with args.

(domain! 'testing)
(effects! '(write))

(define *hook-test-log* '())
(define (hook-test-log! x) (set! *hook-test-log* (cons x *hook-test-log*)))
(define (hook-test-reset!) (set! *hook-test-log* '()))

(define (hook-test-one) (hook-test-log! 'one))
(define (hook-test-two) (hook-test-log! 'two))
(define (hook-test-args a b) (hook-test-log! (list a b)))
(define (hook-test-one-arg x) (hook-test-log! x))
(define (hook-test-no x) #f)
(define (hook-test-yes x) (list 'yes x))

(define (hook-test-clear! hook)
  (for-each (lambda (f) (remove-hook! hook f)) (hook-functions hook))
  (for-each (lambda (f) (remove-hook! hook f #t)) (hook-functions hook)))

(deftest 'a-named-function-joins-a-hook-once
  "adding the same name twice leaves one entry; remove-hook! takes it off"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook 'hook-test-one)
    (add-hook! 'hook-test-hook 'hook-test-one)
    (check-equal! (hook-functions 'hook-test-hook) '(hook-test-one) "one entry")
    (hook-test-reset!)
    (run-hooks 'hook-test-hook)
    (check-equal! *hook-test-log* '(one) "ran once")
    (remove-hook! 'hook-test-hook 'hook-test-one)
    (check-equal! (hook-functions 'hook-test-hook) '() "gone")))

(deftest 'a-name-resolves-when-the-hook-runs
  "redefining the function after add-hook! changes what the hook runs"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook 'hook-test-late)
    (set-symbol-value! 'hook-test-late (lambda () (hook-test-log! 'first)))
    (hook-test-reset!)
    (run-hooks 'hook-test-hook)
    (set-symbol-value! 'hook-test-late (lambda () (hook-test-log! 'second)))
    (run-hooks 'hook-test-hook)
    (check-equal! *hook-test-log* '(second first) "the new definition ran the second time")
    (hook-test-clear! 'hook-test-hook)))

(deftest 'append-puts-a-function-last
  "the default prepends, APPEND appends"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook 'hook-test-one)
    (add-hook! 'hook-test-hook 'hook-test-two #t)
    (check-equal! (hook-functions 'hook-test-hook) '(hook-test-one hook-test-two) "appended")
    (hook-test-reset!)
    (run-hooks 'hook-test-hook)
    (check-equal! (reverse *hook-test-log*) '(one two) "ran in that order")
    (hook-test-clear! 'hook-test-hook)))

(deftest 'a-local-hook-runs-before-the-global-one-in-its-buffer-only
  "LOCAL puts the function on the current buffer; another buffer does not see it"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (let ((a (buffer-create "*hook-test-a*"))
          (b (buffer-create "*hook-test-b*")))
      (add-hook! 'hook-test-hook 'hook-test-two)
      (with-current-buffer a
        (lambda ()
          (add-hook! 'hook-test-hook 'hook-test-one #f #t)
          (check-equal! (hook-functions 'hook-test-hook) '(hook-test-one hook-test-two)
                        "local first, then global")
          (hook-test-reset!)
          (run-hooks 'hook-test-hook)
          (check-equal! (reverse *hook-test-log*) '(one two) "both ran, local first")))
      (with-current-buffer b
        (lambda ()
          (check-equal! (hook-functions 'hook-test-hook) '(hook-test-two) "b sees the global only")
          (hook-test-reset!)
          (run-hooks 'hook-test-hook)
          (check-equal! *hook-test-log* '(two) "only the global ran")))
      (with-current-buffer a
        (lambda () (remove-hook! 'hook-test-hook 'hook-test-one #t)))
      (buffer-kill! a)
      (buffer-kill! b))
    (hook-test-clear! 'hook-test-hook)))

(deftest 'run-hook-with-args-carries-the-arguments
  "an abnormal hook gets the arguments"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook 'hook-test-args)
    (hook-test-reset!)
    (run-hook-with-args 'hook-test-hook 1 2)
    (check-equal! *hook-test-log* '((1 2)) "got both")
    (hook-test-clear! 'hook-test-hook)))

(deftest 'until-success-stops-at-the-first-true-answer
  "the value of the first function that answers is the value of the run"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook 'hook-test-no)
    (add-hook! 'hook-test-hook 'hook-test-yes #t)
    (add-hook! 'hook-test-hook 'hook-test-args #t)
    (hook-test-reset!)
    (check-equal! (run-hook-with-args-until-success 'hook-test-hook 'x) '(yes x) "the first true value")
    (check-equal! *hook-test-log* '() "the function after it did not run")
    (check-equal! (run-hook-with-args-until-failure 'hook-test-hook 'x) #f "one said no")
    (hook-test-clear! 'hook-test-hook)))

(deftest 'a-closure-joins-a-hook-and-an-unbound-name-runs-nothing
  "a closure works as before; a name with no definition is skipped"
  (lambda ()
    (hook-test-clear! 'hook-test-hook)
    (add-hook! 'hook-test-hook (lambda () (hook-test-log! 'closure)))
    (add-hook! 'hook-test-hook 'hook-test-never-defined)
    (hook-test-reset!)
    (run-hooks 'hook-test-hook)
    (check-equal! *hook-test-log* '(closure) "the closure ran, the unbound name did not raise")
    (hook-test-clear! 'hook-test-hook)))

(deftest 'the-editor-seams-are-named-hooks
  "the buffer seams and fs-change run through add-hook! now"
  (lambda ()
    (add-hook! 'buffer-created-hook 'hook-test-one-arg)
    (hook-test-reset!)
    (buffer-created! "*hook-test-x*")
    (remove-hook! 'buffer-created-hook 'hook-test-one-arg)
    (check-true! (pair? *hook-test-log*) "buffer-created! ran the hook")))
