;;; git.scm --- git as a diff-mode backend.
;;;
;;; diff-mode.scm draws sections, cards and hunks and knows no source
;;; control. This file supplies the git data: what is unstaged, what is
;;; staged, what git does not track yet, and the recent history. Another
;;; backend — a patch file, two directories, an agent's proposed edits —
;;; registers the same three functions and gets the same buffer.
;;;
;;; M-x git-diff opens the diff for the directory you are in. In a
;;; subdirectory the diff covers only that subtree, and the buffer is named
;;; for the scope. C-x g belongs to group navigation.

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

;; A merge conflict, by the same XY codes dired reads: both sides touched
;; the path (AA/DD) or git left a "U" on either side.
(define (git--conflict? entry)
  (let ((index (diff--get entry 'index))
        (worktree (diff--get entry 'worktree)))
    (or (equal? index "U") (equal? worktree "U")
        (and (equal? index "A") (equal? worktree "A"))
        (and (equal? index "D") (equal? worktree "D")))))

(define (git--conflict-paths status)
  (if (diff--error? status)
      '()
      (map (lambda (e) (diff--get e 'path)) (filter git--conflict? status))))

;; The diff itself only ever computes "added/deleted/renamed/modified" from
;; a/b; "conflict" is a git word, so git says it here, the way git--untracked
;; already says "untracked" — an override diff-mode's card status reads back.
(define (git--mark-conflicts files paths)
  (map (lambda (f)
         (if (member (diff--name f) paths) (cons 'status (cons "conflict" f)) f))
       files))

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
                      (let* ((un (git--mark-conflicts (git--ok unstaged)
                                                       (git--conflict-paths status)))
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

(mode-icon! "git-diff" "")

(define-mode "git-diff"
  (lambda ()
    (git--upgrade-locals! (current-buffer))
    (set-mode! "diff-mode")))

(mode-icon! "git-show" "")

(define-mode "git-show"
  (lambda ()
    (git--upgrade-locals! (current-buffer))
    (set-mode! "diff-show")))

;; Both are compatibility shims, not modes you use. A desktop file written
;; before the diff-backend split names them and carries the old `git-*`
;; locals. The shim rewrites those locals and hands the buffer over. The
;; `git-diff` COMMAND goes straight to diff-mode and never comes here.
(mode-doc! "git-diff"
  "An old name for `diff-mode`. The mode rewrites the locals of a buffer saved before the diff backends, then changes to `diff-mode`.")
(mode-doc! "git-show"
  "An old name for `diff-show`. The mode rewrites the locals of a buffer saved before the diff backends, then changes to `diff-show`.")

;; The directory the diff is about. The current buffer's directory when it
;; sits in a repository; otherwise the most recent buffer that does — M-x
;; git-diff from a chat or *scratch* means "the project I am working in", not the
;; home directory. Standing in a subdirectory scopes the diff to it; the
;; fallback takes the found buffer's ROOT, because a chat has no place in
;; the tree. The scan is capped: MRU means a hit comes early.
(define (git--context-dir)
  (let ((here (default-directory)))
    (if (string? (git-root here))
        here
        (let loop ((bs (buffer-list-mru)) (left 10))
          (cond ((or (null? bs) (= left 0)) here)
                ((let ((r (git-root (buffer-directory (car bs)))))
                   (and (string? r) r)))
                (else (loop (cdr bs) (- left 1))))))))

(domain! 'git)
(effects! '(read))

;; the buffer is named for the SCOPE, so a subdirectory diff and a
;; whole-repository diff are two buffers, not one fighting itself
(define (git--open! root prefix)
  (let ((buf (git--buf-name (git--scope-label root prefix))))
    (buffer-create buf)
    (buffer-set-local! buf 'diff-backend "git")
    (buffer-set-local! buf 'diff-root root)
    (buffer-set-local! buf 'diff-scope (if (string? prefix) prefix ""))
    (switch-to-buffer! buf)
    (set-mode! "diff-mode")))

(define-command "git-diff" "Show the diff for the directory you are in"
  (lambda ()
    (let* ((dir (git--context-dir))
           (root (git-root dir)))
      (if (not (string? root))
          (message "not a git repository")
          (git--open! root (git-prefix dir))))))

;; `M-x diff-mode`, the file-precise entry. define-mode makes every mode an
;; M-x command; the generated diff-mode command set the mode on the current
;; buffer, found no 'diff-backend local, and did nothing. This override
;; supplies the policy: a diff buffer refreshes in place; a file buffer
;; opens the diff for that one file; every other buffer opens the diff for
;; its directory. `M-x git-diff` keeps the directory scope. The scope
;; comes from git-prefix, not string arithmetic on the root: git resolves
;; symlinks in the root, the buffer path keeps them.
(define (git--basename p)
  (let ((i (string-rindex p "/")))
    (if i (substring p (+ i 1) (string-length p)) p)))

(define-command "diff-mode" "Toggle the source-control diff for this file or directory"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (buffer-local buf 'diff-backend)
          ;; from inside a diff the same command toggles back
          (run-command "quit-window")
          (let* ((path (buffer-path buf))
                 (dir (buffer-directory buf))
                 (root (git-root dir)))
            (if (not (string? root))
                (message "not a git repository")
                (git--open! root
                  (if (string? path)
                      (string-append (git-prefix dir) (git--basename path))
                      (git-prefix dir)))))))))

(define (git--scope-label root prefix)
  (if (or (not (string? prefix)) (equal? prefix ""))
      root
      (string-append root "/" (git--strip-slash prefix))))

(define (git--strip-slash p)
  (if (and (> (string-length p) 1) (string-suffix? "/" p))
      (substring p 0 (- (string-length p) 1))
      p))
