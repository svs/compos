;;; code-mode-test.scm --- what a code buffer tells its chat.
;;;
;;; code-mode is a workspace: it joins a group, opens a chat, loads the
;;; coding presets and turns on llm-mode. What it CHANGES is policy — the
;;; instructions in both prompt paths, the permission a code chat gets,
;;; and the browser category it denies until asked.

(domain! 'testing)
(effects! '(write))

(define t--cm-buf "zz-code-mode.ex")

(deftest 'agents-work-quietly-unless-the-user-asks-for-presentation
  "the shared prompt keeps work out of the user's visible editor state"
  (lambda ()
    (for-each
      (lambda (prompt)
        (check-contains! prompt "QUIET EDITOR" "quiet is the default")
        (check-contains! prompt "reachable through Scheme without making a buffer visible"
                         "Scheme does not need display")
        (check-contains! prompt "Do not select, switch to, or display a buffer merely to work"
                         "work does not move the editor")
        (check-contains! prompt "only when the user asks to see it"
                         "display is for the user")
        (check-contains! prompt "excludes display-effect operations by default"
                         "discovery starts quiet")
        (check-contains! prompt "Preserve focus" "presentation keeps the user's place"))
      (list *llm-system* (hello)))))

(deftest 'agent-discovery-hides-display-effects-until-presentation-is-explicit
  "the tool filter hides visible movement without removing the public API"
  (lambda ()
    (let ((effects (plist-get
                     (catalog-entry 'function "display-buffer-other-window!")
                     'effects))
          (quiet (llm-tool-call "apropos"
                   (list 'query "display-buffer-other-window!")))
          (present (llm-tool-call "apropos"
                     (list 'query "display-buffer-other-window!"
                           'include-display #t))))
      (check-true! (member "display" effects) "the effect is checked-in metadata")
      (check-false! (string-contains? quiet "display-buffer-other-window!")
                    "default agent discovery is quiet")
      (check-contains! present "display-buffer-other-window!"
                       "an explicit presentation search opts in")
      (check-contains! (value->string (apropos "display-buffer-other-window!"))
                       "display-buffer-other-window!"
                       "the public catalog remains complete"))))

(deftest 'explicit-narrowing-and-widening-are-discoverable-as-presentation
  "named-buffer presentation APIs stay quiet by default and direct when requested"
  (lambda ()
    (let ((quiet (llm-tool-call "apropos" (list 'query "widen")))
          (present (llm-tool-call "apropos"
                     (list 'query "widen" 'include-display #t))))
      (check-false! (string-contains? quiet "buffer-widen!")
                    "quiet discovery hides visible mutations")
      (check-contains! present "buffer-widen!"
                       "presentation discovery finds the named-buffer API")
      (check-contains! present "(buffer-widen! BUF)"
                       "the result gives the direct call shape")
      (check-equal!
        (plist-get (catalog-entry 'function "buffer-widen!") 'effects)
        '("write" "display") "widening is correctly stamped"))))

(deftest 'the-side-chat-prompt-distinguishes-display-from-buffer-history
  "open in the other buffer means another window; switch means buffer history"
  (lambda ()
    (let* ((buf (test-buffer! "zz-code-mode.md" "text\n"))
           (prompt (chat-preamble-body buf (list buf))))
      (check-contains! prompt "\"open it in the other buffer\"" "it names the display request")
      (check-contains! prompt "(display-buffer-other-window! NAME)" "and uses another window")
      (check-contains! prompt "\"switch to the other buffer\"" "it names the history request")
      (check-contains! prompt "(run-command \"previous-buffer\")" "and uses buffer history")
      (check-contains! prompt "when the target is clear" "and does not ask needlessly")
      (buffer-kill! buf))))

;;; --- from here down, the tests turn code-mode on --------------------------------
;;; That joins a group, opens a chat and loads the coding presets, which
;;; in a live editor is the person's own workspace.

(tests-need-a-disposable-editor!
  "turns code-mode on, which joins a group, opens a chat and loads the coding presets")

(define (t--cm-fresh!)
  ;; code-mode TOGGLES, and test-buffer! reuses an existing buffer — so a
  ;; buffer left over with the mode on would be turned off instead of on
  (when (buffer-known? t--cm-buf) (buffer-kill! t--cm-buf))
  (test-buffer! t--cm-buf "code\n"))

(define (t--cm-on!)
  (t--cm-fresh!)
  (switch-to-buffer! t--cm-buf)
  (run-command "code-mode")
  t--cm-buf)

(define (t--cm-off! &rest extra)
  (for-each
    (lambda (b)
      (when (minor-mode-on? b "code-mode") (disable-minor-mode! b "code-mode"))
      (when (minor-mode-on? b "browser-mode") (disable-minor-mode! b "browser-mode"))
      (when (string-prefix? "*scratch:" b) (buffer-kill! b)))
    (buffer-list))
  (customize-set! 'code-presets '(aimax))
  (customize-set! 'code-model "")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) extra)
  (when (buffer-known? t--cm-buf)
    (let ((id (buffer-group t--cm-buf)))
      (when (and id (group-record-by-id id)) (group-record-delete! id)))
    (buffer-kill! t--cm-buf)))

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


(deftest 'code-mode-joins-a-group-loads-the-presets-and-turns-on-llm-mode
  "one command sets the whole workspace up"
  (lambda ()
    (let ((buf (t--cm-on!)))
      (let ((modes (buffer-local buf 'minor-modes)))
        (check-true! (member "code-mode" modes) "code-mode is on")
        (check-true! (member "llm-mode" modes) "and llm-mode with it")
        (check-equal! (length modes) 2 "and nothing else"))
      ;; the ExUnit original compared the legacy 'group local to the buffer
      ;; NAME; a group id replaced it, so that assertion has been failing.
      (check-true! (buffer-group buf) "the buffer joined a group")
      (check-equal! (buffer-local buf 'chat-presets) '(aimax) "with the coding presets")
      (check-equal! (buffer-local buf 'modeline-info) "code · aimax" "and the modeline says so"))
    (t--cm-off!)))

(deftest 'the-coding-presets-ride-over-the-buffers-own
  "and a preset removed from the setting does not linger"
  (lambda ()
    (let ((buf (t--cm-fresh!))
          (saved code-presets))
      (buffer-set-local! buf 'chat-presets '(project))
      (customize-set! 'code-presets '(aimax web))
      (switch-to-buffer! buf)
      (run-command "code-mode")

      (check-equal! (buffer-local buf 'chat-presets) '(aimax web project)
                    "the coding presets come first, the buffer's own last")
      (check-equal! (buffer-local buf 'modeline-info) "code · aimax web project" "the modeline")

      ;; a live customization rebuilds from the buffer's own pre-mode value
      (customize-set! 'code-presets '(aimax))
      (check-equal! (buffer-local buf 'chat-presets) '(aimax project)
                    "the removed preset disappears at once")

      (run-command "code-mode")
      (check-equal! (buffer-local buf 'chat-presets) '(project) "and leaving gives back its own")
      (customize-set! 'code-presets saved))
    (t--cm-off!)))

(deftest 'the-scratch-chat-carries-the-coding-presets
  "the scratch is where the agent is asked, so it holds the configuration"
  (lambda ()
    (let* ((buf (t--cm-on!))
           (scratch (string-append "*scratch:" buf "*")))
      (run-command "scratch-buffer")
      (check-equal! (current-buffer) scratch "the scratch has the focus")
      (check-equal! (buffer-local scratch 'chat-presets) '(aimax) "with the coding presets")
      (check-equal! (buffer-group scratch) (buffer-group buf) "in the document's group")
      (check-equal! (buffer-group-role scratch (buffer-group buf)) "scratch"
                    "with the scratch role")
      (check-true! (member "llm-mode" (buffer-local scratch 'minor-modes)) "and llm-mode on")
      (t--cm-off! scratch))))

(deftest 'the-scratch-chats-system-prompt-names-the-buffer-to-edit
  "an agent told to edit must be told which buffer"
  (lambda ()
    (let* ((buf (t--cm-on!))
           (scratch (string-append "*scratch:" buf "*")))
      (run-command "scratch-buffer")
      (let ((note (llm-mode--group-note scratch)))
        (check-contains! note buf "it names the document")
        (check-contains! note scratch "and the scratch")
        (check-contains! note "buffer-replace!" "and the call that edits"))

      ;; a buffer in no group says nothing: M-o on a lone document keeps
      ;; the system prompt it always had
      (let ((lone (test-buffer! "zz-cm-lone" "")))
        ;; a buffer born while the frame is in a group inherits it, and
        ;; 'group is only the legacy field. Drop the memberships to make
        ;; this the groupless buffer the check is about.
        (for-each (lambda (id) (buffer-remove-group! lone id))
                  (buffer-group-ids lone))
        (check-equal! (llm-mode--group-note lone) "" "a lone buffer adds nothing")
        (buffer-kill! lone))
      (t--cm-off! scratch))))

(deftest 'a-scratch-already-open-picks-up-the-presets-when-code-mode-turns-on
  "the workspace reaches what is already on screen"
  (lambda ()
    (let* ((buf (t--cm-fresh!))
           (scratch (string-append "*scratch:" buf "*")))
      (switch-to-buffer! buf)
      (run-command "scratch-buffer")
      (check-false! (buffer-local scratch 'chat-presets) "no presets before the mode")

      (run-command "scratch-buffer")
      (check-equal! (current-buffer) buf "the second toggle comes back")
      (run-command "code-mode")

      (check-equal! (buffer-local scratch 'chat-presets) '(aimax) "the open scratch picked them up")
      (check-true! (member "llm-mode" (buffer-local scratch 'minor-modes)) "and llm-mode with them")
      (t--cm-off! scratch))))

(deftest 'code-model-pins-the-model-for-the-buffer-and-its-scratch
  "one setting, both halves of the workspace"
  (lambda ()
    (let ((saved code-model))
      (customize-set! 'code-model "openai:test-coder")
      (let* ((buf (t--cm-on!))
             (scratch (string-append "*scratch:" buf "*")))
        (run-command "scratch-buffer")
        (check-equal! (buffer-local buf 'llm-model) "openai:test-coder" "the document")
        (check-equal! (buffer-local scratch 'llm-model) "openai:test-coder" "and the scratch")

        ;; clearing the setting gives the editor's default model back
        (customize-set! 'code-model "")
        (check-false! (buffer-local buf 'llm-model) "cleared")
        (customize-set! 'code-model saved)
        (t--cm-off! scratch)))))

(deftest 'disabling-code-mode-restores-what-it-changed
  "each local goes back to the value the mode found; absent reads as #f"
  (lambda ()
    (let ((buf (t--cm-on!)))
      (run-command "code-mode")
      (check-equal! (buffer-local buf 'minor-modes) '() "no minor mode is left")
      (check-false! (buffer-local buf 'chat-presets) "no presets")
      (check-false! (buffer-local buf 'group) "no group")
      (check-false! (buffer-local buf 'modeline-info) "no modeline")
      (check-false! (buffer-local buf 'code-mode-saved) "and nothing left to restore"))
    (t--cm-off!)))

(deftest 'code-mode-keeps-an-llm-mode-the-user-turned-on-first
  "it restores what it found, not what it would have set"
  (lambda ()
    (let ((buf (t--cm-fresh!)))
      (enable-minor-mode! buf "llm-mode")
      (switch-to-buffer! buf)
      (run-command "code-mode")
      (run-command "code-mode")
      (check-equal! (buffer-local buf 'minor-modes) '("llm-mode") "llm-mode stayed on"))
    (t--cm-off!)))

(deftest 'restore-minor-modes-re-runs-the-code-setup-once
  "the reload path rebuilds the workspace from the surviving locals"
  (lambda ()
    (let ((buf (t--cm-on!)))
      (buffer-set-local! buf 'chat-presets '(aimax project))
      (restore-minor-modes! buf)
      (let ((modes (buffer-local buf 'minor-modes)))
        (check-true! (member "code-mode" modes) "code-mode is back")
        (check-true! (member "llm-mode" modes) "and llm-mode with it")
        (check-equal! (length modes) 2 "and nothing else"))
      (check-true! (buffer-group buf) "the group is back")
      (check-equal! (buffer-local buf 'modeline-info) "code · aimax" "and the modeline"))
    (t--cm-off!)))


;;; --- the worktree prompt ---------------------------------------------------------

(define (t--cm-git! root)
  (shell-command->string (string-append "rm -rf " root " " root "-worktrees"))
  (make-directory! root)
  (write-file! (string-append root "/one.ex") "defmodule One do\nend\n")
  (shell-command->string
    (string-append "cd " root
                   " && git init -q -b main ."
                   " && git add ."
                   " && git -c user.email=t@t -c user.name=t commit -q -m one"))
  ;; git answers with the PHYSICAL path, and on macOS /tmp is a symlink to
  ;; /private/tmp — so every later comparison must use the resolved one
  (string-trim (shell-command->string (string-append "cd " root " && pwd -P"))))

;; y-or-n reads its answer on the minibuffer's 'change handler, so this
;; is the same path a typed "y" takes — no key dispatch needed.
(define (t--cm-answer! key)
  (minibuffer-change! key)
  (not (minibuffer-state)))

(deftest 'code-mode-asks-before-it-assigns-this-frame-a-worktree
  "the current checkout is the safe default until the user chooses"
  (lambda ()
    (let* ((root (t--cm-git! (string-append (aimax-home) "/zz-cm-proj")))
           (path (string-append root "/one.ex"))
           (workspace (string-append root "-worktrees/a1"))
           (saved-lsp lsp-auto-start))
      ;; a .ex file in a git project would auto-attach elixir-ls, which
      ;; then tries to install itself. This test is about the worktree.
      (customize-set! 'lsp-auto-start #f)
      (find-file path)
      (switch-to-buffer! path)
      (run-command "code-mode")

      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Create a new worktree for code mode? (y or n) " "it asks first")
      (check-false! (file-exists? workspace) "and has made nothing yet")

      ;; n: stay in the checkout we are already in
      (check-true! (t--cm-answer! "n") "the prompt closes")
      (check-equal! (current-buffer) path "we stay in the file we were in")
      (check-equal! (buffer-local path 'workspace-isolation-choice) "current" "the choice is recorded")
      (check-false! (file-exists? workspace) "and still no worktree")
      (check-false! (plist-get (agent-worktree-opts path "a1" '()) 'cwd)
                    "so an agent runs in the checkout")

      ;; y: a worktree of its own
      (run-command "code-mode")
      (switch-to-buffer! path)
      (run-command "code-mode")
      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Create a new worktree for code mode? (y or n) " "it asks again")
      (check-true! (t--cm-answer! "y") "the prompt closes")

      (let ((task (current-buffer)))
        (check-equal! (buffer-local task 'workspace-root) workspace "the workspace is a sibling")
        (check-equal! task (string-append workspace "/one.ex") "and we are in its copy")
        (check-equal! (buffer-local task 'workspace-project-root) root "which knows its project")
        (check-equal! (buffer-local task 'workspace-id) "a1" "and its id")
        (check-equal! (buffer-local task 'modeline-info) "code · a1 · aimax" "the modeline says both")

        ;; the ordinary editor tool changes the task buffer, and saving
        ;; cannot touch the primary checkout: the displayed buffer is the copy
        (buffer-replace! task "One" "TaskOne")
        (with-current-buffer task (lambda () (run-command "save-buffer")))
        (check-equal! (read-file path) "defmodule One do\nend\n" "the checkout is untouched")
        (check-equal! (read-file task) "defmodule TaskOne do\nend\n" "and the worktree has the edit")

        ;; the chat belongs to the workspace, not to the primary checkout.
        ;; A chat is named for where it lives, and a worktree is its own
        ;; checkout, so the name is the worktree's, not the whole path.
        (switch-to-buffer! task)
        (run-command "chat")
        (let ((chat (current-buffer)))
          (check-equal! chat (group-chat-name workspace) "the chat is the workspace's")
          (check-equal! (buffer-local chat 'workspace-root) workspace "and carries its root")
          (check-equal! (buffer-local chat 'workspace-id) "a1" "and its id")
          (check-equal! (plist-get (agent-worktree-opts chat "a1" '()) 'cwd) workspace
                        "so an agent runs inside it")
          (check-equal! (group-chat workspace) chat "and the group answers with it")

          ;; a second task is a sibling workspace with its own group and chat
          (switch-to-buffer! path)
          (run-command "workspace-init")
          (let* ((second (current-buffer))
                 (second-workspace (buffer-local second 'workspace-root)))
            (check-equal! second-workspace (string-append root "-worktrees/a2")
                          "the second is a sibling, not a child")
            (switch-to-buffer! second)
            (run-command "chat")
            (check-false! (equal? (current-buffer) chat) "with a chat of its own")
            (check-true! (buffer-known? chat) "and the first chat survives")
            (check-equal! (length (worktree-list root)) 3 "three worktrees: the checkout and two"))))

      ;; leave nothing behind
      (for-each (lambda (b)
                  (when (or (string-prefix? root b) (string-contains? b (string-append root "-worktrees")))
                    (buffer-kill! b)))
                (buffer-list))
      (shell-command->string (string-append "rm -rf " root " " root "-worktrees"))
      (customize-set! 'lsp-auto-start saved-lsp)
      (t--cm-off!))))
