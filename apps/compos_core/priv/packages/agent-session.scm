;;; agent-session.scm --- Agent session lifecycle and user input.
;;;
;;; This module owns reconnect, send, queue, input history, interruption, and
;;; thread creation. Transcript rendering and backend events remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

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

(define (agent-revive! slug)
  (unless (member slug (agent-list))
    (llm-session-close! slug))
  (chat-attach! (agent-buf slug)))

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
                  (chat-switch! buf cname model)
                  (when (boundp (quote workspace-llm-defaults-note!))
                    (workspace-llm-defaults-note! buf))))))))))

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
                      (if (member (caddr b) (list "meta" "waiting" "permission" "question" "queued"))
                          acc
                          (string-append acc
                            (substring-bytes text (car b)
                                             (min (cadr b) mark)))))))))))

(define (agent-seed-transcript buf)
  (or (chat-flatten buf) (agent-conversation-text buf)))

(define (agent-send-msg! slug raw)
  (let* ((buf (agent-buf slug))
         ;; a one-shot note — a skill body a mode pushed — rides the next
         ;; message exactly once, then clears
         (once (or (buffer-local buf 'chat-note-once) ""))
         ;; What the user sees rides as a small navigation hint. Document text
         ;; never rides in the message. The agent reads current context itself.
         (msg (string-append
                (if (equal? once "") "" (string-append once "\n\n"))
                (editor-context-preamble buf) raw)))
    (buffer-set-local! buf 'chat-note-once #f)
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

(define (agent-continue! thread text)
  (let ((buf (if (buffer-exists? thread) thread (agent-buf thread))))
    (if (not (and buf (buffer-exists? buf)))
        (error "agent-continue!: unknown chat" thread)
        (let ((slug (or (agent-slug-of buf) (chat-ensure-runtime! buf))))
          (when (equal? (agent-status slug) 'dead)
            (agent-revive! slug))
          (agent-send-msg! slug text)))))

(category! 'chat)

(public! 'agent-continue!
  "(agent-continue! THREAD TEXT) — send to a durable chat buffer or live slug, reviving and replaying it after restart")

(define-command "agent-send" "Send the input to the agent, reviving it if dead"
  (lambda ()
    (let* ((buf (current-buffer))
           ;; say something the moment RET lands: the first send spawns a
           ;; backend and mounts MCP servers, seconds with nothing moving
           (feedback (when (equal? (buffer-local buf 'mode-name) "chat-mode")
                       (chat-activity! buf
                         (if (agent-slug-of buf) "sending…" "starting agent…"))))
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
                   ;; A blank RET commits the oldest queued message as
                   ;; steering. Non-empty RET only adds to the queue.
                   (let ((info (agent-info slug)))
                     (if (and (plist-get info 'steering)
                              (> (plist-get info 'queued) 0)
                              (member (plist-get info 'status)
                                      (list 'running 'needs_attention)))
                         (if (agent-steer! slug)
                             (message "steering the oldest queued message")
                             (message "the queued message could not steer this turn"))
                         (insert! "\n")))
                   (begin
                     ;; the message itself lands in the record when its
                     ;; turn starts; only the walk position resets here
                     (chat-history-reset! buf)
                     (let ((result (agent-send-msg! slug input)))
                       (if (equal? result 'queued)
                           ;; mid-turn: the message moves up into the
                           ;; transcript at once, muted, and the input clears
                           ;; for the next one. Blank RET can explicitly steer
                           ;; the oldest row; otherwise it runs after this turn.
                           (begin
                             (agent-echo-queued! slug input)
                             (chat-clear-input! buf)
                             (end-of-buffer!)
                             (message
                               (if (plist-get (agent-info slug) 'steering)
                                   "queued — press RET again to steer"
                                   "queued — runs when this turn ends")))
                           (begin
                             (chat-clear-input! buf)
                             (end-of-buffer!)
                             (message (if (equal? result 'answered)
                                          "answered"
                                          "sent")))))))))))))

(define *chat-history-limit* 200)

(define (chat-history buf)
  (chat-take
    (let loop ((ts (if (boundp (quote chat-turns)) (chat-turns buf) '())) (acc '()))
      (cond ((null? ts) (reverse acc))
            ((equal? (car (car ts)) "user")
             (loop (cdr ts) (cons (car (cdr (car ts))) acc)))
            (else (loop (cdr ts) acc))))
    *chat-history-limit*))

(define (chat-history-reset! buf)
  (buffer-set-local! buf 'chat-history-pos #f)
  (buffer-set-local! buf 'chat-history-draft #f))

(define (chat-in-input? buf)
  (>= (point) (or (buffer-local buf 'agent-saved-mark) 0)))

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
               (agent-finalize-running-tools! buf "cancelled")
               (agent-discard-queued! buf)
               (llm-session-cancel! slug)
               (message "cancel requested — C-RET again forces a restart")))))))

(define-command "chat-abort" "Stop the reply in flight in this chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf)))
      (if (and slug (member (agent-status slug) '(running starting needs_attention)))
          (begin
            (agent-finalize-running-tools! buf "cancelled")
            (agent-discard-queued! buf)
            (llm-session-cancel! slug)
            ;; both waiting markers: a thread renders its own ('agent-waiting),
            ;; a chat that never attached a runtime renders 'chat-waiting
            (agent-clear-waiting! slug)
            (chat-clear-waiting! buf)
            (message "aborted"))
          (run-command "keyboard-quit")))))

(define-command "chat-unqueue" "Remove the newest queued message and return it to the input"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (texts (or (buffer-local buf 'chat-queued) '())))
      (if (null? texts)
          (message "no queued messages")
          (let* ((rev (reverse texts))
                 (text (car rev))
                 (kept (reverse (cdr rev)))
                 (removed (if (and slug (not (equal? (agent-status slug) 'dead)))
                              (agent-dequeue! slug text)
                              #t)))
            (if (not removed)
                (message "already committed as steering")
                (begin
                  (buffer-set-local! buf 'chat-queued (if (null? kept) #f kept))
                  (let ((draft (chat-input-text buf)))
                    (chat-replace-input! buf
                      (if (equal? (string-trim draft) "")
                          text
                          (string-append text "\n" draft))))
                  (message "unqueued — the message is back in the input"))))))))

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

(define (chat-marker-guard? buf p)
  (and (buffer-local buf 'agent-saved-mark)
       (<= p (chat-input-start buf))))

(effects! '(write))

(define-command "chat-delete-backward" "Delete backward, but never into the transcript"
  (lambda ()
    (if (chat-marker-guard? (current-buffer) (point))
        (message "beginning of input")
        (unless (delete-active-region!) (delete-char! -1)))))

(define-command "chat-delete-forward" "Delete forward, but never the input marker"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (and (buffer-local buf 'agent-saved-mark)
               (>= (point) (chat-mark buf))
               (< (point) (chat-input-start buf)))
          (message "this is the input marker")
          (unless (delete-active-region!) (delete-char! 1))))))

;; the chat keeps point in its input around every command
(define (chat-input-post-command!)
  (chat-snap-to-input!))

(add-hook! 'pre-command-hook 'chat-snap-to-input!)
(add-hook! 'post-command-hook 'chat-input-post-command!)

(define (agent-install-keys! buf)
  ;; the mark is a marker: the buffer keeps the position current through
  ;; every edit. Declared here because every chat passes through this fn,
  ;; on setup, attach, and restore alike.
  ;; 'stay: the input starts AT the mark, so a keystroke there must land
  ;; after it, in the input. The agent's own appends go through
  ;; buffer-insert-at-local!, which advances a stay marker itself.
  (buffer-marker-local! buf 'agent-saved-mark 'stay)
  
  
  
  )

(mode-keys! "chat-mode"
  '(
    ("DEL" "chat-delete-backward")
    ("C-d" "chat-delete-forward")
    ("RET" "agent-send")
    ("C-RET" "agent-interrupt-send")
    ("C-g" "chat-abort")
    ("TAB" "agent-toggle-fold")
    ("<up>" "chat-history-previous")
    ("<down>" "chat-history-next")
    ("C-c C-y" "agent-permission-allow")
    ("C-c C-a" "agent-permission-always")
    ("C-c C-n" "agent-permission-deny")
    ("C-c p" "chat-set-permission-mode")
    ("C-c t" "chat-refresh-tools")
    ("C-c C-d" "chat-unqueue")
    ("C-c C-v" "chat-toggle-view")))

(category! 'chat)

(public! 'execute "(execute \"task\") — spawn a task chat on an ACP backend; returns its slug")

(public! 'execute* "(execute* \"task\" '(connector \"codex\" model \"...\" directory \"/repo/\")) — spawn with config")

(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  ;; agent-next-slug only names the buffer now; the session slug is the
  ;; chat's durable id, assigned by chat-attach-agent!
  (let* ((name (agent-next-slug))
         (buf (string-append "*chat:" name "*")))
    (buffer-create buf)
    ;; Callers over RPC have no meaningful selected file buffer to inherit
    ;; from. An explicit directory is ordinary chat identity policy and wins
    ;; over buffer-create's interactive inheritance.
    (let ((dir (plist-get opts 'directory)))
      (when dir
        (buffer-set-local! buf 'default-directory dir)
        ;; the explicit marker: group companions must not override a
        ;; directory the spawner chose
        (buffer-set-local! buf 'chat-directory dir)))
    ;; a spawned chat may declare its permission posture up front — the
    ;; first turn can start before anyone could press C-c p
    (let ((pm (plist-get opts 'permission-mode)))
      (when pm (buffer-set-local! buf 'chat-permission-mode pm)))
    ;; ...and its presets, which must land in the buffer-local, not only in
    ;; this one call's config. 'chat-presets is the single source of truth
    ;; for a chat's optional tools (the compos bridge is intrinsic):
    ;; agent-revive! and desktop restore both read it. A spawn that skips it
    ;; starts with the right extra servers and loses them at first revive.
    (let ((ps (plist-get opts 'presets)))
      (when ps (buffer-set-local! buf 'chat-presets ps)))
    (chat-task-init! buf name)
    (let ((slug (chat-attach-agent! buf
                  (or (plist-get opts 'connector) *default-connector*)
                  (plist-get opts 'model)
                  opts)))
      (pop-to-buffer buf)
      (when (equal? (current-buffer) buf)
        (set-mode! "chat-mode")
        (end-of-buffer!))
      (unless (equal? prompt "")
        (llm-session-send! slug prompt))
      slug)))

(define-command "agent-open" "Prompt for a task and spawn a new agent thread"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task) (execute task)))))
