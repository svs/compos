;;; agent.scm — agent threads. A thread is a buffer; no sidebars.
;;;
;;; (execute "task") is the API — spawns an ACP agent (Claude Code et al.)
;;; whose transcript streams into *agent: <slug>*. Steer by typing at the
;;; ╰─ you ▸ marker and RET (queued if the agent is mid-turn). C-RET
;;; interrupts. TAB folds/unfolds tool output. C-c C-y / C-c C-n answer
;;; permission requests. The Elixir side (Aimax.Core.Agent) is mechanism
;;; only: subprocess, framing, event batches. Everything visible lives here.

;;; --- faces --------------------------------------------------------------------

(set-face-attribute! 'agent-tool 'fg "#7aa2f7")
(set-face-attribute! 'agent-thought 'fg "#787c99")
(set-face-attribute! 'agent-permission 'fg "#e0af68")
(set-face-attribute! 'agent-meta 'fg "#787c99")
(set-face-attribute! 'agent-queued 'fg "#565a6e")

;; threads are primary work surfaces, not popups — they take the full window
;; (the *agents* fleet list, when it lands, is the popup-weight surface)

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
  (let ((buf (agent-buffer slug)))
    (substring-bytes (buffer-text buf)
                     (+ (agent-input-start slug) (agent-queued-bytes buf))
                     (buffer-size buf))))

(define (agent-clear-input! slug)
  (let ((buf (agent-buffer slug)))
    (let ((start (+ (agent-input-start slug) (agent-queued-bytes buf))))
      (buffer-delete-range! buf start (- (buffer-size buf) start)))))

