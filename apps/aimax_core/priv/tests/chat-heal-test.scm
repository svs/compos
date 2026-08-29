;;; chat-heal-test.scm --- a tool call and its result are one unit on the wire.
;;;
;;; The provider rejects a result whose call it cannot see ("No tool call
;;; found for function call output"), and it rejects a call whose result
;;; never came. One such request wedges the whole chat, because every later
;;; turn replays the same broken prefix. The record heals itself before each
;;; send, and compaction no longer cuts a tool round in half.

(domain! 'testing)
(effects! '(read))

(define t--heal-buf "*zz-heal*")

;; a record, newest first, in one buffer local
(define (t--heal-turn role blocks) (list 'role role 'blocks blocks))
(define (t--heal-text t) (list "text" t))
(define (t--heal-call id) (list "tool-use" id "eval-scheme" "{}"))
(define (t--heal-result id) (list "tool-result" id "42" #f))

(effects! '(write))

(define (t--heal-put! turns)
  (test-buffer! t--heal-buf "")
  (buffer-set-local! t--heal-buf 'chat-wire-turns turns)
  t--heal-buf)

(define (t--heal-record) (buffer-local t--heal-buf 'chat-wire-turns))

(deftest 'a-result-whose-call-is-gone-loses-the-result
  "the compacted summary swallowed the turn that made the call"
  (lambda ()
    ;; newest first: only the results turn survived the compaction
    (t--heal-put!
      (list (t--heal-turn "assistant" (list (t--heal-text "done")))
            (t--heal-turn "user" (list (t--heal-result "tu_1")))
            (t--heal-turn "user" (list (t--heal-text "[compacted]")))))
    (check-equal! (chat-heal! t--heal-buf) 1 "one block dropped")
    (check-false! (string-contains? (value->string (t--heal-record)) "tool-result")
                  "the orphaned result is gone")
    (check-equal! (length (chat-turns t--heal-buf)) 2 "both prose turns stay")
    (buffer-kill! t--heal-buf)))

(deftest 'a-call-whose-result-never-came-loses-the-call
  "an aborted turn: the assistant asked for a tool, nothing answered"
  (lambda ()
    (t--heal-put!
      (list (t--heal-turn "assistant" (list (t--heal-call "tu_9")))
            (t--heal-turn "user" (list (t--heal-text "hello")))))
    (check-equal! (chat-heal! t--heal-buf) 1 "one block dropped")
    ;; the assistant turn held nothing else, so the turn goes with it
    (check-equal! (length (t--heal-record)) 1 "the empty turn goes too")
    (buffer-kill! t--heal-buf)))

(deftest 'a-whole-tool-round-survives-and-healing-writes-nothing
  "a matched call and result are left alone"
  (lambda ()
    (t--heal-put!
      (list (t--heal-turn "assistant" (list (t--heal-text "done")))
            (t--heal-turn "user" (list (t--heal-result "tu_1")))
            (t--heal-turn "assistant" (list (t--heal-text "calling") (t--heal-call "tu_1")))
            (t--heal-turn "user" (list (t--heal-text "hello")))))
    (let ((before (t--heal-record)))
      (check-equal! (chat-heal! t--heal-buf) 0 "nothing dropped")
      (check-equal! (t--heal-record) before "the record is unchanged"))
    (buffer-kill! t--heal-buf)))

(deftest 'healing-keeps-the-text-of-a-turn-whose-call-it-drops
  "the prose is not the orphan"
  (lambda ()
    (t--heal-put!
      (list (t--heal-turn "assistant" (list (t--heal-text "I will look") (t--heal-call "tu_7")))
            (t--heal-turn "user" (list (t--heal-text "hello")))))
    (check-equal! (chat-heal! t--heal-buf) 1 "one block dropped")
    (check-contains! (value->string (t--heal-record)) "I will look" "the text stays")
    (check-equal! (length (t--heal-record)) 2 "both turns stay")
    (buffer-kill! t--heal-buf)))

(deftest 'healing-keeps-a-turns-wire-text
  "the wire text is the turn's own, and healing does not read it"
  (lambda ()
    (t--heal-put!
      (list (list 'role "user" 'blocks (list (t--heal-result "tu_x")))
            (list 'role "user" 'blocks (list (t--heal-text "hi")) 'wire "hi + context")))
    (check-equal! (chat-heal! t--heal-buf) 1 "one block dropped")
    (check-contains! (value->string (t--heal-record)) "hi + context" "the wire text stays")
    (buffer-kill! t--heal-buf)))

(deftest 'the-compaction-window-opens-on-a-user-message-never-on-tool-results
  "a results turn carries the user role and is not a user message"
  (lambda ()
    ;; newest first. With chat-compact-keep at 1 the window used to stop at
    ;; the results turn — a "user" role that is not a user message.
    (let ((record
            (list (t--heal-turn "assistant" (list (t--heal-text "done")))
                  (t--heal-turn "user" (list (t--heal-result "tu_1")))
                  (t--heal-turn "assistant" (list (t--heal-call "tu_1")))
                  (t--heal-turn "user" (list (t--heal-text "do it")))
                  (t--heal-turn "assistant" (list (t--heal-text "older")))
                  (t--heal-turn "user" (list (t--heal-text "older question")))))
          (old chat-compact-keep))
      (set-symbol-value! 'chat-compact-keep 1)
      (let ((keep (chat-compact-keep-count record)))
        (set-symbol-value! 'chat-compact-keep old)
        ;; 4: everything back to the "do it" that started the round
        (check-equal! keep 4 "the window reaches the user message")))))

(deftest 'the-chat-heal-command-reports-what-it-dropped
  "the echo says what happened, both ways"
  (lambda ()
    (let ((buf (group-chat "zzhealg")))
      (switch-to-buffer! buf)
      (set-mode! "chat-mode")
      (buffer-set-local! buf 'chat-wire-turns
        (list (list 'role "user" 'blocks (list (t--heal-result "tu_z")))))

      (let ((mark (string-length (buffer-text "*Messages*"))))
        (run-command "chat-heal")
        (let ((said (buffer-text "*Messages*")))
          (check-contains! (substring said mark (string-length said))
                           "dropped 1 orphaned tool block" "the first report")))

      (let ((mark (string-length (buffer-text "*Messages*"))))
        (run-command "chat-heal")
        (let ((said (buffer-text "*Messages*")))
          (check-contains! (substring said mark (string-length said))
                           "record is whole" "the second report")))

      (buffer-kill! buf)
      (let ((id (group-resolve-id "zzhealg")))
        (when id (group-record-delete! id))))))
