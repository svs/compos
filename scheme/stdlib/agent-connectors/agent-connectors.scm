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
    ;; the model family it serves; the adapter lists only some of these
    ;; ids (no [1m] forms), and its list is the menu
    accepts "^(claude-|opus|sonnet|haiku|default)"
    install (("claude" "curl -fsSL https://claude.ai/install.sh | bash")
             ("claude-agent-acp" "npm install -g --no-audit --no-fund --prefer-offline @agentclientprotocol/claude-agent-acp"))
    signin "claude"
    ;; the compos tools load up front: deferred behind ToolSearch, apropos
    ;; and eval-scheme each cost a round before the first call
    default-env (("ENABLE_TOOL_SEARCH" "false"))
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
                                      "TaskList" "TaskGet"))))))

(define *codex-app-server-connector*
  '(backend "codex-app-server" cmd "codex app-server"
    description "Codex App Server — ChatGPT subscription"
    install (("codex" "npm install -g @openai/codex"))
    signin "codex login"
    accepts "^(gpt-|o[0-9])"))

(define-connector! "codex-app-server" *codex-app-server-connector*)

(define-connector! "codex" (append '(hidden #t) *codex-app-server-connector*))

(define-connector! "codex-acp"
  '(hidden #t deprecated "use codex-app-server"
    cmd "codex-acp" model-flag "-c model=" accepts "^(gpt-|o[0-9])"))

(define-connector! "opencode"
  '(cmd "opencode acp"
    description "OpenCode — multi-provider ACP agent"
    model-config #t
    ;; opencode drops _meta.systemPrompt: our sections ride the first turn
    system-in-prompt #t))

;; OpenCode Go is a subscription provider inside OpenCode, apart from the
;; pay-as-you-go `opencode/` models. Its own row lets Setup choose it: the
;; same agent, started on a Go model, taking only `opencode-go/` ids.
;; `opencode auth login` keeps its key in OpenCode's auth.json.
(define-connector! "opencode-go"
  '(cmd "opencode acp"
    title "OpenCode Go"
    description "OpenCode Go — the Go subscription's models through OpenCode"
    model-config #t
    model "opencode-go/deepseek-v4.1-flash"
    ;; opencode drops _meta.systemPrompt: our sections ride the first turn
    system-in-prompt #t
    accepts "^opencode-go/"
    signin "opencode auth login"))

;; Hermes Agent — the local agent harness. `hermes-acp` ships with it and
;; speaks ACP, so the editor drives it like any other agent: the Setup card
;; tests it with one turn, and its session reports model and reasoning
;; effort as config options. `hermes login` outside the editor is the whole
;; auth story; its models (today the zai family, by probe) arrive from the
;; session, not from here — so no accepts: a harness that serves several
;; providers serves everything its session lists.
(define-connector! "hermes"
  '(cmd "hermes-acp"
    title "Hermes Agent"
    description "Hermes Agent — the local agent harness, over ACP"
    model-config #t
    signin "hermes login"))

(define-connector! "antigravity"
  ;; Antigravity CLI (`agy`) ships its own ACP server. The session reports
  ;; Model and Thinking level as config options, so the model rides in
  ;; protocol config. --process-per-session is what lets it reach the
  ;; editor's HTTP MCP server. It offers third-party (Claude) models only
  ;; to the clients it names, so this lane serves Gemini.
  ;; The editor names every tool through MCP and writes the whole prompt:
  ;; --agent compos runs ~/.gemini/config/agents/compos.md, whose frontmatter
  ;; grants no built-in tool (tools: [], commandExecutionPolicy: off) and
  ;; whose body replaces Antigravity's system prompt with one line pointing
  ;; at ours. --include-default-customizations=false drops the default
  ;; skills and rules.
  '(cmd "agy acp --process-per-session --agent compos --include-default-customizations=false"
    title "Antigravity"
    description "Antigravity CLI — Gemini models on your Google AI plan"
    model-config #t
    model "gemini-4-neon-medium"
    ;; whether agy reads _meta.systemPrompt is unknown: our sections ride
    ;; the first turn
    system-in-prompt #t
    ;; agy hands Gemini a numeric enum as empty strings (Fireflies'
    ;; expiryDays: 7, 14, 30) and Gemini refuses the whole request, so this
    ;; lane holds the editor's server alone; the rest stay one mcp-find away
    mcp-presets (compos)
    install (("agy" "curl -fsSL https://antigravity.google/cli/install.sh | bash"))
    signin "agy"))

