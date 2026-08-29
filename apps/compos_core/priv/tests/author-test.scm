;;; author-test.scm --- who wrote which line.
;;;
;;; Every edit carries an author. with-edit-author is the Scheme surface
;;; for it, and it stamps the same string the Elixir source option does,
;;; so a test needs nothing but Scheme to make an agent's edit.
;;;
;;; The provenance mechanics — the rope, the run merging, the edit log's
;;; own shape — stay in ExUnit with Buffer.

(domain! 'testing)
(effects! '(write))

(define t--author-buf "zz-author")

(define (t--author! text) (test-buffer! t--author-buf text))

(define (t--author-append! who text)
  (with-edit-author who (lambda () (buffer-append! t--author-buf text))))

(deftest 'an-agent-asks-which-line-runs-are-its-own
  "the runs are line numbers, so an agent can name what it may rewrite"
  (lambda ()
    (t--author! "")
    (t--author-append! "agent:c1" "mine one\nmine two\n")
    (t--author-append! "human" "yours\n")
    (t--author-append! "agent:c1" "mine three\n")

    (check-equal! (author-line-runs t--author-buf "agent:c1") '((1 2) (4 4))
                  "two runs, with the human's line between them")
    (check-true! (lines-mine? t--author-buf 1 2 "agent:c1") "the first run is its own")
    (check-false! (lines-mine? t--author-buf 1 3 "agent:c1")
                  "and a span reaching the human's line is not")
    (buffer-kill! t--author-buf)))

(deftest 'a-line-the-agent-only-part-edited-is-nobody-s-to-claim-alone
  "a line with two authors belongs to neither of them by itself"
  (lambda ()
    (t--author! "")
    (t--author-append! "human" "shared line\n")
    (with-edit-author "agent:c1" (lambda () (buffer-insert! t--author-buf 6 "X")))

    (check-false! (lines-mine? t--author-buf 1 1 "agent:c1") "not the agent's")
    (check-false! (lines-mine? t--author-buf 1 1 "human") "and not the human's")
    (check-equal! (author-line-runs t--author-buf "agent:c1") '()
                  "so the agent owns no run at all")
    (buffer-kill! t--author-buf)))

(deftest 'buffer-authors-and-buffer-edit-log-read-from-scheme
  "the spans and the log are values, not a rendering"
  (lambda ()
    (t--author! "")
    (t--author-append! "agent:c1" "abc")
    (check-equal! (buffer-authors t--author-buf) '((0 3 "agent:c1")) "one span, one author")
    (check-contains! (value->string (buffer-edit-log t--author-buf)) "\"agent:c1\" 0 3 0"
                     "and the log names the same edit")
    (buffer-kill! t--author-buf)))

(deftest 'agent-attribution-does-not-remove-scheme-mechanisms
  "with-edit-author wraps a thunk; whatever the thunk does still works"
  (lambda ()
    (check-contains! (shell-command->string "echo hi") "hi" "a shell call answers")
    (check-contains! (with-edit-author "agent:a1"
                       (lambda () (shell-command->string "echo hi")))
                     "hi" "and it still answers inside the wrapper")))
