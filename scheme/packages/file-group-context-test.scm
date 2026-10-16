;;; file-group-context-test.scm --- File visits receive their context explicitly.

(domain! 'testing)
(effects! '(write))

(define (t--fgc-drop-dispatcher! slug)
  (set! *chat-dispatchers*
    (remove (lambda (entry) (equal? (car entry) slug)) *chat-dispatchers*)))

(define (t--fgc-confirm! text)
  (minibuffer-change! text)
  (run-command "minibuffer-confirm-input"))

(define (t--fgc-cancel!)
  (run-command "minibuffer-cancel"))

(deftest 'an-explicit-file-group-moves-the-file-there
  "a buffer is in one group: a visit with a destination moves a live file, it does not add a membership (ruling 2026-10-16)"
  (lambda ()
    (with-fresh-group "zz-file-context-first"
      (lambda (first)
        (with-fresh-group "zz-file-context-second"
          (lambda (second)
            (let ((path "/tmp/compos-zz-file-context.txt"))
              (write-file! path "context\n")
              (visit path first)
              (visit path second)
              (check-false! (buffer-in-group? path first) "the first membership is gone")
              (check-true! (buffer-in-group? path second) "the file is in the destination")
              (check-equal! (buffer-group path) second "and in nothing else")
              (buffer-kill! path)
              (delete-file! path))))))))

(deftest 'a-new-file-visit-without-an-explicit-group-uses-current-group
  "the shared creation hook places a new file in the visible context"
  (lambda ()
    (with-fresh-group "zz-raw-file-context"
      (lambda (group)
        (let ((path "/tmp/compos-zz-raw-file-context.txt")
              (work (test-buffer! "*zz-file-context-work*" "")))
          (write-file! path "raw\n")
          (buffer-add-group! work group)
          (switch-to-buffer! work)
          (set-frame-local! 'current-group group)
          (visit path)
          (check-true! (buffer-in-group? path group)
                       "the new file inherits current-group")
          (buffer-kill! path)
          (buffer-kill! work)
          (delete-file! path))))))

(deftest 'interactive-find-file-joins-the-current-group
  "a new or reopened buffer joins the current group (the ruling of 2026-09-22)"
  (lambda ()
    (with-fresh-group "zz-find-current"
      (lambda (current)
        (with-fresh-group "zz-find-other"
          (lambda (other)
            (let ((new-path "/tmp/compos-zz-new-current-group.txt")
                  (live-path "/tmp/compos-zz-live-current-group.txt"))
              (write-file! new-path "new\n")
              (write-file! live-path "live\n")
              (visit live-path other)
              (set-frame-local! 'current-group current)

              (find-file-read current)
              (t--fgc-confirm! new-path)
              (check-true! (buffer-in-group? new-path current)
                           "a newly opened buffer joins current-group")

              (find-file-read current)
              (t--fgc-confirm! live-path)
              (check-true! (buffer-in-group? live-path current)
                           "a reopened buffer joins current-group")
              (check-false! (buffer-in-group? live-path other)
                            "and leaves the group it was in")

              (buffer-kill! new-path)
              (buffer-kill! live-path)
              (delete-file! new-path)
              (delete-file! live-path))))))))

(deftest 'cancelled-find-file-changes-no-membership
  "cancelling the file prompt leaves the visible context unchanged"
  (lambda ()
    (with-fresh-group "zz-cancelled-file-group"
      (lambda (group)
        (let ((path "/tmp/compos-zz-cancelled-current-group.txt")
              (work (test-buffer! "*zz-cancelled-file-work*" "")))
          (buffer-add-group! work group)
          (switch-to-buffer! work)
          (set-frame-local! 'current-group group)
          (find-file-read group)
          (minibuffer-change! path)
          (t--fgc-cancel!)
          (check-false! (buffer-known? path) "the cancelled file has no buffer")
          (check-equal! (buffer-group work) group
                        "the existing membership stays unchanged")
          (check-equal! (frame-group) group "the visible context stays unchanged")
          (buffer-kill! work))))))

(deftest 'failed-find-file-changes-no-membership
  "a malformed remote visit creates no buffer and changes no group"
  (lambda ()
    (with-fresh-group "zz-failed-file-group"
      (lambda (group)
        (let ((path "/ssh::/compos-zz-failed-file")
              (work (test-buffer! "*zz-failed-file-work*" "")))
          (buffer-add-group! work group)
          (switch-to-buffer! work)
          (set-frame-local! 'current-group group)
          (find-file-read group)
          (t--fgc-confirm! path)
          (check-false! (buffer-known? path) "the failed file has no buffer")
          (check-equal! (buffer-group work) group
                        "the existing membership stays unchanged")
          (check-equal! (current-buffer) work "the failed visit keeps the work buffer")
          (buffer-kill! work))))))

(deftest 'find-file-in-new-group-creates-and-enters-the-context
  "the direct new-context command creates the file and group as one action"
  (lambda ()
    (let ((path "/tmp/compos-zz-file-in-new-group.txt"))
      (write-file! path "context\n")
      (run-command "find-file-in-new-group")
      (t--fgc-confirm! path)
      (t--fgc-confirm! "zz-file-new-group")
      (let ((id (group-resolve-id "zz-file-new-group")))
        (check-true! id "the group was created")
        (check-true! (buffer-in-group? path id) "the file belongs to it")
        (check-equal! (frame-group) id "the new group was entered")
        (check-equal! (current-buffer) path "the file is selected")
        (buffer-kill! path)
        (delete-file! path)
        (group-record-delete! id)))))

(deftest 'find-file-in-new-group-moves-a-live-file-there
  "a live file moves to the new group; a buffer is in one group (ruling 2026-10-16)"
  (lambda ()
    (with-fresh-group "zz-live-file-old-group"
      (lambda (old)
        (let ((path "/tmp/compos-zz-live-file-new-group.txt"))
          (write-file! path "live\n")
          (visit path old)
          (run-command "find-file-in-new-group")
          (t--fgc-confirm! path)
          (t--fgc-confirm! "zz-live-file-new-group")
          (let ((new (group-resolve-id "zz-live-file-new-group")))
            (check-false! (buffer-in-group? path old) "the old membership is gone")
            (check-true! (buffer-in-group? path new) "the file is in the new group")
            (check-equal! (frame-group) new "the new group is entered")
            (buffer-kill! path)
            (delete-file! path)
            ;; the group's chat would otherwise outlive the record and become
            ;; the current buffer of a later test
            (when (buffer-known? "*chat:zz-live-file-new-group*")
              (buffer-kill! "*chat:zz-live-file-new-group*"))
            (group-record-delete! new)))))))

(deftest 'find-file-in-new-group-rejects-a-duplicate-before-visiting
  "a duplicate name creates no file buffer and changes no group"
  (lambda ()
    (with-fresh-group "zz-duplicate-file-group"
      (lambda (existing)
        (let ((path "/tmp/compos-zz-duplicate-file-new-group.txt"))
          (write-file! path "duplicate\n")
          (run-command "find-file-in-new-group")
          (t--fgc-confirm! path)
          (t--fgc-confirm! "zz-duplicate-file-group")
          (check-false! (buffer-known? path) "the command does not visit the file")
          (check-equal! (group-resolve-id "zz-duplicate-file-group") existing
                        "the existing record remains the only record")
          (delete-file! path))))))

(deftest 'find-file-in-new-group-cancels-at-either-prompt
  "cancelling either prompt creates no group and visits no file"
  (lambda ()
    (let ((path "/tmp/compos-zz-cancel-file-new-group.txt"))
      (write-file! path "cancel\n")

      (run-command "find-file-in-new-group")
      (minibuffer-change! path)
      (t--fgc-cancel!)
      (check-false! (buffer-known? path) "file-prompt cancellation visits nothing")

      (run-command "find-file-in-new-group")
      (t--fgc-confirm! path)
      (minibuffer-change! "zz-cancel-file-new-group")
      (t--fgc-cancel!)
      (check-false! (buffer-known? path) "group-prompt cancellation visits nothing")
      (check-false! (group-resolve-id "zz-cancel-file-new-group")
                    "group-prompt cancellation creates no record")
      (delete-file! path))))

(deftest 'find-file-in-new-group-rolls-back-a-failed-visit
  "a failed visit removes the new record and keeps the current buffer"
  (lambda ()
    (let ((path "/ssh::/compos-zz-failed-new-group")
          (work (test-buffer! "*zz-failed-new-group-work*" "")))
      (switch-to-buffer! work)
      (run-command "find-file-in-new-group")
      (t--fgc-confirm! path)
      (t--fgc-confirm! "zz-failed-new-group")
      (check-false! (buffer-known? path) "the failed visit creates no buffer")
      (check-false! (group-resolve-id "zz-failed-new-group")
                    "the failed visit removes the group record")
      (check-equal! (current-buffer) work "the failed visit keeps the work buffer")
      (buffer-kill! work))))

(deftest 'find-file-keeps-quiet-working-state-out-of-user-lists
  "quiet file loads stay canonical but hidden until a user visit"
  (lambda ()
    (with-fresh-group "zz-quiet-file-context"
      (lambda (group)
        (let ((path "/tmp/compos-zz-quiet-file-context.txt")
              (user (test-buffer! "*zz-quiet-file-context-user*" "")))
          (write-file! path "source\n")
          (buffer-add-group! user group)
          (switch-to-buffer! user)
          (set-frame-local! 'current-group group)
          (find-file path)
          (check-true! (buffer-in-group? path group)
                       "the quiet buffer still joins the working group")
          (check-true! (buffer-context-only? path)
                       "find-file creates context-only state")
          (check-false! (member path (group-user-buffers-mru group))
                        "the quiet buffer stays out of user lists")
          (buffer-append! path "draft\n")
          (visit path group)
          (check-false! (buffer-context-only? path)
                        "a user visit promotes the same buffer")
          (check-equal! (buffer-text path) "source\ndraft\n"
                        "promotion retains unsaved working state")
          (buffer-kill! path)
          (buffer-kill! user)
          (delete-file! path))))))

(deftest 'a-direct-agent-file-visit-uses-the-originating-chat-group
  "the agent keeps an editable context-only buffer until the user visits it"
  (lambda ()
    (with-fresh-group "zz-agent-file-context"
      (lambda (agent-group)
        (with-fresh-group "zz-user-file-context"
          (lambda (user-group)
            (let* ((path "/tmp/compos-zz-agent-file-context.txt")
                   (slug "zz-file-context-agent")
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
                  "(visit \"/tmp/compos-zz-agent-file-context.txt\" (buffer-group (current-buffer)))"))
              (check-true! (buffer-in-group? path agent-group)
                           "the file joined the chat group")
              (check-false! (buffer-in-group? path user-group)
                            "the selected frame group did not leak")
              (check-equal! (current-buffer) user
                            "the tool did not replace the user's buffer")
              (check-true! (buffer-context-only? path)
                           "an agent-created file stays context-only")
              (check-false! (member path (group-user-buffers-mru agent-group))
                            "the group user pool hides agent context")
              (check-false! (member path (map car (switch-sectioned-rows user #f)))
                            "the buffer switcher hides agent context")
              (check-false! (ibuffer-row? path)
                            "ibuffer hides agent context")
              (with-edit-author "agent:zz-file-context-agent"
                (lambda () (buffer-append! path "draft\n")))
              (check-true! (buffer-modified? path)
                           "context-only buffers keep unsaved edits")
              (visit path agent-group)
              (check-false! (buffer-context-only? path)
                            "a user visit promotes the canonical buffer")
              (check-equal! (buffer-text path) "agent\ndraft\n"
                            "promotion keeps the unsaved working state")
              (t--fgc-drop-dispatcher! slug)
              (buffer-kill! path)
              (buffer-kill! user)
              (buffer-kill! chat)
              (delete-file! path))))))))
