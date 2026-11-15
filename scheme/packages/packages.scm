;;; packages.scm --- M-x packages: every package, its tier, its requires and its tier breaks.
;;;
;;; v0 of the packages app in docs/FURTHER READING/internal/proposals/PACKAGES.md.
;;; The tier of a package comes from the assignment table in that document,
;;; so an edit of the table changes the app on the next g. A require from a
;;; package to a package of a lower tier is a tier break: core -> any other
;;; tier, standard -> community, dev or unassigned, community -> dev.
;;; init.scm is the boot manifest, not a package: its requires do not count.

(require 'tabulated-list)

(domain! 'packages)
(effects! '(pure))

(define *packages-buffer* "*packages*")
(define *packages-tiers* '("core" "standard" "community" "dev" "unassigned"))
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
    (let loop ((roots '("scheme/packages/" "scheme/apps/" "scheme/dev/" "scheme/core/" "apps/compos_core/priv/")))
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

(define (packages-scan)
  "(packages-scan) -- every package of the checkout as a plist: name tier file requires required-by breaks"
  (let* ((root (packages--root))
         (table (packages--tier-table))
         (rels (if root (filter packages--source? (project-files root)) '()))
         (raw (map (lambda (rel)
                     (let ((text (read-file (string-append root "/" rel))) (name (packages--name rel)))
                       (list 'name name 'file (string-append root "/" rel) 'tier (packages--tier-of name table)
                             'raw (packages--requires text) 'provides (packages--provides text))))
                   rels))
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

(define (packages-list)
  "(packages-list) -- every package as packages-scan gives it, from the last scan"
  (or packages--scan-cache (begin (set! packages--scan-cache (packages-scan)) packages--scan-cache)))
(public! 'packages-list "(packages-list) - every package of the checkout as a plist: name tier file requires required-by breaks; cached after the first scan")

(define (packages-tier-breaks)
  "(packages-tier-breaks) -- every require that breaks the tier rules as a plist: from from-tier to to-tier feature file line"
  (apply append
    (map (lambda (p)
           (map (lambda (b) (list 'from (plist-get p 'name) 'from-tier (plist-get p 'tier)
                                  'to (plist-get b 'target) 'to-tier (plist-get b 'tier)
                                  'feature (plist-get b 'feature) 'file (plist-get p 'file) 'line (plist-get b 'line)))
                (plist-get p 'breaks)))
         (packages-list))))

;;; the listing

(define (packages--sep? row) (equal? (plist-get row 'kind) "sep"))

(define (packages--rows buf)
  ;; a row is a plist that starts 'id NAME, so term order sorts by name
  (let ((ps (sort (packages-list))))
    (apply append
      (map (lambda (tier)
             (let ((in (filter (lambda (r) (equal? (plist-get r 'tier) tier)) ps)))
               (if (null? in) '()
                   (cons (list 'kind "sep" 'id (string-append "sep:" tier)
                               'title (string-append tier "  ·  " (number->string (length in))))
                         in))))
           *packages-tiers*))))

(define (packages--count xs) (if (null? xs) "" (number->string (length xs))))

(define (packages--break-text row)
  (string-join (packages--dedup (map (lambda (b) (string-append (plist-get b 'target) " (" (plist-get b 'tier) ")"))
                                     (plist-get row 'breaks)))
               ", "))

(define (packages--cells buf row)
  (if (packages--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "" "")
      (list (plist-get row 'name) (plist-get row 'tier)
            (packages--count (plist-get row 'requires)) (packages--count (plist-get row 'required-by))
            (if (null? (plist-get row 'breaks)) "" (list (packages--break-text row) "warning")))))

(define (packages--narrow-cells buf row)
  (if (packages--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "")
      (list (plist-get row 'name)
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
                 (list 'segs (list (list "" (string-append "requires " (number->string (length reqs))))
                                   '("c-sep" "  ·  ") (list "" (string-append "required by " (number->string (length by))))
                                   '("c-sep" "  ·  ") (list (if (null? breaks) "c-ok" "c-warn")
                                                             (if (null? breaks) "no tier breaks"
                                                                 (string-append (number->string (length breaks)) " tier breaks")))))))
         (actions (component 'ui/actions
                    (list 'actions (list (list "packages-source" "Source" "v") (list "packages-refresh" "Scan again" "g")))))
         (break-part (if (null? breaks) '() (list (part (count "Tier breaks" breaks) "Break" (map req-row breaks)))))
         (about (let ((n (line! "About")))
                  (stop (component 'ui/group
                          (list 'title "About"
                                'body (list (component 'ui/kv
                                              (list 'pairs (list (list "Tier" tier)
                                                                 (list "Source" (plist-get row 'file))
                                                                 (list "Role" (if (plist-get row 'manifest)
                                                                                  "the boot manifest: its requires do not count"
                                                                                  "package"))))))))
                        "About" n n)))
         (req-part (if (null? reqs) '() (list (part (count "Requires" reqs) "Require" (map req-row reqs)))))
         (by-part (if (null? by) '() (list (part (count "Required by" by) "User" (map name-row by)))))
         (end (begin (line! "end") (component 'ui/row (list 'segs '(("c-dim" "end")))))))
    (list (string-join (reverse lines) "\n")
          (list (component 'ui/page
                  (list 'body (append (list head meta actions) break-part (list about) req-part by-part (list end))))))))

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
        (list (component 'ui/keys-bar (list 'main '(("v" "source") ("g" "scan again") ("q" "quit"))))))
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
           "Every package of the compos checkout by tier: core, standard, community, dev and unassigned, "
           "as the assignment table in PACKAGES.md puts them. A row shows how many packages it requires, "
           "how many require it, and its tier breaks: each require of a package of a lower tier. "
           "Moving the point shows the package's page beside the list. RET or v visits the source, "
           "/ narrows the rows (tier:core, breaks:NAME), g scans again, q quits.")
    'buffer *packages-buffer*
    'transient #f
    'rows packages--rows
    'key (lambda (buf row) (plist-get row 'id))
    'separator? (lambda (buf row) (packages--sep? row))
    'section? (lambda (buf row) (packages--sep? row))
    'section-label (lambda (buf row) (plist-get row 'title))
    'markable? (lambda (buf row) #f)
    'filters (list (list "tier:" (lambda (b e) (or (plist-get e 'tier) "")) "the package's tier")
                   (list "breaks:" (lambda (b e) (if (packages--sep? e) "" (packages--break-text e))) "a package it breaks the tier rules with"))
    'columns (lambda (buf) (list (list "package" 26) (list "tier" 11) (list "req" 4) (list "by" 4) (list "tier breaks" #f)))
    'cells packages--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 80)
                         'columns (lambda (buf) (list (list "package" 24) (list "tier breaks" #f)))
                         'cells packages--narrow-cells)
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (packages-show-detail! row))
    'title (lambda (buf) (string-append "Packages  ·  " (number->string (length (packages-tier-breaks))) " tier breaks"))
    'total (lambda (buf) (length (filter (lambda (r) (not (packages--sep? r))) (list-entries buf))))
    'noun "package"
    'footer (lambda (buf) '(("v" "source") ("/" "filter") ("g" "scan again") ("q" "quit")))
    'keys '(("RET" "packages-source") ("v" "packages-source") ("g" "packages-refresh") ("q" "quit-window"))))

(define-mode "packages-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "packages-detail-mode" '(("v" "packages-source") ("g" "packages-refresh")))
(mode-doc! "packages-detail-mode"
  "One package: its tier, its tier breaks, what it requires and what requires it. v visits its source, g scans again.")

;;;###autoload
(define-command "packages" "List every package with its tier, its requires and its tier breaks"
  (lambda ()
    (let ((buf (list-mode-show! "packages-mode")))
      (packages-show-detail! (list-current buf))
      buf)))

(define-command "packages-source" "Visit the source of the package at point in the other window"
  (lambda () (packages-visit-source! (packages--at)))
  'modes '(packages-detail-mode packages-mode))

(define-command "packages-refresh" "Scan the packages again"
  (lambda ()
    (set! packages--scan-cache #f)
    (list-refresh! (packages--list))
    (packages-show-detail! (packages--at)))
  'modes '(packages-detail-mode packages-mode))

(effects! '(pure))
(public! 'packages-parse-tiers "(packages-parse-tiers TEXT) -- the assignment table of PACKAGES.md TEXT as ((NAME TIER) ...)")
(public! 'packages-break? "(packages-break? FROM-TIER TO-TIER) -- #t when a require from FROM-TIER to TO-TIER breaks the tier rules")
(effects! '(read))
(public! 'packages-scan "(packages-scan) -- every package of the checkout as a plist: name tier file requires required-by breaks")
(public! 'packages-list "(packages-list) -- every package as packages-scan gives it, from the last scan")
(public! 'packages-tier-breaks "(packages-tier-breaks) -- every require that breaks the tier rules as a plist: from from-tier to to-tier feature file line")
(effects! '(write display))
(public! 'packages-show-detail! "(packages-show-detail! ROW) -- show the page of package ROW beside the list")
(public! 'packages-visit-source! "(packages-visit-source! ROW) -- show package ROW's source file in the other window")

(provide 'packages)
