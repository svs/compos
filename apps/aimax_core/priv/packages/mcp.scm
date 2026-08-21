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
;;; A "@VAR" in 'env, 'headers or 'url is a key reference, resolved by
;;; packages/keys.scm here in Scheme, just before the spec leaves for
;;; Elixir. The connection layer sees only literal values: it never learns
;;; what a secret is or where this machine keeps one. A value that is only
;;; PART secret takes a list of parts:
;;;   'headers (list 'Authorization (list "Bearer " "@ATS_ASH_TOKEN"))
;;;
;;; (define-preset! 'name DESC SERVERS) names a collection; M-x
;;; llm-set-preset enables it for an LLM session. The choice currently lives
;;; in the persisted 'chat-presets buffer-local, so it persists with the
;;; session itself; servers reconnect lazily on the next send. M-x
;;; chat-tool-list shows the tools the chat's model holds, and
;;; chat-tool-surface the servers behind them.

(define *mcp-registry* '())

(define (mcp-register! name spec)
  (set! *mcp-registry*
    (cons (list name spec)
          (remove (lambda (e) (equal? (car e) name)) *mcp-registry*)))
  name)

(define (mcp-connected? name)
  (member (symbol->string name) (map car (mcp-connections))))

;; a spec with its "@VAR" references replaced by the keys they name. The
;; registry keeps the references, so a secret lives in the registry for no
;; longer than one connect. This is the ONE place a spec resolves —
;; resolving twice would re-read a secret whose own text starts with "@".
;;
;; 'url resolves too: some servers take the key as a query parameter
;; (mcp.exa.ai/mcp?exaApiKey=…) and refusing to resolve there only moved
;; the secret back into the config file. A url that carries a key must
;; never print — mcp-url-shown cuts the query string off every display.
(define (mcp-resolve-spec spec)
  (if (or (null? spec) (null? (cdr spec)))
      '()
      (let ((k (car spec)) (v (cadr spec)))
        (cons k
              (cons (cond ((or (equal? k 'env) (equal? k 'headers))
                           (key-resolve-plist v))
                          ((equal? k 'url) (key-resolve v))
                          (else v))
                    (mcp-resolve-spec (cddr spec)))))))

;; a url without its query string. Every line that shows a url goes on a
;; screen or into a chat buffer, and a key can ride in the query.
(define (mcp-url-shown u)
  (let ((i (string-index u "?")))
    (if i (string-append (substring-bytes u 0 i) "?…") u)))

;; connect a registered server unless it already is — safe to call every send
(define (mcp-ensure! name)
  (let ((e (assoc name *mcp-registry*)))
    (cond ((not e)
           (message (string-append "mcp: unknown server " (symbol->string name))))
          ((mcp-connected? name) #t)
          (else
            (message (string-append "mcp: connecting " (symbol->string name) "…"))
            (mcp-connect! (symbol->string name)
                          (mcp-resolve-spec (car (cdr e))))))))

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
  ;; The editor bridge is infrastructure, not an optional integration.  Every
  ;; LLM surface receives eval-scheme/apropos/act even when an old restored
  ;; chat has no preset local (or explicitly stored the empty list).  Other
  ;; presets remain buffer-local and user-selectable.
  (let ((presets (or (buffer-local buf 'chat-presets) '())))
    (if (member 'aimax presets) presets (cons 'aimax presets))))

(define (chat-active-servers buf)
  (fold (lambda (acc p)
          (fold (lambda (acc2 srv) (if (member srv acc2) acc2 (cons srv acc2)))
                acc (preset-servers p)))
        '() (chat-presets-of buf)))

;; The intrinsic `aimax` surface already lives in this process. ACP receives
;; its MCP proxy; the API lane mounts the same registry natively and sends
;; only the remaining, optional servers through the MCP client.
(define (chat-remote-servers buf)
  (remove (lambda (s) (equal? s 'aimax)) (chat-active-servers buf)))

(define (chat-aimax-tools? buf)
  (and (member 'aimax (chat-active-servers buf)) #t))

;; the hook chat-llm-rich pulls at send time: specs are read fresh from
;; Elixir, so tools appear the moment a connecting server becomes ready
(define (chat-extra-tool-specs buf)
  (let ((servers (chat-remote-servers buf)))
    (append
      (if (and (chat-aimax-tools? buf) (boundp (quote llm-tool-specs)))
          (llm-tool-specs)
          '())
      (if (null? servers)
          '()
          (begin
            (for-each mcp-ensure! servers)
            (mcp-tool-specs (map symbol->string servers)))))))

(define (chat-tool-system buf)
  (let* ((aimax? (chat-aimax-tools? buf))
         (note (mcp-system-note (chat-remote-servers buf)))
         (base (cond ((and aimax? (not (equal? note "")))
                      (string-append *llm-system* "\n\n" note))
                     (aimax? *llm-system*)
                     (else note)))
         ;; the skill index (packages/skills.scm, loads after this file)
         ;; rides here — the one system-prompt carrier every lane shares.
         ;; Only a chat that holds eval-scheme can load a skill.
         (sk (if (and aimax? (boundp (quote skills-note))) (skills-note) "")))
    (if (equal? sk "") base (string-append base "\n\n" sk))))

;; Which LLM surface does a preset command act on? The shared LLM session
;; layer owns this configuration; chat-mode and inline llm-mode are its UIs.
(define (llm-preset-target)
  (let ((cur (current-buffer)))
    (cond ((or (chat-buffer? cur) (minor-mode-on? cur "llm-mode")) cur)
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
             (not (connector-can? (or (buffer-local buf 'agent-connector)
                                      *default-connector*)
                                  'stateless))
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
        (begin
          ;; Direct API chats freeze their tool specs for prompt-cache
          ;; stability. Selecting a preset is the user's explicit request to
          ;; change that surface, so make it effective on the very next turn.
          ;; Plain llm-mode buffers have no frozen list and already read live.
          (when (and (boundp (quote chat-adopt-live-tools!))
                     (buffer-local buf 'chat-tool-specs))
            (chat-adopt-live-tools! buf))
          ;; A stateful llm-mode runtime mounted its MCP servers when the
          ;; native thread attached. Drop only the process; the next M-o
          ;; resumes the same Codex thread with the changed preset surface.
          (when (and (minor-mode-on? buf "llm-mode")
                     (boundp (quote llm-mode-reset-runtime!)))
            (llm-mode-reset-runtime! buf #t))
          (message (string-append what " for " buf))))))

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

;;; One preset switch for every UI. The M-x commands and the C-c b menu
;;; change the same buffer-local, start the same servers, and report the
;;; change the same way. A second copy of this logic is how one UI keeps a
;;; live agent and the other silently does not.

;; Every registered preset, each marked with its state in THIS session.
;; The glyphs are the MCP hub's: ● is on, ○ is off.
(define (chat-preset-candidates buf)
  (let ((loaded (chat-presets-of buf)))
    (map (lambda (e)
           (let ((name (car e)))
             (list (symbol->string name)
                   (string-append (if (member name loaded) "● " "○ ")
                                  (custom--plist-get (car (cdr e)) 'description)))))
         *chat-presets*)))

(define (chat-preset-on! buf name)
  (unless (member name (chat-presets-of buf))
    (buffer-set-local! buf 'chat-presets (cons name (chat-presets-of buf))))
  (for-each mcp-ensure! (preset-servers name))
  (chat-presets-changed! buf (string-append "Preset " (symbol->string name) " on"))
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf)))

;; The editor bridge is infrastructure: chat-presets-of adds `aimax` back
;; to every surface. Removing it would report a change that does not
;; happen, so say why instead.
(define (chat-preset-off! buf name)
  (if (equal? name 'aimax)
      (message "The aimax preset is the editor bridge — it stays on")
      (begin
        (buffer-set-local! buf 'chat-presets
          (remove (lambda (p) (equal? p name)) (chat-presets-of buf)))
        (chat-presets-changed! buf (string-append "Preset " (symbol->string name) " off"))
        (when (boundp (quote workspace-llm-defaults-note!))
          (workspace-llm-defaults-note! buf)))))

(define (chat-preset-toggle! buf name)
  (if (member name (chat-presets-of buf))
      (chat-preset-off! buf name)
      (chat-preset-on! buf name)))

(define-command "llm-set-preset" "Enable a tool preset (MCP servers) for this LLM session"
  (lambda ()
    (let ((buf (llm-preset-target)))
      (if (not buf)
          (message "No LLM session here — enable llm-mode first")
          (minibuffer-read "Set LLM preset: " (chat-preset-candidates buf)
            (lambda (name)
              (unless (equal? name "")
                (chat-preset-on! buf (string->symbol name)))))))))

(define-command "llm-unset-preset" "Disable a tool preset for this LLM session"
  (lambda ()
    (let ((buf (llm-preset-target)))
      (if (or (not buf) (null? (chat-presets-of buf)))
          (message "No presets loaded here")
          (minibuffer-read "Unload preset: "
            (map (lambda (p) (list (symbol->string p) "loaded")) (chat-presets-of buf))
            (lambda (name)
              (unless (equal? name "")
                (chat-preset-off! buf (string->symbol name)))))))))

;;; --- calling a tool -----------------------------------------------------------
;;; The chat tool loop calls MCP tools on its own, off this process. Every
;;; other caller — a command, a hook, an agent through the aimax proxy —
;;; calls them here. mcp-call! connects the server first and waits for the
;;; handshake, because a caller that names a server means to use it.
;;;
;;;   (mcp-call! 'ats-ash "whoami" "{}")       waits, returns the text
;;;   (mcp-call! 'ats-ash "whoami" '() CB)     returns now, CB gets the text
;;;   (mcp-call! 'ats-ash "whoami" '() 5000)   waits 5 seconds, then fails
;;;
;;; ARGS is a JSON string or a plist ('(limit 5)). The fourth argument is a
;;; (lambda (ok text) ...) callback or a timeout in milliseconds. The
;;; waiting form stops the editor until the server answers, up to 25
;;; seconds — interactive code passes a callback instead.

;; 'aimax is this editor served back to itself: the proxy answers
;; tools/list by calling the session over the socket, so a caller that
;; waits for its handshake INSIDE the session waits for itself. Nobody
;; needs to — a caller running Scheme already holds every tool that proxy
;; serves.
(define (mcp-self? name) (equal? name 'aimax))

(define (mcp-call! name tool args &optional cb)
  (if (mcp-self? name)
      (begin (message "mcp: aimax is this editor — call its functions directly") #f)
      (begin
        (mcp-ensure! name)
        (if cb
            (mcp-tool-call (symbol->string name) tool args cb)
            (mcp-tool-call (symbol->string name) tool args)))))

;; What a server serves, whether or not this chat can see it: (NAME
;; DESCRIPTION) per tool. It connects the server and waits, like mcp-call!:
;; a registered server that nobody called yet serves an empty list, and
;; that reads as an answer instead of as "not connected yet".
(define (mcp-tools name)
  (if (mcp-self? name)
      '()
      (begin
        (mcp-ensure! name)
        (mcp-await-ready (symbol->string name))
        (let ((d (mcp-server-detail (symbol->string name))))
          (if d (plist-get d 'tools) '())))))

;; ...and the arguments one tool takes, as its JSON schema. Without this a
;; model knows a tool's name and guesses its parameters; it went looking
;; for the schema in describe-function, which documents Scheme and knows
;; nothing about the server. mcp-tools/mcp-tool-schema are to a server what
;; apropos/describe-function are to the editor.
(define (mcp-tool-schema name tool)
  (unless (mcp-self? name)
    (mcp-ensure! name)
    (mcp-await-ready (symbol->string name)))
  (let* ((server (symbol->string name))
         (prefix (string-append "mcp__" server "__"))
         (n (string-length prefix)))
    (let loop ((ss (mcp-tool-specs (list server))))
      (cond ((null? ss) "")
            ((equal? (substring (car (car ss)) n (string-length (car (car ss)))) tool)
             (car (cdr (cdr (car ss)))))
            (else (loop (cdr ss)))))))

;; The note every tool-using model gets. A model knows only the tools it
;; holds: an assistant asked to "run whoami on ats-ash" read the name as a
;; hostname and reached for ssh, because nothing said the name belongs to
;; an MCP server. The browser paragraph in *llm-system* exists for the same
;; reason.
;; Search every registered server's tools by name and description. This is
;; apropos for MCP: the prompt carries the server names and this verb,
;; nothing more, and the model pulls the one tool it needs. Injecting 66
;; tool schemas into every send buys the same knowledge for tens of
;; thousands of tokens a turn.
;;
;; PATTERN is words separated by "|", matched case-insensitively against
;; the tool name and its description. Searching connects each registered
;; server, which is the point: the model asked.
(define (mcp-find pattern &optional server)
  (let ((words (map string-downcase (string-split (string-downcase pattern) "|")))
        (names (filter (lambda (n) (not (mcp-self? n)))
                       (if server
                           (list server)
                           (map car (reverse *mcp-registry*))))))
    (fold (lambda (acc name) (append acc (mcp-find-in name words))) '() names)))

;; a search waits less than a call does: one server that will never answer
;; must not hold the search for the full call budget
(define *mcp-find-wait* 5000)

(define (mcp-find-in name words)
  (let ((server (symbol->string name)))
    (mcp-ensure! name)
    (mcp-await-ready server *mcp-find-wait*)
    (let ((d (mcp-server-detail server)))
      (if (not d)
          '()
          (filter (lambda (row) (mcp-find-hit? row words))
                  (map (lambda (t) (cons server t)) (plist-get d 'tools)))))))

(define (mcp-find-hit? row words)
  (let ((hay (string-downcase (string-append (car (cdr row)) " "
                                             (car (cdr (cdr row)))))))
    (let loop ((ws words))
      (cond ((null? ws) #f)
            ((string-contains? hay (car ws)) #t)
            (else (loop (cdr ws)))))))

;; SERVERS is the list this chat actually holds — its presets' servers,
;; not the editor's whole registry. Advertising a server the chat's tool
;; gate does not hold is worse than silence: the agent believes it has
;; tools it cannot call, and goes looking for the host by ssh.
(define (mcp-system-note servers)
  (let ((names (map symbol->string servers)))
    (if (null? names)
        ""
        (string-append
          "MCP servers registered in this editor: " (string-join names ", ")
          ". A name in that list is a server, not a host — never ssh to one, "
          "and never run a shell command to reach one. For ai-max editor, "
          "mail, and browser work, always use the aimax MCP tools rather "
          "than a shell or host CLI; shell execution is intentionally "
          "disabled in this environment. Tools named mcp__SERVER__TOOL are "
          "already yours to call directly. Reuse editor APIs already named "
          "in the primer or an earlier result. For an unfamiliar operation, "
          "call the aimax apropos tool once, then run the best hit's use "
          "expression with eval-scheme; do not repeat an equivalent search "
          "after a usable hit. A server "
          "whose tools you do not hold is three eval-scheme calls away, and "
          "nothing else in the editor API knows anything about it: "
          "(mcp-find \"words|more words\") searches every server's tools by "
          "name and description and returns (SERVER TOOL DESCRIPTION) — "
          "start here, the way you start with apropos for the editor; "
          "(mcp-tool-schema 'SERVER \"TOOL\") gives that tool's JSON "
          "argument schema, which you read before calling and never guess; "
          "(mcp-call! 'SERVER \"TOOL\" \"JSON\") calls it and returns the "
          "text. describe-function and apropos document Scheme only."))))

;; the hub IS the status display — one line of echo area was a second,
;; worse rendering of the same thing
(define-command "mcp-status" "Show MCP server connections"
  (lambda () (run-command "mcp-hub")))

(category! 'mcp)
(public! 'mcp-register! "(mcp-register! 'name SPEC) — declare an MCP server (stdio or http)")
(public! 'mcp-ensure! "(mcp-ensure! 'name) — connect a registered MCP server if needed")
(public! 'define-preset! "(define-preset! 'name DESC SERVERS) — name a loadable tool collection")
(public! 'chat-preset-candidates "(chat-preset-candidates BUF) — every preset as (NAME \"●|○ DESC\")")
(public! 'chat-preset-toggle! "(chat-preset-toggle! BUF 'name) — turn one preset on or off for a session")
(public! 'mcp-connections "(mcp-connections) — (name status tool-count) per live MCP connection")
(public! 'mcp-call! "(mcp-call! 'name TOOL ARGS [CB]) — call one tool; ARGS is JSON text or a plist")
(public! 'mcp-tools "(mcp-tools 'name) — (TOOL DESCRIPTION) per tool an MCP server serves")
(public! 'mcp-find "(mcp-find \"words|words\" ['name]) — search MCP tools; gives (SERVER TOOL DESC)")
(public! 'mcp-tool-schema "(mcp-tool-schema 'name TOOL) — that tool's JSON argument schema")
(public! 'mcp-system-note "(mcp-system-note) — the line that tells a model which MCP servers exist")

;; Which servers exist is user config, not core: declare them with
;; mcp-register!/define-preset! in ~/.aimax/ai-config.scm.

;;; --- ACP: agents get the same servers -----------------------------------------
;;; A registered server translates to an ACP session/new mcpServers entry,
;;; stdio and http alike; the caller (an agent thread's config, a chat's
;;; presets) decides which servers each agent session sees. mcp-acp-server
;;; resolves the whole spec once, so the adapter gets literal values and
;;; config files stay secret-free. The surface line shows the url the user
;;; wrote, cut at the query string: a key can ride there.

;; the editor itself as an MCP server: the define-tool! registry bridged
;; over the daemon socket, so external agents read and edit live buffers.
;; The socket is named, not defaulted: a second daemon (AIMAX_HOME) listens
;; on its own path, and its agents must reach IT, not the default one.
(mcp-register! 'aimax
  (list 'command "elixir"
        'args (list (priv-path "aimax-mcp-proxy.exs"))
        'env (list 'AIMAX_SOCK (aimax-socket-path))))

(define-preset! 'aimax "Live ai-max editor tools" '(aimax))

;; a plist of string values -> ((NAME VALUE) ...). ACP asks for env and
;; headers in this shape, and the two differ only in name. The values are
;; literal already: mcp-acp-server resolves the whole spec once.
(define (mcp-acp-pairs plist)
  (let loop ((es (or plist '())) (acc '()))
    (if (null? es)
        (reverse acc)
        (loop (cdr (cdr es))
              (cons (list (symbol->string (car es)) (car (cdr es))) acc)))))

;; stdio and http both translate: the adapter starts a subprocess for the
;; first and opens a connection to the second. A spec with neither
;; 'command nor 'url is no server, and mcp-acp-servers drops it.
(define (mcp-acp-server name)
  (let* ((e (assoc name *mcp-registry*))
         (spec (and e (mcp-resolve-spec (car (cdr e))))))
    (cond ((not spec) #f)
          ((plist-get spec 'command)
           (list 'name (symbol->string name)
                 'command (plist-get spec 'command)
                 'args (or (plist-get spec 'args) '())
                 'env (mcp-acp-pairs (plist-get spec 'env))))
          ((plist-get spec 'url)
           (list 'name (symbol->string name)
                 'type (or (plist-get spec 'type) "http")
                 'url (plist-get spec 'url)
                 'headers (mcp-acp-pairs (plist-get spec 'headers))))
          (else #f))))

(define (mcp-acp-servers names)
  (filter (lambda (x) x) (map mcp-acp-server names)))

;; What a thread carries, read from the wire list and not from the model.
;; An ACP session fixes its mcpServers at session/new, so the answer is the
;; chat's presets, not the registry: a server the user registers later is
;; invisible to a running thread. Ask the agent and you get a guess.
;; The status column says nothing here on purpose. The adapter opens its
;; own connection to each server; the editor's client is a different
;; connection to the same server, and "ready" in one says nothing about
;; the other. This line reports what aimax sent, which is the part aimax
;; controls.
(define (mcp-acp-surface-line s)
  (string-append
    "  " (plist-get s 'name)
    (if (plist-get s 'url)
        (string-append "   http    " (mcp-url-shown (plist-get s 'url)))
        (string-append "   stdio   " (plist-get s 'command) " "
                       (string-join (or (plist-get s 'args) '()) " ")))
    "\n"))

;;; --- what the model holds -----------------------------------------------------
;;; Two questions, two buffers. *chat tools* lists the TOOLS the model can
;;; call, which is what a preset is for. *chat servers* lists the server
;;; configuration aimax sent to an ACP agent, which is what to read when a
;;; tool is missing.

;; mcp__SERVER__tool names its server; every other name is the editor's own
(define (chat-tool-server name)
  (if (string-prefix? "mcp__" name)
      (let ((parts (string-split name "__")))
        (if (pair? (cdr parts)) (car (cdr parts)) "mcp"))
      "aimax"))

;; the servers in force, in the order their tools arrive
(define (chat-tool-servers specs)
  (fold (lambda (acc s)
          (let ((server (chat-tool-server (car s))))
            (if (member server acc) acc (append acc (list server)))))
        '() specs))

;; one line of a description: a tool card that wraps to twenty lines hides
;; the next tool
(define (chat-tool-summary text)
  (let* ((first (car (string-split (or text "") "\n")))
         (n (string-length first)))
    (if (> n 96) (string-append (substring first 0 95) "…") first)))

(define (chat-tool-line spec)
  (string-append "  " (string-pad-right (car spec) 34) "  "
                 (chat-tool-summary (car (cdr spec))) "\n"))

(define-command "chat-tool-list" "List the tools this chat's model holds"
  (lambda ()
    (let ((chat (llm-preset-target)))
      (if (not chat)
          (message "No LLM session here — open one with M-x chat first")
          (let* ((out "*chat tools*")
                 (frozen (buffer-local chat 'chat-tool-specs))
                 (specs (if (pair? frozen) frozen (chat-live-tool-specs chat)))
                 (state (cond ((not (pair? frozen)) "live — the next send freezes this list")
                              ((chat-tools-stale? chat) "stale — C-c t adopts the live list")
                              (else "frozen at the first send"))))
            (buffer-create out)
            (buffer-set-read-only! out #f)
            (buffer-delete-range! out 0 (buffer-size out))
            (buffer-append! out
              (string-append
                chat "\n"
                "presets: "
                (let ((ps (chat-presets-of chat)))
                  (if (null? ps) "none" (string-join (map symbol->string ps) ", ")))
                "\n"
                (number->string (length specs)) " tools · " state "\n"))
            (for-each
              (lambda (server)
                (buffer-append! out (string-append "\n" server "\n"))
                (for-each
                  (lambda (spec)
                    (when (equal? (chat-tool-server (car spec)) server)
                      (buffer-append! out (chat-tool-line spec))))
                  specs))
              (chat-tool-servers specs))
            (when (null? specs)
              (buffer-append! out "\nNo tools yet. Turn a preset on with C-c b.\n"))
            (buffer-set-read-only! out #t)
            (display-buffer out))))))

(define-command "chat-tool-surface" "Show the MCP servers this chat's agent holds"
  (lambda ()
    (let ((chat (llm-preset-target)))
      (if (not chat)
          (message "No chat here — open one with M-x chat first")
          (let ((out "*chat servers*")
                (servers (presets-acp-servers (chat-presets-of chat))))
            (buffer-create out)
            (buffer-set-read-only! out #f)
            (buffer-delete-range! out 0 (buffer-size out))
            (buffer-append! out
              (string-append
                chat "\n"
                "presets: "
                (let ((ps (chat-presets-of chat)))
                  (if (null? ps)
                      "none"
                      (string-join (map symbol->string ps) ", ")))
                (if (buffer-local chat 'chat-mcp-dirty)
                    "   (changed — reconnect to apply)"
                    "")
                "\n\n"))
            (for-each (lambda (s) (buffer-append! out (mcp-acp-surface-line s)))
                      servers)
            (buffer-append! out
              (string-append
                "\nThese servers are the whole surface. The claude-code "
                "connector sets strictMcpConfig, so the agent reads no "
                "MCP server from the user's own config.\n"))
            (buffer-set-read-only! out #t)
            (display-buffer out))))))

;; presets -> an agent session's entire server list. Callers pass
;; chat-presets-of, which guarantees the intrinsic aimax editor bridge.
(define (presets-acp-servers presets)
  (mcp-acp-servers
    (fold (lambda (acc p)
            (fold (lambda (a s) (if (member s a) a (cons s a)))
                  acc (preset-servers p)))
          '() presets)))
