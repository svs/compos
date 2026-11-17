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

(define package-default-org "compos-dev")

(define (package-recipe-url recipe)
  ;; :repo is user/repo on github; a bare name is a repo of package-default-org
  (or (plist-get recipe ':url)
      (let ((repo (plist-get recipe ':repo)))
        (and repo
             (string-append "https://github.com/"
                            (if (string-contains? repo "/") repo (string-append package-default-org "/" repo))
                            ".git")))))

(public! 'compos-api-version "The version of the public API this core keeps; a recipe's :api must not be newer")
(public! 'package-default-org "The GitHub org of the standard and community package repos; a bare :repo NAME means ORG/NAME")
(public! 'package-recipe-url "(package-recipe-url RECIPE) - the git url of a recipe plist: :url, or :repo user/repo (or a bare repo of package-default-org) on github")

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
       (let ((forms (scheme-read (read-file path))))
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
                             (map (lambda (f) (if (string-suffix? "/" f)
                                                  (substring f 0 (- (string-length f) 1))
                                                  f))
                                  (list-dir d)))
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
(public! 'package-dir "(package-dir) - <compos-home>/packages, the user's own packages: the personal tier")

;;; --- the personal tier ------------------------------------------------------
;; The user's own packages, as ~/.emacs.d/lisp is in Emacs: single files in
;; (package-dir) and in each folder init.scm puts on load-path. They stay on
;; this machine; nothing pushes them. A package keeps its data out of these
;; folders, in (package-data-dir NAME), so the code folder holds only code.

(define (package--under? path dir)
  (and (string? dir) (or (equal? path dir) (string-prefix? (string-append dir "/") path))))

(define (personal-package-dirs)
  (let* ((home (compos-home))
         (not-personal (list (compos-project-dir) (compos-priv-dir) (package-repos-dir)))
         (dirs (cons (package-dir)
                     (filter (lambda (d)
                               (and (not (equal? d home))
                                    (null? (filter (lambda (o) (package--under? d o)) not-personal))))
                             load-path))))
    (let loop ((ds dirs) (acc '()))
      (cond ((null? ds) (reverse acc))
            ((or (member (car ds) acc) (not (file-directory? (car ds)))) (loop (cdr ds) acc))
            (else (loop (cdr ds) (cons (car ds) acc)))))))

(define (personal-file rel)
  (let loop ((ds (personal-package-dirs)))
    (cond ((null? ds) #f)
          ((file-exists? (string-append (car ds) "/" rel)) (string-append (car ds) "/" rel))
          (else (loop (cdr ds))))))

(public! 'personal-package-dirs "(personal-package-dirs) - the user's own package folders: (package-dir), then each load-path folder outside compos and the clones")
(public! 'personal-file "(personal-file REL) - the path of REL in the first personal package folder that has it, or #f")

(effects! '(write))

(define *personal-packages* '())

(define (package-data-dir name)
  (let ((dir (string-append (compos-home) "/" (if (symbol? name) (symbol->string name) name))))
    (unless (file-directory? dir) (make-directory! dir))
    dir))

(define (personal-packages! . names)
  (for-each
    (lambda (name)
      (let* ((n (if (symbol? name) (symbol->string name) name))
             (path (personal-file (string-append n ".scm"))))
        (if (not path)
            (message (string-append "personal package not found: " n))
            (report-errors (string-append "personal package " n)
              (lambda ()
                (package! (string->symbol n))
                (origin! 'user)
                (load path)
                (unless (member n *personal-packages*)
                  (set! *personal-packages* (append *personal-packages* (list n)))))))))
    names)
  *personal-packages*)

(public! 'package-data-dir "(package-data-dir NAME) - <compos-home>/NAME, where package NAME keeps the user's data; made on first ask")
(public! 'personal-packages! "(personal-packages! NAME ...) - load each personal package NAME.scm in order, stamped as the user's; answers the names loaded")

(effects! '(write))

(define (package--key k)
  ;; init.scm spells a key 'repo, the compos plist way; recipe.scm and
  ;; the code read :repo. Both name one key.
  (if (and (symbol? k) (not (string-prefix? ":" (symbol->string k))))
      (string->symbol (string-append ":" (symbol->string k)))
      k))

(define (package-recipe-add! recipe)
  (let ((n (package--name (car recipe))))
    (set! package--recipes
          (cons (cons n (let loop ((ps (cdr recipe)))
                          (if (and (pair? ps) (pair? (cdr ps)))
                              (cons (package--key (car ps)) (cons (cadr ps) (loop (cddr ps))))
                              ps)))
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
    ;; content-cache is a stdlib package; a package activated before it
    ;; loads goes unrecorded
    (when (boundp 'cache-put!)
      (cache-put! 'package-source n (or (package-recipe-url recipe) dir)))
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
(public! 'package-seed! "(package-seed! 'NAME) - make NAME's clone from the bundled copy (priv/repos) or the core pin (priv/standard.lock), at once; #t when it is there")
(public! 'package-core-pins "(package-core-pins) - the pins core ships for the standard packages, ((NAME URL COMMIT) ...)")

(effects! '(write external execute))

(define (package--clone-command url dir branch commit)
  (string-append "mkdir -p " (sh-quote (package-repos-dir))
                 " && git clone --quiet"
                 (if branch (string-append " --branch " (sh-quote branch)) "")
                 " " (sh-quote url) " " (sh-quote dir)
                 (if commit (string-append " && git -C " (sh-quote dir) " checkout --quiet " (sh-quote commit)) "")))

(define package--cloning '())

(define (package--ensure! n k)
  ;; K gets #t once the checkout is there; a missing clone runs in a task.
  ;; A second call while the clone runs (init.scm reloads on save, a
  ;; require of a require) waits for that clone instead of starting one
  ;; into the same directory, which fails.
  (let ((dir (package-directory n))
        (busy (assoc n package--cloning)))
    (cond
      (busy (set! package--cloning
              (map (lambda (x) (if (equal? (car x) n) (append x (list k)) x)) package--cloning)))
      ((file-exists? dir) (k #t))
      (else
        (let* ((recipe (package-recipe n))
               (pin (assoc n (package-lock)))
               (url (or (package-recipe-url recipe) (and pin (cadr pin)))))
          (if (not url)
              (begin (message (string-append "use-package: no recipe for " n)) (k #f))
              (let ((done (lambda (ok)
                            (let ((e (assoc n package--cloning)))
                              (set! package--cloning
                                    (filter (lambda (x) (not (equal? (car x) n))) package--cloning))
                              (for-each (lambda (w) (w ok)) (if e (cdr e) (list k)))))))
                (set! package--cloning (cons (list n k) package--cloning))
                (message (string-append "cloning " n " from " url))
                (shell-command->string
                  (string-append (package--clone-command url dir (plist-get recipe ':branch)
                                                         (and pin (caddr pin)))
                                 " && echo CLONE-OK")
                  (compos-home)
                  (lambda (out)
                    (if (string-contains? out "CLONE-OK")
                        (done #t)
                        (begin
                          (message (string-append "use-package: clone of " n " failed: " (string-trim out)))
                          (done #f))))))))))))

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

;; A package can ride with core: priv/standard.lock pins the commit this
;; core works with; a release bundles that clone in priv/repos, and the first
;; boot copies it, so it never waits on the network. A checkout without the
;; clone clones it at the pin, at once. The standard library is not one: it
;; lives in scheme/stdlib.
(define (package-core-pins)
  (or (package--read-first (string-append (compos-priv-dir) "/standard.lock")) '()))

(define (package--sh s) (string-append "'" (string-replace s "'" "'\\''") "'"))

(define (package-seed! name)
  (let* ((n (package--name name))
         (dir (package-directory n)))
    (or (file-exists? dir)
        (let* ((bundle (string-append (compos-priv-dir) "/repos/" n))
               (pin (assoc n (package-core-pins)))
               (cmd (cond ((file-exists? bundle)
                           (string-append "mkdir -p " (package--sh (package-repos-dir))
                                          " && cp -R " (package--sh bundle) " " (package--sh dir)))
                          (pin
                           (string-append "git clone --quiet " (package--sh (cadr pin)) " " (package--sh dir)
                                          " && git -C " (package--sh dir) " checkout --quiet " (package--sh (caddr pin))))
                          (else #f))))
          (when cmd (shell-command->string cmd (compos-home)))
          (file-exists? dir)))))

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

(public! 'use-package "(use-package 'NAME ['repo USER/REPO | 'url URL] ['branch B] ['defer #t]) - keys are quoted symbols, :repo spelled 'repo; - clone NAME if missing (in a task), check out its pin, put it on load-path and load it; publishes packages loaded or failed")
(public! 'package-thaw! "(package-thaw!) - in a task, check every package out at its packages.lock pin, cloning what is missing; publishes packages thawed")

;; ---- git state and pull requests: an agent and the user send a change upstream

(effects! '(pure))

(define (package-github-repo url)
  ;; OWNER/REPO of a github url, else #f
  (let* ((u (string-trim (or url "")))
         (rest (cond ((string-prefix? "https://github.com/" u) (substring u 19 (string-length u)))
                     ((string-prefix? "git@github.com:" u) (substring u 15 (string-length u)))
                     ((string-prefix? "ssh://git@github.com/" u) (substring u 21 (string-length u)))
                     (else #f)))
         (rest (and rest (if (string-suffix? ".git" rest) (substring rest 0 (- (string-length rest) 4)) rest))))
    (and rest (= (length (string-split rest "/")) 2) rest)))

(define (package--slug text)
  ;; a branch name piece: lower case letters, digits and dashes, at most 40
  (let* ((cs (map (lambda (c) (if (or (char-alphabetic? c) (char-numeric? c)) (char-downcase c) #\-))
                  (string->list (string-trim text))))
         (s (let loop ((cs cs) (acc '()))
              (cond ((null? cs) (list->string (reverse acc)))
                    ((and (char=? (car cs) #\-) (or (null? acc) (char=? (car acc) #\-))) (loop (cdr cs) acc))
                    (else (loop (cdr cs) (cons (car cs) acc))))))
         (s (if (> (string-length s) 40) (substring s 0 40) s))
         (s (if (string-suffix? "-" s) (substring s 0 (- (string-length s) 1)) s)))
    (if (equal? s "") "change" s)))

(public! 'package-github-repo "(package-github-repo URL) - OWNER/REPO of a github git url, else #f")

(effects! '(read execute))

(define package--prs '())

(define (package--git-status-of dir)
  ;; git only: the shell gate refuses other readers
  (let* ((g (lambda (args) (string-append "git -C " (sh-quote dir) " " args)))
         (head (map string-trim
                    (string-split (string-trim
                                    (shell-command->string
                                      (string-append (g "rev-parse --abbrev-ref HEAD 2>/dev/null || echo -") "; "
                                                     (g "rev-parse --abbrev-ref '@{u}' 2>/dev/null || ")
                                                     (g "rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo -") "; "
                                                     (g "config --get remote.origin.url || echo -"))
                                      dir))
                                  "\n")))
         (dash (lambda (s) (if (equal? s "-") #f s))))
    (if (< (length head) 3)
        (list 'branch #f 'upstream #f 'behind 0 'ahead 0 'dirty 0 'url #f)
        (let* ((up (dash (cadr head)))
               (out (shell-command->string
                      (string-append (if up (g (string-append "rev-list --left-right --count " (sh-quote (string-append up "...HEAD")) " 2>/dev/null; ")) "")
                                     "echo @@; " (g "status --porcelain 2>/dev/null"))
                      dir))
               (parts (string-split out "@@"))
               (ab (string-split (string-trim (car parts)) "\t"))
               (dirty (if (pair? (cdr parts))
                          (length (filter (lambda (l) (not (equal? (string-trim l) "")))
                                          (string-split (cadr parts) "\n")))
                          0)))
          (list 'branch (dash (car head)) 'upstream up
                'behind (or (string->number (car ab)) 0)
                'ahead (or (and (pair? (cdr ab)) (string->number (cadr ab))) 0)
                'dirty dirty
                'url (dash (caddr head)))))))

(define (package-git-status name)
  (let ((dir (package-directory name)))
    (if (file-exists? (string-append dir "/.git"))
        (package--git-status-of dir)
        (list 'branch #f 'upstream #f 'behind 0 'ahead 0 'dirty 0 'url #f))))

(define (package-prs name)
  (let ((e (assoc (package--name name) package--prs))) (if e (cdr e) '())))

(public! 'package-git-status "(package-git-status NAME) - the checkout of NAME as a plist: branch upstream ahead behind dirty url; behind counts what the last package-fetch! saw")
(public! 'package-prs "(package-prs NAME) - the open pull requests of NAME's github repo as ((NUMBER TITLE URL BRANCH) ...), as the last package-fetch! saw them")

(effects! '(write external execute))

(define (package-fetch! . k)
  ;; in a task: git fetch every clone and read its open PRs with gh
  (let* ((names (filter (lambda (n) (file-exists? (string-append (package-directory n) "/.git")))
                        (package-installed)))
         (step (lambda (n)
                 (let* ((dir (package-directory n))
                        (repo (package-github-repo (package--git dir "config --get remote.origin.url"))))
                   (string-append
                     "echo " (sh-quote (string-append "@@ " n)) "; "
                     "git -C " (sh-quote dir) " fetch --quiet origin 2>/dev/null; "
                     (if repo
                         (string-append "gh pr list -R " (sh-quote repo)
                                        " --state open --json number,title,url,headRefName"
                                        " --jq '.[] | \"\\(.number)\\t\\(.url)\\t\\(.headRefName)\\t\\(.title)\"' 2>/dev/null; ")
                         ""))))))
    (if (null? names)
        (begin (set! package--prs '()) (when (pair? k) ((car k) '())) '())
        (begin
          (shell-command->string
            (string-join (map step names) "")
            (compos-home)
            (lambda (out)
              (let loop ((ls (string-split out "\n")) (cur #f) (acc '()))
                (cond ((null? ls)
                       (set! package--prs (map (lambda (e) (cons (car e) (reverse (cdr e)))) acc))
                       (event-publish! "packages" 'fetched (map car package--prs))
                       (when (pair? k) ((car k) package--prs)))
                      ((string-prefix? "@@ " (car ls))
                       (let ((n (substring (car ls) 3 (string-length (car ls)))))
                         (loop (cdr ls) n (cons (list n) acc))))
                      (else
                       (let ((f (string-split (car ls) "\t")))
                         (if (and cur (>= (length f) 4) (string->number (car f)))
                             (loop (cdr ls) cur
                                   (cons (append (car acc)
                                                 (list (list (string->number (car f)) (string-join (cdddr f) "\t")
                                                             (cadr f) (caddr f))))
                                         (cdr acc)))
                             (loop (cdr ls) cur acc))))))))
          names))))

(define (package--pr-script repo branch fresh? message title body)
  ;; on BRANCH (new when FRESH?): commit all, fork, push, open or find the PR; the last line says
  (let ((q sh-quote))
    (string-append
      "set -e; "
      (if fresh? (string-append "git checkout --quiet -b " (q branch) "; ") "")
      "git add -A; "
      "if ! git diff --cached --quiet; then git commit --quiet -m " (q message) "; fi; "
      "if [ -z \"$(git rev-list '@{u}..HEAD' 2>/dev/null || git rev-list origin/HEAD..HEAD)\" ]; then echo 'PR-FAIL nothing to send'; exit 0; fi; "
      "user=$(gh api user --jq .login); owner=" (q (car (string-split repo "/"))) "; "
      "name=" (q (cadr (string-split repo "/"))) "; "
      "if [ \"$user\" = \"$owner\" ]; then remote=origin; else "
      "remote=fork; "
      "gh repo fork " (q repo) " --clone=false >/dev/null 2>&1 || true; "
      "if ! git remote get-url fork >/dev/null 2>&1; then "
      "case \"$(git remote get-url origin)\" in git@*|ssh:*) git remote add fork \"git@github.com:$user/$name.git\";; "
      "*) git remote add fork \"https://github.com/$user/$name.git\";; esac; fi; fi; "
      "git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push --quiet -u \"$remote\" " (q branch) " 2>&1; "
      "url=$(gh pr list -R " (q repo) " --head " (q branch) " --state open --json url --jq '.[0].url'); "
      "if [ -z \"$url\" ]; then "
      "head=" (q branch) "; [ \"$remote\" = fork ] && head=\"$user:" branch "\"; "
      "url=$(gh pr create -R " (q repo) " --head \"$head\" --title " (q title) " --body " (q body) " | tail -1); fi; "
      "echo \"PR-URL $url\"")))

(define (package-pr name description . k)
  ;; commit NAME's changes to a branch, push it to the user's fork, open the PR; K and the event get the url
  (let* ((n (package--name name))
         (dir (package-directory n))
         (desc (string-trim description))
         (lines (string-split desc "\n"))
         (title (string-trim (car lines)))
         (body (string-append (string-trim (string-join (cdr lines) "\n"))
                              (if (null? (cdr lines)) "" "\n\n")
                              "Sent from compos with package-pr."))
         (done (lambda (url err)
                 (if url
                     (event-publish! "packages" 'pr-opened (list n url))
                     (begin (message (string-append "package-pr " n ": " err))
                            (event-publish! "packages" 'pr-failed (list n err))))
                 (when (pair? k) ((car k) url)))))
    (cond ((equal? title "") (error "package-pr: the description is empty"))
          ((not (file-exists? (string-append dir "/.git")))
           (error (string-append "package-pr: " n " has no git checkout at " dir)))
          (else
           (let* ((st (package--git-status-of dir))
                  (repo (package-github-repo (plist-get st 'url)))
                  (cur (plist-get st 'branch))
                  ;; a compos/ branch is a PR in progress: commit to it again
                  (fresh? (not (and cur (string-prefix? "compos/" cur))))
                  (branch (if fresh? (string-append "compos/" (package--slug title)) cur)))
             (if (not repo)
                 (error (string-append "package-pr: " n "'s origin is not on github"))
                 (begin
                   (shell-command->string
                     (package--pr-script repo branch fresh? desc title body)
                     dir
                     (lambda (out)
                       (let* ((ls (reverse (string-split (string-trim out) "\n")))
                              (last (if (null? ls) "" (car ls))))
                         (cond ((string-prefix? "PR-URL https://" last) (done (substring last 7 (string-length last)) #f))
                               ((string-prefix? "PR-FAIL " last) (done #f (substring last 8 (string-length last))))
                               (else (done #f (string-trim out)))))))
                   branch)))))))

(public! 'package-fetch! "(package-fetch! [K]) - in a task, git fetch every clone and read its open PRs with gh; K gets ((NAME PR ...) ...); publishes packages fetched")
(public! 'package-pr "(package-pr NAME DESCRIPTION [K]) - commit NAME's changes to a compos/ branch (or the compos/ branch it is on), push it to your fork of its github repo, open the PR; answers the branch, K gets the PR url or #f; publishes packages pr-opened (NAME URL) or pr-failed. In an agent: (app-await (lambda (k) (package-pr NAME DESC k))) inside a task")

(define-command "package-pr" "Send a package's changes upstream as a pull request"
  (interactive
    (lambda (k)
      (minibuffer-read "Package: " (package-installed)
        (lambda (name)
          (minibuffer-read (string-append "Describe the change to " name ": ") '()
            (lambda (d) (k (list (string-trim name) d))))))))
  (lambda (name d)
    (package-pr name d (lambda (url) (when url (message (string-append "opened " url)))))
    (message (string-append "sending " name " upstream"))))


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
           (bare (if (string-suffix? ".git" base) (substring base 0 (- (string-length base) 4)) base))
           ;; a community repo is compos-NAME; the package in it is NAME
           (name (if (string-prefix? "compos-" bare) (substring bare 7 (string-length bare)) bare))
           (key (if url? 'url 'repo)))
      (use-package name key s)
      (message (format "installing ~a; add (use-package '~a '~a ~s) to init.scm" name name key s)))))

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
