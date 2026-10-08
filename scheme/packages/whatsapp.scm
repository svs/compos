;;; whatsapp.scm --- Read and reply to WhatsApp chats through MCP.

(package! "whatsapp")

(domain! 'chat)
(effects! '(write))

(defgroup 'whatsapp "Read and reply to WhatsApp chats through the whatsapp MCP server.")

;; Seconds before the chat list refreshes from WhatsApp.
(define whatsapp-cache-ttl 30)

;; Maximum recent chats to show.
(define whatsapp-chat-limit 30)

;; Maximum recent messages to show in one conversation.
(define whatsapp-message-limit 50)

(define *whatsapp-buffer* "*WhatsApp*")
(defcustom 'whatsapp-group "*WhatsApp*"
  "Group to open WhatsApp in. Uses the exact *WhatsApp* group."
  'group 'whatsapp 'type 'string)
(define *whatsapp-show-buffer* "*WhatsApp conversation*")

(define (whatsapp--join-group! buf)
  (let ((group (frame-group)))
    (when group (buffer-add-group! buf group)))
  buf)
(define *whatsapp-call* mcp-call!)

(domain! 'chat)
(effects! '(pure))

(define (whatsapp--text value fallback)
  (if (and (string? value) (not (equal? value ""))) value fallback))

(define (whatsapp--one-line value)
  (string-join (string-split (whatsapp--text value "") "\n") " "))

(define (whatsapp--parse-chats text)
  (if (not (string? text))
      #f
      (let* ((trimmed (string-trim text))
             (direct (and (not (equal? trimmed "")) (json-parse trimmed))))
        (cond
          ((equal? trimmed "") '())
          ((and (pair? direct) (symbol? (car direct))) (list direct))
          ((or (pair? direct) (null? direct)) direct)
          (else
            (json-parse
              (string-append
                "["
                (string-join (string-split trimmed "}\n{") "},{")
                "]")))))))

(define (whatsapp--from-me? chat)
  (let ((value (plist-get chat 'last_is_from_me)))
    (or (equal? value 1) (equal? value #t))))

(define (whatsapp--cells buf chat)
  (let ((jid (whatsapp--text (plist-get chat 'jid) "unknown")))
    (list
      (whatsapp--text (plist-get chat 'name) jid)
      (whatsapp--text (plist-get chat 'last_message_time) "")
      (string-append
        (if (whatsapp--from-me? chat) "me: " "")
        (whatsapp--one-line (plist-get chat 'last_message))))))

(define (whatsapp--clean-message-body body)
  (cond
    ((string-prefix? "[image - Message ID:" body) "[image]")
    ((string-prefix? "[video - Message ID:" body) "[video]")
    ((string-prefix? "[audio - Message ID:" body) "[audio]")
    ((string-prefix? "[document - Message ID:" body) "[document]")
    (else body)))

;;; The conversation as a tree.
;;;
;;; The transcript the server prints is the source, and it reaches the
;;; buffer as it came. The whatsapp grammar parses it; the rows, the
;;; view, and the motion between messages are three readings of that
;;; one parse. Nothing here scans lines.

(define (whatsapp--node-of kind nodes)
  (let loop ((ns nodes))
    (cond ((null? ns) #f)
          ((equal? (car (car ns)) kind) (car ns))
          (else (loop (cdr ns))))))

(define (whatsapp--slice text node)
  (if node (substring-bytes text (nth 1 node) (nth 2 node)) ""))

(define (whatsapp--msg-start row) (nth 0 row))
(define (whatsapp--msg-end row) (nth 1 row))
(define (whatsapp--msg-time row) (nth 2 row))
(define (whatsapp--msg-sender row) (nth 3 row))
(define (whatsapp--msg-body row) (nth 4 row))
(define (whatsapp--msg-mine? row) (nth 5 row))

;; every message in BUF as (START END TIME SENDER BODY MINE?)
(define (whatsapp--messages buf)
  (let ((text (buffer-text buf)))
    (with-current-buffer buf
      (lambda ()
        (map
          (lambda (node)
            (let* ((parts (ts-children "message" (nth 1 node) (nth 2 node)))
                   (sender
                     (whatsapp--slice text
                       (whatsapp--node-of "sender" parts))))
              (list
                (nth 1 node) (nth 2 node)
                (whatsapp--slice text
                  (whatsapp--node-of "timestamp" parts))
                sender
                (whatsapp--clean-message-body
                  (string-trim
                    (whatsapp--slice text
                      (whatsapp--node-of "body" parts))))
                (equal? sender "Me"))))
          ;; Name the root. One message covers the whole buffer on its
          ;; own, and the smallest node over that range would then be
          ;; the message, not the conversation holding it.
          ;;
          ;; A loading notice or an error is not a transcript, and the
          ;; grammar says so by giving back an error node instead.
          (filter (lambda (node) (equal? (car node) "message"))
                  (ts-children "conversation" 0
                               (string-byte-length text))))))))

;; The message a position stands in. A position past the last one
;; belongs to it: a reader at the end of the buffer is reading the
;; last thing said.
(define (whatsapp--message-at rows pos)
  (let loop ((rs rows) (best #f))
    (cond ((null? rs) best)
          ((> (whatsapp--msg-start (car rs)) pos) best)
          (else (loop (cdr rs) (car rs))))))

(define (whatsapp--current-message buf)
  (and (buffer-derived-mode? buf "whatsapp-chat-mode")
       (whatsapp--message-at (whatsapp--messages buf)
                             (buffer-point buf))))





(define (whatsapp--short-time stamp)
  (if (> (string-byte-length stamp) 15)
      (substring-bytes stamp 5 16)
      stamp))

(define (whatsapp--message-block row current?)
  (component 'ui/row
    (list
      'class
        (string-append
          "whatsapp-message"
          (if (whatsapp--msg-mine? row) " whatsapp-message-me" "")
          (if current? " whatsapp-message-current" ""))
      ;; the node's own start names the row, so a click selects the
      ;; message the same motion keys would
      'click
        (string-append "msg:"
                       (number->string (whatsapp--msg-start row)))
      'segs
        (list
          (list "whatsapp-message-time"
                (whatsapp--short-time (whatsapp--msg-time row)))
          (list "whatsapp-message-sender"
                (string-append "  " (whatsapp--msg-sender row)))
          ;; the body is its own block in the grid, so it needs no
          ;; newline of its own
          (list "whatsapp-message-body" (whatsapp--msg-body row))))))

;; WhatsApp's own reply carries the message it answers. This transport
;; has no field for one, so the quote goes into the text — the reader
;; on the other end still sees what was answered.
(define (whatsapp--quote row)
  (let loop ((words (string-split
                      (whatsapp--one-line (whatsapp--msg-body row)) " "))
             (kept '()) (width 0))
    (if (or (null? words) (> width 120))
        (string-append
          "> " (whatsapp--msg-sender row) ": "
          (string-join (reverse kept) " ")
          (if (null? words) "" " …")
          "\n")
        (loop (cdr words) (cons (car words) kept)
              (+ width 1 (string-byte-length (car words)))))))

(define (whatsapp--conversation-blocks rows current notice)
  (cons
    (component 'ui/actions
      (list 'class "whatsapp-actions"
            'actions
              '(("whatsapp-reply" "Reply" "r")
                ("whatsapp-refresh" "Refresh" "g"))))
    (if (pair? rows)
        (map (lambda (row)
               (whatsapp--message-block row
                 (and current
                      (= (whatsapp--msg-start row)
                         (whatsapp--msg-start current)))))
             rows)
        (list
          (component 'ui/empty
            (list 'class "whatsapp-empty"
                  'text
                    (if (and (string? notice)
                             (not (equal? (string-trim notice) "")))
                        (string-trim notice)
                        "No messages.")))))))



(define (whatsapp--conversation-buffer jid)
  *whatsapp-show-buffer*)



(domain! 'chat)
(effects! '(write))

(define (whatsapp--replace-text! buf text)
  (let ((p (buffer-point buf)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf text)
    (buffer-goto! buf (min p (buffer-size buf)))))

;; The view is a projection of the tree, rebuilt from the buffer text
;; every time. Nothing about a message is kept anywhere else, so the
;; blocks a reader sees and the text the grammar read cannot drift.
(define (whatsapp--paint! buf)
  (when (buffer-known? buf)
    (let* ((rows (whatsapp--messages buf))
           (current (whatsapp--message-at rows (buffer-point buf))))
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks
        (whatsapp--conversation-blocks rows current
          (buffer-local buf 'whatsapp-notice)))
      (buffer-set-local! buf 'modeline-info
        (string-append
          "WhatsApp · "
          (whatsapp--text (buffer-local buf 'whatsapp-name) "chat")
          (if current
              (string-append " · " (whatsapp--msg-sender current))
              ""))))))

;; RAW is what the server printed. It goes in as it came: the grammar
;; reads the buffer, so anything this rewrote would be a second
;; opinion about what was said.
(define (whatsapp--render-conversation! buf raw)
  (let ((text (if (string? raw) raw "")))
    (whatsapp--replace-text! buf text)
    (buffer-set-local! buf 'whatsapp-notice text)
    (buffer-set-local! buf 'whatsapp-messages-jid
      (buffer-local buf 'whatsapp-jid))
    (whatsapp--paint! buf)
    (buffer-set-read-only! buf #t)))

;; Motion belongs to the tree: the next message is the next sibling of
;; the node point stands in, and every mode with a grammar moves this
;; way.
(define (whatsapp--select-at! buf pos)
  (buffer-goto! buf pos)
  (whatsapp--paint! buf))

(define (whatsapp--goto-message! buf op)
  (let* ((rows (whatsapp--messages buf))
         (here (whatsapp--message-at rows (buffer-point buf))))
    (if (not here)
        (message "No messages here")
        (let ((target
                (with-current-buffer buf
                  (lambda ()
                    (ts-node "message"
                             (whatsapp--msg-start here)
                             (whatsapp--msg-end here) op)))))
          (if target
              (whatsapp--select-at! buf (nth 1 target))
              (message (if (equal? op 'next)
                           "Last message"
                           "First message")))))))

(domain! 'chat)
(effects! '(read external))

(define (whatsapp--fetch-chats buf k)
  (let* ((text
           (*whatsapp-call* 'whatsapp "list_chats"
             (list 'limit whatsapp-chat-limit
                   'page 0
                   'include_last_message #t
                   'sort_by "last_active")))
         (rows (whatsapp--parse-chats text)))
    (if rows
        (begin
          ;; A cache callback redraws with the cached rows. Seed the
          ;; unfiltered rows first so local filtering cannot retain the
          ;; empty source installed by the mode's initial render.
          (buffer-set-local! buf 'list-source-entries rows)
          (k rows))
        (begin
          (message "WhatsApp did not return a chat list")
          (k #f)))))

(define (whatsapp--refresh-conversation! buf)
  (let ((jid (buffer-local buf 'whatsapp-jid)))
    (when jid
      (whatsapp--render-conversation! buf "Loading messages…\n")
      (*whatsapp-call* 'whatsapp "list_messages"
        (list 'chat_jid jid
              'limit whatsapp-message-limit
              'page 0
              'include_context #f)
        (lambda (ok text)
          ;; One shared scene pane serves every chat. Ignore a response
          ;; whose request no longer owns that pane.
          (when (and (buffer-known? buf)
                     (equal? jid (buffer-local buf 'whatsapp-jid)))
            (whatsapp--render-conversation! buf
              (if ok
                  text
                  (string-append
                    "Could not load messages: "
                    (whatsapp--text text "unknown error")
                    "\n")))))))))

(define (whatsapp--display-conversation! buf)
  ;; Show the conversation without selecting its window; the index keeps
  ;; keyboard focus so moving up/down continues to preview chats. Every
  ;; chat lands in the index's one detail window, and C-` there walks the
  ;; chats already opened (packages/detail.scm).
  (display-buffer-detail! buf *whatsapp-buffer*))

(define (whatsapp--open-chat! chat &optional display?)
  (let* ((jid (whatsapp--text (plist-get chat 'jid) ""))
         (name (whatsapp--text (plist-get chat 'name) jid))
         (buf (whatsapp--conversation-buffer jid)))
    (if (equal? jid "")
        (message "This chat has no WhatsApp JID")
        (begin
          (unless (buffer-known? buf) (buffer-create buf))
          ;; Keep the conversation buffer's text attached to the selected
          ;; JID: the transcript in it is the only copy of this chat.
          (unless (equal? jid (buffer-local buf 'whatsapp-messages-jid))
            (buffer-set-local! buf 'whatsapp-messages-jid #f)
            (buffer-set-local! buf 'whatsapp-notice #f)
            (buffer-set-local! buf 'render-blocks #f))
          (buffer-set-local! buf 'whatsapp-jid jid)
          (buffer-set-local! buf 'whatsapp-name name)
          (with-current-buffer buf
            (lambda () (set-mode! "whatsapp-chat-mode")))
          (when display? (whatsapp--display-conversation! buf))))))

(domain! 'chat)
(effects! '(write external))

(define *whatsapp-reply-tool* (string-append "send" "_" "message"))

(define (whatsapp--send! buf text)
  (let* ((chat
           (and (buffer-derived-mode? buf "whatsapp-mode")
                (list-current *whatsapp-buffer*)))
         (jid
           (if chat
               (plist-get chat 'jid)
               (buffer-local buf 'whatsapp-jid))))
    (if (not jid)
        (message "No WhatsApp chat is selected")
        (begin
          (message "Sending WhatsApp reply…")
          (*whatsapp-call* 'whatsapp *whatsapp-reply-tool*
            (list 'recipient jid 'message text)
            (lambda (ok result)
              (when (buffer-known? buf)
                (if ok
                    (begin
                      (message "WhatsApp reply sent")
                      (whatsapp--refresh-conversation! buf))
                    (message
                      (string-append
                        "WhatsApp reply failed: "
                        (whatsapp--text result "unknown error")))))))))))

(domain! 'chat)
(effects! '(write external))

(define-style! 'whatsapp
  "
/* A log, not a chat app: one type size, one grid. The stamp is
   11 cells wide and two cells of gutter follow it, so a body that
   hangs at 13ch keeps its wrapped lines under the sender. */
.whatsapp-actions { padding: 2px 8px 8px; }
.whatsapp-message { margin: 0; padding: 3px 9px; border-left: 2px solid transparent; font-family: var(--font-mono); font-size: 12px; line-height: 1.45; }
.whatsapp-message-me { background: var(--hl-line-bg); border-left-color: var(--accent-fg); }
.whatsapp-message-current { outline: 1px solid var(--accent-fg); outline-offset: -1px; }
.whatsapp-message-time { color: var(--dim-fg); font-variant-numeric: tabular-nums; }
.whatsapp-message-sender { color: var(--dim-fg); font-weight: 600; }
.whatsapp-message-me .whatsapp-message-sender { color: var(--accent-fg); }
.whatsapp-message-body { display: block; padding-left: 13ch; color: var(--fg); white-space: pre-wrap; overflow-wrap: anywhere; }
.whatsapp-empty { margin: 4px 8px; font-family: var(--font-mono); font-size: 12px; color: var(--dim-fg); }
")

(add-hook! (list 'block-click 'whatsapp)
  (lambda (buf id)
    (and (equal? (buffer-local buf 'mode-name) "whatsapp-chat-mode")
         (cond
           ((equal? id "whatsapp-reply")
            (with-current-buffer buf
              (lambda () (run-command "whatsapp-reply")))
            #t)
           ((equal? id "whatsapp-refresh")
            (with-current-buffer buf
              (lambda () (run-command "whatsapp-chat-refresh")))
            #t)
           ((string-prefix? "msg:" id)
            (let ((pos (string->number
                         (substring-bytes id 4 (string-byte-length id)))))
              (when (number? pos) (whatsapp--select-at! buf pos)))
            #t)
           (else #f)))))

(define-mode "whatsapp-chat-mode"
  (lambda ()
    (let* ((buf (current-buffer))
           (jid (buffer-local buf 'whatsapp-jid))
           (loaded?
             (and jid
                  (equal? jid (buffer-local buf 'whatsapp-messages-jid)))))
      (whatsapp--join-group! buf)
      ;; before anything reads the buffer: every question below is a
      ;; question for the grammar
      (buffer-set-local! buf 'ts-lang "whatsapp")
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'special #f)
      (buffer-set-local! buf 'desktop-skip-locals
        '(render-blocks whatsapp-notice whatsapp-messages-jid))
      (buffer-set-local! buf 'render-mode "blocks")
      (cond
        (loaded? (whatsapp--paint! buf))
        (jid (whatsapp--refresh-conversation! buf))
        (else (whatsapp--render-conversation! buf ""))))))

(mode-doc! "whatsapp-chat-mode"
  (string-append
    "One WhatsApp conversation, read as messages rather than as lines. "
    "Up and down move between messages and mark the one you stand on; "
    "n/p and j/k do the same. r replies to that message, quoting it, "
    "and g refreshes."))

(mode-keys! "whatsapp-chat-mode"
  '(("<down>" "whatsapp-next-message")
    ("<up>" "whatsapp-prev-message")
    ("n" "whatsapp-next-message")
    ("p" "whatsapp-prev-message")
    ("j" "whatsapp-next-message")
    ("k" "whatsapp-prev-message")
    ("r" "whatsapp-reply")
    ("g" "whatsapp-chat-refresh")
    ("q" "quit-window")))

(domain! 'chat)
(effects! '(read external))

(define-list-mode! "whatsapp-mode"
  (list
    'doc (string-append
           "Recent WhatsApp chats. RET reads the selected conversation. "
           "Use r to reply, g to refresh, / to filter, and q to quit.")
    'buffer *whatsapp-buffer*
    'special #f
    'rows (lambda (buf)
            (whatsapp--join-group! buf)
            (list-entries buf))
    'cache-fetch whatsapp--fetch-chats
    'cache-ttl whatsapp-cache-ttl
    'columns (lambda (buf)
               (list (list "chat" 24) (list "last active" 25)
                     (list "message" #f)))
    'cells whatsapp--cells
    'title (lambda (buf) "WhatsApp chats")
    'meta (lambda (buf)
            (string-append
              (number->string (length (list-source-entries buf)))
              " recent chats"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'local-filter #t
    'no-marks #t
    'preview (lambda (buf chat) (whatsapp--open-chat! chat #f))
    'key (lambda (buf chat) (plist-get chat 'jid))
    'footer (lambda (buf)
              '(("RET" "read") ("r" "reply") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "whatsapp-open")
            ("r" "whatsapp-reply")
            ("g" "whatsapp-refresh")
            ("q" "quit-window"))))

(mode-doc! "whatsapp-mode"
  "Recent WhatsApp chats. RET reads a conversation. Use g to refresh.")

(domain! 'chat)
(effects! '(read external display))

(define-command "whatsapp-list" "Show the recent WhatsApp chat index"
  (lambda () (list-mode-show! "whatsapp-mode")))

(define-command "whatsapp-show-current" "Prepare the WhatsApp conversation pane"
  (lambda ()
    ;; Opening the scene must not turn the list's incidental first row
    ;; into a conversation choice. Keep the last explicitly opened chat;
    ;; RET in the index is the only operation that replaces this pane.
    (unless (buffer-known? *whatsapp-show-buffer*)
      (buffer-create *whatsapp-show-buffer*))
    (whatsapp--join-group! *whatsapp-show-buffer*)
    (when (and (not (buffer-local *whatsapp-show-buffer* 'whatsapp-jid))
               (= (buffer-size *whatsapp-show-buffer*) 0))
      (buffer-append! *whatsapp-show-buffer* "No conversation selected.\n")
      (buffer-set-read-only! *whatsapp-show-buffer* #t))))

(define-scene! "whatsapp"
  '(h 0.32
      (as index (ensure "*WhatsApp*" "whatsapp-list"))
      (as show (ensure "*WhatsApp conversation*" "whatsapp-show-current"))
      (as chat group-chat)))

(define-command "whatsapp" "Open the WhatsApp workspace"
  (lambda ()
    (let ((destination (if (equal? whatsapp-group "") "whatsapp" whatsapp-group)))
      (scene-open! "whatsapp" destination)
      ;; scene construction can be followed by current-group derivation from
      ;; the old visible panes; make the requested destination authoritative.
      (switch-to-group! destination))))

(define-command "whatsapp-open" "Read the WhatsApp chat on this row"
  (lambda ()
    (let ((chat (list-current *whatsapp-buffer*)))
      (if chat
          (whatsapp--open-chat! chat #t)
          (message "No WhatsApp chat is selected")))))

(domain! 'chat)
(effects! '(read external))

(define-command "whatsapp-refresh" "Refresh recent WhatsApp chats"
  (lambda ()
    (message "Refreshing WhatsApp chats…")
    (cache-refresh! *whatsapp-buffer*)))

(define-command "whatsapp-chat-refresh" "Refresh this WhatsApp conversation"
  (lambda () (whatsapp--refresh-conversation! (current-buffer))))

(domain! 'chat)
(effects! '(write external))

(define-command "whatsapp-reply" "Reply to the selected message, or to the chat"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (whatsapp--current-message buf)))
      (read-string
        (if row
            (string-append "Reply to " (whatsapp--msg-sender row) ": ")
            "Reply: ")
        (lambda (text)
          (let ((trimmed (string-trim text)))
            (unless (equal? trimmed "")
              (whatsapp--send! buf
                (if row
                    (string-append (whatsapp--quote row) trimmed)
                    trimmed)))))
        'history 'whatsapp-reply-history))))

(define-command "whatsapp-next-message" "Move to the next message"
  (lambda () (whatsapp--goto-message! (current-buffer) 'next)))

(define-command "whatsapp-prev-message" "Move to the previous message"
  (lambda () (whatsapp--goto-message! (current-buffer) 'prev)))

(mode-icon! "whatsapp-mode" "W")
(mode-icon! "whatsapp-chat-mode" "W")


;;; The feed: every WhatsApp message becomes a "whatsapp:<chat jid>" event
;;; in the event log. The bridge on the WhatsApp host pushes each message it
;;; stores to a webhook here, over the tailnet. A slow sweep reads the
;;; bridge's /api/messages after a saved rowid and adds what a push dropped;
;;; a received message only the sweep found is a "feed:whatsapp" missed event.

(domain! 'chat)
(effects! '(write external))

(defcustom 'whatsapp-feed-enabled #f
  "Run the WhatsApp feed. It starts at boot, so it stays on after a restart."
  'group 'whatsapp 'type 'boolean
  ;; custom.scm loads after this package, so the saved value arrives here
  'set (lambda (on) (whatsapp-feed--apply on)))

(defcustom 'whatsapp-feed-bridge "http://100.110.113.41:8080"
  "The bridge's REST server, which the sweep reads."
  'group 'whatsapp 'type 'string)

(defcustom 'whatsapp-feed-sweep-seconds 900
  "Seconds between two sweeps of the bridge."
  'group 'whatsapp 'type 'integer)

;; the message ids the log holds, newest first; seeded from the log once
(defvar '*whatsapp-feed-seen* #f)

(effects! '(pure))

(define (whatsapp-feed--event row)
  "(whatsapp-feed--event ROW) — the topic, kind and data of one bridge message. A direct chat's topic is its phone number, so a person under a LID and under a phone JID is one conversation; a group's is its JID."
  (list (string-append "whatsapp:"
                       (let ((phone (plist-get row 'phone)))
                         (if (and phone (not (equal? phone ""))) phone (plist-get row 'chat_jid))))
        (if (plist-get row 'is_from_me) 'sent 'received)
        (list 'id (plist-get row 'id)
              'chat (plist-get row 'chat_jid)
              'chat-name (plist-get row 'chat_name)
              'phone (plist-get row 'phone)
              'sender (plist-get row 'sender)
              'sender-phone (plist-get row 'sender_phone)
              'text (plist-get row 'content)
              'at (plist-get row 'timestamp)
              'media (plist-get row 'media_type)
              'file (plist-get row 'filename))))

(effects! '(write))

(define (whatsapp-feed-publish! row)
  "(whatsapp-feed-publish! ROW) — log one bridge message unless the log has it; its seq, or #f"
  (unless *whatsapp-feed-seen*
    (set! *whatsapp-feed-seen*
          (map (lambda (e) (plist-get (plist-get e 'data) 'id))
               (event-log-newest "whatsapp:*" 2000))))
  (let ((id (plist-get row 'id)))
    (if (or (not id) (member id *whatsapp-feed-seen*))
        #f
        (let ((e (whatsapp-feed--event row)))
          (set! *whatsapp-feed-seen* (take (cons id *whatsapp-feed-seen*) 2000))
          (event-publish! (car e) (cadr e) (caddr e))))))

(define (whatsapp-feed--handle request)
  "(whatsapp-feed--handle REQUEST) — the feed webhook's /whatsapp: one message the bridge pushed"
  (if (not (equal? (plist-get request 'method) "POST"))
      (event-feed-reply 405 "POST only")
      (let ((row (json-parse (plist-get request 'body))))
        (if (not row)
            (event-feed-reply 400 "bad json")
            (begin (whatsapp-feed-publish! row)
                   (event-feed-reply 200 "ok"))))))

(effects! '(write external))

(define (whatsapp-feed-sweep!)
  "(whatsapp-feed-sweep!) — read the bridge after the saved rowid and log what the log lacks. The first sweep only saves the newest rowid."
  (let ((after (event-log-position "whatsapp-feed-sweep")))
    (http-get-json
     (string-append whatsapp-feed-bridge "/api/messages?limit=500&after="
                    (number->string (or after -1)))
     '()
     (lambda (rows)
       (when (pair? rows)
         (let ((missed 0))
           (when after
             (for-each (lambda (row)
                         (when (and (whatsapp-feed-publish! row)
                                    (not (plist-get row 'is_from_me)))
                           (set! missed (+ missed 1))))
                       rows))
           (event-log-position-set! "whatsapp-feed-sweep"
                                    (plist-get (car (reverse rows)) 'rowid))
           (when (> missed 0)
             (event-publish! "feed:whatsapp" 'missed (list 'count missed)))
           (when (= (length rows) 500) (whatsapp-feed-sweep!))))))))

(define (whatsapp-feed--tick _)
  (ignore-errors (lambda () (whatsapp-feed-sweep!)))
  (debounce! 'whatsapp-feed-sweep (* 1000 whatsapp-feed-sweep-seconds)
             (lambda (x) (whatsapp-feed--tick x)) #f))

(define (whatsapp-feed-start!)
  "(whatsapp-feed-start!) — listen for the bridge's pushes and start the sweep"
  (event-feed-route! "/whatsapp" (lambda (request) (whatsapp-feed--handle request)))
  (event-feed-start!)
  (whatsapp-feed--tick #f))

(define (whatsapp-feed-stop!)
  "(whatsapp-feed-stop!) — stop taking the bridge's pushes and stop the sweep"
  (set! *event-feed-routes* (events--without "/whatsapp" *event-feed-routes*))
  (debounce-cancel! 'whatsapp-feed-sweep))

(define-command "whatsapp-feed-start" "Turn WhatsApp messages into events: the webhook and the sweep"
  (lambda () (whatsapp-feed-start!) (message "WhatsApp feed on")))

(define-command "whatsapp-feed-stop" "Stop turning WhatsApp messages into events"
  (lambda () (whatsapp-feed-stop!) (message "WhatsApp feed off")))

;; after the load, not in it: a start inside the loader does not take
(define (whatsapp-feed--apply on)
  "(whatsapp-feed--apply ON) — start or stop the feed once the boot is done; starting twice is harmless"
  ;; at boot a task cannot start yet, so the feed waits for the boot to end
  (debounce! 'whatsapp-feed-boot 0
             (lambda (_) (if on (whatsapp-feed-start!) (whatsapp-feed-stop!))) #f))

(when whatsapp-feed-enabled (whatsapp-feed--apply #t))

;;; notices: a WhatsApp message that arrives passes in the corner

(domain! 'chat)
(effects! '(write display))

(defcustom 'whatsapp-notify #t
  "Show a notice for each WhatsApp message that arrives.")

(define (whatsapp-notify--text x)
  (if (and (string? x) (> (string-length x) 0)) x #f))

(define (whatsapp-notify--saw e)
  "a received message, other than a status update, makes a notice: the chat, then the first line"
  (let ((d (plist-get e 'data)))
    (when (and whatsapp-notify
               (eq? (plist-get e 'kind) 'received)
               (not (equal? (plist-get d 'chat) "status@broadcast")))
      (let ((text (whatsapp-notify--text (plist-get d 'text)))
            (media (whatsapp-notify--text (plist-get d 'media))))
        (notify! "whatsapp"
                 (or (whatsapp-notify--text (plist-get d 'chat-name))
                     (whatsapp-notify--text (plist-get d 'phone))
                     "WhatsApp")
                 (cond (text (first-line text))
                       (media (string-append "[" media "]"))
                       (else ""))
                 (list 'topic (plist-get e 'topic) 'event (plist-get e 'seq)))))))

(event-subscribe! "whatsapp-notify" "whatsapp:*" 'whatsapp-notify--saw)
