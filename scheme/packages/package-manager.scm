;;; package-manager.scm --- every package from every source; install and uninstall
;;
;; M-x package-manager lists what the compos-dev GitHub org offers, the
;; use-package recipes of init.scm, the pins of packages.lock, the core pins
;; and the develop checkouts, merged by name.  Tabs: all and installed.
;; i installs: clones, loads, adds the use-package line to init.scm.
;; d uninstalls: drops that line, the recipe and the pin, trashes the clone.
;; Code already loaded stays until restart.

(require 'tabulated-list)

(domain! 'packages)
(effects! '(pure))

(define *package-manager-buffer* "*package-manager*")
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

(define (package-manager-on-event e)
  (when (equal? (plist-get e 'topic) "packages")
    (package-manager--redraw!)))

(define (package-manager-install! name)
  (let* ((row (package-manager-row name))
         (repo (or (and row (plist-get row 'repo))
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
(public! 'package-manager-install! "(package-manager-install! NAME) -- clone and load package NAME and add its use-package line to init.scm")
(public! 'package-manager-uninstall! "(package-manager-uninstall! NAME) -- drop NAME's use-package line from init.scm, its recipe and its lock pin, and move its clone to the trash")
(public! 'package-manager-open-repo! "(package-manager-open-repo! ROW) -- open ROW's GitHub repo in the system browser")

(event-subscribe! "package-manager" "packages" 'package-manager-on-event)

(effects! '(write display))

(define (package-manager--at)
  (or (buffer-local-value 'package-manager-row (current-buffer))
      (and (buffer-known? *package-manager-buffer*) (list-current *package-manager-buffer*))))

(define (package-manager--tone status)
  (cond ((equal? status "available") "dim")
        ((equal? status "cloned") "warn")
        (else "ok")))

(define (package-manager--cells buf row)
  (list (plist-get row 'name)
        (plist-get row 'status)
        (if (plist-get row 'loaded) "yes" "")
        (package-manager--sources-text row)
        (or (plist-get row 'description) "")))

(define (package-manager--narrow-cells buf row)
  (list (plist-get row 'name) (plist-get row 'status) (or (plist-get row 'description) "")))

(define (package-manager--actions row)
  (append (cond ((or (plist-get row 'core) (plist-get row 'dev)) '())
                ((package-manager--installed? row) (list (list "package-manager-uninstall" "Uninstall" "d" "bad")))
                (else (list (list "package-manager-install" "Install" "i" "good"))))
          (if (plist-get row 'repo) (list (list "package-manager-open-repo" "GitHub ↗" "o")) '())
          (list (list "package-manager-refresh" "Refresh" "g"))))

(define (package-manager--page row)
  (let* ((name (plist-get row 'name))
         (status (plist-get row 'status))
         (desc (plist-get row 'description))
         (kv (lambda (pairs) (component 'ui/kv (list 'pairs (filter (lambda (p) (cadr p)) pairs))))))
    (list
      (component 'ui/title (list 'text name 'badge status 'tone (package-manager--tone status)))
      (component 'ui/meta (list 'segs (list (list "" (if (and (string? desc) (not (equal? desc ""))) desc "no description")))))
      (component 'ui/actions (list 'actions (package-manager--actions row)))
      (component 'ui/group
        (list 'title "Package"
              'body (list (kv (list (list "Status" status)
                                    (list "Loaded" (if (plist-get row 'loaded) "yes" "no"))
                                    (list "Loads" (if (plist-get row 'defer) "on first use" "at startup"))
                                    (list "Sources" (package-manager--sources-text row)))))))
      (component 'ui/group
        (list 'title "Where"
              'body (list (kv (list (list "Repo" (plist-get row 'repo))
                                    (list "Url" (plist-get row 'url))
                                    (list "Checkout" (plist-get row 'dir))
                                    (list "Pinned at" (let ((p (plist-get row 'pin))) (and (string? p) (> (string-length p) 12) (substring p 0 12))))
                                    (list "Updated" (plist-get row 'updated)))))))
      (component 'ui/row (list 'segs '(("c-dim" "end")))))))

(define (package-manager-show-detail! row)
  (when row
    (let* ((list-buf *package-manager-buffer*)
           (buf (string-append "*package-manager:" (plist-get row 'name) "*")))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf))) (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "package-manager-detail-mode")))
        (app-claim! buf "package-manager" 'detail))
      (buffer-set-local! buf 'package-manager-row row)
      (buffer-set-read-only! buf #f)
      (anchor-page! buf (package-manager--page row))
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar (list 'main (map (lambda (a) (list (caddr a) (cadr a))) (package-manager--actions row))))))
      (buffer-set-read-only! buf #t)
      (display-buffer-detail! buf list-buf))))

(define (package-manager--redraw!)
  (when (buffer-known? *package-manager-buffer*)
    (list-refresh! *package-manager-buffer*)
    (let ((r (list-current *package-manager-buffer*)))
      (when (and r (buffer-known? (string-append "*package-manager:" (plist-get r 'name) "*")))
        (package-manager-show-detail! r)))))

(define-list-mode! "package-manager-mode"
  (list
    'doc (string-append
           "Every compos package from every source: the compos-dev GitHub org, the use-package recipes of init.scm, "
           "packages.lock, the core pins and develop checkouts. Status: installed (cloned and in init.scm), cloned "
           "(cloned, not in init.scm), core, dev, or available. Tabs: all and installed; left and right step them. "
           "Moving the point shows the package's page beside the list. i installs: clones, loads and adds the "
           "use-package line to init.scm. d uninstalls: removes that line and the lock pin and moves the clone to "
           "the trash; loaded code stays until restart. o opens the repo on GitHub, g reads every source again, "
           "/ narrows (status:available, source:github), q quits.")
    'buffer *package-manager-buffer*
    'transient #f
    'plain #t
    'local-filter #t
    'tabs (list (list "all" (lambda (buf r) #t))
                (list "installed" (lambda (buf r) (package-manager--installed? r))))
    'rows (lambda (buf) (package-manager-rows))
    'key (lambda (buf row) (plist-get row 'name))
    'markable? (lambda (buf row) #f)
    'filters (list (list "status:" (lambda (b e) (or (plist-get e 'status) "")) "the package's status")
                   (list "source:" (lambda (b e) (package-manager--sources-text e)) "a source that lists it"))
    'columns (lambda (buf) (list (list "package" 18) (list "status" 10) (list "loaded" 7) (list "sources" 22) (list "description" #f)))
    'cells package-manager--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 84)
                         'columns (lambda (buf) (list (list "package" 16) (list "status" 10) (list "description" #f)))
                         'cells package-manager--narrow-cells)
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (package-manager-show-detail! row))
    'title (lambda (buf)
             (let ((rows (package-manager-rows)))
               (string-append "Packages  ·  " (number->string (length (filter package-manager--installed? rows)))
                              " installed of " (number->string (length rows)))))
    'noun "package"
    'footer (lambda (buf) '(("i" "install") ("d" "uninstall") ("o" "github") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("i" "package-manager-install") ("d" "package-manager-uninstall") ("o" "package-manager-open-repo")
            ("g" "package-manager-refresh") ("q" "quit-window"))))

(define-mode "package-manager-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "package-manager-detail-mode"
  '(("i" "package-manager-install") ("d" "package-manager-uninstall") ("o" "package-manager-open-repo")
    ("g" "package-manager-refresh")))
(mode-doc! "package-manager-detail-mode"
  "One package's page. i installs it, d uninstalls it, o opens its repo on GitHub, g reads every source again; M-<down> and M-<up> walk the parts.")

(define-command "package-manager-install" "Install the package at point: clone, load, add to init.scm"
  (lambda ()
    (let ((r (package-manager--at)))
      (cond ((not r) (message "no package here"))
            ((package-manager--installed? r) (message (string-append (plist-get r 'name) " is already installed")))
            (else (package-manager-install! (plist-get r 'name))))))
  'modes '(package-manager-mode package-manager-detail-mode))

(define-command "package-manager-uninstall" "Uninstall the package at point: drop it from init.scm and trash its clone"
  (lambda ()
    (let ((r (package-manager--at)))
      (cond ((not r) (message "no package here"))
            ((not (package-manager--installed? r)) (message (string-append (plist-get r 'name) " is not installed")))
            (else (let ((n (plist-get r 'name)))
                    (y-or-n (string-append "Uninstall " n "?")
                            (lambda () (package-manager-uninstall! n))))))))
  'modes '(package-manager-mode package-manager-detail-mode))

(define-command "package-manager-open-repo" "Open the GitHub repo of the package at point"
  (lambda () (package-manager-open-repo! (package-manager--at)))
  'modes '(package-manager-mode package-manager-detail-mode))

(define-command "package-manager-refresh" "Read every package source again"
  (lambda () (package-manager--redraw!) (package-manager-fetch!) (message "reading the package sources …"))
  'modes '(package-manager-mode package-manager-detail-mode))

;;;###autoload
(define-command "package-manager" "List every package from every source; install and uninstall them"
  (lambda ()
    (let ((buf (list-mode-show! "package-manager-mode")))
      (app-claim! buf "package-manager" 'listing)
      (package-manager-show-detail! (list-current buf))
      (package-manager-fetch!)
      buf)))

(public! 'package-manager-show-detail! "(package-manager-show-detail! ROW) -- show package ROW's page beside the list")

(provide 'package-manager)
