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

(define (define-connector! name config)
  (set! *agent-connectors*
    (cons (list name config)
          (let loop ((cs *agent-connectors*) (acc '()))
            (cond ((null? cs) (reverse acc))
                  ((equal? (car (car cs)) name) (loop (cdr cs) acc))
                  (else (loop (cdr cs) (cons (car cs) acc))))))))

(define (connector-config name)
  (let ((e (assoc name *agent-connectors*)))
    (if e (car (cdr e)) '())))

(define-connector! "claude-code"
  ;; npm's @zed-industries/claude-code-acp lags upstream (pins an old
  ;; claude-agent-sdk with a stale model catalog: no Sonnet 5/Opus 5/Fable,
  ;; no pricing) — bare "claude-code-acp" resolves the stale global npm
  ;; install via PATH, so point at a from-source build instead:
  ;; ~/src/claude-code-acp, `npm run build` with node >=22.
  '(cmd "/Users/svs/.asdf/installs/nodejs/24.0.2/bin/node /Users/svs/src/claude-code-acp/dist/index.js"
    meta (claudeCode (options (settingSources () strictMcpConfig #t)))
    models ("claude-sonnet-5" "claude-opus-5" "claude-haiku-4-5-20251001")))

(define *codex-app-server-connector*
  '(backend "codex-app-server" cmd "codex app-server"
    models ("gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna" "gpt-5.5"
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
            "opencode/claude-opus-5" "opencode/claude-haiku-4-5"
            "opencode/gemini-3.1-pro")))

(define-connector! "api"
  (list 'backend "req-llm"
        ;; User choices stay first as favorites; ReqLLM contributes every
        ;; chat model whose provider is actually configured on this machine.
        'models (lambda ()
                  (fold (lambda (acc m)
                          (if (member m acc) acc (append acc (list m))))
                        *llm-models* (llm-available-models)))))

(define-connector! "gemini-nano"
  '(backend "chrome-gemini-nano" models ("gemini-nano")))

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
         (conf (if (and codex? (boundp (quote codex-config-with-env)))
                   (codex-config-with-env conf0)
                   conf0)))
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

(define (agent-config-with-primer conf)
  (let ((primer (if (boundp (quote hello)) (hello) "")))
    (if (equal? primer "")
        conf
        (agent-config-append-system conf primer))))

(define (agent-config-append-system conf text)
  (let* ((meta (or (plist-get conf 'meta) '()))
         (sp (or (plist-get meta 'systemPrompt) '()))
         (had (or (plist-get sp 'append) "")))
    (append (list 'meta (append (list 'systemPrompt
                                      (list 'append (if (equal? had "")
                                                        text
                                                        (string-append had "\n\n" text))))
                                meta))
            conf)))

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

(define (agent-live-system-prompt-parts conf)
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
        mode-parts))))

(define (agent-system-prompt-parts conf)
  (let* ((buf (plist-get conf 'buffer))
         (live (agent-live-system-prompt-parts conf)))
    (if (and buf (boundp (quote chat-prompt-snapshot-parts)))
        (chat-prompt-snapshot-parts buf 'acp live)
        live)))

(define (agent-config-with-system-parts conf)
  (fold (lambda (out part) (agent-config-append-system out (car (cdr part))))
        conf (agent-system-prompt-parts conf)))

(domain! 'chat)

(effects! '(read))

(public! 'agent-live-system-prompt-parts
  "(agent-live-system-prompt-parts CONF) — current ACP fragments before the conversation freeze")

(effects! '(write))

(public! 'agent-system-prompt-parts
  "(agent-system-prompt-parts CONF) — named ACP system-prompt fragments in session-start order")

(define (agent-resolve-config* opts)
  (let* ((cname (or (plist-get opts 'connector) *default-connector*))
         (conf (append opts (connector-config cname)))
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
          ((equal? name "gemini-nano")
           "Chrome Gemini Nano — local browser inference")
          ((equal? backend "req-llm")
           "direct API — metered, cached, cheap lane")
          ((equal? backend "codex-app-server")
           "Codex App Server — ChatGPT subscription")
          (else
           "ACP agent — subscription or external adapter"))))

(define (agent-conf-model conf)
  (or (plist-get conf 'model)
      (let loop ((es (or (plist-get conf 'env) '())))
        (cond ((null? es) #f)
              ((equal? (car (car es)) "ANTHROPIC_MODEL") (car (cdr (car es))))
              (else (loop (cdr es)))))))

(define (agent-update-modeline! buf)
  (let* ((c (or (buffer-local buf 'agent-connector) *default-connector*))
         ;; never name a model this connector can't run: a pinned id left
         ;; over from another backend (an ACP "default" sentinel, say) is
         ;; about to be dropped at send time anyway
         (pinned (let ((m (buffer-local buf 'agent-model)))
                   (and m (not (agent-model-foreign? buf c m)) m)))
         (m (or pinned (and (connector-can? c 'stateless) (llm-model))))
         (cost (and (connector-can? c 'metered) (buffer-local buf 'chat-cost))))
    (buffer-set-local! buf 'modeline-info
      (string-append
        c
        (if (and m (not (equal? m ""))) (string-append " · " m) "")
        (let ((effort (buffer-local buf 'agent-effort)))
          (if effort (string-append " · " effort) ""))
        (if cost (string-append " · " (format-usd cost)) "")
        ;; what will and won't stop to ask — never leave this ambiguous
        " · " (symbol->string (chat-permission-mode buf))
        ;; the agent's own mode, when it is running something other than
        ;; its default (plan mode especially changes what a turn DOES)
        (let ((am (buffer-local buf 'agent-mode)))
          (if (and am (not (equal? am "default"))) (string-append " · " am) ""))
        ;; the editor has tools this chat froze out. Say so: adopting them
        ;; (C-c t) costs a cache miss, so it is the user's call, not ours.
        (if (and (boundp (quote chat-tools-stale?)) (chat-tools-stale? buf))
            " · tools stale"
            "")))
    ;; the segment is clickable: ui-command! runs this on a click
    (buffer-set-local! buf 'modeline-info-command "agent-switch")))
