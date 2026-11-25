;;; permission-rules-test.scm --- the rule engine's contract: precedence and the first migration.

(domain! 'permissions)
(effects! '(read))

(deftest 'a-new-home-gets-the-old-stores-as-rules
  "the first use migrates: the deny patterns become locked asks, the shell policy one rule per kind"
  (lambda ()
    (let ((rules (map permission-describe-rule (permission-rules))))
      (check-true! (member "ask text \\bdeploy\\b everywhere (locked)" rules)
                   (string-append "a deny pattern is a locked ask; the rules: " (value->string rules)))
      (check-true! (pair? (filter (lambda (r) (and (equal? (plist-get r 'selector) (list 'kind 'shell 'domain "read"))
                                                   (equal? (plist-get r 'scope) 'everywhere)
                                                   (equal? (plist-get r 'by) "migration")))
                                  (permission-rules)))
                   "the shell policy gives each kind a rule"))))

(deftest 'the-most-specific-rule-wins
  "function over domain, narrow deny over wide allow, narrow scope over wide"
  (lambda ()
    (let* ((g "grp:zz-perm") (ctx (list 'group g 'chat "chat:zz-perm" 'task #f))
           (ids (list (permission-rule-add! (list 'kind 'call 'domain "writing" 'effect "write") (list 'group g) 'allow "test")
                      (permission-rule-add! (list 'function "todo-handover!") (list 'group g) 'ask "test")
                      (permission-rule-add! (list 'kind 'shell 'domain "read") (list 'chat "chat:zz-perm") 'allow "test")
                      (permission-rule-add! (list 'kind 'shell) (list 'chat "chat:zz-perm") 'allow "test")
                      (permission-rule-add! (list 'kind 'shell 'function "rm*") (list 'group g) 'deny "test")))
           (gives (lambda (a) (let ((r (permission-decide a ctx))) (and r (plist-get r 'gives))))))
      (check-equal! (gives (permission-call-action "todo-create" #f)) 'allow "a write in the domain runs")
      (check-equal! (gives (permission-call-action "todo-handover!" #f)) 'ask "its exception asks")
      (check-equal! (gives (permission-shell-action "ls" 'read)) 'allow "the chat's rule for the same kind beats the policy")
      (check-false! (equal? (gives (permission-shell-action "mix compile" 'edit)) 'allow)
                    "a wider chat rule loses to the policy's kind rule: the selector counts before the scope")
      (check-equal! (gives (permission-shell-action "rm -rf x" 'edit)) 'deny "a narrow deny beats a wide allow")
      (for-each (lambda (id) (permission-rule-remove! id)) ids))))
