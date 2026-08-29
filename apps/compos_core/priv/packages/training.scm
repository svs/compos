;;; training.scm --- launch the guided curriculum and its companion chat.

(package! 'training)
(domain! 'learning)
(effects! '(read write external))

(defgroup 'training "Guided editor training.")

(defcustom 'training-bot-silent-mode #f
  "Start the tour without changing the editor window setup."
  'group 'training 'type 'boolean)

(define (training-document-path)
  "Return the repository's durable training curriculum."
  (let* ((root (daemon-source-root))
         (from-root (string-append root "/docs/training.md"))
         (from-app (string-append root "/../../docs/training.md")))
    (if (file-exists? from-root) from-root from-app)))

(define (training-tour-prompt)
  "Return the first companion turn for the guided tour."
  (string-append
    "You are the training bot. Read the live training.md buffer before you reply. "
    "Start its interactive tour now. Teach one short step per turn, then wait for "
    "the user to try it. Begin with M-x and ask the user to run describe-mode. "
    "Later, teach shortcut keys, C-h k, C-h m, M-?, C-c w, and C-c RET. "
    "Demonstrate that a companion can summarize the current buffer's major mode. "
    "Keep each turn concise and encouraging."))

(define (training--prepare-document!)
  (let* ((path (training-document-path))
         (buf (find-file path)))
    (with-current-buffer buf
      (lambda ()
        (auto-mode path)
        (run-hooks 'find-file-hook)
        (unless (buffer-local buf 'render-mode)
          (run-command "preview-mode"))))
    buf))

(define (training--open-document!)
  (let ((buf (training--prepare-document!)))
    (unless training-bot-silent-mode
      (display-buffer-other-window! buf))
    buf))

(define (training-mode-summary-prompt buf)
  "Return the companion request that teaches BUF's major mode."
  (let* ((mode (or (buffer-local buf 'mode-name) "fundamental-mode"))
         (doc (or (mode-doc mode) "No mode documentation is registered.")))
    (string-append
      "Teach me the major mode of the buffer named \"" buf "\". "
      "The major mode is " mode ". Summarize its purpose, philosophy, "
      "most useful commands, and shortcut keys. Explain how M-x relates "
      "to those keys. Keep the lesson concise.\n\n"
      "Registered mode documentation:\n" doc)))

(define (training--send! chat prompt)
  (with-current-buffer chat
    (lambda ()
      (set-mode! "chat-mode")
      (end-of-buffer!)
      (insert! prompt)
      (run-command "agent-send"))))

(define (training--show-chat-beside! document chat)
  ;; The document already occupies the other window. Use it as the reference
  ;; window, then show and select its companion in the remaining pane.
  (let ((doc-window (window-showing document)))
    (when doc-window
      (select-window! doc-window)
      (display-buffer-other-window! chat)
      (let ((chat-window (window-showing chat)))
        (when chat-window
          (select-window! chat-window))))))

(define (training-start-tour!)
  "Open training.md, start its companion chat, and send the first tour turn."
  (let* ((document (training--open-document!))
         (group (group-ensure! document))
         (chat (group-chat group)))
    (unless training-bot-silent-mode
      (training--show-chat-beside! document chat))
    (training--send! chat (training-tour-prompt))
    (message "Training tour started in the companion chat")
    chat))

(define (training-companion-summarize-mode!)
  "Ask the current buffer's companion chat to summarize its major mode."
  (let* ((source (current-buffer))
         (group (group-ensure! source))
         (chat (group-chat group)))
    (unless training-bot-silent-mode
      (display-buffer-other-window! chat))
    (training--send! chat (training-mode-summary-prompt source))
    (message (string-append "Asked the companion about "
                            (or (buffer-local source 'mode-name) "fundamental-mode")))
    chat))

(define-command "training-bot"
  "Open docs/training.md and start its guided companion-chat tour"
  (lambda () (training-start-tour!)))

(define-command "training-guide" "Open docs/training.md in another window"
  (lambda () (training--open-document!)))

(define-command "training-companion-summarize-mode"
  "Ask the companion chat to summarize the current major mode"
  (lambda () (training-companion-summarize-mode!)))

(define (training--follow-link arg)
  (cond ((equal? arg "summarize-mode")
         (run-command "training-companion-summarize-mode"))
        ((equal? arg "start-tour") (run-command "training-bot"))
        ((equal? arg "guide") (run-command "training-guide"))
        (else (message (string-append "Unknown training link: " arg)))))

(on-preview-link! "training" training--follow-link)

(category! 'training)
(public! 'training-document-path
  "(training-document-path) — the repository's docs/training.md curriculum")
(public! 'training-tour-prompt
  "(training-tour-prompt) — the first companion turn in the interactive curriculum")
(public! 'training-mode-summary-prompt
  "(training-mode-summary-prompt BUFFER) — ask a companion to teach BUFFER's major mode")
(public! 'training-start-tour!
  "(training-start-tour!) — open training.md and start its companion-chat tour")
(public! 'training-companion-summarize-mode!
  "(training-companion-summarize-mode!) — ask this buffer's companion to teach its major mode")
