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
    ;; the kill ring changes while the command runs; last-command only
    ;; when it has finished
    (check-true! (wait-until (lambda () (equal? (last-command) "kill-word")) 3000 20)
                 "last-command names the kill")
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

(deftest 'a-command-names-its-modes-where-it-is-defined
  "'modes offers a command only in those modes; a command a mode map binds is still offered everywhere"
  (lambda ()
    (define-command "zz-command-test-scoped" "Test: only in morg" (interactive 'p)
      (lambda (n) (set! *command-test-got* n))
      'modes '(morg-mode))
    (define-command "zz-command-test-bound" "Test: bound in a mode map"
      (lambda () #t))
    (define-key (mode-keymap "morg-mode") "<f9> b" "zz-command-test-bound")
    (let ((buf (command-test-buffer! "x")))
      (check-false! (command-applicable? "zz-command-test-scoped" buf) "not offered in fundamental-mode")
      (check-true! (command-applicable? "zz-command-test-bound" buf) "a mode map binding does not scope")
      (with-current-buffer buf (lambda () (set-mode! "morg-mode")))
      (check-true! (command-applicable? "zz-command-test-scoped" buf) "offered in morg-mode")
      (command-call "zz-command-test-scoped" 4)
      (check-equal! *command-test-got* 4 "the spec still reaches the function"))
    (define-key (mode-keymap "morg-mode") "<f9> b" #f)
    (buffer-kill! "zz-command-test-buf")))

;; a global function the next command's name already holds
(define (zz-command-test-held) 'function)

(deftest 'a-command-is-a-function-of-its-name
  "define-command binds the name: a call from code takes its arguments, a left-out p is 1; a name that held a function keeps it; commandp tells them apart"
  (lambda ()
    (zz-command-test-count 5)
    (check-equal! *command-test-got* 5 "the name calls the command with its argument")
    (zz-command-test-count)
    (check-equal! *command-test-got* 1 "a left-out p is 1, no prompt")
    (check-true! (commandp 'zz-command-test-count) "the name is a command")
    (check-true! (commandp zz-command-test-count) "the function is a command")
    (check-false! (commandp car) "a plain function is not")
    (define-command "zz-command-test-held" "Test: a name that held a function" (lambda () 'command))
    (check-equal! (zz-command-test-held) 'function "the function the name held stays")
    (check-equal! (command-call "zz-command-test-held") 'command "command-call runs the command")
    (undefine-command "zz-command-test-held")
    (check-equal! (zz-command-test-held) 'function "undefine-command leaves it too")))

(deftest 'a-command-defined-on-its-function
  "define-command on the function its name holds makes that function the command: code passes the arguments, M-x collects them with a procedure spec, 'show gets the answer, a second define does not wrap it twice, undefine gives the function back"
  (lambda ()
    (define (zz-command-test-add a b) (+ a b))
    (set-symbol-value! 'zz-command-test-add zz-command-test-add)
    (set! *command-test-got* #f)
    (define-command "zz-command-test-add" "Test: a command on its function"
      (interactive (lambda (k) (k (list 2 3))))
      (symbol-value 'zz-command-test-add)
      'show (lambda (v) (set! *command-test-got* v)))
    (let ((f (symbol-value 'zz-command-test-add)))
      (check-true! (commandp f) "the function is the command")
      (check-equal! (f 1 1) 2 "code passes its arguments, nothing shows")
      (check-false! *command-test-got* "a code call does not show")
      (check-equal! (command-call "zz-command-test-add" 4 4) 8 "command-call passes them too")
      (run-command "zz-command-test-add")
      (check-equal! *command-test-got* 5 "M-x collects the arguments and shows the answer")
      (define-command "zz-command-test-add" "Test: a command on its function"
        (interactive (lambda (k) (k (list 2 3))))
        (symbol-value 'zz-command-test-add))
      (check-true! (eq? (symbol-value 'zz-command-test-add) f) "a second define keeps the same function")
      (undefine-command "zz-command-test-add")
      (check-true! (eq? (symbol-value 'zz-command-test-add) f) "undefine leaves the function")
      (check-false! (commandp "zz-command-test-add") "and it is no command"))))
