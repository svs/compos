;;; herdr.scm --- the agents in this group's shells, as an app.
;;;
;;; One row per agent that runs in a shell of the group: Claude Code, Codex,
;;; Pi and the rest, as Herdr shows them. The state is what the agent says
;;; itself with OSC 7501 (term-status, comint.scm): working, blocked, done,
;;; idle or error. An agent that says nothing is found as the program in
;;; the foreground of its shell, and its state is unknown. The rows that
;;; need you come first. A row's page is its shell.

;;;###autoload
(autoload-modes "herdr-mode")

(domain! 'processes)
(effects! '(read))

(define *herdr-app-id* "herdr")

;; the programs that are agents when they own a shell's foreground
(define herdr-agent-programs
  '("claude" "codex" "opencode" "pi" "gemini" "cursor-agent" "copilot" "amp"
    "aider" "goose" "crush" "droid" "kimi" "kilo" "qwen" "grok" "devin"
    "hermes" "omp" "cline" "kiro-cli" "letta" "qodercli"
    ;; DeepSeek: the harness, its TUI and the TUI's short name, and Reasonix
    "dsh" "dsh-tui" "dst" "reasonix"))

;; the worse first: what needs you, then what finished, then what runs
(define herdr--order '("blocked" "error" "done" "working" "idle" "unknown"))

(define (herdr-buffer-name group) (string-append "*herdr:" (group-name group) "*"))

(define (herdr--group buf) (buffer-local buf 'herdr-group))

;; Claude Code's native build is named after its version:
;; ~/.local/share/claude/versions/2.1.318 is claude
(define (herdr--program path)
  (let* ((parts (filter (lambda (p) (not (equal? p ""))) (string-split path "/")))
         (base (if (pair? parts) (car (reverse parts)) path))
         (digit? (and (> (string-length base) 0)
                      (member (substring base 0 1) '("0" "1" "2" "3" "4" "5" "6" "7" "8" "9"))))
         (up (and digit? (> (length parts) 2) (list-ref (reverse parts) 2))))
    (or up base)))

;; the interpreters an agent can run under: the agent is their script
(define herdr--interpreters '("node" "bun" "deno" "python" "python3" "ruby"))

;; the agents a command line runs: its program, or the script an
;; interpreter runs, past the interpreter's flags
;; (node --enable-source-maps /opt/homebrew/bin/claude is claude)
(define (herdr--command-agents line)
  (let* ((words (filter (lambda (w) (not (equal? w ""))) (string-split line " ")))
         (prog (and (pair? words) (herdr--program (car words))))
         (script (and prog (member prog herdr--interpreters)
                      (let ((rest (filter (lambda (w) (not (string-prefix? "-" w))) (cdr words))))
                        (and (pair? rest) (herdr--program (car rest))))))
         (name (or script prog)))
    (if (and name (member name herdr-agent-programs)) (list name) '())))

;; the agent in the foreground of SHELL, or #f
(define (herdr--foreground-agent shell)
  (let ((agents (apply append (map herdr--command-agents (terminal-foreground shell)))))
    (and (pair? agents) (car agents))))

(define (herdr--shells group)
  (filter (lambda (b) (and (equal? (buffer-local b 'render-mode) "terminal") (process-running? b)))
          (group-buffers group)))

;; a row: (shell S agent A state ST kind K msg M), one per shell with an agent
(define (herdr--row shell)
  (let* ((status (term-status shell))
         (live (and status (member (plist-get status 'state) '("working" "blocked" "done" "idle" "error"))))
         (fg (herdr--foreground-agent shell))
         (agent (or fg (and live (plist-get status 'app)))))
    (and agent
         (list 'shell shell 'agent agent
               'state (if live (plist-get status 'state) "unknown")
               'kind (or (and live (plist-get status 'kind)) "")
               'msg (or (and live (plist-get status 'msg)) "")))))

(define (herdr-rows buf)
  (let ((rows (filter (lambda (r) r) (map herdr--row (herdr--shells (herdr--group buf))))))
    (apply append (map (lambda (s) (filter (lambda (r) (equal? (plist-get r 'state) s)) rows))
                       herdr--order))))

(define (herdr--face state)
  (cond ((equal? state "working") "chat-live")
        ((member state '("blocked" "error")) "alert")
        ((equal? state "done") "accent")
        ((equal? state "idle") "chat-idle")
        (else "chat-stopped")))

(define (herdr--glyph state)
  (cond ((equal? state "working") "*") ((equal? state "blocked") "!")
        ((equal? state "done") "+") ((equal? state "error") "x")
        ((equal? state "idle") "-") (else "?")))

(define (herdr--state-label row)
  (let ((s (plist-get row 'state)) (k (plist-get row 'kind)))
    (cond ((and (equal? s "blocked") (not (equal? k ""))) (string-append "needs " k))
          ((equal? s "blocked") "needs you")
          (else s))))

(define (herdr--cells buf row)
  (let ((face (herdr--face (plist-get row 'state))))
    (list (list (herdr--glyph (plist-get row 'state)) face)
          (list (plist-get row 'agent) "default")
          (list (herdr--state-label row) face)
          (list (plist-get row 'shell) "chat-idle")
          (list (plist-get row 'msg) "chat-idle"))))

(define (herdr--narrow-cells buf row)
  (let ((face (herdr--face (plist-get row 'state))))
    (list (list (herdr--glyph (plist-get row 'state)) face)
          (list (plist-get row 'agent) "default")
          (list (herdr--state-label row) face)
          (list (plist-get row 'msg) "chat-idle"))))

(define (herdr--meta buf)
  (let* ((rows (herdr-rows buf))
         (count (lambda (s) (length (filter (lambda (r) (equal? (plist-get r 'state) s)) rows))))
         (need (+ (count "blocked") (count "error"))))
    (string-append (number->string (length rows)) (if (= (length rows) 1) " agent" " agents")
                   (if (> need 0) (string-append ", " (number->string need) " need you") "")
                   (if (> (count "working") 0) (string-append ", " (number->string (count "working")) " working") ""))))

(define-list-mode! "herdr-mode"
  (list
    'doc (string-append
           "The agents in this group's shells, one row each: Claude Code, Codex, Pi and the rest. "
           "The state is what the agent says itself (OSC 7501): working, needs you (blocked, "
           "with what for), done, idle or error. An agent that says nothing shows as unknown. "
           "The rows that need you come first, and the list follows the agents by itself. "
           "RET shows the agent's shell, i interrupts the agent (ESC), g reads the shells again, "
           "/ narrows, and q quits.")
    'transient #f
    'rows herdr-rows
    'columns (lambda (buf) (list (list "" 1) (list "agent" 10) (list "state" 16)
                                 (list "shell" 20) (list "says" #f)))
    'cells herdr--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 72)
                         'columns (lambda (buf) (list (list "" 1) (list "agent" 10) (list "state" 16) (list "says" #f)))
                         'cells herdr--narrow-cells)
                   (list 'name 'wide 'default #t))
    'title (lambda (buf) (string-append "Agents: " (group-name (herdr--group buf))))
    'meta herdr--meta
    'total (lambda (buf) (length (herdr-rows buf)))
    'no-marks #t
    'preview (lambda (buf row) #f)
    'footer (lambda (buf) '(("RET" "shell") ("i" "interrupt") ("g" "refresh") ("/" "filter") ("q" "quit")))
    'keys '(("RET" "herdr-visit") ("i" "herdr-interrupt") ("g" "herdr-refresh") ("q" "quit-window"))))

(effects! '(write display))

(define (herdr-refresh! &optional group)
  (for-each (lambda (b)
              (when (and (buffer-exists? b) (or (not group) (equal? (herdr--group b) group)))
                (list-refresh! b)))
            (filter (lambda (b) (buffer-local b 'herdr-group)) (buffer-list))))

;; a status change redraws the listing of the shell's group
(add-hook! 'terminal-status-hook
  (lambda (shell status was) (herdr-refresh! (buffer-group shell))))

(define-command "herdr-refresh" "Read this group's shells again"
  (lambda () (herdr-refresh! (herdr--group (current-buffer)))))

;; the shell goes where it is already on screen, else to the other window;
;; the focus stays in the list
(define (herdr-show! shell)
  (let ((win (window-showing shell)))
    (if win
        (message (string-append shell " is on screen"))
        (display-buffer-other-window! shell))))

(define-command "herdr-visit" "Show the shell of the agent on this row"
  (lambda ()
    (let ((row (list-current (current-buffer))))
      (if row (herdr-show! (plist-get row 'shell)) (message "no agent here")))))

(define-command "herdr-interrupt" "Interrupt the agent on this row, as ESC does in it"
  (lambda ()
    (let ((row (list-current (current-buffer))))
      (when row
        (process-send! (plist-get row 'shell) "\x1b;")
        (message (string-append "interrupted " (plist-get row 'agent) " in " (plist-get row 'shell)))))))

(define (herdr-listing! group)
  (let ((buf (herdr-buffer-name group)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'herdr-group group)
    (app-claim! buf *herdr-app-id* 'home)
    (buffer-join-here! buf)
    (unless (buffer-derived-mode? buf "herdr-mode")
      (with-current-buffer buf (lambda () (set-mode! "herdr-mode"))))
    buf))

;;;###autoload
(define-command "herdr" "Show the agents in this group's shells and what each is doing"
  (lambda ()
    (let ((group (frame-group)))
      (if (not group)
          (message "herdr lists the agents of a group; this frame is in none")
          (let ((buf (herdr-listing! group)))
            (list-refresh! buf)
            (app-open! buf))))))

(domain! 'processes)
(effects! '(read))
(public! 'herdr-rows "(herdr-rows BUF) — the agent rows of a herdr listing: (shell S agent A state ST kind K msg M), the ones that need you first")
(effects! '(write display))
(public! 'herdr "(herdr) — show the agents in this group's shells and what each is doing")
