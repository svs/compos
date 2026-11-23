;;; chat-surface.scm --- one chat interface for every kind of chat.
;;;
;;; A chat is a transcript that keeps to its newest entry and an input at
;;; its foot. The agent chat, a Telegram conversation and any chat after
;;; them share this: the input is the buffer's text after a mark, typed and
;;; edited with every editing key; <up> and <down> walk what you sent; RET
;;; hands the input to the chat's send; M-> and M-< go to the newest and
;;; the first entry; M-<up> and M-<down> step through the entries; a key
;;; that types brings a transcript read away from the bottom back to it.
;;;
;;; A chat kind injects only its format and its handlers, as one spec:
;;;
;;;   (chat-surface! BUF
;;;     (list 'mark 'LOCAL         ; the local that holds where the input starts
;;;           'draw (lambda (buf) ...)  ; the format: (head ITEMS items ITEMS
;;;                                     ;   above ITEMS prompt PROPS class CLASS)
;;;           'send (lambda (buf text) ...)  ; RET; it clears the input it took
;;;           ;; optional
;;;           'seed (lambda (buf) ...)  ; past inputs, newest first, for a fresh ring
;;;           'walk (lambda (buf dir) ...)  ; an <up>/<down> walk of its own; #t took it
;;;           'follow (lambda (buf) ...)    ; also run when it follows the newest again
;;;           'top (lambda (buf) ...)       ; also run before it goes to the first entry
;;;           'step (lambda (buf delta) ...); its own M-<up>/M-<down>; #t took it
;;;           'input-skip (lambda (buf) ...)))  ; bytes after the mark before the input
;;;
;;; chat-surface-redraw! draws BUF from its 'draw; chat-surface-transcript
;;; and chat-surface-prompt build the two parts for a kind that draws itself.

(domain! 'chat)
(effects! '(read))

(define *chat-surface-kinds* (if (boundp '*chat-surface-kinds*) *chat-surface-kinds* '()))

(define (chat-surface-spec buf)
  "the spec of BUF's chat: its own, else the one its mode registered as its kind"
  (or (buffer-local-value 'chat-surface buf)
      (let ((k (assoc (buffer-local-value 'mode-name buf) *chat-surface-kinds*)))
        (and k (cdr k)))))

(define (chat-surface-handler buf key)
  (let ((s (chat-surface-spec buf)))
    (and (pair? s) (let ((h (plist-get s key))) (and (procedure? h) h)))))

(define (chat-surface-mark-local buf)
  (let ((s (chat-surface-spec buf)))
    (and (pair? s) (plist-get s 'mark))))

(define (chat-surface? buf)
  "#t when BUF is a chat: it has a spec and its input mark is set"
  (let ((l (chat-surface-mark-local buf)))
    (and l (number? (buffer-local-value l buf)) #t)))

(define (chat-surface-drawn? buf)
  "#t when BUF is a chat drawn as blocks, its input at the foot"
  (and (chat-surface? buf) (equal? (buffer-local-value 'render-mode buf) "blocks")))

;;; --- the input: the buffer's text from the mark on ----------------------------

(effects! '(write))

;; the mark never points past the end: an edit the local did not see (undo,
;; a whole-region replace from the client) could leave it there. A stranded
;; local is written back to the end, so the next key lands in the input.
(define (chat-surface-mark buf)
  (let* ((l (chat-surface-mark-local buf))
         (saved (or (and l (buffer-local-value l buf)) 0))
         (size (buffer-size buf)))
    (if (> saved size)
        (begin (when l (buffer-set-local! buf l size)) size)
        saved)))

(define (chat-surface-input-start buf)
  (let ((skip (chat-surface-handler buf 'input-skip)))
    (min (+ (chat-surface-mark buf) (or (and skip (skip buf)) 0))
         (buffer-size buf))))

(define (chat-surface-input-region buf)
  (list (chat-surface-input-start buf) (buffer-size buf)))

(define (chat-surface-input-text buf)
  (let ((r (chat-surface-input-region buf)))
    (substring-bytes (buffer-text buf) (car r) (cadr r))))

(effects! '(read))
(public! 'chat-surface-input-text
  "(chat-surface-input-text BUF) — the text typed in the input of chat BUF, not yet sent")
(effects! '(write))

(define (chat-surface-clear-input! buf &optional read)
  "Delete the input. READ is the input text as the caller read it: the
input is the tail of the buffer, so those exact bytes go from the end, and
text the chat appended between the read and this delete stays."
  (let ((size (buffer-size buf)))
    (if (and (string? read) (not (equal? read "")) (string-suffix? read (buffer-text buf)))
        (let ((n (string-byte-length read)))
          (buffer-delete-range! buf (- size n) n))
        (let ((r (chat-surface-input-region buf)))
          (buffer-delete-range! buf (car r) (- (cadr r) (car r)))))))

(define (chat-surface-replace-input! buf text)
  (chat-surface-clear-input! buf)
  (with-current-buffer buf (lambda ()
    (end-of-buffer!)
    (unless (equal? text "") (insert! text)))))

(define (chat-surface-in-input? buf)
  (>= (buffer-point buf) (chat-surface-mark buf)))

(define (chat-surface-on-first-input-line? buf)
  (let ((start (chat-surface-input-start buf)) (p (buffer-point buf)))
    (or (<= p start)
        (not (string-contains? (substring-bytes (buffer-text buf) start p) "\n")))))

(define (chat-surface-on-last-input-line? buf)
  (not (string-contains? (substring-bytes (buffer-text buf) (buffer-point buf) (buffer-size buf)) "\n")))

(define (chat-surface-snap!)
  "put point back in the input of a drawn chat when a command left it in the transcript"
  (let ((buf (current-buffer)))
    (when (and (chat-surface-drawn? buf) (< (point) (chat-surface-input-start buf)))
      (end-of-buffer!))))

;;; --- history: what you sent in THIS chat, newest first ------------------------
;;; A chat is a session of its own, the way a shell window is. The ring lives
;;; in memory; a chat with a 'seed fills a fresh ring from its own record.

(define *chat-surface-history-limit* 200)

(define (chat-surface-history buf)
  (or (buffer-local-value 'chat-history-ring buf) '()))

(define (chat-surface-history-set! buf ring)
  (buffer-set-local! buf 'chat-history-ring
    (if (> (length ring) *chat-surface-history-limit*) (list-head ring *chat-surface-history-limit*) ring)))

;; consecutive repeats collapse, the way a shell's history does
(define (chat-surface-history-push! buf text)
  (let ((t (string-trim text)) (h (chat-surface-history buf)))
    (unless (or (equal? t "") (and (pair? h) (equal? t (car h))))
      (chat-surface-history-set! buf (cons t h)))))

(define (chat-surface-history-seed! buf)
  (let ((seed (chat-surface-handler buf 'seed)))
    (when (and seed (null? (chat-surface-history buf)))
      (chat-surface-history-set! buf (or (seed buf) '())))))

(define (chat-surface-history-reset! buf)
  (buffer-set-local! buf 'chat-history-pos #f)
  (buffer-set-local! buf 'chat-history-draft #f)
  (buffer-set-local! buf 'chat-history-prefix #f))

;; What you have typed is the search: up walks only the entries that start
;; with it, as a shell's history search does. The prefix is taken once, when
;; you step off the draft, and held for the walk.
(define (chat-surface-history-for buf prefix)
  (let ((h (chat-surface-history buf)))
    (if (equal? prefix "") h (filter (lambda (s) (string-prefix? prefix s)) h))))

(define (chat-surface-history-prefix-of buf)
  (or (buffer-local-value 'chat-history-prefix buf)
      (let ((prefix (chat-surface-input-text buf)))
        (buffer-set-local! buf 'chat-history-prefix prefix)
        prefix)))

(define (chat-surface-history-recall! buf dir)
  (let* ((prefix (chat-surface-history-prefix-of buf))
         (h (chat-surface-history-for buf prefix))
         (pos (or (buffer-local-value 'chat-history-pos buf) -1))
         (next (if (< dir 0) (+ pos 1) (- pos 1))))
    (cond ((>= next (length h))
           (message (if (equal? prefix "") "no earlier input"
                        (string-append "no earlier input starting with " prefix))))
          ((< next -1) #f)
          (else
            (when (= pos -1)
              (buffer-set-local! buf 'chat-history-draft (chat-surface-input-text buf)))
            (buffer-set-local! buf 'chat-history-pos (if (= next -1) #f next))
            (when (= next -1) (buffer-set-local! buf 'chat-history-prefix #f))
            (chat-surface-replace-input! buf
              (if (= next -1) (or (buffer-local-value 'chat-history-draft buf) "") (list-ref h next)))))))

(define (chat-surface-history-move! dir)
  (let* ((buf (current-buffer))
         (motion (if (< dir 0) "previous-line" "next-line"))
         (walk (chat-surface-handler buf 'walk)))
    (chat-surface-history-seed! buf)
    (cond
      ((or (not (chat-surface? buf))
           (not (chat-surface-in-input? buf))
           ;; inside a multi-line input, up and down are still motion
           (if (< dir 0) (not (chat-surface-on-first-input-line? buf)) (not (chat-surface-on-last-input-line? buf))))
       (run-command motion))
      ((and walk (walk buf dir)) #t)
      ((null? (chat-surface-history buf)) (run-command motion))
      (else (chat-surface-history-recall! buf dir)))))

(define-command "chat-surface-history-previous" "Recall the previous thing you sent in this chat"
  (lambda () (chat-surface-history-move! -1)))
(define-command "chat-surface-history-next" "Recall the next thing you sent in this chat"
  (lambda () (chat-surface-history-move! 1)))

;;; --- editing that never crosses into the transcript ---------------------------

(define (chat-surface-guard? buf p)
  (and (chat-surface? buf) (<= p (chat-surface-input-start buf))))

(define-command "chat-surface-delete-backward" "Delete backward, but never into the transcript"
  (lambda ()
    (if (chat-surface-guard? (current-buffer) (point))
        (message "beginning of input")
        (unless (delete-active-region!) (delete-char! -1)))))

(define-command "chat-surface-delete-forward" "Delete forward, but never the input mark"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (and (chat-surface? buf)
               (>= (point) (chat-surface-mark buf))
               (< (point) (chat-surface-input-start buf)))
          (message "this is the input marker")
          (unless (delete-active-region!) (delete-char! 1))))))

;;; --- send ----------------------------------------------------------------------

(define-command "chat-surface-send" "Send what the input holds to this chat"
  (lambda ()
    (let* ((buf (current-buffer)) (send (chat-surface-handler buf 'send)) (text (chat-surface-input-text buf)))
      (cond ((not send) (message "this chat cannot send"))
            ((equal? (string-trim text) "") (message "type a message first"))
            (else (chat-surface-history-push! buf text)
                  (chat-surface-history-reset! buf)
                  (chat-surface-follow! buf)
                  (send buf text))))))

;;; --- the transcript's place ----------------------------------------------------
;;; The transcript scroller keeps a reader's place of its own, apart from
;;; point: 'follow-place records that the reader left the bottom and the
;;; entry they left it on. Clearing it and bumping 'follow-seq is what makes
;;; a chat follow its newest entry again.

(effects! '(write display))

(define (chat-surface-follow! buf)
  "keep BUF's transcript at its newest entry again"
  (let ((seq (buffer-local-value 'follow-seq buf)) (h (chat-surface-handler buf 'follow)))
    (buffer-set-local! buf 'follow-place #f)
    (buffer-set-local! buf 'chat-surface-nav #f)
    (when h (h buf))
    (buffer-set-local! buf 'follow-seq (+ 1 (if (number? seq) seq 0)))))

(define (chat-surface-away? buf)
  (let ((fp (buffer-local-value 'follow-place buf))) (and (pair? fp) (car fp) #t)))

(define (chat-surface-place! buf index)
  "show entry INDEX of BUF's transcript at the top; #f is the very top"
  (let ((seq (buffer-local-value 'follow-seq buf)))
    (buffer-set-local! buf 'follow-place (list #t 0 index 0))
    (buffer-set-local! buf 'follow-seq (+ 1 (if (number? seq) seq 0)))))

;; the chat under point, else the first one a window shows
(define (chat-surface-target)
  (let ((buf (current-buffer)))
    (if (chat-surface? buf)
        buf
        (let loop ((ws (window-list)))
          (cond ((null? ws) #f)
                ((chat-surface? (cadr (car ws))) (cadr (car ws)))
                (else (loop (cdr ws))))))))

(define-command "chat-surface-to-bottom" "Go to the newest message of this chat, and keep to it"
  (lambda ()
    (let ((buf (chat-surface-target)))
      (if (not buf)
          (message "no chat here")
          (begin
            (with-current-buffer buf (lambda () (end-of-buffer!)))
            (chat-surface-follow! buf)
            (buffer-windows-follow-point! buf))))))

(define-command "chat-surface-to-top" "Go to the first message of this chat"
  (lambda ()
    (let ((buf (chat-surface-target)))
      (if (not buf)
          (message "no chat here")
          (let ((h (chat-surface-handler buf 'top)))
            (with-current-buffer buf (lambda () (beginning-of-buffer!)))
            (when h (h buf))
            (chat-surface-place! buf #f))))))

(define (chat-surface-transcript-count buf)
  (let ((tr (find (lambda (n) (and (pair? n) (equal? (plist-get n 'tag) "c-transcript")))
                  (or (buffer-local-value 'render-blocks buf) '()))))
    (if tr (+ (or (plist-get tr 'index-base) 0) (length (or (plist-get tr 'children) '()))) 0)))

(define (chat-surface-step! buf delta)
  "show the entry DELTA from the one at the top; past the newest it keeps to the newest again"
  (let ((own (chat-surface-handler buf 'step)))
    (unless (and own (own buf delta))
      (let* ((total (chat-surface-transcript-count buf))
             (cur (and (chat-surface-away? buf) (buffer-local-value 'chat-surface-nav buf)))
             (target (+ (if (integer? cur) cur total) delta)))
        (if (>= target total)
            (chat-surface-follow! buf)
            (let ((target (max 0 target)))
              (buffer-set-local! buf 'chat-surface-nav target)
              (chat-surface-place! buf target)))))))

(define-command "chat-surface-previous-entry" "Show the message before at the top"
  (lambda () (chat-surface-step! (current-buffer) -1)))
(define-command "chat-surface-next-entry" "Show the message after at the top"
  (lambda () (chat-surface-step! (current-buffer) 1)))

;; the commands that only type: after them the transcript has not changed
(define chat-surface-input-commands
  '("self-insert-command" "chat-surface-delete-backward" "chat-surface-delete-forward"
    "chat-delete-backward" "chat-delete-forward" "delete-backward-char" "delete-char"
    "newline" "yank"))

(define (chat-surface-type-follows!)
  "a key that types in a chat read away from the bottom brings it back to the newest entry"
  (let ((buf (current-buffer)))
    (when (and (chat-surface-drawn? buf)
               (member (editing--command-name) chat-surface-input-commands)
               (chat-surface-away? buf))
      (chat-surface-follow! buf))))

(add-hook! 'post-command-hook 'chat-surface-type-follows!)
(add-hook! 'pre-command-hook 'chat-surface-snap!)
(add-hook! 'post-command-hook 'chat-surface-snap!)

;;; --- the format: the two parts every chat draws --------------------------------

(effects! '(pure))

(define (chat-surface-transcript items &optional opts)
  "the transcript: ITEMS in a scroller that keeps to the newest one. OPTS: 'class, 'attrs, 'index-base (the index of the first item in the whole transcript), 'before (nodes ahead of the items, such as an earlier-row)"
  (let ((opts (or opts '())))
    (list 'tag "c-transcript"
          'class (string-append "ag-scroll" (let ((c (plist-get opts 'class))) (if c (string-append " " c) "")))
          'isolate #t 'follow #t 'anchor "transcript"
          'attrs (or (plist-get opts 'attrs) '())
          'index-base (or (plist-get opts 'index-base) 0)
          'children (append (or (plist-get opts 'before) '()) items))))

(define (chat-surface-prompt &optional opts)
  "the input row: the buffer's live input with its hint. OPTS: 'class, 'label (a node before it), 'hint, 'after (nodes after it, such as a send button)"
  (let ((opts (or opts '())))
    (list 'tag "c-prompt"
          'class (string-append "ag-inputrow" (let ((c (plist-get opts 'class))) (if c (string-append " " c) "")))
          'children (append (let ((l (plist-get opts 'label))) (if l (list l) '()))
                            (list (list 'tag "c-input" 'class (string-append "ag-input" (let ((c (plist-get opts 'input-class))) (if c (string-append " " c) "")))
                                        'input #t 'hint (or (plist-get opts 'hint) "")))
                            (or (plist-get opts 'after) '())))))

(effects! '(write display))

(define (chat-surface-redraw! buf)
  "draw BUF from its spec's 'draw: (head NODES items NODES above NODES prompt PROPS transcript PROPS class CLASS)"
  (let ((draw (chat-surface-handler buf 'draw)))
    (when (and draw (buffer-exists? buf))
      (let ((f (draw buf)))
        (buffer-set-locals! buf
          (list 'render-mode "blocks"
                'render-root (list 'tag "c-buffer" 'class (string-append "agent-view" (let ((c (plist-get f 'class))) (if c (string-append " " c) ""))))
                'render-input (symbol->string (chat-surface-mark-local buf))
                'render-blocks (append (or (plist-get f 'head) '())
                                       (list (chat-surface-transcript (or (plist-get f 'items) '()) (plist-get f 'transcript)))
                                       (or (plist-get f 'above) '())
                                       (list (chat-surface-prompt (plist-get f 'prompt))))))))))

;;; --- making a buffer a chat ----------------------------------------------------

(effects! '(write))

(define (chat-surface-claim-letters! buf)
  "every plain key another map of BUF binds types into the input instead: a chat in a detail window or a dismissible one"
  (let loop ((maps (buffer-keymaps buf)) (before? #t))
    (when (pair? maps)
      (let ((m (car maps)))
        (cond ((equal? m buf) (loop (cdr maps) #f))
              ((member m '("global" "chat-surface-mode-map")) (loop (cdr maps) before?))
              (else
                (for-each (lambda (b)
                            (when (and (= (string-length (car b)) 1) (string? (cadr b))
                                       (not (string-prefix? "keymap:" (cadr b)))
                                       (not (equal? (cadr b) "self-insert-command")))
                              ;; a map ahead of the buffer's own wins over it: its
                              ;; command types here instead; one behind it loses
                              ;; to a key of the buffer's own
                              (if before?
                                  (local-remap*! buf (cadr b) "self-insert-command")
                                  (local-set-key* buf (car b) "self-insert-command"))))
                          (keymap-bindings m))
                (loop (cdr maps) before?)))))))

(define (chat-surface-kind! mode spec)
  "every buffer of MODE is a chat of the kind SPEC injects, attached or not"
  (set! *chat-surface-kinds* (cons (cons mode spec) (filter (lambda (k) (not (equal? (car k) mode))) *chat-surface-kinds*)))
  mode)

(define (chat-surface-attach! buf spec)
  "give BUF the chat SPEC injects, and nothing else: a kind that draws and keys itself (the agent chat) attaches only its handlers"
  (buffer-set-local! buf 'chat-surface spec)
  buf)

(define (chat-surface! buf spec)
  "make BUF a chat of the kind SPEC injects (see the commentary): its input is the buffer's text from SPEC's 'mark on, drawn and keyed by the shared interface"
  (chat-surface-attach! buf spec)
  (let ((l (plist-get spec 'mark)))
    (unless (number? (buffer-local-value l buf)) (buffer-set-local! buf l 0))
    (buffer-marker-local! buf l 'stay))
  (buffer-set-read-only! buf #f)
  (unless (minor-mode-on? buf "chat-surface-mode") (enable-minor-mode! buf "chat-surface-mode"))
  (chat-surface-claim-letters! buf)
  (chat-surface-redraw! buf)
  buf)

(minor-mode-keys! "chat-surface-mode"
  '(("RET" "chat-surface-send")
    ("S-RET" "newline")
    ("<up>" "chat-surface-history-previous")
    ("<down>" "chat-surface-history-next")
    ("DEL" "chat-surface-delete-backward")
    ("C-d" "chat-surface-delete-forward")
    ("M->" "chat-surface-to-bottom")
    ("M-<" "chat-surface-to-top")
    ("M-<up>" "chat-surface-previous-entry")
    ("M-<down>" "chat-surface-next-entry")))

(mode-doc! "chat-surface-mode"
  "The chat interface every kind of chat shares. Type into the input at the foot: RET sends it, S-RET starts a new line, <up> and <down> walk what you sent here. M-> goes to the newest message and keeps to it, M-< to the first; M-<up> and M-<down> step through the messages. Scroll up to read and the transcript stays; type and it comes back to the newest.")

(provide 'chat-surface)
