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
