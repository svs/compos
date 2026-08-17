;;; agent.scm — ACP thread machinery for chats. There is only chat: a
;;; thread is a chat buffer riding an ACP backend (chat-set-backend, or
;;; (execute "task") which spawns a fresh *chat:<slug>*). Steer by typing
;;; at the >>> you: marker and RET (queued if the agent is mid-turn).
;;; C-g aborts the reply in flight; C-RET escalates to a hard reset. TAB
;;; folds/unfolds tool output. C-c C-y / C-c C-n answer permission
;;; requests. The Elixir side (Aimax.Core.Agent) is mechanism only:
;;; subprocess, framing, event batches.

;;; --- faces --------------------------------------------------------------------

(set-face-attribute! 'agent-tool 'fg "#7aa2f7")
(set-face-attribute! 'agent-thought 'fg "#787c99")
(set-face-attribute! 'agent-permission 'fg "#e0af68")
(set-face-attribute! 'agent-meta 'fg "#787c99")
(set-face-attribute! 'agent-queued 'fg "#565a6e")

;; threads are primary work surfaces, not popups — they take the full window
;; (the *chats* fleet list is the popup-weight surface)

;;; --- small helpers ------------------------------------------------------------

(define (agent-buffer slug) (string-append "*agent: " slug "*"))

