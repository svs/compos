;;; agent-connectors.scm --- Agent connector and model configuration.
;;;
;;; This module owns connector declarations, model resolution, ACP prompt
;;; fragments, and the connector modeline. Prompt fragments preserve their
;;; session-start order.

(domain! 'agents)
(effects! '(write))
(category! 'chat)

(define *agent-connectors* '())

(define *default-connector* "claude-code")

(defcustom 'agent-connector-command-overrides '()
  "Per-user adapter commands as ((CONNECTOR COMMAND) ...).
For example, ((\"claude-code\" \"/opt/acp/claude-agent-acp\")) keeps a
nonstandard install out of the built-in connector catalog."
  'group 'chat 'type 'list)

(define (define-connector! name config)
  (set! *agent-connectors*
    (cons (list name config)
          (let loop ((cs *agent-connectors*) (acc '()))
            (cond ((null? cs) (reverse acc))
                  ((equal? (car (car cs)) name) (loop (cdr cs) acc))
                  (else (loop (cdr cs) (cons (car cs) acc))))))))

(define (connector-config name)
  (let* ((e (assoc name *agent-connectors*))
         (config (if e (car (cdr e)) '()))
         (override (assoc name agent-connector-command-overrides)))
    (if (and override (pair? (cdr override))
             (string? (cadr override))
             (not (equal? (cadr override) "")))
        (append (list 'cmd (cadr override)) config)
        config)))

(define-connector! "claude-code"
  ;; @agentclientprotocol/claude-agent-acp ships this executable. Resolve it
  ;; through PATH so npm, pnpm, bun, asdf, and other installers all work.
  '(cmd "claude-agent-acp"
    ;; The editor names every tool through MCP and writes the whole
    ;; system prompt, so the adapter's own tools have no place in an
    ;; editor thread: everything goes through Scheme. settingSources and
    ;; strictMcpConfig take the user's settings file and MCP registry
    ;; away; they do NOT touch the tools the SDK ships with, which is why
    ;; Bash kept running under a prompt that said shell was disabled.
    ;; The adapter merges this list with its own (acp-agent.ts,
    ;; createSessionOptions). ExitPlanMode and AskUserQuestion stay: plan
    ;; mode has to have a way out, and the adapter owns the second one.
    meta (claudeCode
           (options (settingSources () strictMcpConfig #t
                     disallowedTools ("Bash" "BashOutput" "KillShell"
                                      "Read" "Write" "Edit" "MultiEdit"
                                      "NotebookEdit" "Glob" "Grep"
                                      "WebFetch" "WebSearch"
                                      "Task" "Agent" "TodoWrite"
                                      "SlashCommand" "ReportFindings"
                                      "TaskCreate" "TaskUpdate"
                                      "TaskList" "TaskGet"))))
    ;; the seed only has to hold until a session reports its own list;
    ;; llm-models-seen! keeps that answer for the connector, and the picker
    ;; still offers a model here that the adapter does not list yet
    models ("default" "claude-opus-5-5[1m]" "opus[1m]" "claude-fable-5-1[1m]" "sonnet" "haiku"
            "claude-haiku-5-5")))

(define *codex-app-server-connector*
  '(backend "codex-app-server" cmd "codex app-server"
    models ("gpt-6.1-sol" "gpt-6-astra" "gpt-6-sol" "gpt-6-luna"
            "gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna" "gpt-5.5"
            "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex-spark")))

(define-connector! "codex-app-server" *codex-app-server-connector*)

(define-connector! "codex" (append '(hidden #t) *codex-app-server-connector*))

(define-connector! "codex-acp"
  '(hidden #t deprecated "use codex-app-server"
    cmd "codex-acp" model-flag "-c model="
    models ("gpt-5.6-luna" "gpt-5.5" "gpt-5.5-pro" "gpt-5.4" "gpt-5.4-mini" "gpt-5.3-codex")))

(define-connector! "opencode"
  '(cmd "opencode acp"
    model-config #t
    models ("opencode/big-pickle" "opencode/claude-sonnet-5"
            "opencode/claude-opus-5" "opencode/claude-haiku-5-5"
            "opencode/gemini-3.1-pro")))

(define-connector! "deepseek"
  ;; DeepSeek Harness over ACP. The direct API lane bills every request for
  ;; the whole prefix; the harness keeps one session, so DeepSeek's context
  ;; cache serves the prefix and only the new turn is full price.
  ;; @deepseek-ai/dsh ships the `dsh` executable. The provider key lives in
  ;; ~/.dsh/.credentials.yaml, which the harness writes.
  ;; The shipped adapter cannot steer a running turn: reapply
  ;; docs/dsh-acp-steering.patch after every install, or blank RET only ever
  ;; queues on this lane.
  '(cmd "dsh --profile acp"
    ;; the session reports model and reasoning effort as ACP config
    ;; options, so the model rides in protocol config, not the command line
    model-config #t
    ;; the harness drops _meta, so our prompt sections ride the first turn
    system-in-prompt #t
    ;; the thread runs in an editor-owned DSH_HOME (skills.scm), which
    ;; carries the profile patch that turns the harness's own tools and
    ;; prompt off
    sanitize "dsh"
    models ("deepseek-v4-pro" "deepseek-v4-flash" "deepseek-v4-flash-vision-exp")))

(define-connector! "api"
  (list 'backend "req-llm"
        ;; User choices stay first as favorites; ReqLLM contributes every
        ;; chat model whose provider is configured on this machine, and the
        ;; live catalog contributes what the providers shipped since the
        ;; snapshot was cut.
        'models (lambda () (llm-catalogued-models))))

(define-connector! "gemini-nano"
  '(backend "chrome-gemini-nano" models ("gemini-nano")))

;;; --- the live model catalog ---------------------------------------------------
;;; LLMDB ships a snapshot of what each provider offers, and a snapshot
;;; ages: the day a provider ships a model, nothing in the picker can name
;;; it. So ask the provider. OpenRouter publishes its whole catalog with no
;;; key, and it is the provider with the most to miss — hundreds of models,
;;; new ones most weeks. The answer is cached in compos-home, so the list
;;; survives a restart and no menu ever waits on the network.

(define llm-catalog-file (string-append (compos-home) "/model-catalog.scm"))

;; PROVIDER -> ((ID NAME) ...), as the provider itself reports it
(define *llm-catalog* '())
;; when a provider last answered, and when one was last asked. The first
;; is cached with the catalog; the second only holds off a retry storm
;; while the network is down, so it starts fresh every session.
(define *llm-catalog-fetched* 0)
(define *llm-catalog-tried* 0)
(define llm-catalog-max-age 86400)
(define llm-catalog-retry-after 300)

(define *llm-catalog-sources*
  '(("openrouter" "https://openrouter.ai/api/v1/models")))

(define (llm-catalog-models)
  (fold (lambda (acc entry)
          (append acc
            (map (lambda (m) (string-append (car entry) ":" (car m)))
                 (cadr entry))))
        '() *llm-catalog*))

;; A provider answers {"data": [{"id": ..., "name": ...}, ...]}. An id with
;; a colon in it is a billing variant (":batch", ":free"), and one that
;; begins with ~ is the provider's alias marker: neither is a model you
;; would choose by name, and a colon would break "provider:model" routing.
(define (llm-catalog-parse text)
  (let* ((doc (and text (not (equal? (string-trim text) "")) (json-parse text)))
         (data (plist-get doc 'data)))
    (if (not (pair? data))
        '()
        (fold (lambda (acc m)
                (let ((id (plist-get m 'id)))
                  (if (and (string? id)
                           (not (string-contains? id ":"))
                           (not (string-prefix? "~" id)))
                      (append acc (list (list id (or (plist-get m 'name) ""))))
                      acc)))
              '() data))))

(define (llm-catalog-put! provider models)
  (set! *llm-catalog* (alist-put *llm-catalog* provider models)))

(define (llm-catalog-save!)
  (write-file! llm-catalog-file
    (string-append "(set! *llm-catalog* '" (value->string *llm-catalog*) ")\n"
                   "(set! *llm-catalog-fetched* "
                   (number->string *llm-catalog-fetched*) ")\n")))

;; K hears how many models the provider named, or #f when it said nothing.
(define (llm-catalog-fetch! provider url k)
  (shell-command->string
    (string-append "curl -s --max-time 20 '" url "'")
    (lambda (out)
      (let ((models (llm-catalog-parse out)))
        (if (null? models)
            (k #f)
            (begin
              (llm-catalog-put! provider models)
              (set! *llm-catalog-fetched* (current-time))
              (llm-catalog-save!)
              (k (length models))))))))

(define (llm-catalog-refresh! k)
  (for-each (lambda (src) (llm-catalog-fetch! (car src) (cadr src) k))
            *llm-catalog-sources*))

;; Opening the model picker on a day-old catalog refreshes it behind the
;; picker: this list is what it knows now, and the next one is longer.
(define (llm-catalog-maybe-refresh!)
  (when (and (> (- (current-time) *llm-catalog-fetched*) llm-catalog-max-age)
             (> (- (current-time) *llm-catalog-tried*) llm-catalog-retry-after))
    (set! *llm-catalog-tried* (current-time))
    (llm-catalog-refresh!
      (lambda (n)
        (when n (message (string-append "model catalog: "
                                        (number->string n) " models")))))))

(define-command "llm-models-refresh" "Ask every provider for its own model list"
  (lambda ()
    (message "asking the providers for their models...")
    (llm-catalog-refresh!
      (lambda (n)
        (message (if n
                     (string-append "model catalog: " (number->string n)
                                    " models")
                     "model catalog: no answer"))))
    ;; every agent connector reports its own list (chat-mode.scm)
    (for-each
      (lambda (name)
        (llm-models-probe! name
          (lambda (connector n)
            (message (string-append connector ": "
                       (if n (string-append (number->string n) " models")
                           "no answer"))))))
      (llm-models-probe-connectors))))

;; Every model the direct lane can be asked for: the favorites first, then
;; one of everything the snapshot and the providers know. sort is a
;; builtin, so uniqueness over ~800 ids costs n log n rather than the n^2 a
;; member-scan would cost, and the rest read in provider order because the
;; id starts with the provider.
(define (llm-models-unique lst)
  (let loop ((xs (sort lst)) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((and (pair? acc) (equal? (car xs) (car acc))) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

(define (llm-catalogued-models)
  (append *llm-models*
    (remove (lambda (m) (member m *llm-models*))
            (llm-models-unique (append (llm-available-models)
                                       (llm-catalog-models))))))

(define (connector-capabilities name)
  (backend-capabilities (or (plist-get (connector-config name) 'backend) "acp")))

(define (connector-can? name cap)
  (and (member cap (connector-capabilities name)) #t))

(define (connector-models name)
  (let ((m (plist-get (connector-config name) 'models)))
    (cond ((procedure? m) (m))
          (m m)
          (else '()))))

(define (agent-model-env m)
  (list 'env (list (list "ANTHROPIC_MODEL" m)
                   (list "CLAUDE_CODE_SUBAGENT_MODEL" m))))

(define (agent-resolve-config opts)
  ;; a codex thread runs in a sanitized CODEX_HOME so the user's own
  ;; ~/.codex config and skills never reach it (skills.scm, which loads
  ;; after this file). The backend test walks the plist with the member
  ;; builtin so it exercises the same representation as the turn-start path.
  (let* ((conf0 (agent-resolve-config* opts))
         (codex? (let ((tl (member (quote backend) conf0)))
                   (and tl (pair? (cdr tl))
                        (equal? (car (cdr tl)) "codex-app-server"))))
         (conf (cond ((and codex? (boundp (quote codex-config-with-env)))
                      (codex-config-with-env conf0))
                     ;; a DeepSeek Harness thread reads an editor-owned
                     ;; DSH_HOME for the same reason: the user's own
                     ;; settings, keys and skills stay out of it
                     ((and (equal? (plist-get conf0 (quote sanitize)) "dsh")
                           (boundp (quote dsh-config-with-env)))
                      (dsh-config-with-env conf0))
                     (else conf0))))
    ;; ACP threads get exactly the servers their presets name. The editor's
    ;; own tools are the `compos` preset, not an implicit exception. The
    ;; direct lane needs no server config: it reads the same preset surface
    ;; fresh at every send.
    (if (or (equal? (plist-get conf 'backend) "req-llm")
            (plist-get conf 'mcp-servers)
            (not (boundp (quote presets-acp-servers))))
        conf
        (agent-config-with-system-parts
          (append conf
            (list 'mcp-servers
                  (presets-acp-servers (or (plist-get conf 'presets) '()))))))))

(define (agent-system-text had text)
  (if (equal? had "") text (string-append had "\n\n" text)))

;; Most ACP adapters read our sections from _meta.systemPrompt. DeepSeek
;; Harness does not: its ACP surface drops protocol metadata before the
;; model request, so a connector that declares 'system-in-prompt carries
;; the same text in the session's first user message instead. That message
;; is the head of the prefix, which is what the provider caches.
(define (agent-config-append-system conf text)
  (if (plist-get conf 'system-in-prompt)
      (append (list 'system (agent-system-text (or (plist-get conf 'system) "") text))
              conf)
      (let* ((meta (or (plist-get conf 'meta) '()))
             (sp (or (plist-get meta 'systemPrompt) '()))
             (had (or (plist-get sp 'append) "")))
        (append (list 'meta (append (list 'systemPrompt
                                          (list 'append (agent-system-text had text)))
                                    meta))
                conf))))

(define (agent-config-with-mcp-note conf)
  (let ((note (if (and (boundp (quote mcp-system-note))
                       (boundp (quote preset-servers)))
                  ;; only what this thread's presets expose — the same set
                  ;; its mcpServers list holds
                  (mcp-system-note
                    (fold (lambda (acc p)
                            (fold (lambda (acc2 s) (if (member s acc2) acc2 (cons s acc2)))
                                  acc (preset-servers p)))
                          '() (or (plist-get conf 'presets) '())))
                  "")))
    (if (equal? note "")
        conf
        (agent-config-append-system conf note))))

(define (agent-config-with-code-note conf)
  (let ((buf (plist-get conf 'buffer)))
    (if (and buf (boundp (quote code-agent-system-note)))
        (let ((note (code-agent-system-note buf)))
          (if (equal? note "") conf (agent-config-append-system conf note)))
        conf)))

(define (agent-live-system-prompt-source-parts conf)
  (let* ((buf (plist-get conf 'buffer))
         (mode-parts
           (if (and buf (boundp (quote prompt-buffer-parts)))
               (prompt-buffer-parts buf)
               '()))
         (mcp-note
           (if (and (boundp (quote mcp-system-note))
                    (boundp (quote preset-servers)))
               (mcp-system-note
                 (fold (lambda (acc p)
                         (fold (lambda (acc2 s)
                                 (if (member s acc2) acc2 (cons s acc2)))
                               acc (preset-servers p)))
                       '() (or (plist-get conf 'presets) '())))
               "")))
    (filter
      (lambda (part) (not (equal? (car (cdr part)) "")))
      (append
        (compos-acp-prompt-parts)
        (list (list "mcp" mcp-note))
        (if buf
            (list (list "chat-preamble" (chat-preamble buf))
                  (list "code" (chat-code-prompt buf)))
            '())
        mode-parts))))

(define (agent-live-system-prompt-parts conf)
  (let* ((buf (plist-get conf 'buffer))
         (source (agent-live-system-prompt-source-parts conf))
         (parts (if (boundp (quote prompt-section-parts))
                    (prompt-section-parts source)
                    source)))
    (if (and buf (boundp (quote prompt-parts-enabled)))
        (prompt-parts-enabled buf parts)
        parts)))

(define (agent-system-prompt-parts conf)
  (let* ((buf (plist-get conf 'buffer))
         (target (and buf (or (buffer-ref buf) buf)))
         (live (agent-live-system-prompt-parts
                 (if target (append (list 'buffer target) conf) conf))))
    (if (and buf (boundp (quote chat-prompt-snapshot-parts)))
        (chat-prompt-snapshot-parts target 'acp live)
        live)))

(define (agent-config-with-system-parts conf)
  (fold (lambda (out part) (agent-config-append-system out (car (cdr part))))
        conf (agent-system-prompt-parts conf)))

(domain! 'chat)

(effects! '(read))

(public! 'agent-live-system-prompt-parts
  "(agent-live-system-prompt-parts CONF) — current ACP prompt sections before the conversation freeze")
(public! 'agent-live-system-prompt-source-parts
  "(agent-live-system-prompt-source-parts CONF) — unfiltered ACP prompt fragments")

(effects! '(write))

(public! 'agent-system-prompt-parts
  "(agent-system-prompt-parts CONF) — named ACP system-prompt sections in session-start order")

;; the buffer's own working directory, offered as a cwd for the thread it
;; attaches: a chat answers with its 'chat-directory (buffer-directory follows
;; that local), any other buffer with the directory it belongs to.
(define (agent-config-buffer-cwd opts)
  (let ((buf (plist-get opts 'buffer)))
    (if (and (string? buf) (buffer-exists? buf))
        (list 'cwd (buffer-directory buf))
        '())))

(define (agent-resolve-config* opts)
  (let* ((cname (or (plist-get opts 'connector) *default-connector*))
         ;; A thread works where its buffer works. The ACP and Codex lanes are
         ;; told their cwd once, at session/new, and until now nobody told them
         ;; at all: every session ran in the daemon's own directory. This says
         ;; it LAST, so an explicit 'cwd in the attach opts (an isolated
         ;; worktree) and a connector's own declared cwd both still win.
         (conf (append opts (connector-config cname) (agent-config-buffer-cwd opts)))
         (m (or (plist-get conf 'model)
                (and (member (llm-model) (connector-models cname)) (llm-model)))))
    (cond ((not m) conf)
          ((or (equal? (plist-get conf 'backend) "req-llm")
               (equal? (plist-get conf 'backend) "codex-app-server")
               (plist-get conf 'model-config))
           ;; direct, native, and session-config lanes carry the model in
           ;; protocol config, not adapter command-line wiring
           (append (list 'model m) conf))
          ((plist-get conf 'model-flag)
           ;; value must be quoted TOML — codex ignores the bare form
           (append (list 'model m
                         'cmd (string-append (plist-get conf 'cmd) " "
                                             (plist-get conf 'model-flag)
                                             "\"" m "\""))
                   conf))
          ((plist-get conf 'env) conf)           ; explicit env wins
          (else (append (list 'model m) conf (agent-model-env m))))))

(define (connector-names)
  (let loop ((cs *agent-connectors*) (acc '()))
    (if (null? cs)
        (reverse acc)
        (loop (cdr cs)
              (if (plist-get (car (cdr (car cs))) 'hidden)
                  acc
                  (cons (car (car cs)) acc))))))

(define (connector-description name)
  (let ((backend (or (plist-get (connector-config name) 'backend) "acp")))
    (cond ((equal? name "opencode")
           "OpenCode — multi-provider ACP agent")
          ((equal? name "deepseek")
           "DeepSeek Harness — session-cached DeepSeek models")
          ((equal? name "gemini-nano")
           "Chrome Gemini Nano — local browser inference")
          ((equal? backend "req-llm")
           "direct API — metered, cached, cheap lane")
          ((equal? backend "codex-app-server")
           "Codex App Server — ChatGPT subscription")
          (else
           "ACP agent — subscription or external adapter"))))

(define (agent-update-modeline! buf)
  ;; Chat buffers keep the bottom modeline free of LLM configuration.
  (buffer-set-local! buf 'modeline-preset #f)
  (buffer-set-local! buf 'modeline-info #f)
  (buffer-set-local! buf 'modeline-info-command #f))

;; the catalog the providers last reported, so a fresh session offers the
;; long list before anything is fetched
(when (file-exists? llm-catalog-file) (load llm-catalog-file))
