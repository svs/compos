;;; agent-permissions.scm --- Agent permission policy and interaction.
;;;
;;; This module owns permission verdicts, profiles, backend mode sync, and
;;; answers. Agent runtime and transcript functions remain in agent.scm.

(domain! 'permissions)
(effects! '(write))
(category! 'chat)

(define *permission-default-mode* 'approve)

(define (chat-permission-mode buf)
  (or (and buf (buffer-exists? buf) (buffer-local buf 'chat-permission-mode))
      *permission-default-mode*))

(define *permission-deny-patterns*
  (list
        ;; Git that rewrites the work tree is a file write by another name:
        ;; it lands text the editor never saw, and it can lose an unsaved
        ;; buffer. Reading git, staging it, and committing it change no
        ;; working file, so they stay out of this list.
        "git[-_ ]+(checkout|restore|stash|clean|apply|pull|merge|rebase|revert)"
        "git[-_ ]+reset[-_ ]+--(hard|merge)"
        "send[-_ ]*mail" "sendmail" "mail[-_ ]*send" "smtp"
        "send[-_ ]*(message|email|sms|text)"
        "(permanently|forever)[-_ ]*delete" "delete[-_ ]*(permanently|forever)"
        "empty[-_ ]*trash" "trash[-_ ]*empty" "expunge"
        "rm[-_ ]+-[a-z]*[rf]"
        ;; user ruling 2026-09-02: a push through jj is always allowed; the
        ;; jj-push command carries its own agent-author guard.
        "(?<!jj[-_ ])git[-_ ]+push" "force[-_ ]*push"
        "\\bpublish\\b" "\\bdeploy\\b"))

(define (permission-denied-verb? text)
  (let ((t (string-downcase text)))
    (let loop ((ps *permission-deny-patterns*))
      (cond ((null? ps) #f)
            ((re-match? (car ps) t) (car ps))
            (else (loop (cdr ps)))))))

(define (agent-permission-profile slug)
  (let ((buf (agent-buf slug)))
    (and buf (buffer-exists? buf) (buffer-local buf 'agent-permission-profile))))

(define (set-agent-permission-profile! slug profile)
  (let ((buf (agent-buf slug)))
    (when (and buf (buffer-exists? buf))
      (buffer-set-local! buf 'agent-permission-profile profile)))
  profile)

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

(define *permission-policy*
  (lambda (buf title kind raw)
    (let* ((text (string-append (or title "") " " (or kind "") " " (or raw "")))
           (profile (and buf (buffer-exists? buf)
                         (buffer-local buf 'agent-permission-profile))))
      (cond ((permission-denied-verb? text) 'ask)
            ((profile-denies? profile text) 'reject)
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
            (else 'allow-always)))))

(public! 'chat-permission-mode-set!
  "(chat-permission-mode-set! BUF 'approve|'auto|'ask) — set a session's permission stance, and tell a live agent")
(public! 'permission-policy-report
  "(permission-policy-report BUF) — the whole permission policy for one session as readable text")
(public! 'agent-mode-set!
  "(agent-mode-set! BUF MODE) — put the running ACP session in one of its own modes; #f when it refuses")

(public! 'allow-command-when!
  "(allow-command-when! NAME PREDICATE) — register a permission predicate that can allow one M-x command for a chat buffer")

(catalog-meta! 'function "allow-command-when!" 'domain 'permissions 'effects '(write))

(llm-session-permission-fn!
  (lambda (slug name kind raw)
    (let* ((buf (agent-buf slug))
           (v (*permission-policy* buf name kind raw)))
      (cond ((equal? v 'reject) 'reject)
            ((equal? v 'ask) 'ask)
            (else 'allow)))))

(defcustom 'permission-timeout-ms 120000
  "Auto-deny an unanswered permission after this long, in chats no window shows."
  'group 'chat 'type 'integer)

(define (agent-arm-permission-deadline! slug)
  (unless (window-showing (agent-buf slug))
    (agent-permission-deadline! slug permission-timeout-ms)))

(define *permission-auto-modes* '("dontAsk" "acceptEdits" "bypassPermissions"))

(define *permission-ask-modes* '("default"))

(define (agent--pick-mode buf wanted)
  (let ((avail (map car (or (buffer-local buf 'agent-modes) '()))))
    (let loop ((ws wanted))
      (cond ((null? ws) #f)
            ((member (car ws) avail) (car ws))
            (else (loop (cdr ws)))))))

(define (agent-sync-permission-mode! slug)
  (let* ((buf (agent-buf slug))
         (cur (buffer-local buf 'agent-mode))
         (auto? (equal? (chat-permission-mode buf) 'auto))
         (want (cond (auto? (agent--pick-mode buf *permission-auto-modes*))
                     ((member cur *permission-auto-modes*)
                      (agent--pick-mode buf *permission-ask-modes*))
                     (else #f))))
    (when (and want (not (equal? want cur)))
      (when (llm-session-set-mode! slug want)
        (buffer-set-local! buf 'agent-mode want)))))

;; The ACP session's OWN mode. The backend owns the list and the answer:
;; it can refuse, and a refusal must not leave the local claiming it took.
(define (agent-mode-set! buf mode)
  (let ((slug (buffer-local buf 'agent-slug)))
    (cond ((not slug) #f)
          ((llm-session-set-mode! slug mode)
           (buffer-set-local! buf 'agent-mode mode)
           (agent-update-modeline! buf)
           mode)
          (else #f))))

;; (NAME DESCRIPTION) per mode the running session offers.
(define (agent-mode-options buf)
  (map (lambda (m) (list (car m) (or (nth 2 m) "")))
       (or (buffer-local buf 'agent-modes) '())))

(define-command "agent-set-mode" "Switch the agent session's mode (plan, acceptEdits, ...)"
  (lambda ()
    (let* ((buf (current-buffer))
           (slug (buffer-local buf 'agent-slug))
           (modes (buffer-local buf 'agent-modes)))
      (cond ((not slug) (message "not an agent chat"))
            ((not modes) (message "this backend has no session modes"))
            (else
              (minibuffer-read
                (string-append "Mode (now " (or (buffer-local buf 'agent-mode) "?") "): ")
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
  (let ((stance (chat-permission-mode buf)))
    (string-append
      "Permissions — " buf "\n\n"
      "asks (C-c b k): " (symbol->string stance)
      " — " (chat-permission-mode-note stance) "\n"
      "agent mode (C-c b a): "
      (let ((m (buffer-local buf 'agent-mode)))
        (if (or (not m) (equal? m "")) "none" m))
      " — the backend's own mode, read live from the session\n"
      "file tools (C-c b f): " agent-filesystem-tools
      " — deny routes the agent's edits through buffers instead\n"
      "shell (execute): "
      (if (equal? stance 'auto) "runs without asking" "asks first") "\n"
      "editor commands: catalogued effects decide — pure and read run, "
      "destroy and spend ask\n"
      "\nalways stops to ask, whatever the stance:\n"
      (apply string-append
        (map (lambda (p) (string-append "  " p "\n"))
             *permission-deny-patterns*)))))

;; The stance, set outright. Cycling it and applying a bundle take the same
;; road: the local, then the live agent, then the modeline.
(define (chat-permission-mode-set! buf mode)
  (buffer-set-local! buf 'chat-permission-mode mode)
  (when (boundp (quote workspace-llm-defaults-note!))
    (workspace-llm-defaults-note! buf))
  ;; a live agent hears about it immediately, not at the next reconnect
  (let ((slug (buffer-local buf 'agent-slug)))
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
                       " — " (chat-permission-mode-note next))))))

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
                                       "allow_once" "allow")))

(define-command "agent-permission-always" "Allow and stop asking for this tool"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "allow_always" "allow")))

(define-command "agent-permission-deny" "Deny the pending permission request"
  (lambda () (agent-answer-permission! (agent-slug-of (current-buffer))
                                       "reject_once" "reject")))
