;;; agent-session.scm --- Agent session lifecycle and user input.
;;;
;;; This module owns reconnect, send, queue, input history, interruption, and
;;; thread creation. Transcript rendering and backend events remain in agent.scm.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

;; A model is foreign to CNAME when the connector says what it runs (a list
;; from its agent, or a family) and the model is not among it.
(define (agent-model-foreign? buf cname m)
  (let ((known (or (pair? (connector-models cname))
                   (pair? (buffer-local buf 'agent-models))
                   (plist-get (connector-config cname) 'accepts))))
    (and m known
         (not (connector-accepts? cname m))
         (not (assoc m (or (buffer-local buf 'agent-models) '()))))))

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
                      (if (member (caddr b) (list "meta" "status" "waiting" "permission"
                                                  "question" "queued" "eval"))
                          acc
                          (string-append acc
                            (substring-bytes text (car b)
                                             (min (cadr b) mark)))))))))))

(define (agent-seed-transcript buf)
  (or (chat-model-flatten buf)
      (agent-conversation-text buf)))

;;; --- pasted images ------------------------------------------------------------
;;;
;;; A pasted image is a FILE from the moment it lands. The bytes go to
;;; <compos-home>/attachments, the transcript shows the picture, and the
;;; next message carries it. No base64 sits in a buffer-local and none
;;; rides in the message text: a lane that takes image content gets image
;;; content, and every other lane gets a path it can open.

(define (chat-image-extension mime)
  (cond ((equal? mime "image/jpeg") ".jpg")
        ((equal? mime "image/gif") ".gif")
        ((equal? mime "image/webp") ".webp")
        ((equal? mime "image/svg+xml") ".svg")
        (else ".png")))

