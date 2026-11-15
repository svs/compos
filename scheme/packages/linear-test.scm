;;; linear-test.scm --- Linear as a source of todos

(domain! 'testing)
(effects! '(read write))

(deftest 'linear-an-issue-back-from-review-opens-its-task-again
  "a status that leaves review for in progress, or a comment not ours, opens the task again; review itself, other changes and our own comments do not"
  (lambda ()
    (let ((calls '()))
      (with-stubs (list (list 'todo-of-source (lambda (key) (and (equal? key "linear:ZZ-1") (list 'id "zz-task" 'state "done"))))
                        (list 'todo-source-returned! (lambda (id reason who) (set! calls (cons (list id reason) calls)) #f)))
        (lambda ()
          (for-each linear--todo-returned!
            (list '(type "Issue" action "update" actor (name "Rev") updatedFrom (stateId "a") data (identifier "ZZ-1" state (name "In Review" type "started")))
                  '(type "Issue" action "update" actor (name "Rev") updatedFrom (priority 2) data (identifier "ZZ-1" state (name "In Progress" type "started")))
                  '(type "Issue" action "update" actor (name "Rev") updatedFrom (stateId "b") data (identifier "ZZ-1" state (name "In Progress" type "started")))
                  '(type "Comment" action "create" actor (name "Us") data (body "**Done** (todo zz-task)" issue (identifier "ZZ-1")))
                  '(type "Comment" action "create" actor (name "Rev") data (body "zz the label is wrong" issue (identifier "ZZ-1")))
                  '(type "Issue" action "update" actor (name "Rev") updatedFrom (stateId "c") data (identifier "ZZ-2" state (name "Todo" type "unstarted")))))))
      (check-equal! (reverse calls)
                    '(("zz-task" "Rev moved ZZ-1 back to In Progress in Linear.")
                      ("zz-task" "Rev commented on ZZ-1 in Linear:\n\nzz the label is wrong"))
                    "only the move back and the reviewer's comment open the task; an issue with no task is left alone"))))
