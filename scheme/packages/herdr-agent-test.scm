;;; herdr-agent-test.scm --- an agent in a terminal answers as a chat does.

(define t--ha-buf "*zz-herdr-agent*")

(define (t--ha-setup!)
  (test-buffer! t--ha-buf "")
  (buffer-set-locals! t--ha-buf
    (list 'herdr-agent-slug #f 'herdr-agent-harness #f 'herdr-agent-declined #f
          'herdr-agent-stopping #f 'minor-modes '())))

(define (t--ha-done!) (buffer-kill! t--ha-buf))

(define (t--ha-answer event tool)
  (let ((out (base64-decode (herdr-agent-hook "claude-code" event (herdr-agent-slug t--ha-buf) tool))))
    (and (not (equal? out "")) (plist-get (json-parse out) 'hookSpecificOutput))))

(deftest 'a-terminal-gives-its-shell-one-agent-slug
  "the shell gets the slug and this daemon's sockets; the slug stays when the shell is renamed"
  (lambda ()
    (t--ha-setup!)
    (let* ((slug (herdr-agent-slug t--ha-buf))
           (env (term-environment t--ha-buf)))
      (check-true! (string-prefix? "term-" slug) "the slug names a terminal")
      (check-equal! (cadr (assoc "COMPOS_AGENT" env)) slug "the shell knows its slug")
      (check-equal! (cadr (assoc "COMPOS_SOCK" env)) (compos-socket-path) "and this daemon")
      (check-equal! (herdr-agent-terminal slug) t--ha-buf "the slug finds the terminal")
      (check-equal! (agent-buf slug) t--ha-buf "and the agent's calls run there"))
    (t--ha-done!)))

(deftest 'the-first-hook-call-turns-on-the-harness-modes
  "a hook call from the shell turns on herdr-agent-mode and the harness mode; the exit turns them off"
  (lambda ()
    (t--ha-setup!)
    (t--ha-answer "PreToolUse" "zz-other-tool")
    (check-true! (minor-mode-on? t--ha-buf "herdr-agent-mode") "the shared mode is on")
    (check-true! (minor-mode-on? t--ha-buf "herdr-claude-mode") "and the harness mode")
    (run-hook-with-args 'terminal-turn-end-hook t--ha-buf "claude-code" 'exited #f)
    (check-false! (minor-mode-on? t--ha-buf "herdr-agent-mode") "the exit turns it off")
    (check-false! (minor-mode-on? t--ha-buf "herdr-claude-mode") "and the harness mode")
    (t--ha-done!)))

(deftest 'a-status-report-turns-on-the-harness-modes
  "an OSC 7501 status that names a harness turns its modes on"
  (lambda ()
    (t--ha-setup!)
    (run-hook-with-args 'terminal-status-hook t--ha-buf (list 'state "idle" 'app "claude-code") #f)
    (check-true! (minor-mode-on? t--ha-buf "herdr-claude-mode") "the harness mode is on")
    (t--ha-done!)))

(deftest 'a-mode-you-turn-off-stays-off-until-the-agent-exits
  "after you turn herdr-agent-mode off, the hooks answer nothing and turn nothing on"
  (lambda ()
    (t--ha-setup!)
    (herdr-agent-start! t--ha-buf "claude-code")
    (disable-minor-mode! t--ha-buf "herdr-agent-mode")
    (check-false! (t--ha-answer "PreToolUse" "Bash") "no answer")
    (check-false! (minor-mode-on? t--ha-buf "herdr-agent-mode") "the mode stays off")
    (herdr-agent-stop! t--ha-buf)
    (check-true! (and (t--ha-answer "PreToolUse" "Bash") #t) "the next session answers again")
    (t--ha-done!)))

(deftest 'a-claude-terminal-refuses-the-tools-a-chat-refuses
  "a tool the connector refuses is denied, a compos tool is allowed, any other tool gets no answer"
  (lambda ()
    (t--ha-setup!)
    (let ((refused (car (herdr-agent-refused-tools "claude-code"))))
      (check-equal! (plist-get (t--ha-answer "PreToolUse" refused) 'permissionDecision) "deny"
                    "a refused tool is denied")
      (check-equal! (plist-get (t--ha-answer "PreToolUse" "mcp__compos__read-file") 'permissionDecision)
                    "allow" "the daemon's own gate decides a compos tool")
      (check-false! (t--ha-answer "PreToolUse" "zz-other-tool") "another tool gets no answer"))
    (t--ha-done!)))

(deftest 'a-claude-terminal-starts-with-the-chat-prompt
  "the session starts with the prompt sections a chat gets, and says which slug it has"
  (lambda ()
    (t--ha-setup!)
    (let ((text (plist-get (t--ha-answer "SessionStart" "") 'additionalContext)))
      (check-true! (string-contains? text (cadr (car (compos-acp-prompt-parts))))
                   "the standing guidance of a chat is there")
      (check-true! (string-contains? text (herdr-agent-slug t--ha-buf)) "and the slug"))
    (t--ha-done!)))

(deftest 'a-hook-from-no-terminal-gets-no-answer
  "a slug that no terminal has gives an empty answer, so the harness goes on as usual"
  (lambda ()
    (check-equal! (herdr-agent-hook "claude-code" "PreToolUse" "term-zz-none" "Bash")
                  (base64-encode "") "no answer")))
