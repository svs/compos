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
                (editor-context-preamble buf) (chat-fast-note buf) raw image-note)))
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
                           (let ((result (agent-send-msg! slug
                                           (or (and (boundp 'skill-expand-input)
                                                    (skill-expand-input input))
                                               input))))
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
                                   (agent-echo-queued! slug input)
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
         (pos (or (buffer-local buf 'chat-queued-pos) -1))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length q))
           ;; walked past the oldest queued row: restore the draft this walk
           ;; started from, so the sent-history walk starts from it too,
           ;; not from whatever queued text happens to be showing
           (chat-replace-input! buf (or (buffer-local buf 'chat-queued-draft) ""))
           (buffer-set-local! buf 'chat-queued-pos #f)
           (chat-history-recall! buf dir))
          ((< next -1) #f)
          (else
            (when (= pos -1)
              (buffer-set-local! buf 'chat-queued-draft (chat-input-text buf)))
            (buffer-set-local! buf 'chat-queued-pos (if (= next -1) #f next))
            (chat-replace-input! buf
              (if (= next -1)
                  (or (buffer-local buf 'chat-queued-draft) "")
                  (nth next q)))
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
      ((buffer-local buf 'chat-queued-pos) (chat-queued-recall! buf dir))
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

(define (chat-dismiss--close! buf slug ok?)
  (if ok?
      (begin
        (when (and slug (not (equal? (agent-status slug) 'dead)))
          (llm-session-close! slug))
        (message "chat dismissed"))
      (message "chat run ended unsuccessfully; chat remains dismissed")))

(add-hook! (list 'agent-turn-end 'chat-dismiss)
  (lambda (slug stop-reason ok?)
    (let ((buf (agent-buf slug)))
      (when (buffer-local buf 'chat-dismiss-pending)
        (buffer-set-local! buf 'chat-dismiss-pending #f)
        (chat-dismiss--close! buf slug ok?)))))

(define-command "chat-dismiss"
  "Hide this chat, optionally send a final instruction, and dismiss after the current run"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (agent-slug-of buf))
           (input (string-trim (chat-input-text buf)))
           (running (and slug (member (agent-status slug) '(running starting)))))
      (if (not (chat-dismiss--hide! buf))
          (message "could not hide chat: no other buffer is available")
          (begin
            (when (and slug (not (equal? input "")))
              (chat-clear-input! buf)
              (agent-send-msg! slug input))
            (if running
                (buffer-set-local! buf 'chat-dismiss-pending #t)
                (chat-dismiss--close! buf slug #t))
            (message (if running
                         "chat hidden; dismissing after the current run"
                         "chat dismissed")))))))

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
           (walked (buffer-local buf 'chat-queued-pos))
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
                  (buffer-set-local! buf 'chat-queued-pos #f)
                  (let ((draft (if walked (or (buffer-local buf 'chat-queued-draft) "")
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
  (let ((rest (filter
                (lambda (s) (not (equal? (subagent-slot-parent s)
                                         (subagent-slot-parent slot))))
                (subagent-slots g))))
    (group-setting-set! g *subagent-setting* (append rest (list slot)))))

;; record PARENT -> CHILD. -> the group holding the edge, or #f when the
;; parent chat is not here to give the edge a durable home.
(define (subagent-record! parent child)
  (let* ((pslug (subagent-slug parent))
         (cslug (subagent-slug child))
         (named (and pslug (agent-buf pslug)))
         (buf (and named (buffer-exists? named) named)))
    (and pslug cslug (not (equal? pslug cslug)) buf
         (let* ((found (subagent-slot-of pslug))
                (home (if found (car found) (group-ensure! buf)))
                (slot (if found (nth 1 found) (list pslug "live")))
                (kids (subagent-slot-children slot)))
           (and home
                (begin
                  (unless (member cslug kids)
                    (subagent-slot-put! home
                      (append (list pslug (subagent-slot-state slot))
                              kids (list cslug))))
                  (subagent-cache-rebuild! pslug)
                  (subagent-cache-rebuild! cslug)
                  home))))))

;; The kill seam (groups.scm group-buffer-kill-repair) calls this for
;; every buffer, while the buffer can still answer for itself. Only a
;; chat with a slot has anything to say: the slot stays, the children keep
;; running, and the state records that the parent is gone.
(define (subagent-chat-killed! name)
  (let* ((slug (and (string? name) (buffer-exists? name) (agent-slug-of name)))
         (found (and slug (subagent-slot-of slug))))
    (when found
      (let ((slot (nth 1 found)))
        (subagent-slot-put! (car found)
          (append (list slug "gone") (subagent-slot-children slot)))))))

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

;; how much of a child's own words ride in a free-text wake. Past this the
;; parent is pointed at subagent-result instead of being flooded.
(define *subagent-wake-limit* 4000)

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
         (let loop ((ts (reverse (chat-turns buf))))
           (cond ((null? ts) #f)
                 ((equal? (car (car ts)) "assistant") (nth 1 (car ts)))
                 (else (loop (cdr ts))))))))

;; THE reply shape. A plist, because one caller reads one field and a list
;; view reads another:
;;   'slug        the child's durable id
;;   'buffer      its chat buffer, or #f when the chat is gone
;;   'status      running | done | failed | idle | gone
;;   'stop-reason the backend's own word for how the last turn ended
;;   'text        the child's last assistant message, empty when it said nothing
(define (subagent-result chat)
  (let* ((slug (subagent-slug chat))
         (buf (subagent-live-buffer chat))
         (ended (and buf (buffer-local buf 'subagent-turn-end))))
    (list 'slug slug
          'buffer buf
          'status (cond ((not buf) 'gone)
                        ((subagent-running? slug) 'running)
                        ((not ended) 'idle)
                        ((nth 1 ended) 'done)
                        (else 'failed))
          'stop-reason (and ended (nth 0 ended))
          'text (or (subagent-last-assistant chat) ""))))

;; CHATS is one chat or a list of them; the answers come back in that order.
(define (subagent-collect chats)
  (map subagent-result (if (pair? chats) chats (list chats))))

;; #t when CHAT will not reach another turn end on its own: it finished one,
;; or it is gone. A chat that never ran a turn is NOT done -- nothing has
;; happened to it yet.
(define (subagent-done? chat)
  (let ((buf (subagent-live-buffer chat)))
    (cond ((not buf) #t)
          ((subagent-running? chat) #f)
          ((buffer-local buf 'subagent-turn-end) #t)
          (else #f))))

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
         (pending (filter (lambda (s) (not (subagent-done? s))) all)))
    (if (null? pending)
        (begin (k (subagent-collect all)) 'done)
        (begin
          (set! *subagent-waiters* (cons (list pending all k) *subagent-waiters*))
          'waiting))))

;;; --- the wake -----------------------------------------------------------------

(define (subagent-wake-text slug ok? stop-reason)
  (let* ((said (or (subagent-last-assistant slug) ""))
         (long? (> (string-byte-length said) *subagent-wake-limit*))
         (body (if long? (substring-bytes said 0 *subagent-wake-limit*) said)))
    (string-append
      "[subagent " slug
      (if ok? " finished its turn" (string-append " ended with " stop-reason))
      "]\n"
      (if (equal? (string-trim body) "")
          ""
          (string-append body (if long? "\n[...]" "") "\n"))
      "The whole result is "
      (string-append "(subagent-result " (value->string slug) ")"))))

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
  (subagent-notify-parent! slug ok? stop-reason)
  (subagent-waiters-note! slug))

(add-hook! (list 'agent-turn-end "subagents") subagent-turn-end!)

(category! 'chat)

(public! 'subagent-result
  "(subagent-result CHAT) -> a plist of 'slug 'buffer 'status 'stop-reason 'text, read from CHAT's own transcript; it costs the reader no LLM turn")
(public! 'subagent-collect
  "(subagent-collect CHATS) -> one subagent-result per chat, in the order given; CHATS is one chat or a list")
(public! 'subagent-wait
  "(subagent-wait CHATS K) - call K with (subagent-collect CHATS) once every one of them has reached a turn end; returns 'done or 'waiting and never blocks")
(public! 'subagent-done?
  "(subagent-done? CHAT) -> #t when CHAT has finished a turn or is gone")
(public! 'subagent-last-assistant
  "(subagent-last-assistant CHAT) -> the text of CHAT's last assistant message, or #f")
(catalog-meta! 'function "subagent-result" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-collect" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-wait" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "subagent-done?" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "subagent-last-assistant" 'domain 'chat 'effects '(read))


(category! 'chat)

(public! 'execute "(execute \"task\") — spawn a task chat on an ACP backend; returns its slug")

(public! 'execute* "(execute* \"task\" '(connector \"codex\" model \"...\" directory \"/repo/\" notify #t)) — spawn with config; notify #t wakes the spawning chat when a turn of the new one ends")

(define (execute prompt) (execute* prompt '()))

(define (execute* prompt opts)
  ;; agent-next-slug only names the buffer now; the session slug is the
  ;; chat's durable id, assigned by chat-attach-agent!
  (let* ((name (agent-next-slug))
         (buf (agent-chat-buffer name)))
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
    ;; 'notify #t opts into a free-text wake: every turn this chat finishes
    ;; sends a message to the chat that spawned it, which costs that parent
    ;; a turn. The default is silence — the parent reads the child's result
    ;; with (subagent-result SLUG) and spends nothing.
    (when (plist-get opts 'notify)
      (buffer-set-local! buf 'subagent-notify #t))
    (chat-task-init! buf name)
    (let ((slug (chat-attach-agent! buf
                  (or (plist-get opts 'connector) *default-connector*)
                  (plist-get opts 'model)
                  opts)))
      ;; a spawn is quiet: the child gets its mode on its own buffer, and no
      ;; window, point or focus of the spawner's moves. Interactive callers
      ;; display it themselves.
      (with-current-buffer buf
        (lambda ()
          (set-mode! "chat-mode")
          (end-of-buffer!)))
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
