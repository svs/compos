;;; setup-test.scm --- setup.scm: the first-run setup policy.

(domain! 'testing)
(effects! '(read))

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
    (check-true! (assoc "setup" *preview-link-verbs*) "the setup link handler")))

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
