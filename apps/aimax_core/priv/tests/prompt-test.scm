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

(deftest 'direct-and-acp-agents-share-the-same-standing-guidance
  "both lanes compose the same named text files in the same order"
  (lambda ()
    (let ((direct (aimax-direct-prompt-parts))
          (acp (aimax-acp-prompt-parts)))
      (check-equal! direct acp "the lane guidance is identical")
      (check-equal! (map car direct)
                    '("aimax-identity" "quiet-editor" "chat-context"
                      "scheme-api" "discovery" "repository"
                      "scheme-authoring" "browser" "catalog" "recipes")
                    "the checked-in fragment order is explicit")
      (for-each
        (lambda (part)
          (check-true! (> (string-length (cadr part)) 0)
                       (string-append (car part) " is not empty")))
        direct)
      (check-equal! (hello) (prompt-parts-text acp)
                    "hello is only the shared composition")
      (check-contains! (hello) "(chat-context)"
                       "every agent learns to inspect its context")
      (check-contains! (hello) "Research as much as the task requires"
                       "discovery is not artificially curtailed")
      (check-contains! (hello) "continue with more batches"
                       "research can use repeated concurrent batches")
      (check-contains! (hello) "not that research stops after one batch"
                       "one-shot applies to questions, not the whole phase")
      (check-contains! (hello) "almost never read a full file"
                       "agents prefer structural reads")
      (check-contains! (hello) "Most source files have a tree-sitter grammar"
                       "agents know surgical source editing is available")
      (check-contains! (hello) "Write Scheme unless the user explicitly specifies another language"
                       "Scheme remains the default implementation language"))))

(deftest 'chat-context-names-the-conversation-and-its-companions
  "the structured context reports identity, group membership, and prompt state"
  (lambda ()
    (let ((chat (t--prompt-chat "*prompt-context*" "api"))
          (doc "prompt-context.md"))
      (test-buffer! doc "work")
      (buffer-set-local! chat 'group "prompt-context-group")
      (buffer-set-local! doc 'group "prompt-context-group")
      (buffer-set-local! doc 'mode-name "text-mode")
      (buffer-set-local! chat 'agent-slug "prompt-agent")
      (buffer-set-local! chat 'default-directory "/tmp/prompt-context")
      (let ((ctx (with-current-buffer chat (lambda () (chat-context)))))
        (check-equal! (plist-get ctx 'chat) chat "the chat name")
        (check-equal! (plist-get ctx 'agent) "prompt-agent" "the agent name")
        (check-true! (member chat (plist-get ctx 'group-members))
                     "the chat belongs to the group")
        (check-true! (member doc (plist-get ctx 'companions))
                     "the work buffer is a companion")
        (check-equal! (plist-get ctx 'directory) "/tmp/prompt-context"
                      "the workspace directory")
        (check-equal! (plist-get ctx 'prompt) 'prospective
                      "the prompt starts prospective"))
      (chat-prompt-freeze! chat)
      (check-equal! (plist-get (chat-context chat) 'prompt) 'frozen
                    "the context reports the frozen prompt")
      (t--prompt-cleanup chat doc))))

(deftest 'group-members-are-pulled-as-ambient-context
  "the chat names live context but does not attach member outlines or text"
  (lambda ()
    (let ((stale (group-resolve-id "prompt-ambient-group")))
      (when stale (group-record-delete! stale)))
    (let ((id (group-record-create! "prompt-ambient-group"))
          (chat (t--prompt-chat "*prompt-ambient*" "api"))
          (source "prompt-ambient.ex")
          (notes "prompt-ambient.md"))
      (test-buffer! source "def zz_ambient_secret, do: :hidden\n")
      (test-buffer! notes "# ZZ Ambient Heading\nprivate body text\n")
      (chat-set-group! chat id)
      (buffer-add-group! source id)
      (buffer-add-group! notes id)
      (buffer-set-local! source 'mode-name "elixir-mode")
      (buffer-set-local! notes 'mode-name "morg-mode")
      (let ((preamble (chat-preamble chat)))
        (check-contains! preamble "ambient context for this chat"
                         "the members are standing context")
        (check-contains! preamble "does not attach its outline or text"
                         "the prompt states the pull contract")
        (check-contains! preamble "(code-outline \"NAME\")"
                         "source structure is pulled")
        (check-contains! preamble "(markdown-outline \"NAME\")"
                         "Markdown structure is pulled")
        (check-false! (string-contains? preamble "zz_ambient_secret")
                      "the source outline is not attached")
        (check-false! (string-contains? preamble "ZZ Ambient Heading")
                      "the Markdown outline is not attached")
        (check-false! (string-contains? preamble "private body text")
                      "the member text is not attached"))
      (t--prompt-cleanup chat source notes)
      (group-record-delete! id))))

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
      (check-equal! (car (car parts)) "aimax-identity"
                    "ACP starts with the shared guidance")
      (check-true! (assoc "chat-context" parts)
                   "ACP receives the shared context guidance")
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
