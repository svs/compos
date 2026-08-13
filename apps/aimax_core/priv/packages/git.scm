;;; git.scm --- git as a diff-mode backend.
;;;
;;; diff-mode.scm draws sections, cards and hunks and knows no source
;;; control. This file supplies the git data: what is unstaged, what is
;;; staged, what git does not track yet, and the recent history. Another
;;; backend — a patch file, two directories, an agent's proposed edits —
;;; registers the same three functions and gets the same buffer.
;;;
;;; M-x git-diff (C-x g) opens the diff for the directory you are in. In a
;;; subdirectory the diff covers only that subtree, and the buffer is named
;;; for the scope.

(define git-log-count 20)

(define (git--ok v) (if (diff--error? v) '() v))

(define (git--buf-name label) (string-append "*git: " label "*"))

;; untracked files never appear in a diff against HEAD, and they are exactly
;; what an agent just wrote. Show them as empty cards; "untracked" is a git
;; word, so git says it, not diff-mode.
(define (git--untracked status names)
  (if (diff--error? status)
      '()
      (let loop ((es status) (acc '()))
        (cond ((null? es) (reverse acc))
              ((and (equal? (diff--get (car es) 'index) "?")
                    (not (member (diff--get (car es) 'path) names)))
               (loop (cdr es)
                     (cons (list 'file-a #f
                                 'file-b (diff--get (car es) 'path)
                                 'binary? #f
                                 'status "untracked"
                                 'hunks '())
                           acc)))
              (else (loop (cdr es) acc))))))

;; Newest first. Watching an agent work, the file it just touched is the one
;; you want at the top; a deleted file has no mtime and sorts last.
(define (git--by-mtime root files)
  (map cadr
       (sort (map (lambda (f)
                    (list (- 0 (file-mtime (string-append root "/" (diff--name f)))) f))
                  files))))

;; The backend read: four git calls chained off the Session — unstaged is
;; the working tree against the index, staged is the index against HEAD —
;; then one answer for diff-mode.
(define (git--read buf cb)
  (let ((root (buffer-local buf 'diff-root))
        (scope (diff-scope buf)))
    (when root
      (git-status root (or scope "")
        (lambda (status)
          (git-diff root (list 'base #f 'path scope)
            (lambda (unstaged)
              (git-diff root (list 'base "HEAD" 'staged #t 'path scope)
                (lambda (staged)
                  (git-log root git-log-count (or scope "")
                    (lambda (commits)
                      (let* ((un (git--ok unstaged))
                             (st (git--ok staged))
                             (tracked (append (map diff--name un) (map diff--name st))))
                        (cb (list (list "Unstaged changes" (git--by-mtime root un))
                                  (list "Staged changes" (git--by-mtime root st))
                                  (list "Untracked files"
                                        (git--by-mtime root (git--untracked status tracked))))
                            (git--ok commits))))))))))))))

(define (git--resolve buf file)
  (let ((root (buffer-local buf 'diff-root)))
    (and root (string-append root "/" file))))

;; `git show` output is a unified diff with the commit message in front, so
;; diff-show! renders it as the same cards with the message on top
(define (git--show buf commit)
  (let ((root (buffer-local buf 'diff-root))
        (out (string-append "*git show: " (caddr commit) "*")))
    (git-show root (cadr commit)
      (lambda (text)
        (diff-show! out text)
        (buffer-set-local! out 'diff-backend "git")
        (buffer-set-local! out 'diff-root root)))))

(define-diff-backend "git"
  (list 'read git--read
        'resolve git--resolve
        'show git--show))

;; legacy: buffers saved before the backend split carry 'git-* locals and
;; the mode names "git-diff" / "git-show" — upgrade and hand over
(define (git--upgrade-locals! buf)
  (unless (buffer-local buf 'diff-backend)
    (buffer-set-local! buf 'diff-backend "git")
    (when (buffer-local buf 'git-root)
      (buffer-set-local! buf 'diff-root (buffer-local buf 'git-root)))
    (buffer-set-local! buf 'diff-scope (or (buffer-local buf 'git-prefix) ""))
    (when (buffer-local buf 'git-watch)
      (buffer-set-local! buf 'diff-watch #t))))

(define-mode "git-diff"
  (lambda ()
    (git--upgrade-locals! (current-buffer))
    (set-mode! "diff-mode")))

(define-mode "git-show"
  (lambda ()
    (git--upgrade-locals! (current-buffer))
    (set-mode! "diff-show")))

(define-command "git-diff" "Show the diff for the directory you are in"
  (lambda ()
    (let* ((dir (default-directory))
           (root (git-root dir))
           (prefix (git-prefix dir)))
      (if (not (string? root))
          (message "not a git repository")
          ;; the buffer is named for the SCOPE, so a subdirectory diff and a
          ;; whole-repository diff are two buffers, not one fighting itself
          (let ((buf (git--buf-name (git--scope-label root prefix))))
            (buffer-create buf)
            (buffer-set-local! buf 'diff-backend "git")
            (buffer-set-local! buf 'diff-root root)
            (buffer-set-local! buf 'diff-scope (if (string? prefix) prefix ""))
            (switch-to-buffer! buf)
            (set-mode! "diff-mode"))))))

(define (git--scope-label root prefix)
  (if (or (not (string? prefix)) (equal? prefix ""))
      root
      (string-append root "/" (git--strip-slash prefix))))

(define (git--strip-slash p)
  (if (and (> (string-length p) 1) (string-suffix? "/" p))
      (substring p 0 (- (string-length p) 1))
      p))


(global-set-key "C-x g" "git-diff")
