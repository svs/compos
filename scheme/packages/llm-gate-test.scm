;;; llm-gate-test.scm --- the direct lane's gate, concurrency and retry rules.
;;;
;;; The gate is a security boundary: each refusal the Elixir gate made has a
;;; check here. Elixir adds one more: no verdict at all is a denial
;;; (permission_test.exs, tool_gate_contract_test.exs).

(domain! 'testing)
(effects! '(read))

(define (llm-gate-test--policy answer)
  (lambda (slug name kind raw) answer))

(deftest 'llm-gate-refuses-what-the-policy-rejects
  "reject denies with the reason the model reads; ask asks the user"
  (lambda ()
    (check-equal! (llm-tool-gate (llm-gate-test--policy 'reject) "a1" "eval-scheme" "raw" '())
                  '(deny "denied by policy")
                  "reject is a denial")
    (check-equal! (llm-tool-gate (llm-gate-test--policy 'ask) "a1" "eval-scheme" "raw" '())
                  '(ask-permission)
                  "ask asks the user")))

(deftest 'llm-gate-allows-only-what-it-did-before
  "only the symbols ask and reject stop a call; no policy allows"
  (lambda ()
    (for-each
      (lambda (answer)
        (check-equal! (llm-tool-gate (llm-gate-test--policy answer) "a1" "eval-scheme" "raw" '())
                      'allow
                      (string-append "policy answer " (value->string answer))))
      (list 'allow #f #t "reject" "ask" 'always))
    (check-equal! (llm-tool-gate #f "a1" "eval-scheme" "raw" '()) 'allow
                  "a loop with no policy runs its tools")))

(deftest 'llm-gate-passes-the-policy-what-it-matches
  "the policy sees the slug, the tool name, the kind tool and the raw text"
  (lambda ()
    (let ((seen #f))
      (llm-tool-gate (lambda (slug name kind raw) (set! seen (list slug name kind raw)) 'allow)
                     "a1" "eval-scheme" "eval-scheme %{...}" '())
      (check-equal! seen '("a1" "eval-scheme" "tool" "eval-scheme %{...}")
                    "the policy's arguments"))))

(deftest 'llm-gate-a-crashing-policy-gives-no-verdict
  "a policy that raises makes the gate raise, and Elixir denies a gate with no verdict"
  (lambda ()
    (check-false! (ignore-errors
                    (lambda () (llm-tool-gate (lambda (s n k r) (car '())) "a1" "eval-scheme" "raw" '())))
                  "no verdict comes back")))

(deftest 'llm-gate-answers-the-ask-tool-itself
  "ask is never put to the policy; a bad ask is an error result"
  (lambda ()
    (let ((reject (lambda (s n k r) (error "the policy must not see ask"))))
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" '(question "Which?" answers ("a" "b" 3)))
                    '(ask-user "Which?" ("a" "b" "3"))
                    "a question and its answers")
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" '(question "Which?"))
                    '(ask-user "Which?" ())
                    "answers are optional")
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" '(question "Which?" answers "a"))
                    '(ask-user "Which?" ())
                    "answers that are not a list are none")
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" '(answers ("a")))
                    '(error "ask requires a question and an answers array")
                    "no question")
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" '(question 7))
                    '(error "ask requires a question and an answers array")
                    "a question that is not text")
      (check-equal! (llm-tool-gate reject "a1" "ask" "raw" #f)
                    '(error "ask requires a question and an answers array")
                    "no input"))))

(deftest 'llm-gate-read-only-tools-follow-the-first-effect
  "pure and read tools may run side by side; the rest, and the undeclared, may not"
  (lambda ()
    (check-equal! (llm-read-only-tools
                    (list (list 'buffer-text "d" '() '(read))
                          (list "code-outline" "d" '() '(pure external))
                          (list 'buffer-append! "d" '() '(write))
                          (list 'mixed "d" '() '(write read))
                          (list 'bare "d" '())
                          (list 'none "d" '() '())
                          (list 'single "d" "{}" 'read)))
                  '("buffer-text" "code-outline" "single")
                  "the read-only names")
    (check-equal! (llm-read-only-tools '()) '() "no tools")))

(deftest 'llm-gate-retry-reads-the-whole-error-chain
  "the same calls retry as in the Elixir rule"
  (lambda ()
    (for-each
      (lambda (case)
        (check-equal! (llm-retryable? (car case)) (cadr case) (value->string (car case))))
      (list (list '(503 #f) #t)
            (list '(529 #f) #t)
            (list '(429 #f) #f)
            (list '(400 closed) #t)
            (list '("503" #f) #t)
            (list '("503 Service Unavailable" #f) #t)
            (list '("400" closed) #f)
            (list '("bad" closed) #f)
            (list '(#f deadline) #t)
            (list '(#f pool_not_available) #t)
            (list '(#f nxdomain) #f)
            (list '(#f "http2 error: :connection_closed") #t)
            (list '(#f "connection closed") #f)
            (list '(#f (#f disconnected)) #t)
            (list '(#f ("502" #f)) #t)
            (list '(#f #f) #f)
            (list #f #f)))))

(deftest 'llm-gate-retry-delay-backs-off-three-tries
  "BASE then twice BASE, each with up to half its width of jitter; no third retry"
  (lambda ()
    (let ((d1 (llm-retry-delay 1 '(503 #f) 500))
          (d2 (llm-retry-delay 2 '(503 #f) 500)))
      (check-true! (and (>= d1 501) (<= d1 750)) "the first wait")
      (check-true! (and (>= d2 1001) (<= d2 1500)) "the second wait")
      (check-false! (llm-retry-delay 3 '(503 #f) 500) "the third failure stands")
      (check-false! (llm-retry-delay 1 '(400 #f) 500) "a refusal is not retried")
      (check-equal! (llm-retry-delay 1 '(503 #f) 0) 1 "a zero base still waits one millisecond"))))
