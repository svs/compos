;;; agent-perf-test.scm --- the events of a turn become model rounds and tool calls.

(deftest 'agent-perf-times-rounds-and-tools-from-the-events
  "a round runs to the next tool call; a tool runs to its completion; the turn end closes the last round"
  (lambda ()
    (let* ((steps (list (list 0 '(type user-msg text "go"))
                        (list 100 '(type tool-call id "a" name "read"))
                        (list 100 '(type tool-call id "b" name "find"))
                        (list 150 '(type tool-update id "a" status "completed"))
                        (list 180 '(type tool-update id "b" status "completed"))
                        (list 400 '(type turn-end stop-reason "end_turn"))))
           (st (fold (lambda (st s) (agent-perf--event st (cadr s) (+ 1000 (car s)))) #f steps))
           (rows (map (lambda (r) (list (car r) (- (caddr r) (cadr r)))) (reverse (list-ref st 4)))))
      (check-equal! rows '(("round 1 model" 100) ("tool read" 50) ("tool find" 80) ("round 2 model" 220))
                    "two parallel tools sit in one round; the next round starts when both are done"))))