;; The agent the antigravity lane runs. Written when missing, so a fresh
;; machine gets it; an edited copy stays the user's.
(define antigravity-agent-file
  (string-append (getenv "HOME") "/.gemini/config/agents/compos.md"))

(define antigravity-agent-text
  "---
name: compos
description: The compos editor's agent. Every tool comes from the editor's MCP server; the editor writes the instructions.
tools: []
mainAgent: true
subagent: false
commandExecutionPolicy: off
---

# System Prompt
You are the assistant inside the compos editor. The editor's instructions arrive at the head of the first message; follow them. Act only through the tools the editor's MCP server gives you.
")

(define (antigravity-agent-ensure!)
  (unless (file-exists? antigravity-agent-file)
    (make-directory! (string-append (getenv "HOME") "/.gemini/config/agents"))
    (write-file! antigravity-agent-file antigravity-agent-text)))

(antigravity-agent-ensure!)

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
    description "DeepSeek Harness — session-cached DeepSeek models"
    ;; the session reports model and reasoning effort as ACP config
    ;; options, so the model rides in protocol config, not the command line
    model-config #t
    ;; the harness drops _meta, so our prompt sections ride the first turn
    system-in-prompt #t
    ;; the thread runs in an editor-owned DSH_HOME (skills.scm), which
    ;; carries the profile patch that turns the harness's own tools and
    ;; prompt off
    sanitize "dsh"
    accepts "^deepseek-"))

