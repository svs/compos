;;; agent-test.scm --- the model a chat shows after the adapter reports one.
;;;
;;; The adapter reports its own name for the model it runs. A chat shows
;;; the model the person chose, as they chose it. A chat with no choice
;;; shows the adapter's report.

(domain! 'testing)
(effects! '(read))

(define t--ag-buf "*zz-agent-model*")

(define t--ag-available
  '(("default" "Default (recommended)") ("opus[1m]" "Opus 5.5") ("sonnet" "Sonnet 5")))

(define (t--ag-chat! pin)
  (test-buffer! t--ag-buf "")
  (buffer-set-local! t--ag-buf 'agent-slug "zz-ag")
  (buffer-set-local! t--ag-buf 'agent-connector "zz-connector")
  (buffer-set-local! t--ag-buf 'agent-model pin)
  t--ag-buf)

(define (t--ag-report! cur)
  (agent-handle-event "zz-ag"
    (list 'type 'model-state 'current cur 'available t--ag-available))
  (buffer-local t--ag-buf 'agent-model))

(effects! '(write))

(deftest 'a-chosen-model-shows-as-chosen
  "the adapter's report does not replace the chosen name"
  (lambda ()
    (t--ag-chat! "claude-opus-5-5[1m]")
    (check-equal! (t--ag-report! "opus[1m]") "claude-opus-5-5[1m]"
                  "the chosen name stays")))

(deftest 'a-chat-with-no-pin-takes-the-report
  "no pin: the chat shows what the adapter runs"
  (lambda ()
    (t--ag-chat! #f)
    (check-equal! (t--ag-report! "opus[1m]") "opus[1m]" "the report wins")))

;;; --- the backend's session rides with the conversation ----------------------

(deftest 'a-session-event-is-kept-with-the-conversation
  "the session id and the connector that issued it land in the chat's locals"
  (lambda ()
    (t--ag-chat! #f)
    (agent-handle-event "zz-ag" (list 'type 'session 'id "sess-1" 'resumed #f))
    (check-equal! (buffer-local t--ag-buf 'agent-session) "sess-1" "the id is kept")
    (check-equal! (buffer-local t--ag-buf 'agent-session-connector) "zz-connector"
                  "with the connector that issued it")
    (check-equal! (and (member 'agent-session chat-conversation-locals) #t) #t
                  "a reset clears it with the conversation")))
