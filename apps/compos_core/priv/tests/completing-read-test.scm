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

;;; --- completion while you type -------------------------------------------------

(deftest 'typing-offers-the-same-candidates-m-slash-would
  "capf-auto-fire! shows the popup, and accept replaces the range"
  (lambda ()
    (let ((buf (test-buffer! "zz-cr-auto-buf" "(display-buf")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (goto-char! (buffer-size buf))
      (buffer-set-local! buf 'capf-sources
        (list (lambda () (list 1 (point) '("display-buffer-other-window!")))))
      (completion-dismiss!)
      (capf-auto-fire! buf)
      (run-command "completion-accept")
      (check-equal! (buffer-text buf) "(display-buffer-other-window!"
                    "typing offered it and accept took it")
      (buffer-kill! buf))))

(deftest 'typing-never-asks-for-a-buffer-the-frame-left
  "completion-show! measures its range against the frame's buffer, so a popup for another buffer would cut the wrong file"
  (lambda ()
    (let ((away (test-buffer! "zz-cr-auto-away" "alphabet"))
          (here (test-buffer! "zz-cr-auto-here" "here")))
      (delete-other-windows!)
      (buffer-set-local! away 'capf-sources
        (list (lambda () (list 0 8 '("alphabetical")))))
      (switch-to-buffer! here)
      (completion-dismiss!)
      (capf-auto-fire! away)
      (check-false! (completion-accept!) "no popup for a buffer the frame left")
      (buffer-kill! away)
      (buffer-kill! here))))

(deftest 'typing-waits-for-completion-auto-prefix
  "one character is not an invitation"
  (lambda ()
    (let ((buf (test-buffer! "zz-cr-auto-short" "a")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (goto-char! (buffer-size buf))
      (buffer-set-local! buf 'capf-sources
        (list (lambda () (list (- (point) 1) (point) '("alpha")))))
      (completion-dismiss!)
      (capf-auto-fire! buf)
      (check-false! (completion-accept!) "one character is below completion-auto-prefix")
      (buffer-kill! buf))))

(deftest 'the-typing-watch-is-installed-once-per-buffer
  "a mode may re-enter; the buffer keeps one rule"
  (lambda ()
    (let ((buf (test-buffer! "zz-cr-auto-watch" "x")))
      (let ((id (capf-auto-watch! buf)))
        (check-true! (number? id) "the watch left its rule id")
        (check-equal! (capf-auto-watch! buf) id "re-entry kept the same rule")
        (check-equal! (length (buffer-local buf 'change-watches)) 1 "one row in the table"))
      (buffer-unwatch-change! buf 'capf-auto)
      (check-equal! (buffer-local buf 'change-watches) '() "the row left with its rule")
      (buffer-kill! buf))))

(deftest 'keyboard-quit-cancels-the-prompt
  "the command that quits the current operation quits a prompt too"
  (lambda ()
    (cr-test-reset!)
    (completing-read "Pick: " '("alpha" "beta") cr-test-k)
    (check-true! (minibuffer-active?) "the prompt is up")
    (run-command "keyboard-quit")
    (check-false! (minibuffer-active?) "keyboard-quit put the prompt away")
    (check-false! *cr-test-got* "and it answered nothing")))
