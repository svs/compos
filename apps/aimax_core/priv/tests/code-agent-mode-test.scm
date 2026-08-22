;;; code-agent-mode-test.scm --- a chat moves to the coding preset when
;;; its agent edits code.

(domain! 'testing)
(effects! '(write))

(define (t--cam-chat name)
  (let ((buf (string-append "*cam-" name "*")))
    (test-buffer! buf "")
    (buffer-set-local! buf 'agent-saved-mark 0)
    buf))

(define (t--cam-on? buf)
  (let ((ms (buffer-local buf 'minor-modes)))
    (if (and (pair? ms) (member "code-agent-mode" ms)) #t #f)))

(define (t--cam-edit! buf)
  (code-agent-note-tool! buf "eval-scheme" "" "(code-replace! \"a.ex\" 3 \"x\")"))

;; Every test leaves the customs where it found them: they are global, and
;; the next test reads the same ones.
(define (t--cam-reset! &rest buffers)
  (for-each
    (lambda (b)
      (when (buffer-exists? b)
        (when (t--cam-on? b) (disable-minor-mode! b "code-agent-mode"))
        (buffer-kill! b)))
    buffers)
  (customize-set! 'code-agent-auto #t)
  (customize-set! 'code-agent-connector "codex-app-server")
  (customize-set! 'code-agent-model "gpt-5.6-sol")
  (customize-set! 'code-agent-effort "medium"))

(deftest 'the-coding-preset-has-its-defaults
  "codex-app-server, gpt-5.6-sol, medium"
  (lambda ()
    (check-equal! code-agent-connector "codex-app-server" "the connector")
    (check-equal! code-agent-model "gpt-5.6-sol" "the model")
    (check-equal! code-agent-effort "medium" "the effort")))

(deftest 'a-structural-code-edit-pins-the-coding-preset
  "the mode comes on and the identity locals move"
  (lambda ()
    (let ((chat (t--cam-chat "detect")))
      (t--cam-edit! chat)
      (check-true! (t--cam-on? chat) "the mode is on")
      ;; no live runtime here: only the identity locals change, and the
      ;; next send is what attaches
      (check-equal! (buffer-local chat 'agent-connector) "codex-app-server" "connector")
      (check-equal! (buffer-local chat 'agent-model) "gpt-5.6-sol" "model")
      (check-equal! (buffer-local chat 'agent-effort) "medium" "effort")
      (t--cam-reset! chat))))

(deftest 'an-acp-edit-tool-call-triggers-too
  "the trigger reads the tool kind, not only the Scheme it ran"
  (lambda ()
    (let ((chat (t--cam-chat "edit")))
      (code-agent-note-tool! chat "write foo.ex" "edit" "")
      (check-true! (t--cam-on? chat) "an edit-kind call turns the mode on")
      (t--cam-reset! chat))))

(deftest 'a-read-or-a-prose-edit-does-not-trigger
  "reading code is not writing it, and prose is not code"
  (lambda ()
    (let ((chat (t--cam-chat "quiet"))
          (prose "cam-prose.txt"))
      (test-buffer! prose "a\n")
      (code-agent-note-tool! chat "eval-scheme" "" "(code-outline \"a.ex\")")
      (code-agent-note-tool! chat "eval-scheme" ""
        (string-append "(buffer-replace! \"" prose "\" \"a\" \"b\")"))
      (check-false! (t--cam-on? chat) "neither call turned the mode on")
      (buffer-kill! prose)
      (t--cam-reset! chat))))

(deftest 'code-agent-auto-off-keeps-the-chats-own-connector
  "the switch is a preference, and it can be declined"
  (lambda ()
    (let ((chat (t--cam-chat "off")))
      (customize-set! 'code-agent-auto #f)
      (t--cam-edit! chat)
      (check-false! (t--cam-on? chat) "the mode stayed off")
      (check-false! (buffer-local chat 'agent-connector) "and the connector is untouched")
      (t--cam-reset! chat))))

(deftest 'a-writing-workspace-never-moves-to-the-coding-preset
  "a chat that accompanies a document is not a coding chat"
  (lambda ()
    (let ((chat (t--cam-chat "writing"))
          (doc "cam-doc.md"))
      (test-buffer! doc "")
      (buffer-set-local! doc 'group doc)
      (buffer-set-local! chat 'group doc)
      (enable-minor-mode! doc "writing-mode")
      (t--cam-edit! chat)
      (check-false! (t--cam-on? chat) "the writing group held the preset off")
      (disable-minor-mode! doc "writing-mode")
      (buffer-kill! doc)
      (t--cam-reset! chat))))

(deftest 'a-switch-mid-turn-waits-for-the-turn-to-end
  "the mode goes on at once; the connector moves when the turn is over"
  (lambda ()
    (let ((chat (t--cam-chat "turn")))
      (buffer-set-local! chat 'chat-turn-active #t)
      (t--cam-edit! chat)
      (check-true! (t--cam-on? chat) "the mode is on")
      (check-equal! (buffer-local chat 'code-agent-switch-pending) #t "the switch is pending")
      (check-false! (buffer-local chat 'agent-connector)
                    "and the connector has not moved mid-turn")
      (buffer-set-local! chat 'chat-turn-active #f)
      (code-agent-apply-pending! chat)
      (check-equal! (buffer-local chat 'code-agent-switch-pending) #f "the pending clears")
      (check-equal! (buffer-local chat 'agent-connector) "codex-app-server" "connector moved")
      (check-equal! (buffer-local chat 'agent-model) "gpt-5.6-sol" "model moved")
      (t--cam-reset! chat))))

(deftest 'the-mode-adds-one-code-editing-instruction
  "one load instruction per system prompt, and asking twice does not add a second"
  (lambda ()
    (let ((chat (t--cam-chat "skill")))
      (check-false! (buffer-local chat 'chat-note-once) "nothing noted yet")
      (enable-minor-mode! chat "code-agent-mode")
      (let ((first (chat-tool-system chat))
            (second (chat-tool-system chat)))
        (check-contains! first "CODE-EDITING SKILL" "the prompt names the skill")
        (check-contains! first "instead of the filesystem sandbox" "and why")
        (check-contains! first "(skill \"code-editing\")" "and how to load it")
        (check-equal! second first "asking twice answers the same prompt")
        (check-false! (buffer-local chat 'chat-note-once) "and notes nothing once"))
      (t--cam-reset! chat))))

(deftest 'disabling-the-mode-restores-what-it-replaced
  "connector, model, effort and presets all come back"
  (lambda ()
    (let ((chat (t--cam-chat "restore")))
      (buffer-set-local! chat 'agent-connector "api")
      (buffer-set-local! chat 'agent-model "claude-sonnet-5")
      (buffer-set-local! chat 'agent-effort "high")
      (buffer-set-local! chat 'chat-presets '(project))
      (enable-minor-mode! chat "code-agent-mode")
      (check-equal! (buffer-local chat 'agent-connector) "codex-app-server" "connector pinned")
      (check-equal! (buffer-local chat 'agent-model) "gpt-5.6-sol" "model pinned")
      (disable-minor-mode! chat "code-agent-mode")
      (check-equal! (buffer-local chat 'agent-connector) "api" "connector restored")
      (check-equal! (buffer-local chat 'agent-model) "claude-sonnet-5" "model restored")
      (check-equal! (buffer-local chat 'agent-effort) "high" "effort restored")
      (check-equal! (buffer-local chat 'code-agent-saved) #f "the saved set is cleared")
      (check-false! (string-contains? (chat-tool-system chat) "CODE-EDITING SKILL")
                    "and the prompt drops the instruction")
      (t--cam-reset! chat))))

(deftest 'restore-does-not-undo-a-model-the-user-chose
  "a restart re-runs setup, and setup must not overwrite a live choice"
  (lambda ()
    (let ((chat (t--cam-chat "rerun")))
      (enable-minor-mode! chat "code-agent-mode")
      (buffer-set-local! chat 'agent-model "gpt-5.6-terra")
      (restore-minor-modes! chat)
      (check-equal! (buffer-local chat 'agent-model) "gpt-5.6-terra" "the chosen model stands")
      (t--cam-reset! chat))))

(deftest 'a-second-code-edit-is-a-no-op
  "the mode is already on, so nothing moves again"
  (lambda ()
    (let ((chat (t--cam-chat "idem")))
      (t--cam-edit! chat)
      (buffer-set-local! chat 'agent-model "gpt-5.6-terra")
      (t--cam-edit! chat)
      (check-equal! (buffer-local chat 'agent-model) "gpt-5.6-terra"
                    "the second edit left the model alone")
      (t--cam-reset! chat))))
