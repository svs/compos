;;; scheme-ide-test.scm --- packages/scheme-ide.scm: the editor answering
;;; for its own dialect.
;;;
;;; Where a name is defined, and whether the checker is quiet, are Scheme.
;;; The rest of the file stays in ExUnit: M-. and C-c C-d write to the
;;; echo area and C-M-i opens the completion dropdown, and both are render
;;; state that Scheme cannot read.

(domain! 'testing)
(effects! '(read))

(deftest 'find-def-reaches-the-bundled-source-and-every-catalogued-package
  "one lookup covers editor.scm and the packages beside it"
  (lambda ()
    (check-contains! (cadr (scheme-ide--find-def "kill-region-1")) "editor.scm"
                     "a name defined in the stdlib")
    (check-contains! (cadr (scheme-ide--find-def "paredit-in-scheme-mode")) "paredit.scm"
                     "a name defined in a package")
    (check-false! (scheme-ide--find-def "zz-no-such-name-9x9") "and an unknown name")))

(effects! '(write))

(deftest 'the-squiggle-check-is-quiet-without-the-scheme-grammar
  "an ERROR node needs the grammar; without it the check adds no overlay"
  (lambda ()
    (let ((buf "*zz-scheme-ide*"))
      (test-buffer! buf "(unbalanced\n")
      (switch-to-buffer! buf)
      (set-mode! "scheme-mode")
      (scheme-ide--check! buf)
      (check-false! (pair? (filter (lambda (o) (equal? (nth 2 o) "scheme-err"))
                                   (buffer-overlays buf)))
                    "no error overlay")
      (buffer-kill! buf))))
