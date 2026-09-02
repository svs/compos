;;; agent.scm — Translate backend events into chat transcript updates.
;;;
;;; Focused modules own transcript state, permissions, connectors, sessions,
;;; and the chat fleet. This file only coordinates backend event batches.

;; This compound package owns the load order of its focused modules.
(load-bundled-package "agent-permissions.scm")
(load-bundled-package "agent-connectors.scm")
(load-bundled-package "agent-transcript.scm")

;; A nested load changes catalog attribution. Restore this entry point's name.
(package! 'agent)

;; event kinds that count as the turn having produced something visible —
;; a turn-end after none of them is a silent turn
(define *agent-output-kinds* '(chunk thought tool-call tool-update plan question error))

(define (agent-handle-event slug e)
  (let* ((buf (agent-buf slug))
         (type (plist-get e 'type)))
    ;; pending prose reveals before any other block lands, so the
    ;; transcript keeps the model's own order
    (unless (member type '(chunk status model-state mode-state usage context))
      (agent-flush-prose! slug #f))
    ;; any sign of life ends the waiting state; a pending chunk keeps the
    ;; waiting line until its first paragraph reveals
    (unless (member type '(user-msg status chunk))
      (agent-clear-waiting! slug))
    (when (member type *agent-output-kinds*)
      (buffer-set-local! buf 'agent-turn-any #t))
    (cond
      ((equal? type 'model-state)
       ;; the adapter says which model the session ACTUALLY runs — the
       ;; modeline shows that truth, and C-c m picks from this list
       (buffer-set-local! buf 'agent-models (plist-get e 'available))
       ;; and the connector keeps it: the picker offers this list again for
       ;; a chat that has not attached yet, and after a restart
       (llm-models-seen! (buffer-local buf 'agent-connector)
                         (plist-get e 'available))
       (let ((cur (plist-get e 'current)))
         (when cur (buffer-set-local! buf 'agent-model cur)))
       (agent-update-modeline! buf))

      ;; likewise for permission modes: the adapter's own list, and which
      ;; one it is actually in (it switches itself when it enters plan mode)
      ((equal? type 'mode-state)
       (let ((avail (plist-get e 'available))
             (cur (plist-get e 'current)))
         (when avail (buffer-set-local! buf 'agent-modes avail))
         (when (and cur (not (equal? cur "")))
           (buffer-set-local! buf 'agent-mode cur)))
       ;; a chat already in auto mode pushes that down to the agent as
       ;; soon as it learns the session can take it
       (agent-sync-permission-mode! slug)
       (agent-update-modeline! buf))

      ((equal? type 'user-msg)
       (buffer-set-local! buf 'chat-turn-active #t)
       ;; the conversation of record is the truth on EVERY backend: the api
       ;; lane replays it per request, ACP seeds a fresh session from it,
       ;; and both flatten it to .chat files. The api lane's turn task
       ;; already recorded this turn from the wire — chat-record-event!
       ;; knows, and does not record it twice.
       (chat-record-event! buf "user" (list (list "text" (plist-get e 'text))))
       ;; a message queued at RET becomes the normal user line now that
       ;; the model reads it; younger texts stay queued, still muted
       (let ((txt (plist-get e 'text)))
         (agent-pop-queued! buf txt)
         (let ((start (agent-render! slug
                        (string-append "\n>>> you: " txt "\n\n")
                        "agent-you")))
           (agent-block-push! buf start (agent-mark slug) "user" (list txt))))
       (agent-show-waiting! slug)
       (chat-activity! buf "waiting…"))

      ((equal? type 'chunk)
       ;; the assistant's prose accumulates across the turn; turn-end
       ;; records it as one turn
       (buffer-set-local! buf 'agent-turn-text
         (string-append (or (buffer-local buf 'agent-turn-text) "")
                        (plist-get e 'text)))
       ;; the text lands in the buffer at once; the prose block reveals
       ;; it one paragraph at a time
       (let ((start (agent-render! slug (plist-get e 'text) #f)))
         (agent-prose-note! buf start))
       (agent-flush-prose! slug chat-stream-paragraphs)
       (chat-activity! buf "streaming"))

      ((equal? type 'thought)
       (let ((start (agent-render! slug (plist-get e 'text) "agent-thought")))
         (agent-block-extend-or-push! buf start (agent-mark slug) "thought"))
       (chat-activity! buf "thinking…"))

      ((equal? type 'tool-call)
       (chat-activity! buf (string-append "tool · " (agent-tool-title e)))
       ;; code.scm listens: the first tool call that edits code turns the
       ;; chat into a coding session (code-agent-mode)
       (when (boundp (quote code-agent-note-tool!))
         (code-agent-note-tool! buf (agent-tool-title e)
                                (or (plist-get e 'kind) "")
                                (agent-tool-input-text e)))
       (let ((title (agent-tool-title e)))
         (let ((start (agent-render! slug
                        (string-append "\n▸ " (plist-get e 'kind) " · " title "\n")
                        "agent-tool")))
           (agent-block-push! buf start (agent-mark slug) "tool"
             (list (plist-get e 'id) title (plist-get e 'kind)
                   "running" (agent-mark slug)))))
       ;; remember where this tool's body will start (= current mark)
       (buffer-set-local! buf 'agent-tool-bodies
         (cons (list (plist-get e 'id) (agent-mark slug))
               (or (buffer-local buf 'agent-tool-bodies) '())))
       ;; a running card shows open; completion closes it again
       (agent-card-set-open! buf (plist-get e 'id) #t)
       ;; the arguments open the body, ahead of the result, so an opened
       ;; card shows the whole call and not just what came back
       (let ((args (agent-tool-input-text e)))
         (unless (equal? args "")
           (agent-render! slug args #f)
           (agent-block-close-tool! buf (plist-get e 'id)
             (agent-mark slug) "running" #f))))

      ((equal? type 'tool-update)
       (agent-tool-refine! slug buf e)
       (let ((text (agent-tool-update-text e)))
         (unless (equal? text "")
           (agent-render! slug text #f))
         (when (or (equal? (plist-get e 'status) "completed")
                   (equal? (plist-get e 'status) "failed"))
           (agent-block-close-tool! buf (plist-get e 'id)
             (agent-mark slug)
             (if (equal? (plist-get e 'status) "failed") "failed" "done")
             (plist-get e 'duration-ms))
           (let ((entry (assoc (plist-get e 'id)
                               (or (buffer-local buf 'agent-tool-bodies) '()))))
             (when (and entry (> (agent-mark slug) (car (cdr entry))))
               (agent-add-fold! buf (car (cdr entry)) (agent-mark slug))))
           (agent-card-set-open! buf (plist-get e 'id) #f))))

      ((equal? type 'plan)
       (let ((start (agent-render! slug
                      (string-append "\n"
                        (string-join
                          (let loop ((es (plist-get e 'entries)) (acc '()))
                            (if (null? es) (reverse acc)
                                (loop (cdr es)
                                      (cons (string-append "  □ " (car (car es))) acc))))
                          "\n")
                        "\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "plan" '())))

      ((equal? type 'question)
       (chat-activity! buf "waiting for you")
       (let* ((question (plist-get e 'question))
              (answers (or (plist-get e 'answers) '()))
              (start (agent-render! slug
                       (string-append "\n── question: " question " ──\n")
                       "agent-question")))
         (agent-block-push! buf start (agent-mark slug) "question"
           (list (plist-get e 'id) slug question answers)))
       (message (string-append "agent " slug " asks: " (plist-get e 'question))))

      ((equal? type 'question-answer)
       (agent-block-drop-kind! buf "question"))

      ;; the policy decides, not the backend: approvals are invisible
      ;; (the tool just runs), denials and asks are recorded
      ((equal? type 'permission)
       (chat-activity! buf "waiting for you")
       (let* ((title (plist-get e 'title))
              (kind (or (plist-get e 'kind) ""))
              (verdict (*permission-policy* buf title kind (or (plist-get e 'raw) ""))))
         (cond
           ((equal? verdict 'allow)
            (agent-answer-permission! slug "allow_once" "allow"))
           ((equal? verdict 'allow-always)
            (agent-answer-permission! slug "allow_always" "allow"))
           ((equal? verdict 'reject)
            (agent-answer-permission! slug "reject_once" "reject"))
           (else
             (let ((start (agent-render! slug
                            (string-append "\n── needs permission: " title
                                           " ── C-c C-y allow · C-c C-n deny\n")
                            "agent-permission")))
               (agent-block-push! buf start (agent-mark slug) "permission"
                 (list title)))
             (agent-arm-permission-deadline! slug)
             (message (string-append "agent " slug " needs permission: " title))))))

      ;; nobody was watching and nobody answered — the transcript says so
      ((equal? type 'permission-timeout)
       (agent-block-drop-kind! buf "permission")
       (let ((start (agent-render! slug
                      (string-append "permission timed out (denied): "
                                     (plist-get e 'title) "\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ;; what the conversation now occupies, from the backend itself: the
      ;; ACP lane reports it as the turn runs, so the count is a fact and
      ;; not an estimate over the transcript
      ((equal? type 'context)
       (chat-context-note! buf (plist-get e 'used) (plist-get e 'size)))

      ;; every turn's own tally. The direct lane prices it as well; the ACP
      ;; lane reports tokens on a subscription, so it counts without a price
      ;; and its modeline says connector · model
      ((equal? type 'usage)
       (chat-usage-note! buf
         (list 'input (plist-get e 'input) 'output (plist-get e 'output)
               'cache-read (plist-get e 'cache-read)
               'cache-write (plist-get e 'cache-write)
               'cost (plist-get e 'cost))))

      ((equal? type 'turn-end)
       (chat-activity! buf #f)
       (buffer-set-local! buf 'chat-turn-active #f)
       (buffer-set-local! buf 'agent-cancelling #f)
       (agent-finalize-running-tools! buf
         (cond ((member (plist-get e 'stop-reason)
                        '("cancelled" "canceled" "aborted"))
                "cancelled")
               ((member (plist-get e 'stop-reason) '("error" "failed"))
                "failed")
               (else "done")))
       (let ((text (buffer-local buf 'agent-turn-text)))
         (cond
           ((and text (not (equal? (string-trim text) "")))
            (chat-record-event! buf "assistant" (list (list "text" text))))
           ;; a completed turn that rendered NOTHING at all would look like
           ;; the send vanished — say so. (A turn that ran tools, was
           ;; cancelled, or errored already left its own trace.)
           ((and (member (plist-get e 'stop-reason) '("end_turn" "max_tokens"))
                 (not (buffer-local buf 'agent-turn-any)))
            (let ((start (agent-render! slug
                           "(no reply — the model returned no text)\n"
                           "agent-meta")))
              (agent-block-push! buf start (agent-mark slug) "meta" '())))
           (else #f)))
       ;; the reply hit the model's output limit. It stopped mid-sentence,
       ;; and a transcript that says nothing about it reads as an answer.
       (when (equal? (plist-get e 'stop-reason) "max_tokens")
         (let ((start (agent-render! slug
                        "\n[truncated — the reply hit the model's output limit]\n"
                        "agent-meta")))
           (agent-block-push! buf start (agent-mark slug) "meta" '())))
       (buffer-set-local! buf 'agent-turn-text #f)
       (buffer-set-local! buf 'agent-turn-any #f)
       (agent-block-drop-kind! buf "permission")
       (agent-block-drop-kind! buf "question")
       ;; The record used to compact itself here. It does not any more: a
       ;; cached prefix is a tenth the price of a fresh one, so resending
       ;; a long chat is cheap and a compaction is not. The threshold now
       ;; SAYS the chat is large, and M-x chat-compact is the user's to
       ;; run — between turns, which is still the only safe moment to
       ;; rewrite the record.
       (message
         (string-append "agent " slug ": done"
           (if (and (boundp (quote chat-should-compact?)) (chat-should-compact? buf))
               (string-append " — this chat is about "
                              (number->string (quotient (chat-record-tokens buf) 1000))
                              "k tokens: M-x chat-compact")
               "")))
       (when (boundp (quote workspace-finish-reminder!))
         (workspace-finish-reminder! buf slug))
       ;; code.scm listens: a pending coding-preset switch applies between
       ;; turns, so the restart cannot kill the turn that triggered it
       (when (boundp (quote code-agent-apply-pending!))
         (code-agent-apply-pending! buf))
       ;; the chat log: every completed turn writes the conversation to
       ;; <compos-home>/chats (chat.scm loads after this file)
       (when (boundp (quote chat-log-save!))
         (chat-log-save! buf)))

      ((equal? type 'error)
       (chat-activity! buf #f)
       (buffer-set-local! buf 'chat-turn-active #f)
       (agent-finalize-running-tools! buf "failed")
       (let ((start (agent-render! slug
                      (string-append "\n[error: " (plist-get e 'text) "]\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '()))
       ;; the log keeps the turns that led to the error too
       (when (boundp (quote chat-log-save!))
         (chat-log-save! buf)))

      ((equal? type 'dead)
       (chat-activity! buf "disconnected")
       (buffer-set-local! buf 'chat-turn-active #f)
       (agent-finalize-running-tools! buf "failed")
       (agent-block-drop-kind! buf "permission")
       (agent-block-drop-kind! buf "question")
       (let ((start (agent-render! slug "\n[agent exited]\n" "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ((equal? type 'status)
       ;; answered/cancelled attention requests leave the rich view
       (unless (equal? (plist-get e 'status) 'needs_attention)
         (agent-block-drop-kind! buf "permission")
         (agent-block-drop-kind! buf "question")))

      (else #f))))

(llm-session-on-event!
  (lambda (slug events)
    ;; batches race buffer kills — a dead thread's events just drop
    (when (buffer-exists? (agent-buf slug))
      (for-each (lambda (e) (agent-handle-event slug e)) events)
      ;; fleet surfaces track every batch: the erc-track segment + *chats*
      (agents-modeline-refresh!)
      (agents-refresh!))))

;; Branching questions are not permission requests. Their answer goes back
;; to the model as the result of its `ask` tool call.
(define (agent-answer-question! slug id answer)
  (agent-question-respond! slug id answer))

(category! 'chat)
(effects! '(write))
(public! 'agent-answer-question!
  "(agent-answer-question! SLUG ID ANSWER) — answer the agent's pending branching question")

;; Session and fleet APIs depend on the event coordinator above.
(load-bundled-package "agent-session.scm")
(load-bundled-package "agent-fleet.scm")
(package! 'agent)
