;;; project.scm — project.el, the compos way: a project is a git checkout.
;;; Pure policy: the root is found by walking up to a .git marker, files
;;; come from git ls-files (so .gitignore is the filter), and known
;;; projects persist one path per line in <compos-home>/projects. The file
;;; prompt leads with the project's open buffers, and C-x p g searches the
;;; project with ripgrep.

(domain! 'project)
(effects! '(write execute))

(define (strip-trailing-slash d)
  (if (and (> (string-length d) 1) (string-suffix? "/" d))
      (substring d 0 (- (string-length d) 1))
      d))

(define (parent-dir d)
  (let ((d (strip-trailing-slash d)))
    (let ((i (string-rindex d "/")))
      (if (and i (> i 0)) (substring d 0 i) "/"))))

;; walk up from DIR looking for .git (dir or file — worktrees); #f if none
(define (project-root-from dir)
  (cond ((or (equal? dir "") (equal? dir "/")) #f)
        ((file-exists? (string-append dir "/.git")) dir)
        (else (project-root-from (parent-dir dir)))))

(define (project-current)
  (project-root-from (strip-trailing-slash (default-directory))))

(define (project-name root)
  (let ((i (string-rindex root "/")))
    (if i (substring root (+ i 1) (string-length root)) root)))

;;; --- project defaults --------------------------------------------------------

;; A project config uses this form:
;;
;;   (project-defaults!
;;     'llm-connector "codex-app-server"
;;     'llm-model "gpt-5.6-sol"
;;     'llm-effort "high")
;;
;; Loading is staged. An evaluation failure does not replace the last valid
;; defaults for that project. The file still runs in the live Scheme session,
;; as requested, so it can also call normal configuration functions.
(define *project-defaults* '())
(define *project-default-root* #f)
(define *project-default-pending* '())

(define (project-defaults-for root)
  (let ((entry (and root (assoc root *project-defaults*))))
    (if entry (car (cdr entry)) '())))

(define (project-defaults-put values key value)
  (cond
    ((null? values) (list key value))
    ((equal? (car values) key)
     (cons key (cons value (cdr (cdr values)))))
    (else
      (cons (car values)
        (cons (car (cdr values))
          (project-defaults-put (cdr (cdr values)) key value))))))

(define (project-default! key value)
  (if (not *project-default-root*)
      (begin (message "project-default! is only valid inside .project.scm") #f)
      (begin
        (set! *project-default-pending*
          (project-defaults-put *project-default-pending* key value))
        value)))

(define (project-defaults! &rest values)
  (let loop ((rest values))
    (cond
      ((null? rest) *project-default-pending*)
      ((null? (cdr rest))
       (message "project-defaults! requires key and value pairs") #f)
      (else
        (project-default! (car rest) (car (cdr rest)))
        (loop (cdr (cdr rest)))))))

(define (project-default-chat? buf)
  ;; Group chats receive chat-mode after buffer creation. Their initial name
  ;; identifies them early enough for defaults to enter durable chat locals.
  (or (chat-buffer? buf) (string-prefix? "*chat" buf)))

(define (project-default-local-key buf key)
  (if (project-default-chat? buf)
      (cond ((equal? key 'llm-connector) 'agent-connector)
            ((equal? key 'llm-model) 'agent-model)
            ((equal? key 'llm-effort) 'agent-effort)
            ((equal? key 'llm-presets) 'chat-presets)
            ((equal? key 'llm-permission-mode) 'chat-permission-mode)
            (else key))
      key))

(define (project-defaults-apply! buf root)
  (let loop ((defaults (project-defaults-for root)))
    (when (pair? defaults)
      (let ((key (project-default-local-key buf (car defaults)))
            (value (car (cdr defaults))))
        ;; A local choice wins. Project values are defaults, not overrides.
        (unless (buffer-local buf key)
          (buffer-set-local! buf key value))
        (loop (cdr (cdr defaults))))))
  buf)

(define (project-buffer-root buf)
  (project-root-cached (strip-trailing-slash (buffer-directory buf))))

(define (project-defaults-apply-project! root)
  (for-each
    (lambda (buf)
      (when (equal? root (project-buffer-root buf))
        (project-defaults-apply! buf root)))
    (buffer-list)))

(define (project-defaults-load! root)
  (let ((path (and root (string-append root "/.project.scm"))))
    (if (not (and path (file-exists? path)))
        (begin
          (set! *project-defaults*
            (remove (lambda (entry) (equal? (car entry) root))
                    *project-defaults*))
          '())
        (let ((source (read-file path)))
          (set! *project-default-root* root)
          (set! *project-default-pending* '())
          (let ((result (eval-string-safe source)))
            (set! *project-default-root* #f)
            (if (equal? (car result) 'ok)
                (begin
                  (set! *project-defaults*
                    (cons (list root *project-default-pending*)
                          (remove (lambda (entry) (equal? (car entry) root))
                                  *project-defaults*)))
                  (project-defaults-apply-project! root)
                  *project-default-pending*)
                (begin
                  (message
                    (string-append ".project.scm error: "
                                   (value->string (car (cdr result)))))
                  #f)))))))

;; the buffer switcher asks for every buffer's project on each prompt
;; open. The .git walk runs once per directory; the cache holds the
;; answer, #f included.
(define *project-root-cache* '())

(define (project-root-cached dir)
  (let ((hit (assoc dir *project-root-cache*)))
    (if hit
        (car (cdr hit))
        (let ((root (project-root-from dir)))
          (set! *project-root-cache*
            (cons (list dir root) *project-root-cache*))
          root))))

;; fill the editor's seams: a buffer's project column is the name of
;; the git root above its file; the root itself feeds the context
;; switch (a project is also a group). A pathless buffer stays
;; projectless.
(set! buffer-project-label
  (lambda (b)
    (let ((p (buffer-path b)))
      (if p
          (let ((root (project-root-cached (parent-dir p))))
            (if root (project-name root) ""))
          ""))))

(set! buffer-project-root
  (lambda (b)
    (let ((p (buffer-path b)))
      (or (and p (project-root-cached (parent-dir p))) ""))))

;; tracked + untracked-but-not-ignored, like projectile
;; Every project-* entry point works inside a discoverable project. A
;; caller outside one gets an error, never an empty answer that reads as
;; "the project holds nothing".
(define (project-require! root)
  (unless (and (string? root)
               (project-root-from (strip-trailing-slash root)))
    (error "no project:" (if (string? root) root "#f")))
  root)

(define (project-files root)
  (project-require! root)
  (filter (lambda (f) (not (equal? f "")))
          (string-split
            (shell-command->string
              "git ls-files --cached --others --exclude-standard" root)
            "\n")))

;;; --- search ------------------------------------------------------------------
;;; project-find-regexp, the consult way: one ripgrep run, then the matches
;;; are candidates. The invoking window previews the highlighted match, so
;;; you read the hit before you commit to it, and C-g puts back the buffer
;;; you came from.

(defgroup 'project "Projects: a project is a git checkout.")

(defcustom 'project-ripgrep-program "rg" "The ripgrep executable." 'group 'project)
(defcustom 'project-ripgrep-args
  "--line-number --no-heading --color never --smart-case --sort path --max-columns 240 --max-columns-preview"
  "Flags for every project-ripgrep run. --sort path makes the result order
the same on every run: without it ripgrep answers in the order its threads
finish, so \"the first match\" is whichever file the disk offered first.
--max-columns truncates a match on a long line: one minified or generated
line can hold megabytes, and a match list is not the place to carry them."
  'group 'project)
(defcustom 'project-ripgrep-limit 500
  "How many matches one search offers." 'group 'project)
(defcustom 'project-ripgrep-max-text 300
  "The longest match text one row keeps. The cap holds for every caller,
with or without --max-columns in project-ripgrep-args." 'group 'project)

;; "./path:line:text" -> (LABEL PATH LINE TEXT); #f for any other line (rg
;; prints an error to stderr, and stderr is folded into the output)
(define (rg--strip-dot p)
  (if (string-prefix? "./" p) (substring p 2 (string-length p)) p))

(define (rg--clip text)
  (if (> (string-length text) project-ripgrep-max-text)
      (string-append (substring text 0 project-ripgrep-max-text) " …")
      text))

(define (rg--parse line)
  (let* ((parts (string-split line ":"))
         (n (and (> (length parts) 2) (string->number (nth 1 parts)))))
    (and (number? n)
         (let ((path (rg--strip-dot (nth 0 parts)))
               (text (rg--clip (string-trim (string-join (cdr (cdr parts)) ":")))))
           (list (string-append path ":" (nth 1 parts)) path n text)))))

;; rg searches the files git names, the same list project-files offers:
;; the project is the git checkout, not everything under root. A root
;; that is not a checkout lists nothing, so it matches nothing — git's
;; error line fails rg--parse and drops. xargs feeds rg explicit file
;; arguments, so rg never falls back to reading stdin.
(define (rg--matches root pattern)
  (let ((out (shell-command->string
               (string-append
                 "git ls-files --cached --others --exclude-standard -z"
                 " | xargs -0 " project-ripgrep-program " " project-ripgrep-args
                 " -e " (sh-quote pattern)
                 " | head -n " (number->string project-ripgrep-limit))
               root)))
    (filter (lambda (m) m) (map rg--parse (string-split out "\n")))))

;; The interactive command below adds preview and selection policy. Agents and
;; other Scheme callers often need the same search as plain structured data.
(define (project-search-matches root pattern)
  (project-require! root)
  (rg--matches root pattern))

;; preview borrows the window, the jump takes it. Both load the file once,
;; so a previewed match costs the same read as an opened one. The mode is
;; set AFTER the window shows the buffer: set-mode! acts on the current
;; buffer, and the preview is what makes it current.
(define (rg--show root m preview?)
  (let ((path (string-append root "/" (nth 1 m))))
    (if preview?
        (begin (window-preview-buffer! (find-file path)) (auto-mode path))
        (visit path))
    (goto-char! (line-start-position (nth 2 m)))))

(define (project-ripgrep-in root pattern)
  (let ((matches (rg--matches root pattern))
        (here (or (window-buffer (active-window)) (current-buffer)))
        (orig (point)))
    (if (null? matches)
        (message (string-append "No matches for " pattern))
        (minibuffer-read-preview
          (string-append (number->string (length matches)) " matches: ")
          (map (lambda (m) (list (nth 0 m) (nth 3 m))) matches)
          (lambda (label)
            (let ((m (assoc label matches))) (when m (rg--show root m #t))))
          (lambda (label)
            (let ((m (assoc label matches)))
              (if m
                  (rg--show root m #f)
                  (begin (window-preview-buffer! here) (goto-char! orig)))))
          (lambda ()
            (window-preview-buffer! here)
            (goto-char! orig))))))

;;; --- known projects ----------------------------------------------------------

(define *projects-file* (string-append (compos-home) "/projects"))

(define (known-projects)
  (let ((text (read-file *projects-file*)))
    (if text
        ;; A project has one canonical identity. Older project files can
        ;; contain both ROOT and ROOT/; keep one row in the picker. A
        ;; trailing slash is also dangerous at use time: joining ROOT/ and
        ;; FILE creates ROOT//FILE, which normalize-file-input correctly
        ;; reads as Emacs' "discard everything before //" syntax.
        (dedupe-names
          (map strip-trailing-slash
               (filter (lambda (l) (not (equal? l "")))
                       (string-split text "\n"))))
        '())))

(define (project-remember! root)
  (when root
    (let ((root (strip-trailing-slash root)))
      (if (not (member root (known-projects)))
          (write-file! *projects-file*
            (string-append (string-join (cons root (known-projects)) "\n") "\n"))))))

;; The compact modeline shows the file in project coordinates, then the
;; project name. These are derived display values, not buffer identity, so
;; keep them out of the persisted buffer-local contract.
(define (project-modeline-refresh!)
  (let* ((buf (current-buffer))
         (path (buffer-path buf))
         (root (and path (project-root-cached (parent-dir path)))))
    (buffer-set-local! buf 'modeline-file
      (or (and root (project--relative root path)) path ""))
    (buffer-set-local! buf 'modeline-project
      (if root (project-name root) ""))))

;; every visited file teaches the editor its project
(add-hook! 'find-file-hook
  (lambda ()
    (project-remember! (project-current))
    (project-modeline-refresh!)))

;; A file visit re-runs the project config. New non-file buffers use the last
;; valid defaults through their inherited default-directory.
(add-hook! 'find-file-hook
  (lambda ()
    (let ((root (project-current)))
      (when root
        (project-defaults-load! root)
        (project-defaults-apply! (current-buffer) root)))))

(on-buffer-created!
  (lambda (buf)
    (let ((root (project-buffer-root buf)))
      (when (and root (pair? (project-defaults-for root)))
        (project-defaults-apply! buf root)))))

;;; --- commands ----------------------------------------------------------------

;; The prompt after "which project" is "which file". It also offers every
;; parent directory from the project file list. Directories lead the files,
;; so a partial path can select and enter a directory. A buffer outside git's
;; list still shows because an open buffer is a real answer.
(define (project--relative root path)
  (let ((prefix (string-append root "/")))
    (and (string-prefix? prefix path)
         (substring path (string-length prefix) (string-length path)))))

(define (project-open-files root)
  (project-require! root)
  (filter (lambda (f) f)
          (map (lambda (b)
                 (let ((p (buffer-path b))) (and p (project--relative root p))))
               (buffer-list-mru))))

;; Return each parent directory in a file path. The trailing slash lets TAB
;; enter the directory and lets RET open it in dired.
(define (project--file-directories file)
  (let loop ((parts (string-split file "/")) (prefix "") (out '()))
    (if (or (null? parts) (null? (cdr parts)))
        (reverse out)
        (let ((dir (string-append prefix (car parts) "/")))
          (loop (cdr parts) dir (cons dir out))))))

(define (project--directories files)
  (let loop ((files files) (out '()))
    (if (null? files)
        (sort (dedupe-names out))
        (loop (cdr files) (append (project--file-directories (car files)) out)))))

;; The root leads, then every directory, then open files in MRU order, then
;; every other file. RET on an untouched prompt opens the project root.
(define (project-file-candidates root)
  (let* ((open (project-open-files root))
         (files (project-files root))
         (dirs (project--directories (append open files)))
         (rest (filter (lambda (f) (not (member f open))) files)))
    (append (list (list "./" "dired"))
            (map (lambda (d) (list d "dired")) dirs)
            (map (lambda (f) (list f "open")) open)
            (map (lambda (f) (list f "")) rest))))

(define (project-dired-input? f) (or (equal? f ".") (equal? f "./")))

;;; Project grouping is an ordered policy table. Each rule is
;;; (NAME PREDICATE RESOLVER). The first matching predicate wins, and its
;;; resolver returns a group name, a group ID, or #f. With no match, the
;;; project root names its group. User config can prepend a narrow rule and
;;; remove it by name while iterating on grouping policy.
(unless (boundp '*project-grouping-rules*)
  (set-symbol-value! '*project-grouping-rules* '()))

(define (add-project-grouping-rule! name predicate resolver)
  (set! *project-grouping-rules*
    (cons (list name predicate resolver)
          (remove (lambda (rule) (equal? (car rule) name))
                  *project-grouping-rules*)))
  name)

(define (remove-project-grouping-rule! name)
  (set! *project-grouping-rules*
    (remove (lambda (rule) (equal? (car rule) name))
            *project-grouping-rules*))
  name)

(define (project-group-target root)
  (let loop ((rules *project-grouping-rules*))
    (cond ((null? rules) root)
          (((nth 1 (car rules)) root) ((nth 2 (car rules)) root))
          (else (loop (cdr rules))))))

(define (project-enter-group-as! root target)
  (let ((id (and target (group-ensure-record! target))))
    (when id
      (for-each (lambda (buf)
                  (when (and (not (buffer-group buf))
                             (equal? (buffer-project-root buf) root))
                    (buffer-add-group! buf id)))
                (buffer-list))
      (switch-to-group! id))
    id))

(define (project-enter-group! root)
  (project-enter-group-as! root (project-group-target root)))

;; git ls-files does not list an ignored file, and it cannot list a file
;; that does not exist yet. Both are real answers to "which file", so the
;; prompt reads the disk as well: the directory you type into leads, its
;; own entries follow, and git's list keeps the rest. Every label stays
;; project-relative, so what you type still matches the whole path.
(define (project--disk-entries root dir)
  (map (lambda (e)
         (list (string-append dir e) (if (string-suffix? "/" e) "dired" "")))
       (list-dir (string-append root "/" dir))))

(define (project--pool root base dir)
  (if (equal? dir "")
      base
      (let ((disk (project--disk-entries root dir)))
        (append (list (list dir "dired"))
                disk
                (filter (lambda (c)
                          (and (not (equal? (car c) dir))
                               (not (assoc (car c) disk))))
                        base)))))

;; Re-list only when the DIRECTORY part changes. A keystroke inside one
;; directory is the display filter's work, and re-listing a big directory
;; on every keystroke stats thousands of files. The memo lives in the
;; closure, so two prompts never share it.
(define (project--nav root base)
  (let ((listed ""))
    (lambda (input)
      (let ((dir (car (path-split (normalize-file-input input)))))
        (if (equal? dir listed)
            #t
            (begin
              (set! listed dir)
              (minibuffer-set-candidates! (project--pool root base dir))))))))

(define (project-find-file-in root)
  ;; Known-project data predates canonical roots and can carry ROOT/. Strip
  ;; it once before the root enters candidates or callback closures. This
  ;; also guarantees that joining a relative candidate produces one slash.
  (let ((root (strip-trailing-slash root)))
    (project-remember! root)
    (let ((g (or (buffer-group (current-buffer)) (frame-group)))
          (base (project-file-candidates root)))
      (minibuffer-read* (string-append "Find file in " (project-name root) ": ")
        base
        (list (list 'change (project--nav root base))
              (list 'style "palette")
              (list 'confirm
                (lambda (f)
                  (if (project-dired-input? f)
                      (visit-in-group root g)
                      ;; the file opens in the current group, like find-file
                      (visit-in-group (string-append root "/" f) g)))))))))

(define-command "project-find-file"
  "Find a file in the current project (git-aware, ignores ignored)"
  (lambda ()
    (let ((root (project-current)))
      (if root
          (project-find-file-in root)
          (message "Not in a project (no .git above)")))))

(define (project-switch-project-read explicit-group?)
  (let ((projects (known-projects)))
    (if (null? projects)
        (message "No known projects yet — visit a file in one first")
        ;; the current project leads: the first option in a switch
        ;; prompt is the place you are in
        (let* ((cur (project-current))
               (ordered (history-order 'project projects))
               (ordered (if (and cur (member cur ordered))
                            (cons cur (remove (lambda (p) (equal? p cur))
                                              ordered))
                            ordered)))
          (minibuffer-read "Switch to project: "
            (map (lambda (p) (list p (project-name p))) ordered)
            (lambda (p)
              (if explicit-group?
                  (group-read-or-create! "Switch project to group: "
                    (lambda (g)
                      (history-push! 'project p)
                      (project-enter-group-as! p g)
                      (project-find-file-in p)))
                  (begin
                    (history-push! 'project p)
                    (project-enter-group! p)
                    (project-find-file-in p)))))))))

(define-command "project-switch-project"
  "Enter a known project's group, then find a file in it"
  (lambda () (project-switch-project-read (current-prefix-arg))))

(define-command "project-switch-project-in-group"
  "Choose a project, then choose or create its destination group"
  (lambda () (project-switch-project-read #t)))

(define-command "find-file-in-new-group"
  "Choose a file, create a group with it, and enter the group"
  (lambda ()
    (read-file-name "Find file in new group: "
      (lambda (path)
        (group-read-new-name "New group: "
          (lambda (name)
            (let ((id (group-record-create! name)))
              (if (not id)
                  (message (string-append "Could not create group " name))
                  (begin
                    (set! *group-current-inhibit* #t)
                    (let ((buf (visit-in-group (normalize-file-input path) id)))
                      (if (not buf)
                          (begin
                            (group-record-delete! id)
                            (set! *group-current-inhibit* #f)
                            (message "Could not visit the file"))
                          (begin
                            (for-each (lambda (member)
                                        (buffer-add-group! member id))
                                      (buffer-family buf))
                            (set! *group-current-inhibit* #f)
                            (switch-to-group! id)
                            (let ((window (window-showing buf)))
                              (if window
                                  (select-window! window)
                                  (switch-to-buffer! buf)))))))))))))))

(define-command "dired-in-group"
  "Choose or create a group, switch to it, then open a directory"
  (lambda ()
    (group-read-or-create! "Switch Dired to group: "
      (lambda (g)
        (switch-to-group! g)
        (read-file-name "Dired (directory): "
          (lambda (path)
            (visit-in-group (normalize-file-input path) g)))))))

(set! find-file-group-reader
  (lambda (receive)
    (group-read-or-create! "Switch file to group: "
      (lambda (group)
        (switch-to-group! group)
        (receive group)))))

(define-command "project-dired"
  "Open dired at the current project's root"
  (lambda ()
    (let ((root (project-current)))
      (if root
          (dired-open root)
          (message "Not in a project (no .git above)")))))

(define-command "project-ripgrep"
  "Search the project with ripgrep, preview the matches, jump to one"
  (lambda ()
    (let ((root (project-current)))
      (if (not root)
          (message "Not in a project (no .git above)")
          (minibuffer-read
            (string-append "Ripgrep " (project-name root) ": ")
            (history-items 'ripgrep)
            (lambda (pattern)
              (if (equal? (string-trim pattern) "")
                  (message "Nothing to search for")
                  (begin (history-push! 'ripgrep pattern)
                         (project-ripgrep-in root pattern)))))))))

;;; --- kill a project ----------------------------------------------------------
;;; A project is also a set of buffers: every buffer whose directory sits
;;; inside the root. That includes a file buffer, a dired listing of a
;;; project directory, and a shell or a chat born there. project-kill-all
;;; ends the whole context in one act. Unsaved work never dies silently:
;;; each modified file asks "Save it?" first, and a file you do not save
;;; stays open. A live process dies with its buffer, as it does in
;;; group-kill. Every question takes one key.

(define (project-buffer? root b)
  (equal? root (project-root-cached (strip-trailing-slash (buffer-directory b)))))

;; internals (space-prefixed) are not yours to kill, so they never count
(define (project-buffers root)
  (filter (lambda (b) (and (not (string-prefix? " " b)) (project-buffer? root b)))
          (buffer-list)))

(define (project-dirty-buffers root)
  (filter (lambda (b) (and (buffer-path b) (buffer-modified? b)))
          (project-buffers root)))

;; One question per modified file, asked in turn: y saves it, n leaves it
;; alone and the buffer joins KEPT. The questions are a chain, not a
;; loop — a prompt answers later, so each answer asks the next one and
;; the last one calls K with the buffers that stay.
(define (project--ask-save dirty kept k)
  (if (null? dirty)
      (k kept)
      (let ((b (car dirty)))
        (y-or-n (string-append "Save " b "?")
          (lambda ()
            (save-buffer-named! b)
            (project--ask-save (cdr dirty) kept k))
          (lambda ()
            (project--ask-save (cdr dirty) (cons b kept) k))))))

(define (project--kill! members kept root)
  (let ((doomed (filter (lambda (b) (not (member b kept))) members)))
    (for-each (lambda (b)
                (if (process-running? b) (process-kill! b))
                (buffer-kill! b))
              doomed)
    (message (string-append "Killed " (number->string (length doomed))
                            " buffers in " (project-name root)
                            (if (pair? kept)
                                (string-append " — kept " (number->string (length kept))
                                               " unsaved")
                                "")))))

(define (project-kill-buffers! root)
  (let ((members (project-buffers root)))
    (project--ask-save (project-dirty-buffers root) '()
      (lambda (kept) (project--kill! members kept root)))))

(define-command "project-kill-all"
  "Kill every buffer in the current project, asking about unsaved files"
  (lambda ()
    (let ((root (project-current)))
      (if (not root)
          (message "Not in a project (no .git above)")
          (let ((members (project-buffers root)))
            (if (null? members)
                (message (string-append "No buffers in " (project-name root)))
                ;; a kill this wide asks first
                (y-or-n (string-append "Kill " (number->string (length members))
                                       " buffers in " (project-name root) "?")
                  (lambda () (project-kill-buffers! root))
                  (lambda () (message "Cancelled")))))))))

(global-set-key "C-x p f" "project-find-file")
(global-set-key "C-x p p" "project-switch-project")
(global-set-key "C-x p d" "project-dired")
(global-set-key "C-x p g" "project-ripgrep")
(global-set-key "C-x p k" "project-kill-all")
(global-set-key "C-x C-g f" "find-file-in-new-group")

(category! 'project)
(catalog-meta! 'command "project-kill-all" 'domain 'project 'effects '(destroy))
(public! 'project-buffers
  "(project-buffers ROOT) -> names of every buffer whose directory is inside ROOT")
(catalog-meta! 'function "project-buffers" 'domain 'project 'effects '(read))
(public! 'project-current "Root of the current project, #f when outside one")
(public! 'project-default!
  "(project-default! KEY VALUE) — set one default while .project.scm runs")
(public! 'project-defaults!
  "(project-defaults! KEY VALUE ...) — set project buffer defaults in .project.scm")
(public! 'project-defaults-for
  "(project-defaults-for ROOT) -> the last valid defaults loaded for ROOT")
(public! 'project-defaults-load!
  "(project-defaults-load! ROOT) — run ROOT/.project.scm and apply its defaults")
(public! 'project-files "(project-files ROOT) -> project file paths, git-aware")
(public! 'project-search-matches
  "(project-search-matches ROOT PATTERN) -> search project text files as (PATH:LINE PATH LINE TEXT) matches")
(catalog-meta! 'function "project-search-matches" 'domain 'project 'effects '(read execute))
(public! 'project-open-files
  "(project-open-files ROOT) -> paths of ROOT's open buffers, relative, MRU first")
(public! 'add-project-grouping-rule!
  "(add-project-grouping-rule! NAME PREDICATE RESOLVER) — prepend a project-to-group rule")
(catalog-meta! 'function "add-project-grouping-rule!" 'domain 'project 'effects '(write))
(public! 'remove-project-grouping-rule!
  "(remove-project-grouping-rule! NAME) — remove one project grouping rule")
(catalog-meta! 'function "remove-project-grouping-rule!" 'domain 'project 'effects '(write))
(public! 'project-group-target
  "(project-group-target ROOT) -> the first rule's group name, group ID, or #f")
(catalog-meta! 'function "project-group-target" 'domain 'project 'effects '(read))
(public! 'project-enter-group!
  "(project-enter-group! ROOT) — resolve, create, and enter the project's group")
(catalog-meta! 'function "project-enter-group!" 'domain 'project 'effects '(write))
(public! 'project-enter-group-as!
  "(project-enter-group-as! ROOT GROUP) — add project buffers and enter GROUP")
(catalog-meta! 'function "project-enter-group-as!" 'domain 'project 'effects '(write))
(public! 'known-projects "Project roots the editor has seen")
(public! 'project-ripgrep-in
  "(project-ripgrep-in ROOT PATTERN) — ripgrep ROOT, then pick a match with preview")
