;;; agent-fleet.scm --- Chat fleet list, archive, and attention UI.
;;;
;;; This module owns the *chats* list and actions across chat buffers. Runtime
;;; lifecycle and transcript rendering remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(define *agents-buffer* "*chats*")

(add-display-rule! *agents-buffer* 'popup)

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

(category! 'chat)

(effects! '(read))

(defcustom 'chats-archived-limit 15
  "How many saved chats the *chats* list shows below the live ones."
  'group 'chat 'type 'integer)

(define (chats-live-log-paths)
  (let loop ((bs (chat-list-bufs)) (acc '()))
    (if (null? bs)
        acc
        (let ((id (buffer-local (car bs) 'chat-log-id)))
          (loop (cdr bs)
                (if id
                    (cons (string-append (chat-log-dir) "/" id ".chat") acc)
                    acc))))))

(define (chats-archived-rows)
  (if (not (boundp (quote chat-log-files-newest)))
      '()
      (let ((live (chats-live-log-paths)))
        (take-n (filter (lambda (path)
                          (and (not (buffer-known? path))
                               (not (member path live))))
                        (chat-log-files-newest))
                chats-archived-limit))))

(define (chats-archived-row? e)
  (and (string? e) (not (buffer-known? e))))

(define (chats-archived-title path)
  (let* ((leaf (chat-log-leaf path))
         (title (re-replace "\\.chat$" (re-replace "^[0-9]+-" leaf "") "")))
    (if (equal? title "") leaf title)))

(define (chats-archived-cells path)
  (list (list "." "faint")
        (list (chats-archived-title path) "dim")
        (list "" "faint")
        (list (format-time (file-mtime path) "%Y-%m-%d %H:%M") "faint")
        (list "archived" "faint")
        (list "" "faint")))

(define (chats-rows)
  (append (agents-sorted) (chats-archived-rows)))

(effects! '(write))

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

(define (agents-live-cells b)
  (let* ((slug (buffer-local b 'agent-slug))
         (status (chat-row-status b))
         (info (and slug (agent-info slug)))
         (face (cond ((equal? status 'needs_attention) "alert")
                     ((or (equal? status 'running) (equal? status 'starting)) "accent")
                     (else "dim"))))
    (list (list (agent-status-glyph status) face)
          (list b "accent")
          (list (or slug "chat") "dim")
          (list (or (buffer-local b 'modeline-info) "") "faint")
          (list (symbol->string status) face)
          (list (if (and info (> (plist-get info 'queued) 0))
                    (string-append "+" (number->string (plist-get info 'queued)))
                    "")
                "warn"))))

(define (agents-cells buf b)
  (if (chats-archived-row? b)
      (chats-archived-cells b)
      (agents-live-cells b)))

(define (agents-meta buf)
  (let* ((es (list-entries buf))
         (saved (length (filter chats-archived-row? es))))
    (string-append (number->string (- (length es) saved))
                   " chats · attention first · "
                   (number->string saved) " saved")))

(define (agents-refresh!)
  (when (buffer-exists? *agents-buffer*)
    (list-refresh! *agents-buffer*)))

(define (agents-current-buf) (list-current *agents-buffer*))

(define (agents-current-slug)
  (let ((b (agents-current-buf)))
    (and b (buffer-local b 'agent-slug))))

(define (agents-targets)
  (filter (lambda (b) (buffer-exists? b)) (list-targets *agents-buffer*)))

(define (agents-report verb bs)
  (message (if (= (length bs) 1)
               (string-append verb " " (car bs))
               (string-append verb " " (number->string (length bs)) " chats"))))

(define (agents-visit-current)
  (let ((b (agents-current-buf)))
    (cond ((not b) #f)
          ((chats-archived-row? b)
           (visit-in-group b (frame-group))
           (end-of-buffer!))
          (else (switch-to-buffer! b) (end-of-buffer!)))))

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

(define (agent-note-stopped! slug)
  (unless (equal? (agent-status slug) 'dead)
    (let ((buf (agent-buf slug)))
      (agent-clear-waiting! slug)
      (agent-block-drop-kind! buf "permission")
      (let ((start (agent-render! slug "\n[agent stopped]\n" "agent-meta")))
        (agent-block-push! buf start (agent-mark slug) "meta" '())))))

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

(define (agents-kill-runtime! b)
  (let ((slug (buffer-local b 'agent-slug)))
    (and slug
         (begin (agent-note-stopped! slug)
                (llm-session-close! slug)
                #t))))

(define (agents-archive! b)
  (let ((here (active-window)))
    (agents-kill-runtime! b)
    (agent-release-windows! b)
    (buffer-kill! b)
    (when (window-exists? here) (select-window! here))))

(define-command "agents-refresh" "Refresh the chat list"
  (lambda () (agents-refresh!)))

(mode-icon! "chats-mode" "")

(define-list-mode! "chats-mode"
  (list
    'doc (string-append
           "Every chat and agent thread in one list: its runtime, its state and "
           "its cost. It marks and executes like ibuffer. `m` marks a chat, `u` "
           "unmarks it and `U` drops every mark; `s` steers, `y` and `n` answer "
           "a permission request for the marked chats, or for the chat at point "
           "when nothing is marked. `k` flags a runtime to kill, `d` flags a "
           "whole chat to archive, and `x` runs the flags. `RET` opens the chat "
           "at point. Under the live chats the list shows the newest saved "
           "conversations. `RET` on one of them reads its file back and revives "
           "the chat.")
    'buffer *agents-buffer*
    'rows (lambda (buf) (chats-rows))
    'columns (lambda (buf)
               (list (list "" 1) (list "chat" #f) (list "slug" 12)
                     (list "model" 26) (list "status" 17)
                     (list "queue" 6 'right)))
    'cells agents-cells
    'title (lambda (buf) "Chats")
    'meta agents-meta
    'total (lambda (buf) (length (list-entries buf)))
    'footer (lambda (buf)
              '(("RET" "visit") ("m" "mark") ("s" "steer")
                ("y/n" "permission") ("k" "kill") ("d" "archive")
                ("x" "execute") ("+" "new") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
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
    ;; an archive row has no runtime, so no verb here can act on it
    'markable? (lambda (buf e) (not (chats-archived-row? e)))
    'keys '(("RET" "agents-visit") ("s" "agents-steer") ("y" "agents-allow")
            ("n" "agents-deny")
            ("g" "agents-refresh") ("+" "agent-open") ("q" "quit-window"))
    ;; line movement remaps to move-and-preview (n is taken: deny)
    'remap '(("next-line" "agents-next") ("previous-line" "agents-prev"))))

(define-command "chat-list" "List every chat: agent threads and API companions"
  (lambda () (list-mode-show! "chats-mode")))

(define (agents-attention)
  (let loop ((ts (agent-threads)) (acc '()))
    (cond ((null? ts) (reverse acc))
          ((equal? (car (cdr (car ts))) 'needs_attention)
           (loop (cdr ts) (cons (car (car ts)) acc)))
          (else (loop (cdr ts) acc)))))

(define (agents-modeline-refresh!)
  (let ((att (agents-attention)))
    (global-mode-string-set! 'agents-attention
      (if (null? att)
          #f
          (list "ml-attention" (string-append "! " (string-join att " ")))))))

(define-command "agent-goto-attention" "Jump to the first thread needing attention"
  (lambda ()
    (let ((att (agents-attention)))
      (if (null? att)
          (message "no agent needs attention")
          (begin (switch-to-buffer! (agent-buf (car att)))
                 (end-of-buffer!))))))

(define-key "agent-map" "n" "agent-open")

(define-key "agent-map" "l" "chat-list")

(define-key "agent-map" "a" "agent-goto-attention")
