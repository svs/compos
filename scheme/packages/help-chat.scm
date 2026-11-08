;;; help-chat.scm --- C-c h: one help chat for all of compos, that teaches as it works.
;;;
;;; There is one help chat. C-c h pulls it into the group you are in and
;;; shows it; C-c h in the help chat goes back to the buffer you came from.
;;; chat-for keeps it in the group that holds it, so the same conversation
;;; comes back after an archive or a restart. A move takes the record along.

(domain! 'chat)
(effects! '(pure))

(defgroup 'help-chat "One help chat for all of compos, that teaches as it works.")

(define help-chat-key "compos-help")
(define help-chat-buffer-name "compos help")

(define help-chat-prompt
  (string-append
   "## Help chat\n\n"
   "You are the help chat of compos. The user calls you into any group to learn "
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
   "- You move into the group the user is in, so your group changes between turns. "
   "Call `(chat-context)` again when it matters. `(help-chat-origin)` gives the buffer "
   "the user pressed C-c h in; \"this\" means that buffer, unless the user names another one.\n"
   "- Do not change the repository or the user's files unless the user asks.\n"))

(define help-chat--origin #f)

(effects! '(read))

(define (help-chat-origin)
  "where the user pressed C-c h: (group ID group-name NAME buffer NAME), or #f"
  help-chat--origin)

(define (help-chat--live)
  (find (lambda (b) (equal? (buffer-local b 'chat-for-key) help-chat-key)) (buffer-list)))

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

(define (help-chat--forget! g)
  "take the help chat's record out of group G's chat-for index"
  (let ((ix (chat-for--index g)))
    (when (assoc help-chat-key ix)
      (write-file! (chat-for--index-path g)
                   (value->string
                    (filter (lambda (row) (not (equal? (car row) help-chat-key))) ix))))))

(define (help-chat--move! chat g)
  "put CHAT in group G; its log and its chat-for record go along"
  (let ((old (buffer-group chat)))
    (unless (equal? old g)
      (buffer-move-to-group! chat g)
      (chat-log-save! chat)
      (when old (help-chat--forget! old))
      (chat-for! help-chat-key chat g))
    chat))

(define (help-chat-ensure! &optional group)
  "the help chat, in GROUP when given, made quietly when it has none; shows nothing"
  (let* ((chat (or (help-chat--live)
                   (chat-for help-chat-key)
                   (and group (help-chat--create group)))))
    (when (and chat group) (help-chat--move! chat group))
    (when chat (prompt-part-set! chat "help-chat" help-chat-prompt))
    chat))

(effects! '(write display))

(define (help-chat--back)
  (let ((b (and help-chat--origin (plist-get help-chat--origin 'buffer))))
    (if (and b (buffer-known? b))
        (let ((w (window-showing b)))
          (if w (select-window! w) (switch-to-buffer! b)))
        (run-command "previous-buffer"))))

(define-command "help-chat" "Pull the help chat into this group and show it; in it, go back"
  (lambda ()
    (let ((here (current-buffer)))
      (if (equal? (buffer-local here 'chat-for-key) help-chat-key)
          (help-chat--back)
          (let ((g (group-here)))
            (if (not g)
                (message "There is no group here")
                (let ((chat (help-chat-ensure! g)))
                  (set! help-chat--origin
                        (list 'group g 'group-name (group-name g) 'buffer here))
                  (group-chat-buffer-show! chat))))))))

(global-set-key "C-c h" "help-chat")

(effects! '(read))
(public! 'help-chat-origin "(help-chat-origin) -- the group and buffer the user pressed C-c h in")
(effects! '(write))
(public! 'help-chat-ensure! "(help-chat-ensure! [GROUP]) -- the help chat, moved into GROUP; made there when it has none")

(provide 'help-chat)
