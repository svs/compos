;;; llm-costs-test.scm --- a usage report becomes one priced ledger row.
;;;
;;; Each test reads the report as the event log hands it to the workflow:
;;; (seq N topic "llm:usage" kind turn data (...) at SECS). The ledger is a
;;; file of its own for each test.

(domain! 'testing)
(effects! '(write))

(define t--costs-at 1794830400)

(define (t--costs-event seq backend connector model usage &optional cost)
  (list 'seq seq 'topic "llm:usage" 'kind 'turn 'at t--costs-at
        'data (list 'backend backend 'connector connector 'model model 'usage usage
                    'cost (or cost #f) 'slug "chat-test" 'end "done")))

(define t--costs-acp-usage
  '("cachedReadTokens" 5000 "cachedWriteTokens" 200 "inputTokens" 1000 "outputTokens" 100))

;; run THUNK with an empty ledger of its own, in the temp folder. The real
;; ledger comes back and the test file goes, also when THUNK fails.
(define (t--with-ledger name thunk)
  (let ((saved llm-costs-ledger)
        (path (string-append (or (getenv "TMPDIR") "/tmp/") "/llm-costs-test-" name ".jsonl")))
    (write-file! path "")
    (set! llm-costs-ledger path)
    (llm-costs-forget-index!)
    (unwind-protect
      thunk
      (lambda ()
        (set! llm-costs-ledger saved)
        (llm-costs-forget-index!)
        (delete-file! path)))))

(deftest 'a-subscription-turn-records-an-estimate-not-a-cost
  "a turn that a subscription pays for has no cost, and an estimate at the catalog price"
  (lambda ()
    (let* ((row (llm-costs-row (t--costs-event 1 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage)))
           (price (llm-costs-catalog-price "claude-sonnet-5" (llm-costs-tokens "acp" t--costs-acp-usage))))
      (check-equal! (plist-get row 'input) 1000 "the fresh input as the adapter sent it")
      (check-equal! (plist-get row 'cache_read) 5000 "the cached input")
      (check-false! (plist-get row 'cost) "a subscription turn is not spend")
      (check-true! (and price (> price 0)) "the catalog prices the model")
      (check-equal! (plist-get row 'estimate) price "the estimate is the catalog price"))))

(deftest 'a-turn-outside-a-subscription-is-billed
  "a connector with no subscription bills per token, and opencode bills its opencode/ models"
  (lambda ()
    (let ((row (llm-costs-row (t--costs-event 2 "acp" "my-gateway" "claude-sonnet-5" t--costs-acp-usage))))
      (check-true! (> (plist-get row 'cost) 0) "the turn costs the catalog price")
      (check-false! (plist-get row 'estimate) "a billed turn holds no estimate"))
    (check-true! (llm-costs-subscription? "opencode" "opencode-go/deepseek-v4.1-flash")
                 "a Go model is on the subscription")
    (check-false! (llm-costs-subscription? "opencode" "opencode/claude-sonnet-5")
                  "a pay-as-you-go model is billed")
    (check-false! (llm-costs-subscription? #f "claude-sonnet-5")
                  "a turn with no connector is billed")))

(deftest 'a-bare-model-id-is-priced-under-its-provider
  "deepseek reports a bare id, and the catalog names it deepseek:ID"
  (lambda ()
    (check-equal! (llm-costs-model "deepseek" "deepseek-v4-pro") "deepseek:deepseek-v4-pro"
                  "the provider goes in front")
    (check-equal! (llm-costs-model "deepseek" "deepseek:deepseek-v4-pro") "deepseek:deepseek-v4-pro"
                  "an id with a provider stays")
    (check-equal! (llm-costs-model "claude-code" "claude-sonnet-5") "claude-sonnet-5"
                  "another connector's id stays")))

(deftest 'the-backends-own-cost-wins
  "a cost the backend sends as a number is the row's cost; on a subscription it is the estimate"
  (lambda ()
    (let ((row (llm-costs-row (t--costs-event 3 "req-llm" "anthropic" "anthropic:claude-sonnet-5"
                                              '("input_tokens" 11 "output_tokens" 3) 0.0125))))
      (check-equal! (plist-get row 'cost) 0.0125 "the backend's own figure")
      (check-false! (plist-get row 'estimate) "no estimate")
      (check-equal! (plist-get row 'input) 11 "the direct lane's tokens"))
    (let ((row (llm-costs-row (t--costs-event 3 "req-llm" "claude-code" "claude-sonnet-5"
                                              '("input_tokens" 11 "output_tokens" 3) 0.0125))))
      (check-false! (plist-get row 'cost) "a subscription turn is not spend, whoever priced it")
      (check-equal! (plist-get row 'estimate) 0.0125 "the backend's figure is the estimate"))))

(deftest 'an-acp-session-total-costs-what-it-grew
  "an ACP adapter sends the session's running total; a turn costs the growth since the chat's last report"
  (lambda ()
    (t--with-ledger "session"
      (lambda ()
        (let ((turn (lambda (seq amount)
                      (t--costs-event seq "acp" "my-gateway" "claude-sonnet-5" t--costs-acp-usage
                                      (list "amount" amount "currency" "USD")))))
          (check-equal! (llm-costs-session-total '("amount" 0.5 "currency" "USD")) 0.5 "the amount of the total")
          (check-false! (llm-costs-session-total "0.5") "text is no total")
          (llm-costs-record! (list (turn 30 0.5) (turn 31 0.75)))
          (llm-costs-forget-index!)
          (llm-costs-record! (list (turn 32 1.0) (turn 33 0.25)))
          (let ((costs (map (lambda (r) (plist-get r 'cost)) (llm-costs-rows))))
            (check-equal! costs '(0.5 0.25 0.25 0.25)
                          "each turn its growth, read back across a reload; a total that fell is a new session")))
        (let ((row (llm-costs-row (t--costs-event 34 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage
                                                  '("amount" 2.0 "currency" "USD"))
                                  1.5)))
          (check-false! (plist-get row 'cost) "a subscription turn is not spend")
          (check-equal! (plist-get row 'estimate) 0.5 "the adapter's growth is the estimate"))))))

(deftest 'a-new-event-log-does-not-hide-new-turns
  "events.db made again starts its seq at 1; reports below the ledger's old seqs are still new"
  (lambda ()
    (t--with-ledger "reset"
      (lambda ()
        (let ((old (t--costs-event 500 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage))
              (fresh (plist-put (t--costs-event 1 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage)
                                'at (+ t--costs-at 3600))))
          (check-equal! (llm-costs-record! (list old)) 1 "the turn before the reset")
          (llm-costs-forget-index!)
          (check-equal! (llm-costs-record! (list fresh)) 1 "seq 1 of the new log is a new turn")
          (check-equal! (llm-costs-record! (list fresh old)) 0 "both are known now")
          (check-equal! (length (llm-costs-rows)) 2 "two rows"))))))

(deftest 'old-rows-count-on-the-local-day
  "a row core wrote with a UTC ts counts on the local day, as a new row does; the hit rate is a whole percent"
  (lambda ()
    (let ()
      (check-equal! (llm-costs--utc-ts->secs "2026-11-17T00:30:00Z") 1794875400 "the UTC instant")
      (check-equal! (llm-costs--day '(ts "2026-11-17T23:30:00Z"))
                    (format-time (llm-costs--utc-ts->secs "2026-11-17T23:30:00Z") "%Y-%m-%d")
                    "the local day of the instant")
      (check-equal! (llm-costs--day '(ts "nonsense")) "?" "a ts that does not read"))
    (check-equal! (llm-costs--hit-rate '(input 50 cache-read 50)) "50% cached" "no decimal point")))

(deftest 'a-codex-turn-sums-its-requests
  "Codex sends one usage per model request; the row sums them, cached input apart"
  (lambda ()
    (let* ((note (lambda (in cached out reason)
                   (list "threadId" "thread-1" "turnId" "turn-1"
                         "tokenUsage" (list "last" (list "cachedInputTokens" cached "inputTokens" in
                                                         "outputTokens" out "reasoningOutputTokens" reason
                                                         "totalTokens" (+ in out))))))
           (tokens (llm-costs-tokens "codex-app-server" (list (note 900 600 40 10) (note 1100 800 60 0)))))
      (check-equal! (plist-get tokens 'input) 600 "fresh input: input less the cached part")
      (check-equal! (plist-get tokens 'cache-read) 1400 "the cached input")
      (check-equal! (plist-get tokens 'output) 100 "the output of both requests")
      (check-equal! (plist-get tokens 'reasoning) 10 "the reasoning tokens"))))

(deftest 'a-turn-with-no-usage-still-gets-a-row
  "a local model reports no tokens; its turn is still a row, with no cost"
  (lambda ()
    (let ((row (llm-costs-row (t--costs-event 4 "chrome-gemini-nano" "gemini-nano" "gemini-nano" #f))))
      (check-equal! (plist-get row 'input) 0 "no tokens")
      (check-equal! (plist-get row 'backend) "chrome-gemini-nano" "the backend is named")
      (check-false! (plist-get row 'cost) "no price, so no cost"))))

(deftest 'a-batch-that-runs-again-writes-no-row-twice
  "the workflow writes the ledger at least once; a report already in it is skipped"
  (lambda ()
    (t--with-ledger "twice"
      (lambda ()
        (let ((events (list (t--costs-event 10 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage)
                            (t--costs-event 11 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage))))
          (check-equal! (llm-costs-record! events) 2 "two new rows")
          (llm-costs-forget-index!)
          (check-equal! (llm-costs-record! events) 0 "the same batch adds nothing, read back from the file")
          (check-equal! (length (llm-costs-rows)) 2 "the ledger holds two rows"))))))

(deftest 'the-report-sums-a-day-and-keeps-the-estimate-apart
  "M-x llm-costs sums by day and model, reads the rows core wrote before, and never adds an estimate to the spend"
  (lambda ()
    (t--with-ledger "report"
      (lambda ()
        (let ((day (format-time t--costs-at "%Y-%m-%d")))
          ;; a row as core wrote it before this package kept the ledger
          (write-file! llm-costs-ledger
            (string-append "{\"cache_read\":0,\"cache_write\":0,\"cost\":0.01,\"input\":100,"
                           "\"model\":\"claude-sonnet-5\",\"output\":10,\"ts\":\"" day "T10:00:00Z\"}\n"))
          (llm-costs-record! (list (t--costs-event 20 "acp" "claude-code" "claude-sonnet-5" t--costs-acp-usage)))
          (let* ((rows (llm-costs-report))
                 (r (car rows))
                 (s (caddr r)))
            (check-equal! (length rows) 1 "one day, one model")
            (check-equal! (list (car r) (cadr r)) (list day "claude-sonnet-5") "the day and the model")
            (check-equal! (plist-get s 'requests) 2 "the old row and the new one")
            (check-equal! (plist-get s 'cost) 0.01 "the spend is the billed row only")
            (check-true! (> (plist-get s 'estimate) 0) "the subscription turn is an estimate")
            (check-equal! (plist-get s 'input) 1100 "the input of both rows")))))))
