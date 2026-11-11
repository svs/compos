;;; build-identity.scm --- which compos is running, in the echo area after *Messages*.
;;;
;;; A release shows its version and the commit it was built from:
;;;   rel 0.9.0 · 2fa2acc
;;; A dev checkout shows its open jj change and its git commit, read again
;;; while you work:
;;;   dev · jj vxxoqmox · git 2fa2acc
;;; The release step in mix.exs writes priv/build-info.scm; without it a
;;; release still names its version, from the compos_core directory.

(domain! 'system)
(effects! '(read))

(define (build-info)
  "the release's build plist from priv/build-info.scm: version, commit, built; #f in a checkout"
  (let ((p (string-append (compos-priv-dir) "/build-info.scm")))
    (and (file-exists? p)
         (let ((forms (scheme-read (read-file p))))
           (and (pair? forms) (car forms))))))

(define (build-release-version)
  "the version a release runs, from its build info or its compos_core directory"
  (let ((info (build-info)))
    (or (and info (plist-get info 'version))
        (let ((m (re-match "compos_core-([^/]+)/priv" (compos-priv-dir))))
          (and m (cadr m))))))

(define (build-dev-identity root)
  "the open jj change and the git commit of the checkout ROOT, as one line"
  (let* ((jj (let ((line (jj-log "@" root)))
               (and (string? line) (> (string-length line) 7) (substring line 0 8))))
         (git (string-trim (shell-command->string "git rev-parse --short HEAD 2>/dev/null" root))))
    (string-append "dev"
                   (if jj (string-append " · jj " jj) "")
                   (if (> (string-length git) 0) (string-append " · git " git) ""))))

(define *build-identity* #f)
(define *build-identity-at* 0)
(define *build-identity-pending* #f)
(define build-identity-dev-ttl-ms 30000)

(define (build-identity-text)
  "what the modeline shows for this compos; a checkout reads itself again in a task every 30 s"
  (let ((root (compos-project-dir)))
    (if (not root)
        (or *build-identity*
            (let* ((info (build-info))
                   (commit (and info (plist-get info 'commit)))
                   (text (string-append "rel " (or (build-release-version) "?")
                                        (if commit (string-append " · " commit) ""))))
              (set! *build-identity* text)
              text))
        (begin
          (when (and (not *build-identity-pending*)
                     (> (- (monotonic-ms) *build-identity-at*) build-identity-dev-ttl-ms))
            (set! *build-identity-pending* #t)
            (task-run! (lambda () (build-dev-identity root))
                       (lambda (ok? value)
                         (set! *build-identity-pending* #f)
                         (set! *build-identity-at* (monotonic-ms))
                         (when (and ok? (not (equal? value *build-identity*)))
                           (set! *build-identity* value)
                           (build-identity-publish!)))))
          (or *build-identity* "dev")))))

(define (build-identity-describe)
  "what build-info says: the build line, and where this compos runs from"
  (let ((info (build-info)))
    (string-append (build-identity-text)
                   (if (and info (plist-get info 'built)) (string-append " · built " (plist-get info 'built)) "")
                   " · " (or (compos-project-dir) (getenv "RELEASE_ROOT") "?"))))

(define-command "build-info" "Say which compos runs: version and commit, or the checkout's jj change and git commit"
  (lambda () (message (build-identity-describe))))

(define (build-identity-publish!)
  "show the build line in the echo area, after *Messages*; a click says more"
  (echo-extra-hint-set! 'build-identity (list (build-identity-text) "" "build-info")))

(global-mode-string-set! 'build-identity #f)
(build-identity-publish!)
