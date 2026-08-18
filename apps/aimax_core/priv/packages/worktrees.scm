;;; worktrees.scm --- one git worktree per agent: create, list, review, land.
;;;
;;; M-x worktrees pops *worktrees*: one line per worktree of the current
;;; project — branch, commits ahead of the base, dirty count, the owning
;;; agent thread and its status. RET opens the worktree in dired, `=`
;;; diffs it against the base branch, `c` creates one, `a` jumps to the
;;; thread's chat, `L` merges the branch into the primary checkout, `d`
;;; flags for removal and `x` removes.
;;;
;;; The other half is spawn wiring: with `agent-worktree-isolation` on (or
;;; `'isolated #t` in the attach opts), a new ACP thread gets its own
;;; worktree as cwd — its file edits land there, not in your tree. The
;;; worktree is named after the thread slug, so buffer-authors, the
;;; AIMAX_AGENT env, and the branch all carry the same identity.

(define *worktrees-buffer* "*worktrees*")
(add-display-rule! *worktrees-buffer* 'popup)

;;; --- mechanism: git worktree via the shell -----------------------------------

;; worktrees live NEXT TO the root ("/x/proj" -> "/x/proj-worktrees/NAME"):
;; inside it they would shadow project files and churn the file watchers
(define (worktree-base root) (string-append root "-worktrees"))

(define (worktree-dir root name) (string-append (worktree-base root) "/" name))

;; branch agent/NAME from the root's HEAD. Returns the directory, or
;; (error MSG) with git's own words.
(define (worktree-create root name)
  (let ((dir (worktree-dir root name)))
    (if (file-directory? dir)
        dir
        (let ((out (shell-command->string
                     (string-append "git worktree add -b "
                                    (sh-quote (string-append "agent/" name))
                                    " " (sh-quote dir))
                     root)))
          (if (file-directory? dir) dir (list 'error (string-trim out)))))))

;; (path P branch B sha S) per worktree; the first entry is the primary
(define (worktree-list root)
  (let loop ((lines (string-split
                      (shell-command->string "git worktree list --porcelain" root)
                      "\n"))
             (cur '()) (acc '()))
    (cond ((null? lines)
           (reverse (if (null? cur) acc (cons cur acc))))
          ((equal? (car lines) "")
           (loop (cdr lines) '() (if (null? cur) acc (cons cur acc))))
          ((string-prefix? "worktree " (car lines))
           (loop (cdr lines)
                 (append cur (list 'path (substring (car lines) 9
                                                    (string-length (car lines)))))
                 acc))
          ((string-prefix? "branch refs/heads/" (car lines))
           (loop (cdr lines)
                 (append cur (list 'branch (substring (car lines) 18
                                                      (string-length (car lines)))))
                 acc))
          ((string-prefix? "HEAD " (car lines))
           (loop (cdr lines)
                 (append cur (list 'sha (substring (car lines) 5
                                                   (string-length (car lines)))))
                 acc))
          (else (loop (cdr lines) cur acc)))))

(define (worktree--lines out)
  (filter (lambda (l) (not (equal? l ""))) (string-split out "\n")))

(define (worktree--dirty dir)
  (length (worktree--lines (shell-command->string "git status --porcelain" dir))))

(define (worktree--ahead dir base)
  (let ((n (string->number
             (string-trim
               (shell-command->string
                 (string-append "git rev-list --count " (sh-quote base) "..HEAD")
                 dir)))))
    (if (number? n) n 0)))

;;; --- the project this buffer is about ----------------------------------------

;; the current buffer's repository, else the most recent buffer that has
;; one (the git.scm C-x g rule: from a chat, "the project I work in")
(define (worktrees--root)
  (let ((here (git-root (default-directory))))
    (if (string? here)
        here
        (let loop ((bs (buffer-list-mru)) (left 10))
          (cond ((or (null? bs) (= left 0)) #f)
                ((let ((r (git-root (buffer-directory (car bs)))))
                   (and (string? r) r)))
                (else (loop (cdr bs) (- left 1))))))))

;;; --- rows ---------------------------------------------------------------------

(define (worktree--slug wt)
  (let ((b (or (plist-get wt 'branch) "")))
    (and (string-prefix? "agent/" b)
         (substring b 6 (string-length b)))))

(define (worktree--agent-status slug)
  (and slug (boundp (quote agent-threads))
       (let ((e (assoc slug (agent-threads))))
         (and e (let ((s (car (cdr e))))
                  (if (symbol? s) (symbol->string s) s))))))

;; rows also pin the base branch (the primary's) on the buffer: render and
;; the commands read it, and the primary row is always the first entry
(define (worktree-rows buf)
  (let* ((root (buffer-local buf 'worktree-root))
         (wts (if root (worktree-list root) '())))
    (buffer-set-local! buf 'worktree-base
      (or (and (pair? wts) (plist-get (car wts) 'branch)) "HEAD"))
    wts))

(define (worktree-line buf wt)
  (let* ((root (buffer-local buf 'worktree-root))
         (base (or (buffer-local buf 'worktree-base) "HEAD"))
         (path (plist-get wt 'path))
         (primary? (equal? path root))
         (dirty (worktree--dirty path))
         (slug (worktree--slug wt)))
    (string-append
      (string-pad-right (or (plist-get wt 'branch) "(detached)") 26)
      (string-pad-left (if primary? "-" (number->string (worktree--ahead path base))) 5)
      " ahead"
      (string-pad-left (number->string dirty) 5) " dirty  "
      (string-pad-right
        (cond (primary? "primary")
              ((worktree--agent-status slug))
              (slug "no thread")
              (else "-"))
        12)
      path)))

;;; --- commands -------------------------------------------------------------------

(define (worktree--current)
  (let ((wt (list-current (current-buffer))))
    (or wt (begin (message "no worktree on this line") #f))))

(define-command "worktrees" "List the project's git worktrees"
  (lambda ()
    (let ((root (worktrees--root)))
      (if (not root)
          (message "not a git repository")
          (begin
            (buffer-create *worktrees-buffer*)
            (buffer-set-local! *worktrees-buffer* 'worktree-root root)
            (list-mode-show! "worktrees-mode"))))))

(define-command "worktree-visit" "Open the worktree at point in dired"
  (lambda ()
    (let ((wt (worktree--current)))
      (when wt (dired-open (plist-get wt 'path))))))

;; the full "what this agent did" view: committed AND uncommitted work,
;; one diff against the base branch
(define-command "worktree-diff" "Diff the worktree at point against the base branch"
  (lambda ()
    (let ((wt (worktree--current))
          (buf (current-buffer)))
      (when wt
        (let* ((path (plist-get wt 'path))
               (base (or (buffer-local buf 'worktree-base) "HEAD"))
               (label (or (worktree--slug wt) (plist-get wt 'branch) path))
               (text (if (equal? path (buffer-local buf 'worktree-root))
                         ""
                         (shell-command->string
                           (string-append "git diff " (sh-quote base)) path))))
          (if (equal? (string-trim text) "")
              (message "no differences against the base")
              (let ((out (string-append "*worktree diff: " label "*")))
                (diff-show! out text)
                ;; RET on a file card must open the worktree's copy
                (buffer-set-local! out 'diff-backend "git")
                (buffer-set-local! out 'diff-root path))))))))

(define-command "worktree-new" "Create a worktree (and its agent/NAME branch)"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Worktree name: " '()
        (lambda (name)
          (let ((name (string-trim name)))
            (cond ((equal? name "") (message "no name, no worktree"))
                  (else
                    (let ((r (worktree-create (buffer-local buf 'worktree-root) name)))
                      (list-refresh! buf)
                      (message (if (string? r)
                                   (string-append "created " r)
                                   (car (cdr r)))))))))))))

(define-command "worktree-chat" "Jump to the chat of the thread that owns this worktree"
  (lambda ()
    (let ((wt (worktree--current)))
      (when wt
        (let ((slug (worktree--slug wt)))
          (if (and slug (boundp (quote agent-buf))
                   (buffer-exists? (agent-buf slug)))
              (switch-to-buffer! (agent-buf slug))
              (message "no chat for this worktree")))))))

(define-command "worktree-land" "Merge this worktree's branch into the primary checkout"
  (lambda ()
    (let* ((buf (current-buffer))
           (root (buffer-local buf 'worktree-root))
           (wt (worktree--current)))
      (when wt
        (let ((path (plist-get wt 'path))
              (branch (plist-get wt 'branch)))
          (cond ((equal? path root) (message "this IS the primary checkout"))
                ((not branch) (message "detached worktree — nothing to merge"))
                ((> (worktree--dirty path) 0)
                 (message "worktree has uncommitted changes — commit them there first"))
                (else
                  (let ((out (shell-command->string
                               (string-append "git merge --no-ff " (sh-quote branch))
                               root)))
                    (list-refresh! buf)
                    (message (string-trim out))))))))))

;; removal is the flagged x, dired-style. The branch stays: -d refuses
;; unmerged work, and a landed branch dies with it.
(define (worktree--remove! buf path)
  (let ((root (buffer-local buf 'worktree-root)))
    (cond ((equal? path root) (message "refusing to remove the primary checkout") #f)
          ((> (worktree--dirty path) 0)
           (message (string-append path " has uncommitted changes — not removed"))
           #f)
          (else
            (shell-command->string
              (string-append "git worktree remove " (sh-quote path)) root)
            (not (file-directory? path))))))

(define-command "worktrees-refresh" "Refresh the worktree list"
  (lambda () (list-refresh! *worktrees-buffer*)))

(mode-icon! "worktrees-mode" "")

(define-list-mode! "worktrees-mode"
  (list
    'doc (string-append
           "The project's git worktrees: branch, commits ahead of the base, "
           "dirty count, and the agent thread that owns each. RET opens one "
           "in dired; `=` shows everything it changed against the base "
           "branch; `L` merges its branch into the primary checkout; `c` "
           "creates a worktree; `a` jumps to the owning chat; `d` flags and "
           "`x` removes (a dirty worktree refuses).")
    'buffer *worktrees-buffer*
    'rows (lambda (buf) (worktree-rows buf))
    'render (lambda (buf wt) (worktree-line buf wt))
    'key (lambda (buf wt) (plist-get wt 'path))
    'noun "worktree"
    'markable? (lambda (buf wt)
                 (not (equal? (plist-get wt 'path)
                              (buffer-local buf 'worktree-root))))
    'flags (list (list "d" "D" "remove"
                       (lambda (buf path) (worktree--remove! buf path))
                       #t))
    'header (lambda (buf)
              (string-append
                ";; worktrees of " (or (buffer-local buf 'worktree-root) "?")
                " — RET dired · = diff vs base · c create · a chat · "
                "L land · d flag · x remove · g refresh"))
    'keys '(("RET" "worktree-visit") ("=" "worktree-diff")
            ("c" "worktree-new") ("a" "worktree-chat")
            ("L" "worktree-land") ("g" "worktrees-refresh")
            ("q" "quit-window"))))

;;; --- spawn wiring: an isolated thread gets its own worktree -------------------

(defcustom 'agent-worktree-isolation #f
  "When true, a new ACP thread runs in its own git worktree."
  'group 'chat 'type 'boolean)

;; chat-attach-agent! calls this (boundp-guarded) before llm-session-open!.
;; 'isolated in OPTS wins; the defcustom sets the default. A thread that
;; already carries a cwd, or a buffer outside any repository, is left
;; alone. Reattach reuses the slug's existing worktree.
(define (agent-worktree-opts buf slug opts)
  (let ((opts (or opts '())))
    (if (or (not (or (plist-get opts 'isolated) agent-worktree-isolation))
            (plist-get opts 'cwd))
        opts
        (let ((root (git-root (buffer-directory buf))))
          (if (not (string? root))
              opts
              (let ((dir (worktree-create root slug)))
                (if (string? dir)
                    (append (list 'cwd dir) opts)
                    (begin
                      (message (string-append "worktree failed: " (car (cdr dir))))
                      opts))))))))

(category! 'chat)
(public! 'worktrees "M-x worktrees — the project's worktrees: review, land, remove")
(public! 'worktree-create "(worktree-create ROOT NAME) — add ROOT-worktrees/NAME on branch agent/NAME")
(public! 'worktree-list "(worktree-list ROOT) — (path P branch B sha S) per worktree; first is the primary")
