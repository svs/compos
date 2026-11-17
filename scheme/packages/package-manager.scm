;;; package-manager.scm --- install and uninstall packages; M-x packages is the app
;;
;; package-manager-install! clones, loads and adds the use-package line to
;; init.scm. package-manager-uninstall! drops that line, the recipe and the
;; pin, and trashes the clone. Each publishes packages changed, which
;; M-x packages redraws on. package-manager-rows merges every source by name.

(domain! 'packages)
(effects! '(pure))

(define package-manager--log "*package-manager-log*")
(define (package-manager--nl) (list->string (list #\newline)))

(defcustom 'package-manager-org "compos-dev"
  "The GitHub org whose compos-NAME repos the package manager offers")

(define (package-manager--short repo)
  (if (string-prefix? "compos-" repo) (substring repo 7 (string-length repo)) repo))

(define (package-manager--installed? row)
  (not (equal? (plist-get row 'status) "available")))

(define (package-manager--sources-text row)
  (string-join (or (plist-get row 'sources) '()) " "))

(define (package-manager--parse-github json)
  (let ((xs (ignore-errors (lambda () (json-parse json)))))
    (filter (lambda (x) x)
      (map (lambda (r)
             (let ((repo (plist-get r 'name)))
               (and (string? repo) (string-prefix? "compos-" repo)
                    (list (if (assoc repo (package-core-pins)) repo (package-manager--short repo))
                          (list 'description (let ((d (plist-get r 'description))) (if (string? d) d ""))
                                'repo (string-append package-manager-org "/" repo)
                                'archived (eq? (plist-get r 'isArchived) #t)
                                'updated (let ((u (plist-get r 'updatedAt)))
                                           (if (string? u) (substring u 0 (min 10 (string-length u))) #f)))))))
           (if (list? xs) xs '())))))

(define (package-manager--merge entries)
  "ENTRIES are (NAME SOURCE PROPS); answers ((NAME . PROPS) ...), the first value of a key winning, with 'sources"
  (let loop ((es entries) (acc '()))
    (if (null? es)
        (reverse acc)
        (let* ((e (car es)) (n (car e)) (src (cadr e)) (props (caddr e))
               (old (assoc n acc))
               (base (if old (cdr old) '()))
               (merged (let fill ((ps props) (p base))
                         (if (or (null? ps) (null? (cdr ps))) p
                             (fill (cddr ps) (if (plist-get p (car ps)) p (plist-put p (car ps) (cadr ps)))))))
               (srcs (or (plist-get merged 'sources) '()))
               (merged (plist-put merged 'sources (if (member src srcs) srcs (append srcs (list src))))))
          (loop (cdr es)
                (cons (cons n merged) (filter (lambda (x) (not (equal? (car x) n))) acc)))))))

(effects! '(read))

(define package-manager--github #f)

(define (package-manager--github-rows)
  (unless package-manager--github
    (let ((c (and (boundp 'cache-get) (cache-get 'package-manager "github"))))
      (when (string? c) (set! package-manager--github (package-manager--parse-github c)))))
  (or package-manager--github '()))

(define (package-manager--repo-of url) (and (string? url) (package-github-repo url)))

(define (package-manager-rows)
  (let* ((entries
           (append
             (map (lambda (g) (list (car g) "github" (cadr g))) (package-manager--github-rows))
             (map (lambda (r) (let ((url (package-recipe-url (cdr r))))
                                (list (car r) "init" (list 'url url 'repo (package-manager--repo-of url)
                                                           'defer (plist-get (cdr r) ':defer)))))
                  package--recipes)
             (map (lambda (p) (list (car p) "lock" (list 'url (cadr p) 'repo (package-manager--repo-of (cadr p)) 'pin (caddr p))))
                  (package-lock))
             (map (lambda (p) (list (car p) "core" (list 'url (cadr p) 'repo (package-manager--repo-of (cadr p)) 'core #t)))
                  (package-core-pins))
             (map (lambda (d) (list (car d) "dev" (list 'dev (cadr d)))) package-develop-directories)))
         (installed (package-installed)))
    (map (lambda (e)
                 (let* ((n (car e)) (p (cdr e))
                        (status (cond ((plist-get p 'core) "core")
                                      ((plist-get p 'dev) "dev")
                                      ((and (member n installed) (assoc n package--recipes)) "installed")
                                      ((member n installed) "cloned")
                                      (else "available"))))
                   (append (list 'name n 'status status
                                 'loaded (and (featurep (string->symbol n)) #t)
                                 'dir (and (not (equal? status "available")) (package-directory n)))
                           p)))
               (let ((merged (package-manager--merge entries)))
                 (map (lambda (n) (assoc n merged)) (sort (map car merged)))))))

(define (package-manager-row name)
  (let loop ((rs (package-manager-rows)))
    (cond ((null? rs) #f) ((equal? (plist-get (car rs) 'name) name) (car rs)) (else (loop (cdr rs))))))

(define (package-manager--init-path) (string-append (compos-home) "/init.scm"))

(define (package-manager--init-line name text)
  (let ((head (string-append "(use-package '" name " ")))
    (let loop ((ls (string-split text (package-manager--nl))))
      (cond ((null? ls) #f)
            ((string-prefix? head (string-trim (car ls))) (car ls))
            (else (loop (cdr ls)))))))

(public! 'package-manager-rows "(package-manager-rows) -- every package from every source (the GitHub org, the init.scm recipes, packages.lock, the core pins, develop checkouts) as a plist: name status loaded sources description repo url defer pin dir")
(public! 'package-manager-row "(package-manager-row NAME) -- NAME's row of package-manager-rows, or #f")

(effects! '(write external execute))

(define (package-manager--log! text)
  (unless (buffer-known? package-manager--log) (buffer-create package-manager--log))
  (buffer-append! package-manager--log (string-append text (package-manager--nl))))

(define (package-manager-fetch! . k)
  (shell-command->string
    (string-append "gh repo list " package-manager-org
                   " --limit 500 --json name,description,isArchived,updatedAt 2>&1")
    (compos-home)
    (lambda (out)
      (if (string-prefix? "[" (string-trim out))
          (begin
            (when (boundp 'cache-put!) (cache-put! 'package-manager "github" out))
            (set! package-manager--github (package-manager--parse-github out)))
          (begin (package-manager--log! (string-append "gh repo list failed: " out))
                 (message "package-manager: could not read the GitHub org; see *package-manager-log*")))
      (package-manager--redraw!)
      (when (pair? k) ((car k) (package-manager-rows))))))

(define (package-manager--with-init f)
  "run F on the init.scm buffer and save it, unless it held unsaved work; answers #t when saved"
  (let* ((path (package-manager--init-path))
         (known (buffer-known? path))
         (buf (find-file path))
         (dirty (buffer-modified? buf)))
    (f buf)
    (unless dirty (with-current-buffer buf (lambda () (buffer-save!))))
    (unless (or known dirty) (buffer-kill! buf))
    (not dirty)))

(define (package-manager--redraw!)
  "tell M-x packages that the installed packages changed"
  (event-publish! "packages" 'changed #f))

(define (package-manager-install! name . from)
  (let* ((row (package-manager-row name))
         (repo (or (and (pair? from) (car from))
                   (and row (plist-get row 'repo))
                   (string-append package-manager-org "/compos-" name)))
         (line (string-append "(use-package '" name " 'repo " (string #\") repo (string #\") ")")))
    (message (string-append "installing " name " from " repo " …"))
    (use-package name 'repo repo)
    (let ((saved (package-manager--with-init
                   (lambda (buf)
                     (unless (package-manager--init-line name (buffer-text buf))
                       (buffer-append! buf (string-append (if (string-suffix? (package-manager--nl) (buffer-text buf)) "" (package-manager--nl))
                                                          line (package-manager--nl))))))))
      (unless saved (message (string-append "init.scm has unsaved changes: added " name " to it but did not save"))))
    (package-manager--redraw!)
    name))

(define (package-manager-uninstall! name)
  (let ((row (package-manager-row name)))
    (cond
      ((and row (plist-get row 'core)) (message (string-append name " is a core package; it cannot be uninstalled")) #f)
      ((and row (plist-get row 'dev)) (message (string-append name " is a develop checkout; M-x package-develop with an empty dir first")) #f)
      (else
        (let ((saved (package-manager--with-init
                       (lambda (buf)
                         (let ((l (package-manager--init-line name (buffer-text buf))))
                           (when l (buffer-delete-text! buf (string-append l (package-manager--nl)))))))))
          (set! package--recipes (filter (lambda (r) (not (equal? (car r) name))) package--recipes))
          (let ((lock (package-lock)))
            (when (assoc name lock)
              (write-file! (package-lock-path)
                           (string-append ";; packages.lock --- package-freeze! writes it, package-thaw! checks it out." (package-manager--nl)
                                          (pp-to-string (filter (lambda (p) (not (equal? (car p) name))) lock)) (package-manager--nl)))))
          (let ((dir (string-append (package-repos-dir) "/" name)))
            (when (file-directory? dir) (trash-file! dir)))
          (package-manager--redraw!)
          (message (string-append "uninstalled " name
                                  (if (featurep (string->symbol name)) "; its code stays loaded until restart" "")
                                  (if saved "" "; init.scm had unsaved changes, so it is not saved")))
          name)))))

(define (package-manager-open-repo! row)
  (if (and row (plist-get row 'repo))
      (let ((url (string-append "https://github.com/" (plist-get row 'repo))))
        (shell-command->string (string-append "open " url) (compos-home) (lambda (out) #t))
        url)
      (begin (message "no repo for this package") #f)))

(public! 'package-manager-fetch! "(package-manager-fetch! [K]) -- read the GitHub org's package repos with gh in a task, cache them and redraw the list; K gets the rows")
(public! 'package-manager-install! "(package-manager-install! NAME [REPO]) -- clone and load package NAME, from REPO (OWNER/REPO) when given, and add its use-package line to init.scm")
(public! 'package-manager-uninstall! "(package-manager-uninstall! NAME) -- drop NAME's use-package line from init.scm, its recipe and its lock pin, and move its clone to the trash")
(public! 'package-manager-open-repo! "(package-manager-open-repo! ROW) -- open ROW's GitHub repo in the system browser")

(provide 'package-manager)
