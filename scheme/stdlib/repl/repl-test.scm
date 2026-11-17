;;; repl-test.scm --- packages/repl.scm: the live Scheme buffer.
;;;
;;; What the REPL owes the user is Scheme, so it is tested in Scheme: when a
;;; form is whole, what the transcript keeps, and which earlier form a key
;;; brings back. The keys themselves are not tested; the commands they run
;;; are.

(domain! 'testing)
(effects! '(pure))

(deftest 'a-whole-form-is-told-from-one-still-being-typed
  "RET runs the first and breaks the line of the second"
  (lambda ()
    (check-true! (repl--complete? "(+ 1 2)") "one whole form")
    (check-true! (repl--complete? "(+ 1 2) (* 3 4)") "two whole forms")
    (check-true! (repl--complete? "42") "an atom")
    (check-false! (repl--complete? "(+ 1") "an open form")
    (check-true! (repl--complete? ")") "a stray close is whole, and an error")
    (check-true! (repl--complete? "(list \"a(\")") "a paren inside a string")
    (check-false! (repl--complete? "(list \"a") "an open string")
    (check-true! (repl--complete? "(list 1) ; (") "a paren in a line comment")
    (check-false! (repl--complete? "#| (") "an open block comment")
    (check-true! (repl--complete? "#| ( |#") "a closed one")
    (check-equal! (repl--depth "(define (f x)") 1 "the indent of the next line")))

(effects! '(write execute))

(define (repl-test--buffer)
  (let ((buf "*zz-repl*"))
    (test-buffer! buf "")
    (buffer-set-local! buf 'mode-name #f)
    (with-current-buffer buf (lambda () (set-mode! "scheme-repl-mode")))
    buf))

(define (repl-test--run! buf src)
  (repl-set-input! buf src)
  (with-current-buffer buf (lambda () (run-command "scheme-repl-return"))))

(deftest 'the-transcript-keeps-the-value-as-a-comment
  "a value lands behind ;;=> , an error behind ;;!! , and a define says nothing"
  (lambda ()
    (let ((buf (repl-test--buffer)))
      (repl-test--run! buf "(+ 20 22)")
      (check-contains! (buffer-text buf) "scm> (+ 20 22)" "the form stays")
      (check-contains! (buffer-text buf) ";;=> 42" "and its value")
      (check-equal! *1 42 "the value is in *1")
      (repl-test--run! buf "(car (list))")
      (check-contains! (buffer-text buf) ";;!! " "an error is a comment too")
      (check-true! (string? *e) "and its message is in *e")
      (repl-test--run! buf "(define zz-repl-test-x 1)")
      (check-equal! *1 42 "a define does not take the *1 slot")
      (check-equal! (repl-input buf) "" "the prompt is clear again")
      (buffer-kill! buf))))

(deftest 'an-unfinished-form-gets-a-newline-and-an-indent
  "RET on an open form never runs it"
  (lambda ()
    (let ((buf (repl-test--buffer)))
      (repl-test--run! buf "(list 1")
      (check-equal! (repl-input buf) "(list 1\n  " "the line broke and indented")
      (check-false! (string-index (buffer-text buf) ";;=> ") "and nothing ran")
      (buffer-kill! buf))))

(deftest 'ret-above-the-prompt-brings-that-form-back-to-edit
  "the transcript is a library of forms, and reading it runs nothing"
  (lambda ()
    (let ((buf (repl-test--buffer)))
      (repl-test--run! buf "(+ 2 3)")
      (repl-test--run! buf "(* 2 3)")
      (let ((size (buffer-size buf))
            (at (string-index (buffer-text buf) "scm> (+ 2 3)")))
        (buffer-goto! buf (+ at 8))
        (with-current-buffer buf (lambda () (run-command "scheme-repl-return")))
        (check-equal! (repl-input buf) "(+ 2 3)" "the form came down to the prompt")
        (check-equal! (buffer-point buf) (buffer-size buf) "and point is behind it"))
      ;; the value line answers with the form that made it
      (repl-set-input! buf "")
      (let ((at (string-index (buffer-text buf) ";;=> 6")))
        (buffer-goto! buf (+ at 3))
        (with-current-buffer buf (lambda () (run-command "scheme-repl-return")))
        (check-equal! (repl-input buf) "(* 2 3)" "a value brings its own form back"))
      (buffer-kill! buf))))

(deftest 'the-history-walks-into-the-prompt
  "M-p and M-n walk every form; the matching pair walk only what you typed"
  (lambda ()
    (with-stub '*minibuffer-history* '()
      (lambda ()
        (let ((buf (repl-test--buffer)))
          (repl-test--run! buf "(+ 1 1)")
          (repl-test--run! buf "(map car (list))")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-previous-input")))
          (check-equal! (repl-input buf) "(map car (list))" "the last form first")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-previous-input")))
          (check-equal! (repl-input buf) "(+ 1 1)" "then the one before it")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-next-input")))
          (check-equal! (repl-input buf) "(map car (list))" "and back down again")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-next-input")))
          (check-equal! (repl-input buf) "" "past the newest is what you had typed")
          ;; what you have typed narrows the walk
          (repl-set-input! buf "(m")
          (with-current-buffer buf
            (lambda () (run-command "scheme-repl-previous-matching-input")))
          (check-equal! (repl-input buf) "(map car (list))" "only the forms that open with it")
          (with-current-buffer buf
            (lambda () (run-command "scheme-repl-previous-matching-input")))
          (check-equal! (repl-input buf) "(map car (list))" "and there is no second one")
          (buffer-kill! buf))))))

(deftest 'a-restored-transcript-says-where-the-prompt-was
  "the text is durable and the marker is not, so the text answers for it"
  (lambda ()
    (let ((text "scm> (+ 1 2)\n;;=> 3\n\nscm> (list\n  1"))
      (check-equal! (repl--tail-start text)
                    (+ (string-index text "scm> (list") 5)
                    "input starts behind the last prompt")
      (check-false! (repl--tail-start "scm> (+ 1 2)\n;;=> 3\n")
                    "a transcript ending in output has no input to resume"))))

(deftest 'every-repl-is-its-own-session-over-one-past
  "M-x repl opens another buffer, with its own transcript and the same history"
  (lambda ()
    (with-stub '*minibuffer-history* '()
      (lambda ()
        (let ((a (scheme-repl-new!))
              (b (scheme-repl-new!)))
          (check-false! (equal? a b) "two buffers, two names")
          (check-true! (scheme-repl-buffer? a) "both are REPLs")
          (check-true! (if (member b (scheme-repl-buffers)) #t #f) "and both are listed")
          (repl-test--run! a "(+ 1 1)")
          (repl-test--run! b "(+ 2 2)")
          (check-contains! (buffer-text a) ";;=> 2" "each keeps its own transcript")
          (check-false! (string-index (buffer-text a) ";;=> 4") "and only its own")
          ;; the past is one: this buffer walks back to the form the other ran
          (with-current-buffer b (lambda () (run-command "scheme-repl-previous-input")))
          (check-equal! (repl-input b) "(+ 2 2)" "the newest form first")
          (with-current-buffer b (lambda () (run-command "scheme-repl-previous-input")))
          (check-equal! (repl-input b) "(+ 1 1)" "then the one the other buffer ran")
          (buffer-kill! a)
          (buffer-kill! b))))))

(deftest 'the-arrows-are-the-history-where-they-have-nowhere-else-to-go
  "<up> at the prompt walks back; inside a form of many lines it moves point"
  (lambda ()
    (with-stub '*minibuffer-history* '()
      (lambda ()
        (let ((buf (repl-test--buffer)))
          (repl-test--run! buf "(+ 9 9)")
          (repl-test--run! buf "(list 1 2)")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-up")))
          (check-equal! (repl-input buf) "(list 1 2)" "the last form")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-up")))
          (check-equal! (repl-input buf) "(+ 9 9)" "then the one before")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-down")))
          (check-equal! (repl-input buf) "(list 1 2)" "and back down")
          ;; a form of more than one line keeps the arrow for itself
          (repl-set-input! buf "(list 1\n  2)")
          (with-current-buffer buf (lambda () (run-command "scheme-repl-up")))
          (check-equal! (repl-input buf) "(list 1\n  2)" "the form is untouched")
          (check-true! (< (buffer-point buf) (buffer-size buf)) "and point moved up inside it")
          (buffer-kill! buf))))))

(deftest 'what-already-ran-is-a-record
  "a delete stops at the prompt, and typing above it types at the prompt"
  (lambda ()
    (let ((buf (repl-test--buffer)))
      (repl-test--run! buf "(+ 9 9)")
      (let ((size (buffer-size buf))
            (start (repl--start buf)))
        (buffer-goto! buf start)
        (with-current-buffer buf (lambda () (run-command "scheme-repl-backward-delete")))
        (check-equal! (buffer-size buf) size "the prompt is still there")
        (check-equal! (repl--start buf) start "and the input still starts behind it"))
      ;; point in the transcript, then a key that types: back to the prompt
      (buffer-goto! buf 10)
      (with-current-buffer buf (lambda () (run-command "scheme-repl-self-insert")))
      (check-equal! (buffer-point buf) (buffer-size buf) "typing happens at the prompt")
      (buffer-kill! buf))))

(deftest 'the-transcript-walks-by-entry
  "C-c C-p and C-c C-n go from form to form in the record"
  (lambda ()
    (let ((buf (repl-test--buffer)))
      (repl-test--run! buf "(+ 9 9)")
      (repl-test--run! buf "(* 9 9)")
      (let ((prompts (repl--prompt-starts buf)))
        (check-equal! (length prompts) 3 "two forms and the live prompt")
        (buffer-goto! buf (buffer-size buf))
        (with-current-buffer buf (lambda () (run-command "scheme-repl-previous-prompt")))
        (check-equal! (buffer-point buf) (nth 1 prompts) "up to the last form")
        (with-current-buffer buf (lambda () (run-command "scheme-repl-previous-prompt")))
        (check-equal! (buffer-point buf) (nth 0 prompts) "and the one before it")
        (with-current-buffer buf (lambda () (run-command "scheme-repl-next-prompt")))
        (check-equal! (buffer-point buf) (nth 1 prompts) "then back down"))
      (buffer-kill! buf))))
