;;; comint.scm --- terminal, comint shells, and tail.
;;;
;;; term-mode is a PTY in a buffer; comint-shell-mode is a line-oriented
;;; shell; tail-mode follows a growing file. Loaded from init.scm.

(domain! 'files)
(effects! '(read))

;;; --- terminal and comint ---------------------------------------------------

(domain! 'processes)
(effects! '(write execute))

;; The terminal receives raw PTY bytes outside the editor render loop. Its
;; bounded plain transcript stays in the buffer for search, agents, and /raw.
;; The login flag works for zsh, bash, and fish. Override this in init.scm.
(define *terminal-command* "exec \"${SHELL:-/bin/zsh}\" -l")

(define (terminal-mode-init! buf)
  (buffer-set-local! buf 'render-mode "terminal")
  (buffer-set-local! buf 'line-numbers "off")
  ;; a terminal is a place you type, not a reading surface: it is never
  ;; read-only, so q is a letter and C-g only leaves the editing state.
  ;; A desktop from before this change restores the flag, so clear it.
  (buffer-set-read-only! buf #f)
  ;; the focus state of an editable buffer: a landing gives the keys to
  ;; the editor, the first typed key gives them to the terminal, and C-g or
  ;; a window command takes them back
  (buffer-set-local! buf 'takes-keyboard #t)
  (local-remap*! buf "self-insert-command" "term-send-key")
  (unless (process-running? buf)
    ;; A terminal app records its own launch command in the buffer.  That
    ;; local rides the desktop, so waking *opencode* starts OpenCode again
    ;; instead of silently turning the buffer into a login shell.
    (start-terminal! buf
      (or (buffer-local buf 'terminal-command) *terminal-command*))))

(define-mode "term-mode"
  (lambda () (terminal-mode-init! (current-buffer))))

;; The key that arms the editing state reaches the editor, not the
;; terminal. It goes on to the PTY, so the first letter is not lost.
(define term--key-bytes
  (list (list "SPC" " ")
        (list "RET" "\r")
        (list "TAB" "\t")
        (list "DEL" "\x7f;")))

(define (term--key-text key)
  (let ((named (assoc key term--key-bytes)))
    (cond (named (cadr named))
          ((= (string-length key) 1) key)
          (else #f))))

(define-command "term-send-key" "Send this key to the terminal, and give it the keyboard"
  (lambda ()
    (let* ((keys (last-keys))
           (text (and (pair? keys) (null? (cdr keys)) (term--key-text (car keys)))))
      (when text (process-send! (current-buffer) text)))))

(mode-keys! "term-mode"
  (map (lambda (entry) (list (car entry) "term-send-key")) term--key-bytes))

;; ESC belongs to the programs in the terminal (vim, less, the line editor)
(mode-focus-key! "term-mode" "C-g")

;; an old desktop names a terminal buffer's mode shell-mode; term-mode is
;; the one name (migrations.scm runs this once per buffer)
(define (shell-mode-name-migrate! buf)
  (when (equal? (buffer-local buf 'mode-name) "shell-mode")
    (buffer-set-local! buf 'mode-name "term-mode")))
(define-buffer-migration! 'shell-mode-name "2026-09-01"
  (lambda (buf) (shell-mode-name-migrate! buf)))

(mode-doc! "term-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text. It has the two states of an editable buffer: you land in focus, where the keys are the editor's; the first key you type goes to the terminal and gives it the keyboard, `C-g`, the focus key the title shows, or a window command takes the keyboard back. `ESC` stays the terminal's.")

(define-command "shell" "Open a raw PTY shell in the *shell* buffer"
  (lambda ()
    (buffer-create "*shell*")
    (buffer-set-local! "*shell*" 'mode-name "term-mode")
    (with-current-buffer "*shell*"
      (lambda () (terminal-mode-init! "*shell*")))
    ;; a shell is a place you type: it takes the window you stand in and
    ;; the keyboard with it. display-buffer only showed it somewhere else
    (switch-to-buffer! "*shell*")))

;; OpenCode is a terminal application, not an editor mode: it gets the same
;; fast raw PTY, ANSI colour, keyboard routing, and readable transcript as
;; *shell*.  One semantic `opencode` role per group makes renamed groups keep
;; finding their session without encoding durable identity in the buffer name.
(define *opencode-command* "exec opencode")

(define (opencode-buffer-name group)
  (if group
      (string-append "*opencode:" (group-name group) "*")
      "*opencode*"))

(define (opencode-open! group)
  (let* ((dir (default-directory))
         (known (and group (group-buffer-as group 'opencode)))
         (buf (or known (opencode-buffer-name group))))
    (buffer-create buf)
    ;; A stopped or restored app keeps the directory and exact command it was
    ;; born with.  Re-running M-x opencode therefore resumes the same session.
    (unless (buffer-local buf 'terminal-command)
      (buffer-set-local! buf 'default-directory dir)
      (buffer-set-local! buf 'terminal-command
        (string-append "cd -- " (sh-quote dir) " && " *opencode-command*)))
    (buffer-set-local! buf 'mode-name "term-mode")
    (when group (buffer-add-group-as! buf group 'opencode))
    (with-current-buffer buf (lambda () (terminal-mode-init! buf)))
    (display-buffer buf)))

;; groups.scm replaces this seam with its native reader.  Keeping the reader
;; out of terminal code also lets compos boot without the optional workspace
;; package loaded.
(define opencode-group-reader
  (lambda (receive) (receive (frame-group))))

(define-command "opencode"
  "Open OpenCode for this group; with C-u, choose a group"
  (lambda ()
    (if (current-prefix-arg)
        (opencode-group-reader opencode-open!)
        (opencode-open! (frame-group)))))

;;; RET in a comint process sends the current line to the process. RET
;;; elsewhere inserts a newline.

;; Comint contract: processes run with TERM=dumb and are expected to degrade
;; (bash does automatically; zsh needs zle/prompt padding off — the flags
;; below, or the classic `[[ $TERM == dumb ]] && unsetopt zle prompt_cr
;; prompt_sp` in your zshrc). fish refuses dumb terminals — it belongs in
;; term-mode (real terminal emulator pane), not comint.
;; Override *shell-command* in your init.scm.
(define *shell-command* "exec /bin/zsh -f -i +o zle +o prompt_cr +o prompt_sp")

;; The text-buffer shell remains available for tools that want comint.
(define-mode "comint-shell-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (process-running? buf)
        (start-process! buf *shell-command*)))))

(mode-doc! "comint-shell-mode"
  "A shell under the editor. `RET` sends the text after the process mark to the shell. A restart keeps the transcript and starts a new shell.")

(define-command "comint-shell" "Open a text-buffer shell in *comint-shell*"
  (lambda ()
    (if (not (process-running? "*comint-shell*"))
        (start-process! "*comint-shell*" *shell-command*))
    (pop-to-buffer "*comint-shell*")
    (buffer-set-local! "*comint-shell*" 'mode-name "comint-shell-mode")
    (end-of-buffer!)))

(define-command "newline-or-send" "Send input to the process, or insert a newline"
  (lambda ()
    (if (process-running? (current-buffer))
        ;; comint: input = text after the process mark. Typed input STAYS in
        ;; the buffer (pty echo is off) — nothing flickers or disappears.
        (let ((pm (process-mark (current-buffer)))
              (eob (end-of-buffer!)))
          (let ((input (buffer-substring pm eob)))
            (insert! "\n")
            (process-send! (current-buffer) (string-append input "\n"))))
        (insert! "\n"))))
(domain! 'processes)
(effects! '(write execute))

;;; --- tail (follow a growing file) ------------------------------------------
;;; tail -F under the comint layer — local or /ssh: remote. The buffer is
;;; 'special: a view of a file, not the file. desktop-skip! decides what
;;; is saved; tail-mode's setup restarts the tail on restore. end-of-buffer! puts
;;; point at the end, where process appends keep pushing it — follow for free.

(define (tail-command path)
  (if (remote-path? path)
      (let ((hp (remote-parse path)))
        ;; double-quoted: the inner quoting survives to the remote shell
        (string-append "exec " (sh-quote (ssh-command)) " " (sh-quote (car hp)) " "
                       (sh-quote (string-append "tail -n 200 -F " (sh-quote (cadr hp))))))
      (string-append "exec tail -n 200 -F " (sh-quote path))))

(mode-parent! "tail-mode" "special-mode")
(define-mode "tail-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (let ((path (buffer-local buf 'tail-path)))
        (buffer-set-read-only! buf #t)
        (when (and path (not (process-running? buf)))
          (start-process! buf (tail-command path)))))))
(mode-keys! "tail-mode" '(("q" "quit-window")))

(mode-doc! "tail-mode"
  "A file that follows itself, local or over `ssh`. New lines append at the end. The buffer is read-only, and `q` closes it.")

(define (tail-open path)
  (if (and (remote-path? path) (not (remote-parse path)))
      (message "Remote path is /ssh:HOST:/PATH")
      (let ((buf (string-append "*tail: " path "*")))
        (buffer-create buf)
        (buffer-set-local! buf 'tail-path path)
        (switch-to-buffer! buf)
        (set-mode! "tail-mode")
        (end-of-buffer!))))

(define-command "tail-file" "Follow a file as it grows (local or /ssh: remote)"
  (lambda ()
    (read-file-name "Tail file: "
      (lambda (input) (tail-open (normalize-file-input input))))))

(domain! 'unknown)
(effects! '(unknown))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'unknown)
(effects! '(unknown))
(category! 'buffers)
(public! 'tail-open "(tail-open PATH) — follow a file with tail -F, local or /ssh: remote")
(public! 'sh-quote "(sh-quote S) — S as one safe single-quoted word for a shell command")

(domain! 'unknown)
(effects! '(unknown))
