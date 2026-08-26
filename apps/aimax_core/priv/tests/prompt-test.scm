;;; prompt-test.scm --- prompt ownership, composition, and inspection.

(domain! 'testing)
(effects! '(write display))

(define (t--prompt-chat name connector)
  (let ((buf (test-buffer! name "")))
    (buffer-set-local! buf 'mode-name "chat-mode")
    (buffer-set-local! buf 'agent-saved-mark 0)
    (buffer-set-local! buf 'agent-connector connector)
    (buffer-set-local! buf 'chat-presets '(aimax))
    buf))

(define (t--prompt-cleanup &rest buffers)
  (for-each
    (lambda (buf) (when (buffer-known? buf) (buffer-kill! buf)))
    (cons "*Help*" buffers)))

(deftest 'chat-show-prompt-shows-the-direct-prompt-and-its-composition
  "the help page names each fragment and includes the canonical join"
  (lambda ()
    (let ((chat (t--prompt-chat "*prompt-direct*" "api")))
      (chat-prompt-freeze! chat)
      (with-current-buffer chat (lambda () (run-command "chat-show-prompt")))
      (let ((page (buffer-text "*Help*"))
            (parts (chat-prompt-parts chat)))
        (check-contains! page "`*prompt-direct*` · direct API" "the page names the lane")
        (check-contains! page "## Composition" "the page explains the join")
        (check-contains! page "`chat-preamble`" "the page names a fragment")
        (check-contains! page "## Final joined text" "the page includes the wire text")
        (check-contains! page "frozen fragment set" "the page states the lifecycle")
        (check-contains! page (prompt-parts-text parts) "the joined value is exact")
        (check-equal! (chat-prompt-report chat) (chat-prompt-report chat)
                      "recomposition is byte-identical without state changes"))
      (let ((meta (catalog-entry 'command "chat-show-prompt")))
        (check-equal! (plist-get meta 'package) "prompts" "the prompt package owns the command")
        (check-true! (member "display" (plist-get meta 'effects))
                     "the presentation effect is checked-in metadata"))
      (t--prompt-cleanup chat))))

(deftest 'chat-prompt-report-explains-the-acp-session-lifecycle
  "the ACP view distinguishes a prospective prompt from a frozen session"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-acp*" "codex-app-server"))
           (page (chat-prompt-report chat))
           (parts (chat-prompt-parts chat)))
      (check-contains! page "ACP session append" "the page names the ACP lane")
      (check-contains! page "prospective fragment set"
                       "the page says that the prompt is not frozen yet")
      (check-contains! page "first send freezes it"
                       "the page states the conversation lifecycle")
      (check-equal! (car (car (reverse parts))) "aimax-primer"
                    "the primer remains the final ACP fragment")
      (t--prompt-cleanup chat))))

(deftest 'modes-compose-named-buffer-local-prompt-fragments
  "set replaces in place; remove leaves the other mode fragments intact"
  (lambda ()
    (let ((buf (test-buffer! "*prompt-modes*" "")))
      (prompt-part-set! buf "first-mode" "first text")
      (prompt-part-set! buf "second-mode" "second text")
      (prompt-part-set! buf "first-mode" "new first text")
      (check-equal! (prompt-buffer-parts buf)
                    '(("first-mode" "new first text")
                      ("second-mode" "second text"))
                    "replacement preserves composition order")
      (prompt-part-remove! buf "first-mode")
      (check-equal! (prompt-buffer-parts buf)
                    '(("second-mode" "second text"))
                    "one mode cannot remove another mode's fragment")
      (check-true! (member 'prompt-parts chat-runtime-locals)
                   "mode setup rebuilds the derived local after restore")
      (t--prompt-cleanup buf))))

(deftest 'a-direct-chat-keeps-its-first-prompt-until-refresh
  "source changes do not alter the wire prompt during a conversation"
  (lambda ()
    (let ((chat (t--prompt-chat "*prompt-frozen-direct*" "api")))
      (prompt-part-set! chat "mode-note" "first prompt")
      (let ((first (chat-system-prompt-parts chat #t)))
        (prompt-part-set! chat "mode-note" "changed prompt")
        (check-equal! (chat-system-prompt-parts chat #t) first
                      "later source changes do not alter the frozen prompt")
        (check-contains! (prompt-parts-text (chat-live-system-prompt-parts chat #t))
                         "changed prompt" "the live source still changes")
        (with-current-buffer chat (lambda () (run-command "chat-refresh-prompt")))
        (check-contains! (prompt-parts-text (chat-prompt-parts chat))
                         "changed prompt" "the command replaces the snapshot"))
      (check-true! (member 'chat-prompt-snapshot chat-conversation-locals)
                   "the snapshot survives restart with the conversation")
      (let ((snapshot (chat-prompt-snapshot chat)))
        (chat-clear-locals! chat chat-runtime-locals)
        (check-equal! (chat-prompt-snapshot chat) snapshot
                      "a runtime sweep preserves the frozen prompt"))
      (chat-clear-locals! chat chat-conversation-locals)
      (check-false! (chat-prompt-snapshot chat) "chat reset clears the snapshot")
      (t--prompt-cleanup chat))))

(deftest 'an-acp-chat-keeps-its-session-prompt-until-refresh
  "ACP and direct chats use the same conversation snapshot contract"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-frozen-acp*" "codex-app-server"))
           (conf (list 'buffer chat 'presets '(aimax))))
      (prompt-part-set! chat "mode-note" "first ACP prompt")
      (let ((first (agent-system-prompt-parts conf)))
        (prompt-part-set! chat "mode-note" "changed ACP prompt")
        (check-equal! (agent-system-prompt-parts conf) first
                      "the running session keeps its frozen append")
        (check-contains! (prompt-parts-text (agent-live-system-prompt-parts conf))
                         "changed ACP prompt" "the current sources are inspectable")
        (chat-refresh-prompt! chat)
        (check-contains! (prompt-parts-text (chat-prompt-parts chat))
                         "changed ACP prompt" "refresh replaces the ACP snapshot"))
      (t--prompt-cleanup chat))))
