;;; project-defaults-test.scm — project-local defaults follow project buffers.

(domain! 'testing)
(effects! '(write execute))

(tests-need-a-disposable-editor!
  "tile-all replaces the frame layout and its Winner history")

(define t--project-defaults-root
  (string-append (aimax-home) "/zz-project-defaults"))

(define (t--project-defaults-reset!)
  (shell-command->string (string-append "rm -rf " t--project-defaults-root))
  (set! *project-root-cache* '())
  (set! *project-defaults*
    (remove (lambda (entry) (equal? (car entry) t--project-defaults-root))
            *project-defaults*)))

(deftest 'project-file-loads-project-defaults
  ".project.scm runs when a project file is visited"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (write-file! (string-append t--project-defaults-root "/.project.scm")
      "(project-defaults! 'llm-connector \"codex-app-server\" 'llm-model \"zz-project-model\" 'llm-effort \"high\")\n")
    (let ((path (string-append t--project-defaults-root "/one.scm")))
      (write-file! path "(display \"one\")\n")
      (visit path)
      (check-equal! (buffer-local path 'llm-connector) "codex-app-server"
                    "the connector came from the project")
      (check-equal! (buffer-local path 'llm-model) "zz-project-model"
                    "the model came from the project")
      (check-equal! (buffer-local path 'llm-effort) "high"
                    "the effort came from the project")
      (buffer-kill! path))
    (t--project-defaults-reset!)))

(deftest 'project-defaults-do-not-override-a-buffer-choice
  "an existing buffer-local value wins over the project default"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (write-file! (string-append t--project-defaults-root "/.project.scm")
      "(project-default! 'llm-model \"zz-project-model\")\n")
    (let ((path (string-append t--project-defaults-root "/two.scm")))
      (write-file! path "(display \"two\")\n")
      (find-file path)
      (buffer-set-local! path 'llm-model "zz-buffer-model")
      (switch-to-buffer! path)
      (auto-mode path)
      (run-hooks 'find-file-hook)
      (check-equal! (buffer-local path 'llm-model) "zz-buffer-model"
                    "the explicit buffer model remains")
      (buffer-kill! path))
    (t--project-defaults-reset!)))

(deftest 'project-defaults-map-llm-values-to-project-chats
  "a chat born in the project gets its agent configuration"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (write-file! (string-append t--project-defaults-root "/.project.scm")
      "(project-defaults! 'llm-connector \"api\" 'llm-model \"zz-chat-model\" 'llm-effort \"medium\")\n")
    (project-defaults-load! t--project-defaults-root)
    (let ((chat "*chat:zz-project-default*")
          (owner (test-buffer! "*zz-project-default-owner*" "")))
      (buffer-set-local! owner 'default-directory
        (string-append t--project-defaults-root "/"))
      (switch-to-buffer! owner)
      (buffer-create chat)
      (with-current-buffer chat (lambda () (set-mode! "chat-mode")))
      (check-equal! (buffer-local chat 'agent-connector) "api"
                    "the chat connector uses the LLM default")
      (check-equal! (buffer-local chat 'agent-model) "zz-chat-model"
                    "the chat model uses the LLM default")
      (check-equal! (buffer-local chat 'agent-effort) "medium"
                    "the chat effort uses the LLM default")
      (check-false! (buffer-local chat 'llm-model)
                    "the chat does not retain an unclassified LLM local")
      (buffer-kill! chat)
      (buffer-kill! owner))
    (t--project-defaults-reset!)))

(deftest 'tile-all-tiles-every-buffer-in-the-current-project
  "project scope supplies every open project buffer when no group is active"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (set! *project-root-cache* '())
    (switch-to-buffer! "*scratch*")
    (delete-other-windows!)
    (buffer-set-local! "*scratch*" 'group-ids '())
    (buffer-set-local! "*scratch*" 'group #f)
    (set-frame-local! 'current-group #f)
    (set-frame-local! 'pinned-group #f)
    (group-current-recalculate!)
    (let ((first "*zz-project-tile-first*")
          (second "*zz-project-tile-second*")
          (third "*zz-project-tile-third*"))
      (for-each
        (lambda (buf)
          (test-buffer! buf "")
          (buffer-set-local! buf 'default-directory
            (string-append t--project-defaults-root "/")))
        (list first second third))
      (switch-to-buffer! first)
      (delete-other-windows!)
      (check-false! (frame-group) "the test frame has no group context")
      (check-equal! (project-current) t--project-defaults-root
                    "the first buffer supplies the project context")
      (check-equal! (length (tile-all-context-buffers)) 3
                    "tile-all selects all three project buffers")
      (global-set-key "<f9> t" "tile-all")
      (dispatch-keys '("<f9>" "t"))
      (check-true!
        (wait-until (lambda () (= (length (window-list)) 3)) 3000 20)
        "each project buffer gets one window")
      (for-each
        (lambda (buf) (check-true! (window-showing buf) "the buffer is visible"))
        (list first second third))
      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (for-each buffer-kill! (list first second third)))
    (t--project-defaults-reset!)))
