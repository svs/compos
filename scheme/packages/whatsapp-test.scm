;;; whatsapp-test.scm --- WhatsApp list and conversation policy.

(package! "whatsapp-test")

(domain! 'diagnostics)
(effects! '(read))

(define t--whatsapp-chat-stream
  (string-append
    "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund\","
    "\"last_message_time\":\"2026-09-05T11:49:38+05:30\","
    "\"last_message\":\"line one\\nline two\",\"last_is_from_me\":1}\n"
    "{\"jid\":\"456@g.us\",\"name\":\"Team\","
    "\"last_message_time\":\"2026-09-05T10:00:00+05:30\","
    "\"last_message\":\"hello\",\"last_is_from_me\":0}"))

(define t--whatsapp-message-stream
  (string-append
    "[2026-09-05 11:49:38] Chat: Mukund From: Me: line one\n"
    "line two\n"
    "[2026-09-05 11:48:00] Chat: Mukund From: Mukund: "
    "[image - Message ID: ABC - Chat JID: 123@s.whatsapp.net] \n"))

;; a conversation buffer holding TEXT, in the mode that reads it
(define (t--whatsapp-conversation text)
  (let ((buf "*zz-whatsapp-conversation*"))
    (unless (buffer-known? buf) (buffer-create buf))
    (buffer-set-local! buf 'whatsapp-jid #f)
    (buffer-set-local! buf 'whatsapp-name "Mukund")
    (with-current-buffer buf (lambda () (set-mode! "whatsapp-chat-mode")))
    (whatsapp--render-conversation! buf text)
    buf))

(deftest 'whatsapp-parses-chat-stream-and-flattens-previews
  "The chat stream becomes rows with one-line previews."
  (lambda ()
    (let* ((rows (whatsapp--parse-chats t--whatsapp-chat-stream))
           (cells (whatsapp--cells "*WhatsApp*" (car rows))))
      (check-equal! (length rows) 2 "both JSON objects become rows")
      (check-equal! (car cells) "Mukund" "the chat name is the first cell")
      (check-equal! (caddr cells) "me: line one line two"
                    "the preview is one line and marks my message"))))

(deftest 'whatsapp-parses-one-chat-object
  "One JSON object becomes one selectable chat row."
  (lambda ()
    (let ((rows
            (whatsapp--parse-chats
              "{\"jid\":\"123@s.whatsapp.net\",\"name\":\"Mukund\"}")))
      (check-equal! (length rows) 1 "one object still becomes one row")
      (check-equal! (plist-get (car rows) 'jid) "123@s.whatsapp.net"
                    "the JID stays attached to the row"))))

(deftest 'whatsapp-reads-the-transcript-as-a-tree
  "The grammar finds the messages; nothing here scans lines."
  (lambda ()
    (let* ((buf (t--whatsapp-conversation t--whatsapp-message-stream))
           (rows (whatsapp--messages buf))
           (first (car rows))
           (second (cadr rows)))
      (check-equal! (buffer-text buf) t--whatsapp-message-stream
                    "the transcript reaches the buffer as it came")
      (check-equal! (length rows) 2 "both messages become nodes")
      (check-equal! (whatsapp--msg-body first) "line one\nline two"
                    "continuation lines stay with their message")
      (check-true! (whatsapp--msg-mine? first)
                   "messages from Me are identified")
      (check-equal! (whatsapp--msg-sender second) "Mukund"
                    "the sender stays visible")
      (check-equal! (whatsapp--msg-body second) "[image]"
                    "media rows hide transport identifiers"))))

(deftest 'whatsapp-moves-between-messages-and-marks-the-one-at-point
  "Up and down are the tree's siblings, and the view says where you are."
  (lambda ()
    (let* ((buf (t--whatsapp-conversation t--whatsapp-message-stream))
           (rows (whatsapp--messages buf)))
      (whatsapp--select-at! buf (whatsapp--msg-start (car rows)))
      (check-equal! (whatsapp--msg-sender (whatsapp--current-message buf))
                    "Me" "the message at point is the one point stands in")
      (whatsapp--goto-message! buf 'next)
      (check-equal! (buffer-point buf) (whatsapp--msg-start (cadr rows))
                    "next lands on the next message's own start")
      (check-contains! (value->string (buffer-local-value 'render-blocks buf))
                       "whatsapp-message-current"
                       "the view marks the message at point")
      (whatsapp--goto-message! buf 'next)
      (check-equal! (buffer-point buf) (whatsapp--msg-start (cadr rows))
                    "the last message is where next stops")
      (whatsapp--goto-message! buf 'prev)
      (check-equal! (buffer-point buf) (whatsapp--msg-start (car rows))
                    "prev walks back the same way"))))

(deftest 'whatsapp-reply-quotes-the-message-it-answers
  "The transport has no reply-to field, so the quote goes in the text."
  (lambda ()
    (let ((rows (whatsapp--messages
                  (t--whatsapp-conversation t--whatsapp-message-stream))))
      (check-equal! (whatsapp--quote (car rows))
                    "> Me: line one line two\n"
                    "the quote is one line, attributed"))))

(deftest 'whatsapp-conversation-shows-actions-and-empty-state
  "The conversation uses catalogued actions and an empty state."
  (lambda ()
    (let* ((buf (t--whatsapp-conversation "Could not load messages\n"))
           (blocks (buffer-local-value 'render-blocks buf)))
      (check-equal! (length blocks) 2
                    "actions and the empty state render")
      (check-contains! (value->string blocks) "Reply"
                       "the reply action is visible")
      (check-contains! (value->string blocks) "Refresh"
                       "the refresh action is visible")
      (check-contains! (value->string blocks) "Could not load messages"
                       "what the server said is what the reader sees"))))
