;;; file-group-context-test.scm --- File visits receive their context explicitly.

(domain! 'testing)
(effects! '(write))

(define (t--fgc-drop-dispatcher! slug)
  (set! *chat-dispatchers*
    (remove (lambda (entry) (equal? (car entry) slug)) *chat-dispatchers*)))

(deftest 'an-explicit-file-group-adds-membership-without-moving-the-file
  "an existing file can join another group while it keeps its first group"
  (lambda ()
    (let* ((path "/tmp/aimax-zz-file-context.txt")
           (first (group-record-create! "zz-file-context-first"))
           (second (group-record-create! "zz-file-context-second")))
      (write-file! path "context\n")
      (visit path first)
      (visit path second)
      (check-true! (buffer-in-group? path first) "the first membership remains")
      (check-true! (buffer-in-group? path second) "the second membership joins it")
      (buffer-kill! path)
      (delete-file! path)
      (group-record-delete! first)
      (group-record-delete! second))))

(deftest 'a-file-visit-without-a-group-does-not-borrow-the-selected-frame-group
  "desktop and headless visits stay ungrouped unless the caller passes a group"
  (lambda ()
    (let* ((path "/tmp/aimax-zz-raw-file-context.txt")
           (work (test-buffer! "*zz-file-context-work*" ""))
           (group (group-record-create! "zz-raw-file-context")))
      (write-file! path "raw\n")
      (buffer-add-group! work group)
      (switch-to-buffer! work)
      (set-frame-local! 'current-group group)
      (visit path)
      (check-equal! (buffer-group-ids path) '() "the visit did not infer the frame group")
      (buffer-kill! path)
      (buffer-kill! work)
      (delete-file! path)
      (group-record-delete! group))))

(deftest 'a-direct-agent-file-visit-uses-the-originating-chat-group
  "the user can switch buffers while the agent keeps its chat context"
  (lambda ()
    (let* ((path "/tmp/aimax-zz-agent-file-context.txt")
           (slug "zz-file-context-agent")
           (agent-group (group-record-create! "zz-agent-file-context"))
           (user-group (group-record-create! "zz-user-file-context"))
           (chat (group-chat agent-group))
           (user (test-buffer! "*zz-file-context-user*" "")))
      (write-file! path "agent\n")
      (buffer-set-local! chat 'agent-slug slug)
      (buffer-add-group! user user-group)
      (switch-to-buffer! user)
      (set-frame-local! 'current-group user-group)
      (t--fgc-drop-dispatcher! slug)
      ((chat-tool-dispatch slug) "eval-scheme"
        (list 'code
          "(visit \"/tmp/aimax-zz-agent-file-context.txt\" (buffer-group (current-buffer)))"))
      (check-true! (buffer-in-group? path agent-group) "the file joined the chat group")
      (check-false! (buffer-in-group? path user-group) "the selected frame group did not leak")
      (check-equal! (current-buffer) user "the tool did not replace the user's buffer")
      (t--fgc-drop-dispatcher! slug)
      (buffer-kill! path)
      (buffer-kill! user)
      (buffer-kill! chat)
      (delete-file! path)
      (group-record-delete! agent-group)
      (group-record-delete! user-group))))
