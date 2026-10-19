;;; imessage.scm --- Read and reply to iMessage and SMS from Messages on this Mac.

;;; Messages keeps every conversation in ~/Library/Messages/chat.db, the SMS
;;; of the iPhone included once Text Message Forwarding is on. Reading it
;;; needs Full Disk Access for compos; a reply goes out through Messages.app.

(package! "imessage")

(domain! 'chat)
(effects! '(write))

(defgroup 'imessage "Read and reply to iMessage and SMS through Messages on this Mac.")

(define imessage-cache-ttl 30)

(defcustom 'imessage-chat-limit 200
  "Maximum recent chats to show."
  'group 'imessage 'type 'integer)

(defcustom 'imessage-message-limit 200
  "Maximum recent messages to show in one conversation."
  'group 'imessage 'type 'integer)

(defcustom 'imessage-group "*iMessage*"
  "Group to open iMessage in."
  'group 'imessage 'type 'string)

(defcustom 'otp-minutes 15
  "How far back, in minutes, otp-latest and the otp command look for a code."
  'group 'imessage 'type 'integer)

(define imessage-db "~/Library/Messages/chat.db")
(define imessage--address-books
  "~/Library/Application\\ Support/AddressBook/AddressBook-v22.abcddb ~/Library/Application\\ Support/AddressBook/Sources/*/AddressBook-v22.abcddb")
(define *imessage-buffer* "*iMessage*")
(define *imessage-show-buffer* "*iMessage conversation*")
(define *imessage-contacts* #f)

(define (imessage--join-group! buf)
  (let ((group (frame-group)))
    (when group (buffer-add-group! buf group)))
  buf)

(domain! 'chat)
(effects! '(pure))

;;; Newer Messages leaves text empty and keeps the words in attributedBody,
;;; a typedstream: after the NSString class name and a "+" comes the length,
;;; one byte, or 0x81 and two bytes little-endian, then the UTF-8 itself.
;;; sqlite decodes it in the query, so no blob crosses the shell.
(define (imessage--sql-byte blob pos)
  (let ((h (string-append "hex(substr(" blob "," pos ",1))")))
    (string-append "((instr('0123456789ABCDEF',substr(" h ",1,1))-1)*16"
                   "+instr('0123456789ABCDEF',substr(" h ",2,1))-1)")))

(define (imessage--sql-body m)
  (let* ((b (string-append m ".attributedBody"))
         (s (string-append "(instr(" b ",X'4E53537472696E67')+8)"))
         (q (string-append "(" s "+instr(substr(" b "," s ",8),X'2B'))"))
         (len (imessage--sql-byte b q)))
    (string-append
     "replace(coalesce(" m ".text, case when " b " is null then null"
     " when " len " = 129 then cast(substr(" b "," q "+3,"
     (imessage--sql-byte b (string-append q "+1")) "+256*" (imessage--sql-byte b (string-append q "+2"))
     ") as text) else cast(substr(" b "," q "+1," len ") as text) end), char(65532), '[attachment]')")))

(define (imessage--sql-stamp col)
  (string-append "datetime(" col "/1000000000+978307200,'unixepoch','localtime')"))

(define (imessage--key handle)
  ;; a phone number by its last ten digits, an email in lower case
  (cond ((not (string? handle)) #f)
        ((string-contains? handle "@") (string-downcase handle))
        (else (let ((d (re-replace-all "\\D" handle "")))
                (cond ((< (string-length d) 6) handle)
                      ((> (string-length d) 10) (substring d (- (string-length d) 10) (string-length d)))
                      (else d))))))

(define (imessage--one-line s)
  (if (string? s) (string-trim (re-replace-all "\\s+" s " ")) ""))

(define (imessage--minute stamp)
  (if (and (string? stamp) (>= (string-length stamp) 16)) (substring stamp 0 16) (or stamp "")))

(define (otp-scan text)
  (and (string? text)
       (let ((a (re-match "(?i)\\b(?:otp|code|passcode|pin|password)\\b(?:(?!call|helpline)\\D){0,40}?\\b(\\d{4,8})(?![\\d.,]?\\d)" text)))
         (if a (cadr a)
             (let ((b (re-match "(?i)\\b(\\d{4,8})\\b[^.\\n]{0,40}\\b(?:otp|code|verification|one[- ]time)" text)))
               (and b (cadr b)))))))

(domain! 'chat)
(effects! '(read external execute))

(define (imessage--query sql)
  (let* ((out (shell-command->string
               (string-append "sqlite3 -readonly -json " (sh-quote (expand-path imessage-db)) " " (sh-quote sql) " 2>&1")
               "/tmp"))
         (text (string-trim out)))
    (if (equal? text "") '()
        (or (json-parse text) (error (string-append "imessage: " text))))))

(define (imessage--read-contacts)
  (let* ((who "coalesce(nullif(trim(coalesce(r.ZFIRSTNAME,'') || ' ' || coalesce(r.ZLASTNAME,'')),''), r.ZORGANIZATION)")
         (sql (string-append "select " who ", p.ZFULLNUMBER from ZABCDPHONENUMBER p join ZABCDRECORD r on r.Z_PK = p.ZOWNER"
                             " union all select " who ", e.ZADDRESS from ZABCDEMAILADDRESS e join ZABCDRECORD r on r.Z_PK = e.ZOWNER;"))
         (out (shell-command->string
               (string-append "for f in " imessage--address-books "; do sqlite3 -readonly \"$f\" " (sh-quote sql) " 2>/dev/null; done")
               "/tmp")))
    (let loop ((lines (string-split out "\n")) (acc '()))
      (if (null? lines) (reverse acc)
          (let ((cols (string-split (car lines) "|")))
            (loop (cdr lines)
                  (if (and (= (length cols) 2) (not (equal? (car cols) "")))
                      (cons (list (imessage--key (cadr cols)) (car cols)) acc)
                      acc)))))))

(define (imessage-contacts)
  (unless *imessage-contacts* (set! *imessage-contacts* (imessage--read-contacts)))
  *imessage-contacts*)

(define (imessage-name handle)
  (let ((hit (and handle (assoc (imessage--key handle) (imessage-contacts)))))
    (if hit (cadr hit) (or handle "?"))))

(define (imessage--chat-name r)
  (let ((title (plist-get r 'title)) (members (plist-get r 'members)))
    (cond ((and (string? title) (not (equal? title ""))) title)
          ((and (string? members) (string-contains? members ","))
           (string-join (map imessage-name (string-split members ",")) ", "))
          (else (imessage-name (plist-get r 'handle))))))

(define (imessage-chats &optional limit)
  (map (lambda (r) (append r (list 'name (imessage--chat-name r))))
       (imessage--query
        (string-append
         "select c.ROWID id, c.guid guid, c.chat_identifier handle, c.display_name title, c.service_name service,"
         " (select group_concat(h.id, ',') from chat_handle_join ch join handle h on h.ROWID = ch.handle_id where ch.chat_id = c.ROWID) members,"
         " " (imessage--sql-stamp "m.date") " time, m.is_from_me mine, " (imessage--sql-body "m") " text"
         " from chat c join (select chat_id, max(message_date) d from chat_message_join group by chat_id) last on last.chat_id = c.ROWID"
         " join chat_message_join cj on cj.chat_id = c.ROWID and cj.message_date = last.d"
         " join message m on m.ROWID = cj.message_id"
         " group by c.ROWID order by last.d desc limit " (number->string (or limit imessage-chat-limit)) ";"))))

(define (imessage-messages chat &optional limit)
  (reverse
   (imessage--query
    (string-append
     "select m.ROWID id, " (imessage--sql-stamp "m.date") " time, m.is_from_me mine, h.id sender, m.service service, " (imessage--sql-body "m") " text"
     " from chat_message_join j join message m on m.ROWID = j.message_id left join handle h on h.ROWID = m.handle_id"
     " where j.chat_id = " (number->string chat)
     " order by m.date desc limit " (number->string (or limit imessage-message-limit)) ";"))))

(define (imessage--guid to)
  ;; TO is a chat guid, a chat id, or a phone number or email with a chat
  (cond ((number? to)
         (let ((rows (imessage--query (string-append "select guid from chat where ROWID = " (number->string to) ";"))))
           (and (pair? rows) (plist-get (car rows) 'guid))))
        ((not (string? to)) #f)
        ((string-contains? to ";") to)
        ((string-contains? to "'") #f)
        (else
         (let ((rows (imessage--query
                      (string-append "select guid from chat where chat_identifier like '%" (imessage--key to)
                                     "' order by service_name = 'iMessage' desc, ROWID desc limit 1;"))))
           (and (pair? rows) (plist-get (car rows) 'guid))))))

(define (imessage--conversation-text chat rows)
  (let loop ((rs rows) (day #f)
             (acc (list (string-append (plist-get chat 'name) "  (" (or (plist-get chat 'service) "") ")\n"))))
    (if (null? rs) (string-join (reverse acc) "")
        (let* ((r (car rs))
               (time (or (plist-get r 'time) ""))
               (d (substring time 0 (min 10 (string-length time))))
               (hm (if (>= (string-length time) 16) (substring time 11 16) ""))
               (who (if (equal? (plist-get r 'mine) 1) "me" (imessage-name (plist-get r 'sender))))
               (body (re-replace-all "\n" (or (plist-get r 'text) "") "\n       ")))
          (loop (cdr rs) d
                (cons (string-append hm "  " who ": " body "\n")
                      (if (equal? d day) acc (cons (string-append "\n" d "\n") acc))))))))

(define (otp--hits where)
  (let loop ((rows (imessage--query
                    (string-append
                     "select h.id sender, " (imessage--sql-body "m") " text,"
                     " cast(m.date/1000000000 + 978307200 as integer) at,"
                     " cast(strftime('%s','now') - (m.date/1000000000 + 978307200) as integer) age"
                     " from message m left join handle h on h.ROWID = m.handle_id"
                     " where m.is_from_me = 0 and " where " order by m.date desc;")))
             (acc '()))
    (if (null? rows) (reverse acc)
        (let* ((r (car rows)) (code (otp-scan (plist-get r 'text))))
          (loop (cdr rows)
                (if code
                    (cons (list 'code code 'sender (plist-get r 'sender) 'at (plist-get r 'at)
                                'age (plist-get r 'age) 'text (plist-get r 'text))
                          acc)
                    acc))))))

(define (otp--matches? hit match)
  ;; MATCH, #f for any, is found in the sender or the text, any case
  (or (not match) (equal? match "")
      (let ((m (string-downcase match)))
        (or (string-contains? (string-downcase (or (plist-get hit 'sender) "")) m)
            (string-contains? (string-downcase (or (plist-get hit 'text) "")) m)))))

(define (otp-recent &optional minutes match)
  (filter (lambda (h) (otp--matches? h match))
          (otp--hits (string-append "m.date > (strftime('%s','now') - 978307200 - "
                                    (number->string (* 60 (or minutes otp-minutes))) ") * 1000000000"))))

(define (otp-latest &optional minutes match)
  (let ((hits (otp-recent minutes match)))
    (and (pair? hits) (plist-get (car hits) 'code))))

(define (otp-since since &optional match)
  ;; the codes received after unix second SINCE, newest first
  (filter (lambda (h) (otp--matches? h match))
          (otp--hits (string-append "m.date > (" (number->string since) " - 978307200) * 1000000000"))))

(domain! 'chat)
(effects! '(write))

(define (imessage--render! buf text)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text)
  (buffer-goto! buf (buffer-size buf)))

(define (imessage--refresh-conversation! buf)
  (let ((chat (buffer-local buf 'imessage-chat)))
    (when chat
      (task-run! (lambda () (imessage--conversation-text chat (imessage-messages (plist-get chat 'id))))
        (lambda (ok? text)
          ;; one pane serves every chat: drop an answer for a chat it left
          (when (and (buffer-known? buf)
                     (equal? (plist-get chat 'id) (plist-get (buffer-local buf 'imessage-chat) 'id)))
            (imessage--render! buf (if ok? text (string-append "Could not read Messages: " (format "~a" text) "\n")))))))))

(define (imessage--open-chat! chat &optional display?)
  (let ((buf *imessage-show-buffer*))
    (unless (buffer-known? buf) (buffer-create buf))
    (buffer-set-local! buf 'imessage-chat chat)
    (with-current-buffer buf (lambda () (set-mode! "imessage-chat-mode")))
    (when display? (display-buffer-detail! buf *imessage-buffer*))))

(define (imessage--fetch-chats buf k)
  (task-run! (lambda () (imessage-chats))
    (lambda (ok? rows)
      (if ok?
          (begin (buffer-set-local! buf 'list-source-entries rows) (k rows))
          (begin (message (string-append "iMessage: " (format "~a" rows))) (k #f))))))

(define (imessage--cells buf chat)
  (list (or (plist-get chat 'name) "?")
        (imessage--minute (plist-get chat 'time))
        (string-append (if (equal? (plist-get chat 'mine) 1) "me: " "")
                       (imessage--one-line (plist-get chat 'text)))))

(domain! 'chat)
(effects! '(write external execute))

(define imessage--send-script
  '("on run argv"
    "tell application \"Messages\" to send (item 1 of argv) to chat id (item 2 of argv)"
    "end run"))

(define (imessage-send! to text)
  (let ((guid (imessage--guid to)))
    (if (not guid)
        (string-append "no Messages chat with " (format "~a" to))
        (let ((out (string-trim
                    (shell-command->string
                     (string-append "osascript "
                                    (string-join (map (lambda (l) (string-append "-e " (sh-quote l))) imessage--send-script) " ")
                                    " " (sh-quote text) " " (sh-quote guid) " 2>&1")
                     "/tmp"))))
          (if (equal? out "") #t out)))))

(define (imessage--chat-here buf)
  (if (buffer-derived-mode? buf "imessage-mode")
      (list-current *imessage-buffer*)
      (buffer-local buf 'imessage-chat)))

(define-command "imessage-reply" "Send a message to this iMessage or SMS chat"
  (lambda ()
    (let ((chat (imessage--chat-here (current-buffer))))
      (if (not chat)
          (message "No iMessage chat is selected")
          (read-string (string-append "Message to " (plist-get chat 'name) ": ")
            (lambda (text)
              (let ((trimmed (string-trim text)))
                (unless (equal? trimmed "")
                  (message "Sending...")
                  (task-run! (lambda () (imessage-send! (plist-get chat 'guid) trimmed))
                    (lambda (ok? result)
                      (if (and ok? (equal? result #t))
                          (begin
                            (message (string-append "Sent to " (plist-get chat 'name)))
                            (when (buffer-known? *imessage-show-buffer*)
                              (imessage--refresh-conversation! *imessage-show-buffer*)))
                          (message (string-append "iMessage send failed: " (format "~a" result)))))))))
            'history 'imessage-reply-history)))))

(define-command "otp" "Copy the newest one-time code from Messages, within otp-minutes"
  (lambda ()
    (task-run! (lambda () (otp-recent))
      (lambda (ok? hits)
        (cond ((not ok?) (message (string-append "otp: " (format "~a" hits))))
              ((null? hits) (message (string-append "No code in the last " (number->string otp-minutes) " minutes")))
              (else (let ((h (car hits)))
                      (kill-new (plist-get h 'code))
                      (clipboard-put! (plist-get h 'code))
                      (message (string-append (plist-get h 'code) " from " (or (plist-get h 'sender) "?")
                                              ", " (format-age (plist-get h 'age) 'ago) " (copied)")))))))))

(domain! 'chat)
(effects! '(write))

(define-mode "imessage-chat-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (imessage--join-group! buf)
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'desktop-skip-locals '(imessage-chat))
      (imessage--refresh-conversation! buf))))

(mode-doc! "imessage-chat-mode"
  "One iMessage or SMS conversation, newest at the bottom. r sends a message, g refreshes.")

(mode-keys! "imessage-chat-mode"
  '(("r" "imessage-reply")
    ("g" "imessage-chat-refresh")
    ("q" "quit-window")))

(domain! 'chat)
(effects! '(read external))

(define-list-mode! "imessage-mode"
  (list
    'doc "Recent iMessage and SMS chats. RET reads the selected conversation. Use r to send, g to refresh, / to filter, and q to quit."
    'buffer *imessage-buffer*
    'special #f
    'rows (lambda (buf)
            (imessage--join-group! buf)
            (list-entries buf))
    'cache-fetch imessage--fetch-chats
    'cache-ttl imessage-cache-ttl
    'columns (lambda (buf)
               (list (list "chat" 24) (list "last active" 17)
                     (list "message" #f)))
    'cells imessage--cells
    'title (lambda (buf) "iMessage chats")
    'meta (lambda (buf)
            (string-append (number->string (length (list-source-entries buf))) " recent chats"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'local-filter #t
    'no-marks #t
    'preview (lambda (buf chat) (imessage--open-chat! chat #f))
    'debounce #t
    'key (lambda (buf chat) (plist-get chat 'id))
    'footer (lambda (buf)
              '(("RET" "read") ("r" "send") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "imessage-open")
            ("r" "imessage-reply")
            ("g" "imessage-refresh")
            ("q" "quit-window"))))

(mode-doc! "imessage-mode"
  "Recent iMessage and SMS chats. RET reads a conversation. Use g to refresh.")

(domain! 'chat)
(effects! '(read external display))

(define-command "imessage-list" "Show the recent iMessage chat index"
  (lambda () (list-mode-show! "imessage-mode")))

(define-command "imessage-show-current" "Prepare the iMessage conversation pane"
  (lambda ()
    (unless (buffer-known? *imessage-show-buffer*)
      (buffer-create *imessage-show-buffer*))
    (imessage--join-group! *imessage-show-buffer*)
    (when (and (not (buffer-local *imessage-show-buffer* 'imessage-chat))
               (= (buffer-size *imessage-show-buffer*) 0))
      (buffer-append! *imessage-show-buffer* "No conversation selected.\n")
      (buffer-set-read-only! *imessage-show-buffer* #t))))

(define-scene! "imessage"
  '(h 0.32
      (as index (ensure "*iMessage*" "imessage-list"))
      (as show (ensure "*iMessage conversation*" "imessage-show-current"))
      (as chat group-chat)))

(define-command "imessage" "Open the iMessage workspace"
  (lambda ()
    (let ((destination (if (equal? imessage-group "") "imessage" imessage-group)))
      (scene-open! "imessage" destination)
      (switch-to-group! destination))))

(define-command "imessage-open" "Read the iMessage chat on this row"
  (lambda ()
    (let ((chat (list-current *imessage-buffer*)))
      (if chat
          (imessage--open-chat! chat #t)
          (message "No iMessage chat is selected")))))

(domain! 'chat)
(effects! '(read external))

(define-command "imessage-refresh" "Refresh recent iMessage chats"
  (lambda ()
    (message "Refreshing iMessage chats...")
    (cache-refresh! *imessage-buffer*)))

(define-command "imessage-chat-refresh" "Refresh this iMessage conversation"
  (lambda () (imessage--refresh-conversation! (current-buffer))))

(define-command "imessage-contacts-refresh" "Read the names from Contacts again"
  (lambda ()
    (set! *imessage-contacts* #f)
    (task-run! (lambda () (length (imessage-contacts)))
      (lambda (ok? n) (message (if ok? (string-append (number->string n) " contact handles") (format "~a" n)))))))

;;; An agent that asks a site for a code waits for it with otp-wait. Messages
;;; writes chat.db-wal as a message lands, the watch on its directory wakes
;;; the waiters, and each takes the newest code later than its SINCE. The
;;; directory is watched only while someone waits.

(domain! 'chat)
(effects! '(write external execute))

(defcustom 'otp-wait-grace 60
  "Seconds before the call that otp-wait still counts when it has no SINCE: a code that landed while the agent was getting to the wait."
  'group 'imessage 'type 'integer)

(define *otp-waiters* '())
(define *otp-watch* #f)
(define *otp-checking* #f)
(define *otp-dirty* #f)
(define *otp-serial* 0)

(define (otp--first pred xs)
  (cond ((null? xs) #f) ((pred (car xs)) (car xs)) (else (otp--first pred (cdr xs)))))

(define (otp--resolve! id value)
  ;; a waiter is (ID MATCH SINCE K); it answers once, with a hit or #f
  (let ((w (assoc id *otp-waiters*)))
    (when w
      (set! *otp-waiters* (filter (lambda (x) (not (equal? (car x) id))) *otp-waiters*))
      (when (and (null? *otp-waiters*) *otp-watch*)
        (unwatch-path! *otp-watch*)
        (set! *otp-watch* #f))
      ((list-ref w 3) value))))

(define (otp--check!)
  (cond (*otp-checking* (set! *otp-dirty* #t))
        ((pair? *otp-waiters*)
         (set! *otp-checking* #t)
         (set! *otp-dirty* #f)
         (let* ((ws *otp-waiters*)
                (since (apply min (map caddr ws))))
           (task-run! (lambda () (otp-since since))
             (lambda (ok? hits)
               (set! *otp-checking* #f)
               (when ok?
                 (for-each (lambda (w)
                             (let ((hit (otp--first (lambda (h) (and (> (plist-get h 'at) (caddr w))
                                                                     (otp--matches? h (cadr w))))
                                                    hits)))
                               (when hit (otp--resolve! (car w) hit))))
                           ws))
               (when *otp-dirty* (otp--check!))))))))

(define (otp--fs-change root)
  (when (and *otp-watch* (equal? root *otp-watch*)) (otp--check!)))

(add-hook! 'fs-change-hook 'otp--fs-change)

(define (otp-wait match since timeout k)
  (set! *otp-serial* (+ *otp-serial* 1))
  (let ((id (string-append "otp-wait-" (number->string *otp-serial*)))
        (since (or since (- (current-time) otp-wait-grace))))
    (set! *otp-waiters* (cons (list id match since k) *otp-waiters*))
    (unless *otp-watch*
      (let ((got (watch-path! (expand-path "~/Library/Messages"))))
        (set! *otp-watch* (and (string? got) got))))
    (debounce! id (* 1000 (or timeout 120)) (lambda (id) (otp--resolve! id #f)) id)
    (otp--check!)
    id))

(define (otp-await &optional match since timeout)
  ;; blocks: call it inside a task, never on the lane
  (let ((hit (app-await (lambda (k) (otp-wait match since timeout k)) (+ 5 (or timeout 120)))))
    (and hit (plist-get hit 'code))))

(mode-icon! "imessage-mode" "I")
(mode-icon! "imessage-chat-mode" "I")

(effects! '(pure))
(public! 'otp-scan "(otp-scan TEXT) -- the one-time code in a message's TEXT, or #f")
(effects! '(read external execute))
(public! 'imessage-chats "(imessage-chats [LIMIT]) -- recent chats, newest first, as plists: id guid handle name service time mine text")
(public! 'imessage-messages "(imessage-messages CHAT-ID [LIMIT]) -- a chat's recent messages, oldest first, as plists: id time mine sender service text")
(public! 'imessage-name "(imessage-name HANDLE) -- the Contacts name for a phone number or email, else HANDLE")
(public! 'otp-recent "(otp-recent [MINUTES] [MATCH]) -- one-time codes (OTP, verification, 2FA, login) from SMS and iMessage in the last MINUTES (otp-minutes), newest first, as (code C sender S at UNIX age SECONDS text T); MATCH keeps those whose sender or text has it, any case")
(public! 'otp-latest "(otp-latest [MINUTES] [MATCH]) -- the newest one-time code (OTP, verification, 2FA) from SMS or iMessage in the last MINUTES whose sender or text has MATCH, or #f")
(public! 'otp-since "(otp-since UNIX [MATCH]) -- the one-time codes received after unix second UNIX, newest first, as otp-recent gives them")
(effects! '(write external execute))
(public! 'otp-wait "(otp-wait MATCH SINCE TIMEOUT K) -- wait for a one-time code (OTP, verification, 2FA) to arrive by SMS or iMessage: K gets (code C sender S at UNIX age SECONDS text T) for the newest code after SINCE (unix seconds; #f is now less otp-wait-grace) whose sender or text has MATCH (#f any), or #f after TIMEOUT seconds (#f 120). Wakes on the message, no polling; answers the waiter id")
(public! 'otp-await "(otp-await [MATCH] [SINCE] [TIMEOUT]) -- inside a task only: block until a one-time code arrives, as otp-wait, and answer the code string or #f. Note (current-time) before you ask the site for the code and pass it as SINCE")
(effects! '(write external execute))
(public! 'imessage-send! "(imessage-send! TO TEXT) -- send TEXT through Messages; TO is a chat guid, chat id, or a phone or email with a chat. #t, or the error")
