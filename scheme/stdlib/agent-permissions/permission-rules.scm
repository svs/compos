;;; permission-rules.scm --- one rule engine decides what an agent may do.
;;;
;;; An agent's request is judged as ACTIONS, one per thing it does:
;;;   (kind K function F package P domain D effects (E ...) text T path P)
;;; K is tool (a backend tool), call (a Scheme call in an eval payload),
;;; shell (a shell command) or command (an M-x command). Effects, domain and
;;; package come from the catalog stamps; a name with no stamp has the
;;; effect unknown until the decision model classifies it.
;;;
;;; A RULE is
;;;   (id ID selector SEL scope SCOPE gives allow|notify|ask|deny lock BOOL by WHO why TEXT)
;;; SEL is a plist of facets, and every facet it names must match:
;;;   kind, effect, domain, package, function (a trailing * matches a
;;;   prefix), text (a regex on the request text), path (a folder).
;;; SCOPE is everywhere, (group G), (chat ID) or (task ID). A task rule
;;; holds while its task is open. A locked rule only the user changes, in
;;; M-x permissions; a card or an agent never writes over it.
;;;
;;; The most specific matching rule wins; the first difference decides:
;;;   1. the selector's top facet: path > function = text > package >
;;;      domain > effect > kind > none
;;;   2. more facets
;;;   3. a longer path
;;;   4. the narrower scope: task > chat > group > everywhere
;;;   5. the strictest answer: deny > ask > notify > allow
;;; notify runs the call and tells the user it ran.
;;; A request with several actions gets the strictest answer of its actions.

