;;; writing-test.scm --- the writing workspace.
;;;
;;; A word count, the layout a mode declares, and which connector an
;;; inline session opens on. The rest of writing_test presses keys or
;;; reads a rendered window, and stays in ExUnit.

(domain! 'testing)
(effects! '(write))

(deftest 'count-words-counts-whitespace-separated-words
  "runs of whitespace are one separator, and a newline is whitespace"
  (lambda ()
    (let ((buf (test-buffer! "zz-writing-count" "a b  c\nd\n")))
      (check-equal! (count-words buf) 4 "four words")
      (buffer-kill! buf))))

(deftest 'a-modes-layout-declaration-is-what-the-engine-applies
  "the layout is data, so the engine has nothing to interpret"
  (lambda ()
    (check-equal! (mode-layout "writing-layout")
                  '(h 0.34 self scratch-buffer writing-chat-buffer)
                  "the document, its scratch, and its chat")))

;;; --- from here down, the test opens the workspace --------------------------------
;;; M-x write applies the layout above, which splits a live frame into
;;; three panes and opens a chat in one of them.

(tests-need-a-disposable-editor!
  "runs M-x write, which splits the frame into the writing layout and opens a chat")

(deftest 'an-inline-session-runs-on-the-connector-that-has-its-model
  "a model no connector has still reaches the metered lane"
  (lambda ()
    (let* ((buf (test-buffer! "zz-writing-lane.md" "Draft.\n"))
           (scratch (string-append "*scratch:" buf "*"))
           (saved writing-model))
      ;; an API-lane model id names the same model Codex spells without
      ;; the provider prefix: the session opens on Codex, under the name
      ;; Codex knows
      (customize-set! 'writing-model "openai:gpt-5.6-luna")
      (switch-to-buffer! buf)
      (run-command "write")

      (check-equal! (buffer-llm-connector scratch) "codex-app-server" "it opened on Codex")
      (check-equal! (connector-model-id "codex-app-server" "openai:gpt-5.6-luna")
                    "gpt-5.6-luna" "under the name Codex knows")

      ;; a model no connector has still reaches the metered lane rather
      ;; than failing at the first send
      (check-equal! (llm-connector-for-model "made-up:model") "api" "the fallback lane")

      (customize-set! 'writing-model saved)
      (for-each (lambda (b)
                  (when (minor-mode-on? b "writing-mode") (disable-minor-mode! b "writing-mode")))
                (buffer-list))
      (when (buffer-known? scratch) (buffer-kill! scratch))
      (when (buffer-known? buf) (buffer-kill! buf)))))
