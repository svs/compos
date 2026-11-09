;;; agent-sandbox-test.scm --- an agent's shell and saves stay inside policy.
;;;
;;; The shell gate reads an eval-scheme payload before it runs; a command
;;; the payload builds at run time is judged again by shell-command->string
;;; on its final string. An agent's save refuses while the buffer holds
;;; another author's unsaved edits.

(domain! 'testing)
(effects! '(write))

;; the jj command is built here, as an agent would build it, so that no
;; text scan of this file sees it
(define t--sandbox-jj (string-append "j" "j describe -m x"))

(deftest 'a-shell-command-built-at-run-time-meets-the-policy
  "the final command string is judged: a refused kind is refused, other kinds run"
  (lambda ()
    (with-stubs (list (list 'decide-shell-policy '((jj refuse) (other allow))))
      (lambda ()
        (check-equal! (decide-shell-command-verdict t--sandbox-jj) (decide-refusal 'jj)
                      "a bare jj command is refused")
        (check-equal! (decide-shell-command-verdict (string-append "cd /tmp && " t--sandbox-jj))
                      (decide-refusal 'jj) "and one behind another command")
        (check-false! (decide-shell-command-verdict "command -v jj") "naming jj is not running it")
        (check-false! (decide-shell-command-verdict "echo ok") "another kind runs")
        (check-false! (with-edit-author "agent:zz-sandbox-rt"
                        (lambda () (ignore-errors (lambda () (shell-command->string t--sandbox-jj "/tmp")))))
                      "shell-command->string refuses it for an agent")
        (check-equal! (with-edit-author "agent:zz-sandbox-rt"
                        (lambda () (shell-command->string "echo ok" "/tmp")))
                      "ok\n" "and runs an allowed command")))))

(deftest 'a-run-time-ask-passes-only-an-approved-payload
  "an ask kind refuses until the user approves the payload that runs it"
  (lambda ()
    (with-stubs (list (list 'decide--shell-seen (list (list "zz-sandbox-edit" 'edit)))
                      (list 'decide-shell-policy '((edit ask) (jj refuse)))
                      (list 'decide--shell-approved #f))
      (lambda ()
        (check-equal! (decide-shell-command-verdict "zz-sandbox-edit") (decide-refusal 'edit)
                      "unapproved, refused")
        (decide-shell-approve! "(some payload)")
        (check-false! (decide-shell-command-verdict "zz-sandbox-edit") "approved, runs")))))

(define (t--sandbox-buf name)
  (let ((b (test-buffer! name "")))
    (buffer-mark-saved! b)
    b))

(define (t--sandbox-refusal buf)
  (with-edit-author "agent:zz-sandbox-me"
    (lambda () (write-refusal "/tmp/zz-sandbox-never-written" buf #f))))

(deftest 'an-agent-save-refuses-another-authors-unsaved-edits
  "the refusal names whose edits they are"
  (lambda ()
    (let ((b (t--sandbox-buf "*zz-sandbox-foreign*")))
      (with-edit-author "agent:zz-sandbox-other" (lambda () (buffer-append! b "theirs")))
      (with-edit-author "agent:zz-sandbox-me" (lambda () (buffer-append! b " mine")))
      (check-equal! (unsaved-foreign-authors b "agent:zz-sandbox-me") '("agent:zz-sandbox-other")
                    "the other agent's edit is unsaved")
      (check-contains! (or (t--sandbox-refusal b) "") "agent:zz-sandbox-other" "the refusal says whose")
      (check-contains! (or (t--sandbox-refusal b) "") "agent-saves-only-its-own-edits" "and which rule")
      (buffer-kill! b))))

(deftest 'an-agent-save-of-its-own-edits-goes-through
  "edits saved before, and edits of the agent itself, refuse nothing"
  (lambda ()
    (let ((b (t--sandbox-buf "*zz-sandbox-own*")))
      (with-edit-author "user" (lambda () (buffer-append! b "saved before")))
      (buffer-mark-saved! b)
      (with-edit-author "agent:zz-sandbox-me" (lambda () (buffer-append! b " mine")))
      (check-equal! (unsaved-foreign-authors b "agent:zz-sandbox-me") '() "only the agent's own edit is unsaved")
      (check-false! (t--sandbox-refusal b) "so the save goes through")
      (buffer-kill! b))))

(deftest 'an-agent-save-refuses-the-users-unsaved-edits
  "the user's typing is another author's work"
  (lambda ()
    (let ((b (t--sandbox-buf "*zz-sandbox-user*")))
      (with-edit-author "user" (lambda () (buffer-append! b "typed")))
      (check-contains! (or (t--sandbox-refusal b) "") "the user" "the refusal names the user")
      (check-false! (with-edit-author #f (lambda () (write-refusal "/tmp/zz-sandbox-never-written" b #f)))
                    "the user's own save is not an agent's")
      (buffer-kill! b))))
