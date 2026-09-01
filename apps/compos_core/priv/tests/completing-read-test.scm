;;; completing-read-test.scm --- one matcher, completing-read, history, capf.

(domain! 'testing)
(effects! '(write))

(define *cr-test-got* #f)
(define *cr-test-cancelled* #f)
(define (cr-test-k v) (set! *cr-test-got* v))

(define (cr-test-reset!)
  (set! *cr-test-got* #f)
  (set! *cr-test-cancelled* #f)
  (when (minibuffer-active?) (minibuffer-detach!)))

(deftest 'completion-match-has-the-styles-and-never-raises-on-a-paren
  "flex, substring, prefix, regexp, exact; a bad regexp is no match"
  (lambda ()
    (check-true! (completion-match? "foobar" "fbr") "flex: a subsequence")
    (check-false! (completion-match? "foobar" "fbr" 'substring) "substring: not a subsequence")
    (check-true! (completion-match? "foobar" "oob" 'substring) "substring: yes")
    (check-true! (completion-match? "Foobar" "foo" 'prefix) "prefix, case-insensitive")
    (check-false! (completion-match? "Foobar" "oob" 'prefix) "prefix: not inside")
    (check-true! (completion-match? "*scratch*" "*scr") "flex: a star is a character")
    (check-true! (completion-match? "foo(" "(") "flex: a paren is a character")
    (check-true! (completion-match? "foobar" "fo+b" 'regexp) "regexp: a pattern")
    (check-false! (completion-match? "x" "(" 'regexp) "regexp: a bad pattern matches nothing")
    (check-true! (completion-match? "abc" "abc" 'exact) "exact")
    (check-false! (completion-match? "abcd" "abc" 'exact) "exact: no prefix")
    (check-equal! (regexp-quote "a.b") "a\\.b" "regexp-quote escapes")))

(deftest 'completing-read-honours-require-match-default-and-history
  "free text is refused, an empty answer is the default, the answer goes on the history"
  (lambda ()
    (cr-test-reset!)
    (completing-read "Pick: " '("alpha" "beta") cr-test-k
      'require-match #t 'default "beta" 'history 'zz-cr-test-hist)
    (check-true! (minibuffer-active?) "the prompt is up")
    (minibuffer-input! "zzz")
    (run-command "minibuffer-confirm-input")
    (check-false! *cr-test-got* "free text did not answer")
    (check-true! (minibuffer-active?) "and the prompt asks again")
    (minibuffer-input! "")
    (run-command "minibuffer-confirm-input")
    (check-equal! *cr-test-got* "beta" "an empty answer is the default")
    (check-equal! (car (history-items 'zz-cr-test-hist)) "beta" "the answer went on the history")))

(deftest 'm-p-walks-the-history-and-m-n-comes-back
  "the previous answer fills the input; forward past the newest restores what was typed"
  (lambda ()
    (cr-test-reset!)
    (history-push! 'zz-cr-test-hist "older")
    (history-push! 'zz-cr-test-hist "newest")
    (completing-read "Pick: " '() cr-test-k 'history 'zz-cr-test-hist)
    (minibuffer-input! "typed")
    (run-command "previous-history-element")
    (check-equal! (minibuffer-input) "newest" "M-p: the newest item")
    (run-command "previous-history-element")
    (check-equal! (minibuffer-input) "older" "M-p again: the one before")
    (run-command "next-history-element")
    (run-command "next-history-element")
    (check-equal! (minibuffer-input) "typed" "M-n past the newest: what was typed")
    (minibuffer-cancel!)))

(deftest 'a-second-prompt-cancels-the-first-instead-of-losing-it
  "the outer prompt's cancel handler runs, and the new prompt is the one up"
  (lambda ()
    (cr-test-reset!)
    (minibuffer-read* "Outer: " '()
      (list (list 'confirm cr-test-k)
            (list 'cancel (lambda () (set! *cr-test-cancelled* #t)))))
    (minibuffer-read "Inner: " '() cr-test-k)
    (check-true! *cr-test-cancelled* "the outer prompt was cancelled, not dropped")
    (check-equal! (plist-get (minibuffer-state) 'prompt) "Inner: " "the inner prompt is up")
    (minibuffer-cancel!)))

(deftest 'a-predicate-and-a-dynamic-collection-shape-the-candidates
  "the collection is a procedure of the input, and the predicate keeps some rows"
  (lambda ()
    (cr-test-reset!)
    (completing-read "Pick: " (lambda (input) (list "aa" "ab" "zz")) cr-test-k
      'predicate (lambda (label) (not (equal? label "zz"))))
    (check-equal! (plist-get (minibuffer-state) 'total) 2 "two of three rows")
    (minibuffer-cancel!)))

(deftest 'capf-collect-honours-exclusive-no-and-the-default
  "a source with nothing and exclusive no yields; a plain empty answer ends the search"
  (lambda ()
    (check-equal! (capf-collect (list (lambda () (list 0 0 '() 'exclusive 'no))
                                      (lambda () (list 0 0 '("x")))))
                  '(0 0 ("x")) "the second source answered")
    (check-equal! (capf-collect (list (lambda () (list 0 0 '()))
                                      (lambda () (list 0 0 '("x")))))
                  '(0 0 ()) "an exclusive source with nothing ends the search")
    (check-equal! (capf-collect (list (lambda () #f))) #f "no source, no answer")))

(deftest 'accepting-a-completion-replaces-start-to-end-not-start-to-point
  "END past point: the suffix goes too"
  (lambda ()
    (let ((buf (test-buffer! "zz-cr-test-buf" "foobar")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (goto-char! 2)
      (completion-show! 0 6 '("foobaz"))
      (run-command "completion-accept")
      (check-equal! (buffer-text buf) "foobaz" "the whole word was replaced")
      (buffer-kill! buf))))
