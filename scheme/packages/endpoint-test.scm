;;; endpoint-test.scm --- the endpoint registry, fan-out, and discovery.

(deftest 'an-endpoint-spec-survives-under-its-name
  "a caller names a connection once and reconnects from the name"
  (lambda ()
    (endpoint-register! "t-reg" '(command "cat" framing "line"))
    (check-equal! (plist-get (endpoint-spec "t-reg") 'command) "cat" "the spec")
    (check-equal! (endpoint-spec "t-nothing") #f "an unregistered name")))

(deftest 'ensure-refuses-a-name-nobody-registered
  "a typo asks for a connection that cannot exist; say so"
  (lambda ()
    (check-equal! (endpoint-connected? "t-unknown") #f "not connected")))

(deftest 'every-listener-hears-an-endpoint-event
  "the primitive holds one slot, so this package must fan out"
  (lambda ()
    (let ((heard '()))
      (add-hook! (list 'endpoint-event "t-a") (lambda (n k tx) (set! heard (cons (list "a" n k tx) heard))))
      (add-hook! (list 'endpoint-event "t-b") (lambda (n k tx) (set! heard (cons (list "b" n k tx) heard))))
      (run-hook-with-args 'endpoint-event "conn" "frame" "hi")
      (check-equal! (length heard) 2 "both listeners ran"))))

(deftest 'the-registry-names-every-connection-a-package-registered
  "a manager of these programs reads the registry rather than keeping a list"
  (lambda ()
    (endpoint-register! "t-named" '(command "cat" framing "line"))
    (check-true! (member "t-named" (endpoint-names)) "the name is in the registry")
    (check-false! (member "t-never-registered" (endpoint-names)) "and only a registered one")))

(deftest 'a-json-line-daemon-answers-the-shape-an-http-reply-answers
  "a caller reads one shape whether it asked a server, a socket, or a pipe"
  (lambda ()
    (let ((r (endpoint-json-reply #t (list "{\"ok\": true, \"models\": []}"))))
      (check-true! (http-ok? r) "ok is an answer")
      (check-equal! (plist-get (http-json r) 'models) '() "and the body is its JSON"))
    (let ((r (endpoint-json-reply #t (list "{\"ok\": false, \"error\": \"no\"}"))))
      (check-false! (http-ok? r) "a refusal is not an answer"))
    (let ((r (endpoint-json-reply #t (list "not json at all"))))
      (check-false! (http-ok? r) "and neither is a line that is not JSON"))))

(deftest 'asking-a-daemon-that-is-not-running-answers-rather-than-raising
  "a manager asks before it knows; an unopened pipe is a reply, not a crash"
  (lambda ()
    (let ((got #f))
      (endpoint-ask-json "t-not-running" '(op "models") 1000
        (lambda (reply) (set! got reply)))
      (check-true! (pair? got) "the callback ran at once")
      (check-false! (http-ok? got) "and it says the daemon is not running")
      (check-true! (string-contains? (http-message got) "not running") "in those words"))))

;;; --- discovery ---------------------------------------------------------------
;;; The mechanism is only useful if the person writing a connector can
;;; find it. These are the words they actually search for.

;;; The word "socket" is the trap: sockets.scm lists the sockets this
;;; daemon holds open, which is not how a package opens a client
;;; connection. A searcher must reach the endpoint API from that word.
;; The daemons a package registers (laya, needle) are specs here, not code
;; of their own: one test over the registry says what every one must say.
(deftest 'every-bundled-daemon-registers-where-a-manager-looks-and-ships-its-script
  "a line-framed daemon that serves models names its command and a script that is there"
  (lambda ()
    (let ((daemons (filter (lambda (n)
                             (let ((spec (endpoint-spec n)))
                               (and (pair? spec)
                                    (equal? (plist-get spec 'framing) "line")
                                    (equal? (plist-get spec 'serves) "models"))))
                           (endpoint-names))))
      (for-each (lambda (n)
                  (check-true! (member n daemons)
                               (string-append n " is in the endpoint registry, framed by lines, serving models")))
                '("laya" "needle"))
      (for-each
        (lambda (n)
          (let* ((spec (endpoint-spec n))
                 (scripts (filter (lambda (a) (and (string? a) (string-suffix? "-daemon.py" a)))
                                  (or (plist-get spec 'args) '()))))
            (check-true! (string? (plist-get spec 'command))
                         (string-append n " names the program that runs it"))
            (check-true! (pair? scripts)
                         (string-append n " names the daemon script it runs"))
            (for-each (lambda (s)
                        (check-true! (file-exists? s)
                                     (string-append n ": " s " ships with the editor")))
                      scripts)))
        daemons))))
