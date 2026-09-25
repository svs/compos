;;; setup-test.scm --- setup.scm: the first-run setup policy.

(domain! 'testing)
(effects! '(read))

(tests-need-a-disposable-editor!
  "opens a guide window and changes first-run setup state")

(deftest 'setup-report-is-secret-free
  "the report names setup surfaces but never asks for values"
  (lambda ()
    (let ((report (setup-report)))
      (check-contains! report "Gemini Nano" "the bootstrap provider")
      (check-contains! report "Doppler" "the secret policy")
      (check-contains! report "M-x" "the teaching path")
      (check-contains! report "](#inference)" "the inference anchor")
      (check-contains! report "https://openrouter.ai/settings/keys" "the key link")
      (check-false! (string-contains? report "sk-") "no API key prefix"))))

(deftest 'setup-knows-the-gemini-nano-connector
  "the existing connector is the provider bootstrap seam"
  (lambda ()
    (let ((gemini (assoc "Gemini Nano" (setup-connectors))))
      (check-true! gemini "the connector row")
      (check-true! (cadr gemini) "the connector is loaded")
      (check-contains! (caddr gemini) "no API key" "the local credential rule"))))

(deftest 'setup-secret-backends-hide-values
  "backend inspection returns names and commands only"
  (lambda ()
    (for-each
      (lambda (entry)
        (check-true! (string? (car entry)) "backend name")
        (check-true! (string? (cadr entry)) "backend program")
        (check-false! (and (not (equal? (caddr entry) #t))
                           (not (equal? (caddr entry) #f)))
                      "backend status is boolean"))
      (setup-secret-backends))))

(deftest 'setup-greets-with-the-detected-secret-backends
  "the wizard starts as a conversation and names only available tools"
  (lambda ()
    (let ((greeting
            (setup-secret-greeting-for
              '(("Doppler" "doppler" #t "doppler login")
                ("1Password" "op" #t "op signin")
                ("GPG" "gpg" #f "gpg --list-secret-keys")))))
      (check-equal! greeting
        "Hello. I see Doppler and 1Password. Would you like to configure your secrets?"
        "the opening question"))))

(deftest 'setup-greeting-handles-a-machine-with-no-secret-tool
  "the first question remains useful before a backend is installed"
  (lambda ()
    (check-equal!
      (setup-secret-greeting-for
        '(("Doppler" "doppler" #f "doppler login")))
      "Hello. I see no supported secret tools. Would you like to configure your secrets?"
      "the empty detection result")))

(deftest 'silent-setup-does-not-change-the-window-setup
  "a silent bot can explain a step without displaying its document"
  (lambda ()
    (let ((before (window-list))
          (old setup-bot-silent-mode))
      (set! setup-bot-silent-mode #t)
      (setup--show-document! "silent test" "# Silent\n")
      (check-equal! (window-list) before "the window list")
      (set! setup-bot-silent-mode old))))

(deftest 'the-setup-surface-registers-links-and-other-window-file-opening
  "bots can discover the window-safe command and setup documents own their links"
  (lambda ()
    (check-true! (member "find-file-other-window" (command-names))
                 "the M-x command")
    (check-true! (pair? (hook-functions '(preview-link "setup"))) "the setup link handler")))

(deftest 'setup-documents-open-at-the-beginning
  "opening M-x must not reveal a hidden end-of-document point"
  (lambda ()
    (setup--document-set! *setup-buffer* "# First\n\nLast\n")
    (check-equal! (buffer-point *setup-buffer*) 0 "the document point")))

(deftest 'setup-ai-link-route-opens-a-guide-at-its-start
  "the setup link route opens the AI guide in a readable help buffer"
  (lambda ()
    (let ((old setup-bot-silent-mode))
      (set! setup-bot-silent-mode #f)
      (buffer-set-local! *setup-buffer* 'help-title "not the AI guide")
      (setup--follow-link "ai")
      (check-equal! (buffer-local *setup-buffer* 'help-title) "Start with AI"
                    "the guide is open")
      (check-equal! (buffer-point *setup-buffer*) 0 "the guide starts at its title")
      (check-true! (window-showing *setup-buffer*) "the guide is visible")
      (set! setup-bot-silent-mode old)
      (delete-other-windows!))))

(deftest 'welcome-marker-makes-first-frame-policy-idempotent
  "every profile sees Welcome once without legacy-state detection"
  (lambda ()
    (when (file-exists? (setup-welcome-marker-path))
      (delete-file-path! (setup-welcome-marker-path) #t))
    (check-true! (setup-welcome-needed?) "an unmarked profile needs Welcome")
    (setup-mark-welcome-seen!)
    (check-false! (setup-welcome-needed?) "the marker suppresses later frames")
    (delete-file-path! (setup-welcome-marker-path) #t)))

(deftest 'welcome-is-marked-only-after-it-opens
  "a display failure must not suppress Welcome on the next launch"
  (lambda ()
    (let ((original (command-function "setup-welcome")))
      (when (file-exists? (setup-welcome-marker-path))
        (delete-file-path! (setup-welcome-marker-path) #t))
      (define-command "setup-welcome" "test display failure"
        (lambda () (error "welcome display failed")))
      (check-equal! (car (eval-string-safe "(setup-show-welcome-once!)")) 'error
                    "the display failure is reported")
      (check-false! (file-exists? (setup-welcome-marker-path))
                    "the next launch may try again")
      (define-command "setup-welcome" "Open the welcome page" original))))

(deftest 'openrouter-enablement-selects-the-api-lane
  "a stored key turns on hosted inference without exposing the value"
  (lambda ()
    (let ((old-cache *key-cache*)
          (old-keys *llm-keys*)
          (old-connector *default-connector*)
          (old-model (llm-model)))
      (set! *key-cache* (cons '("OPENROUTER_API_KEY" "zz-test-key") *key-cache*))
      (check-true! (setup-openrouter-enable!) "the provider enables")
      (check-equal! *default-connector* "api" "the direct connector")
      (check-equal! (llm-model) setup-openrouter-model "the routed model")
      (set! *key-cache* old-cache)
      (set! *llm-keys* old-keys)
      (set! *default-connector* old-connector)
      (set-llm-model! old-model))))

;; The bug this guards: setup.scm registered the stored key by calling
;; setup-openrouter-enable! at load time. Every boot and every reload of
;; the file then set *default-connector* to "api". A chat spawned after
;; that rode the metered lane, and no ACP thread could start.
(deftest 'a-stored-key-registers-without-choosing-the-connector
  "registration is mechanism; the connector stays the user's choice"
  (lambda ()
    (let ((old-cache *key-cache*)
          (old-keys *llm-keys*)
          (old-connector *default-connector*)
          (old-model (llm-model)))
      (set! *key-cache* (cons '("OPENROUTER_API_KEY" "zz-test-key") *key-cache*))
      (set! *default-connector* "claude-code")
      (check-true! (setup-openrouter-register!) "the key registers")
      (check-equal! *default-connector* "claude-code" "the connector is untouched")
      (check-equal! (llm-model) old-model "the model is untouched")
      (set! *key-cache* old-cache)
      (set! *llm-keys* old-keys)
      (set! *default-connector* old-connector)
      (set-llm-model! old-model))))

;; Boot must leave the ACP default in place. setup.scm loads before this
;; test runs, so this reads the value its load-time form produced.
(deftest 'boot-does-not-choose-the-inference-connector
  "no bundled package selects a connector while it loads"
  (lambda ()
    (check-equal! *default-connector* "claude-code"
                  "the boot default the user did not change")))

(deftest 'agent-connectors-resolve-portable-default-commands
  "built-in ACP commands resolve through PATH instead of an author's checkout"
  (lambda ()
    (check-equal!
      (plist-get (agent-resolve-config '(connector "claude-code")) 'cmd)
      "claude-agent-acp"
      "the maintained Claude ACP executable")
    (check-equal!
      (plist-get (agent-resolve-config '(connector "deepseek")) 'cmd)
      "dsh --profile acp"
      "the DeepSeek Harness ACP profile")))

(deftest 'agent-connector-command-has-a-per-user-override
  "a nonstandard adapter install can replace one connector command"
  (lambda ()
    (let ((old agent-connector-command-overrides))
      (set! agent-connector-command-overrides
        '(("deepseek" "zz-dsh --profile acp")))
      (check-equal!
        (plist-get (agent-resolve-config '(connector "deepseek")) 'cmd)
        "zz-dsh --profile acp"
        "the configured command")
      (set! agent-connector-command-overrides old))))

(deftest 'setup-never-restores-an-unavailable-default
  "missing connectors stay visible in the scan but cannot become the default"
  (lambda ()
    (let ((old-connectors *agent-connectors*)
          (old-saved setup-default-connector)
          (old-default *default-connector*))
      (set! *agent-connectors*
        '(("zz-missing" (cmd "zz-compos-missing-adapter"))
          ("gemini-nano" (backend "chrome-gemini-nano"))))
      (set! setup-default-connector "zz-missing")
      (set! *default-connector* "zz-missing")
      (let ((missing (assoc "zz-missing" (setup-inference-scan))))
        (check-true! missing "the missing connector is reported")
        (check-false! (list-ref missing 2) "the missing connector is unavailable"))
      (setup-apply-default-connector!)
      (check-equal! *default-connector* "gemini-nano"
                    "the first runnable connector is the fallback")
      (set! *agent-connectors* old-connectors)
      (set! setup-default-connector old-saved)
      (set! *default-connector* old-default))))
