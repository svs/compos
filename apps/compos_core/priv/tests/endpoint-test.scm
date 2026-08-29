;;; endpoint-test.scm --- the endpoint registry, fan-out, and discovery.

(deftest 'an-endpoint-spec-survives-under-its-name
  "a caller names a connection once and reconnects from the name"
  (lambda ()
    (endpoint-register! "t-reg" '(command "cat" framing "line"))
    (check-equal! (plist-get (endpoint-spec "t-reg") 'command) "cat" "the spec")
    (check-equal! (endpoint-spec "t-nothing") #f "an unregistered name")))

(deftest 'registering-the-same-name-twice-replaces-the-spec
  "a spec is a name's current answer, not a growing list"
  (lambda ()
    (endpoint-register! "t-twice" '(command "cat"))
    (endpoint-register! "t-twice" '(command "sh"))
    (check-equal! (plist-get (endpoint-spec "t-twice") 'command) "sh" "the later spec")
    (check-equal!
      (length (filter (lambda (e) (equal? (car e) "t-twice")) *endpoint-registry*))
      1 "one entry")))

(deftest 'ensure-refuses-a-name-nobody-registered
  "a typo asks for a connection that cannot exist; say so"
  (lambda ()
    (check-equal! (endpoint-connected? "t-unknown") #f "not connected")))

(deftest 'every-listener-hears-an-endpoint-event
  "the primitive holds one slot, so this package must fan out"
  (lambda ()
    (let ((heard '()))
      (on-endpoint-event! "t-a" (lambda (n k tx) (set! heard (cons (list "a" n k tx) heard))))
      (on-endpoint-event! "t-b" (lambda (n k tx) (set! heard (cons (list "b" n k tx) heard))))
      (for-each (lambda (e) ((cadr e) "conn" "frame" "hi")) *endpoint-event-handlers*)
      (check-equal! (length heard) 2 "both listeners ran"))))

(deftest 'a-listener-name-replaces-its-own-earlier-listener
  "a reload must not stack a second copy of the same listener"
  (lambda ()
    (on-endpoint-event! "t-dup" (lambda (n k tx) #f))
    (on-endpoint-event! "t-dup" (lambda (n k tx) #f))
    (check-equal!
      (length (filter (lambda (e) (equal? (car e) "t-dup")) *endpoint-event-handlers*))
      1 "one listener")))

;;; --- discovery ---------------------------------------------------------------
;;; The mechanism is only useful if the person writing a connector can
;;; find it. These are the words they actually search for.

(define (endpoint--apropos-finds? query)
  (pair? (filter (lambda (e)
                   (let ((n (or (plist-get e 'qualified-name) "")))
                     (string-contains? n "endpoint")))
                 (apropos query))))

(deftest 'apropos-finds-the-endpoint-api-by-what-it-is-for
  "a connector author searches for the job, not for our word"
  (lambda ()
    (for-each
      (lambda (q)
        (check-true! (endpoint--apropos-finds? q)
          (string-append "apropos finds endpoints for: " q)))
      ;; one query per way somebody arrives at this API; apropos is the
      ;; slowest thing in this suite, so this list stays short
      '("subprocess" "socket" "persistent connection"))))

;;; The word "socket" is the trap: sockets.scm lists the sockets this
;;; daemon holds open, which is not how a package opens a client
;;; connection. A searcher must reach the endpoint API from that word.
(deftest 'searching-for-a-socket-reaches-the-client-api-not-the-listener-list
  "the daemon's own listeners must not absorb the whole word"
  (lambda ()
    (let ((names (map (lambda (e) (or (plist-get e 'qualified-name) ""))
                      (apropos "socket"))))
      (check-true! (pair? (filter (lambda (n) (string-contains? n "endpoint")) names))
        "the endpoint API is reachable from \"socket\"")
      (check-true!
        (let loop ((xs names))
          (cond ((null? xs) #f)
                ((string-contains? (car xs) "endpoint") #t)
                ((string-contains? (car xs) "sockets/") #f)
                (else (loop (cdr xs)))))
        "an endpoint row comes before the listener rows"))))
