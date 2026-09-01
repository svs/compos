;;; variable-test.scm --- a default value and a buffer-local value.

(domain! 'testing)
(effects! '(write))

(deftest 'defvar-sets-a-default-once-and-defvar-local-writes-locally
  "the default, the local, and which one variable-set! chooses"
  (lambda ()
    (defvar 'zz-var-plain 1 "a test variable")
    (defvar 'zz-var-plain 2)
    (check-equal! (default-value 'zz-var-plain) 1 "a second defvar keeps the value")
    (check-equal! (variable-doc 'zz-var-plain) "a test variable" "the doc is kept")
    (defvar-local 'zz-var-local 10)
    (let ((a (test-buffer! "zz-var-a" "x")) (b (test-buffer! "zz-var-b" "y")))
      (with-current-buffer a
        (lambda ()
          (check-equal! (variable-value 'zz-var-local) 10 "no local yet: the default")
          (check-false! (local-variable-p 'zz-var-local) "and it is not local")
          (variable-set! 'zz-var-local 11)
          (check-equal! (variable-value 'zz-var-local) 11 "variable-set! wrote the buffer's own")
          (check-true! (local-variable-p 'zz-var-local) "now it is local")
          (check-equal! (default-value 'zz-var-local) 10 "the default did not move")))
      (with-current-buffer b
        (lambda ()
          (check-equal! (variable-value 'zz-var-local) 10 "another buffer reads the default")
          (variable-set! 'zz-var-plain 3)
          (check-equal! (default-value 'zz-var-plain) 3 "a plain variable is set globally")))
      (with-current-buffer a
        (lambda ()
          (kill-local-variable! 'zz-var-local)
          (check-equal! (variable-value 'zz-var-local) 10 "killing the local restores the default")))
      (buffer-kill! a)
      (buffer-kill! b))))
