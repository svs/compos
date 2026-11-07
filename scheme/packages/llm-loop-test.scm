;;; llm-loop-test.scm --- the model wire's retry and read-only rules.

(domain! 'testing)
(effects! '(write))

(deftest 'a-providers-not-now-is-retried
  "500 and 529 say ask again; a bad request does not"
  (lambda ()
    (check-true! (llm-retryable? 500 #f) "500")
    (check-true! (llm-retryable? 529 #f) "529")
    (check-true! (llm-retryable? 503 #f) "503")
    (check-false! (llm-retryable? 400 #f) "a bad request is not worth repeating")
    (check-false! (llm-retryable? 401 #f) "nor an auth failure")))

(deftest 'a-wedged-pool-is-retried-by-its-reason
  "A transport failure carries its reason as text, not a status"
  (lambda ()
    (check-true! (llm-retryable? #f "http2 error: :connection_closed")
                 "the text names a closed connection")
    (check-true! (llm-retryable? #f ":pool_not_available")
                 "the pool is out of the registry")
    (check-true! (llm-retryable? #f ":read_only") "the pool is read only while it starts")
    (check-false! (llm-retryable? #f "some other failure")
                  "a reason no transport names is not retried")
    (check-false! (llm-retryable? #f #f) "no reason, no retry")))

(deftest 'the-wait-doubles-and-jitters
  "Each attempt waits twice the last, plus up to half its width"
  (lambda ()
    (let ((first (llm-retry-delay 1 500))
          (second (llm-retry-delay 2 500))
          (third (llm-retry-delay 3 500)))
      (check-true! (and (>= first 500) (< first 751)) "500ms plus jitter")
      (check-true! (and (>= second 1000) (< second 1501)) "then 1s")
      (check-true! (and (>= third 2000) (< third 3001)) "then 2s"))))

(deftest 'only-pure-or-read-tools-run-at-once
  "The round's concurrency follows the declared first effect"
  (lambda ()
    (check-true! (llm-effect-read-only? '(pure)) "pure")
    (check-true! (llm-effect-read-only? '(read external)) "read with a modifier")
    (check-false! (llm-effect-read-only? '(write)) "a write does not")
    (check-false! (llm-effect-read-only? '(unknown)) "nor does unknown")
    (check-false! (llm-effect-read-only? '()) "a tool that declares nothing does not")
    (check-equal! (llm-read-only-tools
                    (list (list "a" "d" '() '(read))
                          (list "b" "d" '() '(write))
                          (list "c" "d" '())))
                  '("a")
                  "the names of the tools that may run together")))
