;;; agent-verbs-test.scm --- the one-call verbs keep their contracts.

(require 'agent-verbs)

(deftest 'agent-verbs-chains-count-the-calls-agents-chain
  "heads are the editor calls of one eval, core Scheme left out; counts come most frequent first"
  (lambda ()
    (check-equal! (agent-verbs--heads "(let ((b (buffer-text \"x\"))) (buffer-replace! b \"a\" \"b\") (buffer-text b))")
                  '("buffer-text" "buffer-replace!") "each editor call once, let left out")
    (check-equal! (agent-verbs--count '("a" "b" "a" "c" "a" "b") 2) '((3 "a") (2 "b")) "top two by count")))

(deftest 'agent-verbs-file-edit-keeps-unsaved-work
  "file-edit! saves a file no one edits, and never saves a buffer with unsaved work of the user"
  (lambda ()
    (let ((path "/tmp/agent-verbs-edit-test.txt"))
      (write-file! path "one\ntwo\n")
      (check-equal! (plist-get (file-edit! path "two" "TWO") 'saved) #t "a closed file is saved")
      (check-equal! (read-file path) "one\nTWO\n" "the file has the edit")
      (check-false! (buffer-known? path) "the buffer it opened is closed")
      (let ((b (visit path)))
        (buffer-replace! b "one" "ONE")
        (let ((r (file-edit! path "TWO" "2")))
          (check-equal! (plist-get r 'saved) #f "unsaved work stays unsaved")
          (check-true! (string-prefix? "edited, not saved" (plist-get r 'result)) "the answer says why")
          (check-equal! (read-file path) "one\nTWO\n" "the file is as it was"))
        (buffer-kill! b)))))

(deftest 'agent-verbs-shell-job-wakes-the-chat-that-started-it
  "the done event of a shell-job! lands on the topic its chat listens to, even when another buffer is current as the command ends"
  (lambda ()
    (let ((a (buffer-create "*zz-shell-job-a*"))
          (b (buffer-create "*zz-shell-job-b*"))
          (heard #f) (said #f) (done #f))
      (buffer-set-local! a 'chat-id "chat:11:22")
      (buffer-set-local! b 'chat-id "chat:33:44")
      (with-stubs (list (list 'agent-listen! (lambda (spec note) (set! heard (plist-get spec 'topic)) 'zz-listener))
                        (list 'shell-command->string (lambda (cmd dir k) (set! done k)))
                        (list 'event-log-append! (lambda (topic kind data) (set! said topic) 1))
                        (list 'events--pump! (lambda () #f)))
        (lambda ()
          (with-current-buffer a (lambda () (shell-job! "zz" "true" "read it")))
          (with-current-buffer b (lambda () (done "ok")))))
      (check-equal! heard "job:11-22:zz" "chat A listens on its own job topic")
      (check-equal! said heard "the end of the command is published where chat A listens")
      (buffer-kill! a)
      (buffer-kill! b))))
