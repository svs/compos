;;; code-mode-test.scm --- what a code buffer tells its chat.
;;;
;;; code-mode is a workspace: it joins a group, opens a chat, loads the
;;; coding presets and turns on llm-mode. What it CHANGES is policy — the
;;; instructions in both prompt paths, the permission a code chat gets,
;;; and the browser category it denies until asked.

(domain! 'testing)
(effects! '(write))

(define t--cm-buf "zz-code-mode.ex")

(deftest 'the-side-chat-prompt-handles-other-buffer-without-a-question
  "two words a person says all day, and the call that answers them"
  (lambda ()
    (let* ((buf (test-buffer! "zz-code-mode.md" "text\n"))
           (prompt (chat-preamble-body buf (list buf))))
      (check-contains! prompt "When the user says \"other buffer\"" "it names the words")
      (check-contains! prompt "(run-command \"previous-buffer\") immediately" "and the call")
      (check-contains! prompt "Do not ask a question." "and says not to ask")
      (buffer-kill! buf))))

;;; --- from here down, the tests turn code-mode on --------------------------------
;;; That joins a group, opens a chat and loads the coding presets, which
;;; in a live editor is the person's own workspace.

(tests-need-a-disposable-editor!
  "turns code-mode on, which joins a group, opens a chat and loads the coding presets")

(define (t--cm-on!)
  (test-buffer! t--cm-buf "code\n")
  (switch-to-buffer! t--cm-buf)
  (run-command "code-mode")
  t--cm-buf)

(define (t--cm-off!)
  (for-each
    (lambda (b)
      (when (minor-mode-on? b "code-mode") (disable-minor-mode! b "code-mode"))
      (when (minor-mode-on? b "browser-mode") (disable-minor-mode! b "browser-mode"))
      (when (string-prefix? "*scratch:" b) (buffer-kill! b)))
    (buffer-list))
  (customize-set! 'code-presets '(aimax))
  (customize-set! 'code-model "")
  (when (buffer-known? t--cm-buf) (buffer-kill! t--cm-buf)))

(deftest 'the-shared-policy-lets-a-code-workspace-chat-restart-the-daemon
  "the grant is the buffer's, so only this workspace's chat gets it"
  (lambda ()
    (let* ((buf (t--cm-on!))
           (chat (group-chat buf)))
      (check-equal! (*permission-policy* chat "restart-daemon" "command" "")
                    'allow-always "the code chat may restart the daemon"))
    (t--cm-off!)))

(deftest 'the-code-instructions-ride-in-both-prompt-paths
  "and only for code buffers: the writing voice is the default"
  (lambda ()
    (let* ((buf (t--cm-on!)))
      ;; the shared edit protocol names the structural readers for any
      ;; buffer; what code-mode adds is the coding voice and its own
      ;; instructions
      (let ((preamble (chat-preamble-body buf (list buf))))
        (check-contains! preamble "coding companion" "the voice")
        (check-contains! preamble "(code-outline \"BUF\")" "the read call")
        (check-contains! preamble "(code-replace! \"BUF\" LINE NEW)" "the write call")
        (check-contains! preamble "(buffer-insert-after! \"BUF\" ANCHOR TEXT)" "the insert call")
        (check-contains! preamble "browser category is denied in code-mode by default"
                         "and what is denied")
        (check-contains! preamble "ask the user to enable M-x browser-mode" "and how to ask")
        (check-false! (string-contains? preamble "Match the document's voice")
                      "the writing instruction is gone"))

      ;; and M-o, on the same words
      (check-contains! (llm-mode--group-note buf) "(code-outline \"BUF\")"
                       "the M-o path carries them too")

      ;; the user owns the words
      (let ((saved code-instructions))
        (customize-set! 'code-instructions "")
        (check-false! (string-contains? (llm-mode--group-note buf) "buffer-insert-after!")
                      "emptying the custom takes them out")
        (customize-set! 'code-instructions saved)))
    (t--cm-off!)))

(deftest 'code-mode-denies-browser-tools-until-the-user-enables-browser-mode
  "a coding agent has no business opening tabs unasked"
  (lambda ()
    (let ((buf (t--cm-on!)))
      (check-contains!
        (with-current-buffer buf
          (lambda ()
            (llm-tool-call "eval-scheme" (list 'code "(tab-list (lambda (tabs) tabs))"))))
        "browser category denied in code-mode" "the call is refused")

      (switch-to-buffer! buf)
      (run-command "browser-mode")
      (check-true! (code-mode--browser-enabled? buf) "and enabling the mode lifts it"))
    (t--cm-off!)))
