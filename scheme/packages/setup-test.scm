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
      (check-contains! report "**api**" "every declared connector has a row")
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

(deftest 'a-provider-secret-answers-the-direct-lane
  "llm-key answers from the secret setting that names the provider, and picks no connector"
  (lambda ()
    (let ((old-cache *key-cache*)
          (old-keys *llm-keys*)
          (old-connector *default-connector*))
      (set! *llm-keys* '())
      (set! *key-cache* (cons '("OPENROUTER_API_KEY" "zz-test-key") *key-cache*))
      (set! *default-connector* "claude-code")
      (check-equal! (secret-for-provider "openrouter") 'openrouter-api-key "the declared secret")
      (check-equal! (llm-key "openrouter") "zz-test-key" "the key, through the setting")
      (check-true! (setup--any-llm-key?) "the direct lane has a key")
      (check-equal! *default-connector* "claude-code" "the connector is untouched")
      (set! *key-cache* old-cache)
      (set! *llm-keys* old-keys)
      (set! *default-connector* old-connector))))

;; The bug this guards: setup.scm registered the stored key by calling
;; setup-openrouter-enable! at load time. Every boot and every reload of
;; the file then set *default-connector* to "api". A chat spawned after
;; that rode the metered lane, and no ACP thread could start.
(deftest 'a-connector-asks-for-its-unset-secret
  "a secret setting in a connector's env is a requirement until it has a value"
  (lambda ()
    (let ((old-connectors *agent-connectors*)
          (old-vars *custom-vars*))
      (defcustom 'zz-setup-test-key #f "A test key." 'type 'secret 'env "ZZ_SETUP_TEST_KEY")
      (set! *agent-connectors*
        '(("zz-keyed" (cmd "sh" env (("ZZ_SETUP_TEST_KEY" zz-setup-test-key))))))
      (let ((need (find (lambda (r) (equal? (plist-get r 'kind) 'secret))
                        (setup-connector-requirements "zz-keyed"))))
        (check-equal! (plist-get need 'secret) 'zz-setup-test-key "the declared secret")
        (check-false! (plist-get need 'met) "unset, it is a question")
        (check-contains! (list-ref (assoc "zz-keyed" (setup-inference-scan)) 3)
                         "ZZ_SETUP_TEST_KEY" "the card names it"))
      (set-symbol-value! 'zz-setup-test-key "zz-value")
      (check-true! (null? (setup--unmet (setup-connector-requirements "zz-keyed")))
                   "set, nothing is missing")
      (check-equal! (agent-env-resolve '(("ZZ_SETUP_TEST_KEY" zz-setup-test-key)))
                    '(("ZZ_SETUP_TEST_KEY" "zz-value")) "the agent gets the value")
      (unbind-global! 'zz-setup-test-key)
      (set! *custom-vars* old-vars)
      (set! *agent-connectors* old-connectors))))

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

;;; --- install a coding agent ----------------------------------------------------

(define (setup-test--with-present present fn)
  (let ((old setup--program-present?))
    (set! setup--program-present? (lambda (program) (and (member program present) #t)))
    (let ((result (fn)))
      (set! setup--program-present? old)
      result)))

(deftest 'an-agent-install-runs-only-the-missing-steps
  "a program already on PATH is not installed again"
  (lambda ()
    (check-equal! (map car (setup-test--with-present '()
                             (lambda () (setup-agent-missing-steps "claude-code"))))
                  '("claude" "claude-agent-acp") "a bare machine needs both")
    (check-equal! (map car (setup-test--with-present '("claude")
                             (lambda () (setup-agent-missing-steps "claude-code"))))
                  '("claude-agent-acp") "the CLI is present; the adapter is not")
    (check-equal! (map car (setup-test--with-present '()
                             (lambda () (setup-agent-missing-steps "codex-app-server"))))
                  '("codex") "codex")))

(deftest 'an-agent-install-script-installs-then-names-the-sign-in
  "the script runs each step, names the sign-in command, and leaves a shell"
  (lambda ()
    (let ((script (setup-agent-install-script "codex-app-server"
                    '(("codex" "npm install -g @openai/codex")))))
      (check-contains! script "npm install -g @openai/codex" "the step")
      (check-contains! script "codex login" "the sign-in command")
      (check-contains! script "-l" "a login shell stays"))))

(deftest 'an-installed-agent-starts-no-terminal
  "nothing runs when every program is present"
  (lambda ()
    (check-false! (setup-test--with-present '("claude" "claude-agent-acp" "npm")
                    (lambda () (setup-install-agent! "claude-code")))
                  "no install")
    (check-false! (buffer-exists? (setup-agent-install-buffer "claude-code"))
                  "no terminal buffer")))

(deftest 'an-npm-install-without-npm-starts-no-terminal
  "a missing npm stops the install before a terminal opens"
  (lambda ()
    (check-false! (setup-test--with-present '()
                    (lambda () (setup-install-agent! "codex-app-server")))
                  "no install")
    (check-false! (buffer-exists? (setup-agent-install-buffer "codex-app-server"))
                  "no terminal buffer")))

;;; --- the pages read as web pages -----------------------------------------------

(deftest 'a-setup-page-opens-rendered
  "a setup document opens in preview-mode, not as Markdown source"
  (lambda ()
    (let ((here (current-buffer))
          (old setup-bot-silent-mode))
      (set! setup-bot-silent-mode #f)
      (when (buffer-exists? *setup-buffer*) (buffer-kill! *setup-buffer*))
      (run-command "setup-welcome")
      (check-true! (minor-mode-on? *setup-buffer* "preview-mode") "preview-mode is on")
      (check-equal! (buffer-local *setup-buffer* 'preview-renderer) "markdown" "the renderer")
      (set! setup-bot-silent-mode old)
      (buffer-kill! *setup-buffer*)
      (switch-to-buffer! here))))

(deftest 'the-welcome-page-has-its-doors-and-its-keys
  "the welcome page links the three first steps and names the three keys"
  (lambda ()
    (let ((doc (setup-welcome-document)))
      (check-contains! doc "](compos:setup/wizard)" "the wizard")
      (check-contains! doc "](compos:training/tutorial)" "the tutorial")
      (check-contains! doc "](compos:setup/ai)" "the AI guide")
      (check-contains! doc "| `M-x` |" "the command key")
      (check-contains! doc (setup-logo-path) "the logo")
      (check-true! (file-exists? (setup-logo-path)) "the logo file ships"))))
