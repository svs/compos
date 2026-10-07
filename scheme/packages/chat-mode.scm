;;; chat-mode.scm --- the chat buffer, the LLM pipes, and one LLM setup.
;;;
;;; chat-mode is the conversation buffer; llm-mode is the pipe that runs an
;;; LLM over a region. This file also holds what a chat is made of: the
;;; three lists of chat buffer-locals (identity, conversation, runtime),
;;; the .chat file format, the backends, and the C-c b setup. It loads
;;; from init.scm before every package that opens a chat.

(domain! 'chat)
(effects! '(unknown))

;;; --- LLM pipes (gptel) -----------------------------------------------------
;;; (llm prompt handler) is the async primitive; everything here is
;;; composition. Handlers are ordinary closures — build your own pipelines.

(define (llm-on-region instruction handler)
  (let ((text (region-text)))
    (if (equal? text "")
        (message "No region — set the mark first (C-SPC)")
        (begin
          (message "LLM thinking...")
          (llm (string-append instruction
                              "\n\nReturn ONLY the result, no commentary.\n\n"
                              text)
               handler)))))

;; M-| : region -> LLM -> *llm* buffer
(define-command "llm-pipe-region" "Pipe the region through the LLM into *llm*"
  (lambda ()
    (minibuffer-read "LLM instruction: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (buffer-create "*llm*")
            (buffer-append! "*llm*" (string-append "\n;; " instr "\n" result "\n"))
            (message "LLM done -> *llm*")))))))

;; The block subsystems: a block that waits in the document with a record
;; and verbs, indicated by its fence line alone. One file per block under
;; editor/blocks/; an action that creates a block loads after it.
(load (string-append (compos-priv-dir) "/editor/blocks/block.scm"))
(load (string-append (compos-priv-dir) "/editor/blocks/diff-block.scm"))
(load (string-append (compos-priv-dir) "/editor/blocks/llm-rewrite.scm"))
(global-set-key "M-|" "llm-pipe-region")

