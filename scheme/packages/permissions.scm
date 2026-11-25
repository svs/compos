;;; permissions.scm --- M-x permissions: every rule that decides what an agent may do.
;;;
;;; One row per rule of the engine (permission-rules.scm in agent-permissions).
;;; A rule names a selector (kind, effect, domain, package, function, text,
;;; path), a scope (everywhere, a group, a chat, a task) and gives allow,
;;; notify, ask or deny; the most specific rule wins. a adds a rule, k takes
;;; one back, c gives it its next answer, l locks or unlocks it. A locked rule
;;; only the user changes; a card never writes over it.

(require 'tabulated-list)

(domain! 'chat)
(effects! '(read))
(category! 'chat)

(define *permissions-buffer* "*permissions*")

(define (permissions--list) (list-mode-group-buffer "permissions-mode"))

(define (permissions--scope-label scope)
  (cond ((not (pair? scope)) "everywhere")
        ((equal? (car scope) 'group)
         (string-append "group " (or (and (boundp 'group-name) (group-name (cadr scope))) (cadr scope))))
        ((equal? (car scope) 'task)
         (string-append "task " (cadr scope)
                        (if (permission--task-open? (cadr scope)) "" " (ended)")))
        (else (string-append (symbol->string (car scope)) " " (permission--str (cadr scope))))))

(define (permissions--selector-label sel)
  (if (or (not sel) (null? sel))
      "everything"
      (let ((s (string-join (map (lambda (f) (string-append (symbol->string f) " " (permission--str (plist-get sel f))))
                                 (permission--facets sel))
                            ", ")))
        (if (> (string-length s) 70) (string-append (substring s 0 70) "...") s))))

(define (permissions--rows buf) (permission-rules))

(define (permissions--cells buf r)
  (list (permission--str (plist-get r 'gives))
        (permissions--scope-label (plist-get r 'scope))
        (string-append (if (plist-get r 'lock) "locked " "") (permission--str (plist-get r 'by)))
        (permissions--selector-label (plist-get r 'selector))))

(define (permissions--detail-text r)
  (let ((sel (or (plist-get r 'selector) '())))
    (string-append
      (permission-describe-rule r) "\n\n"
      "gives     " (permission--str (plist-get r 'gives)) "\n"
      "where     " (permissions--scope-label (plist-get r 'scope)) "\n"
      (apply string-append
        (map (lambda (f) (string-append (string-pad-right (symbol->string f) 10) (permission--str (plist-get sel f)) "\n"))
             (permission--facets sel)))
      "made by   " (permission--str (plist-get r 'by)) "  " (permission--str (plist-get r 'created)) "\n"
      "rank      " (string-join (map number->string (permission-rule-rank r)) " ")
      "  (facet, facets, path, scope, strictness: the greater wins)\n\n"
      (permission--str (plist-get r 'why)) "\n\n"
      (if (plist-get r 'lock)
          "Locked: only you change it, here. l unlocks it.\n"
          "k takes it back, c gives it the next answer (allow, notify, ask, deny), l locks it.\n")
      (if (equal? (plist-get sel 'kind) 'shell)
          "A shell rule judges shell commands only; an agent reads and edits through editor calls.\n"
          "")
      "\n────\nend\n")))

(effects! '(write display))

(define (permissions--detail-buffer r) (string-append "*permission:" (plist-get r 'id) "*"))

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
  (let ((r (or (buffer-local-value 'permission-row (current-buffer))
               (let ((l (permissions--list))) (and (buffer-exists? l) (list-current l))))))
    ;; the page may hold an old copy: read the rule as it is now
    (and r (permission-rule (plist-get r 'id)))))

(define (permissions--redraw! &optional r)
  (let ((l (permissions--list))) (when (buffer-exists? l) (list-refresh! l)))
  (let ((now (and r (permission-rule (plist-get r 'id)))))
    (when (and now (buffer-known? (permissions--detail-buffer now)))
      (buffer-set-local! (permissions--detail-buffer now) 'permission-row now)
      (buffer-set-text! (permissions--detail-buffer now) (permissions--detail-text now) #t))))

(define *permissions-answers* '(allow notify ask deny))

(define (permissions-parse-rule text group)
  "(SEL SCOPE GIVES) from TEXT: GIVES FACET VALUE[, FACET VALUE...] [in everywhere|group|chat ID|task ID]; group means GROUP"
  (let* ((parts (string-split (string-trim text) " in "))
         (head (string-trim (car parts)))
         (where (and (pair? (cdr parts)) (string-trim (cadr parts))))
         (gives (string->symbol (car (string-split head " "))))
         (rest (string-trim (substring head (string-length (symbol->string gives)) (string-length head))))
         (sel (apply append
                (map (lambda (clause)
                       (let* ((c (string-trim clause))
                              (sp (string-search " " c)))
                         (if (or (equal? c "") (not sp) (equal? c "everything"))
                             '()
                             (let ((f (string->symbol (substring c 0 sp))) (v (string-trim (substring c sp (string-length c)))))
                               (list f (if (equal? f 'kind) (string->symbol v) v))))))
                     (string-split rest ","))))
         (scope (cond ((or (not where) (equal? where "everywhere")) 'everywhere)
                      ((equal? where "group") (list 'group group))
                      (else (let ((w (string-split where " ")))
                              (list (string->symbol (car w)) (string-join (cdr w) " ")))))))
    (if (and (member gives *permissions-answers*)
             (every (lambda (f) (assq f *permission-facet-ranks*)) (permission--facets sel)))
        (list sel scope gives)
        #f)))

(define-list-mode! "permissions-mode"
  (list
    'doc (string-append
           "Every rule that decides what an agent may do. A rule names what it selects (kind, effect, domain, "
           "package, function, text, path), where it holds (everywhere, a group, a chat, a task) and what it gives: "
           "allow, notify (runs and tells you), ask or deny. The most specific rule wins: path, then function or text, "
           "then package, domain, effect and kind; then more facets; then the narrower scope; then the stricter answer. "
           "a adds a rule, k takes one back, c gives it the next answer, l locks or unlocks it, RET shows its page, "
           "/ narrows, g reads them again, q quits.")
    'buffer *permissions-buffer*
    'transient #f
    'rows permissions--rows
    'key (lambda (buf r) (plist-get r 'id))
    'local-filter #t
    'tabs (list (list "all" (lambda (buf r) #t))
                (list "granted" (lambda (buf r) (pair? (plist-get r 'scope))))
                (list "everywhere" (lambda (buf r) (not (pair? (plist-get r 'scope)))))
                (list "locked" (lambda (buf r) (and (plist-get r 'lock) #t))))
    'body (lambda (buf r) (permissions--detail-text r))
    'columns (lambda (buf) (list (list "gives" 7) (list "where" 26) (list "by" 16) (list "rule" #f)))
    'cells permissions--cells
    'preview (lambda (buf row) (permissions-show-detail! row))
    'title (lambda (buf) "Permissions")
    'noun "rule"
    'footer (lambda (buf) '(("RET" "page") ("a" "add") ("k" "take back") ("c" "next answer") ("l" "lock") ("/" "filter") ("g" "read again") ("q" "quit")))
    'keys '(("RET" "permissions-show") ("a" "permissions-add") ("k" "permissions-revoke") ("c" "permissions-cycle")
            ("l" "permissions-lock") ("g" "permissions-refresh") ("q" "quit-window"))))

(define-mode "permissions-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "permissions-detail-mode"
            '(("k" "permissions-revoke") ("c" "permissions-cycle") ("l" "permissions-lock") ("g" "permissions-refresh")))
(mode-doc! "permissions-detail-mode" "One permission rule: what it selects, where it holds, what it gives, and why. k takes it back, c gives it the next answer, l locks or unlocks it, g reads it again.")

(define-command "permissions" "Open every rule that decides what an agent may do"
  (lambda () (list-mode-show! "permissions-mode")))

(define-command "permissions-show" "Show the rule at point as its own page beside the list"
  (lambda () (permissions-show-detail! (permissions--at)))
  'modes '(permissions-mode))

(define-command "permissions-refresh" "Read the rules again"
  (lambda () (permissions--redraw!))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-add" "Add a rule, such as: ask function todo-handover! in group"
  (interactive "sRule (GIVES FACET VALUE, ... in everywhere|group|chat ID|task ID): ")
  (lambda (text)
    (let ((parsed (permissions-parse-rule text (buffer-group (permissions--list)))))
      (if (not parsed)
          (message "not a rule: say allow|notify|ask|deny, then facets such as function todo-handover!, then in group")
          (let ((id (permission-rule-add! (car parsed) (cadr parsed) (caddr parsed) "user" "added in M-x permissions")))
            (message (string-append "added: " (permission-describe-rule (permission-rule id))))
            (permissions--redraw!)))))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-revoke" "Take back the rule at point"
  (lambda ()
    (let ((r (permissions--at)))
      (if (not r)
          (message "no rule here")
          (begin (permission-rule-remove! (plist-get r 'id) "user")
                 (message (string-append "took back: " (permission-describe-rule r)))
                 (permissions--redraw!)))))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-cycle" "Give the rule at point its next answer: allow, notify, ask, deny"
  (lambda ()
    (let ((r (permissions--at)))
      (if (not r)
          (message "no rule here")
          (let* ((tail (member (plist-get r 'gives) *permissions-answers*))
                 (next (if (and tail (pair? (cdr tail))) (cadr tail) (car *permissions-answers*))))
            (permission-rule-set! (plist-get r 'id) 'gives next "user")
            (message (string-append "now: " (permission-describe-rule (permission-rule (plist-get r 'id)))))
            (permissions--redraw! r)))))
  'modes '(permissions-mode permissions-detail-mode))

(define-command "permissions-lock" "Lock or unlock the rule at point: a locked rule only you change"
  (lambda ()
    (let ((r (permissions--at)))
      (if (not r)
          (message "no rule here")
          (begin (permission-rule-set! (plist-get r 'id) 'lock (not (plist-get r 'lock)) "user")
                 (message (string-append "now: " (permission-describe-rule (permission-rule (plist-get r 'id)))))
                 (permissions--redraw! r)))))
  'modes '(permissions-mode permissions-detail-mode))

(public! 'permissions-show-detail! "(permissions-show-detail! ROW) — show the page of a permissions rule beside the list")
(public! 'permissions-parse-rule "(permissions-parse-rule TEXT GROUP) — (SEL SCOPE GIVES) from a rule typed as GIVES FACET VALUE, ... in SCOPE")

(provide 'permissions)