;; The direct lane needs one key from any provider. Each provider's key is a
;; secret setting; 'provider makes llm-key answer from it, and 'model is the
;; model a first run picks with it.
(defcustom 'openrouter-api-key #f
  "OpenRouter: one key for every model."
  'type 'secret 'group 'llm 'env "OPENROUTER_API_KEY" 'provider "openrouter"
  'model "openrouter:anthropic/claude-sonnet-5"
  'key-page "https://openrouter.ai/settings/keys")

(defcustom 'anthropic-api-key #f
  "Anthropic: Claude models."
  'type 'secret 'group 'llm 'env "ANTHROPIC_API_KEY" 'provider "anthropic"
  'model "claude-sonnet-5"
  'key-page "https://console.anthropic.com/settings/keys")

(defcustom 'openai-api-key #f
  "OpenAI: GPT models."
  'type 'secret 'group 'llm 'env "OPENAI_API_KEY" 'provider "openai"
  'model "openai:gpt-5.6-luna"
  'key-page "https://platform.openai.com/api-keys")

;; Every connector above reports its models when a session starts, and
;; connector-models answers from that. These two report nothing, so they
;; declare their own.
(define-connector! "api"
  (list 'backend "req-llm"
        'title "Hosted model (your API key)"
        'description "direct API — metered, cached, cheap lane"
        ;; User choices stay first as favorites; ReqLLM contributes every
        ;; chat model whose provider is configured on this machine, and the
        ;; live catalog contributes what the providers shipped since the
        ;; snapshot was cut.
        'models (lambda () (llm-catalogued-models))))

(define-connector! "gemini-nano"
  '(backend "chrome-gemini-nano" models ("gemini-nano")
    description "Chrome Gemini Nano — local browser inference"))

;; one package per connector: each declares its command, install steps,
;; sign-in and secrets with define-connector!. A connector loads after
;; this file and registers itself; this file names none of them.

(define (connector-capabilities name)
  (backend-capabilities (or (plist-get (connector-config name) 'backend) "acp")))

(define (connector-can? name cap)
  (and (member cap (connector-capabilities name)) #t))

(define (connector-models name)
  "The models connector NAME runs: the list its agent reported (a session
   reports it at start, and llm-models-seen! keeps it). A connector whose
   backend reports nothing (gemini-nano, the catalogued api lane) declares
   its own, and a declared list also stands in until the first report."
  (let ((reported (if (boundp 'llm-models-remembered)
                      (map car (llm-models-remembered name))
                      '())))
    (if (pair? reported)
        reported
        (let ((m (plist-get (connector-config name) 'models)))
          (cond ((procedure? m) (m)) (m m) (else '()))))))

;; #t when connector NAME runs model M: its agent lists it, or it matches the
;; model family the connector declares as 'accepts. The list ages with every
;; release; the family does not.
(define (connector-accepts? name m)
  (and m
       (or (and (member m (connector-models name)) #t)
           (let ((re (plist-get (connector-config name) 'accepts)))
             (and re (re-match? re m) #t)))))

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
    ;; fresh at every send. A connector that declares 'mcp-presets gets those
    ;; presets whatever the chat's are: an adapter that chokes on some
    ;; server's schemas holds only the servers it can take.
    (if (or (equal? (plist-get conf 'backend) "req-llm")
            (plist-get conf 'mcp-servers)
            (not (boundp (quote presets-acp-servers))))
        conf
        (agent-config-with-system-parts
          (append conf
            (list 'mcp-servers
                  (presets-acp-servers (or (plist-get conf 'mcp-presets)
                                           (plist-get conf 'presets)
                                           '()))))))))

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
        (plist-put conf 'meta
                   (plist-put meta 'systemPrompt
                              (list 'append (agent-system-text had text)))))))

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
        (if (boundp (quote preset-prompt-parts))
            (preset-prompt-parts (plist-get conf 'presets))
            '())
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
  (agent-config-wrap-system
    (fold (lambda (out part) (agent-config-append-system out (car (cdr part))))
          conf (agent-system-prompt-parts conf))))

;; a 'system-in-prompt adapter reads the sections at the head of the first
;; user message (acp.ex prepends them once). The tags are the boundary:
;; without them the model reads our sections and the user's first words as
;; one question.
(define (agent-config-wrap-system conf)
  (let ((s (plist-get conf 'system)))
    (if (and (string? s) (not (equal? s "")))
        (plist-put conf 'system (string-append "<system>\n" s "\n</system>\n\n"))
        conf)))

;; A Codex thread starts with one instruction text (codex_app_server.ex):
;; the sections the ACP lane sends as _meta.systemPrompt.append, the chat's
;; system text and the runtime model id, each once; and the approval policy.
(define (codex-thread-fields meta system model mode)
  "(codex-thread-fields META SYSTEM MODEL MODE) - (APPROVAL-POLICY INSTRUCTIONS-OR-#f) for a Codex thread"
  (let* ((sp (and (list? meta) (plist-get meta 'systemPrompt)))
         (base (and (list? sp) (plist-get sp 'append)))
         (identity (and (string? model)
                        (string-append "Your exact runtime model ID is " (json-encode model)
                                       ". When asked which model you are, "
                                       "report that exact ID; do not replace it with a generic Codex or GPT family name.")))
         (parts (fold (lambda (acc s)
                        (if (and (string? s) (not (equal? (string-trim s) "")) (not (member s acc)))
                            (append acc (list s))
                            acc))
                      '() (list base system identity))))
    (list (if (equal? mode "auto") "never" "on-request")
          (if (null? parts) #f (string-join parts "\n\n")))))

(domain! 'chat)

(effects! '(read))

(public! 'agent-live-system-prompt-parts
  "(agent-live-system-prompt-parts CONF) — current ACP prompt sections before the conversation freeze")
(public! 'agent-live-system-prompt-source-parts
  "(agent-live-system-prompt-source-parts CONF) — unfiltered ACP prompt fragments")

(effects! '(pure))

(public! 'codex-thread-fields
  "(codex-thread-fields META SYSTEM MODEL MODE) - (APPROVAL-POLICY INSTRUCTIONS-OR-#f) for a Codex thread")

(effects! '(write))

(public! 'agent-system-prompt-parts
  "(agent-system-prompt-parts CONF) — named ACP system-prompt sections in session-start order")

;; the buffer's own working directory, offered as a cwd for the thread it
;; attaches: a chat answers with its 'chat-directory (buffer-directory follows
;; that local), any other buffer with the directory it belongs to.
(define (agent-config-buffer-cwd opts)
  ;; a chat carried from another machine keeps that machine's directory;
  ;; a process cannot start there, so a missing directory falls back to
  ;; the group's, else the home directory
  (let ((buf (plist-get opts 'buffer)))
    (if (and (string? buf) (buffer-exists? buf))
        (let* ((dir (buffer-directory buf))
               (g (buffer-group buf))
               (gdir (and g (group-cwd g))))
          (list 'cwd (cond ((and (string? dir) (file-directory? dir)) dir)
                           ((and (string? gdir) (file-directory? gdir)) gdir)
                           (else (getenv "HOME")))))
        '())))

;; an env value that is a symbol names a secret setting (keys.scm) or a
;; global the user's config sets; it is read when the thread starts, and a
;; pair whose value is unset drops out
(define (agent-env-resolve env)
  (let loop ((ps env) (acc '()))
    (if (null? ps)
        (reverse acc)
        (let* ((v (car (cdr (car ps))))
               (v (cond ((not (symbol? v)) v)
                        ((secret-setting? v) (secret-value v))
                        (else (and (boundp v) (symbol-value v))))))
          (loop (cdr ps) (if (string? v) (cons (list (car (car ps)) v) acc) acc))))))

(define (agent-config-env-resolve conf)
  (let ((env (plist-get conf 'env)))
    (if env (append (list 'env (agent-env-resolve env)) conf) conf)))

;; the chat's own adapter environment ('agent-env, from its preset) joins
;; the connector's: a name the connector or the model env sets wins
(define (agent-config-buffer-env conf opts)
  (let* ((buf (plist-get opts 'buffer))
         (extra (and (string? buf) (buffer-exists? buf) (buffer-local-value 'agent-env buf))))
    (if (pair? extra)
        (let ((env (or (plist-get conf 'env) '())))
          (append (list 'env (append env (filter (lambda (p) (not (assoc (car p) env))) extra)))
                  conf))
        conf)))

(define (agent-config-default-env conf)
  ;; a connector's default-env fills only the keys nobody else set
  (let ((defaults (plist-get conf 'default-env)))
    (if (pair? defaults)
        (let ((env (or (plist-get conf 'env) '())))
          (append (list 'env (append env (filter (lambda (p) (not (assoc (car p) env)))
                                                 defaults)))
                  conf))
        conf)))

(define (agent-resolve-config* opts)
  (agent-config-env-resolve
   (agent-config-default-env
   (agent-config-buffer-env
   (let* ((cname (or (plist-get opts 'connector) *default-connector*))
          ;; A thread works where its buffer works. The ACP and Codex lanes are
          ;; told their cwd once, at session/new, and until now nobody told them
          ;; at all: every session ran in the daemon's own directory. This says
          ;; it LAST, so an explicit 'cwd in the attach opts (an isolated
          ;; worktree) and a connector's own declared cwd both still win.
          (conf (append opts (connector-config cname) (agent-config-buffer-cwd opts)))
          (m (or (plist-get conf 'model)
                 (and (connector-accepts? cname (llm-model)) (llm-model)))))
     (cond ((not m) conf)
           ((or (equal? (plist-get conf 'backend) "req-llm")
                (equal? (plist-get conf 'backend) "codex-app-server")
                (plist-get conf 'model-config))
            ;; direct, native, and session-config lanes carry the model in
            ;; protocol config, not adapter command-line wiring
            (append (list 'model m) conf))
           ((plist-get conf 'model-flag)
            ;; codex wants quoted TOML and ignores the bare form; a plain
            ;; argv flag (gemini -m) declares model-bare, or the quotes
            ;; become part of the model id
            (let ((q (if (plist-get conf 'model-bare) "" "\"")))
              (append (list 'model m
                            'cmd (string-append (plist-get conf 'cmd) " "
                                                (plist-get conf 'model-flag)
                                                q m q))
                      conf)))
           ((plist-get conf 'env) conf)           ; explicit env wins
           (else (append (list 'model m) conf (agent-model-env m)))))
   opts))))

(define (connector-names)
  (let loop ((cs *agent-connectors*) (acc '()))
    (if (null? cs)
        (reverse acc)
        (loop (cdr cs)
              (if (plist-get (car (cdr (car cs))) 'hidden)
                  acc
                  (cons (car (car cs)) acc))))))

(effects! '(read))
(public! 'connector-names
  "(connector-names) — the names of the connectors that are not hidden")
(public! 'connector-config
  "(connector-config NAME) — the config plist of connector NAME, with its command override")

;; Resolving a config can create the sanitized codex/dsh homes and turn off
;; codex skills in the thread's cwd, so it writes.
(effects! '(write))
(public! 'agent-resolve-config
  "(agent-resolve-config OPTS) — the full config a chat thread starts with: connector, model, env, MCP servers and system parts")
(effects! '(write))

(define (connector-description name)
  (let ((config (connector-config name)))
    (or (plist-get config 'description)
        "ACP agent — subscription or external adapter")))

(define (agent-update-modeline! buf)
  ;; Chat buffers keep the bottom modeline free of LLM configuration.
  (buffer-set-local! buf 'modeline-preset #f)
  (buffer-set-local! buf 'modeline-info #f)
  (buffer-set-local! buf 'modeline-info-command #f)
  ;; the model, lane and preset facts are drawn once and kept; a model the
  ;; adapter reports after a reattach must redraw them, or the window keeps
  ;; the default model it drew before the session knew its own
  (when (boundp 'dashboard--sync!) (dashboard--sync! buf)))

;;; Catalog stamps for the names the docs and skills teach (the effects audit of 2026-11-26).
(domain! 'chat)
(effects! '(read))
(public! 'agent-config-with-system-parts "(agent-config-with-system-parts CONF) — CONF with the system prompt parts filled in")
