;;; agent-listen-test.scm --- a listener takes the events its SPEC names.
;;;
;;; A listener with no kind takes every kind except sent. The feeds publish
;;; the user's own outgoing messages as sent, so the agent's own reply must
;;; not wake the agent that listens on the same conversation.

(domain! 'testing)
(effects! '(pure))

(define (t--listen-event kind text)
  (list 'topic "whatsapp:910000000000" 'kind kind 'seq 1
        'data (list 'text text 'sender "Vipul")))

(deftest 'a-listener-with-no-kind-skips-sent-events
  "a listener with no kind takes a received event and skips a sent one"
  (lambda ()
    (let ((l (list 'id "l1" 'topic "whatsapp:910000000000")))
      (check-true! (agent-listen--wants? l (t--listen-event 'received "on my way"))
                   "a received message wakes the agent")
      (check-false! (agent-listen--wants? l (t--listen-event 'sent "sent by the agent"))
                    "the agent's own sent message does not wake it"))))

(deftest 'a-listener-that-names-a-kind-takes-only-that-kind
  "a listener that names a kind takes that kind, sent too, and no other kind"
  (lambda ()
    (let ((sent (list 'id "l2" 'topic "whatsapp:910000000000" 'kind "sent"))
          (received (list 'id "l3" 'topic "whatsapp:910000000000" 'kind "received")))
      (check-true! (agent-listen--wants? sent (t--listen-event 'sent "hi"))
                   "a listener for sent takes a sent event")
      (check-false! (agent-listen--wants? sent (t--listen-event 'received "hi"))
                    "and skips a received one")
      (check-true! (agent-listen--wants? received (t--listen-event 'received "hi"))
                   "a listener for received takes a received event")
      (check-false! (agent-listen--wants? received (t--listen-event 'sent "hi"))
                    "and skips a sent one"))))

(deftest 'a-listener-match-still-filters-the-kinds-it-takes
  "the match text filters the events, and a sent event stays out with no kind"
  (lambda ()
    (let ((l (list 'id "l4" 'topic "whatsapp:910000000000" 'match "vipul")))
      (check-true! (agent-listen--wants? l (t--listen-event 'received "hello"))
                   "a received event whose data holds the match text wakes the agent")
      (check-false! (agent-listen--wants? (list 'id "l5" 'match "nobody")
                                          (t--listen-event 'received "hello"))
                    "a received event without the match text does not")
      (check-false! (agent-listen--wants? l (t--listen-event 'sent "hello"))
                    "a sent event stays out even when it holds the match text"))))