;; the buffer a thread renders into: any buffer claiming the slug — chats
;; host threads too (chat-set-backend) — else the conventional name above
(define (agent-buf slug)
  (let loop ((bs (buffer-list)))
    (cond ((null? bs) (agent-buffer slug))
          ((equal? (buffer-local (car bs) 'agent-slug) slug) (car bs))
          (else (loop (cdr bs))))))

(define (agent-slug-of buf) (buffer-local buf 'agent-slug))

;; the input region lives in editor.scm: chat-input-region and friends,
;; keyed by BUFFER, because a restored chat has locals and no runtime

(define (agent-status slug)
  (let ((info (agent-info slug)))
    (if info (plist-get info 'status) 'dead)))

;;; --- overlays (per-buffer accumulated: overlay-set! replaces per tag) --------

(define (agent-add-overlay! buf s e face)
  (let ((ranges (cons (list s e face) (or (buffer-local buf 'agent-overlays) '()))))
    (buffer-set-local! buf 'agent-overlays ranges)
    (overlay-set! buf 'agent ranges)))

;;; --- folds --------------------------------------------------------------------
;;; 'agent-folds: list of (start end open?) — hidden ranges derived from it.
;;; Appends only ever happen at the mark, after every stored range: offsets
;;; never move.

(define (agent-apply-folds! buf)
  (fold-set! buf 'agent
    (let loop ((fs (or (buffer-local buf 'agent-folds) '())) (acc '()))
      (cond ((null? fs) acc)
            ((car (cdr (cdr (car fs)))) (loop (cdr fs) acc)) ; open — not hidden
            (else (loop (cdr fs)
                        (cons (list (car (car fs)) (car (cdr (car fs)))) acc)))))))

(define (agent-add-fold! buf s e)
  (buffer-set-local! buf 'agent-folds
    (cons (list s e #f) (or (buffer-local buf 'agent-folds) '())))
  (agent-apply-folds! buf))

;;; ONE open-state per tool card (S4/S6): 'agent-open-cards holds the ids
;;; whose cards show open in the rich view; the matching plain-view fold
;;; tracks it. Scheme adds the id when a tool starts and removes it when
;;; the tool completes; a click or TAB toggles it, and the choice
;;; survives save/restore with the other conversation locals.

(define (agent-open-cards buf) (or (buffer-local buf 'agent-open-cards) '()))

(define (agent-card-open? buf id) (and (member id (agent-open-cards buf)) #t))

(define (agent-card-set-open! buf id open?)
  (let ((cards (agent-open-cards buf)))
    (buffer-set-local! buf 'agent-open-cards
      (if open?
          (if (member id cards) cards (cons id cards))
          (filter (lambda (c) (not (equal? c id))) cards))))
  ;; the plain view's fold over the tool body follows, when one exists
  (let ((entry (assoc id (or (buffer-local buf 'agent-tool-bodies) '()))))
    (when entry
      (let ((s (car (cdr entry))))
        (buffer-set-local! buf 'agent-folds
          (map (lambda (f)
                 (if (= (car f) s) (list (car f) (car (cdr f)) open?) f))
               (or (buffer-local buf 'agent-folds) '())))
        (agent-apply-folds! buf)))))

(define (agent-card-toggle! buf id)
  (agent-card-set-open! buf id (not (agent-card-open? buf id))))

;; the tool id whose body fold starts at byte S, or #f
(define (agent-card-at-fold buf s)
  (let loop ((es (or (buffer-local buf 'agent-tool-bodies) '())))
    (cond ((null? es) #f)
          ((= (car (cdr (car es))) s) (car (car es)))
          (else (loop (cdr es))))))

(define-command "agent-toggle-fold" "Toggle the transcript fold at or around point"
  (lambda ()
    (let* ((buf (current-buffer))
           (p (point))
           ;; the fold point is on: header line just above, or inside
           (hit (let loop ((fs (or (buffer-local buf 'agent-folds) '())))
                  (cond ((null? fs) #f)
                        ((and (>= p (- (car (car fs)) 120))
                              (< p (car (cdr (car fs)))))
                         (car fs))
                        (else (loop (cdr fs))))))
           (id (and hit (agent-card-at-fold buf (car hit)))))
      (cond ((not hit) (message "no fold here"))
            ;; a tool body: the card open-state owns both views
            (id (agent-card-toggle! buf id))
            (else
             (buffer-set-local! buf 'agent-folds
               (map (lambda (f)
                      (if (= (car f) (car hit))
                          (list (car f) (car (cdr f)) (not (car (cdr (cdr f)))))
                          f))
                    (buffer-local buf 'agent-folds)))
             (agent-apply-folds! buf))))))

;;; --- block model --------------------------------------------------------------
;;; 'agent-blocks: newest-first list of (start end kind meta...) over byte
;;; ranges — the rich renderer's map of the transcript. Text stays canonical;
;;; blocks only say what each span IS. Kinds: "user" "prose" "thought" "tool"
;;; "plan" "permission" "waiting" "meta". Appends land at the mark, after
;;; every recorded range, so stored offsets never shift.

(define (agent-blocks buf) (or (buffer-local buf 'agent-blocks) '()))

(define (agent-block-push! buf start end kind meta)
  (buffer-set-local! buf 'agent-blocks
    (cons (append (list start end kind) meta) (agent-blocks buf))))

;; consecutive same-kind streaming spans melt into one block
(define (agent-block-extend-or-push! buf start end kind)
  (let ((bs (agent-blocks buf)))
    (if (and (not (null? bs))
             (equal? (car (cdr (cdr (car bs)))) kind)
             (= (car (cdr (car bs))) start))
        (buffer-set-local! buf 'agent-blocks
          (cons (append (list (car (car bs)) end kind)
                        (cdr (cdr (cdr (car bs)))))
                (cdr bs)))
        (agent-block-push! buf start end kind '()))))

;; a tool block closes when its update completes: extend to the body end,
;; flip status. Block: (start end "tool" id title kind status body-start).
;; Newest-first scan; tool updates always hit recent blocks.
(define (agent-block-close-tool! buf id end status)
  (buffer-set-local! buf 'agent-blocks
    (let loop ((bs (agent-blocks buf)) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((and (equal? (nth 2 (car bs)) "tool")
                  (equal? (nth 3 (car bs)) id))
             (let ((b (car bs)))
               (append (reverse acc)
                       (cons (list (nth 0 b) end "tool" id
                                   (nth 4 b) (nth 5 b) status (nth 7 b))
                             (cdr bs)))))
            (else (loop (cdr bs) (cons (car bs) acc)))))))

(define (agent-block-drop-kind! buf kind)
  (buffer-set-local! buf 'agent-blocks
    (let loop ((bs (agent-blocks buf)) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((equal? (car (cdr (cdr (car bs)))) kind) (loop (cdr bs) acc))
            (else (loop (cdr bs) (cons (car bs) acc)))))))

;;; --- tool cards ---------------------------------------------------------------
;;; What a card SAYS is presentation, so it is decided here. The backend
;;; sends the call and the result; an adapter that has only a title sends
;;; that instead, and these fall back to it.
;;;
;;; A card used to read "tool eval-scheme" and open onto nothing: the
;;; arguments were thrown away and the body held only the result, which is
;;; often empty. Fifteen identical cards tell you nothing about what
;;; happened.

(defcustom 'agent-tool-body-limit 2000
  "How many bytes of a tool result a card body shows. The model still gets all of it."
  'group 'chat 'type 'integer)

(defcustom 'agent-tool-title-limit 72
  "How many bytes of a tool call's main argument the card's title shows."
  'group 'chat 'type 'integer)

(define (agent-first-line s)
  (let ((i (string-index s "\n")))
    (if i (substring-bytes s 0 i) s)))

(define (agent-clip s n)
  (if (> (string-byte-length s) n) (substring-bytes s 0 n) s))

;; most tools have one argument that matters; show that rather than a blob
(define (agent-tool-primary args)
  (or (plist-get args 'code) (plist-get args 'query)
      (plist-get args 'path) (plist-get args 'name)))

(define (agent-tool-args e)
  (let ((json (plist-get e 'input)))
    (and (string? json) (json-parse json))))

;; "name · the first line of what it was called with"
(define (agent-tool-title e)
  (let ((name (plist-get e 'name))
        (args (agent-tool-args e)))
    (if (not name)
        (or (plist-get e 'title) "tool")     ; an adapter's own title
        (let ((v (and args (agent-tool-primary args))))
          (if (and v (string? v) (not (equal? (string-trim v) "")))
              (string-append name " · "
                (agent-clip (string-trim (agent-first-line v)) agent-tool-title-limit))
              name)))))

(define (agent-tool-input-text e)
  (let* ((args (agent-tool-args e))
         (v (and args (agent-tool-primary args))))
    (cond ((not args) "")
          ((null? args) "")
          ((and v (string? v)) (string-append (string-trim v) "\n\n"))
          (else (string-append (string-trim (plist-get e 'input)) "\n\n")))))

;; a result can be enormous (buffer-text of a big file). The card shows a
;; readable slice; the model already got the whole thing.
(define (agent-tool-update-text e)
  (let ((out (plist-get e 'output)))
    (if (not (string? out))
        (or (plist-get e 'text) "")          ; an adapter's own rendering
        (let ((s (string-trim out)))
          (cond ((equal? s "") "")
                ((> (string-byte-length s) agent-tool-body-limit)
                 (string-append (substring-bytes s 0 agent-tool-body-limit) "\n[…]\n"))
                (else (string-append s "\n")))))))

;;; --- rendering ----------------------------------------------------------------

;; face #f -> plain text
(define (agent-render! slug text face)
  (let ((buf (agent-buf slug))
        (start (agent-mark slug)))
    (agent-append! slug text)
    (when face
      (agent-add-overlay! buf start (+ start (string-byte-length text)) face))
    ;; agent-append! moves 'agent-saved-mark itself, in the same buffer
    ;; message as the insert. Setting it here as well is a second frame in
    ;; which the mark is stale, and the input row shows the marker.
    start))

;;; the waiting line: rendered after each user turn, deleted on the turn's
;;; first output. It is the last text before the marker, so deleting it never
;;; shifts a fold; the runtime re-adjusts its mark automatically.
(define (agent-show-waiting! slug)
  (let* ((buf (agent-buf slug))
         (text "⋯ thinking\n")
         (start (agent-render! slug text "agent-thought")))
    (buffer-set-local! buf 'agent-waiting
      (list start (+ start (string-byte-length text))))))

(define (agent-clear-waiting! slug)
  (let* ((buf (agent-buf slug))
         (w (buffer-local buf 'agent-waiting)))
    (when w
      (let* ((start (car w))
             (end (car (cdr w)))
             (size (buffer-size buf)))
        ;; An obsolete range is harmless runtime metadata. It must never
        ;; take the chat buffer process down or delete text that replaced the
        ;; waiting line while events crossed.
        (when (and (>= start 0) (>= end start) (<= end size)
                   (equal? (substring-bytes (buffer-text buf) start end)
                           "⋯ thinking\n"))
          (buffer-delete-range! buf start (- end start))))
      (agent-block-drop-kind! buf "waiting")
      (buffer-set-local! buf 'agent-waiting #f)
      (buffer-set-local! buf 'agent-saved-mark
        (min (agent-mark slug) (buffer-size buf))))))

;; event kinds that count as the turn having produced something visible —
;; a turn-end after none of them is a silent turn
(define *agent-output-kinds* '(chunk thought tool-call tool-update plan error))

(define (agent-handle-event slug e)
  (let ((buf (agent-buf slug))
        (type (plist-get e 'type)))
    ;; any sign of life ends the waiting state
    (unless (or (equal? type 'user-msg) (equal? type 'status))
      (agent-clear-waiting! slug))
    (when (member type *agent-output-kinds*)
      (buffer-set-local! buf 'agent-turn-any #t))
    (cond
      ((equal? type 'model-state)
       ;; the adapter says which model the session ACTUALLY runs — the
       ;; modeline shows that truth, and C-c m picks from this list
       (buffer-set-local! buf 'agent-models (plist-get e 'available))
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
       (chat-pop-queued! buf)
       ;; the conversation of record is the truth on EVERY backend: the api
       ;; lane replays it per request, ACP seeds a fresh session from it,
       ;; and both flatten it to .chat files. The api lane's turn task
       ;; already recorded this turn from the wire — chat-record-event!
       ;; knows, and does not record it twice.
       (chat-record-event! buf "user" (list (list "text" (plist-get e 'text))))
       (let ((start (agent-render! slug
                      (string-append "\n>>> you: " (plist-get e 'text) "\n\n")
                      "agent-you")))
         (agent-block-push! buf start (agent-mark slug) "user"
           (list (plist-get e 'text))))
       (agent-show-waiting! slug))

      ((equal? type 'chunk)
       ;; the assistant's prose accumulates across the turn; turn-end
       ;; records it as one turn
       (buffer-set-local! buf 'agent-turn-text
         (string-append (or (buffer-local buf 'agent-turn-text) "")
                        (plist-get e 'text)))
       (let ((start (agent-render! slug (plist-get e 'text) #f)))
         (agent-block-extend-or-push! buf start (agent-mark slug) "prose")))

      ((equal? type 'thought)
       (let ((start (agent-render! slug (plist-get e 'text) "agent-thought")))
         (agent-block-extend-or-push! buf start (agent-mark slug) "thought")))

      ((equal? type 'tool-call)
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
         (unless (equal? args "") (agent-render! slug args #f))))

      ((equal? type 'tool-update)
       (let ((text (agent-tool-update-text e)))
         (unless (equal? text "")
           (agent-render! slug text #f))
         (when (equal? (plist-get e 'status) "completed")
           (agent-block-close-tool! buf (plist-get e 'id)
             (agent-mark slug) "done")
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

      ;; the policy decides, not the backend: approvals are invisible
      ;; (the tool just runs), denials and asks are recorded
      ((equal? type 'permission)
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

      ;; the direct lane prices every turn; ACP rides a subscription and
      ;; emits none, so its modeline stays connector · model
      ((equal? type 'usage)
       (chat-usage-note! buf
         (list 'input (plist-get e 'input) 'output (plist-get e 'output)
               'cache-read (plist-get e 'cache-read)
               'cache-write (plist-get e 'cache-write)
               'cost (plist-get e 'cost))))

      ((equal? type 'turn-end)
       (buffer-set-local! buf 'agent-cancelling #f)
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
       ;; the conversation has one more turn to read, so it may now name
       ;; itself (chat.scm decides whether this turn is one of the naming
       ;; turns; the package loads after this one)
       (when (boundp (quote chat-rename-from-content!))
         (chat-rename-from-content! buf))
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
               ""))))

      ((equal? type 'error)
       (let ((start (agent-render! slug
                      (string-append "\n[error: " (plist-get e 'text) "]\n")
                      "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ((equal? type 'dead)
       (agent-block-drop-kind! buf "permission")
       (let ((start (agent-render! slug "\n[agent exited]\n" "agent-meta")))
         (agent-block-push! buf start (agent-mark slug) "meta" '())))

      ((equal? type 'status)
       ;; answered/cancelled permission -> its banner leaves the rich view
       (unless (equal? (plist-get e 'status) 'needs_attention)
         (agent-block-drop-kind! buf "permission")))

      (else #f))))

(llm-session-on-event!
  (lambda (slug events)
    ;; batches race buffer kills — a dead thread's events just drop
    (when (buffer-exists? (agent-buf slug))
      (for-each (lambda (e) (agent-handle-event slug e)) events)
      ;; fleet surfaces track every batch: the erc-track segment + *chats*
      (agents-modeline-refresh!)
      (agents-refresh!))))

;;; --- permissions: one policy, three modalities --------------------------------
;;; Threat model: an agent holding eval-scheme in a local editor is already
;;; trusted — per-call modals are theater EXCEPT for irreversible,
;;; outward-facing acts (send mail, permanent deletion, push/publish).
;;; So: ONE policy function, consulted identically on both lanes.
;;;
;;;   ask     — every tool call banners (the old ACP behavior)
;;;   approve — the deny-list banners, everything else runs (default)
;;;   auto    — approve, and the backend is told to stop asking too (W4)
;;;
;;; The deny-list never relies on a backend asking: it also holds at OUR
;;; chokepoints — the direct lane's dispatcher gate and the MCP proxy —
;;; because every deny-listed verb reaches the world through one of those.

(define *permission-default-mode* 'approve)

;; A gate with no chat behind it — the MCP proxy, which answers an agent
;; we are not rendering — has no chat mode to read. The policy must stay
;; total: every chokepoint calls it, and one of them has no buffer.
(define (chat-permission-mode buf)
  (or (and buf (buffer-exists? buf) (buffer-local buf 'chat-permission-mode))
      *permission-default-mode*))

;; verb-shaped patterns over the tool name/title/payload
(define *permission-deny-patterns*
  (list "send[-_ ]*mail" "sendmail" "mail[-_ ]*send" "smtp"
        "send[-_ ]*(message|email|sms|text)"
        "(permanently|forever)[-_ ]*delete" "delete[-_ ]*(permanently|forever)"
        "empty[-_ ]*trash" "trash[-_ ]*empty" "expunge"
        "rm[-_ ]+-[a-z]*[rf]" "git[-_ ]+push" "force[-_ ]*push"
        "\\bpublish\\b" "\\bdeploy\\b"))

;; -> the matching pattern, or #f
(define (permission-denied-verb? text)
  (let ((t (string-downcase text)))
    (let loop ((ps *permission-deny-patterns*))
      (cond ((null? ps) #f)
            ((re-match? (car ps) t) (car ps))
            (else (loop (cdr ps)))))))

;;; --- per-agent permission profiles (the seam permission packages fill) -----
;;; A thread may carry a permission profile: a plist stored as a chat-identity
;;; local, so it survives restart and save. No profile means allow-all — the
;;; default. The one field today is 'deny-patterns: extra verb-shaped regexes
;;; denied for THIS agent, on top of the shared list. Permission packages will
;;; define the richer schema (effect allow/deny, per-domain).

(define (agent-permission-profile slug)
  (let ((buf (agent-buf slug)))
    (and buf (buffer-exists? buf) (buffer-local buf 'agent-permission-profile))))

(define (set-agent-permission-profile! slug profile)
  (let ((buf (agent-buf slug)))
    (when (and buf (buffer-exists? buf))
      (buffer-set-local! buf 'agent-permission-profile profile)))
  profile)

;; -> the matching pattern, or #f
(define (profile-denies? profile text)
  (and profile
       (let ((t (string-downcase text)))
         (let loop ((ps (or (plist-get profile 'deny-patterns) '())))
           (cond ((null? ps) #f)
                 ((re-match? (car ps) t) (car ps))
                 (else (loop (cdr ps))))))))

;; The one policy. Override wholesale in ~/.aimax/init.scm:
;;   (set! *permission-policy* (lambda (buf title kind raw) 'allow))
;; -> 'allow | 'allow-always | 'ask | 'reject
(define *permission-policy*
  (lambda (buf title kind raw)
    (let* ((text (string-append (or title "") " " (or kind "") " " (or raw "")))
           (profile (and buf (buffer-exists? buf)
                         (buffer-local buf 'agent-permission-profile))))
      (cond ((equal? kind "execute") 'reject)  ; no shell — aimax is the only sandbox
            ((permission-denied-verb? text) 'ask)
            ((profile-denies? profile text) 'reject)
            ((equal? (chat-permission-mode buf) 'ask) 'ask)
            (else 'allow-always)))))

;; the direct lane's gate (Backend.ReqLLM calls this before every tool):
;; collapse to the three verdicts Elixir understands
(llm-session-permission-fn!
  (lambda (slug name kind raw)
    (let* ((buf (agent-buf slug))
           (v (*permission-policy* buf name kind raw)))
      (cond ((equal? v 'reject) 'reject)
            ((equal? v 'ask) 'ask)
            (else 'allow)))))

;; a chat nobody is looking at cannot answer a banner — give it a deadline
;; so headless work denies and moves on instead of hanging forever
(defcustom 'permission-timeout-ms 120000
  "Auto-deny an unanswered permission after this long, in chats no window shows."
  'group 'chat 'type 'integer)

(define (agent-arm-permission-deadline! slug)
  (unless (window-showing (agent-buf slug))
    (agent-permission-deadline! slug permission-timeout-ms)))

;; `auto` is approve PLUS backend-side permissiveness: an agent that
;; advertises session modes is told to stop asking us at all, which is the
;; only way a long unattended run avoids round-tripping every tool call.
;; The deny-list does NOT rely on this — it holds at our own chokepoints.
;; First match wins, so a backend offering only some of these still works.
(define *permission-auto-modes* '("dontAsk" "acceptEdits" "bypassPermissions"))
(define *permission-ask-modes* '("default"))

(define (agent--pick-mode buf wanted)
  (let ((avail (map car (or (buffer-local buf 'agent-modes) '()))))
    (let loop ((ws wanted))
      (cond ((null? ws) #f)
            ((member (car ws) avail) (car ws))
            (else (loop (cdr ws)))))))

;; auto pushes a permissive mode down; leaving auto reverts ONLY the mode
;; we imposed. Anything else the agent is in — plan mode above all — is
;; the user's or the agent's choice and is never stomped.
(define (agent-sync-permission-mode! slug)
  (let* ((buf (agent-buf slug))
         (cur (buffer-local buf 'agent-mode))
         (auto? (equal? (chat-permission-mode buf) 'auto))
         (want (cond (auto? (agent--pick-mode buf *permission-auto-modes*))
                     ((member cur *permission-auto-modes*)
                      (agent--pick-mode buf *permission-ask-modes*))
                     (else #f))))
    (when (and want (not (equal? want cur)))
      (when (llm-session-set-mode! slug want)
        (buffer-set-local! buf 'agent-mode want)))))

;; the agent's OWN mode list (claude-code: default/acceptEdits/plan/
;; dontAsk/bypassPermissions) — plan mode in particular has no aimax
;; equivalent, so it is worth picking directly
(define-command "agent-set-mode" "Switch the agent session's mode (plan, acceptEdits, ...)"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (buffer-local buf 'agent-slug))
           (modes (buffer-local buf 'agent-modes)))
      (cond ((not slug) (message "not an agent chat"))
            ((not modes) (message "this backend has no session modes"))
            (else
              (minibuffer-read
                (string-append "Mode (now " (or (buffer-local buf 'agent-mode) "?") "): ")
                (map (lambda (m) (list (car m) (or (nth 2 m) ""))) modes)
                (lambda (m)
                  (unless (equal? (string-trim m) "")
                    (if (llm-session-set-mode! slug m)
                        (begin (buffer-set-local! buf 'agent-mode m)
                               (agent-update-modeline! buf)
                               (message (string-append "agent mode: " m)))
                        (message "the agent refused that mode"))))))))))

(define-command "chat-set-permission-mode" "Cycle this chat's permission mode"
  (lambda ()
    (let* ((buf (current-buffer))
           (m (chat-permission-mode buf))
           (next (cond ((equal? m 'approve) 'auto)
                       ((equal? m 'auto) 'ask)
                       (else 'approve))))
      (buffer-set-local! buf 'chat-permission-mode next)
      ;; a live agent hears about it immediately, not at the next reconnect
      (let ((slug (buffer-local buf 'agent-slug)))
        (when (and slug (not (equal? (agent-status slug) 'dead)))
          (agent-sync-permission-mode! slug)))
      (agent-update-modeline! buf)
      (message
        (string-append "permissions: " (symbol->string next)
          (cond ((equal? next 'ask) " — every tool call asks")
                ((equal? next 'approve) " — only irreversible acts ask")
                (else " — the agent stops asking too; the deny-list still holds")))))))

;;; --- permission answers -------------------------------------------------------

;; option whose kind matches exactly, else by prefix — options are
;; (option-id name kind) triples from the ACP request
(define (agent-perm-option options exact prefix)
  (let loop ((os options) (by-prefix #f))
    (cond ((null? os) by-prefix)
          ((equal? (nth 2 (car os)) exact) (car os))
          ((and (not by-prefix) (string-prefix? prefix (nth 2 (car os))))
           (loop (cdr os) (car os)))
          (else (loop (cdr os) by-prefix)))))

;; want: "allow_once" | "allow_always" | "reject_once"; no match -> cancel.
;; bb's rule, adopted: approving is invisible, denying is recorded — an
;; allowed tool just runs, a denial leaves a line in the transcript.
(define (agent-answer-permission! slug exact prefix)
  (let ((info (agent-info slug)))
    (let ((perm (and info (plist-get info 'permission))))
      (if (not perm)
          (message "no pending permission")
          (let ((opt (agent-perm-option (plist-get perm 'options) exact prefix)))
            (agent-permission-respond! slug (plist-get perm 'rpc-id)
              (if opt (car opt) #f))
            (when (string-prefix? "reject" prefix)
              (let ((start (agent-render! slug
                             (string-append "permission denied: "
                                            (plist-get perm 'title) "\n")
                             "agent-meta")))
                (agent-block-push! (agent-buf slug) start
                  (agent-mark slug) "meta" '()))))))))

(define-command "agent-permission-allow" "Allow the pending permission request once"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_once" "allow")))

;; allow this AND stop asking for this tool (ACP allow_always)
(define-command "agent-permission-always" "Allow and stop asking for this tool"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_always" "allow")))

(define-command "agent-permission-deny" "Deny the pending permission request"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "reject_once" "reject")))

;;; --- steering -----------------------------------------------------------------

;; a model saved on a buffer may belong to a DIFFERENT connector — an
;; earlier ACP session's model-state (its "current" id, e.g. an adapter's
;; own "default" sentinel), or a pin left from before a connector switch.
;; Carrying it verbatim into a new connector is worse than none: an ACP
;; adapter just ignores an id it doesn't recognize, but the api lane's
;; wire sends it to the provider unmodified and 404s. Declared empty (a
;; connector that has never reported models) can't validate anything, so
;; nothing is filtered then. On rejection: clear the buffer local so the
;; foreign id doesn't keep coming back, and warn once.
;; the pure half: is this buffer's pinned model one this connector could
;; actually run? (Used by the modeline, which must never claim a model the
;; session isn't running — and must not have side effects.)
(define (agent-model-foreign? buf cname m)
  (let ((declared (append (connector-models cname)
                          (map car (or (buffer-local buf 'agent-models) '())))))
    (and m (pair? declared) (not (member m declared)))))

(define (agent-model-for-connector buf cname)
  (let ((m0 (buffer-local buf 'agent-model)))
    (if (agent-model-foreign? buf cname m0)
        (begin
          (buffer-set-local! buf 'agent-model #f)
          (agent-update-modeline! buf)
          (message (string-append m0 " isn't a " cname
                                  " model — using its default"))
          #f)
        m0)))

;; a restored (or crashed) thread is a live transcript with a dead runtime.
;; The slug-keyed door onto the one attach function (editor.scm): a fresh
;; agent on its own connector, seeded with what was said.
(define (agent-revive! slug) (chat-attach! (agent-buf slug)))

;; the low-level reattach: kill + start again on this connector/model.
;; Fresh session — the transcript stays, server-side context doesn't.
;; Callers that want a SWITCH (which may not need a restart at all) go
;; through chat-switch! in editor.scm; this is for the paths that must
;; restart whatever happens: the C-RET hard reset, and a preset change
;; whose whole point is a new mcpServers list.
(define (agent-reconnect! slug cname model)
  (let ((buf (agent-buf slug)))
    (llm-session-close! slug)
    (buffer-set-local! buf 'agent-connector cname)
    (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
    (agent-update-modeline! buf)
    (agent-revive! slug)))

(define-command "agent-switch" "Reattach this thread to a new connector and model"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (agent-slug-of buf))
          (message "not an agent buffer")
          (minibuffer-read "Connector: " (connector-names)
            (lambda (cname)
              (minibuffer-read "Model (empty = connector default): "
                (connector-models cname)
                (lambda (model)
                  ;; one switch function for every path (editor.scm)
                  (chat-switch! buf cname model)))))))))

;; a revived/switched thread runs a FRESH provider session (different
;; provider = different session ids; resume can't cross). Seed its first
;; prompt with the transcript tail so the conversation continues instead of
;; restarting from nothing. Whole lines only — a byte-offset cut could
;; split a utf-8 char and poison the json encoder.

;; the conversation as text: block-mapped spans minus the chrome (meta
;; cards, waiting/permission banners) — seeding a fresh session with the
;; help banner is noise, not context. Buffers from before the block model
;; fall back to the raw region below the mark.
(define (agent-conversation-text buf)
  (let ((bs (or (buffer-local buf 'agent-blocks) '()))
        (text (buffer-text buf))
        (mark (or (buffer-local buf 'agent-saved-mark) (buffer-size buf))))
    (if (null? bs)
        (substring-bytes text 0 mark)
        (let loop ((bs (reverse bs)) (acc ""))
          (if (null? bs)
              acc
              (let ((b (car bs)))
                (loop (cdr bs)
                      (if (member (caddr b) (list "meta" "waiting" "permission"))
                          acc
                          (string-append acc
                            (substring-bytes text (car b)
                                             (min (cadr b) mark)))))))))))

;; the seed for a fresh session is simply the WHOLE conversation, in the
;; portable transcript format (### You / ### Assistant — same as .chat
;; files): the record when the chat has one, block text minus chrome for
;; legacy buffers. No cap, no tail games — switching models sends the chat.
(define (agent-seed-transcript buf)
  (or (chat-flatten buf) (agent-conversation-text buf)))

;; the wire text may carry chrome (editor context, seed transcript) the
;; user never typed — the raw input rides along as the DISPLAY text: it is
;; what the transcript renders and what the record keeps as the turn
(define (agent-send-msg! slug raw)
  (let* ((buf (agent-buf slug))
         ;; what the user is looking at in the other windows — "this" works
         ;; — and, with tools off, the group's live text. Both ride the
         ;; MESSAGE, never the system prompt: everything above this turn is
         ;; already cached, and an edit must not cost that cache.
         (msg (string-append (chat-context-block buf)
                             (editor-context-preamble buf) raw)))
    (if (buffer-local buf 'agent-seed-context)
        (begin
          (buffer-set-local! buf 'agent-seed-context #f)
          ;; Say it. This is not a resumed session — the adapter has no
          ;; memory of any of this, and the conversation above is being
          ;; pasted into its first message. A reader who thinks the agent
          ;; remembers will misread everything that follows.
          (let ((start (agent-render! slug
                         "\n[fresh session — the conversation above was replayed into it]\n"
                         "agent-meta")))
            (agent-block-push! buf start (agent-mark slug) "meta" '()))
          (llm-session-send! slug
            (string-append
              "Context: this continues an earlier conversation from the"
              " user's editor (possibly with a different model). The"
              " conversation so far:\n\n" (agent-seed-transcript buf)
              "\n\nContinue naturally from there. New message:\n" msg)
            raw))
        (llm-session-send! slug msg raw))))

(define-command "agent-send" "Send the input to the agent, reviving it if dead"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; a chat without a runtime gets one on first send, on its own
           ;; connector; RET is agent-send on EVERY chat
           (slug (or (agent-slug-of buf)
                     (and (equal? (buffer-local buf 'mode-name) "chat-mode")
                          (buffer-local buf 'agent-saved-mark)
                          (chat-ensure-runtime! buf)))))
      (cond ((not slug) (message "not an agent buffer"))
            (else
             ;; a preset changed under a live ACP session: its tool list is
             ;; fixed at session/new, so reattach before sending
             (when (boundp (quote chat-apply-pending-presets!))
               (chat-apply-pending-presets! buf))
             (when (equal? (agent-status slug) 'dead)
               (agent-revive! slug))
             (let ((input (string-trim (chat-input-text buf))))
               (if (equal? input "")
                   (insert! "\n")
                   (begin
                     ;; the message itself lands in the record when its
                     ;; turn starts; only the walk position resets here
                     (chat-history-reset! buf)
                     (if (equal? (agent-send-msg! slug input) 'queued)
                         ;; mid-turn: the text stays put, muted, until its turn
                         (begin
                           (chat-mark-queued! buf)
                           (end-of-buffer!)
                           (message "queued — runs when this turn ends"))
                         (begin
                           (chat-clear-input! buf)
                           (end-of-buffer!)
                           (message "sent")))))))))))

;;; --- input history --------------------------------------------------------------
;;; Up and down walk the messages you sent, the way a shell walks its
;;; history. The text you were typing is kept as the draft, so walking
;;; back down to the bottom returns it.
;;;
;;; The messages come from the record, which every backend already fills
;;; and which the desktop, .chat files, and the api lane already read. A
;;; second copy would be a second truth: a chat restored from a .chat file
;;; gets its turns back, so it must get its history back with them.
;;;
;;; Up and down still move the cursor inside a multi-line input. Only the
;;; first line recalls an earlier message, and only the last line walks
;;; back toward the draft.

;; how far back up walks — a long conversation needs no more
(define *chat-history-limit* 200)

;; your messages, newest first (the record is already newest first)
(define (chat-history buf)
  (chat-take
    (let loop ((ts (if (boundp (quote chat-turns)) (chat-turns buf) '())) (acc '()))
      (cond ((null? ts) (reverse acc))
            ((equal? (car (car ts)) "user")
             (loop (cdr ts) (cons (car (cdr (car ts))) acc)))
            (else (loop (cdr ts) acc))))
    *chat-history-limit*))

;; back to "not walking": the next up starts from the newest message again
(define (chat-history-reset! buf)
  (buffer-set-local! buf 'chat-history-pos #f)
  (buffer-set-local! buf 'chat-history-draft #f))

;; The marker shares a line with the first line of input (">>> you: aaa"),
;; so moving up from the second line lands point INSIDE the marker. That
;; is still the input area: measure from the mark, not from the text after
;; the marker, or the next up walks out of the input entirely.
(define (chat-in-input? buf)
  (>= (point) (or (buffer-local buf 'agent-saved-mark) 0)))

;; no newline between the input start and point
(define (chat-on-first-input-line? buf)
  (let ((start (car (chat-input-region buf))))
    (or (<= (point) start)
        (not (string-contains?
               (substring-bytes (buffer-text buf) start (point))
               "\n")))))

(define (chat-on-last-input-line? buf)
  (not (string-contains?
         (substring-bytes (buffer-text buf) (point) (buffer-size buf))
         "\n")))

;; 'chat-history-pos is #f while you edit your own draft, else an index
;; into the history (0 is the newest message).
(define (chat-history-recall! buf dir)
  (let* ((h (chat-history buf))
         (pos (or (buffer-local buf 'chat-history-pos) -1))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length h)) (message "no earlier message"))
          ((< next -1) #f)
          (else
            ;; hold the draft the first time you step off it
            (when (= pos -1)
              (buffer-set-local! buf 'chat-history-draft (chat-input-text buf)))
            (buffer-set-local! buf 'chat-history-pos (if (= next -1) #f next))
            (chat-replace-input! buf
              (if (= next -1)
                  (or (buffer-local buf 'chat-history-draft) "")
                  (nth next h)))))))

(define (chat-history-move! dir)
  (let* ((buf (current-buffer))
         (motion (if (< dir 0) "previous-line" "next-line")))
    (if (or (not (buffer-local buf 'agent-saved-mark))
            (not (chat-in-input? buf))
            (null? (chat-history buf))
            ;; inside a multi-line input, up and down are still motion
            (if (< dir 0)
                (not (chat-on-first-input-line? buf))
                (not (chat-on-last-input-line? buf))))
        (run-command motion)
        (chat-history-recall! buf dir))))

(define-command "chat-history-previous" "Recall the previous message you sent"
  (lambda () (chat-history-move! -1)))

(define-command "chat-history-next" "Recall the next message you sent"
  (lambda () (chat-history-move! 1)))

;; C-RET escalates: dead -> revive; running -> polite session/cancel;
;; still running on the next press -> hard reset (kill + reattach, same
;; connector/model, transcript kept). The deterministic unstick gesture.
(define-command "agent-interrupt-send" "Revive, cancel, or hard-reset the agent"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer)))
          (buf (current-buffer)))
      (when slug
        (cond ((equal? (agent-status slug) 'dead)
               (agent-revive! slug))
              ((buffer-local buf 'agent-cancelling)
               (buffer-set-local! buf 'agent-cancelling #f)
               (agent-reconnect! slug
                 (or (buffer-local buf 'agent-connector) *default-connector*)
                 (or (buffer-local buf 'agent-model) ""))
               (message "agent restarted (hard reset)"))
              (else
               (buffer-set-local! buf 'agent-cancelling #t)
               (llm-session-cancel! slug)
               (message "cancel requested — C-RET again forces a restart")))))))

;; The plain half of that ladder, on the key Emacs aborts with. C-g stops
;; the reply in flight and leaves the thread alone — no restart, no
;; escalation. With nothing running it quits the usual way, so C-g in a
;; chat still clears the mark and closes the minibuffer.
(define-command "chat-abort" "Stop the reply in flight in this chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf)))
      (if (and slug (member (agent-status slug) '(running starting needs_attention)))
          (begin
            (llm-session-cancel! slug)
            ;; both waiting markers: a thread renders its own ('agent-waiting),
            ;; a chat that never attached a runtime renders 'chat-waiting
            (agent-clear-waiting! slug)
            (chat-clear-waiting! buf)
            (message "aborted"))
          (run-command "keyboard-quit")))))

;;; --- connectors ---------------------------------------------------------------
;;; A connector is a named config plist for a thread's backend: 'backend
;;; (which Elixir Backend module runs turns — "acp" default, "stub" for
;;; tests), 'cmd (the ACP adapter), 'env (auth/model context), 'cwd,
;;; 'mcp-servers. The point is
;;; economic as much as technical — a codex connector rides a ChatGPT
;;; subscription, claude-code rides a Max plan, an api connector burns tokens.
;;; Define your own in ~/.aimax/ai-config.scm:
;;;   (define-connector! "codex" '(cmd "codex-acp"))
;;;   (set! *default-connector* "codex")

(define *agent-connectors* '())
(define *default-connector* "claude-code")

(define (define-connector! name config)
  (set! *agent-connectors*
    (cons (list name config)
          (let loop ((cs *agent-connectors*) (acc '()))
            (cond ((null? cs) (reverse acc))
                  ((equal? (car (car cs)) name) (loop (cdr cs) acc))
                  (else (loop (cdr cs) (cons (car cs) acc))))))))

(define (connector-config name)
  (let ((e (assoc name *agent-connectors*)))
    (if e (car (cdr e)) '())))

;; 'meta rides verbatim into session/new as _meta. claude-code-acp spreads
;; _meta.claudeCode.options over its own defaults, so this plist is how
;; aimax takes control of the agent's surface. (Verified against
;; @zed-industries/claude-code-acp 0.16.2: options = {...defaults,
;; ...userProvidedOptions, ...ACP-controlled fields}.)
;;
;; It takes BOTH keys. settingSources () stops the adapter reading
;; settings.json and CLAUDE.md. It does NOT stop MCP servers: the CLI reads
;; those from ~/.claude.json, which no setting source covers, and merges
;; them into --mcp-config. strictMcpConfig #t adds --strict-mcp-config,
;; which makes --mcp-config the only source. Without it every thread also
;; carried the user's own claude.ai connectors — Gmail, Slack, Exa — that
;; no preset asked for.
;;
;; The same plist takes the rest of the Agent SDK tool controls, so a
;; connector can cut the surface further:
;;   (options (settingSources () strictMcpConfig #t
;;             disallowedTools ("WebSearch" "WebFetch")))
(define-connector! "claude-code"
  ;; npm's @zed-industries/claude-code-acp lags upstream (pins an old
  ;; claude-agent-sdk with a stale model catalog: no Sonnet 5/Opus 5/Fable,
  ;; no pricing) — bare "claude-code-acp" resolves the stale global npm
  ;; install via PATH, so point at a from-source build instead:
  ;; ~/src/claude-code-acp, `npm run build` with node >=22.
  '(cmd "/Users/svs/.asdf/installs/nodejs/24.0.2/bin/node /Users/svs/src/claude-code-acp/dist/index.js"
    meta (claudeCode (options (settingSources () strictMcpConfig #t)))
    models ("claude-sonnet-5" "claude-opus-5" "claude-haiku-4-5-20251001")))
;; Codex rides a ChatGPT subscription (auth from `codex login`). The primary
;; connector speaks App Server directly. The old Codex ACP bridge remains a
;; hidden compatibility connector for saved chats, but is deprecated and is
;; no longer offered for new chats.
(define *codex-app-server-connector*
  '(backend "codex-app-server" cmd "codex app-server"
    models ("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna" "gpt-5.5"
            "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex-spark")))
(define-connector! "codex-app-server" *codex-app-server-connector*)
;; Existing .chat headers and user config named this connector "codex".
;; Keep that identity working, but do not show a duplicate picker row.
(define-connector! "codex" (append '(hidden #t) *codex-app-server-connector*))
(define-connector! "codex-acp"
  '(hidden #t deprecated "use codex-app-server"
    cmd "codex-acp" model-flag "-c model="
    models ("gpt-5.6-luna" "gpt-5.5" "gpt-5.5-pro" "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex")))
;; the direct-API lane: in-process req_llm turns — streaming, tools, cost
;; tracking, no subprocess. "api" is just another connector, and it
;; declares its models like any other — as a thunk, because the set is
;; *llm-models*, which a user can set! at any time.
(define-connector! "api"
  (list 'backend "req-llm"
        ;; User choices stay first as favorites; ReqLLM contributes every
        ;; chat model whose provider is actually configured on this machine.
        'models (lambda ()
                  (fold (lambda (acc m)
                          (if (member m acc) acc (append acc (list m))))
                        *llm-models* (llm-available-models)))))

;; What a connector's backend CAN DO, asked of the backend itself. Every
;; question that used to be "is this the api lane?" is one of these now: a
;; new lane declares what it is instead of being special-cased by name.
;;   stateless     — no server-side session; the record is replayed whole
;;   metered       — turns are billed and report usage
;;   session_modes — the adapter has its own permission modes
;;   models        — it can switch model in place
(define (connector-capabilities name)
  (backend-capabilities (or (plist-get (connector-config name) 'backend) "acp")))

(define (connector-can? name cap)
  (and (member cap (connector-capabilities name)) #t))

;; ONE model catalog, keyed by connector: what the switch prompt offers,
;; what a pinned model is validated against, what C-c m lists. 'models is
;; a list, or a thunk when the set is dynamic.
(define (connector-models name)
  (let ((m (plist-get (connector-config name) 'models)))
    (cond ((procedure? m) (m))
          (m m)
          (else '()))))

;; CLAUDE_CODE_SUBAGENT_MODEL too: the adapter's bundled SDK defaults
;; subagents to a retired model id (404s) unless told otherwise
(define (agent-model-env m)
  (list 'env (list (list "ANTHROPIC_MODEL" m)
                   (list "CLAUDE_CODE_SUBAGENT_MODEL" m))))

;; per-call opts win over the connector. A thread's model ('model in conf,
;; defaulting to the editor's model when this connector offers it) reaches
;; the backend by whatever route the connector declares: 'model-flag appends
;; it to the adapter command line (codex -c model=...), otherwise it rides
;; the anthropic env pair. Connectors that offer neither stay untouched.
(define (agent-resolve-config opts)
  (let ((conf (agent-resolve-config* opts)))
    ;; ACP threads get exactly the servers their presets name. The editor's
    ;; own tools are the `aimax` preset, not an implicit exception. The
    ;; direct lane needs no server config: it reads the same preset surface
    ;; fresh at every send.
    (if (or (equal? (plist-get conf 'backend) "req-llm")
            (plist-get conf 'mcp-servers)
            (not (boundp (quote presets-acp-servers))))
        conf
        (agent-config-with-primer
          (agent-config-with-mcp-note
            (append conf
              (list 'mcp-servers
                    (presets-acp-servers (or (plist-get conf 'presets) '())))))))))

;; ...and the sentence that says the other servers exist. An agent holds
;; the preset's tools and nothing else, so a server outside the preset is
;; invisible to it — it guessed ssh for one. _meta.systemPrompt.append
;; rides on the claude-code preset prompt rather than replacing it.
;; ...and the primer, so an ACP agent gets the same cold start a socket
;; client gets from `initialize`. It holds the aimax tools through the MCP
;; proxy; without this it holds them and does not know what they are for.
(define (agent-config-with-primer conf)
  (let ((primer (if (boundp (quote hello)) (hello) "")))
    (if (equal? primer "")
        conf
        (agent-config-append-system conf primer))))

(define (agent-config-append-system conf text)
  (let* ((meta (or (plist-get conf 'meta) '()))
         (sp (or (plist-get meta 'systemPrompt) '()))
         (had (or (plist-get sp 'append) "")))
    (append (list 'meta (append (list 'systemPrompt
                                      (list 'append (if (equal? had "")
                                                        text
                                                        (string-append had "\n\n" text))))
                                meta))
            conf)))

(define (agent-config-with-mcp-note conf)
  (let ((note (if (and (boundp (quote mcp-system-note))
                       (boundp (quote preset-servers)))
                  ;; only what this thread's presets expose — the same set
                  ;; its mcpServers list holds
                  (mcp-system-note
                    (fold (lambda (acc p)
                            (fold (lambda (acc2 s) (if (member s acc2) acc2 (cons s acc2)))
                                  acc (preset-servers p)))
                          '() (or (plist-get conf 'presets) '())))
                  "")))
    (if (equal? note "")
        conf
        (agent-config-append-system conf note))))

(define (agent-resolve-config* opts)
  (let* ((cname (or (plist-get opts 'connector) *default-connector*))
         (conf (append opts (connector-config cname)))
         (m (or (plist-get conf 'model)
                (and (member (llm-model) (connector-models cname)) (llm-model)))))
    (cond ((not m) conf)
          ((or (equal? (plist-get conf 'backend) "req-llm")
               (equal? (plist-get conf 'backend) "codex-app-server"))
           ;; direct and native lanes carry the model in protocol config,
           ;; not adapter command-line wiring
           (append (list 'model m) conf))
          ((plist-get conf 'model-flag)
           ;; value must be quoted TOML — codex ignores the bare form
           (append (list 'model m
                         'cmd (string-append (plist-get conf 'cmd) " "
                                             (plist-get conf 'model-flag)
                                             "\"" m "\""))
                   conf))
          ((plist-get conf 'env) conf)           ; explicit env wins
          (else (append (list 'model m) conf (agent-model-env m))))))

(define (connector-names)
  (let loop ((cs *agent-connectors*) (acc '()))
    (if (null? cs)
        (reverse acc)
        (loop (cdr cs)
              (if (plist-get (car (cdr (car cs))) 'hidden)
                  acc
                  (cons (car (car cs)) acc))))))

(define (connector-description name)
  (let ((backend (or (plist-get (connector-config name) 'backend) "acp")))
    (cond ((equal? backend "req-llm")
           "direct API — metered, cached, cheap lane")
          ((equal? backend "codex-app-server")
           "Codex App Server — ChatGPT subscription")
          (else
           "ACP agent — subscription or external adapter"))))

;; the model a resolved config lands on: explicit 'model, else the
;; ANTHROPIC_MODEL env pair, else #f (adapter's own default)
(define (agent-conf-model conf)
  (or (plist-get conf 'model)
      (let loop ((es (or (plist-get conf 'env) '())))
        (cond ((null? es) #f)
              ((equal? (car (car es)) "ANTHROPIC_MODEL") (car (cdr (car es))))
              (else (loop (cdr es)))))))

;; modeline: "connector · model [· $cost]" — the thread's economic
;; identity; click it to switch (modeline-info-command -> agent-switch).
;; The api lane follows the editor default when no model is pinned, and
;; carries its running cost; ACP rides a subscription and shows none.
(define (agent-update-modeline! buf)
  (let* ((c (or (buffer-local buf 'agent-connector) *default-connector*))
         ;; never name a model this connector can't run: a pinned id left
         ;; over from another backend (an ACP "default" sentinel, say) is
         ;; about to be dropped at send time anyway
         (pinned (let ((m (buffer-local buf 'agent-model)))
                   (and m (not (agent-model-foreign? buf c m)) m)))
         (m (or pinned (and (connector-can? c 'stateless) (llm-model))))
         (cost (and (connector-can? c 'metered) (buffer-local buf 'chat-cost))))
    (buffer-set-local! buf 'modeline-info
      (string-append c
        (if (and m (not (equal? m ""))) (string-append " · " m) "")
        (let ((effort (buffer-local buf 'agent-effort)))
          (if effort (string-append " · " effort) ""))
        (if cost (string-append " · " (format-usd cost)) "")
        ;; what will and won't stop to ask — never leave this ambiguous
        " · " (symbol->string (chat-permission-mode buf))
        ;; the agent's own mode, when it is running something other than
        ;; its default (plan mode especially changes what a turn DOES)
        (let ((am (buffer-local buf 'agent-mode)))
          (if (and am (not (equal? am "default"))) (string-append " · " am) ""))
        ;; the editor has tools this chat froze out. Say so: adopting them
        ;; (C-c t) costs a cache miss, so it is the user's call, not ours.
        (if (and (boundp (quote chat-tools-stale?)) (chat-tools-stale? buf))
            " · tools stale"
            "")))
    ;; the segment is clickable: ui-command! runs this on a click
    (buffer-set-local! buf 'modeline-info-command "agent-switch")))

;;; --- thread creation ----------------------------------------------------------

;; skip live runtimes, existing thread buffers, AND slugs claimed by any
;; buffer's 'agent-slug local — chats host threads under their own names
;; now, so checking *agent:* buffers alone hands out duplicates (two chats
;; on one slug = events and prompts routed into the wrong buffer)
(define (agent-claimed-slugs)
  (filter (lambda (s) s)
          (map (lambda (b) (buffer-local b 'agent-slug)) (buffer-list))))

(define (agent-next-slug)
  (let ((claimed (agent-claimed-slugs)))
    (let loop ((n 1))
      (let ((slug (string-append "a" (number->string n))))
        (if (or (member slug (agent-list))
                (buffer-exists? (agent-buffer slug))
                (member slug claimed))
            (loop (+ n 1))
            slug)))))

(define (agent-install-keys! buf)
  (local-set-key* buf "RET" "agent-send")
  (local-set-key* buf "C-RET" "agent-interrupt-send")
  (local-set-key* buf "C-g" "chat-abort")
  (local-set-key* buf "TAB" "agent-toggle-fold")
  (local-set-key* buf "<up>" "chat-history-previous")
  (local-set-key* buf "<down>" "chat-history-next")
  (local-set-key* buf "C-c C-y" "agent-permission-allow")
  (local-set-key* buf "C-c C-a" "agent-permission-always")
  (local-set-key* buf "C-c C-n" "agent-permission-deny")
  (local-set-key* buf "C-c p" "chat-set-permission-mode")
  (local-set-key* buf "C-c t" "chat-refresh-tools")
  (local-set-key* buf "C-c C-v" "chat-toggle-view"))

;; (execute "task")                         — spawn a task chat on the default connector
;; (execute* "task" '(connector "codex"))   — pick a connector / pin a model
(category! 'chat)
(public! 'execute "(execute \"task\") — spawn a task chat on an ACP backend; returns its slug")
(public! 'execute* "(execute* \"task\" '(connector \"codex\" model \"...\")) — spawn with config")

(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  (let* ((slug (agent-next-slug))
         (buf (string-append "*chat:" slug "*")))
    (buffer-create buf)
    (buffer-set-local! buf 'agent-slug slug)
    ;; a spawned chat may declare its permission posture up front — the
    ;; first turn can start before anyone could press C-c p
    (let ((pm (plist-get opts 'permission-mode)))
      (when pm (buffer-set-local! buf 'chat-permission-mode pm)))
    ;; ...and its presets, which must land in the buffer-local, not only in
    ;; this one call's config. 'chat-presets is the single source of truth
    ;; for a chat's tools: agent-revive! and the desktop restore both read
    ;; it. A spawn that skips it starts with the right servers and loses
    ;; them at the first revive.
    (let ((ps (plist-get opts 'presets)))
      (when ps (buffer-set-local! buf 'chat-presets ps)))
    (chat-task-init! buf slug)
    (chat-attach-agent! buf
      (or (plist-get opts 'connector) *default-connector*)
      (plist-get opts 'model)
      opts)
    (display-buffer buf)
    (when (equal? (current-buffer) buf)
      (set-mode! "chat-mode")
      (end-of-buffer!))
    (unless (equal? prompt "")
      (llm-session-send! slug prompt))
    slug))

(define-command "agent-open" "Prompt for a task and spawn a new agent thread"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task) (execute task)))))

;;; --- the fleet: *chats*, every chat in one list ------------------------------------------------------
;;; dired for threads. One line each, needs-attention first; single-key ops.
;;; Live + dead-but-buffered threads both list (a transcript is a thread).

;; there is only chat: the fleet list shows every chat — agent-backed
;; threads with live status, API companions as plain "chat" rows
(define *agents-buffer* "*chats*")
(add-display-rule! *agents-buffer* 'popup)

;; every thread the editor knows: (slug status). One scan of the fleet —
;; chat-list-bufs — answers both questions; a thread is just a chat that
;; claims a slug, so this is a filter over it, not a second walk with its
;; own idea of what counts.
(define (agent-threads)
  (map (lambda (b) (list (buffer-local b 'agent-slug) (chat-row-status b)))
       (filter (lambda (b) (buffer-local b 'agent-slug)) (chat-list-bufs))))

(define (agent-status-rank s)
  (cond ((equal? s 'needs_attention) 0)
        ((equal? s 'running) 1)
        ((equal? s 'starting) 1)
        ((equal? s 'idle) 2)
        ((equal? s 'api) 2)
        (else 3)))

(define (agent-status-glyph s)
  (cond ((equal? s 'needs_attention) "!")
        ((equal? s 'running) "*")
        ((equal? s 'starting) "*")
        ((equal? s 'idle) "-")
        ((equal? s 'api) "-")
        (else "x")))

;; every chat the editor knows: agent-backed threads carry their runtime
;; status, plain API companions read 'api
(define (chat-list-bufs)
  (let loop ((bs (buffer-list)) (acc '()))
    (cond ((null? bs) (reverse acc))
          ((and (not (string-prefix? " " (car bs)))
                (or (buffer-local (car bs) 'agent-slug)
                    (chat-buffer? (car bs))))
           (loop (cdr bs) (cons (car bs) acc)))
          (else (loop (cdr bs) acc)))))

(define (chat-row-status b)
  (let ((slug (buffer-local b 'agent-slug)))
    (if slug (agent-status slug) 'api)))

;; rank buckets — the builtin sort takes no comparator
(define (agents-sorted)
  (let ((bs (chat-list-bufs)))
    (let loop ((rank 0) (acc '()))
      (if (> rank 3) (reverse acc)
          (loop (+ rank 1)
                (let inner ((bs bs) (acc acc))
                  (cond ((null? bs) acc)
                        ((= (agent-status-rank (chat-row-status (car bs))) rank)
                         (inner (cdr bs) (cons (car bs) acc)))
                        (else (inner (cdr bs) acc)))))))))

(define (agents-line b)
  (let* ((slug (buffer-local b 'agent-slug))
         (status (chat-row-status b))
         (info (and slug (agent-info slug))))
    (string-append
      (agent-status-glyph status) " "
      (string-pad-right (or slug "chat") 12)
      (string-pad-right b 26) " "
      (string-pad-right (or (buffer-local b 'modeline-info) "") 32) " "
      (string-pad-right (symbol->string status) 17)
      (if (and info (> (plist-get info 'queued) 0))
          (string-append "+" (number->string (plist-get info 'queued)) " queued")
          ""))))

(define (agents-refresh!)
  (when (buffer-exists? *agents-buffer*)
    (list-refresh! *agents-buffer*)))

(define (agents-current-buf) (list-current *agents-buffer*))

;; the slug on the current line, #f when the chat has no runtime
(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

;; the chats a verb acts on — list-mode's own marked-or-current rule, with
;; killed buffers dropped: a mark outlives the chat that carried it
(define (agents-targets)
  (filter (lambda (b) (buffer-exists? b)) (list-targets *agents-buffer*)))

;; how a verb reports what it did to N chats at once
(define (agents-report verb bs)
  (message (if (= (length bs) 1)
               (string-append verb " " (car bs))
               (string-append verb " " (number->string (length bs)) " chats"))))

(define (agents-visit-current)
  (let ((b (agents-current-buf)))
    (when b (switch-to-buffer! b) (end-of-buffer!))))

;; the other window follows the highlight, like ibuffer/notmuch
(define (agents-preview!)
  (let ((b (agents-current-buf)))
    (when (and b (buffer-exists? b))
      (display-buffer-other-window! b))))

(define-command "agents-next" "Move down and preview the chat in another window"
  (lambda () (next-line!) (agents-preview!)))

(define-command "agents-prev" "Move up and preview the chat in another window"
  (lambda () (previous-line!) (agents-preview!)))

(define-command "agents-visit" "Visit the thread on the current line"
  (lambda () (agents-visit-current)))

;; a live runtime for BUF: a restored chat has a transcript and no runtime,
;; and every verb here needs one. This is the same attach the chat buffer
;; itself does when you type in it, so steering from the list revives a
;; chat exactly like visiting it and pressing RET does.
(define (agents-live-slug buf)
  (let ((slug (or (buffer-local buf 'agent-slug) (chat-ensure-runtime! buf))))
    (if (equal? (agent-status slug) 'dead) (agent-revive! slug) slug)))

(define-command "agents-steer" "Send a steering message to the marked chats"
  (lambda ()
    (let ((bs (agents-targets)))
      (if (null? bs)
          (message "no chat here")
          (minibuffer-read
            (if (= (length bs) 1)
                (string-append "Steer " (car bs) ": ")
                (string-append "Steer " (number->string (length bs)) " chats: "))
            '()
            (lambda (msg)
              (unless (equal? msg "")
                (for-each (lambda (b) (agent-send-msg! (agents-live-slug b) msg)) bs)
                (agents-refresh!)
                (agents-report "steered" bs))))))))

;; y and n answer every marked chat that waits on a permission; a chat with
;; no runtime has no question pending, so it is skipped, not attached
(define (agents-answer! exact prefix verb)
  (let ((bs (filter (lambda (b) (buffer-local b 'agent-slug)) (agents-targets))))
    (if (null? bs)
        (message "no chat with a runtime here")
        (begin
          (for-each (lambda (b)
                      (agent-answer-permission! (buffer-local b 'agent-slug)
                                                exact prefix))
                    bs)
          (agents-refresh!)
          (agents-report verb bs)))))

(define-command "agents-allow" "Allow the pending permission for the marked chats"
  (lambda () (agents-answer! "allow_once" "allow" "allowed")))

(define-command "agents-deny" "Deny the pending permission for the marked chats"
  (lambda () (agents-answer! "reject_once" "reject" "denied")))

;; mark the transcript BEFORE the runtime dies (the mark primitive needs it
;; alive) so windows showing the thread refresh honestly
(define (agent-note-stopped! slug)
  (unless (equal? (agent-status slug) 'dead)
    (let ((buf (agent-buf slug)))
      (agent-clear-waiting! slug)
      (agent-block-drop-kind! buf "permission")
      (let ((start (agent-render! slug "\n[agent stopped]\n" "agent-meta")))
        (agent-block-push! buf start (agent-mark slug) "meta" '())))))

;; point any window showing BUF somewhere else, in every frame — killing a
;; displayed buffer leaves a ghost that resurrects empty
(define (agent-release-windows! buf)
  (let* ((others (filter (lambda (b) (and (not (equal? b buf))
                                          (not (string-prefix? "*agent" b))))
                         (buffer-list-mru)))
         (repl (if (null? others) "*scratch*" (car others))))
    (for-each
      (lambda (w)
        (when (equal? (car (cdr w)) buf)
          (window-set-buffer! (car w) repl)))
      (window-list-all))))

;; kill the runtime, keep the transcript. #f when the chat has no runtime:
;; the caller counts what really happened instead of reporting a kill that
;; killed nothing.
(define (agents-kill-runtime! b)
  (let ((slug (buffer-local b 'agent-slug)))
    (and slug
         (begin (agent-note-stopped! slug)
                (llm-session-close! slug)
                #t))))

;; archive: runtime (if any) + buffer both go (desktop stops restoring it).
;; Killing a displayed chat moves windows around, so come back to the list.
(define (agents-archive! b)
  (let ((here (active-window)))
    (agents-kill-runtime! b)
    (agent-release-windows! b)
    (buffer-kill! b)
    (when (window-exists? here) (select-window! here))))

(define-command "agents-refresh" "Refresh the chat list"
  (lambda () (agents-refresh!)))

(define-list-mode! "chats-mode"
  (list
    'doc (string-append
           "Every chat and agent thread in one list: its runtime, its state and "
           "its cost. It marks and executes like ibuffer. `m` marks a chat, `u` "
           "unmarks it and `U` drops every mark; `s` steers, `y` and `n` answer "
           "a permission request for the marked chats, or for the chat at point "
           "when nothing is marked. `k` flags a runtime to kill, `d` flags a "
           "whole chat to archive, and `x` runs the flags. `RET` opens the chat "
           "at point.")
    'buffer *agents-buffer*
    'rows (lambda (buf) (agents-sorted))
    'render (lambda (buf row) (agents-line row))
    ;; two flags, both destructive, neither irreversible: k stops a runtime
    ;; and keeps the transcript, d drops the chat as well
    'flags (list (list "k" "K" "kill runtime"
                       (lambda (buf b)
                         (and (buffer-exists? b) (agents-kill-runtime! b))))
                 (list "d" "D" "archive"
                       (lambda (buf b)
                         (and (buffer-exists? b)
                              (begin (agents-archive! b) #t)))))
    'noun "chat"
    'header (lambda (buf)
              (string-append ";; chats — RET visit · m mark · s steer · "
                             "y/n permission · k flag kill · d flag archive · "
                             "x execute · u/U unmark · + new · g refresh"))
    'keys '(("RET" "agents-visit") ("s" "agents-steer") ("y" "agents-allow")
            ("n" "agents-deny")
            ("g" "agents-refresh") ("+" "agent-open") ("q" "quit-window"))
    ;; line movement remaps to move-and-preview (n is taken: deny)
    'remap '(("next-line" "agents-next") ("previous-line" "agents-prev"))))

(define-command "chat-list" "List every chat: agent threads and API companions"
  (lambda () (list-mode-show! "chats-mode")))

;;; --- attention: the erc-track segment -----------------------------------------

(define (agents-attention)
  (let loop ((ts (agent-threads)) (acc '()))
    (cond ((null? ts) (reverse acc))
          ((equal? (car (cdr (car ts))) 'needs_attention)
           (loop (cdr ts) (cons (car (car ts)) acc)))
          (else (loop (cdr ts) acc)))))

(define (agents-modeline-refresh!)
  (let ((att (agents-attention)))
    (set-modeline-extra!
      (if (null? att) "" (string-append "! " (string-join att " "))))))

(define-command "agent-goto-attention" "Jump to the first thread needing attention"
  (lambda ()
    (let ((att (agents-attention)))
      (if (null? att)
          (message "no agent needs attention")
          (begin (switch-to-buffer! (agent-buf (car att)))
                 (end-of-buffer!))))))

(global-set-key "C-c a n" "agent-open")
(global-set-key "C-c a l" "chat-list")
(global-set-key "C-c a a" "agent-goto-attention")
