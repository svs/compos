;;; paredit-scan-test.scm --- the paredit scanner, on strings.
;;;
;;; par-scan-forward, par-scan-backward, par-up and par-close take text
;;; and an offset and answer an offset. No buffer, no keys, no window.
;;;
;;; The 37 tests that press a key stay in ExUnit: paredit IS the key
;;; behaviour, and that path is what the GUI uses.

(domain! 'testing)
(effects! '(read))

(deftest 'par-scan-forward-walks-lists-atoms-strings-and-char-literals
  "one datum forward, whatever kind it is"
  (lambda ()
    (check-equal! (par-scan-forward "(foo bar) baz" 0) 9 "over a list")
    (check-equal! (par-scan-forward "(foo bar) baz" 9) 13 "over an atom")
    (check-equal! (par-scan-forward "'(a b) c" 0) 6 "a quote goes with its datum")
    (check-equal! (par-scan-forward "\"a\\\"b\" c" 0) 6 "an escape does not end the string")
    (check-equal! (par-scan-forward "#\\( x" 0) 3 "a char literal is not an opener")
    (check-equal! (par-scan-forward "; c\nfoo" 0) 7 "a comment is skipped, not scanned")
    (check-equal! (par-scan-forward "#|x (|# foo" 0) 11 "and so is a block comment")))

(deftest 'par-scan-forward-answers-false-at-a-closer-or-at-end-of-text
  "there is no next datum, and saying so is the answer"
  (lambda ()
    (check-false! (par-scan-forward "(a) " 3) "at the end of the text")
    (check-false! (par-scan-forward "(a b)" 4) "at a closer")))

(deftest 'par-scan-backward-finds-the-previous-sibling-start
  "backward is not forward run in reverse: it answers a start"
  (lambda ()
    (check-equal! (par-scan-backward "(a bb)" 5) 3 "the previous atom")
    (check-equal! (par-scan-backward "(a bb)" 3) 1 "and the one before it")
    (check-false! (par-scan-backward "(a bb)" 1) "the first has none")
    (check-equal! (par-scan-backward "(a) (b) x" 8) 4 "over a whole list")))

(deftest 'par-up-and-par-close-see-the-enclosing-list
  "through strings and comments, which hold delimiters that are not"
  (lambda ()
    (check-equal! (par-up "(a (b c) d)" 5) 3 "the inner opener")
    (check-equal! (par-up "(a (b c) d)" 2) 0 "the outer one")
    (check-false! (par-up "x y" 2) "no enclosing list")
    (check-equal! (par-close "(a (b c) d)" 5) 7 "the matching closer")
    (check-equal! (par-up "(a \"))\" b)" 8) 0 "closers in a string do not count")
    (check-equal! (par-close "(a ;)\n b)" 3) 8 "nor one in a comment")))

(effects! '(write))

(deftest 'the-paredit-keys-pass-through-without-the-mode
  "the dispatcher commands are global; only a local map reaches them"
  (lambda ()
    ;; a plain buffer binds nothing, so the keys keep their defaults
    (let ((buf (test-buffer! "zz-paredit-plain" "(a)\n")))
      (check-equal! (local-keys buf) '() "the buffer's own map is empty")
      (buffer-kill! buf))))
