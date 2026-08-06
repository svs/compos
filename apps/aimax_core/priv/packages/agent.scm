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
    start))

(define (agent-handle-event slug e)
  (let ((buf (agent-buffer slug))
        (type (plist-get e 'type)))
    (cond
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
    (for-each (lambda (e) (agent-handle-event slug e)) events)))

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

(define-command "agent-send"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (if (not slug)
          (message "not an agent buffer")
          (let ((input (string-trim (agent-input slug))))
            (if (equal? input "")
                (insert! "\n")
                (begin
                  (agent-clear-input! slug)
                  (if (equal? (agent-prompt! slug input) 'queued)
                      (message "queued — agent is mid-turn")
                      (message "sent"))
                  (end-of-buffer!))))))))

(define-command "agent-interrupt-send"
  (lambda ()
    (let ((slug (agent-slug-of (current-buffer))))
      (when slug
        (agent-cancel! slug)
        (let ((input (string-trim (agent-input slug))))
          (unless (equal? input "")
            (agent-clear-input! slug)
            (agent-prompt! slug input)))
        (message "interrupted")))))

;;; --- thread creation ----------------------------------------------------------

(define (agent-next-slug)
  (let loop ((n 1))
    (if (member (string-append "a" (number->string n)) (agent-list))
        (loop (+ n 1))
        (string-append "a" (number->string n)))))

(define (agent-install-keys! buf)
  (local-set-key* buf "RET" "agent-send")
  (local-set-key* buf "C-RET" "agent-interrupt-send")
  (local-set-key* buf "TAB" "agent-toggle-fold")
  (local-set-key* buf "C-c C-y" "agent-permission-allow")
  (local-set-key* buf "C-c C-n" "agent-permission-deny"))

;; (execute "task")                    — spawn a thread, hand it the task, show it
;; (execute* "task" '(cwd "/x"))       — extra config plist entries pass through
(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  (let ((slug (agent-next-slug)))
    (let ((buf (agent-buffer slug)))
      (buffer-create buf)
      (buffer-set-local! buf 'mode-name "Agent")
      (buffer-set-local! buf 'agent-slug slug)
      (buffer-append! buf (string-append ";; agent thread · " slug "\n"))
      (let ((mark (buffer-size buf)))
        (buffer-append! buf *agent-prompt-marker*)
        (agent-install-keys! buf)
        ;; agents default to the editor's model (until presets land); the
        ;; adapter honors ANTHROPIC_MODEL. Only when it IS an anthropic model
        ;; — (llm-model) may point at another provider. An 'env in opts wins.
        (agent-start! slug
          (append (list 'buffer buf 'mark mark)
                  (if (or (plist-get opts 'env)
                          (string-contains? (llm-model) ":"))
                      opts
                      (append (list 'env (list (list "ANTHROPIC_MODEL" (llm-model))))
                              opts))))
        (unless (equal? prompt "")
          (agent-prompt! slug prompt))
        (display-buffer buf)
        ;; popup selects the thread window — land point in the input region
        (when (equal? (current-buffer) buf)
          (end-of-buffer!))
        slug))))

(define-command "agent-open"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task) (execute task)))))

(global-set-key "C-c a n" "agent-open")
