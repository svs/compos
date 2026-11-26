;;; llm-catalog-test.scm --- the model catalog: its policy and its parsing.
;;;
;;; A refresh is a network fetch and belongs to no test. What is testable is
;;; the policy (when a catalog is stale, what a person reads about it) and
;;; how a provider's own list reads.

(domain! 'testing)
(effects! '(read))

(deftest 'llm-catalog-counts-an-unrecorded-catalog-as-stale
  "the catalog packaged with the build records no capture time, so it is stale"
  (lambda ()
    (check-true! (llm-catalog-stale-age? #f)
                 "a catalog with no recorded age is stale")))

(deftest 'llm-catalog-stale-follows-the-max-age
  "the limit is llm-catalog-max-age-days, and the limit itself is still fresh"
  (lambda ()
    (let ((max llm-catalog-max-age-days))
      (check-false! (llm-catalog-stale-age? 0)
                    "a catalog captured today is fresh")
      (check-false! (llm-catalog-stale-age? max)
                    "a catalog exactly at the limit is still fresh")
      (check-true! (llm-catalog-stale-age? (+ max 1))
                   "a catalog one day past the limit is stale"))))

(define (llm-catalog-test--has-key? plist key)
  (cond ((null? plist) #f)
        ((equal? (car plist) key) #t)
        ((null? (cdr plist)) #f)
        (else (llm-catalog-test--has-key? (cddr plist) key))))

(deftest 'llm-catalog-info-names-every-field-the-policy-reads
  "the policy reads these keys, so the primitive must carry every one"
  (lambda ()
    (let ((info (llm-catalog-info)))
      (for-each
        (lambda (key)
          ;; plist-get answers #f for a key that is absent AND for one whose
          ;; value is #f, so the presence test walks the keys themselves
          (check-true! (llm-catalog-test--has-key? info key)
                       (string-append "llm-catalog-info carries " (symbol->string key))))
        '(snapshot-id captured-at models providers stale-days path)))))

(deftest 'llm-catalog-describe-says-what-the-catalog-holds
  "the line a person reads names the counts and the capture time"
  (lambda ()
    (let ((text (llm-catalog--describe
                  '(models 7430 providers 179 captured-at "2026-09-22T04:30:15Z"))))
      (check-contains! text "7430" "the description counts the models")
      (check-contains! text "179" "the description counts the providers")
      (check-contains! text "2026-09-22T04:30:15Z"
                       "the description says when the catalog was captured"))))

(deftest 'model-catalog-keeps-one-id-per-model
  "A provider's own catalog reads as (ID NAME), without its billing variants"
  (lambda ()
    (check-equal!
      (llm-catalog-parse
        "{\"data\":[{\"id\":\"anthropic/claude-fable-5.1\",\"name\":\"Fable 5.1\"},{\"id\":\"anthropic/claude-fable-5.1:batch\"},{\"id\":\"~anthropic/claude-fable-latest\"},{\"id\":\"qwen/qwen3\"}]}")
      '(("anthropic/claude-fable-5.1" "Fable 5.1") ("qwen/qwen3" ""))
      "a billing variant and an alias marker are not models you would choose")
    (check-equal! (llm-catalog-parse "not json") '()
                  "junk names no models")
    (check-equal! (llm-catalog-parse "") '()
                  "and neither does silence")))

(deftest 'model-catalog-answers-in-provider-model-form
  "The catalog contributes ids the direct lane can route"
  (lambda ()
    (let ((saved *llm-catalog*))
      (set! *llm-catalog* '(("openrouter" (("vendor/one" "One") ("vendor/two" "")))))
      (check-equal! (llm-catalog-models)
                    '("openrouter:vendor/one" "openrouter:vendor/two")
                    "provider first, exactly as set-llm-model! reads it")
      (set! *llm-catalog* saved))))

(deftest 'model-ids-are-unique-without-a-quadratic-scan
  "Two catalogs merge to one list, sorted, with no repeats"
  (lambda ()
    (check-equal!
      (llm-models-unique '("b" "a" "b" "c" "a"))
      '("a" "b" "c")
      "one of each")))
