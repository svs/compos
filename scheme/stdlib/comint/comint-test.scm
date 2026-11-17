;;; comint-test.scm --- the environment a terminal gives its shell.

(deftest 'a-terminal-exports-the-environment-the-functions-give
  "each function in term-environment-functions adds variables, and the shell exports them quoted"
  (lambda ()
    (test-buffer! "*zz-term-env*" "")
    (add-hook! '(term-environment-functions zz-test)
      (lambda (buf) (list (list "ZZ_TERM_NAME" buf))))
    (let ((prefix (term--export-prefix "*zz-term-env*")))
      (check-true! (string-prefix? "export " prefix) "the shell exports")
      (check-true! (string-contains? prefix (string-append "ZZ_TERM_NAME=" (sh-quote "*zz-term-env*")))
                   "the value of each function, quoted"))
    (remove-hook! '(term-environment-functions zz-test) #f)
    (check-false! (assoc "ZZ_TERM_NAME" (term-environment "*zz-term-env*"))
                  "a removed function adds nothing")
    (buffer-kill! "*zz-term-env*")))
