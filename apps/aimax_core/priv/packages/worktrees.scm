;;; worktrees.scm --- one git worktree per agent: create, list, review, land.
;;;
;;; M-x workspace-manage pops *worktrees*: one line per workspace of the current
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

(package! 'worktrees 'git)
(domain! 'git)
(effects! '(write external))

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

(define (worktree--behind dir base)
  (let ((n (string->number
             (string-trim
               (shell-command->string
                 (string-append "git rev-list --count HEAD.." (sh-quote base))
                 dir)))))
    (if (number? n) n 0)))

;; Git remains the source of truth. The reminder therefore survives reloads
;; without another persistent buffer local.
(define (workspace--buffers workspace)
  (filter (lambda (b) (equal? (buffer-local b 'workspace-root) workspace))
          (buffer-list)))

(define (workspace--unsaved workspace)
  (length
    (filter (lambda (b) (and (buffer-path b) (buffer-modified? b)))
            (workspace--buffers workspace))))

;;; --- workspace LLM defaults --------------------------------------------------

;; A conversation keeps its own identity once born. Configuration choices also
;; become the defaults for conversations born later in the same workspace.
;; Store the whole record in one local so explicit "default" (#f) values remain
;; distinguishable from a workspace that has never chosen anything.
(define (workspace--llm-defaults-from buf)
  (let ((chat? (or (chat-buffer? buf)
                   (equal? (buffer-local buf 'mode-name) "chat-mode"))))
    (list
      'connector (or (buffer-local buf (if chat? 'agent-connector 'llm-connector))
                     (if chat? *default-connector* "codex-app-server"))
      'model (buffer-local buf (if chat? 'agent-model 'llm-model))
      'effort (buffer-local buf (if chat? 'agent-effort 'llm-effort))
      'presets (or (buffer-local buf 'chat-presets) '())
      'permission-mode
      (or (buffer-local buf 'chat-permission-mode) *permission-default-mode*))))

(define (workspace--llm-defaults workspace)
  (let ((sources
          (filter (lambda (b)
                    (and (equal? (buffer-local b 'workspace-root) workspace)
                         (pair? (buffer-local b 'workspace-llm-defaults))))
                  (buffer-list-mru))))
    (and (pair? sources) (buffer-local (car sources) 'workspace-llm-defaults))))

(define (workspace-llm-defaults-note! buf)
  (let ((workspace (buffer-local buf 'workspace-root)))
    (when workspace
      (let ((defaults (workspace--llm-defaults-from buf)))
        (for-each
          (lambda (b)
            (when (equal? (buffer-local b 'workspace-root) workspace)
              (buffer-set-local! b 'workspace-llm-defaults defaults)))
          (buffer-list))
        defaults))))

(define (workspace--apply-llm-defaults! chat defaults)
  (when (pair? defaults)
    (buffer-set-local! chat 'agent-connector (plist-get defaults 'connector))
    (buffer-set-local! chat 'agent-model (plist-get defaults 'model))
    (buffer-set-local! chat 'agent-effort (plist-get defaults 'effort))
    (buffer-set-local! chat 'chat-presets (or (plist-get defaults 'presets) '()))
    (buffer-set-local! chat 'chat-permission-mode
      (or (plist-get defaults 'permission-mode) *permission-default-mode*))
    (buffer-set-local! chat 'workspace-llm-defaults defaults))
  chat)

(define (workspace--finish-state buf)
  (let ((workspace (buffer-local buf 'workspace-root))
        (project (buffer-local buf 'workspace-project-root))
        (id (buffer-local buf 'workspace-id)))
    (if (and workspace project id (file-directory? workspace))
        (let* ((rows (worktree-list project))
               (base (or (and (pair? rows) (plist-get (car rows) 'branch)) "HEAD"))
               (matches (filter (lambda (wt) (equal? (plist-get wt 'path) workspace)) rows))
               (wt (and (pair? matches) (car matches))))
          (list 'id id 'workspace workspace 'project project 'base base
                'branch (and wt (plist-get wt 'branch))
                'sha (and wt (plist-get wt 'sha))
                'dirty (worktree--dirty workspace)
                'unsaved (workspace--unsaved workspace)
                'ahead (worktree--ahead workspace base)
                'behind (worktree--behind workspace base)))
        #f)))

(define (worktree--class-add! buf name)
  (let ((classes (if (buffer-local buf 'window-class)
                     (string-split (buffer-local buf 'window-class) " ")
                     '())))
    (unless (member name classes)
      (buffer-set-local! buf 'window-class
        (string-join (append classes (list name)) " ")))))

(define (worktree--class-remove! buf name)
  (let ((classes
          (filter (lambda (c) (not (equal? c name)))
                  (if (buffer-local buf 'window-class)
                      (string-split (buffer-local buf 'window-class) " ")
                      '()))))
    (buffer-set-local! buf 'window-class
      (if (null? classes) #f (string-join classes " ")))))

(define (worktree--daemon-port buf)
  (let* ((url (or (buffer-local buf 'workspace-daemon) (editor-url)))
         (colon (and (string? url) (string-rindex url ":"))))
    (if colon
        (let ((tail (substring url (+ colon 1) (string-length url))))
          (if (string-index tail "/")
              (if (string-prefix? "https://" url) "443" "80")
              tail))
        "?")))

(define (worktree-mode--header buf)
  (let ((state (workspace--finish-state buf)))
    (if state
        (string-append
          "WORKTREE " (or (buffer-local buf 'workspace-name)
                            (plist-get state 'id))
          " · PORT " (worktree--daemon-port buf) " · "
          (cond ((or (> (plist-get state 'dirty) 0)
                     (> (plist-get state 'unsaved) 0)) "UNCOMMITTED")
                ((> (plist-get state 'behind) 0) "NEEDS REBASE")
                ((> (plist-get state 'ahead) 0) "UNMERGED")
                (else "READY TO TEARDOWN"))
          " · " (number->string (plist-get state 'ahead)) " ahead"
          " · " (number->string (plist-get state 'behind)) " behind"
          " · " (number->string (plist-get state 'dirty)) " dirty"
          " · " (number->string (plist-get state 'unsaved)) " unsaved"
          " · M-x workspace-diff / workspace-rebase / workspace-land / workspace-cancel")
        "WORKTREE · unavailable")))

(define (worktree-mode--apply! buf)
  (buffer-set-local! buf 'header-line (worktree-mode--header buf))
  (worktree--class-add! buf "workspace-pending"))

(define (worktree-mode--teardown! buf)
  (buffer-set-local! buf 'header-line #f)
  (worktree--class-remove! buf "workspace-pending"))

(register-minor-mode! "worktree-mode" worktree-mode--apply! worktree-mode--teardown!)
(define *worktree-mode-doc*
  "Automatic identity for buffers in a linked Git worktree. A persistent header and window treatment show whether the workspace is uncommitted, behind, unmerged, or ready to tear down.")
(define-command "worktree-mode" "Toggle the current buffer's worktree identity header"
  (lambda () (toggle-minor-mode! "worktree-mode")))
(mode-doc! "worktree-mode" *worktree-mode-doc*)
;; Minor modes predate catalog registration. Stamp this automatic mode
;; explicitly so reload cannot inherit the preceding package's namespace.
(catalog-register! 'mode "worktree-mode" *worktree-mode-doc*
  'package 'worktrees 'namespace 'git 'domain 'git 'effects '(write external)
  'use "(run-command \"worktree-mode\")")

(define (worktree-mode--refresh-workspace! workspace)
  (for-each
    (lambda (b)
      (when (equal? (buffer-local b 'workspace-root) workspace)
        (unless (minor-mode-on? b "worktree-mode")
          (enable-minor-mode! b "worktree-mode"))
        (worktree-mode--apply! b)))
    (buffer-list)))

(define (worktree-mode--maybe-enable! buf)
  (let ((checkout (git-root (buffer-directory buf))))
    (when (string? checkout)
      (let* ((rows (worktree-list checkout))
             (primary (and (pair? rows) (plist-get (car rows) 'path)))
             (matches (filter (lambda (wt) (equal? (plist-get wt 'path) checkout)) rows))
             (wt (and (pair? matches) (car matches))))
        (when (and primary wt (not (equal? checkout primary)))
          (let ((id (or (worktree--slug wt) (worktree--leaf checkout))))
            (workspace--stamp! buf id checkout primary)
            (buffer-set-local! buf 'group checkout)))))))

(add-hook! 'find-file-hook
  (lambda () (worktree-mode--maybe-enable! (current-buffer))))

(set! buffer-workspace-label
  (lambda (b)
    (let ((id (buffer-local b 'workspace-id)))
      (if id
          (string-append "worktree "
                         (or (buffer-local b 'workspace-name) id)
                         " :" (worktree--daemon-port b))
          ""))))

(define *workspace-finish-seen* '())

(define (workspace--finish-fingerprint state)
  (list (plist-get state 'sha)
        (plist-get state 'dirty)
        (plist-get state 'unsaved)
        (plist-get state 'ahead)
        (plist-get state 'behind)))

(define (workspace--remember-finish! state)
  (let ((workspace (plist-get state 'workspace))
        (fingerprint (workspace--finish-fingerprint state)))
    (set! *workspace-finish-seen*
      (cons (list workspace fingerprint)
            (remove (lambda (e) (equal? (car e) workspace))
                    *workspace-finish-seen*)))))

(define (workspace--finish-seen? state)
  (let ((e (assoc (plist-get state 'workspace) *workspace-finish-seen*)))
    (and e (equal? (cadr e) (workspace--finish-fingerprint state)))))

(define (workspace--retire! state)
  (let ((workspace (plist-get state 'workspace))
        (project (plist-get state 'project)))
    (for-each
      (lambda (b)
        (when (minor-mode-on? b "worktree-mode")
          (disable-minor-mode! b "worktree-mode"))
        (if (buffer-path b)
            (buffer-kill! b)
            (begin
              (buffer-set-local! b 'workspace-id #f)
              (buffer-set-local! b 'workspace-name #f)
              (buffer-set-local! b 'workspace-root #f)
              (buffer-set-local! b 'workspace-project-root #f)
              (buffer-set-local! b 'workspace-backend #f)
              (buffer-set-local! b 'workspace-daemon #f)
              (buffer-set-local! b 'default-directory project)
              (buffer-set-local! b 'group project))))
      (workspace--buffers workspace))))

(define (workspace-land-and-teardown! buf)
  (let ((state (workspace--finish-state buf)))
    (when state
      (let ((workspace (plist-get state 'workspace))
            (project (plist-get state 'project))
            (base (plist-get state 'base))
            (branch (plist-get state 'branch)))
        (cond
          ((> (plist-get state 'unsaved) 0)
           (message "workspace has unsaved buffers — save before teardown"))
          ((> (plist-get state 'dirty) 0)
           (message "workspace has uncommitted changes — commit before teardown"))
          ((> (worktree--dirty project) 0)
           (message "primary checkout has uncommitted changes — teardown refused"))
          ((not branch)
           (message "workspace has no branch — teardown refused"))
          (else
            (when (> (plist-get state 'behind) 0)
              (shell-command->string
                (string-append "git rebase " (sh-quote base)) workspace))
            (let ((rebased (workspace--finish-state buf)))
              (if (or (not rebased)
                      (> (plist-get rebased 'dirty) 0)
                      (> (plist-get rebased 'behind) 0))
                  (message "automatic rebase needs attention — workspace kept")
                  (begin
                    (when (> (plist-get rebased 'ahead) 0)
                      (shell-command->string
                        (string-append "git merge --no-ff " (sh-quote branch))
                        project))
                    (let ((landed (workspace--finish-state buf)))
                      (if (and landed (> (plist-get landed 'ahead) 0))
                          (message "automatic merge needs attention — workspace kept")
                          (begin
                            (shell-command->string
                              (string-append "git worktree remove " (sh-quote workspace))
                              project)
                            (if (file-directory? workspace)
                                (message "worktree removal failed — workspace kept")
                                (begin
                                  (when (boundp (quote daemon-release-workspace!))
                                    (daemon-release-workspace! workspace))
                                  (workspace--retire! state)
                                  (message (string-append
                                             "landed and tore down workspace "
                                             (plist-get state 'id)))))))))))))))))

(define (workspace--offer-finish! buf state)
  (when (and (= (plist-get state 'dirty) 0)
             (= (plist-get state 'unsaved) 0)
             (not (workspace--finish-seen? state))
             (not (minibuffer-state)))
    (workspace--remember-finish! state)
    (y-or-n
      (string-append "Land and teardown workspace " (plist-get state 'id)
                     "? Rebase runs automatically")
      (lambda () (workspace-land-and-teardown! buf))
      (lambda ()
        (message (string-append "kept workspace " (plist-get state 'id)
                                " · the red header remains"))))))

(define (workspace-finish-reminder! buf slug)
  (let ((state (workspace--finish-state buf)))
    (when state
      (let ((notice
              (string-append
                "workspace " (plist-get state 'id)
                " · " (number->string (plist-get state 'dirty)) " dirty"
                " · " (number->string (plist-get state 'unsaved)) " unsaved"
                " · " (number->string (plist-get state 'ahead)) " ahead"
                " · " (number->string (plist-get state 'behind)) " behind"
                " · commit to get the land-and-teardown prompt")))
        (message notice)
        (worktree-mode--refresh-workspace! (buffer-local buf 'workspace-root))
        (when (buffer-exists? *worktrees-buffer*)
          (list-refresh! *worktrees-buffer*))
        (workspace--offer-finish! buf state)
        notice))))

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

(define (worktree--chat path)
  (let ((hits
          (filter (lambda (b)
                    (and (chat-buffer? b)
                         (equal? (buffer-local b 'workspace-root) path)))
                  (buffer-list-mru))))
    (if (pair? hits) (car hits) #f)))

(define (worktree--agent-status chat slug)
  (let* ((owner (and chat (buffer-local chat 'agent-slug)))
         (id (or owner slug)))
    (and id (boundp (quote agent-threads))
         (let ((e (assoc id (agent-threads))))
           (and e (let ((s (cadr e)))
                    (if (symbol? s) (symbol->string s) s)))))))

;; rows also pin the base branch (the primary's) on the buffer: render and
;; the commands read it, and the primary row is always the first entry
(define (worktree-rows buf)
  (let* ((root (buffer-local buf 'worktree-root))
         (wts (if root (worktree-list root) '())))
    (buffer-set-local! buf 'worktree-base
      (or (and (pair? wts) (plist-get (car wts) 'branch)) "HEAD"))
    (let ((base (buffer-local buf 'worktree-base)))
      (map
        (lambda (wt)
          (let* ((path (plist-get wt 'path))
                 (primary? (equal? path root))
                 (slug (worktree--slug wt))
                 (chat (worktree--chat path)))
            (append wt
              (list 'dirty (worktree--dirty path)
                    'ahead (if primary? 0 (worktree--ahead path base))
                    'owner (cond (primary? "primary")
                                 ((worktree--agent-status chat slug))
                                 (chat "chat")
                                 (slug "no thread")
                                 (else "-"))))))
        wts))))

(define (worktree-cells buf wt)
  (let* ((root (buffer-local buf 'worktree-root))
         (path (plist-get wt 'path))
         (primary? (equal? path root))
         (dirty (or (plist-get wt 'dirty) 0))
         (ahead (or (plist-get wt 'ahead) 0)))
    (list
      (list (or (plist-get wt 'branch) "(detached)") "accent")
      (list (if primary? "-" (number->string ahead)) (if (> ahead 0) "warn" "dim"))
      (list (number->string dirty) (if (> dirty 0) "alert" "dim"))
      (list (or (plist-get wt 'owner) "-") "dim")
      (list path "faint"))))

(define (worktree-meta buf)
  (string-append (number->string (length (list-entries buf))) " worktrees · base "
                 (or (buffer-local buf 'worktree-base) "HEAD") " · "
                 (or (buffer-local buf 'worktree-root) "?")))

;;; --- commands -------------------------------------------------------------------

(domain! 'code)
(effects! '(write external))

(define (worktree--current)
  (let ((wt (list-current (current-buffer))))
    (or wt (begin (message "no worktree on this line") #f))))

(define (workspace--command-state)
  (if (equal? (current-buffer) *worktrees-buffer*)
      (let* ((buf (current-buffer))
             (wt (worktree--current))
             (root (buffer-local buf 'worktree-root))
             (path (and wt (plist-get wt 'path))))
        (and wt
             (list 'id (or (worktree--slug wt) (plist-get wt 'branch) path)
                   'workspace path
                   'project root
                   'base (or (buffer-local buf 'worktree-base) "HEAD")
                   'branch (plist-get wt 'branch)
                   'sha (plist-get wt 'sha)
                   'dirty (worktree--dirty path)
                   'unsaved (workspace--unsaved path)
                   'ahead (or (plist-get wt 'ahead) 0)
                   'behind (worktree--behind path
                             (or (buffer-local buf 'worktree-base) "HEAD")))))
      (or (workspace--finish-state (current-buffer))
          (begin (message "this buffer is not in a task workspace") #f))))

(define (workspace--refresh-state! state)
  (when state
    (worktree-mode--refresh-workspace! (plist-get state 'workspace))
    (when (buffer-exists? *worktrees-buffer*)
      (list-refresh! *worktrees-buffer*))))

(define-command "workspace-manage" "List and manage the project's task workspaces"
  (lambda ()
    (let ((root (worktrees--root)))
      (if (not root)
          (message "not a git repository")
          (begin
            (buffer-create *worktrees-buffer*)
            (buffer-set-local! *worktrees-buffer* 'worktree-root root)
            (list-mode-show! "worktrees-mode"))))))

(define-command "workspace-visit-files" "Open the selected workspace in dired"
  (lambda ()
    (let ((wt (worktree--current)))
      (when wt (dired-open (plist-get wt 'path))))))

;; the full "what this agent did" view: committed AND uncommitted work,
;; one diff against the base branch
(define-command "workspace-diff" "Diff this workspace against the primary branch"
  (lambda ()
    (let ((state (workspace--command-state)))
      (when state
        (let* ((path (plist-get state 'workspace))
               (project (plist-get state 'project))
               (base (plist-get state 'base))
               (label (plist-get state 'id))
               (text (if (equal? path project)
                         ""
                         (shell-command->string
                           (string-append "git diff " (sh-quote base)) path))))
          (if (equal? (string-trim text) "")
              (message "no differences against the primary branch")
              (let ((out (string-append "*workspace diff: " label "*")))
                (diff-show! out text)
                ;; RET on a file card must open the workspace's copy.
                (buffer-set-local! out 'diff-backend "git")
                (buffer-set-local! out 'diff-root path))))))))

(define-command "workspace-new" "Create a task workspace"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Workspace name: " '()
        (lambda (name)
          (let ((name (string-trim name)))
            (cond ((equal? name "") (message "no name, no worktree"))
                  (else
                    (let ((r (worktree-create (buffer-local buf 'worktree-root) name)))
                      (list-refresh! buf)
                      (message (if (string? r)
                                   (string-append "created " r)
                                   (car (cdr r)))))))))))))

(define-command "workspace-chat" "Jump to the chat that owns this workspace"
  (lambda ()
    (let ((wt (worktree--current)))
      (when wt
        (let* ((path (plist-get wt 'path))
               (chat (worktree--chat path))
               (slug (worktree--slug wt)))
          (cond (chat (switch-to-buffer! chat))
                ((and slug (boundp (quote agent-buf))
                      (buffer-exists? (agent-buf slug)))
                 (switch-to-buffer! (agent-buf slug)))
                (else (message "no chat for this worktree"))))))))

(define-command "workspace-land" "Merge this workspace into the primary checkout"
  (lambda ()
    (let ((state (workspace--command-state)))
      (when state
        (let ((path (plist-get state 'workspace))
              (root (plist-get state 'project))
              (branch (plist-get state 'branch)))
          (cond ((equal? path root) (message "this is the primary checkout"))
                ((not branch) (message "detached workspace — nothing to merge"))
                ((> (plist-get state 'unsaved) 0)
                 (message "workspace has unsaved buffers — save them first"))
                ((> (plist-get state 'dirty) 0)
                 (message "workspace has uncommitted changes — commit them first"))
                ((> (worktree--dirty root) 0)
                 (message "primary checkout has uncommitted changes — merge refused"))
                (else
                  (let ((out (shell-command->string
                               (string-append "git merge --no-ff " (sh-quote branch))
                               root)))
                    (workspace--refresh-state! state)
                    (message (string-trim out))))))))))

(define (workspace--rebase-prompt state)
  (string-append
    "Handle the rebase of this task workspace now.\n\n"
    "Workspace: " (plist-get state 'workspace) "\n"
    "Primary checkout: " (plist-get state 'project) "\n"
    "Primary branch: " (plist-get state 'base) "\n\n"
    "Inspect git status and the commit graph first. Rebase this workspace onto "
    (plist-get state 'base)
    ". Resolve conflicts carefully, preserving the intent of both sides. "
    "Run the relevant tests after resolving conflicts, verify that the workspace "
    "is clean and no rebase is left in progress, then report exactly what changed. "
    "Do not merge, land, or tear down the workspace. If a conflict cannot be "
    "resolved without choosing user intent, use the ask tool with the concrete options."))

(define (workspace--start-rebase-chat! state)
  (let* ((path (plist-get state 'workspace))
         (project (plist-get state 'project))
         (id (plist-get state 'id))
         (owner (and (boundp (quote daemon-workspace-owner))
                     (daemon-workspace-owner path))))
    (if (and owner (not (equal? (plist-get owner 'url) (editor-url))))
        (message "open this workspace with C-x w before rebasing it")
        (let ((chat (group-chat path)))
          (unless (buffer-local chat 'workspace-root)
            (workspace--stamp! chat id path project))
          (buffer-set-local! chat 'group path)
          (group-chat-show! path)
          (let ((slug (or (agent-slug-of chat) (chat-ensure-runtime! chat))))
            (agent-send-msg! slug (workspace--rebase-prompt state))
            (message (string-append "workspace rebase handed to " slug)))))))

(define-command "workspace-rebase" "Open the workspace chat to handle a rebase"
  (lambda ()
    (let ((state (workspace--command-state)))
      (when state
        (let ((path (plist-get state 'workspace))
              (root (plist-get state 'project))
              (branch (plist-get state 'branch)))
          (cond ((equal? path root) (message "this is the primary checkout"))
                ((not branch) (message "detached workspace — nothing to rebase"))
                ((> (plist-get state 'unsaved) 0)
                 (message "workspace has unsaved buffers — save them first"))
                ((> (plist-get state 'dirty) 0)
                 (message "workspace has uncommitted changes — commit them first"))
                (else (workspace--start-rebase-chat! state))))))))

;; Cancel is the flagged x, dired-style. It removes only a clean worktree.
;; The branch stays as a recovery path. The daemon claim does not.
(define (worktree--remove! buf path)
  (let* ((root (or (buffer-local buf 'worktree-root)
                   (buffer-local buf 'workspace-project-root)
                   (worktrees--root)))
         (workspace-buffers (workspace--buffers path))
         (state (and (pair? workspace-buffers)
                     (workspace--finish-state (car workspace-buffers)))))
    (cond ((equal? path root) (message "refusing to remove the primary checkout") #f)
          ((> (workspace--unsaved path) 0)
           (message (string-append path " has unsaved buffers — not removed"))
           #f)
          ((> (worktree--dirty path) 0)
           (message (string-append path " has uncommitted changes — not removed"))
           #f)
          (else
            (shell-command->string
              (string-append "git worktree remove " (sh-quote path)) root)
            (let ((removed? (not (file-directory? path))))
              (when (and removed? (boundp (quote daemon-release-workspace!)))
                (daemon-release-workspace! path))
              (when (and removed? state)
                (workspace--retire! state))
              removed?)))))

(define-command "workspace-manage-refresh" "Refresh the workspace management list"
  (lambda () (list-refresh! *worktrees-buffer*)))

(define-command "workspace-cancel" "Cancel and remove this clean task workspace"
  (lambda ()
    (let ((state (workspace--command-state)))
      (when state
        (let ((path (plist-get state 'workspace))
              (project (plist-get state 'project)))
          (if (equal? path project)
              (message "refusing to remove the primary checkout")
              (y-or-n
                (string-append "Cancel workspace " (plist-get state 'id)
                               "? The branch is kept")
                (lambda ()
                  (if (worktree--remove! (current-buffer) path)
                      (message (string-append "cancelled workspace "
                                              (plist-get state 'id)))
                      (message "workspace was not removed")))
                (lambda () (message "workspace kept")))))))))

(mode-icon! "worktrees-mode" "")

(define-list-mode! "worktrees-mode"
  (list
    'doc (string-append
           "The project's git worktrees: branch, commits ahead of the base, "
           "dirty count, and the agent thread that owns each. RET opens one "
           "in dired; `=` diffs against the primary branch; `r` rebases onto "
           "it; `L` merges into it. `d` flags a clean workspace for cancel, "
           "and `x` confirms. Cancel keeps the branch and releases ownership.")
    'buffer *worktrees-buffer*
    'rows (lambda (buf) (worktree-rows buf))
    'columns (lambda (buf)
               (list (list "branch" 26) (list "ahead" 7 'right)
                     (list "dirty" 7 'right) (list "owner" 12)
                     (list "path" #f)))
    'cells worktree-cells
    'title (lambda (buf) "Workspace changes")
    'meta worktree-meta
    'total (lambda (buf) (length (worktree-rows buf)))
    'footer (lambda (buf)
              '(("RET" "dired") ("=" "diff main") ("r" "rebase main")
                ("L" "merge main") ("c" "create") ("a" "chat")
                ("d" "cancel") ("x" "confirm")
                ("/" "filter") ("g" "refresh") ("q" "quit")))
    'key (lambda (buf wt) (plist-get wt 'path))
    'noun "workspace"
    'markable? (lambda (buf wt)
                 (not (equal? (plist-get wt 'path)
                              (buffer-local buf 'worktree-root))))
    'flags (list (list "d" "D" "cancel"
                       (lambda (buf path) (worktree--remove! buf path))
                       #t))
    'keys '(("RET" "workspace-visit-files") ("=" "workspace-diff")
            ("c" "workspace-new") ("a" "workspace-chat")
            ("r" "workspace-rebase") ("L" "workspace-land")
            ("g" "workspace-manage-refresh")
            ("q" "quit-window"))))

;;; --- spawn wiring: an isolated thread gets its own worktree -------------------

(category! 'code)
(effects! '(write external))

;; A project is the stable parent. Each task worktree is one child workspace.
;; Its group owns one chat. All workspaces stay in this editor daemon.
(define (worktree--primary root)
  (let ((rows (worktree-list root)))
    (and (pair? rows) (plist-get (car rows) 'path))))

(define (worktree--leaf path)
  (let ((parts (path-split path)))
    (if (pair? (cdr parts)) (cadr parts) path)))

(define (workspace--project-name root)
  (worktree--leaf root))

;; The chat namer already spends one small-model call on the user's task.
;; Reuse that name for the workspace instead of making a second naming call.
(define (workspace-name-from-chat! buf name)
  (let ((workspace (buffer-local buf 'workspace-root))
        (project (buffer-local buf 'workspace-project-root)))
    (when (and workspace project (not (equal? (string-trim name) "")))
      (when (boundp (quote daemon-name-workspace!))
        (daemon-name-workspace! workspace (workspace--project-name project) name))
      (for-each
        (lambda (b)
          (when (equal? (buffer-local b 'workspace-root) workspace)
            (buffer-set-local! b 'workspace-name name)
            (when (minor-mode-on? b "worktree-mode")
              (worktree-mode--apply! b))))
        (buffer-list)))
    name))

(define (worktree--next-task-name root)
  (let loop ((n 1))
    (let ((name (string-append "a" (number->string n))))
      (if (file-directory? (worktree-dir root name))
          (loop (+ n 1))
          name))))

(define (worktree--path-under? root path)
  (or (equal? path root)
      (string-prefix? (string-append root "/") path)))

(define (worktree--target-file workspace source)
  (let* ((prefix (string-trim
                   (shell-command->string "git rev-parse --show-prefix"
                                          (buffer-directory source))))
         (leaf (worktree--leaf (buffer-path source))))
    (string-append workspace "/" prefix leaf)))

(define (worktree--runs-aimax? root)
  (and (file-exists? (string-append root "/mix.exs"))
       (file-directory? (string-append root "/apps/aimax_core"))))

(define (worktree--navigate-to-owner! url buf)
  (navigate-url!
    (if (buffer-path buf)
        (string-append url "/b/" (url-encode (buffer-path buf)))
        url)))

(define (worktree--provision-daemon! buf id root)
  (let* ((info (daemon-provision-workspace! root id))
         (url (car info))
         (home (cadr info)))
    (daemon-assign-workspace! (string-append "worktree-" id)
                              url home root)
    (worktree--navigate-to-owner! url buf)
    url))

(define (worktree--daemon-owner! buf id root)
  (let ((owner (and (boundp (quote daemon-workspace-owner))
                    (daemon-workspace-owner root))))
    (cond
      ((and owner
            (equal? (plist-get owner 'url) (editor-url))
            (worktree--runs-aimax? root)
            (not (equal? (daemon-source-root) root)))
        ;; Migrate the old multi-workspace claim to a daemon that runs this
        ;; checkout. The current daemon cannot demonstrate the worktree code.
        (daemon-release-workspace! root)
        (worktree--provision-daemon! buf id root))
      (owner
        (let ((url (plist-get owner 'url)))
          (unless (equal? url (editor-url))
            (worktree--navigate-to-owner! url buf))
          url))
      ((and (worktree--runs-aimax? root)
            (boundp (quote daemon-provision-workspace!)))
        (worktree--provision-daemon! buf id root))
      ((boundp (quote daemon-claim-workspace!))
        (daemon-claim-workspace! root))
      (else #f))))

(define (workspace--stamp! buf id root project-root)
  (let ((owner (worktree--daemon-owner! buf id root)))
    (buffer-set-local! buf 'workspace-id id)
    (buffer-set-local! buf 'workspace-root root)
    (buffer-set-local! buf 'workspace-project-root project-root)
    (buffer-set-local! buf 'workspace-backend "git-worktree")
    (buffer-set-local! buf 'workspace-daemon owner)
    (buffer-set-local! buf 'default-directory root)
    (let* ((entry (and (boundp (quote daemon-workspace-owner))
                       (daemon-workspace-owner root)))
           ;; A registry entry may still carry legacy claimed paths, but the
           ;; human label belongs only to the daemon's active workspace.
           (name (or (and entry
                          (equal? (plist-get entry 'workspace) root)
                          (plist-get entry 'workspace-name))
                     id)))
      (buffer-set-local! buf 'workspace-name name)
      (when (boundp (quote daemon-name-workspace!))
        (daemon-name-workspace! root (workspace--project-name project-root) name)))
    (when (boundp (quote worktree-mode--apply!))
      (unless (minor-mode-on? buf "worktree-mode")
        (enable-minor-mode! buf "worktree-mode"))
      (worktree-mode--apply! buf))
    buf))

;; Open the task copy before code-mode enables its agent surface. Unsaved text
;; follows the user into the task buffer, but the primary buffer stays intact.
(define (code-worktree--open-copy! source primary workspace id)
  (let* ((path (buffer-path source))
         (target (worktree--target-file workspace source))
         (source-text (buffer-text source))
         (source-modified? (buffer-modified? source)))
    (find-file target)
    (with-current-buffer target (lambda () (auto-mode target)))
    (when source-modified?
      (buffer-delete-range! target 0 (buffer-size target))
      (buffer-insert! target 0 source-text))
    (workspace--stamp! target id workspace primary)
    (buffer-set-local! target 'group workspace)
    ;; Replace every visible copy of this source. Other primary buffers stay
    ;; available, but this coding task never edits through their windows.
    (for-each
      (lambda (w)
        (when (equal? (cadr w) source)
          (window-set-buffer! (car w) target)))
      (window-list-all))
    (switch-to-buffer! target)
    target))

;; Return the buffer that code-mode must enable. A buffer in an existing
;; worktree already has isolation, so entering code-mode only stamps it.
(define (worktree-init-buffer! buf)
  (let* ((path (buffer-path buf))
         (checkout (and path (git-root (buffer-directory buf)))))
    (if (not (string? checkout))
        buf
        (let* ((primary (or (worktree--primary checkout) checkout))
               (existing? (not (equal? checkout primary))))
          (if existing?
              (let ((id (or (worktree--slug
                              (let ((rows (filter
                                            (lambda (wt)
                                              (equal? (plist-get wt 'path) checkout))
                                            (worktree-list checkout))))
                                (if (pair? rows) (car rows) '())))
                            (worktree--leaf checkout))))
                (workspace--stamp! buf id checkout primary)
                (buffer-set-local! buf 'group checkout)
                buf)
              (let* ((id (worktree--next-task-name primary))
                     (made (worktree-create primary id)))
                (if (string? made)
                    (code-worktree--open-copy! buf primary made id)
                    (begin
                      (message (string-append "worktree failed: " (cadr made)))
                      buf))))))))

(define-command "workspace-init"
  "Create or enter a task worktree in this browser frame"
  (lambda ()
    (let ((target (worktree-init-buffer! (current-buffer))))
      (enable-minor-mode! target "code-mode")
      (message (string-append "workspace "
                              (or (buffer-local target 'workspace-id) "unchanged")
                              " · one daemon · this frame")))))

;; group-chat calls this after it assigns the group. It copies durable
;; workspace identity from one work buffer into the group's single chat.
(define (workspace-chat-inherit! chat group)
  (let ((owners
          (filter (lambda (b)
                    (and (not (equal? b chat))
                         (equal? (buffer-local b 'workspace-root) group)))
                  (group-buffers group))))
    (when (pair? owners)
      (let ((owner (car owners)))
        (workspace--stamp! chat
          (buffer-local owner 'workspace-id)
          (buffer-local owner 'workspace-root)
          (buffer-local owner 'workspace-project-root))
        (let ((defaults (or (workspace--llm-defaults group)
                            (workspace-llm-defaults-note! owner))))
          (workspace--apply-llm-defaults! chat defaults))))
    chat))

(defcustom 'agent-worktree-isolation #t
  "When true, every new agent inside a Git checkout runs in its own worktree."
  'group 'chat 'type 'boolean)

;; chat-attach-agent! calls this (boundp-guarded) before llm-session-open!.
;; An explicit 'isolated value in OPTS wins; the defcustom sets the default.
;; A thread that
;; already carries a cwd, or a buffer outside any repository, is left
;; alone. Reattach reuses the slug's existing worktree.
(define (worktree--opt-present? opts key)
  (cond ((null? opts) #f)
        ((equal? (car opts) key) #t)
        ((null? (cdr opts)) #f)
        (else (worktree--opt-present? (cdr (cdr opts)) key))))

(define (agent-worktree-opts buf slug opts)
  (let ((opts (or opts '())))
    (let ((workspace (buffer-local buf 'workspace-root))
          (isolated? (if (worktree--opt-present? opts 'isolated)
                         (plist-get opts 'isolated)
                         agent-worktree-isolation)))
      (cond ((plist-get opts 'cwd) opts)
            (workspace (append (list 'cwd workspace) opts))
            ((not isolated?) opts)
            (else
              (let ((root (git-root (buffer-directory buf))))
                (if (not (string? root))
                    opts
                    (let ((dir (worktree-create root slug)))
                      (if (string? dir)
                          (begin
                            (workspace--stamp! buf slug dir root)
                            (append (list 'cwd dir) opts))
                          (begin
                            (message (string-append "worktree failed: " (cadr dir)))
                            opts))))))))))

(category! 'chat)
(public! 'workspace-manage
  "M-x workspace-manage — review, rebase, land, or cancel task workspaces")
(public! 'worktree-create "(worktree-create ROOT NAME) — add ROOT-worktrees/NAME on branch agent/NAME")
(public! 'worktree-list "(worktree-list ROOT) — (path P branch B sha S) per worktree; first is the primary")
(category! 'code)
(effects! '(write external))
(public! 'worktree-init-buffer!
  "(worktree-init-buffer! BUF) — enter or create BUF's isolated coding workspace")
(public! 'workspace-finish-reminder!
  "(workspace-finish-reminder! BUF SLUG) — announce diff, rebase, land, and cancel after a turn")
(public! 'workspace-name-from-chat!
  "(workspace-name-from-chat! BUF NAME) — apply the LLM chat name to its project workspace")
(public! 'workspace-llm-defaults-note!
  "(workspace-llm-defaults-note! BUF) — make BUF's LLM settings the defaults for new workspace chats")
