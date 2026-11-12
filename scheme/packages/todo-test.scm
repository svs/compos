;;; todo-test.scm --- the todo list's policy.

(domain! 'testing)
(effects! '(read write))

(deftest 'todo-chat-event-redraws-only-when-the-card-changes
  "a second event that leaves the chat-status row the same asks for no redraw"
  (lambda ()
    (let ((topic (string-append "chat:todo-test-" (number->string (current-time)))))
      (check-equal! (todo--chat-changed? topic) #t "the first event changes the card")
      (check-equal! (todo--chat-changed? topic) #f "the same row changes nothing")
      (set! *todo-chat-sigs* (filter (lambda (s) (not (equal? (car s) topic))) *todo-chat-sigs*)))))


;; the files a pattern names: file-glob walks, todo-skip-directories decides
(deftest 'todo-glob-reaches-any-depth-and-skips-the-named-folders
  "** finds a todos.md at each depth, and enters no skipped folder and no dot folder"
  (lambda ()
    (let ((root (string-append "/tmp/zz-todo-glob-" (number->string (current-time))
                               "-" (number->string (random 100000)))))
      (for-each (lambda (d)
                  (make-directory! (string-append root d))
                  (write-file! (string-append root d "/todos.md") "# zz\n"))
                '("/a" "/a/b" "/node_modules" "/a/.hidden"))
      (write-file! (string-append root "/a/notes.md") "zz\n")
      (check-equal! (todo--glob (string-append root "/**/todos.md"))
                    (list (string-append root "/a/todos.md") (string-append root "/a/b/todos.md"))
                    "the two files outside the skipped folders, the shallow one first")
      (check-equal! (todo--glob (string-append root "/*/*.md"))
                    (list (string-append root "/a/notes.md") (string-append root "/a/todos.md")
                          (string-append root "/node_modules/todos.md"))
                    "* stays in one name and skips nothing by name")
      (check-equal! (todo--glob (string-append root "/none/**/todos.md")) '()
                    "a folder that is not there names no file"))))

(deftest 'todo-directories-default-follows-the-compos-home
  "a daemon with a home of its own finds and files its todos in that home, not in ~/.compos"
  (lambda ()
    (check-equal! (plist-get (cadr (assoc 'todo-directories *custom-vars*)) 'default)
                  (list (string-append (compos-home) "/**/todos.md"))
                  "the default is the home of this daemon")
    (with-stubs (list (list 'compos-home (lambda () "/tmp/zz-todo-home")))
      (lambda ()
        (check-equal! (todo--home-directories) '("/tmp/zz-todo-home/**/todos.md")
                      "the default follows a home that COMPOS_HOME names")
        (with-stubs (list (list 'todo-directories (todo--home-directories))
                          (list 'todo--files (lambda () '())))
          (lambda ()
            (check-equal! (todo--project-file "zz-new")
                          "/tmp/zz-todo-home/zz-new/todos.md"
                          "a new project's file goes under that home")))))))

(deftest 'a-pane-page-counts-no-tasks-until-the-todo-files-are-found
  "a page that draws when its buffer wakes does not start the walk of the folders"
  (lambda ()
    (with-stubs (list (list 'todo-ready? (lambda () #f))
                      (list 'todo-list (lambda args (error "the page read the todo list"))))
      (lambda () (check-equal! (pane-home--review-count) 0 "0 and no read of the list")))
    (with-stubs (list (list 'todo-ready? (lambda () #t))
                      (list 'frame-group (lambda () #f))
                      (list 'todo-list (lambda args '((id "zz-1") (id "zz-2")))))
      (lambda () (check-equal! (pane-home--review-count) 2 "the count, once the files are found")))))

;; todo-assign-chat!: a new chat shows nowhere until asked, is the calling
;; agent's subagent, and a kept chat gives way when its backend is gone or
;; its connector is not the group's now.

(define t--todo-runs 0)

(define (t--todo-in-group fn)
  ;; FN gets a fresh group and a task filed in it, under a scratch todo dir
  ;; of its own: two runs in one second must not share a file
  (set! t--todo-runs (+ t--todo-runs 1))
  (let ((old todo-directories)
        (dir (string-append "/tmp/zz-todo-test-" (number->string (current-time))
                            "-" (number->string t--todo-runs) "/*.md")))
    (unwind-protect
      (lambda ()
        (set! todo-directories (list dir))
        (todo--rescan!)
        (with-fresh-group "zz-todo-assign"
          (lambda (g) (fn g (todo-create "zz assigned task" (list 'group g 'project "zz"))))))
      (lambda () (set! todo-directories old) (todo--rescan!)))))

(define (t--todo-assign id g &optional status)
  ;; the brief starts no backend; it names the chat's slug as a start would
  (with-stubs (list (list 'agent-continue!
                          (lambda (c text) (buffer-set-local! c 'agent-slug (string-append "zz-slug-" c))))
                    (list 'agent-status (lambda (slug) (or status 'idle))))
    (lambda () (todo-assign-chat! id g))))

(deftest 'todo-a-sub-task-result-lands-on-the-task-and-its-parent
  "the task is the record: a review summary is the sub-task's status and goes to the parent's log"
  (lambda ()
    (t--todo-in-group
      (lambda (g parent)
        (let ((sub (todo-create "zz sub-task" (list 'group g 'project "zz" 'parent parent))))
          (todo-review sub "zz measured 3 rounds\nmore detail" "agent:zz")
          (check-equal! (plist-get (todo-get sub) 'status) "zz measured 3 rounds\nmore detail"
                        "the summary is the sub-task's status, both lines, read back from the file")
          (todo-review sub "" "agent:zz")
          (check-equal! (plist-get (todo-get sub) 'status) "zz measured 3 rounds\nmore detail"
                        "a blank summary keeps the status")
          (check-true! (any (lambda (l) (string-contains? l (string-append "sub-task " sub " zz sub-task -> review: zz measured 3 rounds")))
                            (plist-get (todo-get parent) 'log))
                       "the parent's log names the sub-task, its state and the summary's first line")
          (todo-log sub "zz progress" "agent:zz")
          (check-equal! (length (filter (lambda (l) (string-contains? l "sub-task ")) (plist-get (todo-get parent) 'log))) 1
                        "progress without a state change stays on the sub-task"))))))

(deftest 'todo-handover-archives-the-chat-and-a-new-one-takes-the-task
  "the old chat goes, a new chat is the assignee, and the task no longer names the old one"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (let* ((old (t--todo-assign id g))
               (old-ref (chat-stable-id! old))
               (new (with-stubs (list (list 'agent-continue!
                                            (lambda (c text) (buffer-set-local! c 'agent-slug (string-append "zz-slug-" c))))
                                      (list 'agent-status (lambda (slug) 'idle))
                                      ;; the test chat runs no agent to stop
                                      (list 'agents-kill-runtime! (lambda (c) #f)))
                      (lambda () (todo-handover! id "agent:zz"))))
               (t (todo-get id)))
          ;; the new chat takes the task's title, so it may reuse the old name: compare ids
          (check-true! (and (string? new) (buffer-exists? new) (not (equal? (chat-stable-id! new) old-ref)))
                       "a new chat took the task")
          (check-false! (find (lambda (b) (equal? (buffer-local-value 'chat-id b) old-ref)) (buffer-list))
                        "the old chat is archived")
          (check-equal! (plist-get t 'assignee) (chat-stable-id! new) "the task names the new chat")
          (check-false! (member old-ref (or (plist-get t 'chats) '())) "the old chat is off the task")
          (check-true! (any (lambda (l) (string-contains? l (string-append "handed over: " old-ref))) (plist-get t 'log))
                       "the log says who handed over")
          (buffer-kill! new))))))

(deftest 'todo-handover-of-a-running-chat-waits-for-its-turn-end
  "a chat that hands over its own task finishes its turn first"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (let* ((old (t--todo-assign id g))
               (said (with-stubs (list (list 'agent-status (lambda (slug) 'running)))
                       (lambda () (todo-handover! id "agent:zz")))))
          (check-true! (string? said) "it answers a note, not a chat")
          (check-true! (buffer-exists? old) "the chat stays until its turn ends")
          (check-equal! (buffer-local-value 'todo-handover old) (list id "agent:zz") "the handover waits on the chat")
          (buffer-kill! old))))))

(deftest 'todo-assign-chat-shows-the-new-chat-in-no-window
  "the chat starts quiet, in no frame of its group or another, until someone shows it"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (let ((chat (t--todo-assign id g)))
          (check-equal! (buffer-group chat) g "the chat is in the task's group")
          (check-true! (buffer-context-only? chat) "panes leaves it out until a show promotes it")
          (check-false! (member chat (map cadr (with-frame-windows (lambda () (window-list-all)))))
                        "no window shows it")
          (buffer-kill! chat))))))

(deftest 'todo-assign-chat-from-an-agent-records-the-spawn-edge
  "the agent that starts the task is the new chat's parent, by the chat's slug"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (let ((edge #f))
          (with-stubs (list (list 'subagent-spawner (lambda () "zz-parent"))
                            (list 'subagent-record!
                                  (lambda (p c) (set! edge (list p (agent-slug-of c))))))
            (lambda ()
              (let ((chat (t--todo-assign id g)))
                (check-equal! edge (list "zz-parent" (agent-slug-of chat))
                              "the edge names the chat's slug")
                (check-true! (string-prefix? "zz-slug-" (cadr edge))
                             "recorded once the brief gave the chat its slug, not its buffer name")
                (check-true! (buffer-local-value 'subagent-notify chat) "the parent hears its turn ends")
                (buffer-kill! chat)))))))))

(deftest 'todo-assign-chat-reuses-a-kept-chat-only-while-it-is-current
  "a live chat on the group's connector goes on; a dead one or another connector gives way"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (let* ((want (or (plist-get (llm-group-bundle g) 'connector) *default-connector*))
               (first (t--todo-assign id g)))
          (buffer-set-local! first 'agent-connector want)
          (check-equal! (t--todo-assign id g) first "a live chat on the group's connector is kept")
          (let ((second (t--todo-assign id g 'dead)))
            (check-false! (equal? second first) "a chat whose backend is gone gives way")
            (buffer-set-local! second 'agent-connector "zz-other-connector")
            (let ((third (t--todo-assign id g)))
              (check-false! (equal? third second) "a chat on another connector gives way")
              (for-each (lambda (c) (when (buffer-known? c) (buffer-kill! c))) (list first second third)))))))))

(deftest 'todo-assign-chat-a-person-starts-is-listed-after-the-command
  "no window at birth; in the chat lists once the command ends"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (with-stub 'subagent-spawner (lambda () #f)
          (lambda ()
            (let ((chat (t--todo-assign id g)))
              (check-true! (buffer-context-only? chat) "out of panes' placement while the command runs")
              (chat-quiet--list!)
              (check-false! (buffer-context-only? chat) "listed once the command ends")
              (check-false! (member chat (map cadr (with-frame-windows (lambda () (window-list-all)))))
                            "and still in no window")
              (buffer-kill! chat))))))))

(deftest 'todo-assign-chat-an-agent-starts-stays-out-of-the-lists
  "an agent's chat, by eval or by WHO, is hidden until . or a show asks for it"
  (lambda ()
    (t--todo-in-group
      (lambda (g id)
        (with-stub 'subagent-record! (lambda (p c) #f)
          (lambda ()
            (let ((by-eval (with-stub 'subagent-spawner (lambda () "zz-parent")
                             (lambda () (t--todo-assign id g)))))
              (chat-quiet--list!)
              (check-true! (buffer-context-only? by-eval) "the eval's agent: hidden after the command")
              (buffer-kill! by-eval))
            (let ((by-who (with-stubs (list (list 'subagent-spawner (lambda () #f))
                                            (list 'agent-continue!
                                                  (lambda (c text) (buffer-set-local! c 'agent-slug (string-append "zz-slug-" c))))
                                            (list 'agent-status (lambda (s) 'dead)))
                            (lambda () (todo-assign-chat! id g "agent:zz-parent")))))
              (chat-quiet--list!)
              (check-true! (buffer-context-only? by-who) "WHO agent:...: hidden after the command")
              (buffer-kill! by-who))))))))
