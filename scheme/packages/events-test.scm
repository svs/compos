;;; events-test.scm --- the event log: topics, positions, views.

(domain! 'testing)
(effects! '(write))

(define *events-test-seen* '())
(define (events-test--take e) (set! *events-test-seen* (cons (plist-get e 'kind) *events-test-seen*)))
(define (events-test--boom e) (error "boom"))
(define (events-test--count state e) (+ state 1))

(deftest 'events-topic-patterns
  "a pattern names one topic, or every topic that starts with it before the star"
  (lambda ()
    (check-equal! (event-topic-match? "chat:1" "chat:1") #t "exact")
    (check-equal! (event-topic-match? "chat:1" "chat:12") #f "exact is not a prefix")
    (check-equal! (event-topic-match? "chat:*" "chat:12") #t "prefix")
    (check-equal! (event-topic-match? "chat:*" "job:1") #f "other topic")))

(deftest 'events-subscriber-takes-its-topic-and-keeps-a-position
  "a subscriber gets only what its pattern matches, and its position follows"
  (lambda ()
    (set! *events-test-seen* '())
    (event-subscribe! "zz-events-a" "zz:a:*" 'events-test--take)
    (event-publish! "zz:a:1" 'one)
    (event-publish! "zz:b:1" 'other)
    (let ((seq (event-publish! "zz:a:2" 'two)))
      (check-equal! (reverse *events-test-seen*) '(one two) "only the matching events, in order")
      (check-equal! (event-position "zz-events-a") seq "the position is the last event it took"))
    (event-unsubscribe! "zz-events-a")))

(deftest 'events-returning-subscriber-takes-what-it-missed
  "a name that subscribes again first takes the events after its position"
  (lambda ()
    (set! *events-test-seen* '())
    (event-subscribe! "zz-events-b" "zz:c" 'events-test--take)
    (set! *event-subs* (filter (lambda (s) (not (equal? (car s) "zz-events-b"))) *event-subs*))
    (event-publish! "zz:c" 'missed)
    (check-equal! *events-test-seen* '() "nothing arrives while it is away")
    (event-subscribe! "zz-events-b" "zz:c" 'events-test--take)
    (check-equal! *events-test-seen* '(missed) "the missed event arrives on return")
    (event-unsubscribe! "zz-events-b")))

(deftest 'events-bad-subscriber-does-not-stall
  "a subscriber that raises moves past the event, and the others still get it"
  (lambda ()
    (set! *events-test-seen* '())
    (event-subscribe! "zz-events-boom" "zz:d" 'events-test--boom)
    (event-subscribe! "zz-events-ok" "zz:d" 'events-test--take)
    (let ((seq (event-publish! "zz:d" 'x)))
      (check-equal! *events-test-seen* '(x) "the next subscriber still gets it")
      (check-equal! (event-position "zz-events-boom") seq "the failed one moved on"))
    (event-unsubscribe! "zz-events-boom")
    (event-unsubscribe! "zz-events-ok")))

(deftest 'events-view-folds-its-pattern
  "a view folds the events of its pattern, from the log at definition and after"
  (lambda ()
    (event-publish! "zz:e:1" 'x)
    (event-define-view! 'zz-events-count "zz:e:*" 'events-test--count 0)
    (let ((before (event-view 'zz-events-count)))
      (check-equal! (> before 0) #t "the log builds the view at definition")
      (event-publish! "zz:e:2" 'y)
      (event-publish! "zz:f:1" 'z)
      (check-equal! (event-view 'zz-events-count) (+ before 1) "only its pattern counts"))))

(deftest 'events-chat-status-view
  "the chat-status view keeps a chat's last status and its last stop reason"
  (lambda ()
    (event-publish! "chat:zz-events" 'status '(status running))
    (event-publish! "chat:zz-events" 'turn-end '(stop-reason "cancelled" ok #f))
    (event-publish! "chat:zz-events" 'status '(status idle))
    (let ((row (event-view-get 'chat-status "chat:zz-events")))
      (check-equal! (plist-get row 'status) 'idle "the last status")
      (check-equal! (plist-get row 'stop-reason) "cancelled" "the last stop reason")
      (check-equal! (plist-get row 'turns) 1 "one turn ended"))))
