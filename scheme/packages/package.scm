;;; package.scm --- the package manager: recipes, use-package, the lockfile.
;;;
;;; A package is a git repo of .scm files. Each one is a full clone in
;;; <compos-home>/repos/NAME, and that directory goes on load-path. The
;;; manager needs only git. A recipe says where the repo is:
;;;
;;;   (spotify :repo "user/compos-spotify")                 github
;;;   (spotify :url "https://host/x.git" :branch "main")    any git url
;;;
;;; init.scm declares the packages it uses. use-package clones what is
;;; missing (in a task; the package loads when the clone is done), checks
;;; out the commit packages.lock pins, harvests the autoload cookies and
;;; loads NAME.scm (not with :defer #t):
;;;
;;;   (use-package 'spotify :repo "user/compos-spotify")
;;;
;;; <compos-home>/packages.lock pins each clone to a commit. package-freeze!
;;; writes it from the clones, package-thaw! checks the clones out at it.
;;; package-develop! points a package at a checkout of your own. A clone
;;; is plain git: edit it, commit, push.
;;;
;;; A repo can carry recipe.scm at its root, (NAME :requires (A B) :api N).
;;; use-package installs each require that has a recipe first, and refuses
;;; a package whose :api is newer than compos-api-version.

(domain! 'packages)
(effects! '(pure))

;; the version of the public API (the catalog) this core keeps
(define compos-api-version 1)

(define (package--name x) (if (symbol? x) (symbol->string x) x))

(define (package-recipe-url recipe)
  (or (plist-get recipe ':url)
      (let ((repo (plist-get recipe ':repo)))
        (and repo (string-append "https://github.com/" repo ".git")))))

(public! 'compos-api-version "The version of the public API this core keeps; a recipe's :api must not be newer")
(public! 'package-recipe-url "(package-recipe-url RECIPE) - the git url of a recipe plist: :url, or :repo user/repo on github")

(effects! '(read))

(defcustom 'package-repos-directory #f
  "Where the package clones live; #f is <compos-home>/repos" 'group 'packages)
(defcustom 'package-lock-file #f
  "The package lockfile; #f is <compos-home>/packages.lock" 'group 'packages)
(defcustom 'package-develop-directories '()
  "Packages pointed at a checkout of your own, as ((NAME DIR) ...); package-develop! sets it" 'group 'packages)

(define package--recipes '())

(define (package-repos-dir)
  (or package-repos-directory (string-append (compos-home) "/repos")))

(define (package-lock-path)
  (or package-lock-file (string-append (compos-home) "/packages.lock")))

(define (package-directory name)
  (let* ((n (package--name name))
         (dev (assoc n package-develop-directories)))
    (if dev (expand-path (cadr dev)) (string-append (package-repos-dir) "/" n))))

(define (package--read-first path)
  (and (file-exists? path)
       (let ((forms (scheme-read (read-file path #f))))
         (and (pair? forms) (car forms)))))

(define (package-recipe name)
  ;; the registered recipe first, then the clone's recipe.scm: plist-get
  ;; finds the first key, so what init.scm says wins
  (let* ((n (package--name name))
         (own (let ((e (assoc n package--recipes))) (if e (cdr e) '())))
         (repo (package--read-first (string-append (package-directory n) "/recipe.scm"))))
    (append own (if (pair? repo) (cdr repo) '()))))

(define (package-lock)
  (or (package--read-first (package-lock-path)) '()))

(define (package-installed)
  (let* ((d (package-repos-dir))
         (clones (if (file-directory? d)
                     (filter (lambda (f) (file-exists? (string-append d "/" f "/.git")))
                             (list-dir d))
                     '())))
    (append clones
            (filter (lambda (n) (not (member n clones)))
                    (map car package-develop-directories)))))

(define (package-list) (package-installed))
(define (package-dir) (string-append (compos-home) "/packages"))

(public! 'package-repos-dir "(package-repos-dir) - the directory that holds the package clones")
(public! 'package-lock-path "(package-lock-path) - the path of packages.lock")
(public! 'package-directory "(package-directory NAME) - the checkout NAME loads from: its develop directory, else its clone")
(public! 'package-recipe "(package-recipe NAME) - NAME's recipe plist: the registered one, then the clone's recipe.scm")
(public! 'package-lock "(package-lock) - the pins of packages.lock as ((NAME URL COMMIT) ...)")
(public! 'package-installed "(package-installed) - names of the cloned and developed packages")
(public! 'package-list "(package-list) - names of the installed packages")
(public! 'package-dir "(package-dir) - <compos-home>/packages, the old home of single-file user packages")

(effects! '(write))

(define (package-recipe-add! recipe)
  (let ((n (package--name (car recipe))))
    (set! package--recipes
          (cons (cons n (cdr recipe))
                (filter (lambda (e) (not (equal? (car e) n))) package--recipes)))
    n))

(define (package--activate! n)
  ;; put the checkout on load-path, harvest its cookies, load NAME.scm
  (let* ((recipe (package-recipe n))
         (dir (package-directory n))
         (api (plist-get recipe ':api))
         (main (string-append dir "/" n ".scm")))
    (when (and (number? api) (> api compos-api-version))
      (error (string-append "package " n " needs compos-api-version "
                            (number->string api) "; this compos has "
                            (number->string compos-api-version))))
    (unless (member dir load-path)
      (set! load-path (append load-path (list dir))))
    ;; the app registry files a package with a source under package, not user
    (cache-put! 'package-source n (or (package-recipe-url recipe) dir))
    (autoload-harvest! (list dir))
    (when (and (not (plist-get recipe ':defer)) (file-exists? main))
      (require (string->symbol n) main))
    n))

(define (package-develop! name dir)
  ;; DIR #f goes back to the clone
  (let* ((n (package--name name))
         (old (package-directory n))
         (rest (filter (lambda (e) (not (equal? (car e) n))) package-develop-directories)))
    (customize-save! 'package-develop-directories
                     (if dir (cons (list n (expand-path dir)) rest) rest))
    (let ((new (package-directory n)))
      (when (member old load-path)
        (set! load-path (append (filter (lambda (d) (not (equal? d old))) load-path)
                                (list new)))
        (autoload-harvest! (list new))
        (let ((main (string-append new "/" n ".scm")))
          (when (and (featurep (string->symbol n)) (file-exists? main))
            (load main))))
      new)))

(public! 'package-recipe-add! "(package-recipe-add! '(NAME :repo USER/REPO ...)) - register a recipe; use-package finds it")
(public! 'package-develop! "(package-develop! NAME DIR) - load NAME from the checkout DIR from now on, reloading it when it is loaded; DIR #f goes back to the clone")

(effects! '(write execute))

(define (package--git dir args)
  (string-trim (shell-command->string (string-append "git -C " (sh-quote dir) " " args) dir)))

(define (package-freeze!)
  ;; pin every installed git checkout at its HEAD
  (let ((rows (filter (lambda (r) (= (string-length (caddr r)) 40))
                (map (lambda (n)
                       (let ((dir (package-directory n)))
                         (if (file-exists? (string-append dir "/.git"))
                             (list n (package--git dir "config --get remote.origin.url")
                                   (package--git dir "rev-parse HEAD"))
                             (list n "" ""))))
                     (package-installed)))))
    (write-file! (package-lock-path)
                 (string-append ";; packages.lock --- package-freeze! writes it, package-thaw! checks it out.\n"
                                (pp-to-string rows) "\n"))
    rows))

(public! 'package-freeze! "(package-freeze!) - write packages.lock: each installed package at the commit its checkout holds; answers the rows")

(effects! '(write external execute))

(define (package--clone-command url dir branch commit)
  (string-append "mkdir -p " (sh-quote (package-repos-dir))
                 " && git clone --quiet"
                 (if branch (string-append " --branch " (sh-quote branch)) "")
                 " " (sh-quote url) " " (sh-quote dir)
                 (if commit (string-append " && git -C " (sh-quote dir) " checkout --quiet " (sh-quote commit)) "")))

(define (package--ensure! n k)
  ;; K gets #t once the checkout is there; a missing clone runs in a task
  (let ((dir (package-directory n)))
    (if (file-exists? dir)
        (k #t)
        (let* ((recipe (package-recipe n))
               (pin (assoc n (package-lock)))
               (url (or (package-recipe-url recipe) (and pin (cadr pin)))))
          (if (not url)
              (begin (message (string-append "use-package: no recipe for " n)) (k #f))
              (begin
                (message (string-append "cloning " n " from " url))
                (shell-command->string
                  (string-append (package--clone-command url dir (plist-get recipe ':branch)
                                                         (and pin (caddr pin)))
                                 " && echo CLONE-OK")
                  (compos-home)
                  (lambda (out)
                    (if (string-contains? out "CLONE-OK")
                        (k #t)
                        (begin
                          (message (string-append "use-package: clone of " n " failed: " (string-trim out)))
                          (k #f)))))))))))

(define (package--use n k)
  ;; ensure, install the requires that have recipes, activate; K gets N or #f
  (package--ensure! n
    (lambda (ok)
      (if (not ok)
          (k #f)
          (let loop ((reqs (or (plist-get (package-recipe n) ':requires) '())))
            (if (null? reqs)
                (k (report-errors (string-append "use-package " n)
                                  (lambda () (package--activate! n))))
                (let ((r (package--name (car reqs))))
                  (if (or (featurep (string->symbol r))
                          (not (or (assoc r package--recipes)
                                   (file-exists? (package-directory r)))))
                      (loop (cdr reqs))
                      (package--use r (lambda (_) (loop (cdr reqs))))))))))))

(define (use-package name . props)
  (let ((n (package--name name)))
    (when (pair? props) (package-recipe-add! (cons n props)))
    (package--use n
      (lambda (done)
        (event-publish! "packages" (if done 'loaded 'failed) n)))
    n))

(define (package-thaw!)
  ;; check out every pin of packages.lock in a task; a develop checkout stays
  (let* ((rows (filter (lambda (r) (not (assoc (car r) package-develop-directories)))
                       (package-lock)))
         (step (lambda (r)
                 (let* ((n (car r)) (url (cadr r)) (c (caddr r))
                        (dir (package-directory n)) (q (sh-quote dir)))
                   (string-append
                     "( "
                     (if (file-exists? dir)
                         (string-append "{ git -C " q " cat-file -e " (sh-quote (string-append c "^{commit}"))
                                        " 2>/dev/null || git -C " q " fetch --quiet origin; }"
                                        " && git -C " q " checkout --quiet " (sh-quote c))
                         (package--clone-command url dir #f c))
                     " ) && echo " (sh-quote (string-append n " ok"))
                     " || echo " (sh-quote (string-append n " failed")))))))
    (if (null? rows)
        (message "packages.lock pins nothing")
        (shell-command->string
          (string-join (map step rows) " ; ")
          (compos-home)
          (lambda (out)
            (let ((bad (filter (lambda (l) (string-suffix? " failed" l))
                               (string-split (string-trim out) "\n"))))
              (message (if (null? bad)
                           (string-append "thawed " (number->string (length rows)) " packages")
                           (string-append "thaw: " (string-join bad ", "))))
              (event-publish! "packages" 'thawed out)))))
    (map car rows)))

(public! 'use-package "(use-package 'NAME [:repo USER/REPO | :url URL] [:branch B] [:defer #t]) - clone NAME if missing (in a task), check out its pin, put it on load-path and load it; publishes packages loaded or failed")
(public! 'package-thaw! "(package-thaw!) - in a task, check every package out at its packages.lock pin, cloning what is missing; publishes packages thawed")

(define-command "package-install" "Clone a package from GitHub (user/repo) or a git url and load it"
  (interactive
    (lambda (k)
      (minibuffer-read "Install package (user/repo or git url): " '()
        (lambda (spec)
          (let ((s (string-trim spec)))
            (unless (equal? s "") (k (list s))))))))
  (lambda (s)
    (let* ((url? (string-contains? s "://"))
           (base (car (reverse (string-split s "/"))))
           (name (if (string-suffix? ".git" base) (substring base 0 (- (string-length base) 4)) base))
           (key (if url? ':url ':repo)))
      (use-package name key s)
      (message (format "installing ~a; add (use-package '~a ~a ~s) to init.scm" name name key s)))))

(define-command "package-freeze" "Pin every installed package at its current commit in packages.lock"
  (lambda ()
    (let ((rows (package-freeze!)))
      (message (string-append "froze " (number->string (length rows)) " packages in " (package-lock-path))))))

(define-command "package-thaw" "Check every package out at its packages.lock pin" package-thaw!)

(define-command "package-develop" "Load a package from a checkout of your own (empty: back to the clone)"
  (interactive
    (lambda (k)
      (minibuffer-read "Develop package: " (package-installed)
        (lambda (name)
          (minibuffer-read (string-append "Checkout of " name " (empty: the clone): ") '()
            (lambda (dir)
              (let ((d (string-trim dir)))
                (k (list (string-trim name) (if (equal? d "") #f d))))))))))
  (lambda (name dir)
    (message (string-append name " loads from " (package-develop! name dir)))))

(define-command "package-list" "Echo the installed packages"
  package-list
  'show (lambda (ps)
          (message (if (null? ps)
                       "no packages installed"
                       (string-join ps " · ")))))

;;; --- reloading one file into the live session --------------------------------
;;; In development the daemon reloads a file by itself when it is saved
;;; (Compos.Core.Hotload): it evaluates only the top-level forms whose text
;;; changed, stamps the package context from the file name, and re-runs
;;; mode setup on the buffers wearing a mode the reload redefined. So
;;; editor.scm costs what its diff costs, and no file needs a restart.
;;;
;;; This command is the manual door, and it evaluates the WHOLE file: a
;;; name changed live with set!, or a definition gone stale, goes back to
;;; what the file says even when the file did not change.

(domain! 'packages)
(effects! '(write execute))

(define (reload-file path)
  ;; an agent's reload waits for the reload holds (holds.scm); the user's goes
  (let ((why (and (boundp 'holds-reload-refusal)
                  (let ((a (current-edit-author))) (and (string? a) (string-prefix? "agent:" a)))
                  (holds-reload-refusal))))
    (when why (error (string-append "reload-file: " why))))
  (let* ((file (car (reverse (string-split path "/"))))
         (result (reload-files! (list path) #t)))
    (message (string-append "reloaded " file " · "
                            (number->string (cadr result)) " forms"))
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
                    (filter (lambda (f) (and (string-suffix? ".scm" f)
                                             (not (string-suffix? "-test.scm" f))))
                            (if (file-exists? dir) (list-dir dir) '()))))))
    (apply append (map scm (append load-path (list (package-dir)))))))

;; The force-reload door. A primitive is an anonymous fun the session
;; captured from an Elixir module at boot. Recompiling that module purges
;; the fun, and the next Scheme call that reaches it raises "points to an
;; old version of the code". One dead command, or a dead editor. The dev
;; watcher rebinds after every recompile, so this is the manual door: for a
;; daemon that is already wedged, and for a recompile the watcher missed.
;;
;; This does NOT re-evaluate Scheme files. Use `reload-file` for that. A
;; blanket re-run of every top-level form re-runs boot side effects, and
;; `reload-files!` is not re-entrant.
(define-command "reload-scheme" "Rebind every Elixir primitive in the live session"
  (lambda ()
    (refresh-primitives!)
    (message "primitives rebound")))

(define-command "reload-file" "Reload a Scheme package into the live session"
  (interactive
    (lambda (k)
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
                    (k (list path))))))))))
  reload-file)
