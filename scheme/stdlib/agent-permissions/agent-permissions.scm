;;; agent-permissions.scm --- Agent permission policy and interaction.
;;;
;;; This module owns permission verdicts, profiles, backend mode sync, and
;;; answers. Agent runtime and transcript functions remain in agent.scm.

;; the rule engine every gate below reads
(load "permission-rules.scm")

(domain! 'permissions)
(effects! '(write))
(category! 'chat)

;; auto: the agent is not interrupted for ordinary work. The deny-list
;; in decide.scm still stops the irreversible outward acts, whatever the stance,
;; and C-c b sets a stricter one per chat.
(define *permission-default-mode* 'auto)

(define (chat-permission-mode buf)
  (or (and buf (buffer-exists? buf) (buffer-local-value 'chat-permission-mode buf))
      *permission-default-mode*))

;; The deny-list and permission-denied-verb? live in decide.scm with every
;; other refusal: one place says no to an agent.

(define (agent-permission-profile slug)
  (let ((buf (agent-buf slug)))
    (and buf (buffer-exists? buf) (buffer-local-value 'agent-permission-profile buf))))

(define (profile-denies? profile text)
  (and profile
       (let ((t (string-downcase text)))
         (let loop ((ps (or (plist-get profile 'deny-patterns) '())))
           (cond ((null? ps) #f)
                 ((re-match? (car ps) t) (car ps))
                 (else (loop (cdr ps))))))))

(define *command-permission-rules* '())

(define (allow-command-when! name predicate)
  (set! *command-permission-rules*
    (cons (list name predicate) *command-permission-rules*))
  name)

(define (command-permitted? buf name)
  (let loop ((rules *command-permission-rules*))
    (cond ((null? rules) #f)
          ((and (equal? name (car (car rules)))
                ((cadr (car rules)) buf)) #t)
          (else (loop (cdr rules))))))

;; "Always" has to mean something on OUR side. The backend's own
;; allow_always binds the backend alone; this policy runs first and would
;; re-derive `ask` on the next call, so the button used to promise a
;; memory nobody kept. The answer becomes a rule, held by the chat that
;; gave it.
;;
;; The rule is keyed by the VERB, not the call. A shell command's
;; arguments differ every time, so "gh api repos/a" would never match
;; "gh api repos/b" — and the family is what the user meant.

(define (permission-command-text title raw)
  ;; ACP carries the tool call's own input beside the title; a Bash call
  ;; puts the command there. The title is the fallback, and on the direct
  ;; lane it is all there is.
  (let* ((call (json-parse (or raw "")))
         (input (and call (plist-get call 'rawInput)))
         (cmd (and input (plist-get input 'command))))
    (if (and (string? cmd) (not (equal? cmd ""))) cmd (or title ""))))

(define (permission-verb text)
  (let ((words (remove (lambda (w) (equal? w ""))
                       (string-split (string-trim (or text "")) " "))))
    (cond ((null? words) "")
          ((null? (cdr words)) (car words))
          (else (string-append (car words) " " (cadr words))))))

(define (permission-signature title kind raw)
  (string-downcase
    (if (equal? kind "execute")
        (permission-verb (permission-command-text title raw))
        (string-trim (string-append (or kind "") " " (or title ""))))))

(define (permission-always-rules buf)
  (or (and buf (buffer-exists? buf) (buffer-local-value 'permission-always-rules buf))
      '()))

(define (permission-always-allow! buf sig)
  (when (and buf (buffer-exists? buf) (not (equal? sig "")))
    (buffer-set-local! buf 'permission-always-rules
      (cons sig (remove (lambda (s) (equal? s sig))
                        (permission-always-rules buf)))))
  sig)

(define (permission-always-allowed? buf title kind raw)
  ;; ask mode says every tool call asks, and it means it: a standing rule
  ;; does not survive the user turning the stance back up.
  (and buf
       (not (equal? (chat-permission-mode buf) 'ask))
       (member (permission-signature title kind raw)
               (permission-always-rules buf))
       #t))

(define (permission-tool-effects title)
  (let ((e (and title (catalog-entry 'tool title))))
    (and e (plist-get e 'effects))))

(define (permission-effects-verdict title kind)
  (and (equal? kind "tool")
       (let ((fx (permission-tool-effects title)))
         (and fx
              (cond ((equal? title "apropos") 'allow-always)
                    ((or (member "destroy" fx) (member "spend" fx)) 'ask)
                    ((null? (remove (lambda (f) (member f '("pure" "read"))) fx))
                     'allow-always)
                    (else #f))))))

;;; --- the filesystem is not the agent's ----------------------------------------

(defcustom 'agent-filesystem-tools "deny"
  "What an agent's own filesystem tools may do. Use deny, ask, or allow."
  'group 'chat 'type 'string)

;; The agent edits BUFFERS. A write straight to a file goes around the
;; editor, and provenance records the buffer process, so a change no
;; buffer ever saw carries no revision, no actor and no weave entry: the
;; file reads as though it had always looked that way. The same write
;; leaves an open buffer holding the old text and still reporting itself
;; unmodified, so the next save from that buffer puts the old text back.
;; Both are silent, and the second one loses work.
;;
;; ACP labels what a tool call does to the workspace. "edit", "delete"
;; and "move" are the filesystem verbs; "read" is not one, and compos's
;; own MCP tools arrive as "other", so eval-scheme and the code editors
;; keep working. The titles cover a lane that sends no kind.
(define *filesystem-tool-kinds* '("edit" "delete" "move"))

(define *filesystem-tool-patterns*
  (list "^(edit|write|multiedit|notebookedit)\\b"
        "apply[-_ ]*patch" "str[-_ ]*replace"
        "(write|create|delete|move|rename)[-_ ]*(text[-_ ]*)?file"))

(define (filesystem-tool? title kind)
  (or (and kind (member kind *filesystem-tool-kinds*) #t)
      (and title
           (let ((t (string-downcase title)))
             (let loop ((ps *filesystem-tool-patterns*))
               (cond ((null? ps) #f)
                     ((re-match? (car ps) t) #t)
                     (else (loop (cdr ps)))))))))

;; #f when this is not a filesystem tool, so the policy's cond falls
;; through to the clauses after it.
(define (filesystem-tool-verdict title kind)
  (and (filesystem-tool? title kind)
       (cond ((equal? agent-filesystem-tools "allow") #f)
             ((equal? agent-filesystem-tools "ask") 'ask)
             (else 'reject))))

;; The deny-list is decide's, and decide judges shell commands: a shell
;; line, or the shell calls inside an eval-scheme payload. A word in a
;; search, a query or a string is not an act, so nothing else reads it.
(define *permission-eval-tools* '("eval-scheme" "mcp__compos__eval-scheme"))
(define *permission-read-eval-tools* '("eval-scheme-read" "mcp__compos__eval-scheme-read"))

;; the Scheme an eval-scheme call carries: its code, or the code inside
;; the JSON arguments of the MCP proxy
(define (permission--raw-json raw)
  (and (string? raw) (string-prefix? "{" (string-trim raw))
       (ignore-errors (lambda () (json-parse raw)))))

;; the code of an eval call: the arguments themselves, or, in the tool call
;; Claude Code sends over ACP, its rawInput
(define (permission-eval-code raw)
  (let* ((j (permission--raw-json raw))
         (input (and (pair? j) (plist-get j 'rawInput)))
         (code (or (and (pair? j) (plist-get j 'code))
                   (and (pair? input) (plist-get input 'code)))))
    (if (string? code) code raw)))

;; the tool a request names. Claude Code titles an MCP call "compos:
;; eval-scheme"; its tool call carries the real name, mcp__compos__eval-scheme
(define (permission-tool-name title raw)
  (let* ((j (permission--raw-json raw))
         (name (and (pair? j) (plist-get j 'name))))
    (if (and (string? name)
             (or (member name *permission-eval-tools*) (member name *permission-read-eval-tools*)))
        name
        title)))

(define (permission-shell-text title kind raw)
  "the text decide's deny-list reads: a shell line whole, the shell commands of an eval-scheme payload, #f for any other call"
  (cond ((equal? kind "execute") (string-append (or title "") " " (or raw "")))
        ((member title *permission-eval-tools*)
         (let* ((code (permission-eval-code raw))
                (forms (and code (ignore-errors (lambda () (scheme-read code))))))
           ;; a payload that does not read is judged whole, as before
           (if (and (pair? forms) (boundp (quote mcp-proxy--shell-commands)))
               (string-join (mcp-proxy--shell-commands forms) " ; ")
               code)))
        (else #f)))

;; A turn that an outsider's words started may not send unasked. It holds
;; text that nobody the user trusts wrote, and the editor holds the user's
;; data, so a send in that turn waits for the user, whatever the stance:
;; untrusted input, private data and a way out never meet without a
;; person (the "Rule of Two"). The mark is the well-known untrusted? local
;; at #t (docs/07. AGENTS.md); agent-note-turn-source!
;; (agent-session.scm) sets it, and so may a security package. A read and
;; a local write still run.
(define *permission-send-effects* '("external" "spend" "destroy" "unknown" "execute"))

(define (permission-outside-text? buf)
  (and buf (buffer-exists? buf)
       (eq? (buffer-local-value 'untrusted? buf) #t)))

(define (permission-send-effects? fx)
  (and (pair? fx)
       (pair? (filter (lambda (f) (member f *permission-send-effects*)) fx))))

(define (permission-may-send? title kind raw)
  "#t when the call can send, spend or destroy: a shell line, an eval-scheme payload that runs a shell command, calls a function with such an effect or does not read, a tool or command with such an effect or none on record"
  (let ((title (permission-tool-name title raw)))
  (cond ;; eval-scheme-read refuses any code that writes, so it never sends
        ((member title *permission-read-eval-tools*) #f)
        ((member title *permission-eval-tools*)
         (let* ((code (permission-eval-code raw))
                (forms (and code (ignore-errors (lambda () (scheme-read code))))))
           (or (not (pair? forms))
               (not (boundp (quote mcp-proxy--calls)))
               (pair? (mcp-proxy--shell-commands forms))
               (pair? (filter (lambda (name)
                                (let ((e (catalog-entry 'function name)))
                                  (and e (permission-send-effects? (plist-get e 'effects)))))
                              (mcp-proxy--calls forms))))))
        ((equal? kind "execute") #t)
        ((equal? kind "tool")
         (let ((fx (permission-tool-effects title)))
           (or (not fx) (permission-send-effects? fx))))
        ((equal? kind "command")
         (let ((e (catalog-entry 'command title)))
           (or (not e) (permission-send-effects? (plist-get e 'effects)))))
        ;; the adapter's own kinds: delete destroys, fetch goes out, and
        ;; other says nothing of what it does
        (else (and (member kind '("delete" "fetch" "other")) #t)))))

;; (permit? BUF TITLE KIND RAW) -> allow-always | ask | reject: the one
;; permission decision. Every lane asks it: the ACP request, the direct
;; lane, the MCP proxy and an M-x command a chat runs.
(define (permit--engine buf title kind raw)
  "what the rule engine gives this request: allow-always, ask, reject, or #f when no rule speaks"
  (let* ((hit (permission-decide-all (permission-request-actions title kind raw) (permission-context buf)))
         (gives (and hit (car hit))))
    (cond ((not gives) #f)
          ((equal? gives 'deny) 'reject)
          ((equal? gives 'ask) 'ask)
          ;; ask mode means every call asks: no allow rule waves one through
          ((equal? (chat-permission-mode buf) 'ask) 'ask)
          (else (when (equal? gives 'notify) (permission-notify! buf (cadr hit) (caddr hit)))
                'allow-always))))

(define (permission-notify! buf rule action)
  "say in chat BUF, and in the echo area, that ACTION ran under the notify RULE"
  (let ((line (string-append "ran under a notify rule: " (permission--str (plist-get action 'function))
                             "  (" (permission-describe-rule rule) ")")))
    (message line)
    (let ((slug (and buf (buffer-exists? buf) (agent-slug-of buf))))
      (when slug
        (let ((start (agent-render! slug (string-append "  " line "\n") "agent-meta")))
          (agent-block-push! buf start (agent-mark slug) "meta" '()))))))

(define (permit? buf title kind raw)
    (let* ((text (string-append (or title "") " " (or kind "") " " (or raw "")))
           (profile (and buf (buffer-exists? buf)
                         (buffer-local-value 'agent-permission-profile buf))))
      (cond ((profile-denies? profile text) 'reject)
            ;; a turn an outsider's words started may not send unasked,
            ;; whatever the stance and whatever "always" said before
            ((and (permission-outside-text? buf)
                  (permission-may-send? title kind raw))
             'ask)
            ;; the rule engine (permission-rules.scm): the deny patterns,
            ;; the user's Always answers at every scope, and every rule the
            ;; user wrote in M-x permissions. It sits under the profile and
            ;; the outsider gate and over the file gate, because a gate set
            ;; to ask that asks again after Always is the bug.
            ((permit--engine buf title kind raw))
            ((filesystem-tool-verdict title kind))  ; files go through buffers
            ;; a shell command is exactly the irreversible act the approve
            ;; stance promises to surface: the popup decides, not a silent
            ;; veto. Only auto runs it unasked — and the deny-list verbs
            ;; above still stop to ask even then.
            ((equal? kind "execute")
             (if (equal? (chat-permission-mode buf) 'auto) 'allow-always 'ask))
            ((and (equal? kind "command")
                  (command-permitted? buf title)) 'allow-always)
            ((equal? kind "command") 'ask)
            ((permission-effects-verdict title kind))
            ((equal? (chat-permission-mode buf) 'ask) 'ask)
            (else 'allow-always))))

(public! 'permit?
  "(permit? BUF TITLE KIND RAW) -> 'allow-always, 'ask or 'reject for one tool call, command or shell line in BUF's chat")
(public! 'chat-permission-mode-set!
  "(chat-permission-mode-set! BUF 'approve|'auto|'ask) — set a session's permission stance, and tell a live agent")
(public! 'permission-policy-report
  "(permission-policy-report BUF) — the whole permission policy for one session as readable text")
(public! 'agent-mode-set!
  "(agent-mode-set! BUF MODE) — put the running ACP session in one of its own modes; #f when it refuses")

(public! 'allow-command-when!
  "(allow-command-when! NAME PREDICATE) — register a permission predicate that can allow one M-x command for a chat buffer")

(public! 'permission-signature
  "(permission-signature TITLE KIND RAW) — the verb an Always answer is remembered by")

(effects! '(read))
(public! 'permission-shell-text
  "(permission-shell-text TITLE KIND RAW) -- the shell text checked by the deny-list")

(effects! '(write))
(public! 'permission-always-rules
  "(permission-always-rules BUF) — the verbs this chat answered Always for")

(catalog-meta! 'function "allow-command-when!" 'domain 'permissions 'effects '(write))

(llm-session-permission-fn!
  (lambda (slug name kind raw)
    (let* ((buf (agent-buf slug))
           (v (permit? buf name kind raw)))
      (cond ((equal? v 'reject) 'reject)
            ((equal? v 'ask) 'ask)
            (else 'allow)))))

(defcustom 'permission-timeout-ms 120000
  "Auto-deny an unanswered permission after this long, in chats no window shows."
  'group 'chat 'type 'integer)

(defcustom 'permission-ask-timeout-ms 30000
  "Deny a permission card the editor raised itself, such as the shell gate's ask, when nobody answers it in this long."
  'group 'chat 'type 'integer)

(define (agent-arm-permission-deadline! slug)
  (unless (window-showing (agent-buf slug))
    (agent-permission-deadline! slug permission-timeout-ms)))

;; "dontAsk" is not an auto mode. Its own description is "Don't prompt for
;; permissions, deny if not pre-approved" - a session in that mode refuses
;; every tool compos has not pre-allowed, and never asks, so an auto chat
;; became a chat that could not read a file. Auto must pick a mode that
;; PERMITS. acceptEdits comes first: it silences the edit round-trips and
;; still routes everything else through permit?, so the deny-list
;; and the profile keep working. bypassPermissions is the fallback for a
;; backend with no acceptEdits, and it takes compos out of the loop.
(define *permission-auto-modes* '("acceptEdits" "bypassPermissions"))

(define *permission-ask-modes* '("default"))

(define (agent--pick-mode buf wanted)
  (let ((avail (map car (or (buffer-local-value 'agent-modes buf) '()))))
    (let loop ((ws wanted))
      (cond ((null? ws) #f)
            ((member (car ws) avail) (car ws))
            (else (loop (cdr ws)))))))

(define (agent-sync-permission-mode! slug)
  (let* ((buf (agent-buf slug))
         (cur (buffer-local-value 'agent-mode buf))
         (auto? (equal? (chat-permission-mode buf) 'auto))
         (want (cond (auto? (agent--pick-mode buf *permission-auto-modes*))
                     ((member cur *permission-auto-modes*)
                      (agent--pick-mode buf *permission-ask-modes*))
                     (else #f))))
    (when (and want (not (equal? want cur)))
      (when (llm-session-set-mode! slug want)
        (buffer-set-local! buf 'agent-mode want)))))

;; the session that can answer right now, or #f
(define (agent-mode--live buf)
  (let ((slug (buffer-local-value 'agent-slug buf)))
    (and slug (not (equal? (agent-status slug) 'dead)) slug)))

;; The ACP session's OWN mode. The backend owns the list and the answer:
;; it can refuse, and a refusal must not leave the local claiming it took.
;; With no session to ask — a chat that has not attached, or one still
;; restarting after a backend switch — the choice PARKS, and
;; agent-mode-take-pending! applies it as soon as the session names its
;; modes. Choosing a mode never waits on a running agent.
(define (agent-mode--park! buf mode)
  (buffer-set-local! buf 'agent-mode-wanted mode)
  (buffer-set-local! buf 'agent-mode mode)
  (agent-update-modeline! buf)
  mode)

(define (agent-mode-set! buf mode)
  (let ((slug (agent-mode--live buf)))
    (cond ((not slug) (agent-mode--park! buf mode))
          ((llm-session-set-mode! slug mode)
           (buffer-set-local! buf 'agent-mode-wanted #f)
           (buffer-set-local! buf 'agent-mode mode)
           (agent-update-modeline! buf)
           mode)
          ;; a session that has not named its modes yet is still starting:
          ;; that is a wait, not a refusal
          ((not (pair? (buffer-local-value 'agent-modes buf)))
           (agent-mode--park! buf mode))
          (else #f))))

;; called when a session first names its modes: an explicit choice made
;; before it existed wins over the stance sync, and a mode this backend
;; does not have is dropped rather than kept forever
(define (agent-mode-take-pending! buf)
  (let ((want (buffer-local-value 'agent-mode-wanted buf))
        (avail (map car (or (buffer-local-value 'agent-modes buf) '()))))
    (and want
         (begin
           (buffer-set-local! buf 'agent-mode-wanted #f)
           (and (member want avail) (agent-mode-set! buf want))))))

;; (NAME DESCRIPTION) per mode. The running session's own list when it has
;; one, otherwise the list this connector was last seen offering — so the
;; menu can name a mode for a chat whose session is not up.
(define (agent-mode-options buf)
  (map (lambda (m) (list (car m) (or (nth 2 m) "")))
       (chat-mode-options buf (buffer-local-value 'agent-connector buf))))

(define-command "agent-set-mode" "Switch the agent session's mode (plan, acceptEdits, ...)"
  (lambda ()
    (let* ((buf (current-buffer))
           (modes (agent-mode-options buf)))
      (cond ((not (buffer-local-value 'agent-connector buf)) (message "not an agent chat"))
            ((null? modes) (message "this backend has no session modes"))
            (else
              (minibuffer-read
                (string-append "Mode (now " (or (buffer-local-value 'agent-mode buf) "?") "): ")
                (agent-mode-options buf)
                (lambda (m)
                  (unless (equal? (string-trim m) "")
                    (if (agent-mode-set! buf m)
                        (message (string-append "agent mode: " m))
                        (message "the agent refused that mode"))))))))))

;; What each stance means, in one place: the message after a change and
;; the annotation beside a choice say the same thing.
(define (chat-permission-mode-note mode)
  (cond ((equal? mode 'ask) "every tool call asks")
        ((equal? mode 'approve) "only irreversible acts ask")
        (else "the agent stops asking too; the deny-list still holds")))

(define *permission-modes* '(approve auto ask))

;; The whole policy on one page: what asks, what runs, what is refused,
;; and which C-c b key moves each part. The dialog can only hold three
;; labels; this is the rest of the answer to "am I seeing everything?"
(define (permission-policy-report buf)
  (let ((stance (chat-permission-mode buf))
        (rules (permission-always-rules buf)))
    (string-append
      "Permissions — " buf "\n\n"
      "asks (C-c b k): " (symbol->string stance)
      " — " (chat-permission-mode-note stance) "\n"
      "agent mode (C-c b a): "
      (let ((m (buffer-local-value 'agent-mode buf)))
        (if (or (not m) (equal? m "")) "none" m))
      " — the backend's own mode, read live from the session\n"
      "file tools (C-c b f): " agent-filesystem-tools
      " — deny routes the agent's edits through buffers instead\n"
      "shell (execute): "
      (if (equal? stance 'auto) "runs without asking" "asks first") "\n"
      "editor commands: catalogued effects decide — pure and read run, "
      "destroy and spend ask\n"
      ;; what "Always" built. A standing rule is state the user made, so
      ;; the page that explains the gate has to name it.
      (if (null? rules)
          ""
          (string-append
            "\nyou answered Always here, so these no longer ask:\n"
            (apply string-append
              (map (lambda (r) (string-append "  " r "\n")) rules))))
      "\nalways stops to ask, whatever the stance:\n"
      (apply string-append
        (map (lambda (p) (string-append "  " p "\n"))
             (filter (lambda (p) (not (and decide-allow-git (decide--git-pattern? p))))
                     *permission-deny-patterns*)))
      (if decide-allow-git "\ngit runs without asking (decide-allow-git)\n" "")
      "\nshell gate: "
      (if decide-shell-gate
          (string-append "on — "
            (string-join (map (lambda (r) (string-append (symbol->string (car r)) " " (symbol->string (cadr r))))
                              decide-shell-policy)
                         ", "))
          "off")
      "\n")))

;; The stance, set outright. Cycling it and applying a bundle take the same
;; road: the local, then the live agent, then the modeline.
(define (chat-permission-mode-set! buf mode)
  (buffer-set-local! buf 'chat-permission-mode mode)
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf))
  ;; a live agent hears about it immediately, not at the next reconnect
  (let ((slug (buffer-local-value 'agent-slug buf)))
    (when (and slug (not (equal? (agent-status slug) 'dead)))
      (agent-sync-permission-mode! slug)))
  (agent-update-modeline! buf)
  mode)

(define-command "chat-set-permission-mode" "Cycle this chat's permission mode"
  (lambda ()
    (let* ((buf (current-buffer))
           (m (chat-permission-mode buf))
           (next (cond ((equal? m 'approve) 'auto)
                       ((equal? m 'auto) 'ask)
                       (else 'approve))))
      (chat-permission-mode-set! buf next)
      (message
        (string-append "permissions: " (symbol->string next)
                       " — " (chat-permission-mode-note next)))))
  'modes '(chat-mode))

(define (agent-perm-option options exact prefix)
  (let loop ((os options) (by-prefix #f))
    (cond ((null? os) by-prefix)
          ((equal? (nth 2 (car os)) exact) (car os))
          ((and (not by-prefix) (string-prefix? prefix (nth 2 (car os))))
           (loop (cdr os) (car os)))
          (else (loop (cdr os) by-prefix)))))

(define (agent-answer-permission! slug exact prefix)
  (let ((info (agent-info slug)))
    (let ((perm (and info (plist-get info 'permission))))
      (if (not perm)
          (message "no pending permission")
          (let ((opt (agent-perm-option (plist-get perm 'options) exact prefix)))
            (agent-permission-respond! slug (plist-get perm 'rpc-id)
              (if opt (car opt) #f))
            (when (string-prefix? "reject" prefix)
              (let ((start (agent-render! slug
                             (string-append "permission denied: "
                                            (plist-get perm 'title) "\n")
                             "agent-meta")))
                (agent-block-push! (agent-buf slug) start
                  (agent-mark slug) "meta" '()))))))))

(define-command "agent-permission-allow" "Allow the pending permission request once"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_once" "allow"))
  'modes '(chat-mode))

;; A card's Always answer becomes a rule of the engine (permission-rules.scm)
;; at the scope the user picked. The rule takes the selector of the rule
;; that asked, so the narrower scope wins over it; a call no rule asked for
;; gets a rule for its own function. An editor card (the MCP proxy) writes
;; its rule where the call waits, in mcp-proxy--grant!, which has the call's
;; arguments; a backend's card keeps none, so its rule is written here from
;; what agent.scm recorded.
(define (permission-request-actions title kind raw)
  "the actions of one backend permission request. Only a shell command carries text, so a pattern rule reads shell commands and never a word in a query or a string"
  (if (equal? kind "execute")
      ;; the verb names the rule a card writes; the pattern rules read the whole line
      (let ((cmd (permission-command-text title raw)))
        (list (plist-put (permission-shell-action cmd #f) 'text
                         (or (permission-shell-text title kind raw) cmd))))
      (let ((shell (permission-shell-text title kind raw)))
        (cons (permission-tool-action title #f)
              (if shell (list (permission-shell-action shell #f)) '())))))

(define (permission-grant-for! buf actions scope)
  "write the rule a card's Always answer gives ACTIONS in chat BUF at SCOPE; answers its id or #f. SCOPE (turns N) is a pass: this chat, for N turns, this one included"
  (when (and (or (equal? scope 'chat) (pair? scope)) (not (buffer-local-value 'chat-id buf)) (boundp (quote chat-stable-id!)))
    (chat-stable-id! buf))
  (let* ((ctx (permission-context buf))
         (pass (and (pair? scope) (plist-get ctx 'chat) (permission-pass-expires (plist-get ctx 'chat) (cadr scope))))
         (sc (permission-scope-of ctx (if (pair? scope) 'chat scope)))
         (hit (permission-decide-all actions ctx))
         ;; no rule asked: a lone call gets a rule for its function; an eval
         ;; payload's many calls name nothing worth a rule
         (sel (if (and hit (member (car hit) '(ask deny)))
                  (plist-get (cadr hit) 'selector)
                  (and (pair? actions) (null? (cdr actions))
                       (permission-grant-selector (car actions) 'function))))
         (id (and sc sel (ignore-errors
                           (lambda () (permission-rule-add! sel sc 'allow "card"
                                                            (if pass "a pass given on a card" "answered Always on a card")
                                                            #f pass))))))
    (message (cond (id (string-append "rule added: " (permission-describe-rule (permission-rule id))))
                   ((not sc) "no such scope here: allowed once")
                   (else "that rule is locked: allowed once; M-x permissions changes it")))
    id))

(define (permission--answer-always! scope)
  (let* ((buf (current-buffer))
         (slug (agent-slug-of buf))
         (info (and slug (agent-info slug)))
         (pending (and info (plist-get info 'permission)))
         (asked (buffer-local-value 'permission-asked buf)))
    (buffer-set-local! buf 'permission-grant-scope scope)
    (when (and pending asked (not (buffer-local-value 'permission-asked-editor buf)))
      (buffer-set-local! buf 'permission-grant-scope #f)
      (permission-grant-for! buf (permission-request-actions (car asked) (cadr asked) (nth 2 asked)) scope))
    (agent-answer-permission! slug "allow_always" "allow")))

(define-command "agent-permission-always" "Allow this kind of call in this group from now on"
  (lambda () (permission--answer-always! 'group))
  'modes '(chat-mode))

;; The card's other scopes: the chat's open task (the rule ends with the
;; task), this chat alone, or every chat.
(define-command "agent-permission-for-task" "Allow this kind of call until this chat's task is done"
  (lambda ()
    (if (mcp-proxy--chat-task (current-buffer))
        (permission--answer-always! 'task)
        (message "this chat works no open task: use Allow or Always")))
  'modes '(chat-mode))

(define-command "agent-permission-turn" "Allow this kind of call until this turn ends"
  (lambda () (permission--answer-always! '(turns 1)))
  'modes '(chat-mode))

(define-command "agent-permission-3-turns" "Allow this kind of call for this turn and the next two"
  (lambda () (permission--answer-always! '(turns 3)))
  'modes '(chat-mode))

(define-command "agent-permission-chat" "Allow this kind of call in this chat from now on"
  (lambda () (permission--answer-always! 'chat))
  'modes '(chat-mode))

(define-command "agent-permission-everywhere" "Allow this kind of call in every chat from now on"
  (lambda () (permission--answer-always! 'everywhere))
  'modes '(chat-mode))

(define-command "agent-permission-deny" "Deny the pending permission request"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "reject_once" "reject"))
  'modes '(chat-mode))
