;;; agent.scm — ACP thread machinery for chats. There is only chat: a
;;; thread is a chat buffer riding an ACP backend (chat-set-backend, or
;;; (execute "task") which spawns a fresh *chat:<slug>*). Steer by typing
;;; at the ╰─ you ▸ marker and RET (queued if the agent is mid-turn).
;;; C-RET interrupts. TAB folds/unfolds tool output. C-c C-y / C-c C-n
;;; answer permission requests. The Elixir side (Aimax.Core.Agent) is
;;; mechanism only: subprocess, framing, event batches.

;;; --- faces --------------------------------------------------------------------

(set-face-attribute! 'agent-tool 'fg "#7aa2f7")
(set-face-attribute! 'agent-thought 'fg "#787c99")
(set-face-attribute! 'agent-permission 'fg "#e0af68")
(set-face-attribute! 'agent-meta 'fg "#787c99")
(set-face-attribute! 'agent-queued 'fg "#565a6e")

;; threads are primary work surfaces, not popups — they take the full window
;; (the *chats* fleet list is the popup-weight surface)

;;; --- small helpers ------------------------------------------------------------

(define *agent-prompt-marker* "\n╰─ you ▸ ")

;; events/config are flat plists (no dotted pairs in this scheme)
(define (plist-get pl key)
  (let loop ((pl pl))
    (cond ((null? pl) #f)
          ((null? (cdr pl)) #f)
          ((equal? (car pl) key) (car (cdr pl)))
          (else (loop (cdr (cdr pl)))))))

(define (agent-buffer slug) (string-append "*agent: " slug "*"))

;; the buffer a thread renders into: any buffer claiming the slug — chats
;; host threads too (chat-set-backend) — else the conventional name above
(define (agent-buf slug)
  (let loop ((bs (buffer-list)))
    (cond ((null? bs) (agent-buffer slug))
          ((equal? (buffer-local (car bs) 'agent-slug) slug) (car bs))
          (else (loop (cdr bs))))))

(define (agent-slug-of buf) (buffer-local buf 'agent-slug))

;; input region: [.. transcript .. mark][marker][user input ..]
(define (agent-input-start slug)
  (+ (agent-mark slug) (string-byte-length *agent-prompt-marker*)))

;; messages steered mid-turn stay in the input region, muted, until their
;; turn starts — 'agent-queued holds their raw byte lengths, oldest first
(define (agent-queued-bytes buf)
  (let loop ((q (or (buffer-local buf 'agent-queued) '())) (n 0))
    (if (null? q) n (loop (cdr q) (+ n (car q))))))

;; the live (not-yet-queued) tail of the input region
(define (agent-input slug)
  (let ((buf (agent-buf slug)))
    (substring-bytes (buffer-text buf)
                     (+ (agent-input-start slug) (agent-queued-bytes buf))
                     (buffer-size buf))))

(define (agent-clear-input! slug)
  (let ((buf (agent-buf slug)))
    (let ((start (+ (agent-input-start slug) (agent-queued-bytes buf))))
      (buffer-delete-range! buf start (- (buffer-size buf) start)))))

;; mute the live tail instead of clearing it
(define (agent-mark-queued! slug)
  (let* ((buf (agent-buf slug))
         (start (+ (agent-input-start slug) (agent-queued-bytes buf)))
         (end (buffer-size buf)))
    (buffer-set-local! buf 'agent-queued
      (append (or (buffer-local buf 'agent-queued) '())
              (list (- end start))))
    (agent-add-overlay! buf start end "agent-queued")))

;; its turn started: the muted text leaves the input region (the rendered
;; ╰─ you ▸ line replaces it)
(define (agent-pop-queued! slug)
  (let* ((buf (agent-buf slug))
         (q (or (buffer-local buf 'agent-queued) '())))
    (unless (null? q)
      (buffer-delete-range! buf (agent-input-start slug) (car q))
      (buffer-set-local! buf 'agent-queued (cdr q)))))

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
  (buffer-set-hidden! buf
    (let loop ((fs (or (buffer-local buf 'agent-folds) '())) (acc '()))
      (cond ((null? fs) acc)
            ((car (cdr (cdr (car fs)))) (loop (cdr fs) acc)) ; open — not hidden
            (else (loop (cdr fs)
                        (cons (list (car (car fs)) (car (cdr (car fs)))) acc)))))))

(define (agent-add-fold! buf s e)
  (buffer-set-local! buf 'agent-folds
    (cons (list s e #f) (or (buffer-local buf 'agent-folds) '())))
  (agent-apply-folds! buf))

(define-command "agent-toggle-fold" "Toggle the transcript fold at or around point"
  (lambda ()
    (let ((buf (current-buffer)) (p (point)))
      (let loop ((fs (or (buffer-local buf 'agent-folds) '())) (acc '()) (hit #f))
        (cond ((null? fs)
               (if hit
                   (begin (buffer-set-local! buf 'agent-folds (reverse acc))
                          (agent-apply-folds! buf))
                   (message "no fold here")))
              ;; hit when point is on the header line just above, or inside
              ((and (not hit)
                    (>= p (- (car (car fs)) 120))
                    (< p (car (cdr (car fs)))))
               (let ((f (car fs)))
                 (loop (cdr fs)
                       (cons (list (car f) (car (cdr f)) (not (car (cdr (cdr f))))) acc)
                       #t)))
              (else (loop (cdr fs) (cons (car fs) acc) hit)))))))

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

(define (nth n l) (if (= n 0) (car l) (nth (- n 1) (cdr l))))

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

;;; --- rendering ----------------------------------------------------------------

;; face #f -> plain text
(define (agent-render! slug text face)
  (let ((buf (agent-buf slug))
        (start (agent-mark slug)))
    (agent-append! slug text)
    (when face
      (agent-add-overlay! buf start (+ start (string-byte-length text)) face))
    ;; persisted with the buffer — how a restored thread finds its mark
    (buffer-set-local! buf 'agent-saved-mark (agent-mark slug))
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
      (buffer-delete-range! buf (car w) (- (car (cdr w)) (car w)))
      (agent-block-drop-kind! buf "waiting")
      (buffer-set-local! buf 'agent-waiting #f)
      (buffer-set-local! buf 'agent-saved-mark (agent-mark slug)))))

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
       (agent-pop-queued! slug)
       ;; 'chat-turns is the conversation truth on EVERY backend: the api
       ;; lane replays it per request, ACP seeds a fresh session from it,
       ;; and both flatten it to .chat files
       (chat-turn-push! buf "user" (plist-get e 'text))
       (let ((start (agent-render! slug
                      (string-append "\n╰─ you ▸ " (plist-get e 'text) "\n\n")
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
       (let ((start (agent-render! slug
                      (string-append "\n▸ " (plist-get e 'kind) " · "
                                     (plist-get e 'title) "\n")
                      "agent-tool")))
         (agent-block-push! buf start (agent-mark slug) "tool"
           (list (plist-get e 'id) (plist-get e 'title) (plist-get e 'kind)
                 "running" (agent-mark slug))))
       ;; remember where this tool's body will start (= current mark)
       (buffer-set-local! buf 'agent-tool-bodies
         (cons (list (plist-get e 'id) (agent-mark slug))
               (or (buffer-local buf 'agent-tool-bodies) '()))))

      ((equal? type 'tool-update)
       (let ((text (plist-get e 'text)))
         (unless (equal? text "")
           (agent-render! slug text #f))
         (when (equal? (plist-get e 'status) "completed")
           (agent-block-close-tool! buf (plist-get e 'id)
             (agent-mark slug) "done")
           (let ((entry (assoc (plist-get e 'id)
                               (or (buffer-local buf 'agent-tool-bodies) '()))))
             (when (and entry (> (agent-mark slug) (car (cdr entry))))
               (agent-add-fold! buf (car (cdr entry)) (agent-mark slug)))))))

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
            (chat-turn-push! buf "assistant" text))
           ;; a completed turn that rendered NOTHING at all would look like
           ;; the send vanished — say so. (A turn that ran tools, was
           ;; cancelled, or errored already left its own trace.)
           ((and (equal? (plist-get e 'stop-reason) "end_turn")
                 (not (buffer-local buf 'agent-turn-any)))
            (let ((start (agent-render! slug
                           "(no reply — the model returned no text)\n"
                           "agent-meta")))
              (agent-block-push! buf start (agent-mark slug) "meta" '())))
           (else #f)))
       (buffer-set-local! buf 'agent-turn-text #f)
       (buffer-set-local! buf 'agent-turn-any #f)
       (agent-block-drop-kind! buf "permission")
       (message (string-append "agent " slug ": done")))

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

(agent-on-event!
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

(define (chat-permission-mode buf)
  (or (buffer-local buf 'chat-permission-mode) *permission-default-mode*))

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

;; The one policy. Override wholesale in ~/.aimax/init.scm:
;;   (set! *permission-policy* (lambda (buf title kind raw) 'allow))
;; -> 'allow | 'allow-always | 'ask | 'reject
(define *permission-policy*
  (lambda (buf title kind raw)
    (cond ((permission-denied-verb?
             (string-append (or title "") " " (or kind "") " " (or raw "")))
           'ask)
          ((equal? (chat-permission-mode buf) 'ask) 'ask)
          (else 'allow-always))))

;; the direct lane's gate (Backend.ReqLLM calls this before every tool):
;; collapse to the three verdicts Elixir understands
(agent-permission-fn!
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
      (when (agent-set-mode! slug want)
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
                    (if (agent-set-mode! slug m)
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

;; a restored (or crashed) thread is a live transcript with a dead runtime —
;; reattach a fresh agent on its connector. New ACP session: the transcript
;; stays; server-side context isn't replayed yet (resume lands with P5).
(define (agent-revive! slug)
  (let* ((buf (agent-buf slug))
         (mark (or (buffer-local buf 'agent-saved-mark)
                   ;; older transcript: mark sits at the marker's last occurrence
                   (let loop ((ms (re-find* *agent-prompt-marker* (buffer-text buf)))
                              (last (buffer-size buf)))
                     (if (null? ms) last (loop (cdr ms) (car (car ms)))))))
         (cname (or (buffer-local buf 'agent-connector) *default-connector*))
         ;; a model left over from ANOTHER connector is worse than none:
         ;; the adapter silently ignores it and runs its default while the
         ;; modeline repeats the stale name. Foreign -> connector default.
         (m (let ((m0 (buffer-local buf 'agent-model))
                  ;; legit ids: the connector's declared list plus what
                  ;; the adapter itself reported for this session
                  (declared (append (connector-models cname)
                                    (map car (or (buffer-local buf 'agent-models)
                                                 '())))))
              (if (and m0 (pair? declared) (not (member m0 declared)))
                  (begin
                    (buffer-set-local! buf 'agent-model #f)
                    (agent-update-modeline! buf)
                    (message (string-append m0 " isn't a " cname
                                            " model — using its default"))
                    #f)
                  m0))))
    (buffer-set-local! buf 'agent-queued '())
    ;; seed only when there IS a conversation — a fresh surface's meta
    ;; card alone is chrome, not context. The api lane never seeds: its
    ;; turns are replayed in full on every request anyway.
    (when (and (not (connector-api? cname))
               (> mark 0)
               (not (equal? (string-trim (agent-seed-transcript buf)) "")))
      (buffer-set-local! buf 'agent-seed-context #t))
    (agent-start! slug
      (append (list 'buffer buf 'mark mark)
              (agent-resolve-config
                (append (list 'connector (or (buffer-local buf 'agent-connector)
                                             *default-connector*))
                        (if (and m (not (equal? m "")))
                            (list 'model m)
                            '())
                        ;; agent-backed chats keep their preset MCP servers
                        ;; across revives
                        (let ((ps (buffer-local buf 'chat-presets)))
                          (if ps (list 'presets ps) '()))))))
    (message (string-append "agent " slug ": revived (fresh session)"))))

;; switch a thread's connector/model: kill + reattach. Fresh session — the
;; transcript stays, server-side context doesn't.
(define (agent-reconnect! slug cname model)
  (let ((buf (agent-buf slug)))
    (agent-kill! slug)
    (buffer-set-local! buf 'agent-connector cname)
    (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
    (agent-update-modeline! buf)
    (agent-revive! slug)))

(define-command "agent-switch" "Reattach this thread to a new connector and model"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (if (not slug)
          (message "not an agent buffer")
          (minibuffer-read "Connector: " (connector-names)
            (lambda (cname)
              (minibuffer-read "Model (empty = connector default): "
                (connector-models cname)
                (lambda (model)
                  (agent-reconnect! slug cname model)))))))))

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
;; files): chat-turns when the chat has them, block text minus chrome for
;; legacy buffers. No cap, no tail games — switching models sends the chat.
(define (agent-seed-transcript buf)
  (or (chat-flatten buf) (agent-conversation-text buf)))

;; the wire text may carry chrome (editor context, seed transcript) the
;; user never typed — the raw input rides along as the DISPLAY text: it is
;; what the transcript renders and what 'chat-turns records as the turn
(define (agent-send-msg! slug raw)
  (let* ((buf (agent-buf slug))
         ;; what the user is looking at in the other windows — "this" works
         (msg (string-append (editor-context-preamble buf) raw)))
    (if (buffer-local buf 'agent-seed-context)
        (begin
          (buffer-set-local! buf 'agent-seed-context #f)
          (agent-prompt! slug
            (string-append
              "Context: this continues an earlier conversation from the"
              " user's editor (possibly with a different model). The"
              " conversation so far:\n\n" (agent-seed-transcript buf)
              "\n\nContinue naturally from there. New message:\n" msg)
            raw))
        (agent-prompt! slug msg raw))))

(define-command "agent-send" "Send the input to the agent, reviving it if dead"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; a chat without a runtime gets one on first send — the api
           ;; backend by default; RET is agent-send on EVERY chat
           (slug (or (agent-slug-of buf)
                     (and (equal? (buffer-local buf 'mode-name) "chat-mode")
                          (buffer-local buf 'agent-saved-mark)
                          (chat-attach-agent! buf "api")))))
      (cond ((not slug) (message "not an agent buffer"))
            (else
             ;; a preset changed under a live ACP session: its tool list is
             ;; fixed at session/new, so reattach before sending
             (when (boundp (quote chat-apply-pending-presets!))
               (chat-apply-pending-presets! buf))
             (when (equal? (agent-status slug) 'dead)
               (agent-revive! slug))
             (let ((input (string-trim (agent-input slug))))
               (if (equal? input "")
                   (insert! "\n")
                   (if (equal? (agent-send-msg! slug input) 'queued)
                       ;; mid-turn: the text stays put, muted, until its turn
                       (begin
                         (agent-mark-queued! slug)
                         (end-of-buffer!)
                         (message "queued — runs when this turn ends"))
                       (begin
                         (agent-clear-input! slug)
                         (end-of-buffer!)
                         (message "sent"))))))))))

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
               (agent-cancel! slug)
               (message "cancel requested — C-RET again forces a restart")))))))

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
;; _meta.claudeCode.options over its own defaults, so settingSources ()
;; makes the adapter load NO user-level config: aimax's mcpServers and
;; aimax's permission answers become the only sources. (Verified against
;; @zed-industries/claude-code-acp 0.16.2: options = {...defaults,
;; ...userProvidedOptions, ...ACP-controlled fields}.)
(define-connector! "claude-code"
  '(cmd "claude-code-acp"
    meta (claudeCode (options (settingSources ())))
    models ("claude-sonnet-5" "claude-opus-5" "claude-haiku-4-5-20251001")))
;; codex rides a ChatGPT subscription (auth from `codex login`). Models are
;; what the bundled codex core recognizes; the thread's model is passed as a
;; config override on the adapter's command line ('model-flag).
(define-connector! "codex"
  '(cmd "codex-acp" model-flag "-c model="
    models ("gpt-5.6-luna" "gpt-5.5" "gpt-5.5-pro" "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex")))
;; the direct-API lane: in-process req_llm turns — streaming, tools, cost
;; tracking, no subprocess. "api" is just another connector.
(define-connector! "api" '(backend "req-llm"))

(define (connector-api? name)
  (equal? (plist-get (connector-config name) 'backend) "req-llm"))

;; what the switch prompt offers: the connector's declared 'models; the api
;; lane can use anything the llm wire routes (*llm-models*)
(define (connector-models name)
  (let ((conf (connector-config name)))
    (or (plist-get conf 'models)
        (if (connector-api? name) *llm-models* '()))))

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
    ;; ACP threads get MCP servers: the editor's own tools (aimax proxy)
    ;; plus whatever presets the caller names — the caller controls the
    ;; agent's tool surface, exactly as with API chats. The direct lane
    ;; needs none: its tool surface is read fresh at every send.
    (if (or (equal? (plist-get conf 'backend) "req-llm")
            (plist-get conf 'mcp-servers)
            (not (boundp (quote presets-acp-servers))))
        conf
        (append conf
          (list 'mcp-servers
                (presets-acp-servers (or (plist-get conf 'presets) '())))))))

(define (agent-resolve-config* opts)
  (let* ((cname (or (plist-get opts 'connector) *default-connector*))
         (conf (append opts (connector-config cname)))
         (m (or (plist-get conf 'model)
                (and (member (llm-model) (connector-models cname)) (llm-model)))))
    (cond ((not m) conf)
          ((equal? (plist-get conf 'backend) "req-llm")
           ;; in-process: the model is config, not wiring
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
    (if (null? cs) (reverse acc) (loop (cdr cs) (cons (car (car cs)) acc)))))

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
         (m (or (buffer-local buf 'agent-model)
                (and (connector-api? c) (llm-model))))
         (cost (and (connector-api? c) (buffer-local buf 'chat-cost))))
    (buffer-set-local! buf 'modeline-info
      (string-append c
        (if (and m (not (equal? m ""))) (string-append " · " m) "")
        (if cost (string-append " · " (format-usd cost)) "")
        ;; what will and won't stop to ask — never leave this ambiguous
        " · " (symbol->string (chat-permission-mode buf))
        ;; the agent's own mode, when it is running something other than
        ;; its default (plan mode especially changes what a turn DOES)
        (let ((am (buffer-local buf 'agent-mode)))
          (if (and am (not (equal? am "default"))) (string-append " · " am) ""))))))

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
  (local-set-key* buf "TAB" "agent-toggle-fold")
  (local-set-key* buf "C-c C-y" "agent-permission-allow")
  (local-set-key* buf "C-c C-a" "agent-permission-always")
  (local-set-key* buf "C-c C-n" "agent-permission-deny")
  (local-set-key* buf "C-c p" "chat-set-permission-mode")
  (local-set-key* buf "C-c C-v" "agent-toggle-view"))

(define-command "agent-toggle-view" "Toggle rich and plain transcript rendering"
  (lambda ()
    (let ((buf (current-buffer)))
      (when (agent-slug-of buf)
        (let ((rich? (equal? (buffer-local buf 'render-mode) "agent")))
          (buffer-set-local! buf 'render-mode (if rich? #f "agent"))
          (message (if rich? "plain transcript" "rich transcript")))))))


;; legacy: pre-unification *agent:* buffers restore straight into
;; chat-mode — there is only chat, riding ACP or the API. chat-mode's
;; setup rebuilds keys, overlays, and folds from the persisted locals.
(define-mode "agent-mode" (lambda () (set-mode! "chat-mode")))

;; (execute "task")                         — spawn a task chat on the default connector
;; (execute* "task" '(connector "codex"))   — pick a connector / pin a model
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
      (agent-prompt! slug prompt))
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

;; every thread the editor knows: (slug status) — status from the runtime
;; when alive, 'dead for restored transcripts
(define (agent-threads)
  (let loop ((bs (buffer-list)) (acc '()))
    (cond ((null? bs) (reverse acc))
          ;; any buffer claiming a slug is a thread — chats included
          ((buffer-local (car bs) 'agent-slug)
           (loop (cdr bs)
                 (cons (list (buffer-local (car bs) 'agent-slug)
                             (agent-status (buffer-local (car bs) 'agent-slug)))
                       acc)))
          (else (loop (cdr bs) acc)))))

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
    (let* ((buf *agents-buffer*)
           (bs (agents-sorted))
           ;; a rewrite dumps point to 0 — keep the reader's place (dired)
           (cur? (equal? (current-buffer) buf))
           (p (if cur? (point) 0)))
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-append! buf
        (string-append ";; chats — RET visit · s steer · y/n permission · "
                       "k kill · x archive · + new · g refresh\n"))
      (buffer-set-local! buf 'agents-bufs
        (let loop ((bs bs) (acc '()))
          (if (null? bs) (reverse acc)
              (begin (buffer-append! buf (string-append (agents-line (car bs)) "\n"))
                     (loop (cdr bs) (cons (car bs) acc))))))
      (when cur? (goto-char! (min p (buffer-size buf)))))))

;; chat buffer on the current line: line 0 is the header, entries follow
;; in the order 'agents-bufs recorded
(define (agents-current-buf)
  (let* ((bufs (or (buffer-local *agents-buffer* 'agents-bufs) '()))
         (before (substring-bytes (buffer-text *agents-buffer*) 0 (point)))
         (ln (- (length (string-split before "\n")) 2)))
    (if (and (>= ln 0) (< ln (length bufs))) (nth ln bufs) #f)))

;; the slug on the current line, #f on an API-chat row
(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

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

(define-command "agents-steer" "Send a steering message to the thread at point"
  (lambda ()
    (let ((slug (agents-current-slug)))
      (if (not slug)
          (message "not an agent-backed chat")
          (minibuffer-read (string-append "Steer " slug ": ") '()
            (lambda (msg)
              (unless (equal? msg "")
                (when (equal? (agent-status slug) 'dead) (agent-revive! slug))
                (agent-send-msg! slug msg)
                (agents-refresh!))))))))

(define-command "agents-allow" "Allow the pending permission for the thread at point"
  (lambda ()
    (let ((slug (agents-current-slug)))
      (when slug (agent-answer-permission! slug "allow_once" "allow")
                 (agents-refresh!)))))

(define-command "agents-deny" "Deny the pending permission for the thread at point"
  (lambda ()
    (let ((slug (agents-current-slug)))
      (when slug (agent-answer-permission! slug "reject_once" "reject")
                 (agents-refresh!)))))

;; mark the transcript BEFORE the runtime dies (the mark primitive needs it
;; alive) so windows showing the thread refresh honestly
(define (agent-note-stopped! slug)
  (unless (equal? (agent-status slug) 'dead)
    (let ((buf (agent-buf slug)))
      (agent-clear-waiting! slug)
      (agent-block-drop-kind! buf "permission")
      (let ((start (agent-render! slug "\n[agent stopped]\n" "agent-meta")))
        (agent-block-push! buf start (agent-mark slug) "meta" '())))))

;; point any window showing BUF somewhere else (interactive kill-buffer's
;; dance) — killing a displayed buffer leaves a ghost that resurrects empty
(define (agent-release-windows! buf)
  (for-each
    (lambda (w)
      (when (equal? (car (cdr w)) buf)
        (select-window! (car w))
        (let ((others (filter (lambda (b) (and (not (equal? b buf))
                                               (not (string-prefix? "*agent" b))))
                              (buffer-list-mru))))
          (switch-to-buffer! (if (null? others) "*scratch*" (car others))))))
    (window-list)))

(define-command "agents-kill" "Kill the thread at point, keeping its transcript"
  (lambda ()
    (let ((slug (agents-current-slug)))
      (if (not slug)
          (message "not an agent-backed chat (x drops the buffer)")
          (begin
            (agent-note-stopped! slug)
            (agent-kill! slug)
            (agents-refresh!)
            (message (string-append slug " killed (transcript kept)")))))))

;; archive: runtime (if any) + buffer both go (desktop stops restoring it)
(define-command "agents-archive" "Kill the chat at point and drop its buffer"
  (lambda ()
    (let ((b (agents-current-buf)))
      (when b
        (let ((here (active-window))
              (slug (buffer-local b 'agent-slug)))
          (when slug (agent-kill! slug))
          (agent-release-windows! b)
          (buffer-kill! b)
          (when (window-exists? here) (select-window! here))
          (agents-refresh!)
          (message (string-append b " archived")))))))

(define-command "agents-refresh" "Refresh the chat list"
  (lambda () (agents-refresh!)))

(define-command "chat-list" "List every chat: agent threads and API companions"
  (lambda ()
    (buffer-create *agents-buffer*)
    (buffer-set-local! *agents-buffer* 'mode-name "Chats")
    (local-set-key* *agents-buffer* "RET" "agents-visit")
    ;; line movement remaps to move-and-preview (n is taken: deny)
    (local-remap*! *agents-buffer* "next-line" "agents-next")
    (local-remap*! *agents-buffer* "previous-line" "agents-prev")
    (local-set-key* *agents-buffer* "s" "agents-steer")
    (local-set-key* *agents-buffer* "y" "agents-allow")
    (local-set-key* *agents-buffer* "n" "agents-deny")
    (local-set-key* *agents-buffer* "k" "agents-kill")
    (local-set-key* *agents-buffer* "x" "agents-archive")
    (local-set-key* *agents-buffer* "g" "agents-refresh")
    (local-set-key* *agents-buffer* "+" "agent-open")
    (local-set-key* *agents-buffer* "q" "quit-window")
    (buffer-set-read-only! *agents-buffer* #t)
    (agents-refresh!)
    (display-buffer *agents-buffer*)))

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
