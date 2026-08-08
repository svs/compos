;;; mcp.scm --- MCP client policy: server registry, presets, chat wiring.
;;;
;;; Mechanism is Aimax.Core.MCP (stdio/http JSON-RPC, handshake, tool
;;; bridging); this file decides which servers exist, when to connect, and
;;; which chats see which tools. Bridged tools surface in the LLM loop as
;;; mcp__<server>__<tool> and dispatch in Elixir — never through the
;;; session — so a slow web fetch can't block a keystroke.
;;;
;;; (mcp-register! 'name SPEC) declares a server without connecting:
;;;   stdio: (list 'command "npx" 'args (list "-y" "pkg") 'env (list 'K "v"))
;;;   http:  (list 'url "https://host/mcp" 'headers (list 'authorization "..."))
;;; Env/header values starting with "@" resolve as key lookups
;;; ("@GOOGLE_API_KEY" -> env, ~/.aimax/google-key, doppler).
;;;
;;; (define-preset! 'name DESC SERVERS) names a collection; M-x
;;; chat-load-preset enables it in a chat. The choice lives in the chat's
;;; 'chat-presets buffer-local, so it persists across restarts with the
;;; chat itself; servers reconnect lazily on the next send.

(define *mcp-registry* '())

(define (mcp-register! name spec)
  (set! *mcp-registry*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *mcp-registry*)))
  name)

(define (mcp-connected? name)
  (member (symbol->string name) (map car (mcp-connections))))

;; connect a registered server unless it already is — safe to call every send
(define (mcp-ensure! name)
  (let ((e (assoc name *mcp-registry*)))
    (cond ((not e)
           (message (string-append "mcp: unknown server " (symbol->string name))))
          ((mcp-connected? name) #t)
          (else
            (message (string-append "mcp: connecting " (symbol->string name) "…"))
            (mcp-connect! (symbol->string name) (car (cdr e)))))))

;;; --- presets -----------------------------------------------------------------

(define *chat-presets* '())

(define (define-preset! name description servers)
  (set! *chat-presets*
    (cons (list name (list 'description description 'servers servers))
          (remove (lambda (e) (equal? (car e) name)) *chat-presets*)))
  name)

(define (preset-servers name)
  (let ((e (assoc name *chat-presets*)))
    (if e (custom--plist-get (car (cdr e)) 'servers) '())))

(define (chat-presets-of buf)
  (or (buffer-local buf 'chat-presets) '()))

(define (chat-active-servers buf)
  (fold (lambda (acc p)
          (fold (lambda (acc2 srv) (if (member srv acc2) acc2 (cons srv acc2)))
                acc (preset-servers p)))
        '() (chat-presets-of buf)))

;; the hook chat-llm-rich pulls at send time: specs are read fresh from
;; Elixir, so tools appear the moment a connecting server becomes ready
(define (chat-extra-tool-specs buf)
  (let ((servers (chat-active-servers buf)))
    (if (null? servers)
        '()
        (begin
          (for-each mcp-ensure! servers)
          (mcp-tool-specs (map symbol->string servers))))))

;; which chat does a preset command act on? the current buffer if it is a
;; chat, else the current buffer's group chat
(define (chat-preset-target)
  (let ((cur (current-buffer)))
    (cond ((chat-buffer? cur) cur)
          ((buffer-group cur) (group-chat (buffer-group cur)))
          (else #f))))

;; An ACP session's mcpServers are fixed at session/new, so changing a
;; preset under a live agent changes NOTHING until the session restarts —
;; a silent no-op reads as a broken feature. Mark the chat dirty, say so,
;; and let the next send reattach (the ordinary reconnect path: same
;; connector and model, transcript seeded, new server list). The api lane
;; needs none of this: its specs are read fresh at every send.
(define (chat-presets-changed! buf what)
  (let ((slug (buffer-local buf 'agent-slug)))
    (if (and slug
             (not (connector-api? (or (buffer-local buf 'agent-connector)
                                      *default-connector*)))
             (not (equal? (agent-status slug) 'dead)))
        (begin
          (buffer-set-local! buf 'chat-mcp-dirty #t)
          (minibuffer-read
            (string-append what " — the agent's tools are fixed for this "
                           "session. Reconnect now? ")
            '("yes" "no")
            (lambda (answer)
              (if (equal? answer "yes")
                  (begin
                    (chat-reattach-for-presets! buf)
                    (message (string-append what " — reconnected with the new tools")))
                  (message (string-append
                             what " — takes effect on the next send"))))))
        (message (string-append what " for " buf)))))

;; kill + attach the same connector/model: a fresh session with the new
;; server list, seeded from the transcript so the conversation continues
(define (chat-reattach-for-presets! buf)
  (let ((slug (buffer-local buf 'agent-slug))
        (cname (or (buffer-local buf 'agent-connector) *default-connector*))
        (model (or (buffer-local buf 'agent-model) "")))
    (buffer-set-local! buf 'chat-mcp-dirty #f)
    (agent-reconnect! slug cname model)))

;; the next send honours a pending preset change before prompting
(define (chat-apply-pending-presets! buf)
  (when (buffer-local buf 'chat-mcp-dirty)
    (chat-reattach-for-presets! buf)))

(define-command "chat-load-preset" "Enable a tool preset (MCP servers) in this chat"
  (lambda ()
    (let ((buf (chat-preset-target)))
      (if (not buf)
          (message "No chat here — open one with M-x chat first")
          (minibuffer-read "Load preset: "
            (map (lambda (e) (list (symbol->string (car e))
                                   (custom--plist-get (car (cdr e)) 'description)))
                 *chat-presets*)
            (lambda (name)
              (unless (equal? name "")
                (let ((p (string->symbol name)))
                  (unless (member p (chat-presets-of buf))
                    (buffer-set-local! buf 'chat-presets
                                       (cons p (chat-presets-of buf))))
                  (for-each mcp-ensure! (preset-servers p))
                  (chat-presets-changed! buf (string-append "Preset " name " on"))))))))))

(define-command "chat-unload-preset" "Disable a tool preset in this chat"
  (lambda ()
    (let ((buf (chat-preset-target)))
      (if (or (not buf) (null? (chat-presets-of buf)))
          (message "No presets loaded here")
          (minibuffer-read "Unload preset: "
            (map (lambda (p) (list (symbol->string p) "loaded")) (chat-presets-of buf))
            (lambda (name)
              (unless (equal? name "")
                (buffer-set-local! buf 'chat-presets
                  (remove (lambda (p) (equal? p (string->symbol name)))
                          (chat-presets-of buf)))
                (chat-presets-changed! buf (string-append "Preset " name " off")))))))))

(define-command "mcp-status" "Show MCP server connections"
  (lambda ()
    (let ((cs (mcp-connections)))
      (if (null? cs)
          (message "mcp: no connections")
          (message
            (fold (lambda (acc c)
                    (string-append acc (car c) " " (car (cdr c)) " ("
                                   (number->string (car (cdr (cdr c)))) " tools)  "))
                  "mcp: " cs))))))

(public! 'mcp-register! "(mcp-register! 'name SPEC) — declare an MCP server (stdio or http)")
(public! 'mcp-ensure! "(mcp-ensure! 'name) — connect a registered MCP server if needed")
(public! 'define-preset! "(define-preset! 'name DESC SERVERS) — name a loadable tool collection")
(public! 'mcp-connections "(mcp-connections) — (name status tool-count) per live MCP connection")

;; Which servers exist is user config, not core: declare them with
;; mcp-register!/define-preset! in ~/.aimax/ai-config.scm.

;;; --- ACP: agents get the same servers -----------------------------------------
;;; A registered stdio server translates to an ACP session/new mcpServers
;;; entry; the caller (an agent thread's config, a chat's presets) decides
;;; which servers each agent session sees. "@VAR" env values resolve
;;; Elixir-side at spawn — config files stay secret-free.

;; the editor itself as an MCP server: the define-tool! registry bridged
;; over the daemon socket, so external agents read and edit live buffers
(mcp-register! 'aimax
  (list 'command "elixir" 'args (list (priv-path "aimax-mcp-proxy.exs"))))

(define (mcp-acp-server name)
  (let* ((e (assoc name *mcp-registry*))
         (spec (and e (car (cdr e)))))
    (and spec (plist-get spec 'command)
         (list 'name (symbol->string name)
               'command (plist-get spec 'command)
               'args (or (plist-get spec 'args) '())
               'env (let loop ((es (or (plist-get spec 'env) '())) (acc '()))
                      (if (null? es)
                          (reverse acc)
                          (loop (cdr (cdr es))
                                (cons (list (symbol->string (car es))
                                            (car (cdr es)))
                                      acc))))))))

(define (mcp-acp-servers names)
  (filter (lambda (x) x) (map mcp-acp-server names)))

;; presets -> an agent session's server list: editor tools always, the
;; presets' servers on top
(define (presets-acp-servers presets)
  (mcp-acp-servers
    (cons 'aimax
          (fold (lambda (acc p)
                  (fold (lambda (a s) (if (member s a) a (cons s a)))
                        acc (preset-servers p)))
                '() presets))))