;; mute the live tail instead of clearing it
(define (agent-mark-queued! slug)
  (let* ((buf (agent-buffer slug))
         (start (+ (agent-input-start slug) (agent-queued-bytes buf)))
         (end (buffer-size buf)))
    (buffer-set-local! buf 'agent-queued
      (append (or (buffer-local buf 'agent-queued) '())
              (list (- end start))))
    (agent-add-overlay! buf start end "agent-queued")))

;; its turn started: the muted text leaves the input region (the rendered
;; ╰─ you ▸ line replaces it)
(define (agent-pop-queued! slug)
  (let* ((buf (agent-buffer slug))
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

(define-command "agent-toggle-fold"
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
  (let ((buf (agent-buffer slug))
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
  (let* ((buf (agent-buffer slug))
         (text "⋯ thinking\n")
         (start (agent-render! slug text "agent-thought")))
    (buffer-set-local! buf 'agent-waiting
      (list start (+ start (string-byte-length text))))))

(define (agent-clear-waiting! slug)
  (let* ((buf (agent-buffer slug))
         (w (buffer-local buf 'agent-waiting)))
    (when w
      (buffer-delete-range! buf (car w) (- (car (cdr w)) (car w)))
      (agent-block-drop-kind! buf "waiting")
      (buffer-set-local! buf 'agent-waiting #f)
      (buffer-set-local! buf 'agent-saved-mark (agent-mark slug)))))

(define (agent-handle-event slug e)
  (let ((buf (agent-buffer slug))
        (type (plist-get e 'type)))
    ;; any sign of life ends the waiting state
    (unless (or (equal? type 'user-msg) (equal? type 'status))
      (agent-clear-waiting! slug))
    (cond
      ((equal? type 'user-msg)
       (agent-pop-queued! slug)
       (let ((start (agent-render! slug
                      (string-append "\n╰─ you ▸ " (plist-get e 'text) "\n\n")
                      "agent-you")))
         (agent-block-push! buf start (agent-mark slug) "user"
           (list (plist-get e 'text))))
       (agent-show-waiting! slug))

      ((equal? type 'chunk)
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

      ((equal? type 'permission)
       (let ((start (agent-render! slug
                      (string-append "\n── needs permission: " (plist-get e 'title)
                                     " ── C-c C-y allow · C-c C-n deny\n")
                      "agent-permission")))
         (agent-block-push! buf start (agent-mark slug) "permission"
           (list (plist-get e 'title))))
       (message (string-append "agent " slug " needs permission: "
                               (plist-get e 'title))))

      ((equal? type 'turn-end)
       (buffer-set-local! buf 'agent-cancelling #f)
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
    (when (buffer-exists? (agent-buffer slug))
      (for-each (lambda (e) (agent-handle-event slug e)) events))))

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

;; want: "allow_once" | "allow_always" | "reject_once"; no match -> cancel
(define (agent-answer-permission! slug exact prefix)
  (let ((info (agent-info slug)))
    (let ((perm (and info (plist-get info 'permission))))
      (if (not perm)
          (message "no pending permission")
          (let ((opt (agent-perm-option (plist-get perm 'options) exact prefix)))
            (agent-permission-respond! slug (plist-get perm 'rpc-id)
              (if opt (car opt) #f)))))))

(define-command "agent-permission-allow"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_once" "allow")))

;; allow this AND stop asking for this tool (ACP allow_always)
(define-command "agent-permission-always"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_always" "allow")))

(define-command "agent-permission-deny"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "reject_once" "reject")))

;;; --- steering -----------------------------------------------------------------

;; a restored (or crashed) thread is a live transcript with a dead runtime —
;; reattach a fresh agent on its connector. New ACP session: the transcript
;; stays; server-side context isn't replayed yet (resume lands with P5).
(define (agent-revive! slug)
  (let* ((buf (agent-buffer slug))
         (mark (or (buffer-local buf 'agent-saved-mark)
                   ;; older transcript: mark sits at the marker's last occurrence
                   (let loop ((ms (re-find* *agent-prompt-marker* (buffer-text buf)))
                              (last (buffer-size buf)))
                     (if (null? ms) last (loop (cdr ms) (car (car ms)))))))
         (m (buffer-local buf 'agent-model)))
    (buffer-set-local! buf 'agent-queued '())
    (agent-start! slug
      (append (list 'buffer buf 'mark mark)
              (agent-resolve-config
                (append (list 'connector (or (buffer-local buf 'agent-connector)
                                             *default-connector*))
                        (if (and m (not (equal? m "")))
                            (list 'model m)
                            '())))))
    (message (string-append "agent " slug ": revived (fresh session)"))))

;; switch a thread's connector/model: kill + reattach. Fresh session — the
;; transcript stays, server-side context doesn't.
(define (agent-reconnect! slug cname model)
  (let ((buf (agent-buffer slug)))
    (agent-kill! slug)
    (buffer-set-local! buf 'agent-connector cname)
    (buffer-set-local! buf 'agent-model (if (equal? model "") #f model))
    (agent-update-modeline! buf)
    (agent-revive! slug)))

(define-command "agent-switch"
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

(define-command "agent-send"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (cond ((not slug) (message "not an agent buffer"))
            (else
             (when (equal? (agent-status slug) 'dead)
               (agent-revive! slug))
             (let ((input (string-trim (agent-input slug))))
               (if (equal? input "")
                   (insert! "\n")
                   (if (equal? (agent-prompt! slug input) 'queued)
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
(define-command "agent-interrupt-send"
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
;;; A connector is a named config plist for a thread's backend: 'cmd (the ACP
;;; adapter), 'env (auth/model context), 'cwd, 'mcp-servers. The point is
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

(define-connector! "claude-code"
  '(cmd "claude-code-acp"
    models ("claude-sonnet-5" "claude-opus-5" "claude-haiku-4-5-20251001")))
;; codex rides a ChatGPT subscription (auth from `codex login`). Models are
;; what the bundled codex core recognizes; the thread's model is passed as a
;; config override on the adapter's command line ('model-flag).
(define-connector! "codex"
  '(cmd "codex-acp" model-flag "-c model="
    models ("gpt-5.5" "gpt-5.5-pro" "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex")))
;; direct API calls through the editor's own LLM plumbing (req_llm eventually):
;; no subprocess, no tools — the cheap chat lane
(define-connector! "llm" '(type llm))

;; what the switch prompt offers: the connector's declared 'models; llm
;; threads can use anything the llm primitive routes (*llm-models*)
(define (connector-models name)
  (let ((conf (connector-config name)))
    (or (plist-get conf 'models)
        (if (equal? (plist-get conf 'type) 'llm) *llm-models* '()))))

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
  (let* ((cname (or (plist-get opts 'connector) *default-connector*))
         (conf (append opts (connector-config cname)))
         (m (or (plist-get conf 'model)
                (and (member (llm-model) (connector-models cname)) (llm-model)))))
    (cond ((plist-get conf 'type) conf)          ; in-process: nothing to wire
          ((not m) conf)
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

;; modeline: "connector · model" — the thread's economic identity; click it
;; to switch (modeline-info-command -> agent-switch)
(define (agent-update-modeline! buf)
  (let ((c (or (buffer-local buf 'agent-connector) *default-connector*))
        (m (buffer-local buf 'agent-model)))
    (buffer-set-local! buf 'modeline-info
      (if (and m (not (equal? m ""))) (string-append c " · " m) c))))

;;; --- thread creation ----------------------------------------------------------

;; skip live runtimes AND existing thread buffers — restored transcripts
;; keep their slug even though no agent is attached yet
(define (agent-next-slug)
  (let loop ((n 1))
    (let ((slug (string-append "a" (number->string n))))
      (if (or (member slug (agent-list))
              (buffer-exists? (agent-buffer slug)))
          (loop (+ n 1))
          slug))))

(define (agent-install-keys! buf)
  (local-set-key* buf "RET" "agent-send")
  (local-set-key* buf "C-RET" "agent-interrupt-send")
  (local-set-key* buf "TAB" "agent-toggle-fold")
  (local-set-key* buf "C-c C-y" "agent-permission-allow")
  (local-set-key* buf "C-c C-a" "agent-permission-always")
  (local-set-key* buf "C-c C-n" "agent-permission-deny")
  (local-set-key* buf "C-c C-r" "agent-rename")
  (local-set-key* buf "C-c C-v" "agent-toggle-view"))

(define-command "agent-toggle-view"
  (lambda ()
    (let ((buf (current-buffer)))
      (when (agent-slug-of buf)
        (let ((rich? (equal? (buffer-local buf 'render-mode) "agent")))
          (buffer-set-local! buf 'render-mode (if rich? #f "agent"))
          (message (if rich? "plain transcript" "rich transcript")))))))

;; rename = new buffer carrying the transcript + thread identity; the
;; runtime (registered by slug) restarts under the new name if it was alive
(define (agent-do-rename! old new)
  (let ((obuf (agent-buffer old))
        (nbuf (agent-buffer new))
        (alive (not (equal? (agent-status old) 'dead))))
    (agent-kill! old)
    (buffer-create nbuf)
    (buffer-append! nbuf (buffer-text obuf))
    (for-each
      (lambda (k) (buffer-set-local! nbuf k (buffer-local obuf k)))
      '(agent-connector agent-model agent-saved-mark agent-folds agent-overlays))
    (buffer-set-local! nbuf 'agent-slug new)
    (switch-to-buffer! nbuf)
    (buffer-kill! obuf)
    (agent-mode-setup! nbuf)
    (when alive (agent-revive! new))
    (message (string-append "thread renamed: " old " -> " new))))

(define-command "agent-rename"
  (lambda ()
    (let ((old (agent-slug-of (current-buffer))))
      (if (not old)
          (message "not an agent buffer")
          (minibuffer-read (string-append "Rename thread " old " to: ") '()
            (lambda (new)
              (cond ((equal? new "") (message "rename cancelled"))
                    ((buffer-exists? (agent-buffer new)) (message "name taken"))
                    (else (agent-do-rename! old new)))))))))

;; setup doubles as desktop-restore: keys, overlays, and folds all come
;; back from the persisted buffer-locals (the agent process itself does
;; not survive a restart — the transcript does, status reads 'dead)
(define (agent-mode-setup! buf)
  (buffer-set-local! buf 'mode-name "agent-mode")
  (buffer-set-local! buf 'modeline-info-command "agent-switch")
  ;; rich transcript by default; C-c C-v drops to the plain text view
  (buffer-set-local! buf 'render-mode "agent")
  (buffer-set-local! buf 'agent-marker-bytes
    (string-byte-length *agent-prompt-marker*))
  ;; derive the modeline from whatever locals survived — buffers saved
  ;; before this feature existed have none
  (agent-update-modeline! buf)
  ;; a restored thread has no live runtime: pending banners are stale by
  ;; definition
  (agent-block-drop-kind! buf "permission")
  (agent-block-drop-kind! buf "waiting")
  (agent-install-keys! buf)
  (let ((ovs (buffer-local buf 'agent-overlays)))
    (when ovs (overlay-set! buf 'agent ovs)))
  (agent-apply-folds! buf))

(define-mode "agent-mode" (lambda () (agent-mode-setup! (current-buffer))))

;; (execute "task")                         — spawn a thread on the default connector
;; (execute* "task" '(connector "codex"))   — pick a connector; other config
;;                                            plist entries override it
(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  (let ((slug (agent-next-slug)))
    (let ((buf (agent-buffer slug)))
      (buffer-create buf)
      (buffer-set-local! buf 'agent-slug slug)
      (let ((conf (agent-resolve-config opts)))
        (buffer-set-local! buf 'agent-connector
          (or (plist-get opts 'connector) *default-connector*))
        (buffer-set-local! buf 'agent-model
          (or (agent-conf-model conf)
              ;; llm threads ride the editor's model — show it
              (and (equal? (plist-get conf 'type) 'llm) (llm-model))))
        (agent-update-modeline! buf)
        (buffer-append! buf (string-append ";; agent thread · " slug "\n"))
        (let ((mark (buffer-size buf)))
          (buffer-append! buf *agent-prompt-marker*)
          (agent-mode-setup! buf)
          (agent-start! slug
            (append (list 'buffer buf 'mark mark) conf))
          (unless (equal? prompt "")
            (agent-prompt! slug prompt))
          (display-buffer buf)
          ;; popup selects the thread window — land point in the input region
          (when (equal? (current-buffer) buf)
            (end-of-buffer!))
          slug)))))

(define-command "agent-open"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task) (execute task)))))

(global-set-key "C-c a n" "agent-open")
