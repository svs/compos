;;; project.scm — project.el, the ai-max way: a project is a git checkout.
;;; Pure policy: the root is found by walking up to a .git marker, files
;;; come from git ls-files (so .gitignore is the filter), and known
;;; projects persist one path per line in <aimax-home>/projects.

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

(define (project-find-file-in root)
  (project-remember! root)
  (minibuffer-read (string-append "Find file in " (project-name root) ": ")
    (project-files root)
    (lambda (f) (visit (string-append root "/" f)))))

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

(global-set-key "C-x p f" "project-find-file")
(global-set-key "C-x p p" "project-switch-project")
(global-set-key "C-x p d" "project-dired")

(category! 'project)
(public! 'project-current "Root of the current project, #f when outside one")
(public! 'project-files "(project-files ROOT) -> project file paths, git-aware")
(public! 'known-projects "Project roots the editor has seen")
