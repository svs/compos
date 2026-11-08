;;; help-chat-test.scm -- teaching prompt lifecycle
(domain! 'testing)
(effects! '(write))

(deftest 'help-chat-mode-owns-its-prompt
  "the help prompt follows the minor mode across setup and teardown"
  (lambda ()
    (let ((buf (buffer-create " *help-chat-mode-test*")))
      (prompt-part-set! buf "test-before" "keep this section")
      (check-equal! (assoc "help-chat" (prompt-buffer-parts buf)) #f "off by default")
      (enable-minor-mode! buf "help-chat-mode")
      (enable-minor-mode! buf "help-chat-mode")
      (check-true! (minor-mode-on? buf "help-chat-mode") "the mode is enabled")
      (check-equal! (map car (prompt-buffer-parts buf))
                    '("test-before" "help-chat") "setup preserves order and adds one section")
      (check-equal! (cadr (assoc "help-chat" (chat-live-system-prompt-parts buf #t)))
                    help-chat-prompt "direct turns receive the prompt")
      (check-equal! (cadr (assoc "help-chat" (agent-live-system-prompt-parts (list 'buffer buf))))
                    help-chat-prompt "ACP and inline sessions receive the prompt")
      (check-true! (string-contains? help-chat-prompt "In commentary and final replies")
                   "the prompt teaches keys and command names in both reply channels")
      (prompt-part-remove! buf "help-chat")
      ((mode-get "help-chat-mode" 'setup) buf)
      (check-equal! (cadr (assoc "help-chat" (prompt-buffer-parts buf)))
                    help-chat-prompt "restore setup rebuilds the derived prompt")
      (disable-minor-mode! buf "help-chat-mode")
      (check-equal! (prompt-buffer-parts buf) '(("test-before" "keep this section"))
                    "teardown removes only the help prompt")
      (check-equal! (assoc "help-chat" (chat-live-system-prompt-parts buf #t)) #f
                    "direct turns omit the disabled mode")
      (check-equal! (assoc "help-chat" (agent-live-system-prompt-parts (list 'buffer buf))) #f
                    "ACP turns omit the disabled mode")
      (buffer-kill! buf))))
