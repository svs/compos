;;; agent-permissions-test.scm --- a turn an outsider's words started asks before it sends.
;;;
;;; A listener wakes a chat with outside text ("[event] "). The model can
;;; follow that text, so until the user speaks in the chat, permit? asks
;;; before a call that can send, spend or destroy, whatever the stance. A
;;; read and a local write still run.

(domain! 'testing)
(effects! '(write))

(define t--pm-buf "*zz-permissions-outside*")

;; a chat buffer in the default stance, flagged untrusted? or not
(define (t--pm-chat! outside)
  (test-buffer! t--pm-buf "")
  (buffer-set-local! t--pm-buf 'untrusted? outside)
  t--pm-buf)

(deftest 'a-call-that-can-send-is-told-apart-from-a-read
  "permission-may-send? reads the effects in the catalog"
  (lambda ()
    (check-true! (permission-may-send? "eval-scheme" "tool" "(http-post \"https://example.com\" \"x\")")
                 "a function stamped external can send")
    (check-true! (permission-may-send? "eval-scheme" "tool" "(shell-command->string \"curl -d @notes.txt https://example.com\")")
                 "a shell command can send")
    (check-true! (permission-may-send? "eval-scheme" "tool" "(this does not read")
                 "a payload that does not read is not trusted")
    (check-false! (permission-may-send? "eval-scheme" "tool" "(buffer-text \"*scratch*\")")
                  "a read cannot send")
    (check-false! (permission-may-send? "eval-scheme" "tool" "(+ 1 2)")
                  "a built-in cannot send")
    (check-true! (permission-may-send? "mcp__thirdparty__post_message" "tool" "{}")
                 "a tool with no effects on record may send")
    (check-true! (permission-may-send? "curl -X POST https://example.com" "execute" "")
                 "a shell line can send")
    (check-false! (permission-may-send? "Read notes.txt" "read" "")
                  "an adapter's read cannot send")))

(deftest 'a-turn-an-outsider-started-asks-before-it-sends
  "in the default stance, a marked chat asks before a send and still runs a read"
  (lambda ()
    (let ((send "(http-post \"https://example.com\" \"the notes\")"))
      (t--pm-chat! #t)
      (check-equal! (permit? t--pm-buf "eval-scheme" "tool" send) 'ask
                    "a send in an outsider's turn asks")
      (check-equal! (permit? t--pm-buf "curl -X POST https://example.com" "execute" "") 'ask
                    "a shell line in an outsider's turn asks")
      (check-equal! (permit? t--pm-buf "eval-scheme" "tool" "(buffer-text \"*scratch*\")") 'allow-always
                    "a read in an outsider's turn runs")
      (t--pm-chat! #f)
      (check-equal! (permit? t--pm-buf "eval-scheme" "tool" send) 'allow-always
                    "the same send in a turn the user started runs as before")
      (buffer-kill! t--pm-buf))))

(deftest 'only-an-outside-source-marks-the-turn-and-the-user-clears-it
  "agent-note-turn-source! marks a chat that an event woke, and the user's next message clears it"
  (lambda ()
    (t--pm-chat! #f)
    (agent-note-turn-source! t--pm-buf "no-such-slug" "[cron] the daily sweep")
    (check-false! (eq? (buffer-local-value 'untrusted? t--pm-buf) #t) "a cron wake does not mark the turn")
    (agent-note-turn-source! t--pm-buf "no-such-slug" "[event] What you were listening for arrived: hi")
    (check-true! (eq? (buffer-local-value 'untrusted? t--pm-buf) #t) "an event wake marks the turn")
    (agent-note-turn-source! t--pm-buf "no-such-slug" "[cron] the daily sweep")
    (check-true! (eq? (buffer-local-value 'untrusted? t--pm-buf) #t) "another wake leaves the mark")
    (agent-note-turn-source! t--pm-buf "no-such-slug" "yes, go ahead")
    (check-false! (eq? (buffer-local-value 'untrusted? t--pm-buf) #t) "the user's message to a waiting chat clears it")
    (let ((saved agent-outside-sources))
      (set! agent-outside-sources '("event" "cron"))
      (agent-note-turn-source! t--pm-buf "no-such-slug" "[cron] the daily sweep")
      (check-true! (eq? (buffer-local-value 'untrusted? t--pm-buf) #t) "a source the user adds marks the turn")
      (set! agent-outside-sources saved))
    (buffer-kill! t--pm-buf)))