(domain! 'permissions)
(effects! '(read))

;;; --- the store ----------------------------------------------------------
;;; One file under the compos home holds every rule; the registry table
;;; 'permission-rule holds them live, so every lane reads the same rules.

;; .sexp, not .scm: the compos home is on the load path, and a rules file
;; named like this package shadowed it there
(define (permission-rules-file) (string-append (compos-home) "/permission-rules.sexp"))

(define (permission-rules--ensure!)
  (unless (registry-lookup 'permission-meta 'loaded #f)
    (registry-register! 'permission-meta 'loaded #t)
    (let ((src (and (file-exists? (permission-rules-file))
                    (read-file-source (permission-rules-file)))))
      (when (string? src)
        (for-each (lambda (r) (when (and (pair? r) (plist-get r 'id) (not (plist-get r 'expires)))
                                (registry-register! 'permission-rule (plist-get r 'id) r)))
                  (or (ignore-errors (lambda () (scheme-read src))) '())))
      ;; a home with no rules file yet: the old stores become its rules
      (unless (string? src) (permission-rules-migrate!)))))

(define (permission-rules)
  "every rule, in the order they were made"
  (permission-rules--ensure!)
  (map cadr (registry-list 'permission-rule)))

(define (permission-rule id)
  (permission-rules--ensure!)
  (registry-lookup 'permission-rule id #f))

(define (permission-rules-version) (registry-lookup 'permission-meta 'version 0))

(define (permission-rules--save!)
  (registry-register! 'permission-meta 'version (+ 1 (permission-rules-version)))
  (raw-write-file! (permission-rules-file)
    (string-append ";; permission rules: M-x permissions edits them. One rule per line.\n"
                   (string-join (map value->string (permission-rules)) "\n")
                   "\n")))

(define (permission-rules--id sel scope)
  (string-append "r-" (substring (content-hash (value->string (list sel scope))) 0 10)))

;;; --- matching -----------------------------------------------------------

(define (permission--str x) (cond ((string? x) x) ((symbol? x) (symbol->string x)) (else "")))

(define (permission--name-match? want have)
  (let ((w (permission--str want)) (h (permission--str have)))
    (if (string-suffix? "*" w)
        (string-prefix? (substring w 0 (- (string-length w) 1)) h)
        (equal? w h))))

(define (permission--under? dir path)
  (let ((d (expand-file-name (permission--str dir))) (p (permission--str path)))
    (and (not (equal? p ""))
         (let ((p (expand-file-name p)))
           (or (equal? p d) (string-prefix? (if (string-suffix? "/" d) d (string-append d "/")) p))))))

(define (permission--facet-match? key want action)
  (cond ((equal? key 'kind) (equal? (permission--str want) (permission--str (plist-get action 'kind))))
        ((equal? key 'effect) (and (member (permission--str want) (or (plist-get action 'effects) '())) #t))
        ((member key '(domain package function))
         (permission--name-match? want (plist-get action key)))
        ((equal? key 'text)
         (let ((t (plist-get action 'text)) (p (permission--str want)))
           (and (string? t)
                (not (and (boundp (quote permission-pattern-suspended?)) (permission-pattern-suspended? p)))
                (re-match? p (string-downcase t)))))
        ((equal? key 'path) (permission--under? want (plist-get action 'path)))
        (else #f)))

(define (permission--selector-match? sel action)
  (let loop ((s sel))
    (cond ((or (null? s) (null? (cdr s))) #t)
          ((permission--facet-match? (car s) (cadr s) action) (loop (cddr s)))
          (else #f))))

(define (permission--task-open? id)
  (let ((t (and (boundp (quote todo-get)) (ignore-errors (lambda () (todo-get id))))))
    (and t (not (member (plist-get t 'state) '("done" "cancelled" "dropped"))) #t)))

(define (permission--scope-match? scope ctx)
  (cond ((or (not scope) (equal? scope 'everywhere)) #t)
        ((not (pair? scope)) #f)
        ((equal? (car scope) 'group) (equal? (cadr scope) (plist-get ctx 'group)))
        ((equal? (car scope) 'chat) (equal? (cadr scope) (plist-get ctx 'chat)))
        ((equal? (car scope) 'task)
         (and (equal? (cadr scope) (plist-get ctx 'task)) (permission--task-open? (cadr scope))))
        (else #f)))

;;; --- precedence ---------------------------------------------------------

(define *permission-facet-ranks* '((path 6) (function 5) (text 5) (package 4) (domain 3) (effect 2) (kind 1)))

(define (permission--facets sel)
  (if (or (null? sel) (null? (cdr sel))) '() (cons (car sel) (permission--facets (cddr sel)))))

(define (permission-rule-rank rule)
  "the rule's precedence as a list of numbers; the greater list wins"
  (let* ((sel (or (plist-get rule 'selector) '()))
         (fs (permission--facets sel))
         (top (apply max (cons 0 (map (lambda (f) (let ((r (assq f *permission-facet-ranks*))) (if r (cadr r) 0))) fs))))
         (scope (plist-get rule 'scope))
         (srank (cond ((not (pair? scope)) 0)
                      ((equal? (car scope) 'group) 1)
                      ((equal? (car scope) 'chat) 2)
                      ((equal? (car scope) 'task) 3)
                      (else 0))))
    (list top (length fs) (string-length (permission--str (plist-get sel 'path))) srank
          (permission--strictness (plist-get rule 'gives)))))

;; notify lets the call run and tells the user it ran: a relaxed rule that stays alert
(define (permission--strictness g)
  (cond ((equal? g 'deny) 3) ((equal? g 'ask) 2) ((equal? g 'notify) 1) (else 0)))

(define (permission--rank>? a b)
  (cond ((null? a) #f)
        ((> (car a) (car b)) #t)
        ((< (car a) (car b)) #f)
        (else (permission--rank>? (cdr a) (cdr b)))))

(define (permission--by-rank rules)
  "RULES, the winner first"
  (let insert ((rs rules) (out '()))
    (if (null? rs)
        out
        (insert (cdr rs)
                (let place ((xs out))
                  (cond ((null? xs) (list (car rs)))
                        ((permission--rank>? (permission-rule-rank (car rs)) (permission-rule-rank (car xs)))
                         (cons (car rs) xs))
                        (else (cons (car xs) (place (cdr xs))))))))))

(define (permission-explain action ctx)
  "every rule that matches ACTION in CTX, the winner first"
  (permission--by-rank
    (filter (lambda (r) (and (not (permission--expired? r))
                             (permission--scope-match? (plist-get r 'scope) ctx)
                             (permission--selector-match? (or (plist-get r 'selector) '()) action)))
            (permission-rules))))

(define (permission-decide action ctx)
  "the winning rule for ACTION in CTX, or #f when no rule matches"
  (let ((hits (permission-explain action ctx)))
    (and (pair? hits) (car hits))))

(define (permission-decide-all actions ctx)
  "(GIVES RULE ACTION) for the strictest action of ACTIONS, or #f when no rule matches any"
  (let loop ((as actions) (best #f))
    (if (null? as)
        best
        (let ((r (permission-decide (car as) ctx)))
          (loop (cdr as)
                (if (and r (or (not best) (> (permission--strictness (plist-get r 'gives))
                                             (permission--strictness (car best)))))
                    (list (plist-get r 'gives) r (car as))
                    best))))))

;;; --- actions ------------------------------------------------------------

(define (permission--entry-action kind name entry text)
  (list 'kind kind 'function name
        'package (and entry (plist-get entry 'package))
        'domain (and entry (plist-get entry 'domain))
        'effects (or (and entry (pair? (plist-get entry 'effects)) (plist-get entry 'effects))
                     (permission-classified name)
                     '("unknown"))
        'text text))

(define (permission-call-action name text)
  "the action of calling the Scheme function or command NAME"
  (let ((entry (or (catalog-entry 'function name) (catalog-entry 'command name))))
    ;; a name that changes something (it ends in !) and carries no stamp:
    ;; the model classifies it off the lane; until then it is unknown
    (when (and (not entry) (string-suffix? "!" name) (boundp (string->symbol name)))
      (permission-classify-later! name))
    (permission--entry-action 'call name entry text)))

(define *permission-shell-kind-effects*
  '((read ("read" "execute")) (edit ("write" "execute")) (build ("write" "execute"))
    (git ("write" "execute")) (jj ("write" "execute")) (other ("execute"))))

(define (permission-shell-action cmd kind)
  "the action of the shell command CMD, whose decide kind is KIND (read, edit, build, git, jj, other) or #f"
  (let ((fx (assq kind *permission-shell-kind-effects*)))
    (list 'kind 'shell 'function (permission-verb cmd) 'package "shell"
          'domain (and kind (symbol->string kind))
          'effects (if fx (cadr fx) '("execute" "unknown"))
          'text cmd)))

(define (permission-tool-action title text)
  "the action of a backend tool call TITLE"
  (let ((e (catalog-entry 'function title)))
    (list 'kind 'tool 'function title
          'package (and e (plist-get e 'package)) 'domain (and e (plist-get e 'domain))
          'effects (or (permission-tool-effects title) (and e (plist-get e 'effects)) '("unknown"))
          'text text)))

(define (permission-context buf)
  "(group G chat ID task T) of the chat BUF"
  (let ((ok (and (string? buf) (buffer-exists? buf))))
    (list 'group (and ok (buffer-group buf))
          'chat (and ok (buffer-local-value 'chat-id buf))
          'task (and ok (boundp (quote mcp-proxy--chat-task)) (mcp-proxy--chat-task buf)))))

;;; --- names with no stamp ------------------------------------------------
;;; A name with no catalog entry reads as unknown at once; the decision
;;; model classifies it off the lane and the answer is kept.

(define (permission-classified name) (registry-lookup 'permission-classified name #f))

(define (permission-classify-later! name)
  (unless (or (registry-lookup 'permission-classified name #f)
              (registry-lookup 'permission-classifying name #f)
              (not (boundp (quote decide-choice))))
    (registry-register! 'permission-classifying name #t)
    (task-run!
      (lambda ()
        (decide-choice (string-append "What does the editor function " name " do?")
                       '(pure "computes a value, touches nothing"
                         read "reads editor or file state"
                         write "changes buffers, files or settings"
                         destroy "deletes or kills something"
                         external "sends or fetches over the network"
                         execute "runs a process or a shell command")))
      (lambda (ok v)
        (let ((pick (and ok (pair? v) (plist-get v 'choice))))
          (when pick
            (registry-register! 'permission-classified name (list (permission--str pick)))))))))

;;; --- writing rules ------------------------------------------------------

(define (permission--locked-check r by)
  (when (and r (plist-get r 'lock) (not (equal? by "user")))
    (error "that rule is locked: only the user changes it, in M-x permissions")))

(define (permission-rule-add! sel scope gives &optional by why lock expires)
  "add or replace the rule for SEL at SCOPE; answers its id. EXPIRES (turns CHAT-ID END) makes it a pass"
  (permission-rules--ensure!)
  (let* ((scope (or scope 'everywhere))
         (id (permission-rules--id sel (if expires (list scope 'pass) scope))))
    (permission--locked-check (registry-lookup 'permission-rule id #f) by)
    (registry-register! 'permission-rule id
      (list 'id id 'selector sel 'scope scope 'gives gives
            'lock (and lock #t) 'by (or by "user") 'why (or why "")
            'expires (or expires #f)
            'created (format-time-string "%Y-%m-%d %H:%M")))
    (permission-rules--save!)
    id))

(define (permission-rule-remove! id &optional by)
  "take the rule ID back; a locked rule only the user takes back"
  (let ((r (permission-rule id)))
    (permission--locked-check r by)
    (and r (begin (registry-forget! 'permission-rule id) (permission-rules--save!) #t))))

(define (permission-rule-set! id key value &optional by)
  "change one field (gives, lock, why) of the rule ID"
  (let ((r (permission-rule id)))
    (permission--locked-check r by)
    (and r (begin (registry-register! 'permission-rule id (plist-put r key value))
                  (permission-rules--save!) #t))))

(define (permission-grant-selector action width)
  "the selector a card answer writes for ACTION: WIDTH is function, package or domain"
  (let ((k (plist-get action 'kind)))
    (cond ((and (equal? width 'package) (plist-get action 'package))
           (list 'kind k 'package (plist-get action 'package)))
          ((and (equal? width 'domain) (plist-get action 'domain))
           (append (list 'kind k 'domain (plist-get action 'domain))
                   (let ((fx (remove (lambda (e) (member e '("pure" "read"))) (or (plist-get action 'effects) '()))))
                     (if (pair? fx) (list 'effect (car fx)) '()))))
          (else (list 'kind k 'function (plist-get action 'function))))))

(define (permission-scope-of ctx scope)
  "SCOPE (everywhere, group, chat, task) made concrete from CTX, or #f when CTX lacks it"
  (cond ((equal? scope 'everywhere) 'everywhere)
        ((plist-get ctx scope) (list scope (plist-get ctx scope)))
        (else #f)))

(define (permission-describe-rule r)
  "one line: what the rule gives, for what, and where"
  (let ((sel (or (plist-get r 'selector) '())) (scope (plist-get r 'scope)))
    (string-append
      (permission--str (plist-get r 'gives)) " "
      (if (null? sel) "everything"
          (string-join (map (lambda (f) (string-append (symbol->string f) " " (permission--str (plist-get sel f))))
                            (permission--facets sel)) ", "))
      (if (pair? scope) (string-append " in " (symbol->string (car scope)) " " (permission--str (cadr scope))) " everywhere")
      (let ((e (plist-get r 'expires)))
        (if (pair? e)
            (let ((left (- (caddr e) (permission-turns (cadr e)))))
              (string-append " for " (number->string left) (if (= left 1) " more turn" " more turns")))
            ""))
      (if (plist-get r 'lock) " (locked)" ""))))

;;; --- the call gate ------------------------------------------------------
;;; The names an agent's eval may not reach without the user's answer: every
;;; catalog function or command a rule gives ask or deny when it is called,
;;; with the refusal to raise. The interpreter checks them when the eval
;;; looks one up (with-call-gate), so a function passed as a value, reached
;;; through apply or eval, or held in a variable meets the same rules as a
;;; call written out. Only rules that can match a call count; with none,
;;; the gate is empty and nothing is armed.

(define *permission-gated-effects* '("write" "destroy" "spend" "external" "execute" "unknown"))

(define (permission--call-rule? r)
  "#t when the rule R can match a call: no text or path facet, and its kind is call or unset"
  (let ((sel (or (plist-get r 'selector) '())))
    (and (not (plist-get sel 'text)) (not (plist-get sel 'path))
         (member (permission--str (or (plist-get sel 'kind) "call")) '("call"))
         #t)))

(define (permission--gate-candidates rules)
  "the names to judge: every function a rule names outright, and the stamped names that change something and match one of RULES; the action is built from the catalog row in hand, with no lookup per name"
  (append
    (apply append
      (map (lambda (r) (let ((f (plist-get (plist-get r 'selector) 'function)))
                         (if (and (string? f) (not (string-suffix? "*" f))) (list f) '())))
           rules))
    (apply append
      (map (lambda (e)
             (if (and (member (plist-get e 'kind) '("function" "command"))
                      (pair? (filter (lambda (x) (member x *permission-gated-effects*)) (or (plist-get e 'effects) '()))))
                 (let ((a (list 'kind 'call 'function (plist-get e 'name) 'package (plist-get e 'package)
                                'domain (plist-get e 'domain) 'effects (plist-get e 'effects))))
                   (if (pair? (filter (lambda (r) (permission--selector-match? (or (plist-get r 'selector) '()) a)) rules))
                       (list (plist-get e 'name)) '()))
                 '()))
           (catalog)))))

(define (permission--gate-refusal name rule)
  (string-append "refused at call time: " name " " (if (equal? (plist-get rule 'gives) 'deny) "is denied" "needs your permission")
                 " (" (permission-describe-rule rule) "). "
                 (if (equal? (plist-get rule 'gives) 'deny)
                     "M-x permissions changes the rule."
                     "Write the call out by its name in the code, so the permission card can ask before the eval runs.")))

(define (permission-call-gate ctx)
  "((NAME REFUSAL) ...) for every name a call rule gives ask or deny in CTX; cached until the rules, the catalog or CTX change"
  (let* ((rules (filter (lambda (r) (and (member (plist-get r 'gives) '(ask deny))
                                         (not (permission--expired? r))
                                         (permission--call-rule? r)
                                         (permission--scope-match? (plist-get r 'scope) ctx)))
                        (permission-rules)))
         (key (list (permission-rules-version) (catalog-generation)
                    (plist-get ctx 'group) (plist-get ctx 'chat) (plist-get ctx 'task)))
         (hit (registry-lookup 'permission-gate-cache (value->string (cdr (cdr key))) #f)))
    (cond ((null? rules) '())
          ((and hit (equal? (car hit) key)) (cadr hit))
          (else
           (let loop ((ns (permission--gate-candidates rules)) (seen '()) (out '()))
             (if (null? ns)
                 (begin (registry-register! 'permission-gate-cache (value->string (cdr (cdr key))) (list key out)) out)
                 (let ((n (car ns)))
                   (if (member n seen)
                       (loop (cdr ns) seen out)
                       (let ((r (permission-decide (permission-call-action n #f) ctx)))
                         (loop (cdr ns) (cons n seen)
                               (if (and r (member (plist-get r 'gives) '(ask deny)))
                                   (cons (list n (permission--gate-refusal n r)) out)
                                   out)))))))))))

(define (permission-call-trust ctx)
  "the names a rule names outright and allows in CTX: a call to one runs its insides unchecked"
  (apply append
    (map (lambda (r) (let ((f (plist-get (plist-get r 'selector) 'function)))
                       (if (and (string? f) (not (string-suffix? "*" f))
                                (member (plist-get r 'gives) '(allow notify))
                                (permission--call-rule? r)
                                (not (permission--expired? r))
                                (permission--scope-match? (plist-get r 'scope) ctx))
                           (list f) '())))
         (permission-rules))))

;;; --- passes -------------------------------------------------------------
;;; A pass is a chat rule that ends after some turns of its chat: 'expires
;;; (turns CHAT-ID END) holds while the chat has ended fewer than END turns.
;;; The count lives in memory, so a pass does not survive a restart; each
;;; turn end takes the passes it ended out of the store.

(define (permission-turns cid) (registry-lookup 'permission-turns cid 0))

(define (permission--expired? r)
  (let ((e (plist-get r 'expires)))
    (and (pair? e) (equal? (car e) 'turns)
         (>= (permission-turns (cadr e)) (caddr e)))))

(define (permission-pass-expires cid turns)
  "the 'expires of a pass for chat CID that lasts TURNS turns, this one included"
  (list 'turns cid (+ (permission-turns cid) turns)))

(define (permission-turn-ended! cid)
  "count a turn of chat CID, and take out the passes it ended"
  (when cid
    (registry-register! 'permission-turns cid (+ 1 (permission-turns cid)))
    (let ((gone (filter permission--expired? (permission-rules))))
      (when (pair? gone)
        (for-each (lambda (r) (registry-forget! 'permission-rule (plist-get r 'id))) gone)
        (permission-rules--save!)))))

(add-hook! (list 'agent-turn-end "permission-passes")
  (lambda (slug stop-reason ok?)
    (let ((buf (and (boundp (quote agent-buf)) (agent-buf slug))))
      (when (and buf (buffer-exists? buf))
        (permission-turn-ended! (buffer-local-value 'chat-id buf))))))

;;; --- migration ----------------------------------------------------------
;;; The seven stores that came before this engine become rules, once: when
;;; the engine first loads. The old stores stay as they were and
;;; nothing reads them after. It runs once: a rule it made stops it again.

(define (permission--verb-selector verb)
  "the selector of an old grant VERB: shell KIND, a deny pattern, or a tool name"
  (cond ((string-prefix? "shell " verb)
         (list 'kind 'shell 'domain (substring verb 6 (string-length verb))))
        ((and (boundp (quote *permission-deny-patterns*)) (member verb *permission-deny-patterns*))
         (list 'text verb))
        (else (list 'function verb))))

(define (permission-rules-migrate!)
  "make rules of the old stores; answers (added N dropped (RULE ...)). Runs once: a rule it made stops it"
  (if (pair? (filter (lambda (r) (equal? (plist-get r 'by) "migration")) (permission-rules)))
      (list 'added 0 'dropped '() 'skipped "already migrated")
      (let ((before (length (permission-rules))) (dropped '())
            (add! (lambda (sel scope gives why &optional lock)
                    (permission-rule-add! sel scope gives "migration" why lock))))
        ;; 1. the shell policy: one rule per kind, everywhere
        (when (boundp (quote decide-shell-policy))
          (for-each (lambda (row)
                      (add! (list 'kind 'shell 'domain (symbol->string (car row))) 'everywhere
                            (if (equal? (cadr row) 'refuse) 'deny (cadr row))
                            "was decide-shell-policy"))
                    decide-shell-policy))
        ;; 2. the deny patterns: locked asks; only the user changes them
        (when (boundp (quote *permission-deny-patterns*))
          (for-each (lambda (p) (add! (list 'text p) 'everywhere 'ask "was *permission-deny-patterns*" #t))
                    *permission-deny-patterns*))
        ;; 3. what a direct tool call that destroys or spends gets
        (add! (list 'kind 'tool 'effect "destroy") 'everywhere 'ask "a tool that destroys asks")
        (add! (list 'kind 'tool 'effect "spend") 'everywhere 'ask "a tool that spends asks")
        ;; 4. the folders a sandboxed shell writes
        (when (boundp (quote agent-sandbox-writable))
          (for-each (lambda (d) (add! (list 'kind 'shell 'effect "write" 'path d) 'everywhere 'allow
                                      "was agent-sandbox-writable"))
                    agent-sandbox-writable))
        ;; 5. the verbs a group answered Always for
        (when (boundp (quote group-counts))
          (for-each (lambda (gc)
                      (for-each (lambda (v) (add! (permission--verb-selector v) (list 'group (nth 2 gc)) 'allow
                                                  "was the group's Always"))
                                (or (group-setting (nth 2 gc) 'always-verbs) '())))
                    (group-counts)))
        ;; 6 and 7. a chat's task grants and its Always rules
        (for-each
          (lambda (c)
            (for-each (lambda (g)
                        (when (permission--task-open? (cadr g))
                          (add! (permission--verb-selector (car g)) (list 'task (cadr g)) 'allow
                                "was a For this task grant")))
                      (or (buffer-local-value 'task-grants c) '()))
            (let ((cid (buffer-local-value 'chat-id c)))
              (for-each (lambda (sig)
                          ;; a verb of a shell command carries over; a whole
                          ;; call matched only itself, so it goes
                          (if (and cid (< (length (string-split sig " ")) 3) (not (string-contains? sig ":")))
                              (add! (list 'kind 'shell 'function sig) (list 'chat cid) 'allow "was the chat's Always")
                              (set! dropped (cons (list c sig) dropped))))
                        (or (buffer-local-value 'permission-always-rules c) '()))))
          (filter (lambda (b) (equal? (buffer-local-value 'mode-name b) "chat-mode")) (buffer-list)))
        (permission-rules--save!)
        (list 'added (- (length (permission-rules)) before) 'dropped (reverse dropped)))))

(public! 'permission-rules "(permission-rules) — every permission rule, as plists (id selector scope gives lock by why)")
(public! 'permission-rule "(permission-rule ID) — one rule, or #f")
(public! 'permission-explain "(permission-explain ACTION CTX) — every rule that matches ACTION in CTX, the winner first")
(public! 'permission-decide "(permission-decide ACTION CTX) — the winning rule for ACTION in CTX, or #f")
(public! 'permission-decide-all "(permission-decide-all ACTIONS CTX) — (GIVES RULE ACTION) of the strictest action, or #f")
(public! 'permission-rule-rank "(permission-rule-rank RULE) — its precedence as numbers; greater wins")
(public! 'permission-call-action "(permission-call-action NAME TEXT) — the action of calling NAME, from its stamps")
(public! 'permission-shell-action "(permission-shell-action CMD KIND) — the action of a shell command of decide kind KIND")
(public! 'permission-tool-action "(permission-tool-action TITLE TEXT) — the action of a backend tool call")
(public! 'permission-context "(permission-context CHAT) — (group G chat ID task T) of a chat")
(public! 'permission-classified "(permission-classified NAME) — the effects the model gave an unstamped NAME, or #f")
(public! 'permission-describe-rule "(permission-describe-rule RULE) — the rule in one line")
(public! 'permission-grant-selector "(permission-grant-selector ACTION WIDTH) — the selector a card answer writes; WIDTH function, package or domain")
(public! 'permission-scope-of "(permission-scope-of CTX SCOPE) — everywhere, (group G), (chat ID) or (task T) from CTX")
(effects! '(write))
(public! 'permission-rule-add! "(permission-rule-add! SEL SCOPE GIVES [BY WHY LOCK]) — add or replace a rule; answers its id")
(public! 'permission-rule-remove! "(permission-rule-remove! ID [BY]) — take a rule back")
(public! 'permission-rule-set! "(permission-rule-set! ID KEY VALUE [BY]) — change one field of a rule")
(public! 'permission-turns "(permission-turns CHAT-ID) — how many turns the chat ended since the editor started")
(public! 'permission-pass-expires "(permission-pass-expires CHAT-ID TURNS) — the 'expires of a pass that lasts TURNS turns, this one included")
(public! 'permission-call-gate "(permission-call-gate CTX) — ((NAME REFUSAL) ...): the names a call rule gives ask or deny in CTX")
(public! 'permission-call-trust "(permission-call-trust CTX) — the names a rule allows outright in CTX")
(public! 'permission-rules-version "(permission-rules-version) — a number every change of the rules raises")
(public! 'permission-rules-migrate! "(permission-rules-migrate!) — make rules of the old permission stores, once")
(public! 'permission-classify-later! "(permission-classify-later! NAME) — ask the model for an unstamped name's effects, off the lane")
