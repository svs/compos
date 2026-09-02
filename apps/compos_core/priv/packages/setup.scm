;;; setup.scm --- the first-run setup bot, in Scheme.
;;;
;;; Setup is a conversation over existing editor policy. It does not own a
;;; second provider registry or a second secret store. It checks the parts
;;; already loaded, selects the local Gemini Nano connector, and teaches the
;;; user how to continue with M-x.

(package! 'setup)
(domain! 'system)
(effects! '(read write external))

(defgroup 'setup "First-run setup for inference, secrets, connectors, and learning.")

(defcustom 'setup-bot-silent-mode #f
  "Keep setup prompts active, but never create, display, or replace an editor window."
  'group 'setup 'type 'boolean)

(defcustom 'setup-openrouter-model "openrouter:anthropic/claude-sonnet-5"
  "The hosted model selected after OpenRouter setup."
  'group 'setup 'type 'string)

(define *setup-buffer* "*setup*")
(define setup-openrouter-keys-url "https://openrouter.ai/settings/keys")

(define *setup-secret-backends*
  '(("Doppler" "doppler" "doppler login")
    ("1Password" "op" "op signin")
    ("GPG" "gpg" "gpg --list-secret-keys")
    ("macOS Keychain" "security" "security unlock-keychain")
    ("Linux Secret Service" "secret-tool" "secret-tool search service compos")))

(define (setup--program-present? program)
  ;; `command -v` works on macOS and Linux. Do not expose command output.
  (not (equal? (string-trim
                 (shell-command->string
                   (string-append "command -v " program " 2>/dev/null"))) "")))

(define (setup-secret-backends)
  "Return secret backends as (NAME PROGRAM AVAILABLE COMMAND), without values."
  (map (lambda (entry)
         (list (car entry) (cadr entry)
               (setup--program-present? (cadr entry)) (caddr entry)))
       *setup-secret-backends*))

(define (setup--available-secret-backends backends)
  (filter (lambda (entry) (nth 2 entry)) backends))

(define (setup--join-names names)
  (cond ((null? names) "no supported secret tools")
        ((null? (cdr names)) (car names))
        ((null? (cddr names)) (string-append (car names) " and " (cadr names)))
        (else
          (string-append (string-join (reverse (cdr (reverse names))) ", ")
                         ", and " (car (reverse names))))))

(define (setup-secret-greeting-for backends)
  "Return the first setup question for BACKENDS."
  (string-append "Hello. I see "
                 (setup--join-names
                   (map car (setup--available-secret-backends backends)))
                 ". Would you like to configure your secrets?"))

(define (setup-secret-greeting)
  "Return the first setup question, using the installed secret tools."
  (setup-secret-greeting-for (setup-secret-backends)))

(define (setup--yes-no value)
  (if value "ready" "not found"))

(define (setup--connector-ready? name)
  (and (boundp 'connector-config)
       (plist-get (connector-config name) 'backend)))

(define (setup-connectors)
  "Return connector readiness for mail, Spotify, and Gemini Nano."
  (list (list "Gemini Nano" (setup--connector-ready? "gemini-nano")
              "Chrome Prompt API; no API key")
        (list "Spotify" (boundp 'spotify-now-playing)
              "Chrome tab; sign in in the tab")
        (list "Mail" (boundp 'notmuch-inbox)
              "notmuch CLI and a local mail index")))

(define (setup-provider-bootstrap!)
  "Select Gemini Nano as the safe local first provider."
  (if (setup--connector-ready? "gemini-nano")
      (begin
        (set! *default-connector* "gemini-nano")
        (message "Setup: Gemini Nano is the default local connector")
        "gemini-nano")
      (begin
        (message "Setup: Gemini Nano connector is not loaded")
        #f)))

(define (setup--replace-buffer! buf text)
  (buffer-create buf)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text))

;; A bot document never takes the user's selected window. Silent mode does
;; not create or display the document, so it cannot alter the window tree.
(define (bot-show-document-other-window! buf title markdown silent?)
  (if silent?
      (message (string-append "Setup: " title))
      (begin
        (setup--replace-buffer! buf markdown)
        (buffer-set-local! buf 'help-title title)
        (with-current-buffer buf (lambda () (set-mode! "help-mode")))
        (display-buffer-other-window! buf))))

(define (setup--show-document! title markdown)
  (bot-show-document-other-window!
    *setup-buffer* title markdown setup-bot-silent-mode))

(define (find-file-other-window! path)
  "Visit local PATH in another window, or do nothing in silent mode."
  (if setup-bot-silent-mode
      (begin (message (string-append "Silent setup did not open " path)) #f)
      (let* ((p (normalize-file-input path))
             (buf (find-file p)))
        (with-current-buffer buf
          (lambda ()
            (auto-mode p)
            (run-hooks 'find-file-hook)))
        (display-buffer-other-window! buf)
        buf)))

(define setup-find-file-other-window! find-file-other-window!)

(define-command "find-file-other-window"
  "Find a file and display it only in another window"
  (lambda ()
    (read-file-name "Find file in other window: " find-file-other-window!)))

(define-key "ctl-x-4-map" "f" "find-file-other-window")

;;; --- guided setup -------------------------------------------------------------

(define (setup--secret-help! name)
  (setup--show-document! (string-append name " setup")
    (cond
      ((equal? name "1Password")
       (string-append
         "# 1Password\n\n"
         "Sign in with `op signin`. Keep references in config, not secret values.\n\n"
         "The current key chain reads environment variables, local key files, and Doppler.\n"
         "A later 1Password adapter can resolve `@NAME` references through `op`.\n"))
      ((equal? name "GPG")
       (string-append
         "# GPG\n\n"
         "Check your private keys with `gpg --list-secret-keys`.\n\n"
         "Use GPG for encrypted files. Do not put decrypted values in Scheme config.\n"))
      ((equal? name "macOS Keychain")
       (string-append
         "# macOS Keychain\n\n"
         "The `security` command can read Keychain items after macOS grants access.\n\n"
         "The setup bot does not copy a secret into a buffer or transcript.\n"))
      (else
       (string-append
         "# Linux Secret Service\n\n"
         "Use `secret-tool` with your desktop keyring.\n\n"
         "The setup bot does not copy a secret into a buffer or transcript.\n")))))

(define (setup--show-doppler!)
  (if setup-bot-silent-mode
      (message "Doppler is available. Silent setup kept the window layout unchanged.")
      (begin
        (buffer-create *doppler-buffer*)
        (buffer-set-local! *doppler-buffer* 'window-class #f)
        (buffer-set-local! *doppler-buffer* 'window-style #f)
        (buffer-set-local! *doppler-buffer* 'group *doppler-group*)
        (unless (buffer-local *doppler-buffer* 'doppler-project)
          (buffer-set-local! *doppler-buffer* 'doppler-project key-doppler-project))
        (unless (buffer-local *doppler-buffer* 'doppler-config)
          (buffer-set-local! *doppler-buffer* 'doppler-config key-doppler-config))
        (with-current-buffer *doppler-buffer* (lambda () (set-mode! "doppler-mode")))
        (display-buffer-other-window! *doppler-buffer*))))

(define (setup--configure-secret-backend! name)
  (if (equal? name "Doppler")
      (setup--show-doppler!)
      (setup--secret-help! name)))

;; Registration is mechanism: the key becomes usable. Selection is policy:
;; which connector a chat rides is the user's choice. The two are separate
;; calls, so boot can do the first without doing the second.
(define (setup-openrouter-register!)
  "Register the stored OpenRouter key. Do not select a connector."
  (let ((key (key-get "OPENROUTER_API_KEY")))
    (if key
        (begin (register-llm-key! "openrouter" key) #t)
        #f)))

(define (setup-openrouter-enable!)
  "Register the stored OpenRouter key and select hosted inference."
  (if (setup-openrouter-register!)
      (begin
        (set! *default-connector* "api")
        (set-llm-model! setup-openrouter-model)
        (message "OpenRouter is ready as the default inference provider")
        #t)
      (begin (message "OPENROUTER_API_KEY is not available") #f)))

(define (setup--store-openrouter-key! destination key)
  (cond
    ((equal? (string-trim key) "")
     (message "OpenRouter key was empty") #f)
    ((equal? destination "Doppler")
     (if (doppler-secret-set! key-doppler-project key-doppler-config
                              "OPENROUTER_API_KEY" key)
         (begin
           (doppler-forget!)
           (key-forget! "OPENROUTER_API_KEY")
           (setup-openrouter-enable!))
         (begin (message "Doppler did not store OPENROUTER_API_KEY") #f)))
    (else
      (let ((path (string-append (compos-config-dir) "/openrouter-key")))
        (write-file! path (string-append (string-trim key) "\n"))
        (set-file-mode! path "600")
        (key-forget! "OPENROUTER_API_KEY")
        (setup-openrouter-enable!)))))

(define (setup--openrouter-storage-options)
  (if (setup--program-present? "doppler")
      '("Doppler" "Local key file")
      '("Local key file")))

(define (setup--ask-openrouter-key destination)
  (unless setup-bot-silent-mode (tab-open setup-openrouter-keys-url))
  (minibuffer-read "Paste OPENROUTER_API_KEY: " '()
    (lambda (key)
      (setup--store-openrouter-key! destination key)
      (setup--ask-connectors))))

(define (setup--configure-openrouter)
  (minibuffer-read "Store OPENROUTER_API_KEY in: "
    (setup--openrouter-storage-options)
    setup--ask-openrouter-key))

(define (setup--finish!)
  (message "Setup is ready. Run M-x setup-bot whenever you want to revisit it."))

(define (setup--choose-lesson)
  (minibuffer-read "What would you like to learn? "
    '("M-x and philosophy" "Writing code" "Finish")
    (lambda (choice)
      (cond ((equal? choice "M-x and philosophy") (run-command "setup-teach-keys"))
            ((equal? choice "Writing code") (run-command "setup-teach-code"))
            (else (setup--finish!))))))

(define (setup--ask-lesson)
  (y-or-n "Would you like a short editor lesson?"
    setup--choose-lesson setup--finish!))

(define (setup--open-connector! name)
  (cond
    ((equal? name "Spotify")
     (if setup-bot-silent-mode
         (message "Spotify is available. Silent setup did not open its tab.")
         (run-command "spotify")))
    ((equal? name "Mail")
     (if setup-bot-silent-mode
         (message "Mail is available. Silent setup kept the window layout unchanged.")
         (begin
           (buffer-create *notmuch-hello-buffer*)
           (with-current-buffer *notmuch-hello-buffer*
             (lambda () (set-mode! "notmuch-hello-mode")))
           (display-buffer-other-window! *notmuch-hello-buffer*))))))

(define (setup--choose-connector)
  (let ((names (map car (filter cadr (setup-connectors)))))
    (if (null? names)
        (setup--ask-lesson)
        (minibuffer-read "Connect a service: " (append names '("Skip"))
          (lambda (choice)
            (unless (equal? choice "Skip") (setup--open-connector! choice))
            (setup--ask-lesson))))))

(define (setup--ask-connectors)
  (y-or-n "Would you like to connect mail or Spotify now?"
    setup--choose-connector setup--ask-lesson))

(define (setup--ask-gemini)
  (y-or-n "Use local Gemini Nano as the bootstrap inference provider?"
    (lambda () (setup-provider-bootstrap!) (setup--ask-connectors))
    setup--ask-connectors))

(define (setup--ask-provider)
  (if (key-get "OPENROUTER_API_KEY")
      (begin (setup-openrouter-enable!) (setup--ask-connectors))
      (y-or-n "Configure OpenRouter for hosted inference now?"
        setup--configure-openrouter setup--ask-gemini)))

(define (setup--choose-secret-backend)
  (let ((names (map car
                 (setup--available-secret-backends (setup-secret-backends)))))
    (if (null? names)
        (setup--ask-provider)
        (minibuffer-read "Secret backend: " names
          (lambda (choice)
            (setup--configure-secret-backend! choice)
            (setup--ask-provider))))))

(define (setup--ask-secrets)
  (y-or-n (setup-secret-greeting)
    setup--choose-secret-backend setup--ask-provider))

(define (setup-report)
  "Return a secret-free setup report for the bot and the user."
  (let* ((backends (setup-secret-backends))
         (connectors (setup-connectors))
         (secret-lines
           (map (lambda (b)
                  (string-append "- " (car b) ": "
                                 (setup--yes-no (nth 2 b))
                                 " (`" (nth 1 b) "`)"))
                backends))
         (connector-lines
           (map (lambda (c)
                  (string-append "- " (car c) ": "
                                 (setup--yes-no (cadr c))
                                 " — " (caddr c)))
                connectors)))
    (string-append
      "# compos setup\n\n"
      "[Inference](#inference) · [Secrets](#secret-backends) · "
      "[Connectors](#connectors) · [Lessons](#next-lessons)\n\n"
      "## Inference\n\n"
      "Gemini Nano is the bootstrap connector. It runs through the Chrome Prompt API.\n\n"
      "[Create an OpenRouter key](https://openrouter.ai/settings/keys), then rerun the setup bot.\n\n"
      "Run `M-x setup-bootstrap-gemini` to select it as the default.\n\n"
      "## Secret backends\n\n"
      "The key chain reads environment variables, ~/.compos key files, then Doppler.\n"
      "These installed tools are candidates for the setup bot:\n\n"
      (string-join secret-lines "\n") "\n\n"
      "The setup bot never prints secret values.\n\n"
      "## Connectors\n\n"
      (string-join connector-lines "\n") "\n\n"
      "## Next lessons\n\n"
      "- `M-x setup-teach-code` explains the code-agent workflow.\n"
      "- `M-x setup-teach-keys` explains M-x and the editor philosophy.\n"
      "- `M-x apropos` searches the live command and function catalog.\n")))

(define-command "setup-bot" "Walk through first-run setup one question at a time"
  (lambda () (setup--ask-secrets)))

(define-command "setup-report" "Open the secret-free setup status report"
  (lambda () (setup--show-document! "compos setup" (setup-report))))

(define-command "setup-bootstrap-gemini" "Set Gemini Nano as the default local connector"
  (lambda ()
    (setup-provider-bootstrap!)
    (setup--show-document! "Gemini Nano" (string-append
      "# Gemini Nano\n\n"
      "[Back to setup](compos:setup/report)\n\n"
      "Gemini Nano runs locally through a Chrome tab. It needs no API key.\n\n"
      "Open or focus Chrome, then use `M-x start-chat` or your normal chat command.\n"
      "The setup bot selected `gemini-nano` as the default connector.\n"))))

(define-command "setup-teach-code" "Teach the code-agent workflow"
  (lambda ()
    (setup--show-document! "learning to write code" (string-append
      "# Learning to write code\n\n"
      "[Back to setup](compos:setup/report)\n\n"
      "1. Open a project file with `C-x C-f`.\n"
      "2. Start a chat with `M-x start-chat`.\n"
      "3. Enable `M-x code-agent-mode` in that chat.\n"
      "4. Ask for a plan before asking for an edit.\n"
      "5. Review the buffer diff.\n"
      "6. Run focused tests, then the relevant full suite.\n\n"
      "The agent edits live buffers through named tools. Scheme owns the policy.\n"
      "The BEAM owns processes, sockets, PTYs, and model transport.\n"
      "Use `(skill \"code-editing\")` when the agent needs the full code skill.\n"))))

(define-command "setup-teach-keys" "Teach M-x and the compos philosophy"
  (lambda ()
    (setup--show-document! "M-x and the editor philosophy" (string-append
      "# M-x and the editor philosophy\n\n"
      "[Back to setup](compos:setup/report)\n\n"
      "`M-x` runs a named command. Type part of a command name, then select it.\n"
      "Commands are the stable interface for people and agents. Key bindings are preferences.\n\n"
      "`M-x apropos` searches commands and functions by words.\n"
      "`M-x contextual-help` explains the current buffer.\n"
      "`C-h k` explains a key.\n"
      "`C-h m` explains the current mode.\n"
      "`M-:` evaluates Scheme.\n\n"
      "The editor keeps state in buffers. Windows compose views. Modes add local policy.\n"
      "Scheme decides editor behavior. Elixir supplies mechanisms that Scheme cannot provide.\n"
      "This keeps the system open, inspectable, and teachable.\n"))))

(define (setup--follow-link arg)
  (cond ((equal? arg "report") (run-command "setup-report"))
        ((equal? arg "keys") (run-command "setup-teach-keys"))
        ((equal? arg "code") (run-command "setup-teach-code"))
        (else (message (string-append "Unknown setup link: " arg)))))

(on-preview-link! "setup" setup--follow-link)

(category! 'setup)
(public! 'setup-secret-backends
  "(setup-secret-backends) — installed secret tools, without secret values")
(public! 'setup-secret-greeting
  "(setup-secret-greeting) — the first guided setup question for installed secret tools")
(public! 'setup-connectors
  "(setup-connectors) — readiness of the bootstrap connectors")
(public! 'setup-provider-bootstrap!
  "(setup-provider-bootstrap!) — select Gemini Nano as the default connector")
(public! 'setup-openrouter-register!
  "(setup-openrouter-register!) — register the stored OpenRouter key; leave the connector alone")
(public! 'setup-openrouter-enable!
  "(setup-openrouter-enable!) — register the stored OpenRouter key and select hosted inference")
(public! 'setup-find-file-other-window!
  "(setup-find-file-other-window! PATH) — visit PATH only in another window; silent mode does nothing")
(public! 'find-file-other-window!
  "(find-file-other-window! PATH) — visit PATH only in another window; silent setup does nothing")
(public! 'bot-show-document-other-window!
  "(bot-show-document-other-window! BUFFER TITLE MARKDOWN SILENT?) — show bot documentation only in another window")
(public! 'setup-report "(setup-report) — secret-free first-run setup report")

;; A key installed by an earlier setup run stays usable after every reload.
;; This registers the key only. It does not select the connector: the user
;; owns that choice, `customize` keeps it in custom.scm, and a load-time
;; set! overwrites the choice on every boot and on every reload of this
;; file. Run `M-x setup-bot`, or (setup-openrouter-enable!), to select the
;; hosted lane.
(setup-openrouter-register!)