;; gptel's most Emacs-shaped operation: the buffer is both the prompt and
;; the transcript. M-o puts the answer where point was when it was sent. A
;; stateful backend gets one durable session per buffer and only the new tail;
;; the stateless API lane still receives the immutable whole-buffer snapshot.
;; The overlay makes authorship visible without writing chat markers into the
;; document itself.
(define *llm-mode-hooks* '())

(define (llm-mode--addressable-kind buf kind)
  (filter
    (lambda (record)
      (and record
           (equal? (plist-get record 'kind) kind)
           (not (equal? (plist-get record 'state) 'deleted))))
    (map (lambda (record)
           (block-resolve-id buf (plist-get record 'id)))
         (block-records buf))))

(define (llm-mode--kind-ranges buf kind)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (llm-mode--addressable-kind buf kind)))

(define (llm-mode--active-prompt-ranges buf)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (filter (lambda (record) (equal? (plist-get record 'state) 'sent))
               (llm-mode--addressable-kind buf 'llm-prompt))))

(define (llm-mode--range-overlaps? a b)
  (and (< (car a) (cadr b)) (< (car b) (cadr a))))

(define (llm-mode--range-overlaps-any? range ranges)
  (cond ((null? ranges) #f)
        ((llm-mode--range-overlaps? range (car ranges)) #t)
        (else (llm-mode--range-overlaps-any? range (cdr ranges)))))
(define (llm-mode--addressable-turn-ranges buf)
  (filter (lambda (range) (< (car range) (cadr range)))
          (append (llm-mode--kind-ranges buf 'llm-prompt)
                  (llm-mode--kind-ranges buf 'llm-response))))

(define (llm-mode--legacy-response-ranges buf)
  (let ((legacy (or (buffer-local buf 'llm-legacy-responses)
                    (if (null? (llm-mode--kind-ranges buf 'llm-response))
                        (or (buffer-local buf 'llm-responses) '())
                        '())))
        (turns (llm-mode--addressable-turn-ranges buf)))
    (filter
      (lambda (range)
        (and (number? (car range)) (number? (cadr range))
             (< (car range) (cadr range))
             (not (llm-mode--range-overlaps-any? range turns))))
      legacy)))

(define (llm-mode--visible-response-ranges buf)
  (map (lambda (record)
         (list (plist-get record 'start) (plist-get record 'end)))
       (filter
         (lambda (record)
           (and (member (plist-get record 'state)
                        '(streaming complete failed cancelled))
                (< (plist-get record 'start) (plist-get record 'end))))
         (llm-mode--addressable-kind buf 'llm-response))))

(define (llm-mode--response-ranges buf)
  (append (llm-mode--legacy-response-ranges buf)
          (llm-mode--visible-response-ranges buf)))
(define (llm-mode--thinking-chrome buf)
  (map
    (lambda (record)
      (chrome-before
        (plist-get record 'start)
        (or (plist-get (plist-get record 'metadata) 'label) "Thinking")
        "llm-thinking-spinner"))
    (llm-mode--addressable-kind buf 'llm-thinking)))

(define (llm-mode--paint! buf)
  (overlay-set! buf 'llm-mode-responses
    (map (lambda (range)
           (list (car range) (cadr range) 'llm-response))
         (llm-mode--response-ranges buf)))
  (overlay-set! buf 'llm-mode-prompts
    (map (lambda (range)
           (list (car range) (cadr range) 'llm-prompt))
         (llm-mode--active-prompt-ranges buf)))
  (overlay-set! buf 'llm-mode-thinking (llm-mode--thinking-chrome buf)))

(define (llm-mode--sync-ranges! buf)
  ;; Addressable markers are the source of truth for new turns. Legacy
  ;; desktops still mirror their overlay ranges until their first new send.
  (when (minor-mode-on? buf "llm-mode")
    (if (pair? (llm-mode--kind-ranges buf 'llm-response))
        (begin
          (buffer-set-local! buf 'llm-responses
            (llm-mode--response-ranges buf))
          (llm-mode--paint! buf))
        (let ((tracked
                (filter (lambda (ov) (equal? (caddr ov) "llm-response"))
                        (buffer-overlays buf))))
          (when (or (pair? tracked)
                    (not (buffer-local buf 'llm-responses))
                    (null? (buffer-local buf 'llm-responses)))
            (buffer-set-local! buf 'llm-responses
              (map (lambda (ov) (list (car ov) (cadr ov))) tracked)))))))

(define (llm-mode--agent-write? buf source)
  (let ((inline (buffer-local buf 'llm-session-id)))
    (and inline (equal? source (string-append "agent:" inline)))))

(define (llm-mode--change-touches-result? result pos inserted deleted)
  (let ((start (plist-get result 'start))
        (end (plist-get result 'end))
        (added (or inserted 0))
        (removed (or deleted 0)))
    (or (and (> added 0) (<= start pos) (< pos end))
        (and (> removed 0)
             (< pos (+ end removed))
             (< start (+ pos removed))))))

;; Authorship is a live property. The first non-agent edit inside a completed
;; result retires its addressable turn and children; the bytes remain untouched.
(define (llm-mode--declassify-edited-results! buf pos inserted deleted)
  (let ((changed #f))
    (for-each
      (lambda (result)
        (when (and (member (plist-get result 'state) '(complete failed cancelled))
                   (llm-mode--change-touches-result?
                     result pos inserted deleted))
          ;; Freeze the compatibility layer before retiring the native turn.
          ;; Otherwise the now-stale llm-responses mirror can be mistaken for
          ;; an old desktop's legacy overlay and repaint the edited result.
          (unless (buffer-local buf 'llm-legacy-responses)
            (buffer-set-local! buf 'llm-legacy-responses
              (llm-mode--legacy-response-ranges buf)))
          (let ((response-id (plist-get result 'parent)))
            (block-retire-children! buf (plist-get result 'id))
            (block-set-state! buf (plist-get result 'id) 'deleted)
            (when response-id
              (llm-mode--retire-thinking! buf response-id)
              (block-set-state! buf response-id 'deleted))
            (set! changed #t))))
      (llm-mode--addressable-kind buf 'llm-result))
    (when changed
      (buffer-set-local! buf 'llm-session-dirty #t)
      (buffer-set-local! buf 'llm-responses
        (llm-mode--response-ranges buf))
      (llm-mode--paint! buf))
    changed))

(define (llm-mode--ensure-hook! buf)
  (unless (assoc buf *llm-mode-hooks*)
    (set! *llm-mode-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (or (equal? source "locals")
                                  (llm-mode--agent-write? buf source))
                        (llm-mode--declassify-edited-results!
                          buf pos inserted deleted))
                      (llm-mode--sync-ranges! buf)
                      ;; Text after the last answer is the next user turn.
                      ;; Editing anything earlier rewrites conversation
                      ;; history, so the next send starts a new native thread.
                      (let ((end (llm-mode--last-response-end buf)))
                        (when (and end
                                   (not (equal? source "locals"))
                                   (not (llm-mode--agent-write? buf source))
                                   (< pos end))
                          (buffer-set-local! buf 'llm-session-dirty #t))))))
            *llm-mode-hooks*))))

(define (llm-mode--remove-hook! buf)
  (let ((hit (assoc buf *llm-mode-hooks*)))
    (when hit
      (remove-on-change! (cadr hit))
      (set! *llm-mode-hooks*
        (remove (lambda (entry) (equal? (car entry) buf))
                *llm-mode-hooks*)))))

(define (llm-mode--retire-thinking! buf response-id)
  (let* ((active-id (buffer-local buf 'llm-active-thinking))
         (active (and active-id (block-resolve-id buf active-id))))
    (for-each
      (lambda (child)
        (when (equal? (plist-get child 'kind) 'llm-thinking)
          (block-set-state! buf (plist-get child 'id) 'deleted)))
      (block-children buf response-id))
    (when (and active (equal? (plist-get active 'parent) response-id))
      (buffer-set-local! buf 'llm-active-thinking #f))
    (llm-mode--paint! buf)))

;; A restored or interrupted buffer cannot still have a live callback for an
;; old pending/streaming block. Retire those records before their advancing end
;; markers absorb later document edits. Preserve partial streamed text.
(define (llm-mode--heal-orphaned-turns! buf)
  (let ((active (buffer-local buf 'llm-active-response)))
    (for-each
      (lambda (response)
        (let* ((id (plist-get response 'id))
               (state (plist-get response 'state))
               (metadata (plist-get response 'metadata))
               (prompt-id (plist-get metadata 'prompt))
               (result-id (plist-get metadata 'result)))
          (when (and (member state '(pending streaming))
                     (not (equal? id active)))
            (llm-mode--retire-thinking! buf id)
            (when (equal? state 'pending)
              (block-close-end! buf id (plist-get response 'start))
              (when result-id
                (block-close-end! buf result-id (plist-get response 'start))))
            (block-set-state! buf id 'cancelled)
            (when result-id (block-set-state! buf result-id 'cancelled))
            (when prompt-id (block-set-state! buf prompt-id 'complete)))))
      (llm-mode--addressable-kind buf 'llm-response))
    (let ((saved (buffer-local buf 'llm-legacy-responses)))
      (when saved
        (buffer-set-local! buf 'llm-legacy-responses
          (llm-mode--legacy-response-ranges buf))))))

(define (llm-mode--apply! buf)
  (llm-mode--heal-orphaned-turns! buf)
  (buffer-set-local! buf 'llm-responses (llm-mode--response-ranges buf))
  (llm-mode--paint! buf)
  (llm-mode--ensure-hook! buf))

(define (llm-mode--teardown! buf)
  (llm-mode-reset-runtime! buf #f)
  (llm-mode--remove-hook! buf)
  (overlay-clear! buf 'llm-mode-responses)
  (overlay-clear! buf 'llm-mode-prompts)
  (overlay-clear! buf 'llm-mode-thinking))

;; the change rule behind M-o's response ranges is registered under the name
;; the buffer had. A renamed chat needs the rule again, under the new one.
(add-hook! 'buffer-renamed-hook
  (lambda (old new)
    (when (assoc old *llm-mode-hooks*)
      (llm-mode--remove-hook! old)
      (when (minor-mode-on? new "llm-mode")
        (llm-mode--ensure-hook! new)
        ;; Session callbacks close over the buffer name. Reattach them under
        ;; the new name while preserving the native Codex thread itself.
        (llm-mode-reset-runtime! new #t)))))

(register-minor-mode! "llm-mode" llm-mode--apply! llm-mode--teardown!)
(minor-mode-keys! "llm-mode"
  '(("M-o" "llm-send-buffer") ("C-g" "llm-mode-abort")
    ("C-c m" "llm-set-model") ("C-c b" "llm-configure")))

(define-command "llm-mode" "Toggle in-buffer LLM interaction and response formatting"
  (lambda ()
    (if (toggle-minor-mode! "llm-mode")
        (message "LLM mode enabled")
        (message "LLM mode disabled"))))

(mode-doc! "llm-mode"
  "In-buffer LLM interaction. `M-o` shows transient thinking/tool activity at point, then streams the durable result there. `C-g` cancels an in-flight reply and restores the prompt face; `C-c b` chooses backend, model, effort, tools, and prompt sections.")

;; Inline sessions are durable agent conversations by default, matching
;; Codex's editor integrations: one native thread stays attached to the
;; buffer and M-o sends only the next turn.  The direct API lane remains an
;; explicit choice in C-c b for users who want a stateless replay.
(define *llm-mode-connector* "codex-app-server")

;; One model wears two names: the API lane spells it "openai:gpt-5.6-luna" and
;; a subscription connector spells the same model "gpt-5.6-luna".
(define (llm--model-bare m)
  (let ((parts (string-split m ":")))
    (if (> (length parts) 1) (car (cdr parts)) #f)))

;; The name CNAME lists for this model, or #f when that connector does not
;; have the model at all.
(define (connector-model-id cname m)
  (let ((models (if (boundp (quote connector-models)) (connector-models cname) '())))
    (cond ((not m) #f)
          ((member m models) m)
          (else (let ((bare (llm--model-bare m)))
                  (and bare (member bare models) bare))))))

;; the connector that has this model, or #f. Hidden connectors are
;; compatibility names for saved chats; a new session never picks one. The
;; metered lane answers last: it serves nearly every model, and a
;; subscription connector that has the model is the cheaper lane.
(define (llm--connector-owning m)
  (let* ((names (if (boundp (quote connector-names)) (connector-names) '()))
         (ordered
           (append (filter (lambda (c) (not (connector-can? c 'metered))) names)
                   (filter (lambda (c) (connector-can? c 'metered)) names))))
    (let loop ((cs ordered))
      (cond ((null? cs) #f)
            ((connector-model-id (car cs) m) (car cs))
            (else (loop (cdr cs)))))))

;; The model names the lane. A model the default connector does not have must
;; reach the connector that does: Codex answers a model id it does not know
;; with a 400 on the first send, so a buffer holding an API model id — the
;; editor's own default model is one — got no answer and no reason for it.
(define (llm-connector-for-model m)
  (cond ((not (boundp (quote connector-models))) *llm-mode-connector*)
        ((not m) *llm-mode-connector*)
        ((connector-model-id *llm-mode-connector* m) *llm-mode-connector*)
        ((llm--connector-owning m))
        (else "api")))

(define (buffer-llm-connector buf)
  (or (buffer-local buf 'llm-connector)
      (llm-connector-for-model (buffer-llm-model buf))))

(define (buffer-llm-model buf)
  (or (buffer-local buf 'llm-model) (llm-model)))

;; Runtime ids are buffer identities, not turn identities. The local survives
;; desktop restore and buffer rename; the persisted counter prevents a new
;; buffer from colliding with an old renamed one.
;; the document's session is its hidden chat's (llm-mode--companion!); a
;; document that never sent has none
(define (llm-mode--session-id buf) (buffer-local buf 'llm-session-id))

;; the reply lands in the document at its response block, which grows
;; with an insert at its end. The session's own mark belongs to the
;; hidden chat and is never the document's insertion point.
(define (llm-mode--emit! buf response-id text)
  (let ((response (block-resolve-id buf response-id)))
    (when response
      (buffer-insert! buf (plist-get response 'end) text))))

(define (llm-mode--runtime-live? buf)
  (let ((id (buffer-local buf 'llm-session-id)))
    (and id (member id (agent-list)) (not (equal? (agent-status id) 'dead)) #t)))

;; KEEP-THREAD preserves Codex's durable thread identity while dropping only
;; this editor process. A changed history or connector passes #f and starts a
;; genuinely new conversation on the next send.
(define (llm-mode-reset-runtime! buf keep-thread)
  (let ((id (buffer-local buf 'llm-session-id)))
    (when (and id (member id (agent-list))) (llm-session-close! id)))
  (unless keep-thread (buffer-set-local! buf 'llm-thread-id #f))
  (buffer-set-local! buf 'llm-session-dirty #f)
  #t)

(define-command "llm-set-model" "Choose the model for M-o in this buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read
        (string-append "Model for this buffer (now " (buffer-llm-model buf) "): ")
        *llm-models*
        (lambda (model)
          (unless (equal? (string-trim model) "")
            (buffer-set-local! buf 'llm-model model)
            ;; Codex fixes model identity in the thread instructions. Resume
            ;; the same thread through a fresh runtime with the new override.
            (llm-mode-reset-runtime! buf #t)
            (message (string-append "M-o · " model))))))))

;; The live inline turn is data on the document's chat, not a registry of
;; its own: the chat knows its document ('inline-target) and its session,
;; so the turn ('inline-turn, a runtime local) only says which response
;; block grows and what arrived. One entry exists while the session runs
;; a turn for the document; the finish clears it, not the session.
(define (llm-inline--chat id)
  (let ((chat (agent-buf id)))
    (and chat (buffer-exists? chat) chat)))

(define (llm-inline--doc id)
  (let* ((chat (llm-inline--chat id))
         (doc (and chat (buffer-local chat 'inline-target))))
    (and doc (buffer-exists? doc) doc)))

(define (llm-inline--turn id)
  (let ((chat (llm-inline--chat id)))
    (and chat (buffer-local chat 'inline-turn))))

(define (llm-inline--turn-set! id turn)
  (let ((chat (llm-inline--chat id)))
    (when chat (buffer-set-local! chat 'inline-turn turn))))

;; TURN: (response ID insert-at N context-size N streamed BOOL text "" error #f)
(define (llm-inline-begin! id response-id insert-at context-size)
  (llm-inline--turn-set! id
    (list 'response response-id 'insert-at insert-at 'context-size context-size
          'streamed #f 'text "" 'error #f)))

;; the response belongs in its document as it arrives: waiting for the
;; turn-end hid useful prose when a later tool call stalled or failed
(define (llm-inline-add-chunk! id text)
  (let ((turn (llm-inline--turn id))
        (doc (llm-inline--doc id)))
    (when (and turn doc (not (equal? text "")))
      (let ((landed (llm-mode--append-response! doc (plist-get turn 'response) text)))
        (llm-inline--turn-set! id
          (plist-put (plist-put turn 'text (string-append (plist-get turn 'text) text))
                     'streamed (and (or (plist-get turn 'streamed) landed) #t)))))))

(define (llm-inline-error! id text)
  (let ((turn (llm-inline--turn id)))
    (when turn (llm-inline--turn-set! id (plist-put turn 'error text)))))

;; the turn ends: a non-streaming backend still returns one final result,
;; and both paths use the reserved response block. An insertion in the
;; middle dirties the native thread, because its untouched suffix was sent.
(define (llm-inline-finish! id)
  (let ((turn (llm-inline--turn id))
        (doc (llm-inline--doc id)))
    (when turn
      ;; clear before the presentation: a completion may start another
      ;; turn on this same session
      (llm-inline--turn-set! id #f)
      (if (not doc)
          (message "LLM reply discarded — its buffer was killed")
          (let* ((response-id (plist-get turn 'response))
                 (text (plist-get turn 'text))
                 (error (plist-get turn 'error))
                 (streamed (or (plist-get turn 'streamed)
                               (and (not (equal? text ""))
                                    (llm-mode--append-response! doc response-id text)
                                    #t))))
            (llm-mode--finish-response! doc response-id streamed error)
            (when streamed
              (buffer-set-local! doc 'llm-session-dirty
                (< (plist-get turn 'insert-at) (plist-get turn 'context-size))))
            (if error
                (message (string-append "LLM failed · " error))
                (message "LLM response inserted")))))))

(define (llm-inline-note-activity! id event)
  (let ((doc (and (llm-inline--turn id) (llm-inline--doc id))))
    (when doc (llm-mode--note-activity! doc event))))

(define (llm-inline-events! id events)
  (for-each
    (lambda (event)
      (let ((type (plist-get event 'type)))
        (when (member type '(thought tool-call tool-update plan permission question))
          (llm-inline-note-activity! id event))
        (cond ((equal? type 'chunk)
               (llm-inline-add-chunk! id (or (plist-get event 'text) "")))
              ((equal? type 'thread-id)
               (let ((doc (llm-inline--doc id)))
                 (when doc
                   (buffer-set-local! doc 'llm-thread-id (plist-get event 'id)))))
              ((equal? type 'error)
               ;; A failed turn ends in turn-failed, which the status machine
               ;; consumes: no turn-end ever reaches this buffer. Finish here.
               (llm-inline-error! id (or (plist-get event 'text) "request failed"))
               (llm-inline-finish! id))
              ((equal? type 'permission)
               (llm-inline-permission! id event))
              ((equal? type 'question)
               (llm-inline-answer! id event))
              ((equal? type 'turn-end)
               (llm-inline-finish! id)))))
    events))

;; the option that says yes for the rest of the session, else the plain yes
(define (llm-inline--allow-option event)
  (let loop ((os (or (plist-get event 'options) '())) (once #f))
    (cond ((null? os) (or once "allow_once"))
          ((equal? (car (car os)) "allow_always") "allow_always")
          (else (loop (cdr os) (or once (car (car os))))))))

(define (llm-inline-allow! id event)
  (let ((rpc (plist-get event 'rpc-id)))
    (when rpc
      (agent-permission-respond! id rpc (llm-inline--allow-option event)))))

;; the option whose name starts with PREFIX ("reject"), else the plain no
(define (llm-inline--option event prefix)
  (let loop ((os (or (plist-get event 'options) '())))
    (cond ((null? os) (string-append prefix "_once"))
          ((string-prefix? prefix (car (car os))) (car (car os)))
          (else (loop (cdr os))))))

;; One transport, one decision: an M-o session answers a permission the
;; way a chat does, through permit? under the document's stance. The
;; document has no pane for a card, so an ask is a y-or-n question in the
;; minibuffer, and a refusal is silent, as the deny-list intends.
(define (llm-inline-permission-verdict buf event)
  (permit? buf
           (or (plist-get event 'title) "")
           (or (plist-get event 'kind) "")
           (or (plist-get event 'raw) "")))

(define (llm-inline-permission! id event)
  (let* ((buf (llm-inline--doc id))
         (rpc (plist-get event 'rpc-id))
         (verdict (llm-inline-permission-verdict buf event)))
    (when rpc
      (cond ((equal? verdict 'reject)
             (agent-permission-respond! id rpc (llm-inline--option event "reject")))
            ((equal? verdict 'ask)
             (y-or-n (string-append "Allow " (or (plist-get event 'title) "this") "?")
               (lambda () (agent-permission-respond! id rpc (llm-inline--allow-option event)))
               (lambda () (agent-permission-respond! id rpc (llm-inline--option event "reject")))))
            (else (llm-inline-allow! id event))))))

(define (llm-inline-answer! id event)
  (let ((qid (plist-get event 'id))
        (answers (or (plist-get event 'answers) '())))
    (when qid
      ;; An enum question chooses its first allowed answer. A question with
      ;; no choices is the boolean approval emitted by the compos MCP bridge.
      (agent-question-respond! id qid
        (if (pair? answers) (car answers) "true")))))

;; Presets supply the complete tool surface. The runtime opens lazily on the
;; first send, stays attached to BUF, and (for Codex) records a native thread
;; id that a restored buffer resumes.
;;; --- the hidden chat behind M-o ------------------------------------------------
;;; One transport (the owner's ruling, 2026-09-19): a document that talks
;;; gets a chat of its own, *chat:<document>*, made on the first send and
;;; hidden until asked for (llm-companion-show). The chat holds the record,
;;; the tools, the stance and the session; the document keeps building the
;;; wire from its own text, gptel style, and the reply renders into the
;;; document through the inline path while the chat records it.

(define (llm-mode--companion-name buf) (string-append "*chat:" buf "*"))

;; the document's chat, made and attached when it is missing or its
;; session is gone (a restart brings the buffer back, not the session)
(define (llm-mode--companion! buf &optional model)
  (let* ((name (or (buffer-local buf 'llm-companion) (llm-mode--companion-name buf)))
         (connector (buffer-llm-connector buf))
         (model (or model (buffer-llm-model buf)))
         (opts (or (buffer-local buf 'llm-companion-opts) '())))
    (unless (buffer-exists? name)
      (buffer-create name)
      (let ((dir (buffer-local buf 'default-directory)))
        (when dir
          (buffer-set-local! name 'default-directory dir)
          (buffer-set-local! name 'chat-directory dir)))
      (buffer-set-local! name 'chat-presets (chat-presets-of buf))
      (let ((pm (buffer-local buf 'chat-permission-mode)))
        (when pm (buffer-set-local! name 'chat-permission-mode pm)))
      (buffer-set-local! name 'chat-companion-of buf)
      (chat-task-init! name buf))
    (buffer-set-local! buf 'llm-companion name)
    (let ((slug (buffer-local name 'agent-slug)))
      (unless (and slug (member slug (agent-list))
                   (not (equal? (agent-status slug) 'dead)))
        (chat-attach-agent! name connector model opts)))
    (buffer-set-local! name 'inline-target buf)
    (buffer-set-local! buf 'llm-session-id (buffer-local name 'agent-slug))
    name))

;; the send: the chat's session carries the document's wire; the chat
;; records DISPLAY as the user's turn, and the reply comes back through
;; the chat's handler, which forwards it to the inline render
(define (llm-mode--complete buf wire display model response-id insert-at)
  (let* ((companion (llm-mode--companion! buf model))
         (id (buffer-local companion 'agent-slug)))
    (llm-inline-begin! id response-id insert-at (string-byte-length display))
    (llm-session-send! id wire display)))

(define-command "llm-companion-show" "Show this document's hidden chat in the other window"
  (lambda ()
    (let* ((buf (current-buffer))
           (name (buffer-local buf 'llm-companion)))
      (if (and name (buffer-exists? name))
          (display-buffer-other-window! name)
          (message "This document has no chat yet: M-o starts one")))))

(define (llm-mode--last-response-range buf)
  (let loop ((ranges (llm-mode--response-ranges buf)) (latest #f))
    (cond ((null? ranges) latest)
          ((or (not latest) (> (cadr (car ranges)) (cadr latest)))
           (loop (cdr ranges) (car ranges)))
          (else (loop (cdr ranges) latest)))))

(define (llm-mode--last-response-end buf)
  (let ((range (llm-mode--last-response-range buf)))
    (and range (cadr range))))

;; Keep the old range local current for clients and saved desktops that read it.
(define (llm-mode--sync-addressable-responses! buf)
  (let ((ranges (llm-mode--response-ranges buf)))
    (when (pair? ranges) (buffer-set-local! buf 'llm-responses ranges))
    (llm-mode--paint! buf)))

(define (llm-mode--stateful? buf)
  (not (connector-can? (buffer-llm-connector buf) 'stateless)))

(define (llm-mode--wire-text buf snapshot)
  (let* ((range (llm-context-range buf))
         (end (llm-mode--last-response-end buf))
         (relative-end
           (if range
               (and end (<= (car range) end) (<= end (cadr range))
                    (- end (car range)))
               end)))
    (if (and (llm-mode--stateful? buf)
             relative-end
             (or (llm-mode--runtime-live? buf)
                 (buffer-local buf 'llm-thread-id))
             (not (buffer-local buf 'llm-session-dirty)))
        (let ((tail (substring-bytes snapshot relative-end
                                     (string-byte-length snapshot))))
          (if (equal? (string-trim tail) "") "" tail))
        snapshot)))

;; Where a reply goes. A reply is a block of its own, so it belongs after the
;; block point sits in — never inside it, and never above the prompt just
;; typed. The scan is morg-scan, the one fence-aware line scanner, so an
;; answer cannot land between two backtick lines, and the landing agrees
;; with every Morg view of the same bytes.
(define (llm-mode--blocks buf)
  ;; The document as (START END) blocks. A fenced block runs from its opening
  ;; fence to the end of its closing fence; any other run of non-blank lines
  ;; is a paragraph; a blank line separates two of them.
  (let loop ((es (morg-scan buf)) (open #f) (last 0) (acc '()))
    (if (null? es)
        (reverse (if open (cons (list open last) acc) acc))
        (let* ((e (car es))
               (start (car e))
               (k (morg-kind e))
               (end (+ start (string-byte-length (cadr e))))
               (flushed (if open (cons (list open last) acc) acc)))
          (cond
            ((equal? k 'open) (loop (cdr es) start end flushed))
            ((equal? k 'code) (loop (cdr es) open end acc))
            ((equal? k 'close)
             (loop (cdr es) #f end (cons (list (or open start) end) acc)))
            ((and (equal? k 'text) (equal? (string-trim (cadr e)) ""))
             (loop (cdr es) #f end flushed))
            (else (loop (cdr es) (or open start) end acc)))))))

;; A newly typed prompt can share a Morg paragraph with the result immediately
;; before it. Cut the parsed span at every addressable boundary it would cross,
;; keeping the side that contains point. Repeating handles nested old turns.
(define (llm-mode--fit-prompt-range buf range pos)
  (let ((records
          (filter
            (lambda (record)
              (and record (not (equal? (plist-get record 'state) 'deleted))))
            (map (lambda (raw)
                   (block-resolve-id buf (plist-get raw 'id)))
                 (block-records buf)))))
    (let loop ((candidate range))
      (let ((next
              (fold
                (lambda (current record)
                  (let ((start (car current)) (end (cadr current))
                        (rstart (plist-get record 'start))
                        (rend (plist-get record 'end)))
                    (cond
                      ((and (< rstart start) (< start rend) (< rend end))
                       (if (< pos rend) (list start rend) (list rend end)))
                      ((and (< start rstart) (< rstart end) (< end rend))
                       (if (<= pos rstart) (list start rstart) (list rstart end)))
                      (else current))))
                candidate records)))
        (if (equal? next candidate) next (loop next))))))

(define (llm-mode--block-range-at buf pos)
  (let* ((at (max 0 (min pos (buffer-size buf))))
         (raw
           (let loop ((blocks (llm-mode--blocks buf)))
             (cond ((null? blocks) (list at at))
                   ((and (<= (car (car blocks)) at)
                         (<= at (cadr (car blocks))))
                    (car blocks))
                   (else (loop (cdr blocks)))))))
    (llm-mode--fit-prompt-range buf raw at)))

;; Mark the prompt now and reserve one transient activity block plus one durable
;; result block before the request starts. Only the final result owns text.
(define (llm-mode--begin-turn! buf pos insert-at &optional model)
  (let* ((prompt-range (llm-mode--block-range-at buf pos))
         (_legacy
           (when (not (buffer-local buf 'llm-legacy-responses))
             (buffer-set-local! buf 'llm-legacy-responses
               (or (buffer-local buf 'llm-responses) '()))))
         ;; Validate/claim the prompt before touching the document. Insertion at
         ;; its end advances the marker, so reset it to exclude the separator.
         (prompt-id
           (block-create! buf 'llm-prompt
             (car prompt-range) (cadr prompt-range) #f 'sent '()))
         (_separator (buffer-insert! buf insert-at "\n\n"))
         (_prompt-end (block-close-end! buf prompt-id (cadr prompt-range)))
         (response-at (+ insert-at 2))
         (response-id
           (block-create! buf 'llm-response response-at response-at
             #f 'pending (list 'prompt prompt-id)))
         (thinking-id
           (block-create! buf 'llm-thinking response-at response-at response-id
             'streaming
             (list 'label (if model (string-append "Thinking · " model) "Thinking")
                   'activity 'thinking)))
         (result-id
           (block-create! buf 'llm-result response-at response-at response-id
             'pending '())))
    (block-set-metadata! buf response-id
      (list 'prompt prompt-id 'thinking thinking-id 'result result-id))
    (block-set-metadata! buf prompt-id (list 'response response-id))
    (buffer-set-local! buf 'llm-active-prompt prompt-id)
    (buffer-set-local! buf 'llm-active-response response-id)
    (buffer-set-local! buf 'llm-active-thinking thinking-id)
    (buffer-set-local! buf 'llm-active-result result-id)
    (llm-mode--aim! buf response-at)
    (llm-mode--sync-addressable-responses! buf)
    (list 'prompt prompt-id 'response response-id 'thinking thinking-id
          'result result-id 'insert-at insert-at)))

(define (llm-mode--clip-activity text)
  (let* ((clean (string-trim (or text "")))
         (line (if (equal? clean "") "" (car (string-split clean "\n")))))
    (if (> (string-length line) 92)
        (string-append (substring line 0 91) "…")
        line)))

(define (llm-mode--activity-label event)
  (let ((type (plist-get event 'type)))
    (cond
      ((equal? type 'thought)
       (let ((text (llm-mode--clip-activity (plist-get event 'text))))
         (if (equal? text "") "Thinking" (string-append "Thinking · " text))))
      ((equal? type 'tool-call)
       (let* ((title (or (plist-get event 'title) (plist-get event 'name)
                         (plist-get event 'kind) "tool"))
              (shown (if (equal? title "") "tool" title)))
         (string-append "Running · " (llm-mode--clip-activity shown))))
      ((equal? type 'tool-update)
       (let ((status (or (plist-get event 'status) "working")))
         (string-append "Tool · " (if (equal? status "") "working" status))))
      ((equal? type 'plan) "Planning")
      ((equal? type 'permission) "Approving tool")
      ((equal? type 'question) "Answering tool")
      (else "Thinking"))))

(define (llm-mode--note-activity! buf event)
  (let* ((response-id (buffer-local buf 'llm-active-response))
         (response (and response-id (block-resolve-id buf response-id)))
         (thinking-id (and response
                        (plist-get (plist-get response 'metadata) 'thinking)))
         (thinking (and thinking-id (block-resolve-id buf thinking-id))))
    (when (and thinking (equal? (plist-get thinking 'state) 'streaming))
      (block-set-metadata! buf thinking-id
        (list 'label (llm-mode--activity-label event)
              'activity (plist-get event 'type)))
      (llm-mode--paint! buf))))

(define (llm-mode--append-response! buf response-id text)
  (let* ((response (block-resolve-id buf response-id))
         (result-id (and response
                      (plist-get (plist-get response 'metadata) 'result))))
    (if (or (equal? text "")
            (not (member (plist-get response 'state) '(pending streaming))))
        #f
        (begin
          (llm-mode--retire-thinking! buf response-id)
          (llm-mode--emit! buf response-id text)
          (block-set-state! buf response-id 'streaming)
          (when result-id (block-set-state! buf result-id 'streaming))
          (llm-mode--sync-addressable-responses! buf)
          #t))))

(define (llm-mode--fence-for-span buf span)
  (let ((fence (block-at buf (car span))))
    (and fence
         (= (nth 0 fence) (car span))
         (= (nth 1 fence) (cadr span))
         fence)))

;; A completed response contains one durable result block. Morg paragraphs and
;; fences become children of that result; transient thinking remains a sibling.
(define (llm-mode--adopt-response-children! buf response-id)
  (let* ((response (block-resolve-id buf response-id))
         (result-id (and response
                      (plist-get (plist-get response 'metadata) 'result)))
         (container-id (or result-id response-id))
         (container (and response (block-resolve-id buf container-id))))
    (when container
      (block-retire-children! buf container-id)
      (for-each
        (lambda (span)
          (when (and (<= (plist-get container 'start) (car span))
                     (<= (cadr span) (plist-get container 'end))
                     (< (car span) (cadr span)))
            (let* ((fence (llm-mode--fence-for-span buf span))
                   (language (and fence (block-lang fence)))
                   (kind (cond ((and language (equal? language "scheme")) 'scheme)
                               (fence 'code)
                               (else 'paragraph)))
                   (metadata (if language (list 'language language) '()))
                   (id (block-create! buf kind (car span) (cadr span)
                         container-id 'complete metadata)))
              (block-close-end! buf id))))
        (llm-mode--blocks buf)))))

(define (llm-mode--finish-response! buf response-id streamed error)
  (let* ((response (block-resolve-id buf response-id))
         (end (plist-get response 'end))
         (metadata (plist-get response 'metadata))
         (prompt-id (plist-get metadata 'prompt))
         (result-id (plist-get metadata 'result))
         (cancelled (equal? (plist-get response 'state) 'cancelled))
         (state (if cancelled 'cancelled (if error 'failed 'complete))))
    (llm-mode--retire-thinking! buf response-id)
    (when streamed (llm-mode--emit! buf response-id "\n"))
    ;; The final line break belongs to the document, not to either result span.
    (block-close-end! buf response-id end)
    (when result-id (block-close-end! buf result-id end))
    (block-set-state! buf response-id state)
    (when result-id (block-set-state! buf result-id state))
    (when prompt-id (block-set-state! buf prompt-id 'complete))
    (when (equal? (buffer-local buf 'llm-active-response) response-id)
      (buffer-set-local! buf 'llm-active-response #f)
      (buffer-set-local! buf 'llm-active-result #f)
      (buffer-set-local! buf 'llm-active-prompt #f))
    (llm-mode--adopt-response-children! buf response-id)
    (llm-mode--sync-addressable-responses! buf)))

(define (llm-mode--insert-at buf pos)
  ;; Between two blocks POS is already the right place.
  (let* ((size (buffer-size buf))
         (at (max 0 (min pos size))))
    (let loop ((bs (llm-mode--blocks buf)))
      (cond ((null? bs) at)
            ((and (<= (car (car bs)) at) (<= at (cadr (car bs))))
             (cadr (car bs)))
            (else (loop (cdr bs)))))))

(define (llm-mode--aim! buf at)
  ;; The reply streams at the buffer's agent mark, and that mark otherwise
  ;; only remembers where the last reply ended — above anything written
  ;; since. A document aims it at this send. A chat's mark owns the input
  ;; region and is never ours to move.
  (unless (chat-buffer? buf)
    (buffer-set-local! buf 'agent-saved-mark at)))

(define-command "llm-mode-abort" "Cancel the inline reply and restore the prompt face"
  (lambda ()
    (let* ((buf (current-buffer))
           (response-id (buffer-local buf 'llm-active-response))
           (response (and response-id (block-resolve-id buf response-id)))
           (state (and response (plist-get response 'state)))
           (prompt-id (buffer-local buf 'llm-active-prompt))
           (result-id (and response
                        (plist-get (plist-get response 'metadata) 'result))))
      (if (not (member state '(pending streaming)))
          (run-command "keyboard-quit")
          (begin
            (when (and (llm-mode--runtime-live? buf)
                       (member (agent-status (llm-mode--session-id buf))
                               '(running starting needs_attention)))
              (llm-session-cancel! (llm-mode--session-id buf)))
            (llm-mode--retire-thinking! buf response-id)
            (block-set-state! buf response-id 'cancelled)
            (when result-id
              (block-set-state! buf result-id 'cancelled)
              (block-close-end! buf result-id (plist-get response 'end)))
            (when prompt-id (block-set-state! buf prompt-id 'complete))
            (block-close-end! buf response-id (plist-get response 'end))
            (buffer-set-local! buf 'llm-active-response #f)
            (buffer-set-local! buf 'llm-active-result #f)
            (buffer-set-local! buf 'llm-active-prompt #f)
            (llm-mode--sync-addressable-responses! buf)
            (message "LLM response cancelled"))))))
;;; --- where the reply goes -----------------------------------------------------
;;; M-o answers at point. C-u M-o asks where (gptel: the send menu directs
;;; the output): at point, in the document's chat shown in the other
;;; window, in a new document, or over the region as a rewrite. Every
;;; target talks through the document's hidden chat; only the landing
;;; differs.

;; the reply streams into BUF below the block AT sits in
(define (llm-send-at-point! buf at)
    (let* ((context (llm-context-text buf (buffer-text buf)))
           ;; Where the answer belongs: after the block point sits in.
           (insert-at (llm-mode--insert-at buf at))
           (model (buffer-llm-model buf)))
      (unless (minor-mode-on? buf "llm-mode")
        (enable-minor-mode! buf "llm-mode"))
      ;; A rewritten earlier turn cannot be reconciled with a native thread.
      ;; Close it and send the edited whole transcript as a new conversation.
      (let ((resync (buffer-local buf 'llm-session-dirty)))
        (when resync (llm-mode-reset-runtime! buf #f))
        (let ((wire (if resync context (llm-mode--wire-text buf context))))
          (cond
            ((and (llm-mode--runtime-live? buf)
                  (not (equal? (agent-status (llm-mode--session-id buf)) 'idle)))
             (message "LLM is still working"))
            ((and (llm-mode--stateful? buf) (equal? wire ""))
             (message "Nothing new to send"))
            (else
              ;; Claim both sides of the turn before the request begins. The
              ;; response block is the only place the reply may land.
              (let* ((turn (llm-mode--begin-turn! buf at insert-at model))
                     (response-id (plist-get turn 'response)))
                (message (string-append "LLM thinking · " model))
                (llm-mode--complete buf wire context model response-id insert-at))))))))

;; the chat target: the same send with no inline render, and the chat
;; comes into the other window to show the reply. The document keeps no
;; block for this turn, so its next M-o sends the whole document again.
(define (llm-send-in-chat! buf)
  (let* ((context (llm-context-text buf (buffer-text buf)))
         (companion (llm-mode--companion! buf (buffer-llm-model buf)))
         (id (buffer-local companion 'agent-slug))
         (wire (llm-mode--wire-text buf context)))
    (unless (minor-mode-on? buf "llm-mode")
      (enable-minor-mode! buf "llm-mode"))
    (cond ((and (llm-mode--runtime-live? buf)
                (not (equal? (agent-status id) 'idle)))
           (message "LLM is still working") #f)
          ((and (llm-mode--stateful? buf) (equal? wire ""))
           (message "Nothing new to send") #f)
          (else
            (llm-session-send! id wire context)
            (display-buffer-other-window! companion)
            (message (string-append "LLM answers in " companion))
            companion))))

(define (llm-send--new-document-name buf)
  (let loop ((n 1))
    (let ((name (string-append "*llm:" buf
                               (if (= n 1) "" (string-append "<" (number->string n) ">"))
                               "*")))
      (if (buffer-exists? name) (loop (+ n 1)) name))))

;; the new-document target: a document of its own carries the prompt and
;; the reply, with the source document's model and connector. It is an
;; llm-mode document like any other, so it gets a hidden chat of its own
;; and its next M-o continues there.
(define (llm-send-in-new-document! buf)
  (let ((name (llm-send--new-document-name buf))
        (text (llm-context-text buf (buffer-text buf))))
    (buffer-create name)
    (for-each (lambda (key)
                (let ((v (buffer-local buf key)))
                  (when v (buffer-set-local! name key v))))
              '(llm-connector llm-model llm-companion-opts chat-presets
                chat-permission-mode default-directory))
    (buffer-insert! name 0 text)
    (with-current-buffer name (lambda () (set-mode! "morg-mode")))
    (enable-minor-mode! name "llm-mode")
    (display-buffer-other-window! name)
    (llm-send-at-point! name (buffer-size name))
    name))

(define (llm-send--groups buf)
  (list
    (list "Where the reply goes"
      (transient-suffix "p" "At point, in this document" "llm-send-here")
      (transient-suffix "c" "In the document's chat, in the other window" "llm-send-chat")
      (transient-suffix "n" "In a new document, in the other window" "llm-send-new-document")
      (transient-suffix "r" "Over the region, as a rewrite" "llm-rewrite"))))

(transient-define-prefix "llm-send-to" "Choose where the LLM reply goes" llm-send--groups)

(define-command "llm-send-here" "Send this document and stream the reply below the block at point"
  (lambda ()
    (let ((buf (or (transient-scope) (current-buffer))))
      (with-current-buffer buf (lambda () (llm-send-at-point! buf (point)))))))
(define-command "llm-send-chat" "Send this document; the reply shows in its chat in the other window"
  (lambda () (llm-send-in-chat! (or (transient-scope) (current-buffer)))))
(define-command "llm-send-new-document" "Send this document; a new document in the other window carries the reply"
  (lambda () (llm-send-in-new-document! (or (transient-scope) (current-buffer)))))

(define-command "llm-send-buffer" "Send this document to the LLM and stream its reply below the block at point; with C-u, choose where the reply goes"
  (lambda ()
    (if (current-prefix-arg)
        (transient-setup "llm-send-to" (current-buffer))
        (llm-send-at-point! (current-buffer) (point)))))

(global-set-key "M-o" "llm-send-buffer")
(global-set-key "C-c m" "llm-set-model")
(global-set-key "C-c b" "llm-configure")
(for-each (lambda (c) (catalog-meta! 'command c 'domain "llm" 'effects '("write" "external" "spend")))
  '("llm-send-buffer" "llm-send-here" "llm-send-chat" "llm-send-new-document"))
(catalog-meta! 'command "llm-send-to" 'domain "llm" 'effects '("read"))
(catalog-meta! 'command "llm-mode" 'domain "llm" 'effects '("write"))
(catalog-meta! 'mode "llm-mode" 'domain "llm" 'effects '("write"))

;;; --- chat buffer (gptel-style) -------------------------------------------------
;;; *chat* is an ordinary editable buffer. Type after the "### You" marker,
;;; press C-c RET, and the whole buffer becomes the conversation context.

(define (chat-prompt-marker) "\n### You\n")
(define (chat-reply-marker) "\n### Assistant\n")

;; a real mode so desktop restore can rebuild the local keys. A chat that
;; carries the block model ('agent-saved-mark) is a rich companion surface:
;; it opts into the same native renderer as agent threads, RET sends, and
;; a stale "⋯ thinking" from before a restart is swept away.
(mode-doc! "chat-mode"
  "A conversation with a model. `RET` sends what you typed and `S-RET` starts a new line. `C-g` stops the answer. `C-c C-k` clears the conversation but keeps the model.")

(define *chat-restart-message*
  "Continue the work interrupted by the editor restart. Recheck the current workspace state before acting.")

;; The mode setup calls this for a chat whose turn a restart interrupted.
;; The setup reads the turn flag BEFORE chat-sweep-runtime-locals! clears
;; it, so this fn must not read the flag again: it is always #f here.
;; A live runtime means the user or a retry already restarted the chat.
(define (chat-recover-interrupted! buf)
  (when (and (buffer-exists? buf)
             (not (chat-live-runtime? buf)))
    (if (boundp (quote agent-send-msg!))
        (begin
          (chat-finalize-hung-tools! buf)
          (let ((slug (chat-attach! buf)))
            (agent-send-msg! slug *chat-restart-message*)
            (message (string-append "agent " slug ": continuing after restart"))))
        (debounce! (string-append "chat-recover:" buf) 100
                   chat-recover-interrupted! buf))))

;; the transcript half of a lost turn: tool cards still "running", and
;; permission or question blocks that nobody can answer any more.
;; agent-transcript.scm owns these fns and loads later, so guard each call.
(define (chat-finalize-hung-tools! buf)
  (when (boundp (quote agent-finalize-running-tools!))
    (agent-finalize-running-tools! buf "failed"))
  (when (boundp (quote agent-block-drop-kind!))
    (agent-block-drop-kind! buf "permission")
    (agent-block-drop-kind! buf "question"))
  (when (boundp (quote chat-activity!))
    (chat-activity! buf #f)))

;; #t when the buffer says a turn runs and its live runtime says none does.
;; A real turn holds the agent in 'running or 'needs_attention, so 'idle
;; under the flag means the turn-end event was lost — a reload mid-turn,
;; or a crashed event handler. A restart cannot clear this state: the flag
;; is a conversation local, and the dead-runtime recovery does not fire
;; because the runtime is alive.
(define (chat-turn-stale? buf)
  (and (buffer-local buf 'chat-turn-active)
       (chat-live-runtime? buf)
       (equal? (agent-status (buffer-local buf 'agent-slug)) 'idle)))

;; land what the lost turn-end would have landed. Never invents a reply.
(define (chat-drop-stale-turn! buf)
  (buffer-set-local! buf 'chat-turn-active #f)
  (buffer-set-local! buf 'agent-cancelling #f)
  (buffer-set-local! buf 'agent-turn-text #f)
  (buffer-set-local! buf 'agent-turn-any #f)
  (chat-finalize-hung-tools! buf)
  (message "chat unstuck: the hung turn is cleared, RET sends again"))

;; The chat's companion directory: the git root of the directory the chat
;; was born in (buffer-create copies the spawner's default-directory), or
;; that directory outside a repo. One git-root call per chat, at birth.
(define (chat-stamp-directory! buf)
  (let* ((born (or (buffer-local buf 'default-directory)
                   (string-append (expand-path "~") "/")))
         (root (git-root born)))
    (buffer-set-local! buf 'chat-directory
      (if (and (string? root) (not (equal? root "")))
          (string-append root "/")
          born))))

(define-mode "chat-mode"
  (lambda ()
    (let ((buf (current-buffer))
          (interrupted? (buffer-local (current-buffer) 'chat-turn-active)))
      ;; the transcript is a rendering of the chat log, which is the record
      ;; of who said what: a history of the rendering says nothing the log
      ;; does not, so the mode keeps none, and drops any an open or a
      ;; restore recorded before this setup ran
      (buffer-provenance-discard! buf "mode:chat-mode" "mode-policy" "mode")
      ;; On desktop restore EVERY runtime local is a lie: the process it
      ;; described died with the daemon. Clear the whole class — not just
      ;; the 'agent-queued that once deadlocked RET — so that bug cannot
      ;; grow a new head. Guarded on the runtime being gone, because this
      ;; same setup fn also runs via set-mode! on LIVE chats, where the
      ;; slug is the only handle on a running thread.
      (chat-sweep-runtime-locals! buf)
      (when interrupted?
        (if (chat-live-runtime? buf)
            ;; the runtime survived but its turn did not: land the lost
            ;; turn-end so the chat does not stay hung on a tool call
            (when (chat-turn-stale? buf) (chat-drop-stale-turn! buf))
            (debounce! (string-append "chat-recover:" buf) 100
                       chat-recover-interrupted! buf)))
      ;; the companion directory is identity: stamped once, never derived
      (unless (buffer-local buf 'chat-directory)
        (chat-stamp-directory! buf))
      ;; a .chat file just opened from disk: if we wrote it, its header
      ;; restores the identity and its transcript becomes the record, so
      ;; the conversation continues instead of restarting. Headerless files
      ;; (hand-written, or saved before this) are left exactly as they are.
      (when (and (buffer-path buf)
                 (not (buffer-local buf 'agent-saved-mark))
                 (boundp (quote chat-file-init!)))
        (chat-file-init! buf))
      (when (buffer-local buf 'agent-saved-mark)
        ;; the view is identity: default it only when never chosen (S11)
        (when (member (buffer-local buf 'render-mode) '(#f "agent"))
          (buffer-set-local! buf 'render-mode "blocks"))
        ;; Rebuild presentation from the CONVERSATION locals — overlays and
        ;; folds come back, and chrome belonging to a runtime that didn't
        ;; survive the restart is dropped. None of this depends on there
        ;; being a live thread (the sweep above may just have removed the
        ;; slug), so it is not gated on one.
        (when (boundp (quote agent-block-drop-kind!))
          (agent-block-drop-kind! buf "permission")
          ;; a LIVE runtime owns its waiting line, its queue, and its
          ;; pending prose tail; a dead one leaves stale chrome to sweep
          (unless (chat-live-runtime? buf)
            ;; the waiting line and its block leave together
            (agent-sweep-waiting! buf)
            ;; a queued message the dead runtime never read returns to
            ;; the input
            (agent-unqueue-renders-to-input! buf)
            ;; prose the dead runtime streamed but never revealed joins
            ;; the prose block
            (agent-adopt-prose-tail! buf))
          ;; coalesced once here: a chat saved before the join in
          ;; agent-add-overlay! holds one range per streamed delta
          (let ((ovs (buffer-local buf 'agent-overlays)))
            (when ovs
              (let ((joined (agent-overlays-coalesce ovs)))
                (unless (= (length joined) (length ovs))
                  (buffer-set-local! buf 'agent-overlays joined))
                (overlay-set! buf 'agent joined))))
          (agent-apply-folds! buf))
        ;; the modeline states the chat's identity — its connector, which
        ;; survives everything. A chat that has never attached one will
        ;; get "api" on its first send, so that is what it advertises.
        (if (and (buffer-local buf 'agent-connector)
                 (boundp (quote agent-update-modeline!)))
            (agent-update-modeline! buf)
            (begin
              (buffer-set-local! buf 'modeline-info #f)
              (buffer-set-local! buf 'modeline-info-command #f)
              (buffer-set-local! buf 'modeline-preset #f)))
        (agent-clear-waiting! buf)
        ;; ONE key set for every chat: RET is agent-send everywhere — a
        ;; chat without a runtime attaches the api backend on first send
        (when (boundp (quote agent-install-keys!))
          (agent-install-keys! buf))
        ;; a restored point can land inside the marker — typing/pasting
        ;; there corrupts the input boundary (bytes end up pre-marker)
        (chat-snap-to-input!)))))

;; the chat's editor keys; agent-session.scm adds the send and permission
;; keys to the same map
(mode-keys! "chat-mode"
  '(("C-c m" "chat-set-model") ("C-c $" "chat-cost") ("C-c b" "llm-configure")
    ("C-c C-k" "chat-reset") ("S-RET" "newline") ("C-c C-v" "chat-toggle-view")))

;; Stop the chat runtime but keep its transcript.
(mode-keys! "chat-mode" '(("C-c k" "kill-buffer")))


;; there is only one chat interface: the rich group-chat surface. C-c c
;; opens the current buffer's group chat (founding a group if needed);
;; from inside a chat it is a no-op.
(define-command "chat" "Open the group chat for this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (unless (chat-buffer? cur)
        (group-chat-show! (group-ensure! cur))))))

;;; The system prompt is the cache prefix. Every byte is resent on every turn
;;; and tool round, so changing group membership must not change it. The static
;;; context section tells the agent to call chat-context for current members,
;;; roles, companions, workspace, and visible state.

;; Stable instructions for reading and changing live buffers. Prompt composition
;; places this text in the selectable code section.
(define *chat-edit-protocol*
  (string-append
    "Never guess buffer contents. With eval-scheme, inspect source via "
    "(code-outline \"NAME\") and (code-read \"NAME\" LINE); edit via "
    "(code-replace! \"NAME\" LINE NEW) or (code-sexp-replace! \"NAME\" "
    "ANCHOR NEW). Read prose with (buffer-text \"NAME\") and make exact "
    "text edits with (buffer-replace! \"NAME\" OLD NEW). Edits affect the "
    "live buffer and never display it. Treat \"buffer\" and \"window\" precisely. When the "
    "user says \"open it in the other buffer\" or \"show it in the other "
    "buffer\", show the named target with (display-buffer-other-window! NAME). "
    "When the user says \"switch to "
    "the other buffer\", run (run-command \"previous-buffer\"). Do not ask a "
    "question when the target is clear."))

;; The dynamic group belongs to chat-context, not to the cached prompt.
;; These fragments stay stable while buffers join, leave, or change roles.
(define (chat-code-prompt _buf)
  (string-append
    *chat-edit-protocol*
    (if (and (boundp (quote code-instructions))
             (not (equal? code-instructions "")))
        (string-append "\n\n" code-instructions)
        "")))

(define (chat-preamble _buf)
  (chat-preamble-body #f '()))

(define (chat-preamble-body _g _docs)
  (string-append
    "You are the assistant in an editor chat buffer. The transcript "
    "follows; reply to the last user turn only, in markdown.\n\n"))

;;; --- chat backends -------------------------------------------------------------
;;; A chat can ride an ACP agent (claude-code, codex — subscription billing)
;;; instead of the metered API: the buffer stays the same conversation, a
;;; thread binds to it by slug, and the agent's MCP servers come from the
;;; chat's presets plus the editor's own tool proxy. C-c b switches.

;; opts (a config plist) rides in front, so per-call keys — cmd, model,
;; cwd — win over the connector's declared config, first-wins
;; the slug IS the chat's durable id ('chat-id), made git-ref safe for
;; the agent/<slug> worktree branch. A per-boot counter collides across
;; restarts — a restored buffer can claim a live slug and take its
;; events — and a stale 'agent-slug local from an old boot is just as
;; wrong, so neither is consulted: the chat's runtime belongs to the chat.
(define (chat-runtime-slug buf)
  (string-join (string-split (chat-stable-id! buf) ":") "-"))

(define (chat-attach-agent! buf connector &optional model opts)
  (let ((slug (chat-runtime-slug buf))
        ;; a model pinned on the buffer (C-c m before the first send, or a
        ;; .chat header) is part of the chat's identity — carry it in, but
        ;; only if it actually belongs to THIS connector: a bare id left
        ;; over from an earlier ACP session (its own "default" sentinel,
        ;; say) must not ride into the api lane's wire unmodified
        (model (if (and model (not (equal? model "")))
                   model
                   (agent-model-for-connector buf connector))))
    (buffer-set-local! buf 'agent-slug slug)
    (buffer-set-local! buf 'agent-connector connector)
    (when (and model (not (equal? model "")))
      (buffer-set-local! buf 'agent-model model))
    (let ((mark (or (buffer-local buf 'agent-saved-mark)
                    ;; plain chat: give it the marker structure threads use
                    (let ((m (buffer-size buf)))
                      (buffer-set-local! buf 'agent-marker-bytes 0)
                      (buffer-set-local! buf 'render-mode "blocks")
                      m))))
      (buffer-set-local! buf 'agent-saved-mark mark)
      (agent-install-keys! buf)
      (agent-update-modeline! buf)
      ;; the previous incarnation of this chat's session can still be
      ;; registered — a dead backend keeps its process. Free the id so the
      ;; same chat can open it again.
      (when (member slug (agent-list))
        (llm-session-close! slug))
      (llm-session-open! slug
        (append (list 'buffer buf 'mark mark)
                (agent-resolve-config
                  (append
                    ;; isolation (packages/worktrees.scm): an isolated
                    ;; thread gets its own worktree as cwd
                    (if (boundp (quote agent-worktree-opts))
                        (agent-worktree-opts buf slug opts)
                        (or opts '()))
                    (list 'connector connector 'buffer buf
                          'presets (if (boundp (quote chat-presets-of))
                                       (chat-presets-of buf)
                                       '()))
                    ;; the session this conversation already lives in, when
                    ;; the same connector issued it: the adapter loads it
                    ;; instead of starting empty
                    (let ((sid (buffer-local buf 'agent-session)))
                      (if (and sid
                               (equal? (buffer-local buf 'agent-session-connector)
                                       connector))
                          (list 'resume-session sid)
                          '()))
                    (list 'idle-seconds agent-idle-seconds)
                    (let ((effort (buffer-local buf 'agent-effort)))
                      (if effort (list 'effort effort) '()))
                    (if (and model (not (equal? model "")))
                        (list 'model model)
                        '())))))
      slug)))

;; Every chat surface is built the same way: one meta card of help, then
;; the >>> you: input region. Only the card's words differ, so only the
;; words are a parameter — the two builders had drifted into setting
;; different locals for the same layout.
(define (chat-surface-init! buf title lines)
  (let ((help (string-append title "\n" lines)))
    (buffer-append! buf help)
    (agent-block-push! buf 0 (string-byte-length help) "meta" '())
    (buffer-set-local! buf 'agent-saved-mark (string-byte-length help))
    (buffer-set-local! buf 'agent-marker-bytes 0)
    buf))

;; a task chat's surface, used by (execute ...)
(define (chat-task-init! buf label)
  (chat-surface-init! buf (string-append "chat · " label)
    (string-append
      "RET sends · C-g aborts · C-RET interrupts · TAB folds tool output · "
      "C-c b LLM and tools · C-c m model\n")))

;; a chat saved as a file IS a revivable conversation: the transcript
;; format is ### You / ### Assistant (whole buffer = context) and .chat
;; files open straight into chat-mode. One save gesture — C-x C-s — does
;; the right thing: block chats flatten to that portable form via this
;; helper; everything else saves its text.
(define (chat-flatten buf)
  (and (buffer-local buf 'agent-saved-mark)
       (pair? (chat-turns buf))
       (let loop ((ts (reverse (chat-turns buf))) (acc ""))
         (if (null? ts)
             (string-append acc (chat-prompt-marker))
             (loop (cdr ts)
                   (string-append acc
                     (cond ((equal? (car (car ts)) "user")
                            (chat-prompt-marker))
                           ((equal? (car (car ts)) "status")
                            "\n### Status\n")
                           (else (chat-reply-marker)))
                     (cadr (car ts)) "\n"))))))

;;; --- .chat files carry their identity ------------------------------------------
;;; A flattened transcript is text; a chat is text PLUS who was running it.
;;; One optional header line closes that gap, so an opened .chat continues
;;; where it ran instead of starting over on the default backend:
;;;
;;;   #+chat: (connector "codex" model "gpt-5.5" presets (dev) permission-mode approve)
;;;
;;; The header is written by us and read on visit. It never reaches a
;;; model: chat-flatten (the seed) does not include it. Headerless files —
;;; anything written before this, or by hand — behave exactly as before.

(define *chat-file-header* "#+chat:")

;; connector, model and effort are strings everywhere else that touches
;; them: the bundle vocabulary compares them with equal?, the modeline
;; appends them, and the llm-configure transient prints them. A header
;; that spells one as a bare symbol — an old file, a hand edit — puts a
;; symbol in the buffer-local, and the writer below then spells it bare
;; again, so the two keep each other alive until something tries to
;; print it. Coerce on the way out and on the way in. presets and
;; permission-mode stay symbols, which is what they are.
(define (chat-header-string v)
  (if (symbol? v) (symbol->string v) v))

(define *chat-header-strings* '(connector model effort title summary directory))

(define (chat-header-line buf)
  (string-append *chat-file-header* " (connector "
    (value->string (chat-header-string (or (buffer-local buf 'agent-connector) "api")))
    (let ((m (buffer-local buf 'agent-model)))
      (if m (string-append " model " (value->string (chat-header-string m))) ""))
    (let ((effort (buffer-local buf 'agent-effort)))
      (if effort (string-append " effort " (value->string (chat-header-string effort))) ""))
    (let ((ps (buffer-local buf 'chat-presets)))
      (if (pair? ps) (string-append " presets " (value->string ps)) ""))
    (let ((d (buffer-local buf 'chat-directory)))
      (if (string? d) (string-append " directory " (value->string d)) ""))
    (let ((s (and (boundp (quote chat-title-of)) (chat-title-of buf))))
      (if (and (string? s) (not (equal? s "")))
          (string-append " title " (value->string s))
          ""))
    (let ((s (buffer-local buf 'chat-summary)))
      (if (and (string? s) (not (equal? s "")))
          (string-append " summary " (value->string s))
          ""))
    " permission-mode "
    (symbol->string (if (boundp (quote chat-permission-mode))
                        (chat-permission-mode buf)
                        'approve))
    ")\n"))

;;; The v2 section carries what the transcript cannot: the conversation of
;;; record, tool calls and tool results included, as one JSON line below
;;; the transcript. Everything above it is exactly what v1 wrote, so a v2
;;; file still reads as a v1 file, and a v1 file (or a hand-written one)
;;; still opens — it simply has no blocks to replay.

(define *chat-record-marker* "#+chat-record: ")

;; what C-x C-s writes: identity, the portable transcript, then the record
(define (chat-file-text buf)
  (let ((body (chat-flatten buf)))
    (and body
         (string-append (chat-header-line buf) body
           (let ((r (chat-record buf)))
             (if (null? r)
                 ""
                 (string-append "\n" *chat-record-marker*
                                (json-encode (reverse r)) "\n")))))))

;; where the record section starts, in bytes, or #f
(define (chat-file-record-at text)
  (string-index text (string-append "\n" *chat-record-marker*)))

;; the recorded turns, oldest first, or #f
(define (chat-file-record text)
  (let ((i (chat-file-record-at text)))
    (and i
         (let* ((start (+ i 1 (string-byte-length *chat-record-marker*)))
                (rest (substring-bytes text start (string-byte-length text)))
                (nl (string-index rest "\n"))
                (v (json-parse (if nl (substring-bytes rest 0 nl) rest))))
           (and (pair? v) v)))))

;; the header's plist, or #f. Read INSIDE a quote so a hand-edited file can
;; never execute anything: the reader sees one quoted datum, and a failed
;; read just means "no header".
(define (chat-parse-header line)
  (and (string-prefix? *chat-file-header* line)
       (let ((r (eval-string-safe
                  (string-append "(quote "
                                 (substring line (string-length *chat-file-header*)
                                            (string-length line))
                                 ")"))))
         (and (equal? (car r) 'ok) (pair? (cadr r)) (cadr r)))))

;; "### You\nhi\n\n### Assistant\nhello\n" -> (("user" "hi") ("assistant" "hello"))
(define (chat-parse-transcript text)
  (let loop ((parts (cdr (string-split text "\n### "))) (acc '()))
    (if (null? parts)
        (reverse acc)
        (let* ((p (car parts))
               (role (cond ((string-prefix? "You\n" p) "user")
                           ((string-prefix? "Assistant\n" p) "assistant")
                           ((string-prefix? "Status\n" p) "status")
                           (else #f)))
               ;; string-index counts bytes, so the cut must too — a
               ;; transcript is arbitrary prose, not ASCII
               (body (and role
                          (string-trim
                            (substring-bytes p (string-index p "\n")
                                             (string-byte-length p))))))
          (loop (cdr parts)
                (if (and role (not (equal? body "")))
                    (cons (list role body) acc)
                    acc))))))

;; a headered .chat opened from disk becomes a live chat again: its
;; identity comes back, its turns become the conversation of record (the
;; truth every backend runs against), and the rich surface is rebuilt from
;; those turns so RET continues the conversation.
(define (chat-file-init! buf)
  (let* ((text (buffer-text buf))
         (nl (string-index text "\n"))
         (line (if nl (substring-bytes text 0 nl) text))
         (header (chat-parse-header line)))
    (when header
      (for-each
        (lambda (pair)
          (let ((v (plist-get header (car pair))))
            (when v
              (buffer-set-local! buf (cadr pair)
                (if (member (car pair) *chat-header-strings*)
                    (chat-header-string v)
                    v)))))
        '((connector agent-connector) (model agent-model) (effort agent-effort)
          (presets chat-presets) (permission-mode chat-permission-mode)
          (title chat-title) (summary chat-summary)
          (directory chat-directory)))
      ;; A chat wears its title, not its file name. chat-restore renamed
      ;; the buffer itself; every other door into an archived conversation
      ;; -- the desktop, the chats list, plain find-file -- left it named
      ;; after the .chat path, so the modeline said the path.
      (let ((title (buffer-local buf 'chat-title)))
        (when (and (string? title) (not (equal? (string-trim title) "")))
          (rename-buffer! buf title)))
      (let* ((end (or (chat-file-record-at text) (string-byte-length text)))
             (recorded (chat-file-record text))
             (turns (chat-parse-transcript (substring-bytes text (or nl 0) end))))
        ;; v2 replays the record whole — tool calls and tool results come
        ;; back, so the next request repeats the prefix the file recorded.
        ;; v1 has only the transcript: its turns become text turns.
        (buffer-set-local! buf 'chat-wire-turns
          (if recorded
              (reverse recorded)
              (map (lambda (t) (list 'role (car t)
                                     'blocks (list (list "text" (car (cdr t))))))
                   (reverse turns))))
        ;; rebuild the surface from the turns, exactly as a live chat
        ;; renders them — the header and the ### markers are file format,
        ;; not transcript
        (buffer-delete-range! buf 0 (buffer-size buf))
        (buffer-set-local! buf 'agent-blocks '())
        (buffer-set-local! buf 'agent-saved-mark 0)
        (for-each
          (lambda (t)
            (let* ((role (car t))
                   (start (chat-render! buf
                            (cond ((equal? role "user")
                                   (string-append "\n>>> you: " (cadr t) "\n\n"))
                                  ((equal? role "status")
                                   (string-append "\n" (cadr t) "\n\n"))
                                  (else (string-append (cadr t) "\n"))))))
              (agent-block-push! buf start (chat-mark buf)
                (cond ((equal? role "user") "user")
                      ((equal? role "status") "status")
                      (else "prose"))
                (if (equal? role "user") (list (cadr t)) '()))))
          turns)
        (buffer-set-local! buf 'agent-marker-bytes 0)
        (buffer-set-local! buf 'render-mode "blocks")
        ;; a fresh ACP session has to be told what was already said; the
        ;; api lane replays the record on every request anyway
        (buffer-set-local! buf 'agent-seed-context
          (and (pair? turns)
               (boundp (quote connector-can?))
               (not (chat-stateless? buf))))
        ;; the rewrite is presentation, not an edit the user made
        (buffer-mark-saved! buf))
      #t)))

;;; --- what a chat is made of -----------------------------------------------------
;;; The reset/restore bug class (a stale 'agent-queued deadlocking RET, a
;;; banner from a runtime that no longer exists, a help card fed back to a
;;; model as context) had ONE cause: which local means what was implicit,
;;; and reset, restore, and save each kept their own partial list. So the
;;; partition is defined once, here, and everything else consults it.
;;;
;;; STANDING RULE: any new chat buffer-local goes into exactly one of these
;;; three lists, in the same commit that introduces it.

;; who the chat IS — survives reset, restart, and save
;; ('default-directory is on every buffer, chats included: where it was
;; opened from, which is identity, not conversation or runtime)
;; 'render-mode is the chat's chosen VIEW ("blocks" rich, "plain" text) —
;; a choice about the chat, so identity (S11)
;; An idle adapter is two OS processes and up to a few hundred MB for a
;; conversation nobody is having. A chat idle this long closes its adapter
;; and keeps the session; the next message reopens it on the same session.
;; 0 keeps every adapter running.
(require 'custom)
(defcustom 'agent-idle-seconds 600
  "Seconds a chat is idle before its adapter closes; 0 keeps every adapter running.")

(define chat-identity-locals
  '(group group-id modeline-groups chat-id group-meta group-layout group-noise
    ;; the last name the chat DERIVED from its group: a name the person
    ;; typed does not match it, and that is what makes a manual rename stick
    chat-derived-name
    agent-connector agent-model agent-effort
    chat-presets prompt-disabled-parts chat-permission-mode render-mode default-directory
    ;; the directory the spawner chose; group companions never override it
    chat-directory
    agent-permission-profile window-class header-line
    ;; which locals are markers is a fact about how the buffer works, so
    ;; it survives a reset with the rest of the identity
    marker-locals
    code-agent-saved
    workspace-id workspace-name workspace-root workspace-project-root
    workspace-backend workspace-daemon workspace-llm-defaults
    workspace-isolation-choice project-defaults-inherited chat-companion-of
    ;; the group whose group-on-chat hooks this chat already ran: a chat takes them
    ;; once, so the mark has to outlive a restart
    group-config-loaded))

;; what was SAID — survives restart and save; reset clears it
;; ('chat-turns is the pre-record shape: chat-record-migrate! reads it once
;; on setup and clears it, and it stays listed so a reset cannot leave one
;; behind for the migration to read again)
(define chat-conversation-locals
  '(chat-wire-turns chat-turns agent-blocks agent-overlays agent-folds
    agent-open-cards
    chat-turn-active
    ;; where the unrevealed prose tail starts: text the model said that
    ;; the prose block does not cover yet — restore adopts it, reset
    ;; clears it with the transcript
    agent-prose-from
    chat-tool-specs
    ;; The exact named system fragments this conversation sends. The first
    ;; turn sets them. Prompt refresh replaces them. Reset clears them.
    chat-prompt-snapshot
    chat-cost chat-last-usage chat-usage-total
    ;; a one-shot note for the next send (a skill body a mode pushed):
    ;; undelivered it must survive a restart, and a reset drops it
    chat-note-once
    ;; images the user pasted and did not send yet: same rule as the note,
    ;; they survive a restart and a reset drops them
    chat-pending-images
    ;; the file this conversation logs itself to under <compos-home>/chats:
    ;; a reset starts a new conversation, which gets a new file, and the
    ;; old file stays as the archive
    chat-log-id
    ;; the backend session this conversation lives in, and the connector
    ;; that issued it: a parked adapter, a revive and a restart reopen the
    ;; same session (ACP session/load); a reset starts a new one
    agent-session agent-session-connector
    ;; the running summary and every paragraph before it: a reset starts
    ;; a new conversation with nothing to say yet
    chat-summary chat-summary-log
    ;; this chat had a runtime and something took it away, so chats-start-all
    ;; knows what to open again. A conversation local, not a global: the flag
    ;; outlives a daemon restart the way chat-turn-active does, and a reset
    ;; drops it with the rest of the conversation
    chat-was-running
    ;; and the title the first one wrote, fixed for the life of the
    ;; conversation: a reset earns a new one
    chat-title
    agent-saved-mark agent-marker-bytes))

;; PROCESS state — mirrors a live runtime, so it is always stale after a
;; restart and meaningless after a reset: both clear it wholesale
;; ('agent-queued is retired — queued messages live in the transcript as
;; "queued" blocks now — but stays listed so old sessions' stale values
;; are still swept)
(define chat-runtime-locals
  '(agent-slug agent-queued agent-waiting chat-activity
    inline-target inline-turn
    agent-cancelling agent-seed-context agent-tool-bodies
    agent-turn-text agent-turn-any chat-compacting
    agent-models agent-mode agent-modes chat-mcp-dirty
    chat-history-pos chat-history-draft
    ;; the rich view's tree, rebuilt from the conversation by
    ;; chat-view-sync!, and the reader's place in it
    render-blocks render-root render-input follow-place follow-seq
    ;; how many earlier budgets of the transcript the reader revealed
    chat-view-reveal
    code-agent-switch-pending prompt-parts editing-state
    ;; set by a turn the connector answered with silence, read once by the
    ;; reconnect at the end of that batch
    chat-connector-suspect))

(define (chat-clear-locals! buf keys)
  (for-each (lambda (k) (buffer-set-local! buf k #f)) keys))

;; a chat whose runtime is gone (restored from desktop, or crashed) is
;; carrying a description of a process that no longer exists — drop it.
;; A LIVE runtime's locals are the handle on it and must never be swept.
(define (chat-live-runtime? buf)
  (let ((slug (buffer-local buf 'agent-slug)))
    (and slug
         (boundp (quote agent-list))
         (member slug (agent-list))
         ;; slugs restart at a1 on every boot: a live slug bound to a
         ;; DIFFERENT buffer is another chat's runtime, not this one's.
         ;; Say #f so the sweep clears the stale local.
         (let ((owner (plist-get (agent-info slug) 'buffer)))
           (or (not owner) (equal? owner buf)))
         #t)))

(define (chat-sweep-runtime-locals! buf)
  (unless (chat-live-runtime? buf)
    (chat-clear-locals! buf chat-runtime-locals)
    ;; chat-turn-active is a CONVERSATION local, so it outlives a restart --
    ;; and the process that was running the turn does not. No status event
    ;; can ever arrive for a runtime that is gone, so this is the one place
    ;; the news can reach the view: no runtime, no turn. Without it a
    ;; restored chat waits on a turn nobody is running, and every RET queues
    ;; behind it.
    (buffer-set-local! buf 'chat-turn-active #f)))

;; wipe the conversation, keep the identity: group, backend, model,
;; presets and permission mode survive; every chat comes back as the one
;; rich surface (a legacy plain chat upgrades on reset). Idempotent.
(define-command "chat-reset" "Reset this chat: clear the transcript, start fresh"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (let ((g (buffer-group buf))
                (titled? (string? (buffer-local buf 'chat-title))))
            ;; FIRST: resolve anything the runtime is waiting on. A pending
            ;; permission answered after its blocks are gone is the
            ;; blind-banner race; killing the thread resolves it cancelled.
            (let ((slug (buffer-local buf 'agent-slug)))
              (when (and slug (boundp (quote llm-session-close!)))
                (unless (equal? (agent-status slug) 'dead)
                  (llm-session-close! slug))))
            (overlay-clear! buf "all")
            ;; every tag: a reset empties the buffer, so no owner's ranges
            ;; still mean anything
            (fold-clear! buf 'all)
            (chat-clear-locals! buf chat-conversation-locals)
            (chat-clear-locals! buf chat-runtime-locals)
            (buffer-delete-range! buf 0 (buffer-size buf))
            ;; the title named the old conversation: go back to a fresh
            ;; untitled name so the next prompt titles it again
            (let ((buf (let ((fresh (and titled? g (group-chat-new-name g))))
                         (if (and fresh (rename-buffer! buf fresh)) fresh buf))))
              (group-chat-init! buf (or g buf))
              (with-current-buffer buf
                (lambda () (set-mode! "chat-mode") (end-of-buffer!)))
              (message "Chat reset")))))))

;; the manual door for the same repair the mode setup runs on restore. A
;; turn that shows as running while the runtime is idle or gone stays hung
;; forever without it, because no event will ever clear the flag.
(define-command "chat-unstick" "Clear a turn this chat shows as running when no runtime runs one"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
         (message "not a chat buffer"))
        ((not (buffer-local buf 'chat-turn-active))
         (message "no turn is stuck in this chat"))
        ((and (chat-live-runtime? buf) (not (chat-turn-stale? buf)))
         (message "this turn is live: C-g cancels it"))
        (else (chat-drop-stale-turn! buf))))))

;;; --- switching, transparently ---------------------------------------------------
;;; "Transparent" means testable: the buffer, its group, the record,
;;; presets, permission mode, cost history, and keybindings survive EVERY
;;; switch — the user just keeps typing. Keys are free (RET is agent-send
;;; on every lane), so one function with two mechanisms covers it:
;;;
;;;   live session + backend takes the model + target is offered
;;;       -> set_model in place; server-side context survives
;;;   anything else (lane change, dead session, model not takeable)
;;;       -> close the handle, attach the new backend, seed the transcript

;; can this chat's RUNNING backend take this model without a new session?
(define (chat-model-takeable? buf slug model)
  (and slug
       (not (equal? (agent-status slug) 'dead))
       (let ((cname (or (buffer-local buf 'agent-connector) *default-connector*)))
         (or (connector-can? cname 'stateless)   ; no session to lose
             (let ((offered (map car (or (buffer-local buf 'agent-models) '()))))
               (and (pair? offered) (member model offered)))))))

;; a transcript from before the mark was a buffer-local: it sits at the
;; marker's last occurrence
(define (chat-legacy-mark buf)
  (let loop ((ms (re-find* *chat-input-marker* (buffer-text buf)))
             (last (buffer-size buf)))
    (if (null? ms) last (loop (cdr ms) (car (car ms))))))

;; ONE attach. A chat that never had a runtime and a chat whose runtime
;; died are the same situation: put a fresh thread on the chat's OWN
;; connector — identity survives resets, restarts, and the runtime sweep,
;; so a restored claude-code chat comes back as claude-code — and tell it
;; what was already said. The two functions that did this had drifted:
;; one reset 'agent-queued and rescued a legacy mark, the other decided
;; seeding from a different test.
(define (chat-attach! buf)
  (let* ((cname (or (buffer-local buf 'agent-connector) "api"))
         (mark (or (buffer-local buf 'agent-saved-mark) (chat-legacy-mark buf)))
         (said (string-trim (agent-seed-transcript buf))))
    (buffer-set-local! buf 'agent-saved-mark mark)
    ;; a fresh ACP session starts empty and has to be seeded; one the same
    ;; connector issued before (agent-session) remembers the conversation
    ;; and loads instead; the api lane replays the record on every request
    ;; anyway
    (let ((resume (and (buffer-local buf 'agent-session)
                       (equal? (buffer-local buf 'agent-session-connector) cname))))
      (buffer-set-local! buf 'agent-seed-context
        (and (not resume) (not (connector-can? cname 'stateless))
             (> mark 0) (not (equal? said ""))))
      (let ((slug (chat-attach-agent! buf cname)))
        ;; a chat that comes back leaves no "[agent stopped]" line behind
        (when (boundp (quote agent-drop-stopped-markers!))
          (agent-drop-stopped-markers! buf))
        (unless (equal? said "")
          (message (string-append "agent " slug
                                  (if resume
                                      ": reopening its session"
                                      ": revived (fresh session)"))))
        slug))))

(define (chat-ensure-runtime! buf)
  (or (buffer-local buf 'agent-slug) (chat-attach! buf)))

;; the one switch. connector #f keeps the current one; model "" means the
;; connector's own default. An omitted effort preserves it on the same lane;
;; "default" asks the backend to use the selected model's default.
(define (chat-switch! buf connector model &optional effort)
  (let* ((slug (buffer-local buf 'agent-slug))
         (cur (or (buffer-local buf 'agent-connector) *default-connector*))
         (cname (or connector cur))
         (same-lane? (equal? cname cur)))
    (cond
      ;; in place: nothing restarts, so nothing can be lost
      ((and same-lane? slug (not (equal? (agent-status slug) 'dead))
            (or (equal? model "")
                (and (chat-model-takeable? buf slug model)
                     (llm-session-set-model! slug model)))
            (or (not effort) (llm-session-set-effort! slug effort)))
       (unless (equal? model "") (buffer-set-local! buf 'agent-model model))
       (when effort
         (buffer-set-local! buf 'agent-effort
           (if (equal? effort "default") #f effort)))
       (agent-update-modeline! buf)
       'in-place)
      (else
        ;; identity that belongs to the OLD backend must not follow the
        ;; conversation across (a foreign model id is silently ignored by
        ;; an adapter while the modeline keeps repeating it)
        (unless same-lane?
          (buffer-set-local! buf 'agent-models #f)
          (buffer-set-local! buf 'agent-modes #f)
          (buffer-set-local! buf 'agent-mode #f)
          ;; a mode parked for the old backend names nothing on the new one
          (buffer-set-local! buf 'agent-mode-wanted #f)
          (buffer-set-local! buf 'agent-effort #f))
        (when effort
          (buffer-set-local! buf 'agent-effort
            (if (equal? effort "default") #f effort)))
        (buffer-set-local! buf 'chat-mcp-dirty #f)
        ;; the restart itself is agent-reconnect!'s job — the same one
        ;; C-RET and a preset change use. Reimplementing it here is how
        ;; the two paths drifted.
        (if slug
            (agent-reconnect! slug cname model)
            (begin
              (buffer-set-local! buf 'agent-connector cname)
              (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
              (chat-attach! buf)))
        'reattached))))

(define (chat-llm-apply! buf connector model effort)
  (chat-switch! buf connector (if (equal? model "default") "" model) effort)
  (message
    (string-append "chat LLM: " connector
      (if (equal? model "default") "" (string-append " · " model))
      (if (equal? effort "default") "" (string-append " · " effort))
      " — the conversation carries over")))

;;; --- one LLM setup, whole -------------------------------------------------
;;; A bundle is the ENTIRE choice behind C-c b: the backend, the model, the
;;; reasoning effort, the tool presets that session loads, and the permission
;;; stance it runs under. Remembering three of those five and dropping the
;;; rest is how a recalled combination came back with the wrong tools. A
;;; bundle that carries a name is one you keep.
;;;
;;; The representation is a plist, so a new field costs nothing that is
;;; already on disk:
;;;   (name "review" key "A" connector "claude-code" model "opus[1m]" effort "high"
;;;    presets (compos web) permission "ask" agent-mode "plan")

(define (llm-bundle-get bundle key fallback)
  (let loop ((xs bundle))
    (cond ((or (not (pair? xs)) (not (pair? (cdr xs)))) fallback)
          ((equal? (car xs) key) (cadr xs))
          (else (loop (cdr (cdr xs)))))))

(define (llm-bundle-put bundle key value)
  (append (list key value)
    (let loop ((xs bundle))
      (cond ((or (not (pair? xs)) (not (pair? (cdr xs)))) '())
            ((equal? (car xs) key) (loop (cdr (cdr xs))))
            (else (cons (car xs) (cons (cadr xs) (loop (cdr (cdr xs))))))))))

;; The persisted history predates presets: an old entry is a bare
;; (CONNECTOR MODEL EFFORT) list. It reads as a bundle that names no presets
;; and takes no stance, so recalling it changes only what it knew.
(define (llm-bundle-normalize b)
  (if (and (pair? b) (string? (car b)))
      (list 'connector (car b)
            'model (if (pair? (cdr b)) (cadr b) "default")
            'effort (if (and (pair? (cdr b)) (pair? (cdr (cdr b))))
                        (caddr b)
                        "default"))
      b))

(define (llm-bundle-name b) (llm-bundle-get b 'name #f))
(define (llm-bundle-key b) (llm-bundle-get b 'key #f))
(define (llm-bundle-connector b) (llm-bundle-get b 'connector *default-connector*))
(define (llm-bundle-model b) (llm-bundle-get b 'model "default"))
(define (llm-bundle-effort b) (llm-bundle-get b 'effort "default"))

;; #f is "this bundle recorded no presets", and applying it keeps the ones
;; already loaded. The empty list is "exactly none", which is a choice.
(define (llm-bundle-presets b) (llm-bundle-get b 'presets #f))
(define (llm-bundle-permission b) (llm-bundle-get b 'permission #f))
(define (llm-bundle-agent-mode b) (llm-bundle-get b 'agent-mode #f))
(define (llm-bundle-prompt-disabled b) (llm-bundle-get b 'prompt-disabled #f))

;; What a bundle SETS, without its name: two bundles that configure the
;; same session are one recent choice, however each was reached.
(define (llm-bundle-setup b)
  (list (llm-bundle-connector b) (llm-bundle-model b) (llm-bundle-effort b)
        (llm-bundle-presets b) (llm-bundle-permission b)
        (llm-bundle-agent-mode b) (llm-bundle-prompt-disabled b)))

;; The whole setup on one line, with every part that is already the default
;; left out: a label says what is unusual about this bundle.
(define (llm-bundle-label b)
  (string-join
    (append
      (list (llm-bundle-connector b))
      (let ((m (llm-bundle-model b))) (if (equal? m "default") '() (list m)))
      (let ((e (llm-bundle-effort b))) (if (equal? e "default") '() (list e)))
      (let* ((p (llm-bundle-presets b))
             (extra (and p (remove (lambda (x) (equal? x 'compos)) p))))
        (cond ((not p) '())
              ((null? p) (list "no tools"))
              ;; the compos bridge is on in every session; naming it says nothing
              ((null? extra) '())
              (else (list (string-join (map symbol->string extra) "+")))))
      (let ((k (llm-bundle-permission b)))
        (if (or (not k) (equal? k "approve")) '() (list k)))
      (let ((a (llm-bundle-agent-mode b)))
        (if (or (not a) (equal? a "") (equal? a "default")) '() (list a)))
      (let ((off (llm-bundle-prompt-disabled b)))
        (if (and off (pair? off))
            (list (string-append (number->string (length off)) " prompt off"))
            '()))
      (let ((s (llm-bundle-get b 'sandbox #f)))
        (if (member s '("on" "off")) (list (string-append "sandbox " s)) '())))
    " · "))

;; The buffer whose LLM session the presets and the stance belong to. A chat
;; or an llm-mode buffer is its own session; a grouped work buffer shares its
;; group chat's session. This never CREATES a chat: the menu redraws on every
;; keystroke.
;; The session of a work buffer is its group's most recent chat. The scan
;; walks the MRU list once and asks each buffer the cheap question first
;; (is it a chat?); group-buffers-mru asked every buffer for its groups,
;; which was 60 ms per call in a hundred-buffer editor, and the dashboard
;; asks after every command. A group whose chat never reached the MRU
;; answers with its primary chat.
(define (llm-config-session buf)
  ;; No buffer means the caller had no scope: M-x runs a config command
  ;; outside the transient, and the answer must still be this buffer's
  ;; session rather than #f, which reads as "the defaults" everywhere
  ;; downstream and reports a stance the chat does not have.
  (let ((buf (or buf (current-buffer))))
    (cond ((or (chat-buffer? buf) (minor-mode-on? buf "llm-mode")) buf)
          ((and (boundp (quote buffer-group)) (buffer-group buf))
           (let* ((g (buffer-group buf))
                  (chats (filter (lambda (b)
                                   (and (chat-buffer? b)
                                        (equal? (chat-group-id b) g)))
                                 (buffer-list-mru))))
             (cond ((pair? chats) (car chats))
                   ((and (boundp (quote group-primary-chat)) (group-primary-chat g)))
                   (else buf))))
          (else buf))))

(define (llm-config-permission buf)
  (if (boundp (quote chat-permission-mode)) (chat-permission-mode buf) 'auto))

;; The configuration menu keeps recent complete choices, not three unrelated
;; input histories. The transient records one final choice when it closes.
(defvar '*llm-config-history* '())
(define llm-config-history-limit 10)

;; Named bundles, newest first. These outlive the history: the history
;; forgets at ten, a named bundle is kept until it is forgotten by name.
(defvar '*llm-bundles* '())

;; A named bundle keeps its first menu key. List order may change; identity does not.
(define *llm-config-bundle-keys*
  '("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r"
    "t" "v" "w" "y" "z"))

(define (llm-bundle-next-key used)
  (let loop ((keys *llm-config-bundle-keys*))
    (cond ((null? keys) #f)
          ((member (car keys) used) (loop (cdr keys)))
          (else (car keys)))))

;; Old persisted bundles had no key, or an upper-case one from the first
;; menu. Assign one from the pool once, and keep a key that is in the pool.
;; The pool is the lower-case letters minus the menu's own keys (s u x).
(define (llm-bundles-assign-keys bundles)
  (let loop ((bs (map llm-bundle-normalize bundles)) (used '()) (out '()))
    (if (null? bs)
        (reverse out)
        (let* ((bundle (car bs))
               (saved (llm-bundle-key bundle))
               (key (if (and (member saved *llm-config-bundle-keys*)
                             (not (member saved used)))
                        saved
                        (llm-bundle-next-key used)))
               (keyed (if key (llm-bundle-put bundle 'key key) bundle)))
          (loop (cdr bs) (if key (cons key used) used) (cons keyed out))))))

(persist-global! 'llm-config-history
  (lambda () *llm-config-history*)
  (lambda (v) (set! *llm-config-history* (map llm-bundle-normalize (or v '())))))

(persist-global! 'llm-bundles
  (lambda () *llm-bundles*)
  (lambda (v) (set! *llm-bundles* (llm-bundles-assign-keys (or v '())))))

;; The three parts that are always cheap to read: buffer-locals, and no
;; walk to find the session. The menu redraws on every keystroke, so what
;; the menu shows comes from here.
(define (llm-config-core buf)
  ;; read from the session, as llm-config-combination does for the rest: a
  ;; plain buffer in a group shows its chat's model, not a codex fallback
  (let* ((buf (llm-config-session buf))
         (chat? (equal? (buffer-local buf 'mode-name) "chat-mode")))
    (list
      'connector
      (or (buffer-local buf (if chat? 'agent-connector 'llm-connector))
          (if chat? *default-connector* "codex-app-server"))
      'model
      (or (buffer-local buf (if chat? 'agent-model 'llm-model)) "default")
      'effort
      (or (buffer-local buf (if chat? 'agent-effort 'llm-effort)) "default"))))

;; The whole setup, including the parts that belong to the session rather
;; than to this buffer. This is what gets remembered and what gets saved.
(define (llm-config-combination buf)
  (let ((session (llm-config-session buf)))
    (append (llm-config-core buf)
      (list
        'presets
        (if (boundp (quote chat-presets-of)) (chat-presets-of session) '())
        'permission
        (symbol->string (llm-config-permission session))
        'agent-mode
        (or (buffer-local session 'agent-mode) "")
        'prompt-disabled
        (or (buffer-local session 'prompt-disabled-parts) '())
        'sandbox
        (or (buffer-local session 'sandbox) "group")))))

(define (llm-config-remember! bundle)
  (let ((b (llm-bundle-normalize bundle)))
    (set! *llm-config-history*
      (take
        (cons b
          (remove (lambda (old)
                    (equal? (llm-bundle-setup (llm-bundle-normalize old))
                            (llm-bundle-setup b)))
                  *llm-config-history*))
        llm-config-history-limit))
    b))

(define (llm-bundle-named name)
  (let loop ((bs *llm-bundles*))
    (cond ((null? bs) #f)
          ((equal? (llm-bundle-name (car bs)) name) (car bs))
          (else (loop (cdr bs))))))

;; The name is the identity: saving over one replaces it without changing its key.
(define (llm-bundle-save! name bundle)
  (set! *llm-bundles* (llm-bundles-assign-keys *llm-bundles*))
  (let* ((old (llm-bundle-named name))
         (used (filter string? (map llm-bundle-key *llm-bundles*)))
         (key (or (and old (llm-bundle-key old)) (llm-bundle-next-key used)))
         (named (llm-bundle-put (llm-bundle-normalize bundle) 'name name))
         (b (if key (llm-bundle-put named 'key key) named)))
    (set! *llm-bundles*
      (cons b (remove (lambda (old) (equal? (llm-bundle-name old) name))
                      *llm-bundles*)))
    b))

(define (llm-bundle-forget! name)
  (set! *llm-bundles*
    (remove (lambda (old) (equal? (llm-bundle-name old) name)) *llm-bundles*))
  name)

;; One configuration surface for every LLM frontend. Chat buffers apply the
;; choice to their durable session; ordinary buffers persist it as llm-mode
;; locals, and their next turn resumes or starts the matching session.
(define (llm-config-apply! buf connector model effort)
  ;; the model belongs to the same session the presets and stance do: from a
  ;; plain buffer in a group, that is the group's chat, not the buffer itself
  (let ((buf (llm-config-session buf)))
    (if (equal? (buffer-local buf 'mode-name) "chat-mode")
        (chat-llm-apply! buf connector model effort)
        (begin
          (let ((same-connector
                  (equal? connector (buffer-llm-connector buf))))
            ;; A model/effort change can resume the same Codex thread with new
            ;; overrides. A connector change cannot carry a foreign thread id.
            (llm-mode-reset-runtime! buf same-connector))
          (buffer-set-local! buf 'llm-connector connector)
          (buffer-set-local! buf 'llm-model
            (if (equal? model "default") #f model))
          (buffer-set-local! buf 'llm-effort
            (if (equal? effort "default") #f effort))
          (unless (minor-mode-on? buf "llm-mode")
            (enable-minor-mode! buf "llm-mode"))
          (message
            (string-append "LLM: " connector
              (if (equal? model "default") "" (string-append " · " model))
              (if (equal? effort "default") "" (string-append " · " effort))))))
    (when (boundp (quote workspace-llm-defaults-note!))
      (workspace-llm-defaults-note! buf))))

;; Applying a bundle applies ALL of it, in one pass: the stance and the
;; presets go in first so the reattach that a connector or model change
;; already performs carries the new tool surface too. A preset change on an
;; otherwise unchanged session reconnects at the end, without asking —
;; naming a whole setup IS the answer to that question.
(define (llm-bundle-apply! buf bundle)
  (if (not (buffer-exists? buf))
      #f
      (llm-bundle-apply-live! buf bundle)))

(define (llm-bundle-apply-live! buf bundle)
  (let* ((b (llm-bundle-normalize bundle))
         (session (llm-config-session buf))
         (presets (llm-bundle-presets b))
         (permission (llm-bundle-permission b))
         (mode (llm-bundle-agent-mode b))
         (prompt-disabled (llm-bundle-prompt-disabled b))
         (sandbox (llm-bundle-get b 'sandbox #f)))
    ;; on or off holds for this chat; group hands it back to the group
    (when sandbox
      (buffer-set-local! session 'sandbox (if (member sandbox '("on" "off")) sandbox #f)))
    (when (and permission (boundp (quote chat-permission-mode-set!)))
      (chat-permission-mode-set! session (string->symbol permission)))
    (when (and presets (boundp (quote chat-presets-set!)))
      (chat-presets-set! session presets))
    (when (and (not (equal? prompt-disabled #f))
               (boundp (quote chat-prompt-sections-set!)))
      (chat-prompt-sections-set! session prompt-disabled))
    (llm-config-apply! buf (llm-bundle-connector b) (llm-bundle-model b)
                       (llm-bundle-effort b))
    (when (boundp (quote chat-apply-pending-presets!))
      (chat-apply-pending-presets! session))
    (when (and mode (not (equal? mode "")) (boundp (quote agent-mode-set!)))
      (agent-mode-set! session mode))
    b))

;; Transient uses these catalog helpers to show the live model choices.
(define (chat-live-model-entry buf connector model)
  (and (equal? connector (buffer-local buf 'agent-connector))
       (let loop ((entries (or (buffer-local buf 'agent-models) '())))
         (cond ((null? entries) #f)
               ((and (pair? (car entries))
                     (equal? (car (car entries)) model))
                (car entries))
               (else (loop (cdr entries)))))))

;; A live backend model/list wins. Its compact entry is
;; (id display-name effort-values default-effort). Before that arrives (or
;; while choosing another connector), use the same normalized LLMDB catalog
;; that req_llm uses. Unknown is deliberately empty: never offer a
;; connector-wide superset that the selected model may reject.
(define (chat-model-effort-info buf connector model)
  (let* ((actual (if (equal? model "default")
                     (or (and (equal? connector (buffer-local buf 'agent-connector))
                              (buffer-local buf 'agent-model))
                         (and (connector-can? connector 'stateless) (llm-model)))
                     model))
         (live (and actual (chat-live-model-entry buf connector actual))))
    (if live
        ;; a live entry is (ID LABEL [EFFORTS [DEFAULT-EFFORT]]) and a
        ;; connector that reports neither sends only the first two
        (let* ((tail (if (pair? live) (cdr live) '()))
               (tail (if (pair? tail) (cdr tail) '()))
               (efforts (if (pair? tail) (car tail) '()))
               (tail (if (pair? tail) (cdr tail) '())))
          (list (if (pair? efforts) efforts '())
                (if (pair? tail) (car tail) "")))
        (let* ((r (and actual (llm-model-reasoning actual)))
               (effort (and r (plist-get r 'effort))))
          (list (or (and effort (plist-get effort 'values)) '())
                (or (and effort (plist-get effort 'default)) ""))))))

;; A live backend tells its session which models it serves. That answer is
;; the truth about the CONNECTOR, not about one session, so keep it: the
;; next chat on that connector — and the picker aimed at a connector nothing
;; is attached to — offers the same list, instead of a hand-written seed
;; that ages the day the provider ships a model.
(defvar '*llm-connector-models* '() 'persist #t)

(define (llm-models-remembered connector)
  (let ((e (assoc connector *llm-connector-models*)))
    (if e (cadr e) '())))

(define (llm-models-seen! connector entries)
  (when (and connector (pair? entries))
    (set! *llm-connector-models* (alist-put *llm-connector-models* connector entries)))
  entries)

;; Ask a connector for its models with no chat: open a session that nobody
;; talks to, keep the list it reports at start, and close it. A backend that
;; never answers is closed at the deadline. K hears the connector and the
;; count, or #f.
(define *llm-models-probe-deadline-ms* 30000)

(define (llm-models-probe! connector &optional k)
  (let ((id (string-append "models-probe-" connector))
        (done #f))
    (define (finish! n)
      (unless done
        (set! done #t)
        (when (member id (agent-list)) (llm-session-close! id))
        (when k (k connector n))))
    (define (handler slug events)
      (for-each
        (lambda (e)
          (let ((type (plist-get e 'type)))
            (cond ((and (equal? type 'model-state) (pair? (plist-get e 'available)))
                   (llm-models-seen! connector (plist-get e 'available))
                   (finish! (length (plist-get e 'available))))
                  ((member type '(dead error)) (finish! #f)))))
        events))
    (when (member id (agent-list)) (llm-session-close! id))
    (if (ignore-errors
          (lambda ()
            (llm-session-open! id
              (agent-resolve-config (list 'connector connector 'cwd (getenv "HOME")))
              #f handler #f #f)
            #t))
        (debounce! id *llm-models-probe-deadline-ms* (lambda (_) (finish! #f)) #f)
        (finish! #f))
    id))

;; The connectors that run an agent process and report their own models
(define (llm-models-probe-connectors)
  (filter (lambda (name)
            (let ((conf (connector-config name)))
              (and (plist-get conf 'cmd) (not (plist-get conf 'hidden)))))
          (map car *agent-connectors*)))

;; The backend's own list is the menu. The declared seed shows only for a
;; connector that has not reported yet, and the picker asks it once.
(defvar '*llm-models-probed* '())

(define (chat-model-options buf connector)
  (let* ((live (and (equal? connector (buffer-local buf 'agent-connector))
                    (buffer-local buf 'agent-models)))
         (entries (if (pair? live) live (llm-models-remembered connector))))
    (when (and (null? entries)
               (not (member connector *llm-models-probed*))
               (member connector (llm-models-probe-connectors)))
      (set! *llm-models-probed* (cons connector *llm-models-probed*))
      (llm-models-probe! connector))
    (if (pair? entries)
        ;; a declared model that the connector does not list yet (a new
        ;; release the adapter has no alias for) comes after its own list
        (append
          (map (lambda (e)
                 (list (car e) (if (pair? (cdr e)) (or (cadr e) "") "")))
               entries)
          (map (lambda (m) (list m ""))
               (filter (lambda (m) (not (assoc m entries)))
                       (connector-models connector))))
        (map (lambda (m) (list m "")) (connector-models connector)))))

;; A backend's session modes are the connector's truth as well, and they
;; arrive on the same asynchronous event. Remembering them is what lets the
;; menu offer them to a chat that has not attached yet, and to one whose
;; session is still restarting after a backend switch — the wait for the
;; first mode-state event is why the row used to read "none".
(defvar '*llm-connector-modes* '() 'persist #t)

(define (llm-modes-remembered connector)
  (let ((e (assoc connector *llm-connector-modes*)))
    (if e (cadr e) '())))

(define (llm-modes-seen! connector entries)
  (when (and connector (pair? entries))
    (set! *llm-connector-modes* (alist-put *llm-connector-modes* connector entries)))
  entries)

;; the live session's own list when it has one, the connector's remembered
;; list otherwise. Entries are (id label description), as the adapter sends.
(define (chat-mode-options buf connector)
  (let ((live (and (equal? connector (buffer-local buf 'agent-connector))
                   (buffer-local buf 'agent-modes))))
    (if (pair? live) live (llm-modes-remembered connector))))

;; NOTE is the rail's footer: one line on what RET does here.
(define (llm-config-read! prompt candidates confirm cancel &optional note)
  (minibuffer-read* prompt candidates
    (append
      (list (list 'confirm confirm)
            (list 'cancel cancel)
            (list 'style "palette")
            (list 'legend '(("RET" "pick") ("C-n C-p" "select") ("TAB" "complete")
                            ("C-g" "back"))))
      (if (string? note) (list (list 'note note)) '()))))

;; A palette row with facts: (LABEL HINT "" () "" ((KEY VALUE) ...)). The
;; rail shows the facts while the row is highlighted.
(define (llm-config-row label hint facts)
  (list label hint "" '() "" facts))

;; Candidate palettes select their first row. Put CURRENT there and label it
;; explicitly; unlike pre-filling the minibuffer, this keeps every alternative
;; visible while still showing which value is active. A row's other columns
;; (its facts) ride along.
(define (llm-config-current-first candidates current)
  (let ((selected
          (map (lambda (c)
                 (cons (car c)
                       (cons (string-append "current"
                               (if (equal? (cadr c) "") ""
                                   (string-append " · " (cadr c))))
                             (cddr c))))
               (filter (lambda (c) (equal? (car c) current)) candidates)))
        (others (filter (lambda (c) (not (equal? (car c) current))) candidates)))
    (append selected others)))

;; Compatibility command for saved bindings and existing callers.
(define-command "chat-set-backend" "Choose this chat's LLM backend, model, and effort"
  (lambda () (run-command "llm-configure")))

;;; --- rich chat transcript (the agent thread design) ---------------------------
;;; A companion chat maintains the locals the chat view reads (render-mode
;;; "blocks", 'agent-blocks byte ranges, 'agent-saved-mark), so
;;; chat-view-sync! draws its prose, user cards and tool cards as any chat.
;;; No runtime behind it: the mark lives in 'agent-saved-mark, the
;;; conversation in 'chat-wire-turns.
;;; Buffer layout: [help][transcript … mark][input].

;; the prefix of a user line in the transcript. RET writes it in front of
;; the sent message; the live input carries no marker bytes at all, so no
;; edit can damage the input boundary. A chat saved before this change
;; still holds the marker at its mark; chat-input-migrate! removes it.
(define *chat-input-marker* "\n>>> you: ")

;; the mark never points past the end: an edit the local did not see
;; (undo, a whole-region replace from the client) could leave it there.
;; A stranded local is written back to the end, so the next keystroke
;; lands in the input instead of behind a mark nobody can reach. A whole
;; local is not written: a read must not dirty the buffer.
(define (chat-mark buf)
  (let ((saved (or (buffer-local buf 'agent-saved-mark) 0))
        (size (buffer-size buf)))
    (if (> saved size)
        (begin (buffer-set-local! buf 'agent-saved-mark size) size)
        saved)))

;; append at the mark — after every recorded range, so stored offsets
;; never shift; the input region past the marker slides along
(define (chat-render! buf text)
  (- (buffer-insert-at-local! buf 'agent-saved-mark text)
     (string-byte-length text)))

;;; --- the input region ------------------------------------------------------------
;;; Layout: [transcript … mark][live input]
;;;
;;; ONE function says where it starts. "Where does the input begin" used to
;;; be computed five ways — twice in Scheme off the runtime mark, once off
;;; the buffer-local, once in the payload builder, once in the renderer —
;;; and only one of them knew about 'agent-marker-bytes. Every reader takes
;;; it from here now, and the payload ships the same number to the client.
;;; 'agent-marker-bytes is 0 for every chat made after the marker left the
;;; live input; a restored chat keeps its old value until it migrates.
;;;
;;; It reads buffer-locals, never a runtime: a restored chat has no thread
;;; until its first send, and up-arrow has to work before then.

;; where the live input begins, never past the end of the buffer. A
;; message queued mid-turn does not live here — RET echoes it into the
;; transcript as a muted "queued" block (agent-echo-queued!), and the
;; input clears.
(define (chat-input-start buf)
  (min (+ (chat-mark buf) (or (buffer-local buf 'agent-marker-bytes) 0))
       (buffer-size buf)))

;; a chat from before the marker left the live input still carries the
;; marker bytes at its mark: remove them, keep the draft after them, and
;; record that the input starts at the mark. A chat with the marker in
;; its text and no mark gets its mark from the last marker first. The
;; migration pass runs this once per buffer (migrations.scm); a chat in
;; the new layout is left as it is.
(define (chat-input-migrate! buf)
  (let ((mb (string-byte-length *chat-input-marker*)))
    (when (and (not (buffer-local buf 'agent-saved-mark))
               (pair? (re-find* *chat-input-marker* (buffer-text buf))))
      (buffer-set-local! buf 'agent-saved-mark (chat-legacy-mark buf)))
    (when (buffer-local buf 'agent-saved-mark)
      (let ((size (buffer-size buf))
            (m (chat-mark buf)))
        (when (and (<= (+ m mb) size)
                   (equal? (substring-bytes (buffer-text buf) m (+ m mb))
                           *chat-input-marker*))
          (buffer-delete-range! buf m mb))
        ;; the local cannot sit past the end after the delete
        (buffer-set-local! buf 'agent-saved-mark (chat-mark buf))
        (buffer-set-local! buf 'agent-marker-bytes 0)))))

;; (START END) of the LIVE input — what RET sends
(define (chat-input-region buf)
  (list (chat-input-start buf) (buffer-size buf)))

(define (chat-input-text buf)
  (let ((r (chat-input-region buf)))
    (substring-bytes (buffer-text buf) (car r) (car (cdr r)))))

(define (chat-clear-input! buf)
  (let ((r (chat-input-region buf)))
    (buffer-delete-range! buf (car r) (- (car (cdr r)) (car r)))))

(define (chat-replace-input! buf text)
  (chat-clear-input! buf)
  (end-of-buffer!)
  (unless (equal? text "") (insert! text)))

;;; --- the conversation of record ------------------------------------------------
;;; ...moved to packages/chat.scm: the record, compaction, healing, the
;;; tool surface, the usage ledger, and the direct lane's turn context.
;;; Policy about a conversation is not the editor's business.

;; a mode whose buffer went stale OFF screen registers a catch-up
;; here; the switcher runs it for every window it just (re)filled.
;; diff-mode uses it: hidden diffs skip the expensive re-render and
;; catch up the moment they show.
;; buffer-shown-hook: (FN BUFFER)
(define (windows-shown-catchup!)
  (for-each (lambda (w) (run-hook-with-args 'buffer-shown-hook (car (cdr w))))
            (window-list)))

;;; --- llm cost inspection -----------------------------------------------------
;;; Every request is priced (models.dev catalog, cached in ~/.compos/llmdb.json,
;;; refreshed daily) and recorded in ~/.compos/llm-usage.jsonl; each chat also
;;; sums its own spend in the 'chat-cost buffer-local.

;; What a chat cost, and — the number that decides whether it was worth it
;; — how much of its input the provider served from cache. A conversation
;; resends its whole history every turn. At a healthy hit rate that history
;; bills at about a tenth of the price; at 0% it bills at full price twice
;; over, because a cache WRITE costs more than a plain read.
(define-command "chat-cost" "Show what this chat has cost, and its cache hit rate"
  (lambda ()
    (let* ((buf (current-buffer))
           (c (buffer-local buf 'chat-cost))
           (u (buffer-local buf 'chat-last-usage))
           (ctx (chat-context-tokens buf))
           (total (chat-usage-total buf))
           (rate (chat-hit-rate total)))
      (if (not (or c u ctx))
          (message "No usage reported in this chat yet")
          (message
            (string-append
              "This chat: " (if c (format-usd c) "unpriced")
              ;; what it occupies right now, which is the number a reader
              ;; asks for when a conversation feels long
              (if ctx
                  (string-append " · context "
                    (number->string (plist-get ctx 'used))
                    (let ((size (plist-get ctx 'size)))
                      (if size (string-append " of " (number->string size)) ""))
                    " tokens")
                  "")
              " · cache " (number->string (or (plist-get total 'cache-read) 0)) " read / "
              (number->string (or (plist-get total 'cache-write) 0)) " written"
              (if rate (string-append " · " rate " of input cached") "")
              (if u
                  (string-append " · last turn "
                    (number->string (or (plist-get u 'input) 0)) "→"
                    (number->string (or (plist-get u 'output) 0)) " tokens"
                    (let ((tc (plist-get u 'cost)))
                      (if tc (string-append " (" (format-usd tc) ")") "")))
                  "")))))))

(define-command "llm-costs" "Show LLM spend by day and model (the usage ledger)"
  (lambda ()
    (let ((rows (llm-cost-report))
          (buf "*llm-costs*"))
      (buffer-create buf)
      (buffer-delete-range! buf 0 (string-byte-length (buffer-text buf)))
      (buffer-append! buf
        (fold (lambda (acc r)
                (string-append acc
                  (plist-get r 'day) "  "
                  (format-usd (plist-get r 'cost)) "  "
                  (number->string (plist-get r 'requests)) " reqs  "
                  (number->string (plist-get r 'input)) "→"
                  (number->string (plist-get r 'output)) "  "
                  ;; the cache columns: read is what the prefix cost a tenth
                  ;; of, written is what it cost a quarter more than usual
                  "cache " (number->string (plist-get r 'cache-read)) "r/"
                  (number->string (plist-get r 'cache-write)) "w  "
                  (let ((h (plist-get r 'hit-rate)))
                    (string-pad-right
                      (if h (string-append (number->string h) "% cached") "") 12))
                  "  " (plist-get r 'model) "\n"))
              (string-append
                "LLM spend · ledger ~/.compos/llm-usage.jsonl · per-chat: C-c $\n"
                "hit rate is cached input over billed input: low means the "
                "prefix is being rewritten every turn\n\n")
              rows))
      (switch-to-buffer! buf))))

;; a new chat buffer in the current group; the old conversation stays.
;; The frame's group wins; a buffer outside any group founds one only
;; when the frame stands in none.
(define-command "chat-new" "Start a new chat buffer; with a prefix, hand a task to a new chat in a group and stay here"
  (interactive 'P)
  (lambda (prefix)
    (if prefix
        ;; fire and forget: the task goes to the todo list and its chat
        ;; works in the background; neither the group nor a window moves
        (group-read-or-create! "New chat in group: "
          (lambda (g)
            (minibuffer-read (string-append "Task for " (group-name g) ": ") '()
              (lambda (task)
                (if (equal? (string-trim task) "")
                    (message "No task, no chat")
                    (let ((r (todo-spawn-chat! g task)))
                      (message (string-append "Task " (car r) " handed to " (cadr r)))))))))
        (let ((g (or (frame-group) (group-ensure! (current-buffer)))))
          (if (not g)
              (message "No group for a chat")
              (group-chat-new! g))))))

;; C-c q from anywhere: the prompt becomes a turn in this buffer's group
;; chat (founding the group first if needed) — one chat interface, always
(define-command "llm-ask" "Ask the LLM from anywhere via the minibuffer"
  (lambda ()
    (group-ask! (group-ensure! (current-buffer)))))

(global-set-key "C-c c" "chat")
(global-set-key "C-c n" "chat-new")
(global-set-key "C-c r" "chat-send-region")
(global-set-key "C-c q" "llm-ask")
(global-set-key "C-c w" "chat-companion")

(global-set-key "C-c RET" "chat-companion-ask")

;;; --- the one-shot migrations of a chat ---------------------------------------
;;; Each names a shape an older desktop can carry; migrations.scm runs
;;; them once per buffer on restore, before the mode setup, and deletes
;;; them at the cut-off.

;; pre-group companions carried a 'companion-of pointer: both ends get
;; the 'group tag
(define (chat-companion-of-migrate! buf)
  (let ((doc (buffer-local buf 'companion-of)))
    (when (and doc (not (buffer-local buf 'group)))
      (let ((g (or (and (buffer-exists? doc) (buffer-local doc 'group))
                   doc)))
        (buffer-set-local! buf 'group g)
        (when (and (buffer-exists? doc)
                   (not (buffer-local doc 'group)))
          (buffer-set-local! doc 'group g))))))

;; by name, in a lambda: chat.scm defines chat-record-migrate! after this
;; file loads, and a reload must reach the new definition
(define-buffer-migration! 'chat-record "2026-08-20"
  (lambda (buf) (chat-record-migrate! buf)))
(define-buffer-migration! 'chat-companion-group "2026-08-20"
  (lambda (buf) (chat-companion-of-migrate! buf)))
(define-buffer-migration! 'chat-input-marker "2026-09-05"
  (lambda (buf) (chat-input-migrate! buf)))
