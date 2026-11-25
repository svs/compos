;;; permissions.scm --- M-x permissions: every rule that lets an agent act, and where it holds.
;;;
;;; One row per rule, from every place a rule lives: the shell policy, the
;;; verbs a group answered Always for, the rules a chat keeps, the grants
;;; that last one task, the folders the sandbox lets a shell write, and
;;; the verbs that always ask. k takes a grant back; c changes what the
;;; shell policy gives a kind of command.

(require 'tabulated-list)

(domain! 'chat)
(effects! '(read))
(category! 'chat)

(define *permissions-buffer* "*permissions*")

(define (permissions--list) (list-mode-group-buffer "permissions-mode"))

(define (permissions--group-label g)
  (or (and (boundp 'group-name) (group-name g)) g))

(define (permissions--chats)
  (filter (lambda (b) (and (boundp 'chat-buffer?) (chat-buffer? b))) (buffer-list)))

(define (permissions--task-open? id)
  (let ((t (and id (boundp 'todo-get) (todo-get id))))
    (and t (not (member (plist-get t 'state) '("done" "cancelled"))) #t)))

(define (permissions--shell-why kind grant)
  "what one row of decide-shell-policy covers, and what refuse or ask means for it"
  (string-append
    (cond ((equal? kind 'read)
           "Shell commands that read or search files: cat, grep, sed, head, find. This rule covers the shell only. Agents read every file through the editor (file-section, buffer-text, code-read, project-search-matches), and no rule stops that.")
          ((equal? kind 'edit)
           "Shell commands that write files. Agents edit through the editor's buffer calls, which this rule does not cover. A chat with the sandbox on runs these without a card, but only into the folders on the write tab.")
          ((equal? kind 'jj)
           "jj run from the shell. The editor's jj calls (jj-log, jj-show, jj-describe!, jj-describe-change!) do this work, and no rule stops them.")
          ((equal? kind 'git) "git from the shell. A call that discards work or pushes still raises a card (asks tab).")
          ((equal? kind 'build) "The project's own build, test and format tools.")
          (else "Shell commands that touch no file."))
    (cond ((equal? grant 'refuse)
           (if (equal? kind 'read)
               " Refuse: the gate turns a simple read into the editor call and answers it; anything else is refused with that advice."
               " Refuse: no card; the refusal names what to use instead."))
          ((equal? grant 'ask) " Ask: a card in the chat; Allow, Always or agent-permission-for-task answers it.")
          (else " Allow: runs without a card."))))

(define (permissions--rows-shell)
  (map (lambda (r)
         (list 'id (string-append "shell:" (symbol->string (car r)))
               'kind "shell" 'rule (string-append "shell " (symbol->string (car r)))
               'grant (symbol->string (cadr r)) 'scope "every chat"
               'shell-kind (car r)
               'why (permissions--shell-why (car r) (cadr r))))
       decide-shell-policy))

(define (permissions--rows-group)
  (apply append
    (map (lambda (gc)
           (let ((g (nth 2 gc)))
             (map (lambda (v)
                    (list 'id (string-append "group:" g ":" v) 'kind "group" 'rule v
                          'grant "always" 'scope (string-append "group " (permissions--group-label g))
                          'group g 'verb v
                          'why "Answered Always on a card in a chat of this group. Every chat of the group runs it without asking."))
                  (or (group-setting g 'always-verbs) '()))))
         (if (boundp 'group-counts) (group-counts) '()))))

(define (permissions--short v)
  "V cut to its first line and 60 characters, for the list and a page name"
  (let* ((line (car (string-split (or v "") "\n")))
         (n (string-length line)))
    (if (or (> n 60) (not (equal? line v)))
        (string-append (substring line 0 (min n 60)) "...")
        line)))

(define (permissions--rows-chat)
  (apply append
    (map (lambda (c)
           (append
             (map (lambda (v)
                    (list 'id (string-append "chat:" c ":" (substring (content-hash v) 0 8)) 'kind "chat"
                          'rule (permissions--short v) 'full v
                          'grant "always" 'scope (string-append "chat " c) 'chat c 'verb v
                          'why (string-append
                                 "Answered Always (C-c C-a) in this chat. Only this chat runs it without asking."
                                 (if (< (length (string-split v " ")) 3) ""
                                     " The rule is the whole call: only this exact call runs again without asking."))))
                  (permission-always-rules c))
             (map (lambda (g)
                    (list 'id (string-append "task:" c ":" (car g) ":" (cadr g)) 'kind "task" 'rule (car g)
                          'grant (if (permissions--task-open? (cadr g)) "allow" "ended")
                          'scope (string-append "task " (cadr g)) 'chat c 'verb (car g) 'task (cadr g)
                          'why "Answered For this task (agent-permission-for-task). Holds while the task is open."))
                  (or (buffer-local-value 'task-grants c) '()))))
         (permissions--chats))))

(define (permissions--rows-write)
  (map (lambda (d)
         (list 'id (string-append "write:" d) 'kind "write" 'rule (string-append "write " d)
               'grant (if (and (boundp 'agent-sandbox) agent-sandbox) "allow" "sandbox off")
               'scope "sandboxed chats" 'dir d
               'why "agent-sandbox-writable: a sandboxed shell command may write here, and in its chat's directory and the temp folders, without a card."))
       (if (boundp 'agent-sandbox-writable) agent-sandbox-writable '())))

(define (permissions--rows-deny)
  (map (lambda (p)
         (list 'id (string-append "deny:" p) 'kind "ask" 'rule p 'grant "always asks"
               'scope "every chat" 'pattern p
               'why "*permission-deny-patterns*: a call that matches raises a card every time, whatever else allows it."))
       (if (boundp '*permission-deny-patterns*) *permission-deny-patterns* '())))

(define (permissions--rows buf)
  (append (permissions--rows-chat)
          (permissions--rows-group)
          (permissions--rows-shell)
          (permissions--rows-write)
          (permissions--rows-deny)))

(define (permissions--cells buf row)
  (list (plist-get row 'kind) (plist-get row 'grant) (plist-get row 'scope) (plist-get row 'rule)))

(define (permissions--revocable? row)
  (member (plist-get row 'kind) '("group" "chat" "task" "write")))

(define (permissions--detail-text row)
  (string-append
    (or (plist-get row 'full) (plist-get row 'rule)) "\n"
    (plist-get row 'kind) "  ·  " (plist-get row 'grant) "  ·  " (plist-get row 'scope) "\n\n"
    (plist-get row 'why) "\n\n"
    (cond ((permissions--revocable? row) "k takes it back.\n")
          ((equal? (plist-get row 'kind) "shell") "c cycles allow, ask, refuse.\n")
          (else "Fixed: change *permission-deny-patterns* to change it.\n"))
    "\n────\nend\n"))

(effects! '(write display))

(define (permissions--detail-buffer row) (string-append "*permission:" (plist-get row 'id) "*"))

(define (permissions-show-detail! row)
  "show the page of the rule ROW beside the permissions list"
  (when row
    (let ((buf (permissions--detail-buffer row)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group (permissions--list))))
          (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "permissions-detail-mode"))))
      (buffer-set-local! buf 'permission-row row)
      (buffer-set-text! buf (permissions--detail-text row) #t)
      (display-buffer-detail! buf (permissions--list)))))

(define (permissions--at)
  (or (buffer-local-value 'permission-row (current-buffer))
      (let ((l (permissions--list))) (and (buffer-exists? l) (list-current l)))))

(define (permissions--redraw!)
  (let ((l (permissions--list))) (when (buffer-exists? l) (list-refresh! l))))

(define (permissions-revoke! row)
  "take back the grant ROW: a group's Always, a chat's Always, a task grant, or a writable folder"
  (let ((kind (plist-get row 'kind)) (v (plist-get row 'verb)))
    (cond
      ((equal? kind "group")
       (group-setting-set! (plist-get row 'group) 'always-verbs
                           (filter (lambda (x) (not (equal? x v))) (or (group-setting (plist-get row 'group) 'always-verbs) '()))))
      ((equal? kind "chat")
       (buffer-set-local! (plist-get row 'chat) 'permission-always-rules
                          (filter (lambda (x) (not (equal? x v))) (permission-always-rules (plist-get row 'chat)))))
      ((equal? kind "task")
       (buffer-set-local! (plist-get row 'chat) 'task-grants
                          (filter (lambda (g) (not (equal? g (list v (plist-get row 'task)))))
                                  (or (buffer-local-value 'task-grants (plist-get row 'chat)) '()))))
      ((equal? kind "write")
       (customize-save! 'agent-sandbox-writable
                        (filter (lambda (d) (not (equal? d (plist-get row 'dir)))) agent-sandbox-writable)))
      (else #f))))

(define (permissions-cycle-shell! row)
  "move the shell policy row ROW to its next answer: allow, ask, refuse"
  (let* ((k (plist-get row 'shell-kind))
         (now (cadr (assq k decide-shell-policy)))
         (next (cond ((equal? now 'allow) 'ask) ((equal? now 'ask) 'refuse) (else 'allow))))
    (customize-save! 'decide-shell-policy
                     (map (lambda (r) (if (equal? (car r) k) (list k next) r)) decide-shell-policy))
    next))

(define-list-mode! "permissions-mode"
  (list
    'doc (string-append
           "Every rule that lets an agent act: the shell policy, the verbs a group or a chat answered Always for, "
           "the grants that last one task, the folders a sandboxed shell may write, and the calls that always ask. "
           "The tabs keep the grants you gave, the shell policy, the writable folders, the calls that always ask, or all. "
           "Moving the point shows the rule's page beside the list. k takes a grant back, c cycles a shell kind "
           "through allow, ask and refuse, RET shows the page, / narrows, g reads it again, q quits.")
    'buffer *permissions-buffer*
    'transient #f
    'rows permissions--rows
    'key (lambda (buf row) (plist-get row 'id))
    'local-filter #t
    'tabs (list (list "granted" (lambda (buf r) (member (plist-get r 'kind) '("group" "chat" "task"))))
                (list "shell" (lambda (buf r) (equal? (plist-get r 'kind) "shell")))
                (list "write" (lambda (buf r) (equal? (plist-get r 'kind) "write")))
                (list "asks" (lambda (buf r) (equal? (plist-get r 'kind) "ask")))
                (list "all" (lambda (buf r) #t)))
    'body (lambda (buf r) (permissions--detail-text r))
    'columns (lambda (buf) (list (list "kind" 6) (list "gives" 11) (list "where" 24) (list "rule" #f)))
    'cells permissions--cells
    'preview (lambda (buf row) (permissions-show-detail! row))
    'title (lambda (buf) "Permissions")
    'noun "rule"
    'footer (lambda (buf) '(("RET" "page") ("k" "take back") ("c" "cycle shell") ("/" "filter") ("g" "read again") ("q" "quit")))
    'keys '(("RET" "permissions-show") ("k" "permissions-revoke") ("c" "permissions-cycle")
            ("g" "permissions-refresh") ("q" "quit-window"))))

(define-mode "permissions-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "permissions-detail-mode"
            '(("k" "permissions-revoke") ("c" "permissions-cycle") ("g" "permissions-refresh")))
(mode-doc! "permissions-detail-mode" "One permission rule: what it allows, where it holds, and why. k takes a grant back, c cycles a shell kind, g reads it again.")

(define-command "permissions" "Open every rule that lets an agent act, and take grants back"
  (lambda () (list-mode-show! "permissions-mode")))

(define-command "permissions-show" "Show the rule at point as its own page beside the list"
  (lambda () (permissions-show-detail! (permissions--at)))
  'modes '(permissions-mode))

(define-command "permissions-refresh" "Read the rules again"
  (lambda () (permissions--redraw!))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-revoke" "Take back the grant at point: the next such call asks again"
  (lambda ()
    (let ((row (permissions--at)))
      (cond ((not row) (message "no rule here"))
            ((not (permissions--revocable? row))
             (message (string-append (plist-get row 'rule) " is not a grant: c changes a shell kind")))
            (else (permissions-revoke! row)
                  (message (string-append "took back " (plist-get row 'rule) " (" (plist-get row 'scope) ")"))
                  (permissions--redraw!)))))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-cycle" "Give the shell kind at point its next answer: allow, ask, refuse"
  (lambda ()
    (let ((row (permissions--at)))
      (if (not (and row (equal? (plist-get row 'kind) "shell")))
          (message "c changes a shell policy row")
          (let ((next (permissions-cycle-shell! row)))
            (message (string-append (plist-get row 'rule) " now " (symbol->string next)))
            (permissions--redraw!)))))
  'modes '(permissions-mode permissions-detail-mode))

(public! 'permissions-revoke! "(permissions-revoke! ROW) — take back a grant row of M-x permissions")
(public! 'permissions-show-detail! "(permissions-show-detail! ROW) — show the page of a permissions row beside the list")

(provide 'permissions)
