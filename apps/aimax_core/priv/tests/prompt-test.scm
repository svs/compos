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
      (with-current-buffer chat (lambda () (run-command "chat-show-prompt")))
      (let ((page (buffer-text "*Help*"))
            (parts (chat-prompt-parts chat)))
        (check-contains! page "`*prompt-direct*` · direct API" "the page names the lane")
        (check-contains! page "## Composition" "the page explains the join")
        (check-contains! page "`chat-preamble`" "the page names a fragment")
        (check-contains! page "## Final joined text" "the page includes the wire text")
        (check-contains! page (prompt-parts-text parts) "the joined value is exact")
        (check-equal! (chat-prompt-report chat) (chat-prompt-report chat)
                      "recomposition is byte-identical without state changes"))
      (let ((meta (catalog-entry 'command "chat-show-prompt")))
        (check-equal! (plist-get meta 'package) "prompts" "the prompt package owns the command")
        (check-true! (member "display" (plist-get meta 'effects))
                     "the presentation effect is checked-in metadata"))
      (t--prompt-cleanup chat))))

(deftest 'chat-prompt-report-explains-the-acp-session-lifecycle
  "the ACP view distinguishes the current reconstruction from a live session"
  (lambda ()
    (let* ((chat (t--prompt-chat "*prompt-acp*" "codex-app-server"))
           (page (chat-prompt-report chat))
           (parts (chat-prompt-parts chat)))
      (check-contains! page "ACP session append" "the page names the ACP lane")
      (check-contains! page "keeps its earlier value until reconnect"
                       "the page states the session lifecycle")
      (check-contains! page "reconstructs the append from current buffer state"
                       "the page does not claim to inspect hidden runtime state")
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
