;;; drive-eval-test.scm --- drive-eval counts the rounds and tool calls of the last turn.

(require 'drive-eval)

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
  "the first line scores each model; a cell shows passed/runs and median rounds, tools and seconds"
  (lambda ()
    (let* ((rows '((count haiku #t 2 1 5000 "end_turn" () "7") (count opus #f 3 2 12000 "end_turn" (("round 1 model" 900)) "8")))
           (text (drive-eval--text rows '((haiku) (opus)) '((count)))))
      (check-true! (string-prefix? "drive-eval: haiku 1/1 ok" text) "the score line")
      (check-true! (string-contains? text "0/1 3.0r 2.0t 12.0s") "the failed run")
      (check-true! (string-contains? text "round 1 model 900") "and where its time went"))))

(deftest 'drive-eval-friction-names-each-wasted-call
  "each tool call is useful or wasted with a kind; a round is wasted when every call in it is"
  (lambda ()
    ;; oldest first, as a chat log keeps it
    (let* ((use (lambda (id name input result) (list (list "tool-use" id name input) (list "tool-result" id result #f))))
           (rec (list '(role "user" blocks (("text" "count the lines")))
                      (list 'role "assistant" 'blocks (use "a" "ToolSearch" "{}" "Tool: x"))
                      (list 'role "assistant" 'blocks (use "b" "eval-scheme-read" "{\"query\":\"1\"}" "error: eval-scheme-read takes {code}; you sent {query}, missing code."))
                      (list 'role "assistant" 'blocks (use "c" "eval-scheme-read" "{\"code\":\"(lines-of b)\"}" "refused: lines-of is unbound."))
                      (list 'role "assistant" 'blocks (use "d" "apropos" "{\"query\":\"lines\"}" "((kind \"function\" name \"nothing-used\"))"))
                      (list 'role "assistant" 'blocks (append (use "e" "apropos" "{\"query\":\"count\"}" "((kind \"function\" name \"buffer-line-count\"))")
                                                                (use "f" "eval-scheme-read" "{\"code\":\"(buffer-line-count b)\"}" "3")))
                      (list 'role "assistant" 'blocks (use "g" "eval-scheme-read" "{\"code\":\"(buffer-line-count b)\"}" "3"))))
           (fr (drive-eval-friction rec)))
      (check-equal! (map car fr) '(schema-load wrong-args unbound dead-discovery #f #f repeated) "the kind of each call, in order")
      (check-equal! (drive-eval-wasted fr) 5 "the round of a used search and its call is not wasted")
      (check-true! (string-contains? (drive-eval-friction-text (list (list 'count 'haiku fr))) "5 of 6 tool rounds wasted") "the report counts rounds"))))
