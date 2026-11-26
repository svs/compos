;;; packages.scm --- M-x packages: every package, where it lives, whether it is loaded, its tier and its tier breaks.
;;;
;;; The tabs split the packages by where they live: packages (scheme/packages,
;;; the clones and the user's own), stdlib (scheme/stdlib) and core (priv and
;;; scheme/core). l loads the package at point and k unloads it.
;;;
;;; v0 of the packages app in docs/FURTHER READING/internal/proposals/PACKAGES.md.
;;; The tier of a package comes from the assignment table in that document,
;;; so an edit of the table changes the app on the next g. A require from a
;;; package to a package of a lower tier is a tier break: core -> any other
;;; tier, standard -> community, dev or unassigned, community -> dev.
;;; init.scm is the boot manifest, not a package: its requires do not count.

(require 'tabulated-list)
(require 'package-manager)
(require 'package-update)

(domain! 'packages)
(effects! '(pure))

(define *packages-buffer* "*packages*")
(define *packages-tiers* '("installed" "core" "standard" "community" "personal" "dev" "unassigned"))
(define *packages-sections* '("packages" "stdlib" "core"))
;; feature -> the global names its load through this app made
(defcustom 'packages-sources '("compos-dev")
  "Where M-x packages finds packages to install, in order: a GitHub org or user, whose compos-NAME repos are the packages NAME, or OWNER/REPO for one repo. compos-dev is the default source; M-x packages-add-source adds your own.")
(define packages--source-cache #f)
(define packages--defs '())
;; core by rule: priv/editor.scm, priv/core.scm and the manifest
(define packages--kernel '("editor" "core" "init"))
(define packages--manifests '("init"))
(define packages--doc "docs/FURTHER READING/internal/proposals/PACKAGES.md")
(define packages--scan-cache #f)

(define (packages--dedup xs)
  (let loop ((xs xs) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((member (car xs) acc) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

(define (packages--strip-parens s)
  (let loop ((cs (string->list s)) (depth 0) (acc '()))
    (cond ((null? cs) (list->string (reverse acc)))
          ((char=? (car cs) #\() (loop (cdr cs) (+ depth 1) acc))
          ((char=? (car cs) #\)) (loop (cdr cs) (max 0 (- depth 1)) acc))
          ((> depth 0) (loop (cdr cs) depth acc))
          (else (loop (cdr cs) depth (cons (car cs) acc))))))

(define (packages--names-of text)
  "the package names of one table line: comma separated, parentheses dropped"
  (filter (lambda (n) (not (equal? n "")))
          (map (lambda (n)
                 (let ((n (string-trim n)))
                   (if (string-suffix? "." n) (substring n 0 (- (string-length n) 1)) n)))
               (string-split (packages--strip-parens text) ","))))

(define (packages-parse-tiers text)
  "(packages-parse-tiers TEXT) -- the assignment table of PACKAGES.md TEXT as ((NAME TIER) ...)"
  (let loop ((lines (string-split text "\n")) (tier #f) (acc '()))
    (if (null? lines) (reverse acc)
        (let* ((l (string-trim (car lines)))
               (add (lambda (names) (append (reverse (map (lambda (n) (list n tier)) names)) acc))))
          (cond ((string-prefix? "### 1. Core" l) (loop (cdr lines) "core" acc))
                ((string-prefix? "### 2. Standard" l) (loop (cdr lines) "standard" acc))
                ((string-prefix? "### 3. Community" l) (loop (cdr lines) "community" acc))
                ((string-prefix? "### Dev-only" l) (loop (cdr lines) "dev" acc))
                ((string-prefix? "#" l) (loop (cdr lines) #f acc))
                ((and tier (string-prefix? "- " l))
                 (let* ((body (substring l 2 (string-length l)))
                        (i (string-index body ":")))
                   (loop (cdr lines) tier
                         (add (packages--names-of (if i (substring body (+ i 1) (string-length body)) body))))))
                ;; the dev table is one plain line of names
                ((and (equal? tier "dev") (not (equal? l "")))
                 (loop (cdr lines) tier (add (packages--names-of l))))
                (else (loop (cdr lines) tier acc)))))))

(define (packages-break? from to)
  "(packages-break? FROM-TIER TO-TIER) -- #t when a require from FROM-TIER to TO-TIER breaks the tier rules"
  (cond ((equal? from "core") (not (equal? to "core")))
        ((equal? from "standard") (if (member to '("community" "dev" "unassigned")) #t #f))
        ((equal? from "community") (equal? to "dev"))
        (else #f)))

(define (packages--name rel)
  "the package name of a source path: its path under scheme/packages, scheme/apps or priv, without .scm"
  (let ((bare (substring rel 0 (- (string-length rel) 4))))
    (let loop ((roots '("scheme/packages/" "scheme/stdlib/" "scheme/apps/" "scheme/dev/" "scheme/core/" "apps/compos_core/priv/")))
      (cond ((null? roots) bare)
            ((string-prefix? (car roots) bare) (substring bare (string-length (car roots)) (string-length bare)))
            (else (loop (cdr roots)))))))

(define (packages--source? rel)
  (and (string-suffix? ".scm" rel)
       (not (string-suffix? "-test.scm" rel))
       (or (string-prefix? "scheme/" rel)
           (and (string-prefix? "apps/compos_core/priv/" rel)
                (not (string-prefix? "apps/compos_core/priv/tests/" rel))
                (not (string-prefix? "apps/compos_core/priv/grammars/" rel))
                (not (string-prefix? "apps/compos_core/priv/queries/" rel))))))

(define (packages--top name)
  (let ((i (string-index name "/"))) (if i (substring name 0 i) name)))

(define (packages--section row)
  "where ROW's package belongs: core (priv, scheme/core, or the core tier of PACKAGES.md), stdlib (scheme/stdlib, a release's priv/stdlib, or the standard tier) or packages"
  (let ((file (or (plist-get row 'file) "")) (name (plist-get row 'name)) (tier (plist-get row 'tier)))
    (cond ((or (member name packages--kernel) (equal? tier "core")) "core")
          ((or (equal? tier "standard") (string-contains? file "/scheme/stdlib/") (string-contains? file "/priv/stdlib/")) "stdlib")
          ((or (string-contains? file "/priv/") (string-contains? file "/scheme/core/")) "core")
          (else "packages"))))

(define (packages--feature row) (string->symbol (packages--base (plist-get row 'name))))

(define (packages--tier-of name table)
  (let ((e (or (assoc name table) (assoc (packages--top name) table))))
    (cond (e (cadr e))
          ((member name packages--kernel) "core")
          (else "unassigned"))))

(define (packages--requires text)
  "every (require 'F [FILE]) outside a comment or a string as (FEATURE FILE LINE)"
  (let ((nls (map car (re-find* "\\n" text))))
    (map (lambda (m)
           (let ((g (re-match "\\(require '([^\\s)\"]+)(?:\\s+\"([^\"]+)\")?" (substring-bytes text (car m) (cadr m)))))
             (list (cadr g) (and (> (length g) 2) (caddr g))
                   (+ 1 (length (filter (lambda (o) (< o (car m))) nls))))))
         (re-find* "(?m)^[^;\\n\"]*\\(require '[^\\n]*" text))))

(define (packages--provides text)
  (map (lambda (m) (cadr (re-match "\\(provide '([^\\s)]+)" (substring-bytes text (car m) (cadr m)))))
       (re-find* "(?m)^\\s*\\(provide '[^\\s)]+" text)))

(effects! '(read))

(define (packages--root) (compos-project-dir))

(define (packages--tier-table)
  (let ((root (packages--root)))
    (if (not root) '()
        (let ((path (string-append root "/" packages--doc)))
          (if (file-exists? path) (packages-parse-tiers (read-file path)) '())))))

(define (packages--base name)
  (let ((i (string-rindex name "/"))) (if i (substring name (+ i 1) (string-length name)) name)))

(define (packages--resolve raw features feature file)
  "the package a require names: its FILE when it gives one, else the file or provide of FEATURE"
  (or (and file
           (let ((n (substring file 0 (- (string-length file) 4))))
             (let loop ((ps raw))
               (cond ((null? ps) #f)
                     ((let ((x (plist-get (car ps) 'name))) (or (equal? x n) (string-suffix? (string-append "/" n) x))) (car ps))
                     (else (loop (cdr ps)))))))
      (let ((e (assoc feature features))) (and e (cadr e)))))

;; stdlib: DIR/DIR.scm is the package DIR, DIR/FILE.scm is DIR/FILE
(define (packages--standard-sources)
  (if (not (boundp 'stdlib-dirs))
      '()
      (apply append
        (map (lambda (dir)
               (let ((d (car (reverse (string-split dir "/")))))
                 (map (lambda (f) (let ((b (substring f 0 (- (string-length f) 4))))
                                    (list (string-append dir "/" f) (if (equal? b d) d (string-append d "/" b)))))
                      (filter (lambda (f) (and (string-suffix? ".scm" f) (not (string-suffix? "-test.scm" f))))
                              (map (lambda (e) (plist-get e 'name)) (ls dir))))))
             (stdlib-dirs)))))

;; a release has no checkout: its core is priv's own files and priv/packages,
;; one level of subdirectories each (priv/editor/blocks/block.scm is editor/blocks/block)
(define (packages--release-sources)
  (let* ((priv (compos-priv-dir))
         (scm? (lambda (f) (and (string-suffix? ".scm" f) (not (string-suffix? "-test.scm" f)) (not (equal? f "build-info.scm")))))
         (names (lambda (e) (plist-get e 'name)))
         (dir? (lambda (e) (equal? (plist-get e 'type) "directory")))
         (files (lambda (dir) (if (file-directory? dir) (filter scm? (map names (filter (lambda (e) (not (dir? e))) (ls dir)))) '())))
         (subdirs (lambda (dir) (if (file-directory? dir) (map (lambda (e) (let ((n (names e))) (substring n 0 (- (string-length n) 1)))) (filter dir? (ls dir))) '())))
         (walk (lambda (dir prefix)
                 (append (map (lambda (f) (list (string-append dir "/" f) (string-append prefix (substring f 0 (- (string-length f) 4))))) (files dir))
                         (apply append (map (lambda (s) (map (lambda (f) (list (string-append dir "/" s "/" f) (string-append prefix s "/" (substring f 0 (- (string-length f) 4)))))
                                                             (files (string-append dir "/" s))))
                                            (subdirs dir)))))))
    (if (not priv) '()
        (append (map (lambda (f) (list (string-append priv "/" f) (substring f 0 (- (string-length f) 4)))) (files priv))
                (walk (string-append priv "/editor") "editor/")
                (walk (string-append priv "/packages") "")))))

;; without PACKAGES.md, as in a release, the tier follows where the file is
(define (packages--tier-by-place file name)
  (cond ((member name packages--kernel) "core")
        ((string-contains? file "/stdlib/") "standard")
        ((string-contains? file "/priv/") "core")
        (else "unassigned")))

(define (packages-scan)
  "(packages-scan) -- every package of the checkout as a plist: name tier file requires required-by breaks"
  (let* ((root (packages--root))
         (table (packages--tier-table))
         (rels (if root (filter (lambda (rel) (and (packages--source? rel) (file-exists? (string-append root "/" rel))))
                                (project-files root))
                        '()))
         ;; (FILE NAME): the checkout's sources, then the standard packages' clone
         (std (packages--standard-sources))
         (sources (append (if root
                              (filter (lambda (src) (not (assoc (car src) std)))
                                      (map (lambda (rel) (list (string-append root "/" rel) (packages--name rel))) rels))
                              (packages--release-sources))
                          std))
         (raw (map (lambda (src)
                     (let ((text (read-file (car src))) (name (cadr src)))
                       (list 'name name 'file (car src) 'tier (if (null? table) (packages--tier-by-place (car src) name) (packages--tier-of name table))
                             'raw (packages--requires text) 'provides (packages--provides text))))
                   sources))
         ;; a feature is a file's base name, or what a file provides
         (features (append (map (lambda (p) (list (packages--base (plist-get p 'name)) p)) raw)
                           (apply append (map (lambda (p) (map (lambda (f) (list f p)) (plist-get p 'provides))) raw))))
         (rows (map (lambda (p)
                      (let* ((tier (plist-get p 'tier))
                             (manifest? (if (member (plist-get p 'name) packages--manifests) #t #f))
                             (reqs (map (lambda (r)
                                          (let* ((target (packages--resolve raw features (car r) (cadr r)))
                                                 (to (if target (plist-get target 'tier) "missing")))
                                            (list 'feature (car r) 'line (caddr r)
                                                  'target (and target (plist-get target 'name)) 'tier to
                                                  'break (and (not manifest?) target (packages-break? tier to)))))
                                        (plist-get p 'raw))))
                        (list 'id (plist-get p 'name) 'name (plist-get p 'name) 'file (plist-get p 'file) 'tier tier
                              'manifest manifest? 'requires reqs
                              'breaks (filter (lambda (r) (plist-get r 'break)) reqs))))
                    raw)))
    (map (lambda (row)
           (let ((name (plist-get row 'name)))
             (append row
                     (list 'required-by
                           (packages--dedup
                             (map (lambda (o) (plist-get o 'name))
                                  (filter (lambda (o)
                                            (and (not (plist-get o 'manifest))
                                                 (not (equal? (plist-get o 'name) name))
                                                 (pair? (filter (lambda (r) (equal? (plist-get r 'target) name)) (plist-get o 'requires)))))
                                          rows)))))))
         rows)))

(define (packages--main-branch dir)
  "the remote's main branch of the clone in DIR, as origin/NAME: origin/HEAD when the clone knows it, else origin/main"
  (let ((h (package--git dir "rev-parse --abbrev-ref origin/HEAD 2>/dev/null")))
    (if (and (string-prefix? "origin/" h) (not (equal? h "origin/HEAD"))) h "origin/main")))

(define (packages--main-behind dir)
  "the commits on the remote's main branch that the clone in DIR does not have, as the last fetch saw them"
  (let ((n (string->number (package--git dir (string-append "rev-list --count HEAD.." (packages--main-branch dir) " 2>/dev/null")))))
    (or n 0)))

(define (packages--installed-rows)
  "a row per installed package with its git state and open PRs; the id keeps it apart from a checkout file of the same name"
  (let ((lock (package-lock)) (pins (package-core-pins)))
  (map (lambda (n)
         (let* ((dir (package-directory n))
                (git (package-git-status n))
                (locked (assoc n lock)))
           (list 'id (string-append "installed:" n) 'name n 'tier "installed"
                 'repo (let ((u (and git (plist-get git 'url)))) (and (string? u) (package-github-repo u)))
                 'file (string-append dir "/" n ".scm") 'dir dir
                 'requires '() 'required-by '() 'breaks '()
                 'git git 'prs (package-prs n)
                 'sha (and (file-exists? (string-append dir "/.git")) (package--git dir "rev-parse --short HEAD"))
                 ;; how far HEAD is behind the remote's main branch, whatever branch the clone is on
                 'main-behind (and (file-exists? (string-append dir "/.git")) (packages--main-behind dir))
                 'pin (let ((p locked)) (and p (string? (caddr p)) (substring (caddr p) 0 (min 7 (string-length (caddr p))))))
                 'dev (let ((d (assoc n package-develop-directories))) (and d (cadr d)))
                 'held (and locked (> (length locked) 3) (plist-get (list-tail locked 3) 'held) #t)
                 'release-pin (let ((p (assoc n pins))) (and p (caddr p))))))
       (package-installed))))

(define (packages--git-text row)
  "branch +ahead -behind ~dirty, ASCII; empty for a checkout file"
  (let ((g (plist-get row 'git)))
    (if (not g) (if (plist-get row 'loaded) "loaded" "")
        (let ((num (lambda (pre k) (let ((v (plist-get g k))) (if (and v (> v 0)) (string-append " " pre (number->string v)) "")))))
          (string-append (or (plist-get g 'branch) "-") (let ((s (plist-get row 'sha))) (if (string? s) (string-append " " s) ""))
                         (num "+" 'ahead) (num "-" 'behind) (num "~" 'dirty))))))

(define (packages--personal-rows)
  "a row per file in the user's own package folders; the first folder that has a name wins, as load does"
  (let loop ((dirs (if (boundp 'personal-package-dirs) (personal-package-dirs) '())) (seen '()) (acc '()))
    (if (null? dirs)
        (reverse acc)
        (let* ((dir (car dirs))
               (names (map (lambda (f) (substring f 0 (- (string-length f) 4)))
                           (filter (lambda (f) (and (string-suffix? ".scm" f) (not (string-suffix? "-test.scm" f))))
                                   (list-dir dir))))
               (fresh (filter (lambda (n) (not (member n seen))) names)))
          (loop (cdr dirs) (append seen fresh)
                (append (reverse (map (lambda (n)
                                        (list 'id (string-append "personal:" n) 'name n 'tier "personal"
                                              'file (string-append dir "/" n ".scm") 'dir dir
                                              'loaded (if (member n *personal-packages*) #t #f)
                                              'requires '() 'required-by '() 'breaks '()))
                                      fresh))
                        acc))))))

(define (packages--parse-source source json)
  "the package rows SOURCE's gh answer JSON offers: a list of repos for an org, one repo for OWNER/REPO"
  (let* ((one? (string-index source "/"))
         (x (ignore-errors (lambda () (json-parse json))))
         (repos (cond ((not x) '()) (one? (list x)) ((list? x) x) (else '()))))
    (filter (lambda (r) r)
      (map (lambda (r)
             (let ((repo (plist-get r 'name)))
               (and (string? repo) (not (eq? (plist-get r 'isArchived) #t))
                    (or one? (string-prefix? "compos-" repo))
                    (let ((name (if (string-prefix? "compos-" repo) (substring repo 7 (string-length repo)) repo))
                          (full (if one? source (string-append source "/" repo))))
                      (list 'id (string-append "source:" full) 'name name 'tier "available" 'section "packages"
                            'source source 'repo full 'file #f
                            'description (let ((d (plist-get r 'description))) (if (string? d) d ""))
                            'requires '() 'required-by '() 'breaks '())))))
           repos))))

(define (packages--parse-sources out)
  "the rows of every source in OUT, the answer of packages--fetch-sources!: one @@source SOURCE line before each gh answer"
  (apply append
    (map (lambda (part)
           (let ((nl (string-index part "\n")))
             (if (not nl) '()
                 (let ((source (string-trim (substring part 0 nl))))
                   (if (member source packages-sources)
                       (packages--parse-source source (substring part (+ nl 1) (string-length part)))
                       '())))))
         (string-split out "@@source "))))

(define (packages--pinned-rows)
  "the packages init.scm and packages.lock name, as rows a source offers: they come first, so a pin wins over an org"
  (let ((row (lambda (name url source)
               (let ((repo (and (string? url) (package-github-repo url))))
                 (and repo (list 'id (string-append "source:" repo) 'name name 'tier "available" 'section "packages"
                                 'source source 'repo repo 'file #f 'description ""
                                 'requires '() 'required-by '() 'breaks '()))))))
    (filter (lambda (r) r)
            (append (map (lambda (r) (row (car r) (package-recipe-url (cdr r)) "init.scm")) package--recipes)
                    (map (lambda (p) (row (car p) (cadr p) "packages.lock")) (package-lock))))))

(define (packages--source-rows have)
  "what the sources offer, from the last fetch, less the names in HAVE; the first source that offers a name wins"
  (unless packages--source-cache
    (let ((c (cache-get 'packages "sources")))
      (when (string? c) (set! packages--source-cache (packages--parse-sources c)))))
  (let loop ((rs (append (packages--pinned-rows) (or packages--source-cache '()))) (seen have) (acc '()))
    (cond ((null? rs) (reverse acc))
          ((member (plist-get (car rs) 'name) seen) (loop (cdr rs) seen acc))
          (else (loop (cdr rs) (cons (plist-get (car rs) 'name) seen) (cons (car rs) acc))))))

(define (packages-update? row)
  "(packages-update? ROW) -- #t when ROW's clone is behind its tracked branch or behind the remote's main branch, as the last fetch saw it"
  (let ((g (plist-get row 'git)) (m (plist-get row 'main-behind)))
    (or (and g (number? (plist-get g 'behind)) (> (plist-get g 'behind) 0))
        (and (number? m) (> m 0)))))

(define (packages-available? row)
  "(packages-available? ROW) -- #t when ROW is a package a source offers and this machine does not have"
  (equal? (plist-get row 'tier) "available"))

(define (packages--all)
  "the installed clones, the user's personal packages, then every package as packages-scan gives it, each with its section, from the last scan"
  (or packages--scan-cache
      (begin (set! packages--scan-cache
                   (map (lambda (r) (append r (list 'section (packages--section r))))
                        (let ((here (append (packages--installed-rows) (packages--personal-rows) (packages-scan))))
                          (append here (packages--source-rows (map (lambda (r) (packages--base (plist-get r 'name))) here))))))
             packages--scan-cache)))

(define (packages-loaded? row)
  "(packages-loaded? ROW) -- #t when ROW's package is loaded now"
  (if (featurep (packages--feature row)) #t #f))

(define (packages-tier-breaks)
  "(packages-tier-breaks) -- every require that breaks the tier rules as a plist: from from-tier to to-tier feature file line"
  (apply append
    (map (lambda (p)
           (map (lambda (b) (list 'from (plist-get p 'name) 'from-tier (plist-get p 'tier)
                                  'to (plist-get b 'target) 'to-tier (plist-get b 'tier)
                                  'feature (plist-get b 'feature) 'file (plist-get p 'file) 'line (plist-get b 'line)))
                (plist-get p 'breaks)))
         (packages--all))))

;;; the listing

(define (packages--sep? row) (equal? (plist-get row 'kind) "sep"))

;; imenu makes a plural of a lower-case kind (function -> functions); a tier is a name, so it starts upper-case
(define (packages--tab-name tier)
  (string-append (string-upcase (substring tier 0 1)) (substring tier 1 (string-length tier))))

(define (packages--imenu-rows buf)
  "one imenu row per package, its section the kind: imenu has a tab for each section"
  (with-current-buffer buf
    (lambda ()
      (let loop ((os (list-offsets buf)) (es (list-entries buf)) (acc '()))
        (if (or (null? os) (null? es)) (reverse acc)
            (loop (cdr os) (cdr es)
                  (if (packages--sep? (car es)) acc
                      (cons (list (line-number-at-pos (car os)) (packages--tab-name (plist-get (car es) 'section)) (plist-get (car es) 'name)
                                  (if (null? (plist-get (car es) 'breaks)) "" (string-append "breaks: " (packages--break-text (car es)))))
                            acc))))))))

(define (packages--rows buf)
  ;; the list draws from here, so the buffer takes its imenu here too
  (buffer-set-local! buf 'imenu-index-function 'packages--imenu-rows)
  ;; by name; the id breaks a tie, as a clone and a checkout file can share a name
  (let ((ps (map caddr (sort (map (lambda (r) (list (plist-get r 'name) (plist-get r 'id) r)) (packages--all))))))
    (apply append
      (map (lambda (group)
             (let* ((title (car group))
                    (in (filter (lambda (r) (and (equal? (plist-get r 'section) (cadr group))
                                                 (eq? (packages-available? r) (caddr group))))
                                ps)))
               (if (null? in) '()
                   (cons (list 'kind "sep" 'id (string-append "sep:" title) 'section (cadr group)
                               'title (string-append title "  ·  " (number->string (length in))
                                                     (if (caddr group) "  ·  from " "  ·  ")
                                                     (if (caddr group) (string-join packages-sources ", ")
                                                         (string-append (number->string (length (filter packages-loaded? in))) " loaded"))))
                         in))))
           ;; (TITLE SECTION AVAILABLE?): what is here, by section, then what the sources offer
           '(("packages" "packages" #f) ("available" "packages" #t) ("stdlib" "stdlib" #f) ("core" "core" #f))))))

(define (packages--count xs) (if (pair? xs) (number->string (length xs)) ""))

(define (packages--break-text row)
  (string-join (packages--dedup (map (lambda (b) (string-append (plist-get b 'target) " (" (plist-get b 'tier) ")"))
                                     (plist-get row 'breaks)))
               ", "))

(define (packages--state-cell row)
  (cond ((packages-loaded? row) (list "loaded" "success"))
        ((packages-available? row) (list "get" "link"))
        (else (list "-" "shadow"))))

;; when the clones were last fetched; until then a clone's updates are not known
(define packages--checked #f)

(define (packages--updates-text row)
  "held, release pin (the release vouches for another commit), N behind, up to date, checking, or empty for a package that is no git clone"
  (let ((g (plist-get row 'git)) (pin (plist-get row 'release-pin)) (sha (plist-get row 'sha)))
    (cond ((not g) "")
          ((plist-get row 'held) "held")
          ((and (string? pin) (string? sha) (not (string-prefix? sha pin))) "release pin")
          ((packages-update? row) (string-append (number->string (plist-get g 'behind)) " behind"))
          ((not packages--checked) "checking…")
          (else "up to date"))))

(define (packages--updates-cell row)
  (let ((t (packages--updates-text row)))
    (cond ((equal? t "") "")
          ((equal? t "held") (list t "shadow"))
          ((or (packages-update? row) (equal? t "release pin")) (list t "warning"))
          ((equal? t "up to date") (list t "success"))
          (else (list t "shadow")))))

(define (packages--cells buf row)
  (if (packages--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "" "" "" "" "" "" "")
      (list (plist-get row 'name) (or (plist-get row 'source) (plist-get row 'section))
            (packages--state-cell row) (packages--updates-cell row)
            (plist-get row 'tier)
            (packages--count (plist-get row 'requires)) (packages--count (plist-get row 'required-by))
            (packages--git-text row) (packages--count (plist-get row 'prs))
            (if (null? (plist-get row 'breaks)) "" (list (packages--break-text row) "warning")))))

(define (packages--narrow-cells buf row)
  (if (packages--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "")
      (list (plist-get row 'name)
            (packages--state-cell row) (packages--updates-cell row)
            (if (null? (plist-get row 'breaks)) "" (list (packages--break-text row) "warning")))))

;;; the page

(define (packages--tone tier)
  (cond ((equal? tier "core") "info") ((equal? tier "standard") "good") ((equal? tier "unassigned") "warn") (else "")))

(define (packages--via r)
  (let ((t (plist-get r 'target)))
    (if (and t (not (equal? t (plist-get r 'feature)))) (string-append " -> " t) "")))

(define (packages--page row)
  "the page, and its anchors as blocks with their lines"
  (let* ((lines '())
         (line! (lambda (text) (set! lines (cons text lines)) (length lines)))
         (stop (lambda (blk name first last) (append blk (list 'anchor-name name 'lines (list first last)))))
         ;; a row is (TEXT BLOCK): TEXT is its line
         (req-row (lambda (r)
                    (let ((tier (string-append "  " (plist-get r 'tier)))
                          (at (string-append "  line " (number->string (plist-get r 'line)))))
                      (cons (string-append (plist-get r 'feature) (packages--via r) tier at)
                            (component 'ui/row
                              (list 'segs (list (list "" (plist-get r 'feature)) (list "c-dim" (packages--via r))
                                                (list (if (plist-get r 'break) "c-warn" "c-dim") tier)
                                                (list "c-dim" at))))))))
         (name-row (lambda (n) (cons n (component 'ui/row (list 'segs (list (list "" n)))))))
         (part (lambda (title name rows)
                 (let* ((first (line! title))
                        (body (let loop ((rs rows) (i 1) (acc '()))
                                (if (null? rs) (reverse acc)
                                    (loop (cdr rs) (+ i 1)
                                          (cons (let ((n (line! (car (car rs)))))
                                                  (stop (cdr (car rs)) (string-append name " " (number->string i)) n n))
                                                acc))))))
                   (stop (component 'ui/group (list 'title title 'body body)) name first (length lines)))))
         (count (lambda (title xs) (string-append title "  ·  " (number->string (length xs)))))
         (name (plist-get row 'name))
         (tier (plist-get row 'tier))
         (reqs (plist-get row 'requires))
         (breaks (plist-get row 'breaks))
         (by (plist-get row 'required-by))
         (head (let ((n (line! name)))
                 (stop (component 'ui/title (list 'text name 'badge tier 'tone (packages--tone tier))) "Title" n n)))
         (meta (component 'ui/meta
                 (list 'segs (list (cond ((packages-loaded? row) '("c-ok" "loaded"))
                                         ((packages-available? row) (list "c-accent" (string-append "available from " (plist-get row 'source))))
                                         (else '("c-dim" "not loaded")))
                                   (list "c-sep" (string-append "  ·  " (plist-get row 'section) "  ·  "))
                                   (list "" (string-append "requires " (number->string (length reqs))))
                                   '("c-sep" "  ·  ") (list "" (string-append "required by " (number->string (length by))))
                                   '("c-sep" "  ·  ") (list (if (null? breaks) "c-ok" "c-warn")
                                                             (if (null? breaks) "no tier breaks"
                                                                 (string-append (number->string (length breaks)) " tier breaks")))))))
         (actions (component 'ui/actions
                    (list 'actions (append (if (equal? (plist-get row 'section) "core") '()
                                               (cond ((packages-loaded? row) (list (list "packages-unload" "Unload" "k" "bad")))
                                                     ((packages-available? row) (list (list "packages-load" "Install" "l" "good")))
                                                     (else (list (list "packages-load" "Load" "l" "good")))))
                                           (if (and (equal? (plist-get row 'tier) "installed") (not (plist-get row 'dev)))
                                               (list (list "packages-uninstall" "Uninstall" "d" "bad")) '())
                                           (if (plist-get row 'repo) (list (list "packages-open-repo" "GitHub ↗" "o")) '())
                                           (if (plist-get row 'file) (list (list "packages-source" "Source" "v")) '())
                                         (if (plist-get row 'git) (list (list "packages-update" "Update" "u" "good")
                                                                         (list "packages-hold" (if (plist-get row 'held) "Let it update" "Hold") "h")
                                                                         (list "packages-pr" "Send upstream" "P")) '())
                                         (if (package-previous (plist-get row 'name)) (list (list "packages-rollback" "Roll back" "r" "bad")) '())
                                         (list (list "packages-refresh" "Scan again" "g"))))))
         (break-part (if (null? breaks) '() (list (part (count "Tier breaks" breaks) "Break" (map req-row breaks)))))
         (about (let ((n (line! "About")))
                  (stop (component 'ui/group
                          (list 'title "About"
                                'body (list (component 'ui/kv
                                              (list 'pairs (list (list "Tier" tier)
                                                                 (list "Source" (or (plist-get row 'file) (string-append "github.com/" (plist-get row 'repo))))
                                                                 (list "Role" (cond ((plist-get row 'manifest) "the boot manifest: its requires do not count")
                                                                                    ((let ((d (plist-get row 'description))) (and (string? d) (not (equal? d "")) d)))
                                                                                    (else "package")))))))))
                        "About" n n)))
         (git (plist-get row 'git))
         (kv-row (lambda (k v) (cons (string-append k "  " v)
                                     (component 'ui/row (list 'segs (list (list "c-dim" k) (list "" (string-append "  " v))))))))
         (num (lambda (k) (number->string (or (and git (plist-get git k)) 0))))
         (git-part (if (not git) '()
                       (list (part "Git" "Git"
                                   (list (kv-row "updates" (packages--updates-text row))
                                         (kv-row "branch" (or (plist-get git 'branch) "-"))
                                         (kv-row "commit" (or (plist-get row 'sha) "-"))
                                         (kv-row "pinned at" (string-append (or (plist-get row 'pin) "not pinned") (if (plist-get row 'held) ", held" "")))
                                         (kv-row "release vouches for" (let ((c (plist-get row 'release-pin))) (if (string? c) (substring c 0 (min 7 (string-length c))) "-")))
                                         (kv-row "upstream" (or (plist-get git 'upstream) "-"))
                                         (kv-row "ahead" (num 'ahead))
                                         (kv-row "behind" (num 'behind))
                                         (kv-row "changed files" (num 'dirty))
                                         (kv-row "origin" (or (plist-get git 'url) "-")))))))
         (prs (or (plist-get row 'prs) '()))
         (pr-part (if (null? prs) '()
                      (list (part (count "Open PRs" prs) "PR"
                                  (map (lambda (p)
                                         (let ((head (string-append "#" (number->string (car p)) " " (cadr p))))
                                           (cons (string-append head "  " (caddr p))
                                                 (component 'ui/row (list 'segs (list (list "" head) (list "c-dim" (string-append "  " (caddr p)))))))))
                                       prs)))))
         (req-part (if (null? reqs) '() (list (part (count "Requires" reqs) "Require" (map req-row reqs)))))
         (by-part (if (null? by) '() (list (part (count "Required by" by) "User" (map name-row by)))))
         (end (begin (line! "end") (component 'ui/row (list 'segs '(("c-dim" "end")))))))
    (list (string-join (reverse lines) "\n")
          (list (component 'ui/page
                  (list 'body (append (list head meta actions) break-part (list about) git-part pr-part req-part by-part (list end))))))))

(effects! '(write display))

(define (packages--list)
  (if (equal? (buffer-local-value 'mode-name (current-buffer)) "packages-mode")
      (current-buffer)
      (or (buffer-local-value 'packages-list (current-buffer)) *packages-buffer*)))

(define (packages--at)
  "the package at hand: the page's own, else the list's row"
  (or (buffer-local-value 'packages-row (current-buffer))
      (let ((r (list-current (packages--list)))) (and r (not (packages--sep? r)) r))))

(define (packages-show-detail! row)
  "(packages-show-detail! ROW) -- show the page of package ROW beside the list"
  (when (and row (not (packages--sep? row)))
    (let* ((list-buf (packages--list))
           (buf (string-append "*packages:" (plist-get row 'name) "*"))
           (page (packages--page row)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf))) (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "packages-detail-mode")))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (buffer-set-local! buf 'packages-row row)
      (buffer-set-local! buf 'packages-list list-buf)
      (buffer-set-read-only! buf #f)
      (buffer-set-text! buf (car page) #t)
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks (cadr page))
      (anchor-set-blocks! buf (car page) (cadr page))
      (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))
      (anchor-sync! buf)
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar (list 'main '(("l" "load/install") ("k" "unload") ("d" "uninstall") ("o" "github") ("v" "source") ("P" "send upstream") ("g" "scan again") ("q" "quit"))))))
      (buffer-set-read-only! buf #t)
      (display-buffer-detail! buf list-buf))))

(define (packages-visit-source! row)
  "(packages-visit-source! ROW) -- show package ROW's source file in the other window"
  (let ((file (and row (plist-get row 'file))))
    (if (not file)
        (message "No package here")
        (window-set-buffer! (get-other-window) (visit file (buffer-group (current-buffer)))))))

(define-list-mode! "packages-mode"
  (list
    'doc (string-append
           "Every package by where it lives: packages (scheme/packages, the installed clones and your own), stdlib (scheme/stdlib) and core (priv and scheme/core). "
           "The tabs across the top are all, packages, stdlib and core; left and right step them. "
           "A row shows whether the package is loaded, its tier from PACKAGES.md, how many packages it requires and how many require it, its git state and open PRs, and its tier breaks. "
           "Below what is here, available lists what the sources offer: packages-sources holds the GitHub orgs, users and OWNER/REPO repos to read, compos-dev by default; a adds a source of your own and R removes one. Packages init.scm or packages.lock name and this machine lacks show there too. l on an available package installs it: clones, loads, adds its use-package line to init.scm; d uninstalls an installed clone: drops that line and its pin and trashes the clone; o opens the repo on GitHub. "
           "l loads the package at point and k unloads it: its FEATURE-unload-function runs, its commands, catalog entries and names go, and the feature is forgotten. Core cannot be unloaded. "
           "Moving the point shows the package's page beside the list. RET or v visits the source, P sends a clone's changes upstream as a PR, "
           "g scans again and fetches every clone: the git column shows the commit and how far it is ahead or behind, the updates column says up to date or how many commits a clone is behind, and the echo names the ones behind (M-x packages-check-updates does the same from anywhere). "
           "Packages follow the compos release: u updates the package at point to the commit the release vouches for (a package of your own source to its newest), U updates every package, h holds one at its commit so updates skip it, and r rolls one back to the commit before its last update and holds it there; the updates column says held, release pin when the release vouches for another commit, N behind or up to date. "
           "An update never stops at a break: when it drops public names or raises the package's :major, the uses in your own code become a todo with the fix plan, and a chat starts on it for your review. "
           "/ narrows the rows (state:loaded, state:update, state:up-to-date, state:held, tier:core, breaks:NAME), q quits.")
    'buffer *packages-buffer*
    'transient #f
    'plain #t
    ;; the list keeps the rows of the tab and of / itself
    'local-filter #t
    ;; tabs across the top: one per tier, the breaks, then all with the tier sections
    'tabs (cons (list "all" (lambda (buf r) #t))
                (map (lambda (section) (list section (lambda (buf r) (equal? (plist-get r 'section) section))))
                     *packages-sections*))
    'rows packages--rows
    'key (lambda (buf row) (plist-get row 'id))
    'separator? (lambda (buf row) (packages--sep? row))
    'section? (lambda (buf row) (packages--sep? row))
    'section-label (lambda (buf row) (plist-get row 'title))
    'markable? (lambda (buf row) #f)
    'filters (list (list "state:" (lambda (b e) (if (packages--sep? e) "" (string-append (if (packages-loaded? e) "loaded" "unloaded") (if (packages-update? e) " update" (if (equal? (packages--updates-text e) "up to date") " up-to-date" "")) (if (plist-get e 'held) " held" "")))) "loaded, unloaded, update, up-to-date or held")
                   (list "tier:" (lambda (b e) (or (plist-get e 'tier) "")) "the package's tier")
                   (list "breaks:" (lambda (b e) (if (packages--sep? e) "" (packages--break-text e))) "a package it breaks the tier rules with"))
    'columns (lambda (buf) (list (list "package" 26) (list "in" 9) (list "state" 7) (list "updates" 11) (list "tier" 11) (list "req" 4) (list "by" 4) (list "git" 22) (list "prs" 4) (list "tier breaks" #f)))
    'cells packages--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 80)
                         'columns (lambda (buf) (list (list "package" 24) (list "state" 7) (list "updates" 11) (list "tier breaks" #f)))
                         'cells packages--narrow-cells)
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (packages-show-detail! row))
    'title (lambda (buf) (string-append "Packages  ·  " (number->string (length (packages-tier-breaks))) " tier breaks"))
    'total (lambda (buf) (length (filter (lambda (r) (not (packages--sep? r))) (list-entries buf))))
    'noun "package"
    'footer (lambda (buf) '(("u" "update") ("U" "update all") ("h" "hold") ("l" "load/install") ("k" "unload") ("d" "uninstall") ("o" "github") ("a" "add source") ("v" "source") ("P" "send upstream") ("/" "filter") ("g" "scan again") ("q" "quit")))
    'keys '(("RET" "packages-source") ("u" "packages-update") ("U" "packages-update-all") ("h" "packages-hold") ("r" "packages-rollback") ("l" "packages-load") ("k" "packages-unload") ("a" "packages-add-source") ("R" "packages-remove-source") ("d" "packages-uninstall") ("o" "packages-open-repo") ("v" "packages-source") ("P" "packages-pr") ("g" "packages-refresh") ("q" "quit-window"))))

(define-mode "packages-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "packages-detail-mode" '(("u" "packages-update") ("U" "packages-update-all") ("h" "packages-hold") ("r" "packages-rollback") ("l" "packages-load") ("k" "packages-unload") ("a" "packages-add-source") ("R" "packages-remove-source") ("d" "packages-uninstall") ("o" "packages-open-repo") ("v" "packages-source") ("P" "packages-pr") ("g" "packages-refresh")))
(define-command "packages-refresh" "Scan the packages again, then fetch the clones and their open PRs"
  (lambda ()
    (set! packages--scan-cache #f)
    (list-refresh! (packages--list))
    (packages-show-detail! (packages--at))
    (packages--fetch!))
  'modes '(packages-detail-mode packages-mode))

(define (packages--fetch! . quiet)
  "fetch the clones and their PRs, and what the sources offer, in tasks; the list draws them when they come, and the echo names the packages with updates"
  (packages-fetch-sources!)
  (package-fetch!
    (lambda (_)
      (set! packages--checked (current-time))
      (set! packages--scan-cache #f)
      (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*))
      (let ((behind (map (lambda (r) (plist-get r 'name)) (filter packages-update? (packages--all)))))
        (cond ((pair? behind)
               (message (string-append (number->string (length behind)) (if (= (length behind) 1) " package has" " packages have")
                                       " an update: " (string-join behind ", ") "  (/ state:update)")))
              ((null? quiet) (message "Every installed package is up to date")))))))

(effects! '(write external execute))

(define (packages--source-command source)
  (if (string-index source "/")
      (string-append "gh repo view " source " --json name,description,isArchived")
      (string-append "gh repo list " source " --limit 500 --json name,description,isArchived")))

(define (packages-fetch-sources! . k)
  "(packages-fetch-sources! [K]) -- read what every source in packages-sources offers with gh, in a task; cache it and redraw the list; K gets the rows"
  (shell-command->string
    (string-join (map (lambda (s) (string-append "echo '@@source " s "'; " (packages--source-command s) " 2>&1; echo"))
                      packages-sources)
                 "; ")
    (compos-home)
    (lambda (out)
      (cache-put! 'packages "sources" out)
      (set! packages--source-cache (packages--parse-sources out))
      (set! packages--scan-cache #f)
      (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*))
      (when (pair? k) ((car k) packages--source-cache)))))

(define (packages-add-source! source)
  "(packages-add-source! SOURCE) -- add a GitHub org, user or OWNER/REPO to packages-sources, save it, and read it"
  (let ((s (string-trim source)))
    (cond ((equal? s "") #f)
          ((not (re-match "^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$" s)) (message "A source is a GitHub org or user, or OWNER/REPO") #f)
          ((member s packages-sources) (message (string-append s " is already a source")) #f)
          (else (customize-save! 'packages-sources (append packages-sources (list s)))
                (message (string-append "reading " s))
                (packages-fetch-sources!)
                s))))

(define (packages-remove-source! source)
  "(packages-remove-source! SOURCE) -- drop SOURCE from packages-sources and save it; installed packages stay"
  (if (not (member source packages-sources))
      (begin (message (string-append source " is not a source")) #f)
      (begin (customize-save! 'packages-sources (filter (lambda (s) (not (equal? s source))) packages-sources))
             (set! packages--source-cache #f)
             (set! packages--scan-cache #f)
             (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*))
             (message (string-append "removed the source " source))
             source)))

(define (packages-on-event e)
  (when (and (memq (plist-get e 'kind) '(loaded failed changed thawed)) (buffer-known? *packages-buffer*))
    (set! packages--scan-cache #f)
    (list-refresh! *packages-buffer*)))

(event-subscribe! "packages" "packages" 'packages-on-event)

(define (packages-uninstall! row)
  "(packages-uninstall! ROW) -- uninstall ROW's installed clone: drop it from init.scm and packages.lock and trash the clone; its code stays loaded until k or a restart"
  (let ((name (plist-get row 'name)))
    (cond ((not (equal? (plist-get row 'tier) "installed")) (message (string-append name " is not an installed clone")) #f)
          ((plist-get row 'dev) (message (string-append name " is a develop checkout: M-x package-develop with an empty dir first")) #f)
          (else (package-manager-uninstall! name)
                (set! packages--scan-cache #f)
                (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*))
                #t))))

(define-command "packages-uninstall" "Uninstall the installed package at point: drop it from init.scm and trash its clone"
  (lambda ()
    (let ((row (packages--at)))
      (if (not row) (message "No package here")
          (y-or-n (string-append "Uninstall " (plist-get row 'name) "?")
                  (lambda () (packages-uninstall! row))))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-open-repo" "Open the GitHub repo of the package at point"
  (lambda () (package-manager-open-repo! (packages--at)))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-add-source" "Add a package source: a GitHub org or user, or OWNER/REPO"
  (interactive (lambda (k) (minibuffer-read "Add a source (GitHub org, user, or OWNER/REPO): " '() (lambda (s) (k (list s))))))
  (lambda (s) (packages-add-source! s))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-remove-source" "Remove a package source; what you installed from it stays"
  (interactive (lambda (k) (minibuffer-read "Remove the source: " packages-sources (lambda (s) (k (list s))))))
  (lambda (s) (packages-remove-source! s))
  'modes '(packages-detail-mode packages-mode))

;; the check runs from anywhere, though its name puts it in the packages app
;;;###autoload
(app-entry! "packages-check-updates")
;;;###autoload
(define-command "packages-check-updates" "Fetch every installed package and name the ones with updates"
  (lambda () (message "checking the packages for updates…") (packages--fetch!))
  'public #t)

(define-command "packages-pr" "Send the changes of the installed package at point upstream as a pull request"
  (interactive
    (lambda (k)
      (let ((row (packages--at)))
        (if (not (and row (plist-get row 'git)))
            (message "Not an installed package")
            (minibuffer-read (string-append "Describe the change to " (plist-get row 'name) ": ") '()
              (lambda (d) (k (list (plist-get row 'name) d))))))))
  (lambda (name d)
    (message (string-append "sending " name " upstream"))
    (package-pr name d
      (lambda (url)
        (when url
          (message (string-append "opened " url))
          (packages--fetch! #t)))))
  'modes '(packages-detail-mode packages-mode))
(effects! '(write display))
(mode-doc! "packages-detail-mode"
  "One package: whether it is loaded, where it lives, its tier, its tier breaks, what it requires and what requires it. l loads it, k unloads it, v visits its source, g scans again.")

;;; load and unload

(effects! '(write execute))

(define (packages--new-names before after)
  "the names in AFTER and not in BEFORE; both sorted"
  (let loop ((b before) (a after) (acc '()))
    (cond ((null? a) (reverse acc))
          ((null? b) (append (reverse acc) a))
          ((equal? (car a) (car b)) (loop (cdr b) (cdr a) acc))
          ((string<? (car a) (car b)) (loop b (cdr a) (cons (car a) acc)))
          (else (loop (cdr b) a acc)))))

(define (packages--redraw! row)
  (set! packages--scan-cache #f)
  (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*))
  (let ((buf (string-append "*packages:" (plist-get row 'name) "*")))
    (when (buffer-known? buf) (packages-show-detail! (buffer-local-value 'packages-row buf)))))

(define (packages-load! row)
  "(packages-load! ROW) -- load ROW's package into the live session and note the names it defines; #t when it loaded"
  (let ((name (plist-get row 'name)) (feature (packages--feature row)))
    (cond ((equal? (plist-get row 'section) "core") (message (string-append name " is core: it is always loaded")) #f)
          ((packages-loaded? row) (message (string-append name " is already loaded")) #f)
          ((packages-available? row)
           (message (string-append "installing " name " from " (plist-get row 'repo)))
           (package-manager-install! name (plist-get row 'repo))
           #t)
          (else
           (message (string-append "loading " name))
           (let* ((before (sort (global-names)))
                  (ok (ignore-errors (lambda () (load (symbol->string feature)) #t)))
                  (made (packages--new-names before (sort (global-names)))))
             (set! packages--defs (alist-put packages--defs feature made))
             (event-publish! "packages" (if ok 'loaded 'failed) name)
             (message (if ok (string-append "loaded " name ", " (number->string (length made)) " new names")
                          (string-append "loading " name " failed; see *Messages*")))
             (packages--redraw! row)
             (if ok #t #f))))))

(define (packages--names-of-feature feature)
  "every global name FEATURE owns: what its load here made, its catalog entries, and its private FEATURE-- names"
  (let* ((f (symbol->string feature))
         (made (let ((d (assq feature packages--defs))) (if d (cadr d) '())))
         (entries (filter (lambda (e) (equal? (plist-get e 'package) f)) (catalog)))
         (private (filter (lambda (n) (string-prefix? (string-append f "--") n)) (global-names))))
    (list entries (packages--dedup (append made private (map (lambda (e) (plist-get e 'name)) entries))))))

(define (packages-unload! row)
  "(packages-unload! ROW) -- unload ROW's package: run its FEATURE-unload-function, drop its commands, catalog entries, event subscription and globals, and forget the feature; #t when it unloaded"
  (let ((name (plist-get row 'name)) (feature (packages--feature row)))
    (cond ((equal? (plist-get row 'section) "core") (message (string-append name " is core: it cannot be unloaded")) #f)
          ((eq? feature 'packages) (message "packages runs this list: it cannot unload itself") #f)
          ((not (packages-loaded? row)) (message (string-append name " is not loaded")) #f)
          (else
           (let* ((f (symbol->string feature))
                  (hook (string->symbol (string-append f "-unload-function")))
                  (found (packages--names-of-feature feature))
                  (entries (car found)) (names (cadr found)))
             (when (boundp hook) (ignore-errors (lambda () ((symbol-value hook)))))
             (for-each (lambda (e)
                         (if (equal? (plist-get e 'kind) "command")
                             (ignore-errors (lambda () (undefine-command (plist-get e 'name))))
                             (catalog-forget! (string->symbol (plist-get e 'kind)) (plist-get e 'name))))
                       entries)
             (ignore-errors (lambda () (event-unsubscribe! f)))
             (for-each (lambda (n) (let ((s (string->symbol n))) (when (boundp s) (unbind-global! s)))) names)
             (set! *features* (remove (lambda (x) (eq? x feature)) *features*))
             (set! packages--defs (alist-delete packages--defs feature))
             (event-publish! "packages" 'unloaded name)
             (message (string-append "unloaded " name ", " (number->string (length names)) " names"))
             (packages--redraw! row)
             #t)))))

(define-command "packages-update" "Update the package at point to the commit the release vouches for; an API break files a fix for your code"
  (lambda ()
    (let ((row (packages--at)))
      (if (not row) (message "No package here")
          (package-update! (plist-get row 'name)
            (lambda (r)
              (unless (eq? (cadr r) 'updated)
                (message (string-append (car r) ": " (symbol->string (cadr r))
                                        (if (pair? (cddr r)) (string-append ", " (caddr r)) ""))))
              (packages--redraw! row))))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-update-all" "Update every package that is not held to the commits the release vouches for"
  (lambda ()
    (message "updating the packages…")
    (package-update-all! (lambda (rs) (set! packages--scan-cache #f)
                           (when (buffer-known? *packages-buffer*) (list-refresh! *packages-buffer*)))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-hold" "Hold the package at point at its commit, or let it update again"
  (lambda ()
    (let ((row (packages--at)))
      (if (not row) (message "No package here")
          (begin (package-hold! (plist-get row 'name)) (packages--redraw! row)))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-rollback" "Put the package at point back at the commit before its last update, and hold it there"
  (lambda ()
    (let ((row (packages--at)))
      (if (not row) (message "No package here")
          (package-rollback! (plist-get row 'name) (lambda (c) (packages--redraw! row))))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-load" "Load the package at point into the live session"
  (lambda () (let ((row (packages--at))) (if row (packages-load! row) (message "No package here"))))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-unload" "Unload the package at point: its commands, names and feature"
  (lambda () (let ((row (packages--at))) (if row (packages-unload! row) (message "No package here"))))
  'modes '(packages-detail-mode packages-mode))

(effects! '(write display))

;;;###autoload
(define-command "packages" "List every package by where it lives (packages, stdlib, core); load and unload them"
  (lambda ()
    (let ((buf (list-mode-show! "packages-mode")))
      (packages-show-detail! (list-current buf))
      (packages--fetch! #t)
      buf))
  'public #t)

(define-command "packages-source" "Visit the source of the package at point in the other window"
  (lambda () (packages-visit-source! (packages--at)))
  'modes '(packages-detail-mode packages-mode))



(effects! '(pure))
(public! 'packages-parse-tiers "(packages-parse-tiers TEXT) -- the assignment table of PACKAGES.md TEXT as ((NAME TIER) ...)")
(public! 'packages-break? "(packages-break? FROM-TIER TO-TIER) -- #t when a require from FROM-TIER to TO-TIER breaks the tier rules")
(effects! '(read))
(public! 'packages-scan "(packages-scan) -- every package of the checkout as a plist: name tier file requires required-by breaks")
(public! 'packages-loaded? "(packages-loaded? ROW) -- #t when ROW's package is loaded now")
(public! 'packages-update? "(packages-update? ROW) -- #t when ROW's clone is behind its remote, as the last fetch saw it")
(public! 'packages-available? "(packages-available? ROW) -- #t when ROW is a package a source offers and this machine does not have")
(effects! '(write execute))
(public! 'packages-fetch-sources! "(packages-fetch-sources! [K]) -- read what every source in packages-sources offers with gh, in a task; cache it and redraw the list; K gets the rows")
(public! 'packages-add-source! "(packages-add-source! SOURCE) -- add a GitHub org, user or OWNER/REPO to packages-sources, save it, and read it")
(public! 'packages-remove-source! "(packages-remove-source! SOURCE) -- drop SOURCE from packages-sources and save it; installed packages stay")
(public! 'packages-uninstall! "(packages-uninstall! ROW) -- uninstall ROW's installed clone: drop it from init.scm and packages.lock and trash the clone; its code stays loaded until k or a restart")
(public! 'packages-load! "(packages-load! ROW) -- load ROW's package into the live session and note the names it defines, or install it when a source offers it; #t when it loaded or the install started")
(public! 'packages-unload! "(packages-unload! ROW) -- unload ROW's package: run its FEATURE-unload-function, drop its commands, catalog entries, event subscription and globals, and forget the feature; #t when it unloaded")
(effects! '(read))
(public! 'packages-tier-breaks "(packages-tier-breaks) -- every require that breaks the tier rules as a plist: from from-tier to to-tier feature file line")
(effects! '(write display))
(public! 'packages-show-detail! "(packages-show-detail! ROW) -- show the page of package ROW beside the list")
(public! 'packages-visit-source! "(packages-visit-source! ROW) -- show package ROW's source file in the other window")

(provide 'packages)
