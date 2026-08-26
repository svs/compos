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

(deftest 'display-and-history-have-unambiguous-buffer-recipes
  "display targets another window; switching targets buffer history"
  (lambda ()
    (check-equal! (cadr (assoc "show a buffer in the other window" *recipes*))
                  "(display-buffer-other-window! {{buffer}})" "the display recipe")
    (check-equal! (cadr (assoc "other buffer" *recipes*))
                  "(display-buffer-other-window! {{buffer}})" "the common phrase")
    (check-equal! (cadr (assoc "switch to the previous buffer" *recipes*))
                  "(run-command \"previous-buffer\")" "the history recipe")))

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
