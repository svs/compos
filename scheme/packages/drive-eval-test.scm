;;; drive-eval-test.scm --- drive-eval counts the rounds and tool calls of the last turn.

(deftest 'drive-eval-counts-only-the-last-turn
  "rounds are the model replies after the last prompt, tools the tool calls in them"
  (lambda ()
    ;; chat-record is newest first
    (let ((rec (list '(role "status" blocks (("text" "done")))
                     '(role "assistant" blocks (("text" "7")))
                     '(role "assistant" blocks (("tool-use" "t2" "read" "{}") ("tool-result" "x")
                                                  ("tool-use" "t3" "read" "{}") ("tool-result" "y")))
                     '(role "user" blocks (("text" "how many lines?")))
                     '(role "assistant" blocks (("tool-use" "t1" "read" "{}") ("tool-result" "z")))
                     '(role "user" blocks (("text" "earlier"))))))
      (check-equal! (drive-eval--count rec) '(2 2) "two replies, two tool calls, the earlier turn left out"))))

(deftest 'drive-eval-table-says-each-model
  "the first line scores each model; a row shows ok or NO, rounds, tools and seconds"
  (lambda ()
    (let* ((rows '((count haiku #t 2 1 5000 "end_turn") (count opus #f 3 2 12000 "end_turn")))
           (text (drive-eval--text rows '((haiku) (opus)) '((count)))))
      (check-true! (string-prefix? "drive-eval: haiku 1/1 ok" text) "the score line")
      (check-true! (string-contains? text "NO 3r 2t 12.0s") "the failed run"))))
