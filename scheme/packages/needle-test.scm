;;; needle-test.scm --- packages/needle.scm: the on-device tool caller.
;;;
;;; Nothing here starts the daemon or answers a question. What this
;;; package owns is which catalog rows it is allowed to offer and which
;;; band a reply falls in. Its registration and its script are checked
;;; with every bundled daemon's, in endpoint-test.scm.

(domain! 'testing)
(effects! '(read))

(deftest 'needle-offers-only-what-a-call-can-name
  "five slots, and a key or a mode in one of them is a slot spent on nothing"
  (lambda ()
    (let ((rows (needle-rows)))
      (check-true! (pair? rows) "the catalog reaches the daemon")
      (check-true! (pair? (filter (lambda (r) (equal? (plist-get r 'name) "visit")) rows))
                   "a function is offered")
      (check-false! (pair? (filter (lambda (r) (string-prefix? "C-" (plist-get r 'name))) rows))
                    "a key binding is not, because the editor cannot call one")
      (let ((row (nth 0 rows)))
        (check-true! (string? (plist-get row 'name)) "each row names itself")
        (check-true! (string? (plist-get row 'doc)) "carries the doc it is ranked by")
        (check-true! (string? (plist-get row 'sig))
                     "and the signature its arguments are read from")))))

(deftest 'needle-tells-an-answer-from-a-silent-daemon
  "a daemon that did not answer must not read as a refusal, which is an answer"
  (lambda ()
    (let ((r (needle-reply '(ok #t json (ok #t calls () confidence 1.0)))))
      (check-equal! (needle-confidence r) 1.0 "the body is the answer")
      (check-equal! (needle-calls r) '() "and its empty call list is a refusal"))
    (let ((r (needle-reply '(ok #f error "the pipe closed"))))
      (check-false! (plist-get r 'ok) "a dead pipe is not an answer")
      (check-true! (string-contains? (plist-get r 'error) "pipe") "and it says what happened"))))

(deftest 'needle-routes-a-reply-to-act-confirm-or-refuse
  "a tool call is an action, so a middling score reaches a person and not the editor"
  (lambda ()
    (let ((sure '(calls ((name "visit")) held () confidence 0.95))
          (unsure '(calls ((name "visit")) held () confidence 0.4))
          (withheld '(calls () held ((name "visit")) confidence 0.99))
          (empty '(calls () held () confidence 1.0)))
      (check-equal! (needle-verdict sure) 'act "a call the model stands behind runs")
      (check-equal! (needle-verdict unsure) 'confirm "a call it half believes is shown first")
      (check-equal! (needle-verdict withheld) 'confirm
                    "and a withheld call is shown too, whatever its score says")
      (check-equal! (needle-verdict empty) 'refuse
                    "an empty call list is the whole contract for no tool does that"))))

(deftest 'needle-lets-the-words-pick-the-tool
  "the model does not improve on the retriever's first choice; it loses to it"
  (lambda ()
    (check-equal! needle-candidates 1
                  "one row is offered, so the words choose and the model fills")
    (check-true! (<= needle-candidates 5)
                 "and never more than one turn can hold")))

(deftest 'needle-answers-without-the-rung-it-prefers
  "a machine that never built the shallow rung still routes, 20 ms slower"
  (lambda ()
    (let ((held needle-ladder))
      (set! needle-ladder "/no/such/rung.cact")
      (check-true! (needle-available?)
                   "a missing rung is not what makes needle unavailable")
      (check-true! (member "NEEDLE_WEIGHTS" (map value->string (plist-get (needle-spec) 'env)))
                   "the spec still names it, and the daemon falls back when it is absent")
      (set! needle-ladder held))))
