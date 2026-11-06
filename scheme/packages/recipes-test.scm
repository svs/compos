;;; recipes-test.scm --- a pattern reads the command and its arguments.

(domain! 'testing)
(effects! '(write))

(deftest 'recipe-pattern-reads-arguments
  "the literal words pick the recipe, the slots take the rest"
  (lambda ()
    (check-equal! (recipe--match-words '("open" "{{path}}") '("Open" "my" "notes.md"))
                  '((path "my notes.md"))
                  "the last slot takes every word left")
    (check-equal! (recipe--match-words '("make" "{{face}}" "{{color}}") '("make" "default" "red"))
                  '((face "default") (color "red"))
                  "an earlier slot takes the fewest words")
    (check-false! (recipe--match-words '("open" "{{path}}") '("open"))
                  "a slot takes one word at least")
    (check-false! (recipe--match-words '("close" "{{b}}") '("open" "x"))
                  "a literal word must be there")
    (check-equal! (recipe--match-tail '("{{count}}" "columns") '("switch" "to" "2" "columns"))
                  '((count "2"))
                  "a pattern that opens with a slot reads the end of the words")))

(deftest 'recipe-match-picks-the-most-literal-pattern
  "open folder x is the directory, not a file named folder x"
  (lambda ()
    (check-equal! (car (recipe-match "open folder src")) "open a directory" "two literals beat one")
    (check-equal! (recipe-match "dired src") '("open a directory" ((path "src"))) "one literal")
    (check-false! (recipe-match "qqzz nothing") "no pattern, no recipe")))
