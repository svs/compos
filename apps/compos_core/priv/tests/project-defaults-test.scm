;;; project-defaults-test.scm — project-local defaults follow project buffers.

(domain! 'testing)
(effects! '(write execute))

(tests-need-a-disposable-editor!
  "replaces the frame layout and its Winner history")

(define t--project-defaults-root
  (string-append (compos-home) "/zz-project-defaults"))

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

(deftest 'project-defaults-refresh-inherited-values
  "a reload updates inherited values on old and new project buffers"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (let ((config (string-append t--project-defaults-root "/.project.scm"))
          (first (string-append t--project-defaults-root "/refresh-one.scm"))
          (second (string-append t--project-defaults-root "/refresh-two.scm"))
          (chosen (string-append t--project-defaults-root "/refresh-chosen.scm")))
      (write-file! config "(project-default! 'llm-model \"model-a\")\n")
      (write-file! first "one\n")
      (write-file! second "two\n")
      (write-file! chosen "chosen\n")
      (visit first)
      (check-equal! (buffer-local first 'llm-model) "model-a"
                    "the first load applies model A")
      (visit chosen)
      (buffer-set-local! chosen 'llm-model "chosen-model")
      (write-file! config "(project-default! 'llm-model \"model-b\")\n")
      (visit second)
      (check-equal! (buffer-local first 'llm-model) "model-b"
                    "the old buffer updates to model B")
      (check-equal! (buffer-local second 'llm-model) "model-b"
                    "the new buffer replaces its cached model A")
      (check-equal! (buffer-local chosen 'llm-model) "chosen-model"
                    "the changed buffer keeps its explicit model")
      (for-each buffer-kill! (list first second chosen)))
    (t--project-defaults-reset!)))

(deftest 'invalid-project-defaults-preserve-the-last-valid-values
  "an odd key and value list does not commit a partial configuration"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (let ((config (string-append t--project-defaults-root "/.project.scm")))
      (write-file! config "(project-default! 'llm-model \"valid-model\")\n")
      (project-defaults-load! t--project-defaults-root)
      (write-file! config
        "(project-defaults! 'llm-model \"partial-model\" 'llm-effort)\n")
      (check-false! (project-defaults-load! t--project-defaults-root)
                    "the malformed file fails")
      (check-equal! (project-defaults-for t--project-defaults-root)
                    (list 'llm-model "valid-model")
                    "the last valid defaults remain"))
    (t--project-defaults-reset!)))

(deftest 'removing-project-defaults-clears-inherited-values
  "removing the project file clears values that no buffer changed"
  (lambda ()
    (t--project-defaults-reset!)
    (make-directory! (string-append t--project-defaults-root "/.git"))
    (let ((config (string-append t--project-defaults-root "/.project.scm"))
          (path (string-append t--project-defaults-root "/removed.scm")))
      (write-file! config "(project-default! 'llm-model \"removed-model\")\n")
      (write-file! path "removed\n")
      (visit path)
      (delete-file! config)
      (project-defaults-load! t--project-defaults-root)
      (check-false! (buffer-local path 'llm-model)
                    "the removed inherited model clears")
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

;; tile-all no longer scopes to a project: it is the overview of every
;; live work buffer. overview-test.scm covers it.
