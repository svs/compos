;;; recipes-test.scm --- the recipe book the palette reads.
;;;
;;; A recipe is a task, a line to run, and the inputs that line needs. A
;;; templated line with no declared inputs prompts for nothing and runs
;;; with the braces still in it.
;;;
;;; Seven palette tests stay in ExUnit: five press keys, and two wait for
;;; a debounce to fire, which Scheme cannot do.

(domain! 'testing)
(effects! '(read))

(deftest 'other-buffer-maps-to-the-previous-buffer-command
  "the words a person says, and the call that answers them"
  (lambda ()
    (check-equal! (cadr (assoc "other buffer" *recipes*))
                  "(run-command \"previous-buffer\")" "the recipe line")))

(deftest 'no-templated-recipe-is-missing-its-input-declarations
  "a line with braces and no inputs runs with the braces still in it"
  (lambda ()
    (check-equal!
      (map car (filter (lambda (recipe)
                         (and (string-contains? (cadr recipe) "{{")
                              (null? (caddr recipe))))
                       *recipes*))
      '() "every templated recipe declares its inputs")
    ;; and no recipe ships a path from the machine it was written on
    (check-false! (string-contains? (value->string (recipes)) "/abs/path")
                  "no absolute path leaked into the book")))
