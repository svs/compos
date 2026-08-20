;;; package.scm --- fetch and load user packages.
;;;
;;; A package is a plain .scm file. Bundled ones ship in priv/packages;
;;; user ones live in <aimax-home>/packages and load at boot right after
;;; the bundled set (see Session.load_packages). This package only adds
;;; the fetch step:
;;;
;;;   (package-install! "https://example.com/foo.scm")   raw url
;;;   (package-install! "user/repo")                     github <repo>.scm on main
;;;   (package-install! "user/repo/lisp/foo.scm")        github, that file on main
;;;
;;; M-x package-install prompts for a spec. Delete the file to uninstall.

(define (package--quote s)
  (string-append "'" (string-join (string-split s "'") "'\\''") "'"))

(define (package--url spec)
  (if (or (string-prefix? "http://" spec) (string-prefix? "https://" spec))
      spec
      (let ((parts (string-split spec "/")))
        (if (> (length parts) 2)
            (string-append "https://raw.githubusercontent.com/"
                           (car parts) "/" (cadr parts) "/main/"
                           (string-join (cdr (cdr parts)) "/"))
            (string-append "https://raw.githubusercontent.com/" spec "/main/"
                           (cadr parts) ".scm")))))

(define (package-dir) (string-append (aimax-home) "/packages"))

(define (package-list)
  (map (lambda (f) (car (string-split f ".scm")))
       (filter (lambda (f) (string-suffix? ".scm" f))
               (if (file-exists? (package-dir)) (list-dir (package-dir)) '()))))

(define (package-install! spec)
  (let* ((url (package--url spec))
         (name (car (reverse (string-split url "/"))))
         (path (string-append (package-dir) "/" name)))
    (if (not (string-suffix? ".scm" name))
        (message "packages are .scm files — spec must point at one")
        (let ((out (shell-command->string
                     (string-append "mkdir -p " (package--quote (package-dir))
                                    " && curl -fsSL " (package--quote url)
                                    " -o " (package--quote path)
                                    " && echo FETCH-OK"))))
          (if (string-contains? out "FETCH-OK")
              (begin
                (load path)
                (message (string-append name " installed and loaded")))
              (message (string-append "fetch failed: " (string-trim out))))))))

(define-command "package-install" "Fetch a package (.scm) from github/url and load it"
  (lambda ()
    (minibuffer-read "Install package (user/repo, user/repo/file.scm, or url): " '()
      (lambda (spec)
        (unless (equal? (string-trim spec) "")
          (package-install! (string-trim spec)))))))

(define-command "package-list" "Echo the installed user packages"
  (lambda ()
    (let ((ps (package-list)))
      (message (if (null? ps)
                   "no user packages installed"
                   (string-join ps " · "))))))

(category! 'packages)
(public! 'package-install! "(package-install! SPEC) — fetch a .scm (github user/repo[/path] or url) into <aimax-home>/packages and load it")
(public! 'package-list "Names of installed user packages")

;;; --- reloading one file into the live session --------------------------------
;;; The dev loop for a Scheme change was a full daemon restart. (load PATH)
;;; already evaluates a file in the session; this adds the policy: save the
;;; buffer first, stamp the package context from the file name, and say what
;;; happened. Registrations replace by name, so a reload does not stack
;;; duplicates. An Elixir change still needs a daemon restart.

(domain! 'packages)
(effects! '(write execute))

(define (reload-file path)
  (let* ((file (car (reverse (string-split path "/"))))
         (name (car (string-split file ".scm"))))
    (package! (string->symbol name))
    (load path)
    (message (string-append "reloaded " file))
    path))

(public! 'reload-file
  "(reload-file PATH) — evaluate a Scheme file in the live session, stamping its package context from the file name")

;; every reloadable file as (NAME PATH): the stdlib, the bundled
;; packages, and the user packages — the completion the prompt offers
(define (reload--files)
  (let ((scm (lambda (dir)
               (map (lambda (f)
                      (list (car (string-split f ".scm"))
                            (string-append dir "/" f)))
                    (filter (lambda (f) (string-suffix? ".scm" f))
                            (if (file-exists? dir) (list-dir dir) '()))))))
    (append (scm (aimax-priv-dir))
            (scm (string-append (aimax-priv-dir) "/packages"))
            (scm (package-dir)))))

(define-command "reload-file" "Reload a Scheme package into the live session"
  (lambda ()
    (let* ((buf (current-buffer))
           (here (let ((p (buffer-path buf)))
                   (and p (string-suffix? ".scm" p) p)))
           (files (reload--files)))
      (minibuffer-read
        (if here "Reload package (RET = this file): " "Reload package: ")
        (map car files)
        (lambda (name)
          (let* ((n (string-trim name))
                 (e (assoc n files))
                 (path (cond ((and (equal? n "") here) here)
                             (e (cadr e))
                             ((and (string-suffix? ".scm" n) (file-exists? n)) n)
                             (else #f))))
            (if (not path)
                (message (string-append "no package " n))
                (begin
                  ;; reloading the file being edited saves it first
                  (when (and (equal? path here) (buffer-modified? buf))
                    (run-command "save-buffer"))
                  (reload-file path)))))))))
