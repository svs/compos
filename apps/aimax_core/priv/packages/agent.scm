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

(add-display-rule! "*agent" 'popup)

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

(define (agent-input slug)
  (let ((buf (agent-buffer slug)))
    (substring-bytes (buffer-text buf)
                     (agent-input-start slug)
                     (buffer-size buf))))

(define (agent-clear-input! slug)
  (let ((buf (agent-buffer slug))
        (start (agent-input-start slug)))
    (buffer-delete-range! buf start (- (buffer-size buf) start))))

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
       (agent-render! slug
         (string-append "\n╰─ you ▸ " (plist-get e 'text) "\n\n") "agent-you")
       (agent-show-waiting! slug))

      ((equal? type 'chunk)
       (agent-render! slug (plist-get e 'text) #f))

      ((equal? type 'thought)
       (agent-render! slug (plist-get e 'text) "agent-thought"))

      ((equal? type 'tool-call)
       (agent-render! slug
         (string-append "\n▸ " (plist-get e 'kind) " · " (plist-get e 'title) "\n")
         "agent-tool")
       ;; remember where this tool's body will start (= current mark)
       (buffer-set-local! buf 'agent-tool-bodies
         (cons (list (plist-get e 'id) (agent-mark slug))
               (or (buffer-local buf 'agent-tool-bodies) '()))))

      ((equal? type 'tool-update)
       (let ((text (plist-get e 'text)))
         (unless (equal? text "")
           (agent-render! slug text #f))
         (when (equal? (plist-get e 'status) "completed")
           (let ((entry (assoc (plist-get e 'id)
                               (or (buffer-local buf 'agent-tool-bodies) '()))))
             (when (and entry (> (agent-mark slug) (car (cdr entry))))
               (agent-add-fold! buf (car (cdr entry)) (agent-mark slug)))))))

      ((equal? type 'plan)
       (agent-render! slug
         (string-append "\n"
           (string-join
             (let loop ((es (plist-get e 'entries)) (acc '()))
               (if (null? es) (reverse acc)
                   (loop (cdr es)
                         (cons (string-append "  □ " (car (car es))) acc))))
             "\n")
           "\n")
         "agent-meta"))

      ((equal? type 'permission)
       (agent-render! slug
         (string-append "\n── needs permission: " (plist-get e 'title)
                        " ── C-c C-y allow · C-c C-n deny\n")
         "agent-permission")
       (message (string-append "agent " slug " needs permission: "
                               (plist-get e 'title))))

      ((equal? type 'turn-end)
       (message (string-append "agent " slug ": done")))

      ((equal? type 'error)
       (agent-render! slug
         (string-append "\n[error: " (plist-get e 'text) "]\n") "agent-meta"))

      ((equal? type 'dead)
       (agent-render! slug "\n[agent exited]\n" "agent-meta"))

      (else #f))))

(agent-on-event!
  (lambda (slug events)
    ;; batches race buffer kills — a dead thread's events just drop
    (when (buffer-exists? (agent-buffer slug))
      (for-each (lambda (e) (agent-handle-event slug e)) events))))

;;; --- permission answers -------------------------------------------------------

;; pick the first option whose kind matches, else the first option
(define (agent-answer-permission! slug allow?)
  (let ((info (agent-info slug)))
    (let ((perm (and info (plist-get info 'permission))))
      (if (not perm)
          (message "no pending permission")
          (let ((wanted (if allow? "allow" "reject"))
                (all (plist-get perm 'options)))
            (let loop ((os all))
              (cond ((null? os)
                     ;; no kind match — first option for allow, cancel for deny
                     (if (and allow? (not (null? all)))
                         (agent-permission-respond! slug (plist-get perm 'rpc-id)
                           (car (car all)))
                         (agent-permission-respond! slug (plist-get perm 'rpc-id) #f)))
                    ((string-prefix? wanted (car (cdr (cdr (car os)))))
                     (agent-permission-respond! slug (plist-get perm 'rpc-id)
                       (car (car os))))
                    (else (loop (cdr os))))))))))

(define-command "agent-permission-allow"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer)) #t)))

(define-command "agent-permission-deny"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer)) #f)))

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
    (agent-start! slug
      (append (list 'buffer buf 'mark mark)
              (agent-resolve-config
                (append (list 'connector (or (buffer-local buf 'agent-connector)
                                             *default-connector*))
                        (if (and m (not (equal? m "")))
                            (agent-model-env m)
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
              (minibuffer-read "Model (empty = connector default): " *llm-models*
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
                   (begin
                     (agent-clear-input! slug)
                     (if (equal? (agent-prompt! slug input) 'queued)
                         (message "queued — agent is mid-turn")
                         (message "sent"))
                     (end-of-buffer!)))))))))

(define-command "agent-interrupt-send"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (when slug
        (if (equal? (agent-status slug) 'dead)
            (message "agent exited — C-c a n starts a new thread")
            (begin
              (agent-cancel! slug)
              (let ((input (string-trim (agent-input slug))))
                (unless (equal? input "")
                  (agent-clear-input! slug)
                  (agent-prompt! slug input)))
              (message "interrupted")))))))

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

(define-connector! "claude-code" '(cmd "claude-code-acp"))
;; codex rides a ChatGPT subscription; needs the codex-acp adapter on PATH
(define-connector! "codex" '(cmd "codex-acp"))
;; direct API calls through the editor's own LLM plumbing (req_llm eventually):
;; no subprocess, no tools — the cheap chat lane
(define-connector! "llm" '(type llm))

;; CLAUDE_CODE_SUBAGENT_MODEL too: the adapter's bundled SDK defaults
;; subagents to a retired model id (404s) unless told otherwise
(define (agent-model-env m)
  (list 'env (list (list "ANTHROPIC_MODEL" m)
                   (list "CLAUDE_CODE_SUBAGENT_MODEL" m))))

;; per-call opts win over the connector; ANTHROPIC_MODEL defaults to the
;; editor's model when nothing else claims 'env and it is an anthropic model
(define (agent-resolve-config opts)
  (let ((conf (append opts (connector-config
                             (or (plist-get opts 'connector)
                                 *default-connector*)))))
    (if (or (plist-get conf 'env)
            (plist-get conf 'type)              ; llm threads need no env
            (string-contains? (llm-model) ":"))
        conf
        (append conf (agent-model-env (llm-model))))))

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
  (local-set-key* buf "C-c C-n" "agent-permission-deny"))

;; setup doubles as desktop-restore: keys, overlays, and folds all come
;; back from the persisted buffer-locals (the agent process itself does
;; not survive a restart — the transcript does, status reads 'dead)
(define (agent-mode-setup! buf)
  (buffer-set-local! buf 'mode-name "agent-mode")
  (buffer-set-local! buf 'modeline-info-command "agent-switch")
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
