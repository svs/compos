;;; command-test.scm --- interactive specs, prefix counts, this/last-command,
;;; kill appending, undo boundaries. Dummy keys under <f9>.

(domain! 'testing)
(effects! '(write))

(define *command-test-got* #f)

(define-command "zz-command-test-count" "Test: record the numeric prefix" (interactive 'p)
  (lambda (n) (set! *command-test-got* n)))

(define-command "zz-command-test-region" "Test: record the region" (interactive 'r)
  (lambda (s e) (set! *command-test-got* (list s e))))

(define-command "zz-command-test-two-inserts" "Test: two edits with a boundary between"
  (lambda ()
    (insert! "a")
    (undo-boundary!)
    (insert! "b")))

(define (command-test-buffer! text)
  (let ((buf (test-buffer! "zz-command-test-buf" text)))
    (delete-other-windows!)
    (switch-to-buffer! buf)
    (goto-char! 0)
    buf))

(deftest 'a-command-with-a-p-spec-gets-the-numeric-prefix
  "run-command collects the argument from the spec; command-call passes it"
  (lambda ()
    (set-prefix-arg! 3)
    (run-command "zz-command-test-count")
    (check-equal! *command-test-got* 3 "C-u 3 reaches the command as 3")
    (set-prefix-arg! #f)
    (run-command "zz-command-test-count")
    (check-equal! *command-test-got* 1 "no prefix is 1")
    (command-call "zz-command-test-count" 7)
    (check-equal! *command-test-got* 7 "command-call passes the argument")
    (check-true! (procedure? (command-function "zz-command-test-count")) "the function is reachable")))

(deftest 'an-r-spec-gives-the-region-as-two-arguments
  "region start and end"
  (lambda ()
    (command-test-buffer! "hello world")
    (set-mark! 2)
    (goto-char! 5)
    (run-command "zz-command-test-region")
    (check-equal! *command-test-got* '(2 5) "start and end")
    (set-mark! #f)
    (buffer-kill! "zz-command-test-buf")))

(deftest 'a-count-from-the-keys-reaches-next-line
  "universal-argument, a digit, then the motion: three lines"
  (lambda ()
    (global-set-key "<f9> u" "universal-argument")
    (global-set-key "<f9> n" "next-line")
    (command-test-buffer! "1\n2\n3\n4\n5\n")
    (dispatch-keys (list "<f9>" "u" "3" "<f9>" "n"))
    (check-true! (wait-until (lambda () (= (point) 6)) 3000 20)
                 "point moved three lines, to the start of line 4")
    (global-unset-key "<f9> u")
    (global-unset-key "<f9> n")
    (buffer-kill! "zz-command-test-buf")))

(deftest 'a-kill-after-a-kill-appends-and-last-command-names-the-kill
  "two kill-words in a row make one kill-ring entry"
  (lambda ()
    (global-set-key "<f9> k" "kill-word")
    (command-test-buffer! "aa bb cc")
    (kill-push! "zz-marker")
    (dispatch-keys (list "<f9>" "k"))
    (check-true! (wait-until (lambda () (equal? (kill-top) "aa")) 3000 20) "the first kill is an entry")
    (check-equal! (last-command) "kill-word" "last-command names the kill")
    (dispatch-keys (list "<f9>" "k"))
    (check-true! (wait-until (lambda () (equal? (kill-top) "aa bb")) 3000 20)
                 "the second kill grew the entry")
    (check-equal! (kill-nth 1) "zz-marker" "and did not add one")
    (global-unset-key "<f9> k")
    (buffer-kill! "zz-command-test-buf")))

(deftest 'undo-boundary-splits-one-command-into-two-steps
  "insert, boundary, insert; one undo takes back the second insert only"
  (lambda ()
    (global-set-key "<f9> i" "zz-command-test-two-inserts")
    (command-test-buffer! "")
    (dispatch-keys (list "<f9>" "i"))
    (check-true! (wait-until (lambda () (equal? (buffer-text "zz-command-test-buf") "ab")) 3000 20)
                 "both inserts landed")
    (undo!)
    (check-equal! (buffer-text "zz-command-test-buf") "a" "one undo took back b only")
    (global-unset-key "<f9> i")
    (buffer-kill! "zz-command-test-buf")))

(deftest 'set-this-command-decides-the-next-last-command
  "a command may say what it was"
  (lambda ()
    (define-command "zz-command-test-renamer" "Test: says it was yank"
      (lambda () (set-this-command! "yank")))
    (global-set-key "<f9> y" "zz-command-test-renamer")
    (command-test-buffer! "x")
    (dispatch-keys (list "<f9>" "y"))
    (check-true! (wait-until (lambda () (equal? (last-command) "yank")) 3000 20)
                 "the next command sees yank as last-command")
    (global-unset-key "<f9> y")
    (buffer-kill! "zz-command-test-buf")))
