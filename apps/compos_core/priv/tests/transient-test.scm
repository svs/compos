;;; transient-test.scm --- transient menu policy.

(domain! 'testing)
(effects! '(write))

(deftest 'llm-config-history-keeps-recent-distinct-combinations
  "The LLM selector history is newest-first, distinct, and bounded"
  (lambda ()
    (let ((saved *llm-config-history*))
      (set! *llm-config-history* '())
      (llm-config-remember! '("api" "default" "default"))
      (llm-config-remember! '("codex-app-server" "gpt-5.6-terra" "high"))
      (llm-config-remember! '("api" "default" "default"))
      (check-equal!
        *llm-config-history*
        '(("api" "default" "default")
          ("codex-app-server" "gpt-5.6-terra" "high"))
        "a repeated combination moves to the front without a duplicate")
      (set! *llm-config-history*
        '(("c1" "m" "e") ("c2" "m" "e") ("c3" "m" "e")
          ("c4" "m" "e") ("c5" "m" "e") ("c6" "m" "e")
          ("c7" "m" "e") ("c8" "m" "e") ("c9" "m" "e")
          ("c10" "m" "e")))
      (llm-config-remember! '("c11" "m" "e"))
      (check-equal! (length *llm-config-history*) llm-config-history-limit
                    "a new combination drops the oldest entry")
      (check-false! (member '("c10" "m" "e") *llm-config-history*)
                    "the history removes its oldest entry")
      (set! *llm-config-history* saved))))

(deftest 'llm-config-history-offers-ten-numbered-choices
  "The LLM selector offers ten recent combinations with numeric keys"
  (lambda ()
    (let ((saved *llm-config-history*)
          (buf (test-buffer! "zz-llm-config-history" "")))
      (buffer-set-local! buf 'llm-connector "codex-app-server")
      (buffer-set-local! buf 'llm-model "gpt-5.6-luna")
      (buffer-set-local! buf 'llm-effort "medium")
      (set! *llm-config-history*
        '(("codex-app-server" "gpt-5.6-luna" "medium")
          ("c2" "m" "e") ("c3" "m" "e") ("c4" "m" "e")
          ("c5" "m" "e") ("c6" "m" "e") ("c7" "m" "e")
          ("c8" "m" "e") ("c9" "m" "e") ("c10" "m" "e")))
      (check-equal!
        (map (lambda (item) (plist-get item 'key))
             (llm-config--history-items buf))
        '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0")
        "the tenth combination uses zero")
      (set! *llm-config-history* saved)
      (buffer-kill! buf))))
