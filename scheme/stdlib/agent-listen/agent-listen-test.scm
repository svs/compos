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

(deftest 'a-listener-key-is-chat-topic-kind-and-match
  "the same chat, topic, kind and match is one listener; any of them differing is another"
  (lambda ()
    (let* ((a (list 'id "la" 'chat "chat:1:1" 'topic "whatsapp:91" 'kind "received" 'match "INV-7"))
           (ls (list a)))
      (check-equal! (plist-get (agent-listen--twin (list 'id "lb" 'chat "chat:1:1" 'topic "whatsapp:91" 'kind "received" 'match "INV-7" 'note "other") ls) 'id)
                    "la" "the same key answers the live listener")
      (check-false! (agent-listen--twin (list 'chat "chat:2:2" 'topic "whatsapp:91" 'kind "received" 'match "INV-7") ls)
                    "another chat is another listener")
      (check-false! (agent-listen--twin (list 'chat "chat:1:1" 'topic "whatsapp:91" 'kind "sent" 'match "INV-7") ls)
                    "another kind is another listener")
      (check-false! (agent-listen--twin (list 'chat "chat:1:1" 'topic "whatsapp:91" 'kind "received") ls)
                    "another match is another listener")
      (check-equal! (agent-listen--key (list 'chat "c" 'topic "t" 'match "  "))
                    (agent-listen--key (list 'chat "c" 'topic "t"))
                    "a blank match is no match"))))

(deftest 'a-time-listener-key-is-chat-and-at
  "two time listeners of one chat at one time are one, whatever their topics"
  (lambda ()
    (let ((a (list 'id "lt" 'chat "chat:1:1" 'topic "time:lt" 'at 1800000000)))
      (check-equal! (plist-get (agent-listen--twin (list 'chat "chat:1:1" 'topic "time:new" 'at 1800000000) (list a)) 'id)
                    "lt" "same chat and at")
      (check-false! (agent-listen--twin (list 'chat "chat:1:1" 'topic "time:new" 'at 1800000060) (list a))
                    "another time is another listener"))))

(deftest 'another-chat-on-the-same-channel-and-task-is-a-peer
  "a listener of another chat on the same channel for the same task is a peer to warn about"
  (lambda ()
    (let ((other (list 'id "lo" 'chat "chat:2:2" 'topic "whatsapp:91" 'kind "received" 'task "t-1"))
          (mine (list 'chat "chat:1:1" 'topic "whatsapp:91" 'kind "received" 'task "t-1")))
      (check-equal! (map (lambda (x) (plist-get x 'id)) (agent-listen--peers mine (list other)))
                    '("lo") "the other chat's listener is a peer")
      (check-equal! (agent-listen--peers (plist-put mine 'task "t-2") (list other))
                    '() "another task is no peer")
      (check-equal! (agent-listen--peers (plist-put mine 'task #f) (list other))
                    '() "no task, no peer"))))
