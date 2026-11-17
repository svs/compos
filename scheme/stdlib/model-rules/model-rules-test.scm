;;; model-rules-test.scm --- the catalog's pure rules.

(domain! 'testing)
(effects! '(write))

(deftest 'reasoning-controls-come-from-the-typed-shape
  "Effort, thinking and token budget stay separate controls"
  (lambda ()
    (check-equal!
      (model-reasoning-normalize
        "{\"capabilities\":{\"reasoning\":{\"effort\":{\"supported\":true,\"values\":[\"low\",\"high\"],\"default\":\"high\"}}},\"extra\":{}}")
      '(enabled #t effort (values ("low" "high") default "high")
                thinking #f token_budget #f source "llmdb")
      "an effort list with its default")
    (check-equal!
      (model-reasoning-normalize
        "{\"capabilities\":{\"reasoning\":{\"token_budget\":2048}},\"extra\":{}}")
      '(enabled #t effort #f thinking #f
                token_budget (min 0 max 2048 default 2048) source "llmdb")
      "a bare budget is its own min, max and default")
    (check-equal!
      (model-reasoning-normalize
        "{\"capabilities\":{\"reasoning\":{\"token_budget\":{\"min\":1024,\"max\":4096,\"default\":2048}}},\"extra\":{}}")
      '(enabled #t effort #f thinking #f
                token_budget (min 1024 max 4096 default 2048) source "llmdb")
      "a stated budget keeps its min and max")))

(deftest 'reasoning-controls-fall-back-to-the-raw-options
  "The older models.dev reasoning_options list still answers"
  (lambda ()
    (check-equal!
      (model-reasoning-normalize
        "{\"capabilities\":{},\"extra\":{\"reasoning_options\":[{\"type\":\"effort\",\"values\":[\"none\",\"low\"],\"default\":\"low\"}]}}")
      '(enabled #t effort (values ("none" "low") default "low")
                thinking #f token_budget #f source "llmdb")
      "a raw effort option")
    (check-equal!
      (model-reasoning-normalize
        "{\"capabilities\":{},\"extra\":{\"reasoning_options\":[{\"type\":\"toggle\"}]}}")
      '(enabled #t effort #f thinking (types ("enabled") default #f disable_supported #t)
                token_budget #f source "llmdb")
      "a raw toggle is a thinking control")
    (check-false! (model-reasoning-normalize "{}")
                  "a model with no reasoning controls gets none")))

(deftest 'a-live-backend-row-uses-the-efforts-it-offered
  "Codex's own list is authoritative; nothing is invented"
  (lambda ()
    (check-equal!
      (model-codex-entry
        "{\"model\":\"gpt-5.6-sol\",\"displayName\":\"GPT-5.6 Sol\",\"supportedReasoningEfforts\":[{\"reasoningEffort\":\"low\"},{\"reasoningEffort\":\"ultra\"}],\"defaultReasoningEffort\":\"low\"}")
      '("gpt-5.6-sol" "GPT-5.6 Sol" ("low" "ultra") "low")
      "id, name, the efforts, the default")
    (check-equal!
      (model-codex-entry "{\"id\":\"m\",\"supportedReasoningEfforts\":[]}")
      '("m" "" () "")
      "no efforts, no invented default")))

(deftest 'a-snapshot-age-is-whole-days
  "The staleness rule reads the UTC instant the snapshot was captured"
  (lambda ()
    (check-equal! (model-stale-days "2000-01-01T00:00:00Z" (+ 946684800 (* 3 86400))) 3
                  "three whole days later")
    (check-equal! (model-stale-days "2000-01-01T05:30:00+05:30" 946684800) 0
                  "an offset to UTC reads the same instant")
    (check-false! (model-stale-days "not a date" 946684800)
                  "an unreadable instant names no age")))
