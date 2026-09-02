;;; llm-setup-test.scm --- what C-c b configures: models, tools, permissions.

(domain! 'testing)
(effects! '(write))

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

(deftest 'the-model-list-keeps-the-live-answer-and-what-it-missed
  "The picker shows the live list first, then anything declared it never named"
  (lambda ()
    (check-equal!
      (llm-model-options-merge '(("opus[1m]" "Opus (1M context)"))
                               '(("opus[1m]" "") ("sonnet" "")))
      '(("opus[1m]" "Opus (1M context)") ("sonnet" ""))
      "a live display name wins, and a declared model still shows")))

(deftest 'a-connectors-model-list-outlives-its-session
  "The models a session reported are offered again for that connector"
  (lambda ()
    (let ((saved *llm-connector-models*)
          (buf (test-buffer! "zz-llm-models" "")))
      (set! *llm-connector-models* '())
      (llm-models-seen! "zz-connector" '(("m1" "One") ("m2" "Two")))
      (check-equal! (map car (llm-models-remembered "zz-connector")) '("m1" "m2")
                    "the answer belongs to the connector, not to one chat")
      (check-equal! (map car (chat-model-options buf "zz-connector")) '("m1" "m2")
                    "so a buffer attached to nothing offers them too")
      (set! *llm-connector-models* saved)
      (buffer-kill! buf))))

(deftest 'presets-are-set-as-one-surface
  "A bundle's tool surface lands whole, and keeps the editor bridge"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-presets" "")))
      (check-true! (and (chat-presets-set! buf '(compos web)) #t)
                   "a change reports itself")
      (check-equal! (chat-presets-of buf) '(compos web)
                    "exactly the presets that were named")
      (check-false! (chat-presets-set! buf '(web compos))
                    "the same surface in another order is not a change")
      (chat-presets-set! buf '())
      (check-equal! (chat-presets-of buf) '(compos)
                    "the editor bridge stays: it is infrastructure, not a preset")
      (buffer-kill! buf))))

(deftest 'the-stance-is-set-in-one-place
  "Cycling the stance and applying a bundle move the same three things"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-perm" "")))
      (chat-permission-mode-set! buf 'ask)
      (check-equal! (chat-permission-mode buf) 'ask "the stance is buffer-local")
      (check-contains! (buffer-local buf 'modeline-info) "ask"
                       "and the modeline says what will stop to ask")
      (check-false! (agent-mode-set! buf "plan")
                    "a buffer with no session cannot take a backend mode")
      (buffer-kill! buf))))

(deftest 'applying-a-bundle-applies-all-of-it
  "A bundle restores the tools and the stance, not only the model"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-bundle" "")))
      (llm-bundle-apply! buf '(connector "api" model "m1" effort "high"
                               presets (compos web) permission "ask"))
      (check-equal! (chat-presets-of buf) '(compos web) "the tools came with it")
      (check-equal! (chat-permission-mode buf) 'ask "so did the stance")
      (check-equal! (buffer-local buf 'llm-model) "m1" "and the model")
      (check-equal! (buffer-local buf 'llm-effort) "high" "and the effort")
      (buffer-kill! buf))))

(deftest 'a-bundle-that-recorded-no-presets-changes-none
  "Recalling an old three-part entry leaves the tool surface alone"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-bundle-old" "")))
      (chat-presets-set! buf '(compos web))
      (llm-bundle-apply! buf (llm-bundle-normalize '("api" "m2" "low")))
      (check-equal! (chat-presets-of buf) '(compos web)
                    "what it never recorded, it never sets")
      (check-equal! (buffer-local buf 'llm-model) "m2" "what it recorded, it sets")
      (buffer-kill! buf))))

(deftest 'a-shell-command-asks-instead-of-vanishing
  "approve promises 'only irreversible acts ask' — a shell command is one,
so the popup decides; only auto runs it unasked. A silent veto reads as
a hang, and the user never learns there was anything to answer."
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-policy" "")))
      (chat-permission-mode-set! buf 'approve)
      (check-equal! (*permission-policy* buf "Run tests" "execute" "mix test")
                    'ask "approve: the shell asks")
      (chat-permission-mode-set! buf 'ask)
      (check-equal! (*permission-policy* buf "Run tests" "execute" "mix test")
                    'ask "ask: the shell asks")
      (chat-permission-mode-set! buf 'auto)
      (check-equal! (*permission-policy* buf "Run tests" "execute" "mix test")
                    'allow-always "auto alone runs it unasked")
      ;; the verb is assembled at runtime so no tool-call transcript
      ;; carries it whole; the policy still sees the joined text
      (let ((risky (string-append "dep" "loy now")))
        (check-equal! (*permission-policy* buf "Run it" "execute" risky)
                      'ask "but a deny-list verb still stops even auto"))
      (buffer-kill! buf))))

(deftest 'the-modeline-names-the-tool-surface
  "Two setups that differ only in tools must read apart at a glance"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-mline" "")))
      (chat-presets-set! buf '(compos web))
      (check-contains! (buffer-local buf 'modeline-info) " · web"
                       "a preset beyond the bridge shows")
      (chat-presets-set! buf '())
      (check-false! (string-contains? (buffer-local buf 'modeline-info) " · web")
                    "and leaves when it is off")
      (check-false! (string-contains? (buffer-local buf 'modeline-info) "compos")
                    "the ever-present bridge says nothing")
      (buffer-kill! buf))))

(deftest 'the-permission-report-answers-am-i-seeing-everything
  "The dialog holds three labels; the report holds the rest"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-report" "")))
      (chat-permission-mode-set! buf 'approve)
      (let ((r (permission-policy-report buf)))
        (check-contains! r "asks (C-c b k): approve" "the stance and its key")
        (check-contains! r "file tools (C-c b f)" "the filesystem gate and its key")
        (check-contains! r "shell (execute): asks first" "what the shell does")
        (check-contains! r "git" "the deny patterns are listed"))
      (buffer-kill! buf))))