(define (chat-attachment-path buf mime)
  (let ((dir (string-append (compos-home) "/attachments"))
        (n (length (or (buffer-local buf 'chat-pending-images) '()))))
    (unless (file-directory? dir) (make-directory! dir))
    (string-append dir "/"
                   (or (agent-slug-of buf) "chat") "-"
                   (format-time (current-time) "%Y%m%d-%H%M%S") "-"
                   (number->string n)
                   (chat-image-extension mime))))

;; the image joins the transcript at once, above the input: you see what
;; you pasted before you send it. The block names the file; the renderer
;; shows the picture.
(define (chat-image-show! buf path mime)
  (let ((label (string-append "[image " (cadr (path-split path)) "]\n"))
        (start (chat-mark buf)))
    (buffer-insert-at-local! buf 'agent-saved-mark label)
    (agent-block-push! buf start (+ start (string-byte-length label))
                       "image" (list path mime))))

(define (chat-image-paste! kind data mime)
  ;; The hook only runs in chat-mode, so the mode needs no second test here.
  (if (not (and (equal? kind "image") (string-prefix? "image/" mime)))
      #f
      (let* ((buf (current-buffer))
             (path (chat-attachment-path buf mime)))
        (write-file! path (base64-decode data))
        (buffer-set-local! buf 'chat-pending-images
          (append (or (buffer-local buf 'chat-pending-images) '())
                  (list (list mime path))))
        (chat-image-show! buf path mime)
        (message "image attached - it rides with your next message")
        #t)))

(add-paste-hook! "chat-mode" 'chat-image chat-image-paste!)

;; The editor context block rides only when it says something new: when it
;; differs from the block this chat sent last, when C-c RET named a source, or
;; when a fresh session has seen no block yet.
(define (agent-editor-context buf)
  (let* ((force (or (buffer-local buf 'editor-context-source)
                    (buffer-local buf 'agent-seed-context)))
         (pre (editor-context-preamble buf)))
    (string-append
      (if (and (not force) (equal? pre (buffer-local buf 'editor-context-sent)))
          ""
          (begin (buffer-set-local! buf 'editor-context-sent pre) pre))
      ;; the component fences the last reply could not draw
      (chat-component-report buf))))

(define (agent-send-msg! slug raw)
  (let* ((buf (agent-buf slug))
         ;; a one-shot note - a skill body a mode pushed - rides the next
         ;; message exactly once, then clears
         (once (or (buffer-local buf 'chat-note-once) ""))
         ;; images the user pasted since the last send ride once, then clear
         (images (or (buffer-local buf 'chat-pending-images) '()))
         ;; the path rides in the text as well as on the image lane. A
         ;; backend that cannot take image content can still open the file,
         ;; and a path is a few bytes where the picture is megabytes.
         (image-note (apply string-append
                       (map (lambda (im)
                              (string-append "\n[attached image " (cadr im) "]"))
                            images)))
         ;; What the user sees rides as a small navigation hint. Document text
         ;; never rides in the message. The agent reads current context itself.
         (msg (string-append
                (if (equal? once "") "" (string-append once "\n\n"))
                (agent-editor-context buf) (chat-fast-note buf) raw image-note)))
    (buffer-set-local! buf 'chat-note-once #f)
    (buffer-set-local! buf 'chat-fast-runs '())
    (buffer-set-local! buf 'chat-pending-images '())
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
            raw images))
        (llm-session-send! slug msg raw images))))

;; editor-context-preamble (editor.scm) reads this; editor.scm loads first
(defcustom 'editor-context-snapshot #t
  "Start each chat send with one line for every visible buffer: its name, mode and line at point. Set #f to send only what mode providers add."
  'group 'chat 'type 'boolean)

;; #f means TEXT already left the runtime's queue (it was promoted into
;; the running turn as steering) between the row rendering and the key
;; that asked to remove it.
(define (agent-dequeue! slug text)
  (llm-session-dequeue! slug text))

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

;;; Scheme at the chat prompt.
;;
;; A chat buffer is a REPL as well as a conversation. An input that reads
;; as a parenthesised expression runs right here: it prints its value into
;; the transcript, spends no turn, and the model never learns it happened.
;; Prose that must start with an open paren escapes it with a backslash.

(defcustom 'chat-scheme-input #t
  "Run a chat input that opens with a paren as Scheme instead of sending it to the agent. Set #f to send every input."
  'group 'chat 'type 'boolean)

;; How wide a printed value may be before it breaks across lines.
(define chat-scheme-width 84)

(define (chat-scheme-input? text)
  (and chat-scheme-input (string-prefix? "(" text)))

;; Tree-sitter owns the question, so a broken string and a stray closer
;; count too, not only an unclosed paren. RET never evaluates malformed
;; Scheme and never lets it leave as a message: it takes a newline and
;; waits for the expression to close.
(define (chat-scheme-well-formed? text)
  (null? (ts-query-string "scheme" text "(ERROR) @err")))

;;; Pretty printing. (apropos "windows") answers a list of plists, and one
;;; long line of it is unreadable. A value that fits stays on its line; one
;;; that does not breaks, and a plist breaks a key and its value per line.

(define (chat-scheme--proper? v)
  (let loop ((x v))
    (cond ((null? x) #t) ((pair? x) (loop (cdr x))) (else #f))))

(define (chat-scheme--plist? v)
  (and (pair? v) (chat-scheme--proper? v)
       (let loop ((x v))
         (cond ((null? x) #t)
               ((not (pair? (cdr x))) #f)
               ((not (symbol? (car x))) #f)
               (else (loop (cdr (cdr x))))))))

(define (chat-scheme--pairs v indent pad)
  (string-join
    (let loop ((x v) (out '()))
      (if (null? x)
          (reverse out)
          (let ((k (value->string (car x))))
            (loop (cdr (cdr x))
                  (cons (string-append
                          k " "
                          (chat-scheme-pp (car (cdr x))
                                          (+ indent 2 (string-byte-length k))))
                        out)))))
    pad))

(define (chat-scheme-pp v indent)
  (let ((flat (value->string v)))
    (cond ((<= (+ indent (string-byte-length flat)) chat-scheme-width) flat)
          ((not (pair? v)) flat)
          ((not (chat-scheme--proper? v)) flat)
          (else
           (let ((pad (string-append "\n" (string-repeat " " (+ indent 1)))))
             (string-append
               "("
               (if (chat-scheme--plist? v)
                   (chat-scheme--pairs v indent pad)
                   (string-join (map (lambda (x) (chat-scheme-pp x (+ indent 1))) v)
                                pad))
               ")"))))))

(define (chat-scheme-unescape text)
  (if (string-prefix? "\\(" text)
      (substring-bytes text 1 (string-byte-length text))
      text))

; An M-x command is not a Scheme variable, so a bare (previous-buffer) at the
; prompt would read as an unbound name. A one-word call whose name the command
; table knows, and the environment does not, is the command: run it.
(define (chat-scheme-command src)
  (let* ((n (string-byte-length src))
         (inner (if (and (> n 1) (string-prefix? "(" src) (string-suffix? ")" src))
                    (string-trim (substring-bytes src 1 (- n 1)))
                    "")))
    (and (not (equal? inner ""))
         (not (string-index inner "("))
         (not (string-index inner " "))
         (not (string-index inner "\n"))
         (not (boundp (string->symbol inner)))
         (member inner (command-names))
         inner)))

; nested, the rewrite above cannot help — say where the name lives instead
(define (chat-scheme-hint msg)
  (let ((name (and (string-prefix? "unbound variable: " msg)
                   (string-trim (substring-bytes msg 18 (string-byte-length msg))))))
    (if (and name (member name (command-names)))
        (string-append "\n" name " is an M-x command: (run-command \"" name "\")")
        "")))

(define (chat-scheme-report src result)
  (string-append "λ " src "\n"
                 (if (equal? (car result) 'ok)
                     (chat-scheme-pp (cadr result) 0)
                     (string-append "error: " (cadr result)
                                    (chat-scheme-hint (cadr result))))))

(define *chat-scheme-buffer* "*chat-eval*")

;; C-u RET sends the value to its own window instead of the transcript: an
;; apropos answer is a list to read and scroll, not a thing to bury the
;; conversation under. The chat keeps the focus.
(define (chat-scheme-other-window! text)
  (let ((b *chat-scheme-buffer*))
    (unless (buffer-known? b) (buffer-create b))
    (buffer-delete-range! b 0 (buffer-size b))
    (buffer-append! b text)
    (display-buffer-other-window! b)
    b))

(define (chat-scheme-run! buf src other?)
  (let* ((cmd (chat-scheme-command src))
         (result (eval-string-safe (if cmd
                                       (string-append "(run-command \"" cmd "\")")
                                       src)))
         (ok (equal? (car result) 'ok))
         (body (chat-scheme-report src result))
         (shown (if (and other? ok)
                    (string-append "λ " src "\n→ " *chat-scheme-buffer*)
                    body))
         (text (string-append "\n" shown "\n")))
    ;; the expression joins this chat's prompt history before it runs:
    ;; up-arrow reaches the last thing you evaluated here
    (chat-history-push! buf src)
    (chat-history-reset! buf)
    (chat-clear-input! buf)
    (when (and other? ok) (chat-scheme-other-window! body))
    ;; status, not conversation: it is saved with the chat, and every
    ;; model-facing path filters a status row out. The agent is not told
    ;; what you evaluated and never sees the value.
    (chat-record-push! buf "status" (list (list "text" (string-trim text))) #f)
    ;; chat-render! writes at the saved mark, so a chat with no runtime —
    ;; restored, or never sent to — is a REPL too
    (when (buffer-local buf 'agent-saved-mark)
      (when (boundp 'agent-adopt-prose-tail!) (agent-adopt-prose-tail! buf))
      (let* ((start (chat-render! buf text))
             (end (+ start (string-byte-length text))))
        (agent-block-push! buf start end "eval" '())))
    (end-of-buffer!)
    (message (if ok "ok" (cadr result)))
    ;; what was printed, for a caller that records the run
    body))

;; An input that opens with ! is prose for fast-code: it resolves to Scheme
;; before it runs, and then takes the same path a parenthesised input takes.
;; Without fast-code loaded, ! is ordinary prose and goes to the agent.
(define (chat-fast-input? text)
  (and (boundp 'fast-chat-input?) (fast-chat-input? text)))

(define (chat-fast-resolve text k)
  (fast-chat-resolve text k))

;; A ! run spends no turn, but the agent is told: the next message carries
;; what you typed, what it ran and what came back, once. Without it the
;; agent answered "didn't work" blind to the run that didn't.
(define (chat-fast-record! buf typed src body)
  ;; the printed report opens with the expression again; keep what it gave
  (let* ((nl (string-index body "\n"))
         (out (if (and nl (string-prefix? "λ" body))
                  (substring-bytes body (+ nl 1) (string-byte-length body))
                  body)))
    (buffer-set-local! buf 'chat-fast-runs
      (append (or (buffer-local buf 'chat-fast-runs) '())
              (list (list typed src (if (> (string-length out) 300)
                                        (string-append (substring out 0 300) "…")
                                        out)))))))

(define (chat-fast-note buf)
  (let ((runs (or (buffer-local buf 'chat-fast-runs) '())))
    (if (null? runs)
        ""
        (string-append
          "[fast-code runs since your last turn — the user typed ! and words; "
          "fast-code wrote the Scheme and ran it:\n"
          (apply string-append
                 (map (lambda (r)
                        (string-append (car r) "\n  ran " (cadr r)
                                       "\n  gave " (caddr r) "\n"))
                      runs))
          "]\n\n"))))

(define-command "agent-send" "Send the input to the agent, reviving it if dead"
  (lambda ()
    (let* ((buf (current-buffer))
           (chat? (equal? (buffer-local buf 'mode-name) "chat-mode"))
           (typed (string-trim (chat-input-text buf))))
      (if (and chat? (or (chat-scheme-input? typed) (chat-fast-input? typed)))
          ;; the prompt is a REPL before it is a conversation, and an input
          ;; that opens with ! is prose fast-code resolves to Scheme first.
          ;; Malformed Scheme goes nowhere: not to the reader, not to the model.
          ;; The fast model answers after this returns, so its run happens
          ;; back in this chat, and the prefix arg is read now.
          (let ((other? (and (current-prefix-arg) #t)))
            (cond
              ((chat-fast-input? typed)
               (chat-fast-resolve typed
                 (lambda (src)
                   (with-current-buffer buf
                     (lambda ()
                       (let ((printed (chat-scheme-run! buf src other?)))
                         (fast-chat-ran! typed printed)
                         (chat-fast-record! buf typed src printed)))))))
              ((chat-scheme-well-formed? typed)
               (chat-scheme-run! buf typed other?))
              (else
                (insert! "\n")
                (message "unbalanced expression — RET runs it once it closes"))))
          (let* (;; say something the moment RET lands: the first send spawns a
                 ;; backend and mounts MCP servers, seconds with nothing moving
                 (feedback (when chat?
                             (chat-activity! buf
                               (if (agent-slug-of buf) "sending…" "starting agent…"))))
                 ;; a chat without a runtime gets one on first send, on its own
                 ;; connector; RET is agent-send on EVERY chat
                 (slug (or (agent-slug-of buf)
                           (and chat?
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
                   (let ((input (chat-scheme-unescape typed)))
                     (if (equal? input "")
                         ;; A blank RET commits the oldest queued message as
                         ;; steering. Non-empty RET only adds to the queue.
                         (let ((info (agent-info slug)))
                           ;; 'ending says the backend already finished this
                           ;; turn and only an unresolved steer holds it open.
                           ;; A steer into it is never answered, so the
                           ;; message waits and runs as its own turn.
                           (if (and (plist-get info 'steering)
                                    (not (plist-get info 'ending))
                                    (> (plist-get info 'queued) 0)
                                    (member (plist-get info 'status)
                                            (list 'running 'needs_attention)))
                               (if (agent-steer! slug)
                                   (message "steering the oldest queued message")
                                   (message "the queued message could not steer this turn"))
                               (insert! "\n")))
                         (begin
                           ;; the message itself lands in the record when its
                           ;; turn starts; here it only joins the prompt history
                           ;; and the walk position resets
                           (chat-history-push! buf input)
                           (chat-history-reset! buf)
                           ;; /NAME args runs a skill from the chat's skills dirs
                           (let* ((sent (or (and (boundp 'skill-expand-input)
                                                 (skill-expand-input input))
                                            input))
                                  (result (agent-send-msg! slug sent)))
                             (if (equal? result 'queued)
                                 ;; mid-turn: the message moves up into the
                                 ;; transcript at once, muted, and the input
                                 ;; clears for the next one. ONE RET is the
                                 ;; whole send. The turn ends, finish_turn
                                 ;; pops the queue, and the message runs in
                                 ;; order. Nothing asks for a second key: a
                                 ;; message you must send twice reads as a
                                 ;; message that did not go. Blank RET still
                                 ;; steers the oldest row into the turn that
                                 ;; is running, for when waiting is wrong.
                                 (begin
                                   ;; the text the runtime holds, so the
                                   ;; user-msg that delivers it pops this row
                                   (agent-echo-queued! slug sent)
                                   (chat-clear-input! buf)
                                   (end-of-buffer!)
                                   (message "queued — runs when this turn ends"))
                                 (begin
                                   (chat-clear-input! buf)
                                   (end-of-buffer!)
                                   (message (if (equal? result 'answered)
                                                "answered"
                                                "sent")))))))))))))))

;;; Completion at the chat prompt.
;;
;; The vocabulary is the editor's own, so the source is scheme-mode's: one
;; catalog, one orderless matcher, the same answers M-/ gives in a .scm
;; file. It answers only inside an expression. While you write prose it
;; answers with nothing and stops the collect there, because dabbrev
;; popping up mid-sentence is worse than no completion at all.
;;; The chat input completes by its opening character. ( is the editor's
;;; own vocabulary; ! is the same line over every recipe instead. Prose
;;; still offers nothing, and does not fall through to dabbrev.
(define (chat-scheme--capf)
  (let* ((buf (current-buffer))
         (nothing (list (point) (point) '()))
         (input (string-trim (chat-input-text buf))))
    (if (< (point) (chat-input-start buf))
        nothing
        (cond
          ((and (string-prefix? "!" input) (boundp 'fast-chat-capf))
           (or (fast-chat-capf) nothing))
          ((and (string-prefix? "/" input) (boundp 'skill-input-capf))
           (or (skill-input-capf) nothing))
          ((and chat-scheme-input
                (boundp 'scheme-ide--capf)
                (string-prefix? "(" input))
           (scheme-ide--capf))
          (else nothing)))))

(define (chat-scheme--mode-hook!)
  (let ((buf (current-buffer)))
    (let ((cur (or (buffer-local buf 'capf-sources) '())))
      (unless (member chat-scheme--capf cur)
        (buffer-set-local! buf 'capf-sources (cons chat-scheme--capf cur))))
    (desktop-skip! buf 'capf-sources)
    (capf-auto-watch! buf)))

(add-hook! 'chat-mode-hook 'chat-scheme--mode-hook!)

;; the chats already open never ran the hook
(for-each (lambda (b)
            (when (equal? (buffer-local b 'mode-name) "chat-mode")
              (with-current-buffer b chat-scheme--mode-hook!)))
          (buffer-list))

(define *chat-history-limit* 200)

;; One history per chat, newest first: the expressions you ran and the
;; messages you sent in THIS buffer. A chat is a session of its own, the
;; way a shell window is — the apropos call you made here is one
;; up-arrow away here, and the chat next door is not full of it. It
;; lives in memory only: a restart starts you clean, and the transcripts
;; still hold what was said.
(define (chat-history buf)
  (or (buffer-local buf 'chat-history-ring) '()))

(define (chat-history-set! buf ring)
  (buffer-set-local! buf 'chat-history-ring
    (chat-take ring *chat-history-limit*)))

;; consecutive repeats collapse, the way a shell's history does
(define (chat-history-push! buf text)
  (let ((t (string-trim text))
        (h (chat-history buf)))
    (unless (or (equal? t "")
                (and (pair? h) (equal? t (car h))))
      (chat-history-set! buf (cons t h)))))

;; A reload and a restart both start the ring empty, and a chat you had
;; been talking in all morning would answer the first up-arrow with
;; nothing. The first walk in such a chat seeds its ring from its own
;; transcript, newest first.
(define (chat-history-seed! buf)
  (when (null? (chat-history buf))
    (chat-history-set! buf
      (let loop ((ts (if (boundp (quote chat-turns)) (chat-turns buf) '())) (acc '()))
        (cond ((null? ts) (reverse acc))
              ((equal? (car (car ts)) "user")
               (loop (cdr ts) (cons (car (cdr (car ts))) acc)))
              (else (loop (cdr ts) acc)))))))

(define (chat-history-reset! buf)
  (buffer-set-local! buf 'chat-history-pos #f)
  (buffer-set-local! buf 'chat-history-draft #f)
  (buffer-set-local! buf 'chat-history-prefix #f))

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

; What you have already typed is the search. Up walks only the entries
; that start with it, the way a shell's history search does, so "(load "
; reaches the last thing you loaded and "(" reaches every expression
; without the prose in between. An empty draft walks everything. The
; prefix is taken once, when you step off the draft, and held for the
; walk: recall rewrites the input, and reading it again would change the
; ring underfoot.
(define (chat-history-for buf prefix)
  (let ((h (chat-history buf)))
    (if (equal? prefix "")
        h
        (filter (lambda (s) (string-prefix? prefix s)) h))))

(define (chat-history-prefix-of buf)
  (or (buffer-local buf 'chat-history-prefix)
      (let ((prefix (chat-input-text buf)))
        (buffer-set-local! buf 'chat-history-prefix prefix)
        prefix)))

(define (chat-history-recall! buf dir)
  (let* ((prefix (chat-history-prefix-of buf))
         (h (chat-history-for buf prefix))
         (pos (or (buffer-local buf 'chat-history-pos) -1))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length h))
           (message (if (equal? prefix "")
                        "no earlier input"
                        (string-append "no earlier input starting with " prefix))))
          ((< next -1) #f)
          (else
            ;; hold the draft the first time you step off it
            (when (= pos -1)
              (buffer-set-local! buf 'chat-history-draft (chat-input-text buf)))
            (buffer-set-local! buf 'chat-history-pos (if (= next -1) #f next))
            ;; back on the draft, the next walk takes its prefix afresh
            (when (= next -1) (buffer-set-local! buf 'chat-history-prefix #f))
            (chat-replace-input! buf
              (if (= next -1)
                  (or (buffer-local buf 'chat-history-draft) "")
                  (nth next h)))))))

;; the queued rows walk newest first, same direction as sent history, so
;; index 0 is the message closest to the input -- the one chat-unqueue
;; already treats as "the newest queued message"
(define (chat-queued-for buf) (reverse (or (buffer-local buf 'chat-queued) '())))

(define (chat-queued-recall! buf dir)
  (let* ((q (chat-queued-for buf))
         (walk (buffer-local buf 'chat-queued-walk))
         (pos (or (plist-get walk 'pos) -1))
         (draft (if walk (or (plist-get walk 'draft) "") (chat-input-text buf)))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length q))
           ;; walked past the oldest queued row: restore the draft this walk
           ;; started from, so the sent-history walk starts from it too,
           ;; not from whatever queued text happens to be showing
           (chat-replace-input! buf draft)
           (buffer-set-local! buf 'chat-queued-walk #f)
           (chat-history-recall! buf dir))
          ((< next -1) #f)
          (else
            ;; the walk is one record, (pos P draft D): where it stands and
            ;; the draft it started from. No record means no walk.
            (buffer-set-local! buf 'chat-queued-walk
              (and (>= next 0) (list 'pos next 'draft draft)))
            (chat-replace-input! buf (if (= next -1) draft (nth next q)))
            (when (>= next 0)
              (message (string-append "queued " (number->string (+ next 1)) "/"
                                      (number->string (length q))
                                      " -- C-c C-d removes it, RET re-sends it")))))))

(define (chat-history-move! dir)
  (let* ((buf (current-buffer))
         (motion (if (< dir 0) "previous-line" "next-line")))
    (chat-history-seed! buf)
    (cond
      ;; already walking the queued rows: stay in that walk
      ((buffer-local buf 'chat-queued-walk) (chat-queued-recall! buf dir))
      ((or (not (buffer-local buf 'agent-saved-mark))
           (not (chat-in-input? buf))
           ;; inside a multi-line input, up and down are still motion
           (if (< dir 0)
               (not (chat-on-first-input-line? buf))
               (not (chat-on-last-input-line? buf))))
       (run-command motion))
      ;; an empty draft, going up, with rows waiting to run: those come
      ;; before the sent history, since they are what point is closest to
      ((and (< dir 0)
            (equal? (string-trim (chat-input-text buf)) "")
            (pair? (buffer-local buf 'chat-queued)))
       (chat-queued-recall! buf dir))
      ((null? (chat-history buf)) (run-command motion))
      (else (chat-history-recall! buf dir)))))

(define-command "chat-history-previous" "Recall the previous thing you typed at a prompt"
  (lambda () (chat-history-move! -1)))

(define-command "chat-history-next" "Recall the next thing you typed at a prompt"
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
            (agent-clear-waiting! buf)
            ;; C-g is a quit either way: the buffer returns to the
            ;; movement state, and the Cmd-arrows move the focus again
            (editing-quit!)
            (message "aborted"))
          (run-command "keyboard-quit")))))

(define (chat-dismiss--hide! buf)
  (let* ((win (window-showing buf))
         (fallback (car (filter (lambda (b)
                                  (and (not (equal? b buf))
                                       (buffer-exists? b)))
                                (window-fill-buffers)))))
    (if (and win fallback)
        (begin
          (switch-to-buffer-here! fallback)
          (buffer-sleep! buf)
          #t)
        (not win))))

;; A chat ends itself. The agent says how its work ended with chat-finish!,
;; and at the end of the turn the chat is archived and killed only when the
;; agent said done and nothing argues against it: a failed or cancelled
;; run, a waiting permission, unsaved edits, or an open todo of the chat.
;; Anything else keeps the chat, and a notice says why.
(define *chat-finish-outcomes* '(done blocked needs-user))

(define *chat-finish-ask*
  "When your work is complete, call (chat-finish! 'done \"one-line summary\") and the chat closes. If you cannot complete it, call (chat-finish! 'blocked \"why\") or (chat-finish! 'needs-user \"what you need\") and the chat stays.")

(define (chat-dismiss--ask) (string-append "This chat is dismissed. " *chat-finish-ask*))

(define (chat-finish--open-todos buf)
  (let ((id (buffer-local buf 'chat-id)))
    (if (string? id)
        (filter (lambda (t) (member id (todo-chats t)))
                (or (ignore-errors (lambda () (todo-list))) '()))
        '())))

(define (chat-finish--blockers buf slug ok? stop-reason)
  (let ((info (and slug (agent-info slug)))
        (work (ignore-errors (lambda () (chat-work-state buf)))))
    (append
     (if (and ok? (not (equal? stop-reason "cancelled")))
         '()
         (list (string-append "the run ended: " (if (string? stop-reason) stop-reason "error"))))
     (if (and (pair? info) (plist-get info 'permission)) (list "a permission request waits") '())
     (if (and (pair? work) (eq? (plist-get work 'verdict) 'unsaved)) (list "it has unsaved edits") '())
     (map (lambda (t) (string-append "todo " (plist-get t 'id) " is " (plist-get t 'state)))
          (chat-finish--open-todos buf)))))

(define (chat-finish--settle! buf slug ok? stop-reason)
  (let* ((fin (buffer-local buf 'chat-finish))
         (outcome (and (pair? fin) (car fin)))
         (summary (if (pair? fin) (cadr fin) ""))
         (title (chats-title buf))
         (reap? (buffer-local buf 'chat-reap))
         (blockers (chat-finish--blockers buf slug ok? stop-reason)))
    (buffer-set-local! buf 'chat-dismiss-pending #f)
    (buffer-set-local! buf 'chat-finish-asked #f)
    (buffer-set-local! buf 'chat-finish #f)
    (buffer-set-local! buf 'chat-reap #f)
    (if (and (eq? outcome 'done) (null? blockers))
        (begin
          (ignore-errors (lambda () (chat-log-save! buf)))
          (agents-archive! buf)
          (notify! "chat" (string-append "Done: " title) summary)
          'closed)
        (let ((why (string-join
                    (append (cond ((not outcome) '("the agent did not say it is done"))
                                  ((eq? outcome 'done) '())
                                  (else (list (string-append (symbol->string outcome) ": " summary))))
                            blockers)
                    "; ")))
          ;; a chat the reaper asked stays without a notice
          (if reap?
              (begin
                (buffer-set-local! buf 'chat-reaped #t)
                (message (string-append "Kept: " title ": " why)))
              (notify! "chat" (string-append "Kept: " title) why))
          'kept))))

(define (chat-finish-turn-end! slug stop-reason ok?)
  (let ((buf (agent-buf slug)))
    (when (and (string? buf) (buffer-exists? buf))
      ;; a turn the reaper did not start makes a kept chat one it may ask again
      (when (and (buffer-local buf 'chat-reaped) (not (buffer-local buf 'chat-dismiss-pending)))
        (buffer-set-local! buf 'chat-reaped #f))
      (cond ((buffer-local buf 'chat-finish)
             (chat-finish--settle! buf slug ok? stop-reason))
            ((buffer-local buf 'chat-dismiss-pending)
             ;; a dismissed chat that has not said how it ended is asked once
             (if (and ok? (not (buffer-local buf 'chat-finish-asked)))
                 (begin
                   (buffer-set-local! buf 'chat-finish-asked #t)
                   (agent-send-msg! slug (chat-dismiss--ask)))
                 (chat-finish--settle! buf slug ok? stop-reason)))))))

(define (chat-finish! outcome summary &optional buf0)
  (let* ((buf (or buf0 (current-buffer)))
         (slug (agent-slug-of buf))
         (outcome (if (string? outcome) (string->symbol outcome) outcome)))
    (cond ((not slug) (error "chat-finish!: not a chat"))
          ((not (memq outcome *chat-finish-outcomes*))
           (error "chat-finish!: OUTCOME is done, blocked or needs-user"))
          (else
           (buffer-set-local! buf 'chat-finish (list outcome (if (string? summary) summary "")))
           (if (member (agent-status slug) '(running starting))
               (if (eq? outcome 'done)
                   "the chat closes when this turn ends, unless something holds it"
                   "the chat stays; the user gets a notice")
               (chat-finish--settle! buf slug #t #f))))))

(public! 'chat-finish!
  "(chat-finish! OUTCOME SUMMARY [BUF]) -- a chat says how its work ended: done, blocked or needs-user. At the turn end a done chat is archived and killed, unless a failed run, a waiting permission, unsaved edits or an open todo holds it")
(catalog-meta! 'function "chat-finish!" 'domain 'chat 'effects '(destroy))

;; An idle chat is asked to finish. A chat that no window shows, with no
;; turn in flight, no listener waiting for it and nothing typed in its
;; input, that has heard nothing for chat-idle-reap-minutes, is asked one
;; time. A done answer closes it through chat-finish!; any other answer
;; keeps it with no notice, and only a later turn lets the reaper ask again.
(defcustom 'chat-idle-reap-minutes 30
  "Ask a chat to finish after this many idle minutes; it closes when it says it is done. 0 never asks."
  'group 'chat 'type 'integer)

(define (chat-reap--candidates)
  (let ((limit (* 60 chat-idle-reap-minutes))
        (now (current-time)))
    (filter (lambda (b)
              (let ((slug (agent-slug-of b))
                    (seen (alist-get *chats-activity* b)))
                (and slug (buffer-exists? b)
                     (equal? (agent-status slug) 'idle)
                     (number? seen) (>= (- now seen) limit)
                     (not (buffer-local b 'chat-reaped))
                     (not (buffer-local b 'chat-dismiss-pending))
                     (not (window-showing b))
                     (null? (agent-listeners b))
                     (equal? (string-trim (chat-input-text b)) ""))))
            (map car *chats-activity*))))

(defcustom 'chat-idle-reap-dry-run #t
  "Only name the idle chats the reaper would ask, in the echo area; ask none of them."
  'group 'chat 'type 'boolean)

(define (chat-reap! &optional _event)
  "ask each idle chat to finish; answer the chats asked"
  (if (not (and (number? chat-idle-reap-minutes) (> chat-idle-reap-minutes 0)))
      '()
      (let ((bs (chat-reap--candidates)))
        (if chat-idle-reap-dry-run
            (let ((new (filter (lambda (b) (not (buffer-local b 'chat-reap-noted))) bs)))
              (for-each (lambda (b) (buffer-set-local! b 'chat-reap-noted #t)) new)
              (when (pair? new)
                (message (string-append "Reap (dry run) would ask "
                                        (number->string (length new)) ": "
                                        (string-join new ", "))))
              bs)
            (begin
              (for-each (lambda (b)
                          (buffer-set-local! b 'chat-reap #t)
                          (buffer-set-local! b 'chat-dismiss-pending #t)
                          (buffer-set-local! b 'chat-finish-asked #t)
                          (agent-send-msg! (agent-slug-of b)
                                           (string-append "This chat has been idle for "
                                                          (number->string chat-idle-reap-minutes)
                                                          " minutes. " *chat-finish-ask*)))
                        bs)
              bs)))))

(public! 'chat-reap! "(chat-reap!) -- ask each idle chat to finish; answer the chats asked")
(catalog-meta! 'function "chat-reap!" 'domain 'chat 'effects '(write spend))

(when (boundp 'cron-define!)
  (cron-define! "chat-reap" "*/5 * * * *" 'call 'chat-reap! 'save #f))

(define-command "chat-dismiss"
  "Hide this chat, optionally send a final instruction; it closes when the agent says it is done"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (input (string-trim (chat-input-text buf)))
           (running (and slug (member (agent-status slug) '(running starting)))))
      (if (not (chat-dismiss--hide! buf))
          (message "could not hide chat: no other buffer is available")
          (begin
            (when slug
              (buffer-set-local! buf 'chat-dismiss-pending #t)
              (cond ((not (equal? input ""))
                     (chat-clear-input! buf)
                     (buffer-set-local! buf 'chat-finish-asked #t)
                     (agent-send-msg! slug (string-append input "\n\n" (chat-dismiss--ask))))
                    ((not running)
                     (buffer-set-local! buf 'chat-finish-asked #t)
                     (agent-send-msg! slug (chat-dismiss--ask)))))
            (message "chat hidden; it closes when the agent says it is done"))))))

(define (list-remove-at lst i)
  (let loop ((l lst) (n 0) (acc '()))
    (cond ((null? l) (reverse acc))
          ((= n i) (append (reverse acc) (cdr l)))
          (else (loop (cdr l) (+ n 1) (cons (car l) acc))))))

(define-command "chat-unqueue"
  "Remove the previewed queued message (or the newest one) and return it to the input"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (q (chat-queued-for buf))
           (walk (buffer-local buf 'chat-queued-walk))
           (walked (plist-get walk 'pos))
           (idx (if (and walked (< walked (length q))) walked 0)))
      (if (null? q)
          (message "no queued messages")
          (let* ((text (nth idx q))
                 (removed (if (and slug (not (equal? (agent-status slug) 'dead)))
                              (agent-dequeue! slug text)
                              #t)))
            (if (not removed)
                (message "already committed as steering")
                (begin
                  (buffer-set-local! buf 'chat-queued
                    (let ((kept (reverse (list-remove-at q idx))))
                      (if (null? kept) #f kept)))
                  (buffer-set-local! buf 'chat-queued-walk #f)
                  (let ((draft (if walked (or (plist-get walk 'draft) "")
                                   (chat-input-text buf))))
                    (chat-replace-input! buf
                      (if (equal? (string-trim draft) "")
                          text
                          (string-append text "\n" draft))))
                  (message "unqueued — the message is back in the input"))))))))

(define (agent-claimed-slugs)
  (filter (lambda (s) s)
          (map (lambda (b) (buffer-local b 'agent-slug)) (buffer-list))))

(define (agent-chat-buffer slug) (string-append "*chat:" slug "*"))

(define (agent-next-slug)
  ;; The collision check must name the buffer execute* actually creates.
  ;; It used agent-buffer, which still answers "*agent: a1*" from the old
  ;; naming, so a live "*chat:a1*" looked free: buffer-create reused it,
  ;; re-stamped a chat header over the transcript, chat-attach-agent! handed
  ;; back the FIRST chat's slug, and the new prompt was sent into a dead
  ;; session and lost. Two spawns collapsed into one chat.
  (let ((claimed (agent-claimed-slugs)))
    (let loop ((n 1))
      (let ((slug (string-append "a" (number->string n))))
        (if (or (member slug (agent-list))
                (buffer-exists? (agent-chat-buffer slug))
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

(effects! '(write display))

;; Scrolled up in a long chat, a window keeps its own scroll pin and stops
;; following point. Back to the newest message means both halves: point home
;; in the input, and every window showing this chat off its pin again.
(define (chat-to-bottom-target)
  (let ((buf (current-buffer)))
    (if (chat-buffer? buf)
        buf
        (let loop ((ws (window-list)))
          (cond ((null? ws) #f)
                ((chat-buffer? (cadr (car ws))) (cadr (car ws)))
                (else (loop (cdr ws))))))))

;; The transcript scroller keeps a reader position of its own, apart from
;; point: 'follow-place records that the reader left the bottom, and the
;; block they left it on. Every relayout re-places
;; the view from those, so moving point alone is invisible — the hook puts
;; the transcript straight back on the saved block. Clearing them, and
;; bumping the token the hook watches, is what makes a chat follow the
;; newest message again.
(define (chat-follow-again! buf)
  (let ((seq (buffer-local buf 'follow-seq)))
    (buffer-set-local! buf 'follow-place #f)
    ;; the bottom is the transcript window's home: the earlier blocks a
    ;; reader revealed go back behind the reveal row
    (when (buffer-local buf 'chat-view-reveal)
      (buffer-set-local! buf 'chat-view-reveal #f)
      (when (boundp 'chat-view-sync!) (chat-view-sync! buf)))
    (buffer-set-local! buf 'follow-seq (+ 1 (if (number? seq) seq 0)))))

(define-command "chat-to-bottom" "Scroll this chat to the newest message"
  (lambda ()
    (let ((buf (chat-to-bottom-target)))
      (if (not buf)
          (message "no chat here")
          (begin
            (with-current-buffer buf (lambda () (end-of-buffer!)))
            (chat-follow-again! buf)
            (buffer-windows-follow-point! buf))))))
;; The other end: the first message. The transcript draws only its newest
;; blocks, so the top first reveals every earlier one; then the reader's
;; place is the very top, and the bumped token makes the page take it.
(define-command "chat-to-top" "Scroll this chat to its first message"
  (lambda ()
    (let ((buf (chat-to-bottom-target)))
      (if (not buf)
          (message "no chat here")
          (let ((seq (buffer-local buf 'follow-seq)))
            (with-current-buffer buf (lambda () (beginning-of-buffer!)))
            (buffer-set-local! buf 'chat-view-reveal (length (agent-blocks buf)))
            (when (boundp 'chat-view-sync!) (chat-view-sync! buf))
            (buffer-set-local! buf 'follow-place '(#t 0 #f 0))
            (buffer-set-local! buf 'follow-seq (+ 1 (if (number? seq) seq 0))))))))

;; A chat comes back at its newest message. A browser that attaches a
;; frame (a page load, a reconnect after a restart) shows each chat in
;; that frame at the bottom, not at the place a reader left in an older
;; page. Within one page the reader's place still holds.
(define (chat-frame-to-bottom!)
  (for-each (lambda (w)
              (let ((buf (cadr w)))
                (when (chat-buffer? buf) (chat-follow-again! buf))))
            (window-list)))

(add-hook! 'frame-attach-hook 'chat-frame-to-bottom!)

;; M-> is end-of-buffer everywhere else, and in a chat the end of the
;; buffer IS the newest message — but point alone does not move the
;; transcript. On chat-mode's own map the key keeps its meaning and
;; gains the scroller. M-< is its mirror.
(mode-keys! "chat-mode" '(("M->" "chat-to-bottom") ("M-<" "chat-to-top")))

(effects! '(write))

;; the chat keeps point in its input around every command
;; the commands that edit only the input: the transcript model cannot
;; change under them, so the rich view does not sync after them
(define chat-view-input-commands
  '("self-insert-command" "chat-delete-backward" "chat-delete-forward"
    "delete-backward-char" "delete-char"))

(define (chat-input-post-command!)
  (chat-snap-to-input!)
  ;; a command can change the model the rich view draws (a send, a card,
  ;; the verbosity); a key that only types leaves it as it was
  (unless (member (editing--command-name) chat-view-input-commands)
    (chat-view-sync! (current-buffer))))

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
    ("s-RET" "chat-send-new")
    ("C-g" "chat-abort")
    ("TAB" "agent-toggle-fold")
    ("<up>" "chat-history-previous")
    ("<down>" "chat-history-next")
    ("C-c C-y" "agent-permission-allow")
    ("C-c C-a" "agent-permission-always")
    ("C-c C-n" "agent-permission-deny")
    ("C-c p" "chat-set-permission-mode")
    ("C-c t" "chat-todo")
    ("C-c C-d" "chat-unqueue")
    ("C-c C-v" "chat-toggle-view")))

;;; --- the spawn edge -----------------------------------------------------------
;;;
;;; A spawned chat and the chat that spawned it name each other. The edge
;;; lives where group parentage already lives: the group record, in the
;;; record's extension slot. It is durable for the same reason a group's
;;; parent is: the record outlives every buffer in it. A killed child
;;; stays findable, and a killed parent still answers for its children.
;;; The buffer-locals are a cache over this store, never a second copy of
;;; the truth.
;;;
;;; One slot per parent: (PARENT-SLUG STATE CHILD-SLUG ...), children
;;; newest last. STATE is live until the parent chat is killed and gone
;;; after. A child is never killed with its parent.

(domain! 'chat)
(effects! '(pure))

(define *subagent-setting* 'subagents)

(define (subagent-slot-parent slot) (nth 0 slot))
(define (subagent-slot-state slot) (nth 1 slot))
(define (subagent-slot-children slot) (cdr (cdr slot)))

(effects! '(read))

;; a chat names itself by buffer or by slug, the way agent-continue! reads
;; a thread. A killed chat has only its slug left, and the slug is what
;; the store is keyed by.
(define (subagent-slug chat)
  (and (string? chat)
       (or (and (buffer-exists? chat) (agent-slug-of chat)) chat)))

;; the chat that owns this eval. An agent calling over the eval door runs
;; inside with-edit-author agent:SLUG, the same signal jj.scm reads to
;; name a change's author.
(define (subagent-spawner)
  (let ((author (current-edit-author)))
    (and (agent-edit-author? author)
         (let ((slug (substring author 6 (string-length author))))
           (and (not (equal? slug "")) slug)))))

(define (subagent-slots g)
  (let ((held (group-setting g *subagent-setting*)))
    (if (pair? held) held '())))

;; Which group record holds a slot is an accident of where the spawn
;; happened, and a chat can move group afterwards, so a reader scans the
;; records rather than guessing one. -> (GROUP SLOT)
(define (subagent-find-slot pick)
  (let loop ((ids (group-ids)))
    (if (null? ids)
        #f
        (let scan ((slots (subagent-slots (car ids))))
          (cond ((null? slots) (loop (cdr ids)))
                ((pick (car slots)) (list (car ids) (car slots)))
                (else (scan (cdr slots))))))))

(define (subagent-slot-of slug)
  (and slug
       (subagent-find-slot
         (lambda (slot) (equal? (subagent-slot-parent slot) slug)))))

(define (subagent-parent-slot-of slug)
  (and slug
       (subagent-find-slot
         (lambda (slot) (member slug (subagent-slot-children slot))))))

(define (subagent-parent chat)
  (let ((found (subagent-parent-slot-of (subagent-slug chat))))
    (and found (subagent-slot-parent (nth 1 found)))))

(define (subagent-children chat)
  (let ((found (subagent-slot-of (subagent-slug chat))))
    (if found (subagent-slot-children (nth 1 found)) '())))

;; #t when CHAT spawned children and CHAT itself is gone
(define (subagent-gone? chat)
  (let ((found (subagent-slot-of (subagent-slug chat))))
    (and found (equal? (subagent-slot-state (nth 1 found)) "gone"))))

(effects! '(write))

;; the buffer-locals are a cache: written from the store, read by nobody
;; above, and rebuildable at any time.
(define (subagent-cache-rebuild! chat)
  (let* ((slug (subagent-slug chat))
         (here (and (string? chat) (buffer-exists? chat) chat))
         (buf (or here
                  (and slug (let ((b (agent-buf slug)))
                              (and b (buffer-exists? b) b))))))
    (when buf
      (buffer-set-local! buf 'subagent-parent (subagent-parent slug))
      (buffer-set-local! buf 'subagent-children (subagent-children slug)))
    slug))

(define (subagent-slot-put! g slot)
  (with-group-records-lock (lambda ()
    (let ((rest (filter
                  (lambda (s) (not (equal? (subagent-slot-parent s)
                                           (subagent-slot-parent slot))))
                  (subagent-slots g))))
      (group-setting-set! g *subagent-setting* (append rest (list slot)))))))

;; record PARENT -> CHILD. -> the group holding the edge, or #f when the
;; parent chat is not here to give the edge a durable home.
(define (subagent-record! parent child)
  (let* ((pslug (subagent-slug parent))
         (cslug (subagent-slug child))
         (named (and pslug (agent-buf pslug)))
         (buf (and named (buffer-exists? named) named)))
    (and pslug cslug (not (equal? pslug cslug)) buf
         ;; sibling chats record at once: read the slot and write it back
         ;; under one lock, or one sibling's edge replaces the other's
         (let ((home (with-group-records-lock (lambda ()
                       (let* ((found (subagent-slot-of pslug))
                              (home (if found (car found) (group-ensure! buf)))
                              (slot (if found (nth 1 found) (list pslug "live")))
                              (kids (subagent-slot-children slot)))
                         (when (and home (not (member cslug kids)))
                           (subagent-slot-put! home
                             (append (list pslug (subagent-slot-state slot))
                                     kids (list cslug))))
                         home)))))
           (and home
                (begin
                  (subagent-cache-rebuild! pslug)
                  (subagent-cache-rebuild! cslug)
                  ;; the parent counts its children in its header line
                  (when (boundp 'dashboard--sync!) (dashboard--sync! buf))
                  home))))))

;; The kill seam (groups.scm group-buffer-kill-repair) calls this for
;; every buffer, while the buffer can still answer for itself. Only a
;; chat with a slot has anything to say: the slot stays, the children keep
;; running, and the state records that the parent is gone.
(define (subagent-chat-killed! name)
  (let* ((slug (and (string? name) (buffer-exists? name) (agent-slug-of name)))
         (found (and slug (subagent-slot-of slug)))
         (parent (and slug (subagent-parent slug)))
         (pbuf (and parent (subagent-live-buffer parent))))
    (when found
      (with-group-records-lock (lambda ()
        (let ((found (subagent-slot-of slug)))
          (when found
            (subagent-slot-put! (car found)
              (append (list slug "gone")
                      (subagent-slot-children (nth 1 found)))))))))
    ;; the parent counts its children in its header line, and the child is
    ;; still here while it dies: count again once the kill is done
    (when (and pbuf (boundp 'dashboard--sync!))
      (task-run! (lambda () #t) (lambda (ok? v) (dashboard--sync! pbuf))))))

(category! 'chat)

(public! 'subagent-parent
  "(subagent-parent CHAT) -> the durable slug of the chat that spawned CHAT, or #f; CHAT is a buffer name or a slug")
(public! 'subagent-children
  "(subagent-children CHAT) -> the slugs of the chats CHAT spawned, newest last")
(public! 'subagent-gone?
  "(subagent-gone? CHAT) -> #t when CHAT spawned children and CHAT itself has been killed")
(public! 'subagent-record!
  "(subagent-record! PARENT CHILD) - record the spawn edge in PARENT's group record; returns the group")
(public! 'subagent-cache-rebuild!
  "(subagent-cache-rebuild! CHAT) - put CHAT's subagent-parent and subagent-children locals back from the store")
(catalog-meta! 'function "subagent-parent" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-children" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-gone?" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-record!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "subagent-cache-rebuild!" 'domain 'chat 'effects '(write))

;;; --- the result ---------------------------------------------------------------
;;;
;;; A child reports STRUCTURALLY. (subagent-result CHAT) reads the child's
;;; own transcript and costs the parent nothing at all: no turn, no tokens,
;;; no context. A fan-out of ten children therefore costs ten turns, not
;;; twenty, and the parent reads the answers when it wants them.
;;;
;;; A free-text wake is the exception, not the rule. 'notify #t on the spawn
;;; asks for one: when a turn of that child ends, the parent is sent a
;;; message with agent-continue!, which does cost the parent a turn.
;;;
;;; The turn-end hook (agent.scm) is what makes any of this work. It fires
;;; on the :ui lane after the child's transcript has landed, so the last
;;; assistant message a listener reads is the finished one.

(domain! 'chat)
(effects! '(read))

;; how much of a reply the log keeps when it has no RESULT paragraph
(define *subagent-log-tail* 400)

(define (subagent-live-buffer chat)
  (let* ((slug (subagent-slug chat))
         (buf (and slug (agent-buf slug))))
    (and buf (buffer-exists? buf) buf)))

;; a turn is in flight. A chat with no runtime at all is not running.
(define (subagent-running? chat)
  (let ((slug (subagent-slug chat)))
    (if (and slug
             (member slug (agent-list))
             (member (agent-status slug) '(running starting needs_attention)))
        #t
        #f)))

;; the child's last assistant message, from the conversation of record --
;; not from the rendered transcript, which carries tool cards and meta
;; lines the parent has no use for.
(define (subagent-last-assistant chat)
  (let ((buf (subagent-live-buffer chat)))
    (and buf
         ;; newest first; stop at the user's words that began this turn, so an older reply never answers
         (let loop ((rs (chat-record buf)))
           (cond ((null? rs) #f)
                 ((equal? (plist-get (car rs) 'role) "assistant") (chat-turn-display (car rs)))
                 ((and (equal? (plist-get (car rs) 'role) "user")
                       (not (equal? (chat-turn-display (car rs)) "")))
                  #f)
                 (else (loop (cdr rs))))))))

(define *subagent-logs-setting* 'subagent-logs)

(define (subagent-edge-group slug)
  (let ((found (subagent-parent-slot-of slug)))
    (and found (car found))))

(define (subagent-logs g)
  (let ((held (group-setting g *subagent-logs-setting*)))
    (if (pair? held) held '())))

(define (subagent-log-entries slug)
  (let* ((g (subagent-edge-group slug))
         (row (and g (assoc slug (subagent-logs g)))))
    (if row (cdr row) '())))

(define (subagent-log-append! slug kind text)
  (let ((g (subagent-edge-group slug)))
    (when g
      (with-group-records-lock (lambda ()
        (let ((others (filter (lambda (row) (not (equal? (car row) slug)))
                              (subagent-logs g)))
              (entry (list (current-time) kind text)))
          (group-setting-set! g *subagent-logs-setting*
            (append others
                    (list (cons slug (append (subagent-log-entries slug) (list entry))))))))))))

(define (subagent-result-paragraph text)
  (let ((paras (filter (lambda (p) (string-prefix? "RESULT:" p))
                       (map string-trim (string-split text "\n\n")))))
    (and (pair? paras) (car (reverse paras)))))

(define (subagent-log-paragraph slug)
  (let* ((said (or (subagent-last-assistant slug) ""))
         (n (string-byte-length said)))
    (or (subagent-result-paragraph said)
        (if (> n *subagent-log-tail*)
            (substring-bytes said (- n *subagent-log-tail*) n)
            said))))

(define (subagent-verdict-of slug)
  (let loop ((es (reverse (subagent-log-entries slug))))
    (cond ((null? es) #f)
          ((eq? (nth 1 (car es)) 'verdict)
           (let* ((text (nth 2 (car es)))
                  (cut (string-index text ": ")))
             (list (substring-bytes text 0 cut)
                   (substring-bytes text (+ cut 2) (string-byte-length text)))))
          (else (loop (cdr es))))))

(define (subagent-todo-set! buf line target)
  (let loop ((n 0))
    (let ((state (morg-toggle-todo-at! buf (with-current-buffer buf (lambda () (line-start-position line))))))
      (cond ((equal? state target) state)
            ((>= n 2) #f)
            (else (loop (+ n 1)))))))

(define (subagent-todo-note! buf line slug verdict summary)
  (markdown-insert-after! buf line
    (string-append "Result: " summary " [" slug "]"))
  (subagent-todo-set! buf line (if (eq? verdict 'done) "DONE" "TODO")))

(define (subagent-verdict! child verdict summary &optional opts)
  (let* ((slug (subagent-slug child))
         (opts (or opts '()))
         (todo (plist-get opts 'todo))
         (reply (plist-get opts 'message))
         (hits (and todo (markdown-find (car todo) (cadr todo)))))
    (unless (memq verdict '(done again wait))
      (error "subagent-verdict!: VERDICT is done, again, or wait" verdict))
    (unless (subagent-edge-group slug)
      (error "subagent-verdict!: no spawn edge for" slug))
    (when (and todo (null? hits))
      (error "subagent-verdict!: no heading" (cadr todo)))
    (when (and (eq? verdict 'again) (not reply))
      (error "subagent-verdict!: again needs 'message"))
    (subagent-log-append! slug 'verdict
      (string-append (symbol->string verdict) ": " summary))
    (when todo
      (subagent-todo-note! (car todo) (car (car hits)) slug verdict summary))
    (when (eq? verdict 'again)
      (agent-continue! slug reply))
    (when (eq? verdict 'done)
      (subagent-archive! slug))
    (subagent-status-of slug)))

;; A child marked done is put away: its runtime stops, its buffer goes, its
;; file stays. The path rides on the edge log so chat-open-children can
;; bring it back.
(define (subagent-archive! slug)
  (let ((buf (subagent-live-buffer slug)))
    (when buf
      (when (boundp 'chat-log-save!) (ignore-errors (lambda () (chat-log-save! buf))))
      (let ((path (ignore-errors (lambda () (chat-log-path buf)))))
        (when (string? path) (subagent-log-append! slug 'archived path)))
      (agents-archive! buf))))

(define (subagent-archived-path chat)
  (let loop ((es (reverse (subagent-log-entries (subagent-slug chat)))))
    (cond ((null? es) #f)
          ((eq? (nth 1 (car es)) 'archived) (nth 2 (car es)))
          (else (loop (cdr es))))))

;; Every child of CHAT as a buffer: an archived one is read back as the chat
;; list reads a saved chat; its header brings the parent link back.
(define (chat-open-children &optional chat)
  (let* ((parent (or chat (current-buffer))) (g (frame-group)))
    (filter (lambda (b) b)
      (map (lambda (c)
             (or (subagent-live-buffer c)
                 (let ((path (subagent-archived-path c)))
                   (and path
                        (let* ((buf (visit-in-group path g))
                               (title (and buf (buffer-local buf 'chat-title))))
                          (when (and (string? title) (not (equal? title "")))
                            (chat-title buf title))
                          buf)))))
           (subagent-children parent)))))

(define-command "chat-open-children" "Read the archived children of this chat back, under it"
  (lambda ()
    (let ((bs (chat-open-children)))
      (message (string-append (number->string (length bs)) " children open")))))

(effects! '(destroy))

;; Killing a chat kills the chats it spawned, and theirs. The quiet ones go
;; with it; when one is busy -- a turn in flight, or waiting on you -- the
;; kill asks first, and no kills only the parent. Each child is archived, so
;; restoring the parent reads it back (chat-open-children).
(define (subagent-live-descendants chat)
  (apply append
    (map (lambda (c)
           (let ((b (subagent-live-buffer c)))
             (if b (cons b (subagent-live-descendants c)) '())))
         (subagent-children chat))))

(define (subagent-kill-confirm! next target done)
  (let* ((kids (if (and (buffer-known? target) (chat-buffer? target))
                   (subagent-live-descendants target)
                   '()))
         (busy (filter (lambda (b) (memq (subagent-status-of b) '(running wait))) kids))
         (alone! (lambda () (next target done)))
         ;; the children go only once the parent did: a kill declined
         ;; further in (unsaved text, the group's last buffer) keeps them
         (with-kids! (lambda ()
                       (next target
                             (lambda (killed?)
                               (when killed?
                                 (for-each (lambda (b)
                                             (when (buffer-known? b)
                                               (subagent-archive! (subagent-slug b))))
                                           kids))
                               (when done (done killed?)))))))
    (cond ((null? kids) (alone!))
          ((null? busy) (with-kids!))
          (else
           (y-or-n (string-append "Kill " (number->string (length kids))
                                  " children too? (" (number->string (length busy)) " busy)")
                   with-kids! alone!)))))

(advice-add! 'kill-buffer-confirm! 'around 'subagent-children
  (lambda (next target done) (subagent-kill-confirm! next target done)))

(effects! '(read))

(define (subagent-log chat)
  (subagent-log-entries (subagent-slug chat)))

;; THE reply shape. A plist, because one caller reads one field and a list
;; view reads another:
;;   'slug        the child's durable id
;;   'buffer      its chat buffer, or #f when the chat is gone
;;   'status      running | stopped | done | idle | gone
;;   'stop-reason the backend's own word for how the last turn ended
;;   'result      what the orchestrator recorded with subagent-verdict! 'done, or #f
;;   'text        the child's last assistant message, empty when it said nothing
(define (subagent-result chat)
  (let* ((slug (subagent-slug chat))
         (buf (subagent-live-buffer chat))
         (ended (and buf (buffer-local buf 'subagent-turn-end)))
         (verdict (subagent-verdict-of slug)))
    (list 'slug slug
          'buffer buf
          'status (subagent-status-of chat)
          'stop-reason (and ended (nth 0 ended))
          'result (and verdict (equal? (car verdict) "done") (cadr verdict))
          'text (or (subagent-last-assistant chat) ""))))

;; CHATS is one chat or a list of them; the answers come back in that order.
(define (subagent-collect chats)
  (map subagent-result (if (pair? chats) chats (list chats))))

;; A turn end is only stopped; done and wait come from subagent-verdict!, and a later turn end leaves them.
(define (subagent-status-of chat)
  (let* ((slug (subagent-slug chat))
         (buf (subagent-live-buffer chat))
         (said (let ((v (subagent-verdict-of slug))) (and v (car v)))))
    (cond ((equal? said "done") 'done)
          ((not buf) 'gone)
          ((subagent-running? slug) 'running)
          ((equal? said "wait") 'wait)
          ((buffer-local buf 'subagent-turn-end) 'stopped)
          (else 'idle))))

(define (subagent-done? chat)
  (eq? (subagent-status-of chat) 'done))

(define (subagent-stopped? chat)
  (and (memq (subagent-status-of chat) '(stopped wait done gone)) #t))

(define (subagent-mark-done! chat result)
  (subagent-verdict! chat 'done result))

(effects! '(write))

;;; --- waiting ------------------------------------------------------------------
;;;
;;; Non-blocking, the way every other slow thing here is: the caller hands
;;; over a continuation and gets its lane back. A caller that wants the
;;; answer inside ONE eval wraps it in the async lane we already have:
;;;
;;;   (let ((token (eval-defer!)))
;;;     (subagent-wait (subagent-children (agent-slug-of (current-buffer)))
;;;       (lambda (results) (eval-resolve! token (value->string results)))))

(define *subagent-waiters* '())   ; ((pending all k) ...)

(define (subagent-waiters-note! slug)
  (let loop ((ws *subagent-waiters*) (keep '()) (fire '()))
    (if (null? ws)
        (begin
          (set! *subagent-waiters* (reverse keep))
          (for-each
            (lambda (w)
              (unless (ignore-errors
                        (lambda () ((nth 2 w) (subagent-collect (nth 1 w))) #t))
                (message "a subagent-wait callback failed")))
            (reverse fire)))
        (let* ((w (car ws))
               (pending (remove (lambda (s) (equal? s slug)) (nth 0 w))))
          (if (null? pending)
              (loop (cdr ws) keep (cons w fire))
              (loop (cdr ws) (cons (list pending (nth 1 w) (nth 2 w)) keep) fire))))))

;; call K with (subagent-collect CHATS) once every one of them has reached a
;; turn end. Answers at once when they all have. -> 'done or 'waiting.
(define (subagent-wait chats k)
  (let* ((all (map subagent-slug (if (pair? chats) chats (list chats))))
         (pending (filter (lambda (s) (not (subagent-stopped? s))) all)))
    (if (null? pending)
        (begin (k (subagent-collect all)) 'done)
        (begin
          (set! *subagent-waiters* (cons (list pending all k) *subagent-waiters*))
          'waiting))))

;;; --- the wake -----------------------------------------------------------------

(define (subagent-wake-text slug ok? stop-reason)
  (let* ((result (subagent-result-paragraph (or (subagent-last-assistant slug) "")))
         (head (and result (car (string-split result "\n")))))
    (string-append
      "[subagent " slug
      (if ok? " finished its turn" (string-append " ended with " stop-reason))
      "]\n"
      (if head (string-append head "\n") "")
      "The log: (subagent-log " (value->string slug) ")")))

(define (subagent-notify-parent! slug ok? stop-reason)
  (let* ((buf (subagent-live-buffer slug))
         (wanted (and buf (buffer-local buf 'subagent-notify)))
         (parent (and wanted (subagent-parent slug)))
         (pbuf (and parent (subagent-live-buffer parent))))
    (when pbuf
      (agent-continue! pbuf (subagent-wake-text slug ok? stop-reason)))))

;; One listener for the whole subsystem. EVERY chat records its own last
;; turn end, not only a child: a waiter has to be able to ask about a chat
;; nobody spawned.
(define (subagent-turn-end! slug stop-reason ok?)
  (let ((buf (subagent-live-buffer slug)))
    (when buf
      (buffer-set-local! buf 'subagent-turn-end (list stop-reason ok?))))
  (subagent-log-append! slug 'turn-end
    (string-append stop-reason ": " (subagent-log-paragraph slug)))
  (subagent-notify-parent! slug ok? stop-reason)
  (subagent-waiters-note! slug))

;; by name, not by value: a reload then reaches the new procedure
(add-hook! (list 'agent-turn-end "subagents")
  (lambda (slug stop-reason ok?) (subagent-turn-end! slug stop-reason ok?)))

;; after the subagent listener, which reads the chat before a finish kills it
(add-hook! (list 'agent-turn-end "chat-finish")
  (lambda (slug stop-reason ok?) (chat-finish-turn-end! slug stop-reason ok?)))

(category! 'chat)

(public! 'subagent-result
  "(subagent-result CHAT) -> a plist of 'slug 'buffer 'status 'stop-reason 'result 'text, read from CHAT's own transcript; it costs the reader no LLM turn")
(public! 'subagent-collect
  "(subagent-collect CHATS) -> one subagent-result per chat, in the order given; CHATS is one chat or a list")
(public! 'subagent-wait
  "(subagent-wait CHATS K) - call K with (subagent-collect CHATS) once every one of them has reached a turn end; returns 'done or 'waiting and never blocks")
(public! 'subagent-done?
  "(subagent-done? CHAT) -> #t when the orchestrator marked CHAT done")
(public! 'subagent-stopped?
  "(subagent-stopped? CHAT) -> #t when CHAT's last turn ended, or it is done or gone")
(public! 'chat-open-children
  "(chat-open-children [CHAT]) -> the children of CHAT as buffers, the archived ones read back under CHAT")
(catalog-meta! 'function "chat-open-children" 'domain 'chat 'effects '(write display))
(public! 'bulk-handover!
  "(bulk-handover! JOB) -> start the chats of an orchestrator's job; the answers reach the orchestrator as one message")
(catalog-meta! 'function "bulk-handover!" 'domain 'chat 'effects '(write spend))
(public! 'subagent-mark-done!
  "(subagent-mark-done! CHAT RESULT) -> the status after marking CHAT done")
(public! 'subagent-status-of
  "(subagent-status-of CHAT) -> gone | running | done | stopped | idle")
(public! 'subagent-last-assistant
  "(subagent-last-assistant CHAT) -> the text of CHAT's last assistant message, or #f")
(catalog-meta! 'function "subagent-result" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-collect" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-wait" 'domain 'chat 'effects '(write))

;; Bulk handover. Each buffer's own chat, the one M-o opens, works that buffer,
;; and is reused when it exists, so a case keeps one chat and its history
;; however often it is handed over; a chat mid-turn is left alone. An answered
;; chat stops its process but stays, and the next handover wakes it. One orchestrator reports: it is
;; woken once, when every case is in, so it spends a single turn.
(define (bulk-agents--report results skipped opts)
  (string-append
    "These chats each worked one case. For every one that answered, eval (subagent-verdict! SLUG 'done ONE-LINE) "
    "for all of them in one eval: marking it done stops its process and archives the chat, with its history. "
    "Leave one that is stuck or asks something.\n\n"
    "Then reply once: " (or (plist-get opts 'report) "a table of case, your call, why in one line")
    ". After it, list the chats you left open"
    (if (null? skipped) "." ", and these, skipped because they were already working: ")
    (string-join skipped ", ")
    "\n\n"
    (string-join
      (map (lambda (r)
             (string-append "- " (or (plist-get r 'buffer) "?") " (" (or (plist-get r 'slug) "?") "): "
                            (let ((t (plist-get r 'text))) (if (equal? t "") "(no answer)" t))))
           results)
      "\n")))

(define *bulk-jobs* '())

;; The orchestrator starts at once, with the job in its prompt, and hands the
;; cases over itself: it evals (bulk-handover! SLUG), which spawns the children.
(define (bulk-agents! bufs opts)
  (let* ((title (or (plist-get opts 'title) "Orchestrate"))
         (noun (or (plist-get opts 'noun) "items"))
         (rules (plist-get opts 'rules))
         (q "\"")
         (ids (map (lambda (b) (or (ats-case-id b) b)) bufs))
         (n (number->string (length bufs))))
    ;; the orchestrator spawns the subagents itself; its prompt carries the ids and the exact code
    (subagent-live-buffer
      (execute* (string-append
                  "You orchestrate " n " " noun ". You review none of them yourself. Their ids: " (string-join ids ", ") ".\n\n"
                  "1. Now spawn one subagent per id with this single eval, then end your turn:\n"
                  "(for-each (lambda (id) (execute* (string-append (chat-opening-prompt (ats-case-buffer id))"
                  (if (string? rules) (string-append " " q " " rules q) "")
                  ") (list 'title (ats-case-buffer id) 'notify #t))) (list "
                  (string-join (map (lambda (id) (string-append q id q)) ids) " ") "))\n"
                  "(execute* PROMPT OPTS) starts a subagent chat with PROMPT and returns its slug at once; 'notify #t wakes you each time one answers. "
                  "(ats-case-buffer ID) is the buffer holding that approval's page, and (chat-opening-prompt BUF) is its prompt, with the id and how to read the page.\n\n"
                  "2. Each answer wakes you. Until all " n " have answered, end your turn and say nothing.\n\n"
                  "3. When all have answered, mark every one that answered in one eval: (subagent-verdict! SLUG 'done ONE-LINE). "
                  "That stops it and archives its chat with its history. Leave one that is stuck or asks something.\n\n"
                  "4. Then reply once: " (or (plist-get opts 'report) "a table of id, your call, why in one line")
                  ". After it, list the subagents you left open.")
                (list 'title title 'model (plist-get opts 'model))))))

(define (bulk-handover! job-id)
  (let* ((job (assoc job-id *bulk-jobs*))
         (bufs (nth 1 job)) (opts (nth 2 job)) (g (nth 3 job)) (slug (nth 4 job))
         (rules (plist-get opts 'rules))
         (orch (subagent-live-buffer slug))
         (pairs (map (lambda (b) (cons b (llm-companion-ensure! b g))) bufs))
         ;; a chat made just now is starting up, not busy
         (busy? (lambda (p) (let ((s (buffer-local (cadr p) 'agent-slug)))
                              (and (not (caddr p)) s (subagent-running? s)))))
         (work (filter (lambda (p) (not (busy? p))) pairs))
         (skipped (map cadr (filter busy? pairs))))
    (set! *bulk-jobs* (filter (lambda (j) (not (equal? (car j) job-id))) *bulk-jobs*))
    (if (null? work)
        "every case is already being worked"
        (begin
          (for-each
            (lambda (p)
              (let* ((chat (cadr p))
                     (ask (or (chat-opening-prompt (car p))
                              "Brief me on this: where it stands, what's open, and the next step you'd take.")))
                (subagent-record! slug chat)
                ;; an earlier turn's end, or an earlier run's done, must not count as this one's
                (buffer-set-local! chat 'subagent-turn-end #f)
                (when (subagent-verdict-of (subagent-slug chat))
                  (subagent-log-append! (subagent-slug chat) 'verdict "again: handed over again"))
                (agent-continue! chat (if (string? rules) (string-append ask "\n\n" rules) ask))))
            work)
          (subagent-wait (map cadr work)
            (lambda (results) (agent-continue! orch (bulk-agents--report results skipped opts))))
          (string-append "handed " (number->string (length work))
                         (if (null? skipped) "" (string-append ", " (number->string (length skipped)) " already working")))))))

(public! 'bulk-agents!
  "(bulk-agents! BUFS OPTS) — each buffer's own chat (the one M-o opens, reused if it exists) works it; one orchestrator stops the answered chats (they keep their page and history) and reports once all are in. OPTS: 'group (default: the current buffer's) 'title 'model (the orchestrator's) 'rules (added to every case) 'report (what the reply shows)")
(catalog-meta! 'function "bulk-agents!" 'domain 'chat 'effects '(write spend))
(catalog-meta! 'function "subagent-done?" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-stopped?" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-mark-done!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "subagent-status-of" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-last-assistant" 'domain 'chat 'effects '(read))
(public! 'subagent-log "(subagent-log CHILD) - the edge log of a spawned chat, oldest first: (TIME KIND TEXT) entries, KIND turn-end or verdict")
(public! 'subagent-verdict! "(subagent-verdict! CHILD VERDICT SUMMARY [OPTS]) - VERDICT is done, again, or wait; OPTS: 'todo (BUF HEADING) writes a Result line and keyword, 'message TEXT goes to the child on again")
(catalog-meta! 'function "subagent-log" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-verdict!" 'domain 'chat 'effects '(write))


(category! 'chat)

(public! 'execute "(execute \"task\") — spawn a task chat on an ACP backend; returns its slug")

(public! 'execute* "(execute* \"task\" '(connector \"codex\" model \"...\" directory \"/repo/\" title \"Name\" notify #t)) — spawn with config; title names the chat at once; notify #t wakes the spawning chat when a turn of the new one ends")

(define (execute prompt) (execute* prompt '()))

(define (execute--free-name base)
  (let loop ((n 2) (name base))
    (if (and (buffer-known? name) (< n 100))
        (loop (+ n 1) (string-append base "<" (number->string n) ">"))
        name)))

(define (execute* prompt opts)
  ;; agent-next-slug only names the buffer now; the session slug is the
  ;; chat's durable id, assigned by chat-attach-agent!
  (let* ((name (agent-next-slug))
         (title (let ((t (plist-get opts 'title)))
                  (and (string? t) (not (equal? (string-trim t) "")) (string-trim t))))
         ;; 'title names the buffer at birth: the chat never wears *chat:N*,
         ;; so nothing has to rename it
         (buf (if title (execute--free-name title) (agent-chat-buffer name)))
         ;; read before buffer-create, which makes the new chat current
         (spawner-group (buffer-group (current-buffer))))
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
    ;; 'companion BUF: the chat works BUF, and BUF's chat-follow? finds it
    (let ((c (plist-get opts 'companion)))
      (when c (buffer-relate! buf 'companion c)))
    ;; 'notify #t opts into a free-text wake: every turn this chat finishes
    ;; sends a message to the chat that spawned it, which costs that parent
    ;; a turn. The default is silence — the parent reads the child's result
    ;; with (subagent-result SLUG) and spends nothing.
    (when (plist-get opts 'notify)
      (buffer-set-local! buf 'subagent-notify #t))
    ;; the group's own defaults (its 'llm bundle: presets, permission,
    ;; connector, model) land first, as on any new chat in the group; an
    ;; explicit opt still wins. The chat joins its group later, so the
    ;; spawner's group stands in for it here.
    (let ((g (or (buffer-group buf) spawner-group)))
     (when (and g (boundp 'llm-default-bundle-apply!))
      (llm-default-bundle-apply! buf g)
      (let ((ps (plist-get opts 'presets)))
        (when ps (buffer-set-local! buf 'chat-presets ps)))
      (let ((pm (plist-get opts 'permission-mode)))
        (when pm (buffer-set-local! buf 'chat-permission-mode pm)))))
    (chat-task-init! buf name)
    (let* ((bundle (or (let ((g (or (buffer-group buf) spawner-group))) (and g (llm-group-bundle g)))
                       (llm-default-bundle-record)))
           (connector (or (plist-get opts 'connector) (and bundle (plist-get bundle 'connector)) *default-connector*))
           (model (or (plist-get opts 'model)
                      (and bundle (equal? connector (plist-get bundle 'connector)) (plist-get bundle 'model))))
           (slug (chat-attach-agent! buf connector model opts)))
      ;; a spawn is quiet: the child gets its mode on its own buffer, and no
      ;; window, point or focus of the spawner's moves. Interactive callers
      ;; display it themselves.
      (with-current-buffer buf
        (lambda ()
          (set-mode! "chat-mode")
          (end-of-buffer!)))
      ;; a chat born with its title keeps it: the titler and chat-title
      ;; leave a chat with inhibit-retitle alone
      (when title
        (buffer-set-local! buf 'chat-title buf)
        (buffer-set-local! buf 'inhibit-retitle #t))
      ;; the spawner in scope, if there is one: the chat that owns this
      ;; eval. With no parent in scope nothing is recorded and the spawn
      ;; is what it always was.
      (let ((parent (subagent-spawner)))
        (when parent (subagent-record! parent slug)))
      (unless (equal? prompt "")
        (llm-session-send! slug prompt))
      slug)))

(define-command "agent-open" "Prompt for a task and spawn a new agent thread"
  (lambda ()
    (minibuffer-read "Task (empty for blank thread): " '()
      (lambda (task)
        ;; execute is quiet, so the interactive caller is the one that shows
        ;; the new thread — in the other window, never stealing focus
        (let ((slug (execute task)))
          (display-buffer-other-window! (agent-buf slug))
          slug)))))
