;;; help-chat.scm --- C-c h: one help chat for all of compos, that teaches as it works.
;;;
;;; The help chat lives in its own group, help-chat-group. chat-for keeps it,
;;; so the same conversation comes back after an archive or a restart.
;;; C-c h goes to it from any group and remembers where you came from;
;;; C-c h in the help chat goes back there.

(domain! 'chat)
(effects! '(pure))

(defgroup 'help-chat "One help chat for all of compos, that teaches as it works.")

(defcustom 'help-chat-group "help"
  "The group the help chat lives in.")

(define help-chat-key "compos-help")
(define help-chat-buffer-name "compos help")

(define help-chat-prompt
  (string-append
   "## Help chat\n\n"
   "You are the help chat of compos. The user comes here from any group to learn "
   "how to do a thing in the editor. Teach while you work.\n\n"
   "- When the user asks for a task, do it. Then tell how to do it without you: "
   "the command name and its key from `(key-for-command NAME)`, or `M-x NAME` when it has no key.\n"
   "- When you run Scheme for the user, show the one short expression that did the work, "
   "so the user learns the API. Do not show the discovery calls.\n"
   "- Teach one idea at a time. Keep each reply short. When there is a related next step, "
   "end with one thing the user can try.\n"
   "- The first time a concept comes up (group, window, pane, mode, chat, app), "
   "explain it in one sentence.\n"
   "- Answer from the live editor, not from memory: `apropos`, `describe-function` "
   "and the howto entries tell what is true now. Point to `M-x tutorial` for practice.\n"
   "- The user's work is in another group, not in the windows beside you. "
   "`(help-chat-origin)` gives the group and the buffer the user came from. "
   "\"This\" means that buffer, unless the user names another one.\n"
   "- Do not change the repository or the user's files unless the user asks.\n"))

(define help-chat--origin #f)

(effects! '(read))

(define (help-chat-origin)
  "where the user was before C-c h: (group ID group-name NAME buffer NAME), or #f"
  help-chat--origin)

(effects! '(write))

(define (help-chat--create g)
  (unless (buffer-known? help-chat-buffer-name)
    (buffer-create help-chat-buffer-name)
    (group-chat-init! help-chat-buffer-name g)
    (chat-set-group! help-chat-buffer-name g)
    (when (boundp 'llm-default-bundle-apply!)
      (llm-default-bundle-apply! help-chat-buffer-name)))
  ;; chat-title names the buffer after the title, so it comes last
  (chat-for! help-chat-key help-chat-buffer-name g)
  (chat-title help-chat-buffer-name "compos help")
  help-chat-buffer-name)

(define (help-chat-ensure!)
  "the help chat, made quietly when it has none, with its teaching prompt; shows nothing"
  (let* ((g (group-ensure-record! help-chat-group))
         (chat (or (chat-for help-chat-key g) (help-chat--create g))))
    (prompt-part-set! chat "help-chat" help-chat-prompt)
    chat))

(effects! '(write display))

(define-command "help-chat" "Go to the help chat, one chat for all of compos; in it, go back"
  (lambda ()
    (let ((here (current-buffer)))
      (if (equal? (buffer-local here 'chat-for-key) help-chat-key)
          (run-command "group-switch-last")
          (let ((g (frame-group))
                (chat (help-chat-ensure!)))
            (set! help-chat--origin
                  (list 'group g 'group-name (and g (group-name g)) 'buffer here))
            (switch-to-buffer-in-group! chat))))))

(global-set-key "C-c h" "help-chat")

(effects! '(read))
(public! 'help-chat-origin "(help-chat-origin) -- the group and buffer the user left for the help chat")
(effects! '(write))
(public! 'help-chat-ensure! "(help-chat-ensure!) -- the help chat, made quietly when it has none")

(provide 'help-chat)
