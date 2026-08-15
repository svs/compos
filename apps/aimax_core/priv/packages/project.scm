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
  (minibuffer-read (string-append "Find file in " (project-name root) ": ")
    (project-file-candidates root)
    (lambda (f)
      (if (equal? f ".")
          (dired-open root)
          ;; visit shows an open buffer as it is — same call for both
          (visit (string-append root "/" f))))))

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
          (minibuffer-read "Switch to project: "
            (map (lambda (p) (list p (project-name p)))
                 (history-order 'project projects))
            (lambda (p)
              (history-push! 'project p)
              (project-find-file-in p)))))))

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

(global-set-key "C-x p f" "project-find-file")
(global-set-key "C-x p p" "project-switch-project")
(global-set-key "C-x p d" "project-dired")
(global-set-key "C-x p g" "project-ripgrep")

(category! 'project)
(public! 'project-current "Root of the current project, #f when outside one")
(public! 'project-files "(project-files ROOT) -> project file paths, git-aware")
(public! 'project-open-files
  "(project-open-files ROOT) -> paths of ROOT's open buffers, relative, MRU first")
(public! 'known-projects "Project roots the editor has seen")
(public! 'project-ripgrep-in
  "(project-ripgrep-in ROOT PATTERN) — ripgrep ROOT, then pick a match with preview")
