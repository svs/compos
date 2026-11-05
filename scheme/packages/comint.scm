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

;;; --- the environment of a terminal's shell ----------------------------------
;;; Each function in term-environment-functions takes the terminal buffer
;;; and answers ((NAME VALUE) ...). The shell exports them before it starts,
;;; so every program in the terminal reads them. This is the terminal's
;;; process-environment; a package adds a function with a keyed add-hook!.

(define (term-environment buf)
  (apply append
         (map (lambda (f) (let ((p (hook--fn f))) (or (and p (p buf)) '())))
              (hook-functions 'term-environment-functions))))

(define (term--export-prefix buf)
  (let ((env (term-environment buf)))
    (if (null? env)
        ""
        (string-append "export "
                       (string-join (map (lambda (e) (string-append (car e) "=" (sh-quote (cadr e))))
                                         env)
                                    " ")
                       "; "))))

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
  ;; a key no map binds goes to the program: C-c C-c, C-d and the rest
  (buffer-set-local! buf 'undefined-key-command "term-send-key")
  (unless (process-running? buf)
    ;; A terminal app records its own launch command in the buffer.  That
    ;; local rides the desktop, so waking *opencode* starts OpenCode again
    ;; instead of silently turning the buffer into a login shell.
    (start-terminal! buf
      (string-append (term--export-prefix buf)
                     (or (buffer-local buf 'terminal-command) *terminal-command*)))))

(define-mode "term-mode"
  (lambda () (terminal-mode-init! (current-buffer))))

;; The key that arms the editing state reaches the editor, not the
;; terminal. It goes on to the PTY, so the first letter is not lost.
(define term--key-bytes
  (list (list "SPC" " ")
        (list "RET" "\r")
        (list "TAB" "\t")
        (list "DEL" "\x7f;")))

;; the keys a terminal speaks as escape sequences, sent when no map binds them
(define term--escape-bytes
  (list (list "ESC" "\x1b;")
        (list "<up>" "\x1b;[A") (list "<down>" "\x1b;[B")
        (list "<right>" "\x1b;[C") (list "<left>" "\x1b;[D")
        (list "<home>" "\x1b;[H") (list "<end>" "\x1b;[F")
        (list "<delete>" "\x1b;[3~") (list "<prior>" "\x1b;[5~")
        (list "<next>" "\x1b;[6~") (list "S-TAB" "\x1b;[Z")))

;; the control byte of one key: C-a is 1, C-@ and C-SPC are 0, C-? is DEL
(define term--controls "\x0;\x1;\x2;\x3;\x4;\x5;\x6;\x7;\x8;\x9;\xa;\xb;\xc;\xd;\xe;\xf;\x10;\x11;\x12;\x13;\x14;\x15;\x16;\x17;\x18;\x19;\x1a;\x1b;\x1c;\x1d;\x1e;\x1f;")

(define (term--control text)
  (cond ((equal? text "SPC") (substring term--controls 0 1))
        ((not (= (string-length text) 1)) #f)
        (else
         (let ((c (string-byte text 0)))
           (cond ((and (>= c 97) (<= c 122)) (substring term--controls (- c 96) (- c 95)))
                 ((and (>= c 64) (<= c 95)) (substring term--controls (- c 64) (- c 63)))
                 ((= c 63) "\x7f;")
                 (else #f))))))

;; the bytes a terminal sends for KEY, or #f: Meta is ESC first, and the
;; Cmd chords are the editor's
(define (term--key-text key)
  (let ((named (or (assoc key term--key-bytes) (assoc key term--escape-bytes)))
        (n (string-length key)))
    (cond (named (cadr named))
          ((= n 1) key)
          ((string-prefix? "C-M-" key)
           (let ((b (term--control (substring key 4 n))))
             (and b (string-append "\x1b;" b))))
          ((string-prefix? "M-" key)
           (let ((b (term--key-text (substring key 2 n))))
             (and b (string-append "\x1b;" b))))
          ((string-prefix? "C-" key) (term--control (substring key 2 n)))
          (else #f))))

(define-command "term-send-key" "Send these keys to the terminal, and give it the keyboard"
  (lambda ()
    (let* ((keys (last-keys))
           (texts (map term--key-text keys)))
      (if (and (pair? texts) (= (length (filter string? texts)) (length texts)))
          (process-send! (current-buffer) (apply string-append texts))
          (message (string-append (string-join keys " ") " is undefined"))))))

(mode-keys! "term-mode"
  (map (lambda (entry) (list (car entry) "term-send-key")) term--key-bytes))

;; The browser holds the scrollback, so a scroll is the window's scroll
;; request: the terminal moves its own view by that many lines.
(define (term--scroll! lines)
  (scroll-window! (active-window) lines))

(define (term--page)
  (max 1 (- (or (window-rows) 24) 2)))

(define-command "term-scroll-up" "Show the older output, one screen back"
  (lambda () (term--scroll! (- (term--page)))))

(define-command "term-scroll-down" "Show the newer output, one screen on"
  (lambda () (term--scroll! (term--page))))

(define-command "term-scroll-to-top" "Show the oldest output the terminal keeps"
  (lambda () (term--scroll! -100000)))

(define-command "term-scroll-to-bottom" "Go back to the prompt"
  (lambda () (term--scroll! 100000)))

(mode-keys! "term-mode"
  '(("M-v" "term-scroll-up") ("<prior>" "term-scroll-up")
    ("C-v" "term-scroll-down") ("<next>" "term-scroll-down")
    ("M-<" "term-scroll-to-top") ("M->" "term-scroll-to-bottom")))

;; ESC belongs to the programs in the terminal (vim, less, the line editor)
(mode-focus-key! "term-mode" "C-g")

(mode-doc! "term-mode"
  "A raw PTY terminal. Full-screen programs and app servers render outside the editor document loop. The bounded transcript stays readable as buffer text. It has the two states of an editable buffer: you land in focus, where the keys are the editor's; the first key you type goes to the terminal and gives it the keyboard, `C-g`, the focus key the title shows, or a window command takes the keyboard back. The Cmd-arrows move to the next window from either state. `ESC` stays the terminal's. The scrollback scrolls from the keyboard: in focus, `M-v` and `C-v` (or the page keys) go a screen back and on, `M-<` to the oldest output and `M->` to the prompt; while typing, Shift with the page keys, Home and End does the same. `M-<down>` and `M-<up>` from another window scroll it too.")

;;; --- program status ---------------------------------------------------------
;;; A program in a terminal says what it is doing with OSC 7501: idle,
;;; working, blocked, done or error, with its app, a kind and a message.
;;; The terminal keeps the newest record and calls here on each change, in
;;; order, with the record before it; here it becomes hooks. A turn starts when the program goes to working,
;;; and ends when it leaves working and blocked: done is a success, error a
;;; failure, idle a turn you stopped, and an exit a program that went away.

(define *term-status* '())             ; (BUF STATUS) rows

(define (term-status buf)
  (let ((e (assoc buf *term-status*)))
    (if e (cadr e) (and (process-running? buf) (terminal-status buf)))))

(define (term--state status) (and status (plist-get status 'state)))
(define (term--in-turn? state) (and (member state '("working" "blocked")) #t))

(define (term--outcome state)
  (cond ((equal? state "done") 'done)
        ((equal? state "error") 'error)
        ((equal? state "idle") 'stopped)
        (else 'exited)))

(define (term--status-changed! buf status was)
  (let* ((from (term--state was))
         (to (term--state status))
         (app (or (and status (plist-get status 'app)) (and was (plist-get was 'app)))))
    (set! *term-status*
          (cons (list buf status) (filter (lambda (e) (not (equal? (car e) buf))) *term-status*)))
    (run-hook-with-args 'terminal-status-hook buf status was)
    (cond ((and (equal? to "working") (not (term--in-turn? from)))
           (run-hook-with-args 'terminal-turn-start-hook buf app))
          ((and (term--in-turn? from) (not (term--in-turn? to)))
           (run-hook-with-args 'terminal-turn-end-hook buf app (term--outcome to)
                               (and status (plist-get status 'msg)))))))

;; through the name, so a reload of the handler takes effect
(on-event! 'terminal (lambda (buf status was) (term--status-changed! buf status was)))

;;; --- session titles ---------------------------------------------------------
;;; An agent titles its session in the terminal title (OSC 0/2): Claude Code
;;; names the topic, Codex the thread. While an agent reports its status,
;;; the shell takes that title as its name, the way a chat takes the label
;;; of its summary (chat-title). The shell's own titles, such as zsh's
;;; user@host: dir, name nothing: no agent reports then.

(defcustom 'term-session-titles #t
  "Name a shell after the session of the agent that runs in it, as a chat is named.")

;; the titles that name the agent, not its session
(define term--generic-titles
  '("claude code" "claude" "codex" "openai codex" "pi" "opencode" "dsh" "dsh-tui" ""))

;; the title without the activity glyph an agent puts before it (✳, ⠂)
(define (term--session-title title)
  (let ((t (string-trim (re-replace "^[^A-Za-z0-9]+" title ""))))
    (and (not (member (string-downcase t) term--generic-titles))
         (if (> (string-length t) chat-title-max-bytes) (substring t 0 chat-title-max-bytes) t))))

;; the shell's name follows a rename, and the hook tells the listings
(define (term--renamed! old new)
  (set! *term-status*
        (map (lambda (e) (if (equal? (car e) old) (list new (cadr e)) e)) *term-status*))
  (run-hook-with-args 'terminal-retitle-hook new old))

;; A session names the shell, and the shell keeps the name it had before
;; (term-home-name). When the agent shows its bare name again, its session
;; ended, as /clear ends it: the shell takes its own name back, and the
;; next session names it anew.
(define (term--title-changed! buf title)
  (when (and term-session-titles (term-status buf))
    (let ((name (term--session-title title))
          (home (buffer-local buf 'term-home-name)))
      (cond
        ((and name (not (equal? name buf)) (not (equal? (buffer-local buf 'chat-title) name)))
         ;; chat-title answers the name it took, TITLE<2> when TITLE is taken
         (let ((new (chat-title buf name)))
           (when new
             (buffer-set-local! new 'term-home-name (or home buf))
             (term--renamed! buf new))))
        ((and (not name) home)
         (buffer-set-locals! buf (list 'term-home-name #f 'chat-title #f))
         (when (and (not (buffer-known? home)) (rename-buffer! buf home))
           (term--renamed! buf home)))))))

(on-event! 'terminal-title (lambda (buf title) (term--title-changed! buf title)))

;;; --- user variables ---------------------------------------------------------
;;; A program in a terminal sets a variable with OSC 1337 SetUserVar, as in
;;; iTerm2 and WezTerm: a shell integration its git branch, an agent's hook
;;; its model. The shell keeps NAME as its local term-NAME, a string. A
;;; program sets only these, never the buffer's own locals, and nothing runs.

(defcustom 'term-user-vars #t
  "Keep the variables a program in a terminal sets (OSC 1337 SetUserVar) as the shell's term- locals.")

(define (term-var-local name) (string->symbol (string-append "term-" name)))

(define (term-var buf name) (buffer-local buf (term-var-local name)))

(define (term--var-changed! buf name value)
  (when term-user-vars
    (buffer-set-locals! buf (list (term-var-local name) value))
    (run-hook-with-args 'terminal-var-hook buf name value)))

(on-event! 'terminal-var (lambda (buf name value) (term--var-changed! buf name value)))

(define (shell--fresh-name base)
  (let loop ((n 2))
    (let ((name (string-append base "<" (number->string n) ">")))
      (if (buffer-known? name) (loop (+ n 1)) name))))

;; A group has one shell of each kind, *PREFIX:GROUP*, found by its role so
;; a renamed group keeps it. FRESH (C-u) gives a new one beside it instead.
(define (shell--buffer prefix role group fresh)
  (let ((base (if group
                  (string-append "*" prefix ":" (group-name group) "*")
                  (string-append "*" prefix "*"))))
    (cond (fresh (if (buffer-known? base) (shell--fresh-name base) base))
          ((and group (group-buffer-as group role)))
          (else base))))

;; the shell starts in the group's directory, else in this buffer's
(define (shell--command group command)
  (let ((dir (or (and group (group-cwd group)) (default-directory))))
    (string-append "cd -- " (sh-quote dir) " && " command)))

(define-command "shell" "Open this group's raw PTY shell; with C-u, a new one"
  (lambda ()
    (let* ((group (frame-group))
           (fresh (current-prefix-arg))
           (buf (shell--buffer "shell" 'shell group fresh)))
      (buffer-create buf)
      (unless (buffer-local buf 'terminal-command)
        (buffer-set-local! buf 'terminal-command
          (shell--command group *terminal-command*)))
      (buffer-set-local! buf 'mode-name "term-mode")
      ;; the group's own shell carries the role, even when C-u made it first
      (when (and group (equal? buf (shell--buffer "shell" 'shell group #f)))
        (buffer-add-group-as! buf group 'shell))
      (with-current-buffer buf
        (lambda () (terminal-mode-init! buf)))
      ;; a shell is a place you type: it takes the window you stand in and
      ;; the keyboard with it. display-buffer only showed it somewhere else
      (switch-to-buffer! buf))))

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

(define-command "comint-shell"
  "Open this group's text-buffer shell; with C-u, a new one"
  (lambda ()
    (let* ((group (frame-group))
           (fresh (current-prefix-arg))
           (buf (shell--buffer "comint-shell" 'comint-shell group fresh)))
      (buffer-create buf)
      (if (not (process-running? buf))
          (start-process! buf (shell--command group *shell-command*)))
      (when (and group
                 (equal? buf (shell--buffer "comint-shell" 'comint-shell group #f)))
        (buffer-add-group-as! buf group 'comint-shell))
      (pop-to-buffer buf)
      (buffer-set-local! buf 'mode-name "comint-shell-mode")
      (end-of-buffer!))))

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
(public! 'term-status "(term-status BUF) — what the program in BUF's terminal last said it is doing (OSC 7501): a plist of state, app, kind, msg; #f before it says anything. terminal-status-hook runs (BUF STATUS WAS) on every change, terminal-turn-start-hook (BUF APP) when it starts working, and terminal-turn-end-hook (BUF APP OUTCOME MSG) when the turn ends, OUTCOME done, error, stopped or exited")
(public! 'term-var "(term-var BUF NAME) — the variable NAME a program in BUF's terminal set with OSC 1337 SetUserVar, kept as the local term-NAME; #f when unset. terminal-var-hook runs (BUF NAME VALUE) on each change, terminal-retitle-hook (NEW OLD) when an agent's session title renames the shell")
(public! 'tail-open "(tail-open PATH) — follow a file with tail -F, local or /ssh: remote")
(public! 'sh-quote "(sh-quote S) — S as one safe single-quoted word for a shell command")

(domain! 'unknown)
(effects! '(unknown))
