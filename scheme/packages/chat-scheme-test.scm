;;; chat-scheme-test.scm --- the chat prompt is a REPL as well as a prompt.
;;;
;;; An input that reads as a parenthesised expression runs in the editor and
;;; prints into the transcript: no turn is spent, and the model is never told
;;; it happened. Prose that has to open with a paren escapes it.

(domain! 'testing)
(effects! '(read))

(define t--cs-buf "*zz-chat-scheme*")

(effects! '(write))

(define t--cs-buf2 "*zz-chat-scheme-2*")

(define (t--cs-chat-named! name input)
  (test-buffer! name "transcript\n")
  (buffer-set-local! name 'mode-name "chat-mode")
  (buffer-set-local! name 'render-mode "agent")
  (buffer-set-local! name 'agent-saved-mark (buffer-size name))
  (buffer-append! name input)
  name)

(define (t--cs-chat! input) (t--cs-chat-named! t--cs-buf input))

;; a chat's history is a buffer-local, and the test buffer is reused, so
;; each history test starts by forgetting what the last one typed
(define (t--cs-forget-history! name)
  (buffer-set-local! name 'chat-history-ring '())
  (chat-history-reset! name)
  name)

(deftest 'a-parenthesised-input-is-scheme
  "and prose that merely mentions a call is not"
  (lambda ()
    (check-true! (chat-scheme-input? "(+ 1 2)") "a bare expression runs")
    (check-false! (chat-scheme-input? "what does (foo) do?") "prose is prose")
    (check-false! (chat-scheme-input? "\\(+ 1 2)") "a backslash sends it as text")
    (check-equal! (chat-scheme-unescape "\\(+ 1 2)") "(+ 1 2)"
                  "and the backslash never reaches the model")))

(deftest 'a-bang-input-is-prose-for-fast-code
  "! resolves to Scheme here and never reaches the model"
  (lambda ()
    (check-true! (chat-fast-input? "!switch to paper") "a bang opens a fast intent")
    (check-false! (chat-fast-input? "what does ! mean") "a bang mid-sentence is prose")
    (check-false! (chat-fast-input? "(+ 1 2)") "a parenthesised input is the other path")))

(deftest 'a-bang-run-is-told-to-the-agent
  "it spends no turn, but the next message says what it typed, ran and gave"
  (lambda ()
    ;; a recipe's title resolves without the model
    (begin
      (defrecipe! "zz add two numbers" "(+ 1 2)")
      (let ((buf (t--cs-chat! "!zz add two numbers")))
        (with-current-buffer buf (lambda () (run-command "agent-send")))
        (let ((note (chat-fast-note buf)))
          (check-true! (string-contains? note "!zz add two numbers") "the words typed")
          (check-true! (string-contains? note "ran (with-frame-windows (lambda () (+ 1 2)))") "the code run")
          (check-true! (string-contains? note "gave 3") "and what came back"))
        (buffer-set-local! buf 'chat-fast-runs '())
        (check-equal! (chat-fast-note buf) "" "no runs, no note")
        (buffer-kill! buf))
      (set! *recipes* (remove (lambda (r) (equal? (car r) "zz add two numbers")) *recipes*))
      (catalog-forget! 'recipe "zz add two numbers"))))

(deftest 'malformed-scheme-goes-nowhere
  "an unbalanced expression is neither evaluated nor sent"
  (lambda ()
    (check-false! (chat-scheme-well-formed? "(+ 1 1") "an unterminated list")
    (check-false! (chat-scheme-well-formed? "(foo))") "a stray closer")
    (check-true! (chat-scheme-well-formed? "(+ 1 1)") "a whole expression")
    (let ((buf (t--cs-chat! "(+ 1 1")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (buffer-text buf) "transcript\n(+ 1 1\n"
                    "RET took a newline and left the text where it was typed")
      (buffer-kill! buf))))

(deftest 'a-value-is-pretty-printed
  "a plist too wide for one line breaks a key and its value per line"
  (lambda ()
    (check-equal! (chat-scheme-pp '(a 1 b 2) 0) "(a 1 b 2)"
                  "what fits stays on its line")
    (check-true! (string-contains?
                   (chat-scheme-pp (list 'kind "command" 'name "agent-send"
                                         'doc "Send the input to the agent, reviving it if dead")
                                   0)
                   "\n name \"agent-send\"")
                 "a wide plist breaks, one key to a line")))

(deftest 'a-bang-completes-over-every-recipe
  "! completes the whole phrase from the catalog; ( and prose are unchanged"
  (lambda ()
    (let ((buf (t--cs-chat! "!spl")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (let ((r (chat-scheme--capf)))
            (check-equal! (- (cadr r) (car r)) 3
                          "the range is the phrase after the !, not the word before point")
            (check-equal! (car (car (caddr r))) "spl"
                          "what you typed comes first, so RET keeps it")
            (check-equal! (car (cadr (caddr r))) "split the window side by side"
                          "spl finds the recipe next, and accepting writes its title"))))
      (buffer-kill! buf))
    (let ((buf (t--cs-chat! "!dired")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (check-equal! (car (cadr (caddr (chat-scheme--capf)))) "open a directory"
                        "an alias matches but the title is what gets written")))
      (buffer-kill! buf))))

(deftest 'completion-at-the-prompt-is-the-editors-own-vocabulary
  "inside an expression it completes orderless; in prose it offers nothing"
  (lambda ()
    (let ((buf (t--cs-chat! "(buf-tex")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (check-equal! (car (car (caddr (chat-scheme--capf)))) "buffer-text"
                        "buf-tex finds buffer-text, terms in any order")))
      (buffer-kill! buf))
    (let ((buf (t--cs-chat! "what does buf")))
      (with-current-buffer buf
        (lambda ()
          (chat-scheme--mode-hook!)
          (end-of-buffer!)
          (check-equal! (caddr (capf-collect (capf-sources))) '()
                        "prose offers nothing, and dabbrev is not asked either")))
      (buffer-kill! buf))))

(deftest 'ret-on-an-expression-prints-its-value
  "the value lands in the transcript and the input clears"
  (lambda ()
    (let ((buf (t--cs-chat! "(+ 1 2)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (buffer-text buf) "transcript\n\nλ (+ 1 2)\n3\n"
                    "the expression and its value are in the transcript")
      (check-equal! (caddr (car (buffer-local buf 'agent-blocks))) "eval"
                    "the block is its own kind: the reader is shown code, not a summary")
      (check-equal! (chat-input-text buf) "" "the input is clear")
      (buffer-kill! buf))))

(deftest 'an-error-prints-instead-of-breaking-ret
  "a bad expression is a printed line, not a dead key"
  (lambda ()
    (let ((buf (t--cs-chat! "(zz-cs-not-bound)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-true! (string-contains? (buffer-text buf) "error: unbound variable")
                   "the error shows where it was typed")
      (check-equal! (chat-input-text buf) "" "the input is clear")
      (buffer-kill! buf))))

(deftest 'the-expression-runs-in-its-own-chat
  "current-buffer inside it is the chat, the way a shell has a directory"
  (lambda ()
    (let ((buf (t--cs-chat! "(current-buffer)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-true! (string-contains? (buffer-text buf) t--cs-buf)
                   "the chat is the current buffer")
      (buffer-kill! buf))))

(deftest 'a-repl-row-is-status-not-conversation
  "it is saved with the chat and filtered from every model-facing path"
  (lambda ()
    (let ((buf (t--cs-chat! "(+ 2 2)")))
      (with-current-buffer buf (lambda () (run-command "agent-send")))
      (check-equal! (plist-get (car (chat-record buf)) 'role) "status"
                    "the row is status")
      (buffer-kill! buf))))

(deftest 'the-repl-can-be-turned-off
  "with chat-scheme-input #f every input is a message again"
  (lambda ()
    (with-custom 'chat-scheme-input #f
      (lambda () (check-false! (chat-scheme-input? "(+ 1 2)") "nothing runs locally")))
    (check-true! (chat-scheme-input? "(+ 1 2)") "and it comes back")))

(deftest 'prompt-history-belongs-to-its-chat
  "a chat is its own session: the chat next door reaches none of it"
  (lambda ()
    (let ((a (t--cs-forget-history! (t--cs-chat! "(+ 3 4)"))))
      (with-current-buffer a (lambda () (run-command "agent-send")))
      (check-equal! (car (chat-history a)) "(+ 3 4)"
                    "the expression joined this chat's history"))
    (let ((a (t--cs-chat! "")))
      (with-current-buffer a
        (lambda ()
          (end-of-buffer!)
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text a) "(+ 3 4)"
                        "and this chat's prompt recalls it")
          (run-command "chat-history-next")
          (check-equal! (chat-input-text a) ""
                        "down comes back to the draft"))))
    (let ((b (t--cs-forget-history! (t--cs-chat-named! t--cs-buf2 ""))))
      (with-current-buffer b
        (lambda ()
          (end-of-buffer!)
          (run-command "chat-history-previous")
          (check-equal! (chat-input-text b) ""
                        "another chat's up-arrow reaches nothing of it")))
      (buffer-kill! b))
    (buffer-kill! t--cs-buf)))

(deftest 'the-history-collapses-consecutive-repeats
  "the same input twice running takes one slot, and blanks take none"
  (lambda ()
    (let ((b (t--cs-forget-history! (t--cs-chat! ""))))
      (chat-history-push! b "(foo)")
      (chat-history-push! b "(foo)")
      (chat-history-push! b "   ")
      (check-equal! (length (chat-history b)) 1 "one entry")
      (buffer-kill! b))))

(deftest 'a-bare-command-call-runs-the-command
  "an M-x command is not a variable, so (name) reads as the command"
  (lambda ()
    (check-equal! (chat-scheme-command "(previous-buffer)") "previous-buffer"
                  "a command name the environment does not bind")
    (check-equal! (chat-scheme-command "(buffer-list)") #f
                  "a bound function stays a function")
    (check-equal! (chat-scheme-command "(+ 1 2)") #f
                  "an ordinary expression is left alone")
    (check-equal! (chat-scheme-command "(apropos \"windows\")") #f
                  "only a one-word call qualifies")))

(deftest 'an-unbound-command-name-says-where-it-lives
  "nested, the rewrite cannot help, so the error names the command table"
  (lambda ()
    (let ((body (chat-scheme-report "(list (previous-buffer))"
                                    (eval-string-safe "(list (previous-buffer))"))))
      (check-true! (string-index body "is an M-x command")
                   "the hint follows the error")
      (check-true! (string-index body "(run-command \"previous-buffer\")")
                   "and spells the call out"))
    (check-equal! (chat-scheme-hint "unbound variable: not-a-command-anywhere") ""
                  "a name no command table knows gets no hint")))

(deftest 'an-open-paren-walks-the-expressions-only
  "what you have typed is the search: a paren reaches the expressions only"
  (lambda ()
    (let ((seed (t--cs-forget-history! (t--cs-chat! ""))))
      (chat-history-push! seed "(+ 1 2)")
      (chat-history-push! seed "write me a haiku")
      (chat-history-push! seed "(buffer-list)")
      (let ((b (t--cs-chat! "(")))
        (with-current-buffer b
          (lambda ()
            (end-of-buffer!)
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(buffer-list)"
                          "the last expression, not the last message")
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(+ 1 2)"
                          "the prose between them is skipped")
            (run-command "chat-history-next")
            (run-command "chat-history-next")
            (check-equal! (chat-input-text b) "("
                          "and down comes back to the half-typed draft"))))
      (let ((b (t--cs-chat! "")))
        (with-current-buffer b
          (lambda ()
            (end-of-buffer!)
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(buffer-list)" "prose walks this chat's whole ring")
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "write me a haiku" "including the messages"))))
      (buffer-kill! t--cs-buf))))

(deftest 'the-popup-keeps-the-arrows-while-it-shows
  "a word to complete owns the arrows; the space that ends it hands them back"
  (lambda ()
    (check-equal! (keymap-lookup " *completion*" '("<up>")) "completion-prev"
                  "the popup moves with up")
    (check-equal! (keymap-lookup " *completion*" '("<down>")) "completion-next"
                  "and with down")
    (let ((b (t--cs-chat! "(load ")))
      (with-current-buffer b
        (lambda ()
          (end-of-buffer!)
          (check-equal! (chat-scheme--capf) #f
                        "after a space there is no word, so no popup to swallow them")))
      (buffer-kill! b))))

(deftest 'the-history-walks-only-what-you-have-typed
  "up searches by prefix, the way a shell's history search does"
  (lambda ()
    (let ((seed (t--cs-forget-history! (t--cs-chat! ""))))
      (chat-history-push! seed "(load \"one.scm\")")
      (chat-history-push! seed "(buffer-list)")
      (chat-history-push! seed "(load \"two.scm\")")
      (chat-history-push! seed "ship it")
      (let ((b (t--cs-chat! "(load ")))
        (with-current-buffer b
          (lambda ()
            (end-of-buffer!)
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(load \"two.scm\")"
                          "the last load, not the last expression")
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(load \"one.scm\")"
                          "and the one before it, the buffer-list skipped")
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "(load \"one.scm\")"
                          "there is no third, so nothing moves")
            (run-command "chat-history-next")
            (run-command "chat-history-next")
            (check-equal! (chat-input-text b) "(load "
                          "down comes back to what you had typed"))))
      (let ((b (t--cs-chat! "sh")))
        (with-current-buffer b
          (lambda ()
            (end-of-buffer!)
            (run-command "chat-history-previous")
            (check-equal! (chat-input-text b) "ship it"
                          "prose searches by prefix too"))))
      (buffer-kill! t--cs-buf))))
