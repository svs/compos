;;; agent-sandbox.scm --- an agent's shell commands write only where it works.
;;;
;;; With the sandbox on, every shell command an agent runs goes through
;;; macOS's sandbox-exec, under a profile that lets it write only in the
;;; chat's working directory, the temp directories and the tool caches in
;;; agent-sandbox-writable. The kernel checks every path, through pipes,
;;; variables and globs, so a sandboxed shell command does not ask before
;;; it edits or removes a file: jj keeps what it changed in the work tree.
;;; Your own shell commands do not run in the sandbox.
;;;
;;; Three places decide, the nearest first: the chat's llm-config
;;; (sandbox on, off, or as the group), the chat's group (M-x
;;; group-sandbox), and agent-sandbox for every chat.

;; the sandbox reads the chat's llm-config
(require 'llm-config)

(domain! 'system)
(effects! '(write))
(category! 'system)

(defcustom 'agent-sandbox #t
  "Run the agents' shell commands in the sandbox, unless a chat's group or its llm-config says otherwise."
  'group 'agent 'type 'boolean)

(defcustom 'agent-sandbox-writable
  '("~/.compos" "~/.hex" "~/.mix" "~/.cache" "~/.npm" "~/Library/Caches" "~/.cargo" "~/.docker")
  "Where a sandboxed shell command may write besides the chat's working directory and the temp directories: the editor's own state and the tool caches."
  'group 'agent)

(defcustom 'agent-sandbox-exempt '("jj")
  "Programs that run outside the sandbox: they need to write where it cannot, as jj writes the .jj and .git of every repo. A command skips the sandbox only when each of its parts runs one of these, or cd."
  'group 'agent)

(define agent-sandbox-exec "/usr/bin/sandbox-exec")

;; the shell builtin, kept once: a reload must not wrap the wrapper
(define %shell-command->string-builtin
  (if (boundp '%shell-command->string-builtin) %shell-command->string-builtin shell-command->string))

;; what the sandbox makes safe to run without asking: the shell gate's
;; kinds, and the deny patterns that only a shell command can act on
(define agent-sandbox-covered-kinds '(edit))
(define agent-sandbox-covered-patterns '("rm[-_ ]+-[a-z]*[rf]"))

(effects! '(pure))

(define (agent-sandbox--word v)
  (cond ((member v '(#t on "on")) 'on)
        ((member v '(off "off")) 'off)
        (else #f)))

(effects! '(read))

(define (agent-sandbox-of chat)
  "(agent-sandbox-of CHAT) — on or off for the chat CHAT: its llm-config, else its group, else agent-sandbox"
  (or (and chat (buffer-exists? chat)
           (agent-sandbox--word (buffer-local (llm-config-session chat) 'sandbox)))
      (let ((g (and chat (buffer-exists? chat) (buffer-group chat))))
        (and g (agent-sandbox--word (group-setting g 'sandbox))))
      (if agent-sandbox 'on 'off)))

(define (agent-sandbox--author-chat)
  "the chat whose agent is evaluating now, by the edit author, or #f"
  (let ((author (current-edit-author)))
    (and (string? author) (string-prefix? "agent:" author)
         (agent-buf (substring author 6 (string-length author))))))

(define (agent-sandbox-current-chat)
  "(agent-sandbox-current-chat) — the agent's chat this call runs for: the edit author, else an agent chat that is the current buffer; #f for a person"
  (or (agent-sandbox--author-chat)
      (let ((b (current-buffer)))
        (and b (agent-slug-of b) b))))

(define (agent-sandbox-on? &optional chat)
  "(agent-sandbox-on? [CHAT]) — #t when CHAT, else the agent's chat this call runs for, has the sandbox on and this machine has sandbox-exec"
  (let ((c (or chat (agent-sandbox-current-chat))))
    (and c (equal? (agent-sandbox-of c) 'on) (file-exists? agent-sandbox-exec) #t)))

(effects! '(pure))

(define (agent-sandbox--quote path)
  (string-append "\"" (string-replace (string-replace path "\\" "\\\\") "\"" "\\\"") "\""))

(define (agent-sandbox-profile dirs)
  "(agent-sandbox-profile DIRS) — the profile that lets a command write only under DIRS, which are real paths, and to the devices"
  (string-append
   "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"/dev\")"
   (apply string-append
          (map (lambda (d) (string-append " (subpath " (agent-sandbox--quote d) ")")) dirs))
   ")"))

(define (agent-sandbox-exempt? cmd)
  "(agent-sandbox-exempt? CMD) — #t when every part of CMD runs a program in agent-sandbox-exempt, or cd, and nothing substitutes a command or redirects into a file"
  (and (not (re-match? "`|\\$\\(|<\\(|>\\(" cmd))
       (not (re-match? "(^|[^0-9&>])>>?(?!\\s*(&|/dev/null))" cmd))
       (let ((progs (filter (lambda (w) (not (equal? w "")))
                            (map (lambda (part) (car (string-split (string-append (string-trim part) " ") " ")))
                                 (string-split (re-replace-all "&&|\\|\\||[;|\n]" cmd "\n") "\n")))))
         (and (pair? progs)
              (not (null? (filter (lambda (p) (member p agent-sandbox-exempt)) progs)))
              (null? (filter (lambda (p) (not (or (equal? p "cd") (member p agent-sandbox-exempt)))) progs))))))

(effects! '(read))

(define (agent-sandbox--real path)
  (let ((p (ignore-errors (lambda () (file-realpath path)))))
    (and (string? p)
         (if (and (> (string-length p) 1) (string-suffix? "/" p))
             (substring p 0 (- (string-length p) 1))
             p))))

;; a group names more places its chats work in, in group.scm:
;; (group-defaults! 'writable '("~/src/compos"))
(define (agent-sandbox--group-writable chat)
  (let* ((g (and chat (buffer-exists? chat) (buffer-group chat)))
         (dirs (and g (group-setting g 'writable))))
    (cond ((string? dirs) (list dirs))
          ((pair? dirs) (filter string? dirs))
          (else '()))))

(define (agent-sandbox-dirs chat)
  "(agent-sandbox-dirs CHAT) — where a sandboxed command of CHAT may write: its working directory, its group's 'writable, the temp directories and agent-sandbox-writable, as real paths"
  (filter string?
          (map agent-sandbox--real
               (append (list (chat-cwd-of chat) "/tmp" "/private/var/folders")
                       (agent-sandbox--group-writable chat)
                       agent-sandbox-writable))))

(define (agent-sandbox-command cmd chat)
  "(agent-sandbox-command CMD CHAT) — CMD as it runs in CHAT's sandbox"
  (string-append agent-sandbox-exec " -p " (sh-quote (agent-sandbox-profile (agent-sandbox-dirs chat)))
                 " /bin/sh -c " (sh-quote cmd)))

(define (agent-sandbox-wrap cmd &optional chat)
  "(agent-sandbox-wrap CMD [CHAT]) — CMD in the sandbox when CHAT, else the agent's chat this call runs for, has it on; else CMD"
  (let ((c (or chat (agent-sandbox-current-chat))))
    (if (and c (agent-sandbox-on? c) (not (agent-sandbox-exempt? cmd))) (agent-sandbox-command cmd c) cmd)))

(effects! '(write execute))

(define (shell-command->string cmd &rest more)
  "(shell-command->string CMD [DIR] [CALLBACK]) — run CMD in a shell; stderr merges into the output. With CALLBACK, run in a Task and return at once; CALLBACK gets the output. An agent's command runs in its chat's sandbox when the sandbox is on."
  (apply %shell-command->string-builtin
         (cons (if (agent-sandbox--author-chat) (agent-sandbox-wrap cmd (agent-sandbox--author-chat)) cmd)
               more)))

(effects! '(write))

(define (group-sandbox-set! g value)
  "(group-sandbox-set! G VALUE) — the sandbox for the chats of group G: on, off, or #f to follow agent-sandbox"
  (group-setting-set! g 'sandbox (and (agent-sandbox--word value) (symbol->string (agent-sandbox--word value))))
  (group-setting g 'sandbox))

(define-command "group-sandbox" "Choose the sandbox for this group's chats: on, off, or as every chat"
  (lambda ()
    (let ((g (frame-group)))
      (completing-read "Sandbox for this group: " '("on" "off" "global")
                       (lambda (choice)
                         (when (member choice '("on" "off" "global"))
                           (group-sandbox-set! g (if (equal? choice "global") #f choice))
                           (message (string-append "Sandbox for this group: " choice))))))))

(domain! 'system)
(effects! '(read))
(public! 'agent-sandbox-of "(agent-sandbox-of CHAT) — on or off for CHAT: its llm-config, else its group, else agent-sandbox")
(public! 'agent-sandbox-on? "(agent-sandbox-on? [CHAT]) — #t when CHAT, else the agent's chat this call runs for, has the sandbox on")
(public! 'agent-sandbox-dirs "(agent-sandbox-dirs CHAT) — where a sandboxed command of CHAT may write, as real paths")
(public! 'agent-sandbox-wrap "(agent-sandbox-wrap CMD [CHAT]) — CMD in the sandbox when the chat has it on; else CMD")
(effects! '(pure))
(public! 'agent-sandbox-exempt? "(agent-sandbox-exempt? CMD) — #t when CMD runs only programs in agent-sandbox-exempt, so it skips the sandbox")
(public! 'agent-sandbox-profile "(agent-sandbox-profile DIRS) — the profile that lets a command write only under DIRS")
(effects! '(write))
(public! 'group-sandbox-set! "(group-sandbox-set! G VALUE) — the sandbox for group G's chats: on, off, or #f to follow agent-sandbox")
