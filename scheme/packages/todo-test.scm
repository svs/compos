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
                (check-true! (buffer-local chat 'subagent-notify) "the parent hears its turn ends")
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
