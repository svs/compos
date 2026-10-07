;;; agent.scm — Translate backend events into chat transcript updates.
;;;
;;; Focused modules own transcript state, permissions, connectors, sessions,
;;; and the chat fleet. This file only coordinates backend event batches.

;; This compound package owns the load order of its focused modules.
(load "agent-permissions.scm")
(load "agent-connectors.scm")
(load "agent-transcript.scm")

;; event kinds that count as the turn having produced something visible —
;; a turn-end after none of them is a silent turn
(define *agent-output-kinds* '(chunk thought tool-call tool-update plan question error))

;; The statuses that mean a turn is in flight or about to be. Every other
;; status -- idle, api, dead -- says the chat is doing nothing, and the view
;; takes down the turn's chrome when the runtime reports one.
(define *agent-working-statuses* '(running needs_attention starting))

;; A tool event arrives in pieces, and no two backends send the same
;; pieces. The direct lane names the tool and its arguments on the call
;; and hands back the body on completion. ACP calls first with an empty
;; argument list, states the name, the arguments and the body in later
;; updates, and leaves the completion bare. The record wants ONE whole
;; event, so the pieces gather here per tool id and land together when
;; the tool finishes.
(define (agent-tool-note! buf e)
  (let* ((id (plist-get e 'id))
         (pending (or (buffer-local buf 'chat-tool-pending) '()))
         (cur (or (assoc id pending) (list id #f "" "")))
         (raw (plist-get e 'input))
         (body (nth 3 cur)))
    (buffer-set-local! buf 'chat-tool-pending
      (cons (list id
                  ;; plist-get answers nil, not #f, for a key the event
                  ;; does not carry, and nil is true -- ask for the string
                  (if (string? (plist-get e 'name)) (plist-get e 'name) (nth 1 cur))
                  (if (and (string? raw) (not (equal? raw "")) (not (equal? raw "{}")))
                      raw
                      (nth 2 cur))
                  ;; the body streams, so it accumulates -- to the same
                  ;; limit a card shows, because a summary reads no more
                  (let ((txt (agent-tool-update-text e)))
                    (if (or (equal? txt "")
                            (>= (string-byte-length body) agent-tool-body-limit))
                        body
                        (string-append body txt))))
            (filter (lambda (x) (not (equal? (car x) id))) pending)))))

(define (agent-tool-record! buf id failed?)
  (let* ((pending (or (buffer-local buf 'chat-tool-pending) '()))
         (cur (assoc id pending)))
    (when cur
      (buffer-set-local! buf 'chat-tool-pending
        (filter (lambda (x) (not (equal? (car x) id))) pending))
      (chat-record-event! buf "assistant"
        (list (list "tool-use" id (if (string? (nth 1 cur)) (nth 1 cur) "tool")
                    (if (equal? (nth 2 cur) "") "{}" (nth 2 cur)))
              (list "tool-result" id (nth 3 cur) failed?))))))

(define (agent-handle-event slug e)
  (let* ((buf (agent-buf slug))
         (type (plist-get e 'type)))
    ;; pending prose reveals before any other block lands, so the
    ;; transcript keeps the model's own order
    (unless (member type '(chunk status model-state mode-state usage context))
      (agent-flush-prose! slug #f))
    ;; any sign of life ends the waiting state; a pending chunk keeps the
    ;; waiting line until its first paragraph reveals
    (unless (member type '(user-msg status chunk thought))
      (agent-clear-waiting! buf))
    ;; a thought run streams into memory; the event that follows it
    ;; reveals the whole reasoning as ONE block (agent-thought-reveal!)
    (unless (member type
                    '(thought user-msg status model-state mode-state
                      usage context question-answer))
      (agent-thought-reveal! slug))
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
       ;; a model the person chose shows as they chose it
       (let ((cur (plist-get e 'current)))
         (when (and cur (not (buffer-local buf 'agent-model)))
           (buffer-set-local! buf 'agent-model cur)))
       (agent-update-modeline! buf))

      ;; likewise for permission modes: the adapter's own list, and which
      ;; one it is actually in (it switches itself when it enters plan mode)
      ((equal? type 'mode-state)
       (let ((avail (plist-get e 'available))
             (cur (plist-get e 'current))
             (known (buffer-local buf 'agent-modes)))
         (when avail (buffer-set-local! buf 'agent-modes avail))
         ;; and the connector keeps the list, the same way it keeps the
         ;; models: the menu can then name a mode for a chat that has not
         ;; attached to this backend yet
         (llm-modes-seen! (buffer-local buf 'agent-connector) avail)
         (when (and cur (not (equal? cur "")))
           (buffer-set-local! buf 'agent-mode cur))
         ;; Apply the compos stance when modes are first discovered. Later
         ;; updates acknowledge explicit choices (or entering plan mode);
         ;; synchronizing again would immediately undo those choices. A mode
         ;; chosen before the session existed is such a choice, and it wins
         ;; over the stance.
         (when (and avail (not (pair? known)))
           (unless (agent-mode-take-pending! buf)
             (agent-sync-permission-mode! slug))))
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
       (agent-thought-forget! slug)
       (agent-show-waiting! slug)
       (chat-activity! buf "waiting…")
       ;; chat.scm listens: the first prompt names the chat, from the
       ;; prompt itself. It runs once and the name never moves again.
       (when (boundp (quote chat-title-first-prompt!))
         (chat-title-first-prompt! buf)))

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
       (let ((tail (agent-thought-note! slug (or (plist-get e 'text) ""))))
         (when tail
           (chat-activity! buf (agent-activity-preview tail)))))

      ((equal? type 'tool-call)
       (chat-activity! buf (string-append "tool · " (agent-tool-title e)))
       (agent-tool-note! buf e)
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
       ;; a running card stays closed: opening it for the run and
       ;; closing it at completion made the transcript jump on every call
       ;; the arguments open the body, ahead of the result, so an opened
       ;; card shows the whole call and not just what came back
       (let ((args (agent-tool-input-text e)))
         (unless (equal? args "")
           (agent-render! slug args #f)
           (agent-block-close-tool! buf (plist-get e 'id)
             (agent-mark slug) "running" #f))))

      ((equal? type 'tool-update)
       (agent-tool-refine! slug buf e)
       (agent-tool-note! buf e)
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
           (agent-card-set-open! buf (plist-get e 'id) #f)
           ;; the gathered call and its result reach the record together
           (agent-tool-record! buf (plist-get e 'id)
                               (equal? (plist-get e 'status) "failed")))))

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
       (let* ((title (plist-get e 'title))
              (kind (or (plist-get e 'kind) ""))
              (raw (or (plist-get e 'raw) ""))
              ;; a card the editor raised itself was already weighed
              ;; by its policy, which said ask: only the user answers it
              (verdict (if (plist-get e 'editor) 'ask (permit? buf title kind raw))))
         (cond
           ((equal? verdict 'allow)
            (agent-answer-permission! slug "allow_once" "allow"))
           ((equal? verdict 'allow-always)
            (agent-answer-permission! slug "allow_always" "allow"))
           ((equal? verdict 'reject)
            (agent-answer-permission! slug "reject_once" "reject")
            ;; a silent veto reads as a hang — name the door that reopens it
            (when (and (boundp (quote filesystem-tool?))
                       (filesystem-tool? title kind))
              (let ((start (agent-render! slug
                             "  (file tools are set to deny — C-c b f changes this)\n"
                             "agent-meta")))
                (agent-block-push! buf start (agent-mark slug) "meta" '()))))
           ;; a hidden chat has no pane for a card: its document's frame
           ;; gets the question in the minibuffer, and the answer is the
           ;; same answer C-c C-y or C-c C-n would give
           ((buffer-local buf 'inline-target)
            (buffer-set-local! buf 'permission-asked (list title kind raw))
            (y-or-n (string-append "Allow " title "?")
              (lambda () (agent-answer-permission! slug "allow_always" "allow"))
              (lambda () (agent-answer-permission! slug "reject_once" "reject"))))
           (else
             ;; what was asked, kept for the answer: the backend's pending
             ;; record holds no arguments, and "Always" needs them to
             ;; write a rule the policy can match next time
             (buffer-set-local! buf 'permission-asked (list title kind raw))
             ;; only a real ask waits on the user — an auto-answered
             ;; request must never claim it
             (chat-activity! buf "needs permission")
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
       (agent-thought-forget! slug)
       (buffer-set-local! buf 'agent-turn-any #f)
       ;; a tool that never completed leaves its pieces behind; the turn
       ;; is over, so they name nothing now
       (buffer-set-local! buf 'chat-tool-pending '())
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
       ;; chat.scm listens too: a finished turn says what the agent just
       ;; did, one line, from the on-device card writer
       (when (boundp (quote chat-summary-turn!))
         (chat-summary-turn! buf))
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

      ;; A steered turn that the agent never closed. The runtime waited for
      ;; the close, did not get it, and ended the turn. The chat says so
      ;; once: the reply above it is complete.
      ((equal? type 'turn-settled)
       (let ((start (agent-render! slug
                      (string-append "\n[the agent did not end this steered turn; compos ended it after "
                                     (number->string (or (plist-get e 'seconds) 0))
                                     "s]\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ;; The connector took the prompt and said nothing at all. The turn
      ;; ends behind this event; the session itself is the suspect, so the
      ;; batch reconnects it once the turn-end has rendered.
      ((equal? type 'turn-silent)
       (let ((start (agent-render! slug
                      (string-append "\n[the connector said nothing for "
                                     (number->string (or (plist-get e 'seconds) 0))
                                     "s; compos ended the turn and reconnected the session]\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '()))
       (buffer-set-local! buf 'chat-connector-suspect #t))

      ;; The backend named its session. The chat keeps the id with the
      ;; conversation: a parked adapter, a revive and a daemon restart all
      ;; open the next adapter on it (ACP session/load), so the agent keeps
      ;; its memory instead of reading a pasted transcript.
      ((equal? type 'session)
       (buffer-set-local! buf 'agent-session (plist-get e 'id))
       (when (plist-get e 'resumed)
         (message (string-append "agent " slug ": session resumed"))))

      ((equal? type 'dead)
       (chat-activity! buf "disconnected")
       (buffer-set-local! buf 'chat-turn-active #f)
       (agent-finalize-running-tools! buf "failed")
       (agent-block-drop-kind! buf "permission")
       (agent-block-drop-kind! buf "question")
       (let ((start (agent-render! slug "\n[agent exited]\n" "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ;; The runtime says what it is NOW, and the view believes it. This is
      ;; the only place that needs to: set_status emits on every change, so a
      ;; status that is not work ends the turn's chrome here even when the
      ;; turn-end event itself never arrives. Nothing polls and nothing
      ;; reconciles on a timer -- the runtime announces, the view listens.
      ((equal? type 'status)
       (unless (member (plist-get e 'status) *agent-working-statuses*)
         (chat-activity! buf #f)
         (buffer-set-local! buf 'chat-turn-active #f)
         (agent-clear-waiting! buf))
       ;; answered/cancelled attention requests leave the rich view
       (unless (equal? (plist-get e 'status) 'needs_attention)
         (agent-block-drop-kind! buf "permission")
         (agent-block-drop-kind! buf "question")))

      (else #f))))

(define (agent-handle-events slug events)
    ;; batches race buffer kills — a dead thread's events just drop
    (when (buffer-exists? (agent-buf slug))
      ;; one bad event must not kill the batch behind it: a turn-end that
      ;; dies silently leaves the activity line lying ("streaming" forever)
      ;; and the record unwritten. Isolate each event, and say what broke.
      (for-each
        (lambda (e)
          (unless (ignore-errors (lambda () (agent-handle-event slug e) #t))
            (message (string-append "agent " slug ": event "
                       (let ((t (plist-get e 'type)))
                         (if t (symbol->string t) "?"))
                       " failed — transcript may be missing a piece"))))
        events)
      ;; the rich view follows the batch: one tree per batch, not per event
      (chat-view-sync! (agent-buf slug))
      ;; a document's hidden chat renders its reply into the document too:
      ;; every event but the permission, which this handler answered
      (let ((target (buffer-local (agent-buf slug) 'inline-target)))
        (when (and target (buffer-exists? target))
          (llm-inline-events! slug
            (filter (lambda (e) (not (equal? (plist-get e 'type) 'permission))) events))))
      ;; fleet surfaces track every batch: the modeline says at once who
      ;; needs you, and the list settles once the burst stops
      (agents-note-event! slug)
      ;; a session that answered a whole turn with silence is not fit for
      ;; the next one. Restart it HERE, after the batch: a reconnect stops
      ;; the runtime, and an event still waiting behind it would be lost.
      (agent-reconnect-if-suspect! slug)))

;; the restart a silent turn asks for. It runs after the batch, never
;; inside it, and it is the same door C-RET twice opens.
(define (agent-reconnect-if-suspect! slug)
  (let ((buf (agent-buf slug)))
    (when (and (buffer-exists? buf)
               (buffer-local buf 'chat-connector-suspect)
               (boundp (quote agent-reconnect!)))
      (buffer-set-local! buf 'chat-connector-suspect #f)
      ;; a reconnect that fails must not take the batch with it: the turn
      ;; is already closed and the transcript already says why
      (unless (ignore-errors
                (lambda ()
                  (agent-reconnect! slug
                    (or (buffer-local buf 'agent-connector) *default-connector*)
                    (or (buffer-local buf 'agent-model) ""))
                  #t))
        (message (string-append "agent " slug ": could not reconnect the session"))))))

;; one batch of a runtime's events, in order, then one view sync
(llm-session-on-event! agent-handle-events)

;;; --- the turn-end hook --------------------------------------------------------
;;;
;;; agent-on-turn-end! is a single slot, the way the lsp event handler is: this
;;; package owns it and fans out to named listeners. The Agent dispatches it
;;; once per completed turn, after the batch carrying that turn-end has
;;; rendered, on the :ui lane. A listener therefore reads a FINISHED
;;; transcript and may touch buffers that are not this agent's — which is
;;; the whole point: the chat that WAITS on a turn is somebody else.
;;;
;;; A listener takes (SLUG STOP-REASON OK?). OK? says the turn ended
;;; normally; a cancel, an error and a dead backend are all not normal.

(define (agent-turn-end-normal? stop-reason)
  (if (member stop-reason '("end_turn" "max_tokens" "completed" "stop")) #t #f))

(agent-on-turn-end!
  (lambda (slug stop-reason)
    (let ((ok? (agent-turn-end-normal? stop-reason)))
      ;; one bad listener must not eat the ones behind it, for the same
      ;; reason one bad event must not eat its batch
      (for-each
        (lambda (key)
          (unless (ignore-errors
                    (lambda ()
                      (run-hook-with-args (list 'agent-turn-end key) slug stop-reason ok?)
                      #t))
            (message (string-append "turn-end listener "
                                    (if (symbol? key) (symbol->string key) key)
                                    " failed on " slug))))
        (hook-keys 'agent-turn-end)))))

(category! 'chat)
(domain! 'chat)
(effects! '(write))
(public! 'agent-turn-end-normal?
  "(agent-turn-end-normal? STOP-REASON) — #t when that stop reason is an ordinary end of turn, not a cancel or an error")
(catalog-meta! 'function "agent-turn-end-normal?" 'domain 'chat 'effects '(pure))

;; Branching questions are not permission requests. Their answer goes back
;; to the model as the result of its `ask` tool call.
(define (agent-answer-question! slug id answer)
  (agent-question-respond! slug id answer))

(category! 'chat)
(effects! '(write))
(public! 'agent-answer-question!
  "(agent-answer-question! SLUG ID ANSWER) — answer the agent's pending branching question")

;; Session and fleet APIs depend on the event coordinator above.
(load "agent-session.scm")
