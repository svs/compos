;;; app-registry.scm --- M-x app-registry: every app in the editor, in three sections.
;;;
;;; An app is a listing with a page per row (see apps.scm). This app lists
;;; them all, from app-command-scopes, sectioned by where each comes from:
;;;
;;;   user     your own packages under ~/.compos/packages
;;;   package  packages installed with package-install from a URL
;;;   core     what ships with compos: the kernel and its bundled packages
;;;
;;; Moving the point shows the app's page: what it is, its file, its modes,
;;; its commands and the buffers it has open. o (or RET) opens the app,
;;; v visits its source.

(require 'tabulated-list)

(domain! 'commands)
(effects! '(write))
(category! 'commands)

(define *app-registry-buffer* "*app-registry*")
(define *app-registry-sections* '("user" "package" "core"))

(effects! '(pure))

(define (app-registry--first-line s)
  (if (not (string? s)) ""
      (let* ((s (string-trim s))
             (s (if (equal? s "") s (car (string-split s "\n")))))
        (if (> (string-length s) 120) (string-append (substring s 0 117) "...") s))))

(define (app-registry--sep? row) (equal? (plist-get row 'kind) "sep"))

(effects! '(read))

(define (app-registry--meta kind name)
  (and (boundp 'catalog-entry) (catalog-entry kind name)))

(define (app-registry-section origin namespace package)
  "(app-registry-section ORIGIN NAMESPACE PACKAGE) -- user, package or core"
  (cond ((or (equal? origin "builtin") (equal? origin "bundled") (equal? namespace "core")) "core")
        ((and package (cache-get 'package-source package)) "package")
        (else "user")))

(define (app-registry--row scope)
  (let* ((entry (car scope))
         (modes (cadr scope))
         (cmds (caddr scope))
         (launch? (not (member entry (mode-names))))
         (cm (and launch? (app-registry--meta 'command entry)))
         (mm (and (pair? modes) (app-registry--meta 'mode (car modes))))
         (meta (or cm mm '()))
         (pkg (plist-get meta 'package))
         (doc (let ((d (and cm (plist-get cm 'doc))))
                (if (and (string? d) (not (equal? d ""))) d (and mm (plist-get mm 'doc))))))
    (list 'kind "app" 'id entry 'name entry
          'entry (and launch? entry)
          'modes modes 'commands cmds
          'package pkg
          'origin (plist-get meta 'origin)
          'section (app-registry-section (plist-get meta 'origin) (plist-get meta 'namespace) pkg)
          'file (and pkg (locate-library pkg))
          'source (and pkg (cache-get 'package-source pkg))
          'doc (or doc ""))))

(define (app-registry--fold rows)
  ;; a view with no entry of its own, such as a package's page mode, joins
  ;; the app of its package that has an entry
  (let ((owner (lambda (r) (and (not (plist-get r 'entry)) (plist-get r 'package)
                                (find (lambda (o) (and (plist-get o 'entry)
                                                       (equal? (plist-get o 'package) (plist-get r 'package))))
                                      rows)))))
    (let ((strays (filter owner rows)))
      (filter (lambda (r) r)
        (map (lambda (r)
               (cond ((member r strays) #f)
                     (else (let ((mine (filter (lambda (s) (eq? (owner s) r)) strays)))
                             (if (null? mine) r
                                 (append (list 'modes (append (plist-get r 'modes) (apply append (map (lambda (s) (plist-get s 'modes)) mine))))
                                         r))))))
             rows)))))

(define (app-registry--page-mode? m lists)
  (or (string-suffix? "-detail-mode" m) (not (member m lists))))

(define (app-registry--app? r lists)
  ;; an app is a listing with a page per row, opened by one command: a list
  ;; alone, such as ibuffer, is not one
  (and (plist-get r 'entry)
       (find (lambda (m) (app-registry--page-mode? m lists)) (plist-get r 'modes))))

(define (app-registry-apps)
  "(app-registry-apps) -- every app as a plist: name entry modes commands package section file source doc"
  (let ((lists (if (boundp '*list-modes*) (map (lambda (e) (if (pair? e) (car e) e)) *list-modes*) '())))
    (map cdr (sort (map (lambda (r) (cons (string-downcase (plist-get r 'name)) r))
                        (filter (lambda (r) (app-registry--app? r lists))
                                (app-registry--fold (map app-registry--row (app-command-scopes)))))))))

(define (app-registry--open-buffers row)
  (let ((modes (plist-get row 'modes)))
    (filter (lambda (b) (member (buffer-local-value 'mode-name b) modes)) (buffer-list))))

(define (app-registry--rows buf)
  (let ((apps (app-registry-apps)))
    (apply append
      (map (lambda (s)
             (let ((in (filter (lambda (r) (equal? (plist-get r 'section) s)) apps)))
               (if (null? in) '()
                   (cons (list 'kind "sep" 'id (string-append "sep:" s) 'title s) in))))
           *app-registry-sections*))))

(define (app-registry--cells buf row)
  (if (app-registry--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "")
      (list (plist-get row 'name)
            (or (plist-get row 'package) "")
            (let ((n (length (app-registry--open-buffers row)))) (if (= n 0) "" (number->string n)))
            (app-registry--first-line (plist-get row 'doc)))))

(define (app-registry--narrow-cells buf row)
  (if (app-registry--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "")
      (list (plist-get row 'name) (app-registry--first-line (plist-get row 'doc)))))

;; the page, and its anchors as (NAME START END) over character offsets
;; the page: (TEXT BLOCKS). Every part is one line of TEXT and an anchor
;; on it, so the arrows walk the page part by part.
(define (app-registry--page row)
  (let* ((lines '())
         (line! (lambda (text) (set! lines (cons text lines)) (length lines)))
         (stop (lambda (blk name first last) (append blk (list 'anchor-name name 'lines (list first last)))))
         ;; a row is (TEXT BLOCK): TEXT is its line, the name and what it does
         (dim-row (lambda (name about)
                    (cons (if (equal? about "") name (string-append name "  " about))
                          (component 'ui/row (list 'segs (list (list "" name) (list "c-dim" (if (equal? about "") "" (string-append "  " about)))))))))
         (part (lambda (title name rows)
                 ;; a titled group: its heading is a line, and each row one more
                 (let* ((first (line! title))
                        (body (let loop ((rs rows) (i 1) (acc '()))
                                (if (null? rs) (reverse acc)
                                    (loop (cdr rs) (+ i 1)
                                          (cons (let ((n (line! (car (car rs))))) (stop (cdr (car rs)) (string-append name " " (number->string i)) n n)) acc))))))
                   (stop (component 'ui/group (list 'title title 'body body)) name first (length lines)))))
         (count (lambda (title xs) (string-append title "  ·  " (number->string (length xs)))))
         (name (plist-get row 'name))
         (section (plist-get row 'section))
         (entry (plist-get row 'entry))
         (file (plist-get row 'file))
         (doc (plist-get row 'doc))
         (modes (plist-get row 'modes))
         (cmds (filter (lambda (c) (not (member c modes))) (plist-get row 'commands)))
         (open (app-registry--open-buffers row))
         (doc-of (lambda (kind n) (let ((e (app-registry--meta kind n))) (app-registry--first-line (and e (plist-get e 'doc))))))
         (head (let ((n (line! name)))
                 (stop (component 'ui/title (list 'text name 'badge section
                                                  'tone (cond ((equal? section "user") "info") ((equal? section "package") "good") (else ""))))
                       "Title" n n)))
         (meta (component 'ui/meta
                 (list 'segs (list (list "" (or (plist-get row 'package) "no package"))
                                   '("c-sep" "  ·  ") (list "" (string-append (number->string (length modes)) " modes"))
                                   '("c-sep" "  ·  ") (list "" (string-append (number->string (length cmds)) " commands"))
                                   '("c-sep" "  ·  ") (list (if (null? open) "c-dim" "c-ok")
                                                             (if (null? open) "not open" (string-append (number->string (length open)) " open")))))))
         (actions (component 'ui/actions
                    (list 'actions (append (if entry (list (list "app-registry-open" "Open app" "o" "good")) '())
                                           (if file (list (list "app-registry-source" "Source" "v")) '())
                                           (list (list "app-registry-refresh" "Refresh" "g"))))))
         (about (let ((n (line! "About")))
                  (stop (component 'ui/group
                          (list 'title "About"
                                'body (list (list 'tag "c-group" 'class "c-prose c-lines"
                                                  'text (if (equal? doc "") "No description." doc)))))
                        "About" n n)))
         (details (let ((n (line! "Details")))
                    (stop (component 'ui/group
                            (list 'title "Details"
                                  'body (list (component 'ui/kv
                                                (list 'pairs (filter pair?
                                                               (list (list "Opens with" (if entry (string-append "M-x " entry) "another app"))
                                                                     (list "Package" (or (plist-get row 'package) "unknown"))
                                                                     (and file (list "Source" file))
                                                                     (and (plist-get row 'source) (list "Installed from" (plist-get row 'source))))))))))
                          "Details" n n)))
         (mode-part (part (count "Modes" modes) "Mode" (map (lambda (m) (dim-row m (doc-of 'mode m))) modes)))
         (open-part (if (null? open) '() (list (part (count "Open buffers" open) "Buffer" (map (lambda (b) (dim-row b "")) open)))))
         (cmd-part (if (null? cmds) '() (list (part (count "Commands" cmds) "Command" (map (lambda (c) (dim-row c (doc-of 'command c))) cmds))))))
    (list (string-join (reverse lines) "\n")
          (list (component 'ui/page
                  (list 'body (append (list head meta actions about details mode-part) open-part cmd-part)))))))

(effects! '(write display))

(define (app-registry--list)
  (if (equal? (buffer-local-value 'mode-name (current-buffer)) "app-registry-mode")
      (current-buffer)
      (or (buffer-local-value 'app-registry-list (current-buffer)) *app-registry-buffer*)))

(define (app-registry--at)
  "the app at hand: the page's own, else the list's row"
  (or (buffer-local-value 'app-registry-app (current-buffer))
      (let ((r (list-current (app-registry--list)))) (and r (not (app-registry--sep? r)) r))))

(define (app-registry-show-detail! row)
  "(app-registry-show-detail! ROW) -- show the page of app ROW beside the registry"
  (when (and row (not (app-registry--sep? row)))
    (let* ((list-buf (app-registry--list))
           (buf (string-append "*app-registry:" (plist-get row 'name) "*"))
           (page (app-registry--page row)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf))) (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "app-registry-detail-mode")))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (buffer-set-local! buf 'app-registry-app row)
      (buffer-set-local! buf 'app-registry-list list-buf)
      (buffer-set-read-only! buf #f)
      (buffer-set-text! buf (car page) #t)
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks (cadr page))
      (anchor-set-blocks! buf (car page) (cadr page))
      (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))
      (anchor-sync! buf)
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar
                (list 'main '(("o" "open app") ("v" "source") ("g" "refresh") ("q" "quit"))))))
      (buffer-set-read-only! buf #t)
      (display-buffer-detail! buf list-buf))))

(define (app-registry-open! row)
  "(app-registry-open! ROW) -- run app ROW's entry command"
  (cond ((not row) (message "No app here"))
        ((not (plist-get row 'entry)) (message (string-append (plist-get row 'name) " has no entry command")))
        (else (run-command (plist-get row 'entry)))))

(define (app-registry-visit-source! row)
  "(app-registry-visit-source! ROW) -- show app ROW's source file in the other window"
  (let ((file (and row (plist-get row 'file))))
    (if (not file)
        (message "No source file for this app")
        (window-set-buffer! (get-other-window) (visit file (buffer-group (current-buffer)))))))

(define-list-mode! "app-registry-mode"
  (list
    'doc (string-append
           "Every app in the editor, in three sections: user (your own packages under ~/.compos/packages), "
           "package (installed with package-install) and core (what ships with compos). "
           "Moving the point shows the app's page beside the list: its modes, its commands and its open buffers. "
           "o or RET opens the app, v visits its source, / narrows the rows, g reads the apps again, q quits.")
    'buffer *app-registry-buffer*
    'transient #f
    'rows app-registry--rows
    'key (lambda (buf row) (plist-get row 'id))
    'body (lambda (buf r) (if (app-registry--sep? r) "" (plist-get r 'doc)))
    'separator? (lambda (buf row) (app-registry--sep? row))
    'section? (lambda (buf row) (app-registry--sep? row))
    'section-label (lambda (buf row) (plist-get row 'title))
    'markable? (lambda (buf row) #f)
    'columns (lambda (buf) (list (list "app" 24) (list "package" 16) (list "open" 5) (list "about" #f)))
    'cells app-registry--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 90)
                         'columns (lambda (buf) (list (list "app" 22) (list "about" #f)))
                         'cells app-registry--narrow-cells)
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (app-registry-show-detail! row))
    'title (lambda (buf) "Apps")
    'total (lambda (buf) (length (filter (lambda (r) (not (app-registry--sep? r))) (list-entries buf))))
    'noun "app"
    'footer (lambda (buf) '(("o" "open app") ("v" "source") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "app-registry-open") ("o" "app-registry-open") ("v" "app-registry-source")
            ("g" "app-registry-refresh") ("q" "quit-window"))))

(define-mode "app-registry-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "app-registry-detail-mode"
  '(("o" "app-registry-open") ("v" "app-registry-source") ("g" "app-registry-refresh")))
(mode-doc! "app-registry-detail-mode"
  "One app: what it is, where its source is, its modes, its commands and the buffers it has open. o opens the app, v visits its source, g reads it again.")

(define-command "app-registry" "Browse every app: yours, installed packages, and core"
  (lambda ()
    (let ((buf (list-mode-show! "app-registry-mode")))
      (app-registry-show-detail! (list-current buf))
      buf)))

(define-command "app-registry-open" "Open the app at point"
  (lambda () (app-registry-open! (app-registry--at)))
  'modes '(app-registry-detail-mode app-registry-mode))

(define-command "app-registry-source" "Visit the source of the app at point in the other window"
  (lambda () (app-registry-visit-source! (app-registry--at)))
  'modes '(app-registry-detail-mode app-registry-mode))

(define-command "app-registry-refresh" "Read the apps again"
  (lambda ()
    (list-refresh! (app-registry--list))
    (app-registry-show-detail! (app-registry--at)))
  'modes '(app-registry-detail-mode app-registry-mode))

(effects! '(read))
(public! 'app-registry-apps "(app-registry-apps) -- every app as a plist: name entry modes commands package section file source doc")
(public! 'app-registry-section "(app-registry-section ORIGIN NAMESPACE PACKAGE) -- the registry section of a package: user, package or core")
(effects! '(write display))
(public! 'app-registry-show-detail! "(app-registry-show-detail! ROW) -- show the page of app ROW beside the registry")
(public! 'app-registry-open! "(app-registry-open! ROW) -- run app ROW's entry command")
(public! 'app-registry-visit-source! "(app-registry-visit-source! ROW) -- show app ROW's source file in the other window")

(provide 'app-registry)
