;;; project.scm — project.el, the ai-max way: a project is a git checkout.
;;; Pure policy: the root is found by walking up to a .git marker, files
;;; come from git ls-files (so .gitignore is the filter), and known
;;; projects persist one path per line in <aimax-home>/projects. The file
;;; prompt leads with the project's open buffers, and C-x p g searches the
;;; project with ripgrep.

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
(define (project-files root)
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
(defcustom 'project-ripgrep-args "--line-number --no-heading --color never --smart-case"
  "Flags for every project-ripgrep run." 'group 'project)
(defcustom 'project-ripgrep-limit 500
  "How many matches one search offers." 'group 'project)

;; "./path:line:text" -> (LABEL PATH LINE TEXT); #f for any other line (rg
;; prints an error to stderr, and stderr is folded into the output)
(define (rg--strip-dot p)
  (if (string-prefix? "./" p) (substring p 2 (string-length p)) p))

(define (rg--parse line)
  (let* ((parts (string-split line ":"))
         (n (and (> (length parts) 2) (string->number (nth 1 parts)))))
    (and (number? n)
         (let ((path (rg--strip-dot (nth 0 parts)))
               (text (string-trim (string-join (cdr (cdr parts)) ":"))))
           (list (string-append path ":" (nth 1 parts)) path n text)))))

;; the search path is explicit: rg with no path and no terminal on stdin
;; reads stdin and waits forever, which hangs the whole editor
(define (rg--matches root pattern)
  (let ((out (shell-command->string
               (string-append project-ripgrep-program " " project-ripgrep-args
                              " -e " (sh-quote pattern) " ."
                              " | head -n " (number->string project-ripgrep-limit))
               root)))
    (filter (lambda (m) m) (map rg--parse (string-split out "\n")))))

;; The interactive command below adds preview and selection policy. Agents and
;; other Scheme callers often need the same search as plain structured data.
(define (project-search-matches root pattern)
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

(define *projects-file* (string-append (aimax-home) "/projects"))

(define (known-projects)
  (let ((text (read-file *projects-file*)))
    (if text
        (filter (lambda (l) (not (equal? l ""))) (string-split text "\n"))
        '())))

(define (project-remember! root)
  (if (and root (not (member root (known-projects))))
      (write-file! *projects-file*
        (string-append (string-join (cons root (known-projects)) "\n") "\n"))))

;; every visited file teaches the editor its project
(add-hook! 'find-file-hook
  (lambda () (project-remember! (project-current))))

;;; --- commands ----------------------------------------------------------------

;; The prompt after "which project" is "which file", and the answer is
;; usually a file you already have open. So the candidates lead with this
;; project's open buffers, MRU first, then "." for the root in dired, then
;; every other file git knows. A buffer outside git's list (an ignored
;; file, a new file) still shows: it is open, so it is a real answer.
(define (project--relative root path)
  (let ((prefix (string-append root "/")))
    (and (string-prefix? prefix path)
         (substring path (string-length prefix) (string-length path)))))

(define (project-open-files root)
  (filter (lambda (f) f)
          (map (lambda (b)
                 (let ((p (buffer-path b))) (and p (project--relative root p))))
               (buffer-list-mru))))

(define (project-file-candidates root)
  (let* ((open (project-open-files root))
         (rest (filter (lambda (f) (not (member f open))) (project-files root))))
    (append (map (lambda (f) (list f "open")) open)
            (list (list "." "dired"))
            (map (lambda (f) (list f "")) rest))))

(define (project-find-file-in root)
  (project-remember! root)
  (let ((g (buffer-group (current-buffer))))
    (minibuffer-read (string-append "Find file in " (project-name root) ": ")
      (project-file-candidates root)
      (lambda (f)
        (if (equal? f ".")
            (dired-open root)
            ;; the file opens in the current group, like find-file
            (visit-in-group (string-append root "/" f) g))))))

(define-command "project-find-file"
  "Find a file in the current project (git-aware, ignores ignored)"
  (lambda ()
    (let ((root (project-current)))
      (if root
          (project-find-file-in root)
          (message "Not in a project (no .git above)")))))

(define-command "project-switch-project"
  "Pick a known project, then find a file in it"
  (lambda ()
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
                (history-push! 'project p)
                (project-find-file-in p))))))))

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

(category! 'project)
(catalog-meta! 'command "project-kill-all" 'domain 'project 'effects '(destroy))
(public! 'project-buffers
  "(project-buffers ROOT) -> names of every buffer whose directory is inside ROOT")
(catalog-meta! 'function "project-buffers" 'domain 'project 'effects '(read))
(public! 'project-current "Root of the current project, #f when outside one")
(public! 'project-files "(project-files ROOT) -> project file paths, git-aware")
(public! 'project-search-matches
  "(project-search-matches ROOT PATTERN) -> search project text files as (PATH:LINE PATH LINE TEXT) matches")
(catalog-meta! 'function "project-search-matches" 'domain 'project 'effects '(read execute))
(public! 'project-open-files
  "(project-open-files ROOT) -> paths of ROOT's open buffers, relative, MRU first")
(public! 'known-projects "Project roots the editor has seen")
(public! 'project-ripgrep-in
  "(project-ripgrep-in ROOT PATTERN) — ripgrep ROOT, then pick a match with preview")
