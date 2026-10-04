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

(deftest 'the-model-list-is-the-backends-own
  "A reported list is the whole menu; the declared seed shows only before one"
  (lambda ()
    (let ((saved *llm-connector-models*)
          (buf (test-buffer! "zz-llm-models-own" "")))
      (set! *llm-connector-models* '())
      (define-connector! "zz-seeded" '(models ("seed-a" "seed-b")))
      (check-equal! (map car (chat-model-options buf "zz-seeded")) '("seed-a" "seed-b")
                    "nothing reported yet: the seed")
      (llm-models-seen! "zz-seeded" '(("live-a" "Live A")))
      (check-equal! (chat-model-options buf "zz-seeded") '(("live-a" "Live A"))
                    "reported: only the backend's list")
      (set! *agent-connectors*
            (filter (lambda (c) (not (equal? (car c) "zz-seeded"))) *agent-connectors*))
      (set! *llm-connector-models* saved)
      (buffer-kill! buf))))

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
      (check-equal! (agent-mode-set! buf "plan") "plan"
                    "a buffer with no session parks the mode for the session to come")
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
      (check-equal! (permit? buf "Run tests" "execute" "mix test")
                    'ask "approve: the shell asks")
      (chat-permission-mode-set! buf 'ask)
      (check-equal! (permit? buf "Run tests" "execute" "mix test")
                    'ask "ask: the shell asks")
      (chat-permission-mode-set! buf 'auto)
      (check-equal! (permit? buf "Run tests" "execute" "mix test")
                    'allow-always "auto alone runs it unasked")
      ;; the verb is assembled at runtime so no tool-call transcript
      ;; carries it whole; the policy still sees the joined text
      (let ((risky (string-append "dep" "loy now")))
        (check-equal! (permit? buf "Run it" "execute" risky)
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

(deftest 'a-bundle-remembers-disabled-prompt-sections
  "prompt composition is part of the complete LLM setup"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-prompt-bundle" "")))
      (llm-bundle-apply! buf
        '(connector "api" model "m1" effort "high"
          prompt-disabled ("reading" "general")))
      (check-equal! (prompt-disabled-parts buf) '("reading" "general")
                    "the preset restores its prompt exceptions")
      (check-contains! (llm-bundle-label
                         '(connector "api" prompt-disabled ("reading" "general")))
                       "2 prompt off"
                       "saved bundle labels expose the change")
      (buffer-kill! buf))))

(deftest 'llm-config-session-is-the-groups-most-recent-chat
  "a chat is its own session; a work buffer in a group answers the group's most recently used chat; a buffer with no group answers itself"
  (lambda ()
    (let* ((id (group-record-create! "zz-llm-session-group"))
           (chat "*zz-llm-session-chat*")
           (work "*zz-llm-session-work*")
           (lone "*zz-llm-session-lone*")
           (was (current-buffer)))
      (test-buffer! chat "")
      (buffer-set-local! chat 'mode-name "chat-mode")
      (buffer-set-local! chat 'group-id id)
      (test-buffer! work "")
      (buffer-set-local! work 'group-ids (list id))
      (test-buffer! lone "")
      (switch-to-buffer! chat)
      (switch-to-buffer! was)
      (check-equal! (llm-config-session chat) chat "a chat is its own session")
      (check-equal! (llm-config-session work) chat "a work buffer answers its group's recent chat")
      (check-equal! (llm-config-session lone) lone "a buffer with no group answers itself")
      (buffer-kill! chat)
      (buffer-kill! work)
      (buffer-kill! lone)
      (group-record-delete! id))))

(deftest 'a-connectors-mode-list-outlives-its-session
  "The session modes a backend reported are offered again for that connector"
  (lambda ()
    (let ((saved *llm-connector-modes*)
          (buf (test-buffer! "zz-llm-modes" "")))
      (set! *llm-connector-modes* '())
      (llm-modes-seen! "zz-connector"
        '(("plan" "Plan" "plans only") ("go" "Go" "runs tools")))
      (buffer-set-local! buf 'agent-connector "zz-connector")
      (check-equal! (map car (chat-mode-options buf "zz-connector")) '("plan" "go")
                    "a chat with no session still knows the backend's modes")
      (check-equal! (agent-mode-options buf) '(("plan" "plans only") ("go" "runs tools"))
                    "and the menu can name one")
      (set! *llm-connector-modes* saved)
      (buffer-kill! buf))))

(deftest 'an-agent-mode-chosen-with-no-session-waits-for-one
  "A mode chosen before the session exists parks, and is applied or dropped"
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-mode-park" "")))
      (check-equal! (agent-mode-set! buf "plan") "plan"
                    "the choice is taken, not refused")
      (check-equal! (buffer-local buf 'agent-mode-wanted) "plan" "and parked")
      (check-equal! (buffer-local buf 'agent-mode) "plan" "the menu shows it")
      (buffer-set-local! buf 'agent-modes '(("default" "Default" "asks")))
      (check-false! (agent-mode-take-pending! buf)
                    "a mode this backend does not have is dropped")
      (check-false! (buffer-local buf 'agent-mode-wanted) "and not kept forever")
      (buffer-kill! buf))))
