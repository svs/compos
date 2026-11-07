;;; todo-test.scm --- the todo list's policy.

(domain! 'testing)
(effects! '(read write))

(deftest 'todo-chat-event-redraws-only-when-the-card-changes
  "a second event that leaves the chat-status row the same asks for no redraw"
  (lambda ()
    (let ((topic (string-append "chat:todo-test-" (number->string (current-time)))))
      (check-equal! (todo--chat-changed? topic) #t "the first event changes the card")
      (check-equal! (todo--chat-changed? topic) #f "the same row changes nothing")
      (set! *todo-chat-sigs* (filter (lambda (s) (not (equal? (car s) topic))) *todo-chat-sigs*)))))
