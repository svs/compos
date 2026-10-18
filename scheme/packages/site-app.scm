;;; site-app.scm --- turn a live website into a compos list-and-detail app

(package! 'site-app)
(origin! 'bundled)

(domain! 'web)
(effects! '(read))

(define *site-apps* '())
;; each app's one hidden reader tab, kept on disk so a restart reuses it
;; instead of opening another in the browser
(define *site-app-tabs-file* (string-append (compos-home) "/site-app-tabs.json"))

(define (site-app-tabs-load)
  (let ((text (and (file-exists? *site-app-tabs-file*) (read-file *site-app-tabs-file*))))
    (if (and (string? text) (> (string-length text) 2))
        (map (lambda (e) (list (string->symbol (car e)) (cadr e)))
             (filter (lambda (e) (and (pair? e) (string? (car e)) (number? (cadr e)))) (json-parse text)))
        '())))

(define *site-app-tabs* (site-app-tabs-load))

(define (site-app-find pred xs)
  (let loop ((rest xs))
    (cond ((null? rest) #f)
          ((pred (car rest)) (car rest))
          (else (loop (cdr rest))))))

(define (site-app-spec name)
  (let ((hit (assoc name *site-apps*))) (and hit (cadr hit))))

(define (site-app-put! name spec)
  (set! *site-apps* (alist-put *site-apps* name spec)) spec)

(define (site-app-tab name)
  (let ((hit (assoc name *site-app-tabs*))) (and hit (cadr hit))))

(define (site-app-note-tab! name tab)
  (set! *site-app-tabs* (alist-put *site-app-tabs* name tab))
  (write-file! *site-app-tabs-file*
    (json-encode (map (lambda (e) (list (symbol->string (car e)) (cadr e)))
                      (filter (lambda (e) (number? (cadr e))) *site-app-tabs*))))
  tab)

;; The app's tab is disposable. When Chrome says it navigated away or closed,
;; drop it and let the next call open a fresh background tab.
(define (site-app-replace-tab! name)
  (let ((old (site-app-tab name)))
    (site-app-note-tab! name #f)
    (when old (tab-close old))))

(define (site-app-buffer name) (string-append "*" (symbol->string name) "*"))
(define (site-app-mode name) (string-append (symbol->string name) "-mode"))
;; each section of the site is its own index buffer, in a list mode of its own
(define (site-app-page-buffer name id)
  (string-append "*" (symbol->string name) "-" (symbol->string id) "*"))
(define (site-app-page-mode name id)
  (string-append (symbol->string name) "-" (symbol->string id) "-mode"))
(define (site-app-pages spec) (or (plist-get spec 'pages) '()))

(define (site-app-page spec id)
  (site-app-find (lambda (page) (equal? (plist-get page 'id) id)) (site-app-pages spec)))

(define (site-app-current-page buf)
  ;; the live spec by name: a reloaded app must not keep serving the old one
  (let* ((kept (buffer-local buf 'site-app-spec))
         (spec (or (and kept (site-app-spec (plist-get kept 'name))) kept)))
    (site-app-page spec (buffer-local buf 'site-app-page))))

(define (site-app-url spec path)
  (if (or (string-prefix? "http://" path) (string-prefix? "https://" path))
      path
      (string-append (plist-get spec 'base-url) path)))

(define (site-app-host-url? spec url)
  (and (string? url) (string-prefix? (plist-get spec 'base-url) url)))

(define (site-app-parse sheet html)
  (let ((out (and (string? html) (xslt-apply sheet html))))
    (and (string? out) (> (string-length out) 1)
         ;; a paragraph break in the page's text comes through raw, which JSON refuses
         (json-parse (re-replace-all "[\\r\\n]" (re-replace-all "\\t" out " ") "\\\\n")))))

(define (site-app-field row key)
  (let ((value (plist-get row key)))
    (cond ((string? value) value) ((not value) "") (else (format "~a" value)))))

(define (site-app-columns buf)
  (map (lambda (col) (list (plist-get col 'label) (plist-get col 'width)))
       (or (plist-get (site-app-current-page buf) 'columns) '())))

(define (site-app-cells buf row)
  (map (lambda (col)
         (let ((text (site-app-field row (plist-get col 'field)))
               (face (plist-get col 'face)))
           (if face (list text face) text)))
       (or (plist-get (site-app-current-page buf) 'columns) '())))

(define (site-app-row-key buf row)
  (or (plist-get row 'key) (plist-get row 'href)))

(define site-app-section-click "site-app-section:")
(define site-app-status-click "site-app-status:")

(define (site-app-filter-on? tab query)
  ;; a grouped filter is one facet of several, so only the page knows it is on
  (if (and query (not (plist-get tab 'group)))
      (equal? (plist-get tab 'query) query)
      (equal? (plist-get tab 'active) "yes")))

(define (site-app-page-shortcut page)
  ;; the key a section's tab shows: the app's own 'shortcut, else M-KEY
  (or (plist-get page 'shortcut) (string-append "M-" (plist-get page 'key))))

(define (site-app-lead-tabs buf)
  ;; an app's 'lead-tabs (buf) gives tabs of its own before the sections, as
  ;; (CLICK LABEL ACTIVE KEY); its block-click hook takes the CLICK
  (let ((lead (plist-get (buffer-local buf 'site-app-spec) 'lead-tabs)))
    (if lead (lead buf) '())))

(define (site-app-composml-head buf head)
  ;; the site's navbar, then the section's status tabs, each a row of tabs.
  ;; An app's 'list-head (buf) puts blocks of its own above them
  (let* ((spec (buffer-local buf 'site-app-spec))
         (current (buffer-local buf 'site-app-page))
         (filters (or (buffer-local buf 'site-app-filters) '()))
         (query (buffer-local buf 'site-app-filter))
         (own (plist-get spec 'list-head)))
    (append
      (if own (own buf) '())
      (list (component 'ui/tabs
              (list 'class "sa-sections"
                    'tabs (append (site-app-lead-tabs buf)
                                  (map (lambda (page)
                                         (list (string-append site-app-section-click (symbol->string (plist-get page 'id)))
                                               (plist-get page 'label)
                                               (equal? current (plist-get page 'id))
                                               (site-app-page-shortcut page)))
                                       (site-app-pages spec))))))
      ;; one row of tabs per group of filters, in the page's order
      (map (lambda (group)
             (component 'ui/tabs
               (list 'class (if group (string-append "sa-status sa-status-" group) "sa-status")
                     'tabs (map (lambda (tab)
                                  (let ((count (plist-get tab 'count)))
                                    (list (string-append site-app-status-click (plist-get tab 'query))
                                          (if (equal? count "") (plist-get tab 'label)
                                              (string-append (plist-get tab 'label) " " count))
                                          (site-app-filter-on? tab query))))
                                (filter (lambda (tab) (equal? (plist-get tab 'group) group)) filters)))))
           (fold (lambda (groups tab)
                   (if (member (plist-get tab 'group) groups) groups (append groups (list (plist-get tab 'group)))))
                 '() filters)))))

(define (site-app-stars text &optional confirmed?)
  ;; a rating in any shape the sheets give it, "4", "3.5", "★★★" or "★★★✓",
  ;; as (N MET?): its whole stars, and whether a person met the candidate and
  ;; so confirmed it. A trailing ✓ is the sheets' mark for confirmed. #f when
  ;; the text is no rating
  (let* ((t (string-trim (or text "")))
         (met? (or confirmed? (re-match? "✓$" t)))
         (glyphs (re-match? "^★+ ?✓?$" t))
         (n (if glyphs
                (- (length (string-split t "★")) 1)
                (let ((x (string->number t)))
                  (and (number? x)
                       (let loop ((i 0)) (if (and (< i 5) (<= (+ i 1) (+ x 0.5))) (loop (+ i 1)) i)))))))
    (and n (> n 0) (list n met?))))

(define (site-app-stars-string text &optional confirmed?)
  ;; the one way a rating draws: a star a point, filled once met, hollow until then
  (let ((r (site-app-stars text confirmed?)))
    (if (not r)
        ""
        (let loop ((i (car r)) (s ""))
          (if (= i 0) s (loop (- i 1) (string-append s (if (cadr r) "★" "☆"))))))))

(define (site-app-stars-segs text &optional confirmed?)
  ;; the rating as one gold seg; anything that is no rating stays as it is
  (let ((r (site-app-stars text confirmed?)))
    (if r
        (list (list (if (cadr r) "sa-stars sa-stars-met" "sa-stars sa-stars-guess")
                    (site-app-stars-string text confirmed?)))
        (list (list "" (or text ""))))))

(define (site-app-avatar-url buf src)
  (if (string-prefix? "/" src)
      (string-append (plist-get (buffer-local buf 'site-app-spec) 'base-url) src)
      src))

(define (site-app-cell buf col row)
  ;; one cell; a column's 'kind draws it as a status pill, gold stars, an
  ;; avatar or a name. A cell draws its segs and text, never nested blocks, so
  ;; a pill is a seg and an avatar is the cell itself
  (let ((text (or (site-app-field row (plist-get col 'field)) ""))
        (kind (plist-get col 'kind))
        (class (if (plist-get col 'face) (string-append "sa-cell c-" (plist-get col 'face)) "sa-cell")))
    (cond ((equal? text "") (list 'tag "span" 'class class 'text ""))
          ((eq? kind 'badge)
           (let ((tone (site-app-tone-class (plist-get (buffer-local buf 'site-app-spec) 'tones) text)))
             (list 'tag "span" 'class (string-append class " sa-badge-cell")
                   'segs (list (list (if tone (string-append "c-badge sa-pill " tone) "c-badge sa-pill") text)))))
          ((eq? kind 'stars)
           (let ((confirmed (plist-get col 'confirmed)))
             (list 'tag "span" 'class (string-append class " sa-stars-cell")
                   'segs (site-app-stars-segs text (and confirmed (not (equal? (site-app-field row confirmed) "")))))))
          ((eq? kind 'avatar)
           (list 'tag "img" 'class (string-append class " sa-avatar")
                 'attrs (list (list "src" (site-app-avatar-url buf text)) (list "alt" "")
                              (list "loading" "lazy") (list "referrerpolicy" "no-referrer"))))
          ((eq? kind 'name) (list 'tag "span" 'class (string-append class " sa-name-cell") 'text text))
          (else (list 'tag "span" 'class class 'text text)))))

(define (site-app-composml buf row)
  ;; a row as blocks: one cell per column, on the column widths. Its class
  ;; names the width the fixed columns need with room left for the one that
  ;; takes the rest; the stylesheet moves that one to a line of its own in a
  ;; narrower window rather than squeezing it into a sliver. A page with a
  ;; 'row (buf row) draws its rows itself
  (let* ((page (site-app-current-page buf))
         (cols (or (plist-get page 'columns) '()))
         (fixed (fold (lambda (sum col) (+ sum 1 (or (plist-get col 'width) 0))) 0 cols))
         (need (* 10 (quotient (+ fixed 30 9) 10))))
    (if (plist-get page 'row)
        ((plist-get page 'row) buf row)
        (list 'tag "div" 'class (string-append "sa-row sa-need-" (number->string (min 140 (max 60 need))))
              'attrs (list (list "style"
                                 (string-append "grid-template-columns:"
                                                (string-join (map (lambda (col)
                                                                    (let ((w (plist-get col 'width)))
                                                                      (if w (string-append (number->string w) "ch") "minmax(0,1fr)")))
                                                                  cols)
                                                             " "))))
              'children (map (lambda (col) (site-app-cell buf col row))
                             cols)))))

(define (site-app-title buf)
  (let* ((spec (buffer-local buf 'site-app-spec))
         (page (site-app-current-page buf)))
    (string-append (or (plist-get spec 'title) (symbol->string (plist-get spec 'name)))
                   " · " (or (plist-get page 'label) ""))))

(define (site-app-header buf)
  ;; the site's navbar, then the section's own status tabs when it has them
  (let* ((spec (buffer-local buf 'site-app-spec))
         (current (buffer-local buf 'site-app-page))
         (mark (lambda (text on) (if on (string-append "[" text "]") (string-append " " text " "))))
         (nav (string-join
                (append
                  (map (lambda (tab) (mark (string-append (list-ref tab 3) " " (cadr tab)) (caddr tab)))
                       (site-app-lead-tabs buf))
                  (map (lambda (page)
                         (mark (string-append (site-app-page-shortcut page) " " (plist-get page 'label))
                               (equal? current (plist-get page 'id))))
                       (site-app-pages spec)))
                " "))
         (filters (or (buffer-local buf 'site-app-filters) '()))
         (query (buffer-local buf 'site-app-filter)))
    (if (null? filters)
        nav
        (string-append nav "\n"
          (string-join
            (map (lambda (tab)
                   (let* ((count (plist-get tab 'count))
                          (text (if (equal? count "") (plist-get tab 'label)
                                    (string-append (plist-get tab 'label) " " count))))
                     (if (equal? (plist-get tab 'query) query)
                         (string-append "[" text "]")
                         (string-append " " text " "))))
                 filters)
            " ")))))

(define (site-app-head-part blocks)
  ;; the page's head, title through the actions, is its top part: the
  ;; header. The tabs are not in it: they are the page's own switch
  (let* ((tabs? (lambda (x) (and (pair? x) (re-match? "\\bc-tabs\\b" (or (plist-get x 'class) "")))))
         (head (filter (lambda (x) (not (tabs? x))) blocks))
         (tabs (filter tabs? blocks))
         (real (filter (lambda (x) (and (pair? x) (plist-get x 'lines))) head))
         (name (let find ((bs real)) (cond ((null? bs) "Header") ((plist-get (car bs) 'anchor-name) (plist-get (car bs) 'anchor-name)) (else (find (cdr bs)))))))
    (if (null? real)
        blocks
        (cons (site-app-claim (component 'ui/group (list 'tag "c-header" 'body (site-app-unanchored head)))
                              (apply min (map (lambda (x) (car (plist-get x 'lines))) real))
                              (apply max (map (lambda (x) (cadr (plist-get x 'lines))) real))
                              name)
              tabs))))

(define (site-app-rows buf) (or (buffer-local buf 'site-app-rows) '()))

;; A site-app's buffers are one app, named for it: a page is its detail,
;; a section its list. app-layout! lays them out by that. Answers the name.
(define (site-app-claim! buf &optional name)
  (let ((nm (or name (buffer-local buf 'site-app-name)
                (let ((sp (buffer-local buf 'site-app-spec))) (and sp (plist-get sp 'name))))))
    (when (and nm (boundp 'app-claim!))
      (app-claim! buf (if (symbol? nm) (symbol->string nm) nm)
                  (if (buffer-local buf 'site-app-row) 'detail 'list)))
    nm))

;; buffers open before apps were claimed take their claim on load
(for-each (lambda (b) (when (buffer-exists? b) (site-app-claim! b))) (buffer-list))

(define (site-app-join-group! buf &optional name)
  ;; an app whose spec says 'own-group lives in a group of its own, named for
  ;; it; any other joins the group of the frame it opened in
  (let* ((nm (site-app-claim! buf name))
         (spec (and nm (site-app-spec nm))))
    (if (and spec (plist-get spec 'own-group))
        (app-join-group! buf (or (plist-get spec 'title) (symbol->string nm)))
        (let ((group (frame-group)))
          (when (and group (not (buffer-in-group? buf group)))
            (buffer-add-group! buf group)))))
  buf)

(effects! '(write external))

(define (site-app-html! name tab page k)
  ;; The site renders its pages whole before any script runs, so a plain fetch
  ;; through the extension (your cookies, no tab) reads them. The live tab is
  ;; kept for what only a live page can do: pressing its buttons. A 'live page
  ;; draws itself in the browser, so it is read from the live tab once its
  ;; 'wait selector shows. A page's 'path may be a thunk, for a path that moves
  (let* ((spec (site-app-spec name))
         (path (plist-get page 'path))
         (url (site-app-url spec (if (procedure? path) (path) path)))
         (query (buffer-local (site-app-page-buffer name (plist-get page 'id)) 'site-app-filter)))
    (if (plist-get page 'live)
        (site-app-navigate! name url (or (plist-get page 'wait) (plist-get spec 'ready))
          (lambda (tab answer) (k (and answer (plist-get answer 'html)))))
        (site-app-fetch-html! (if (and (string? query) (> (string-length query) 0))
                                  (string-append url "?" query)
                                  url)
                              k))))

(define (site-app-fill! name page html)
  (let* ((buf (site-app-page-buffer name (plist-get page 'id)))
         (rows (site-app-parse (plist-get page 'sheet) html))
         (sheet (or (plist-get page 'tabs-sheet) (plist-get (site-app-spec name) 'tabs-sheet)))
         (tabs (or (and sheet (site-app-parse sheet html)) '()))
         (on (and (pair? tabs) (site-app-find (lambda (t) (equal? (plist-get t 'active) "yes")) tabs))))
    (if (not (or (pair? rows) (null? rows)))
        (message (string-append (symbol->string name) ": stylesheet did not return rows"))
        (begin
          (buffer-set-local! buf 'site-app-page (plist-get page 'id))
          (buffer-set-local! buf 'site-app-rows rows)
          (buffer-set-local! buf 'site-app-filters (if (pair? tabs) tabs '()))
          ;; the page says which of its tabs it drew; that is the one we are on.
          ;; Grouped filters are facets, several on at once: the query we read stands
          (when (and on (not (plist-get on 'group))) (buffer-set-local! buf 'site-app-filter (plist-get on 'query)))
          (buffer-set-local! buf 'list-layout-cache #f)
          (list-refresh! buf)
          ;; a page's 'after-fill (BUF ROWS) hears every read, to keep it
          (let ((after (plist-get page 'after-fill))) (when after (after buf rows)))
          (message (string-append (number->string (length rows))
                                  " " (string-downcase (plist-get page 'label))
                                  (if on (string-append " · " (plist-get on 'label)) "")))))
    rows))

(define (site-app-read-page! name page)
  (message (string-append "Reading " (plist-get page 'label) "..."))
  (site-app-html! name #f page
    (lambda (html)
      (if html (site-app-fill! name page html)
          (message "The site did not answer")))))

(define *site-app-opening* '())
;; when each open began: an open whose reply never comes (a closed window, a
;; lost message) must not hold every read behind it for good
(define *site-app-opening-at* '())
(define (site-app-opening-live? name)
  (let ((t (assoc name *site-app-opening-at*)))
    (and t (< (- (monotonic-ms) (cadr t)) 20000))))

(define (site-app-find-tab! name k)
  ;; the reader tab lives in its own window, so it is looked for in every
  ;; window: a look in this frame's alone never found it, and opened another.
  ;; An app with 'adopt takes a tab already on its site before it opens one,
  ;; and callers that ask while a tab is opening wait for that same tab
  (let ((spec (site-app-spec name))
        (remembered (site-app-tab name))
        (waiting (and (site-app-opening-live? name) (assoc name *site-app-opening*))))
    (if waiting
        (set! *site-app-opening* (alist-put *site-app-opening* name (cons k (cadr waiting))))
        (chrome-call "tabs" '()
          (lambda (reply)
            (let* ((tabs (or (plist-get reply 'tabs) '()))
                   (live (and remembered
                             (site-app-find
                               (lambda (tab) (equal? (plist-get tab 'id) remembered))
                               tabs)))
                   (base (plist-get spec 'base-url))
                   (stray (and (not live) (plist-get spec 'adopt) (string? base)
                               (site-app-find
                                 (lambda (tab) (string-prefix? base (or (plist-get tab 'url) "")))
                                 tabs))))
              (cond
                (live (k remembered))
                (stray (k (site-app-note-tab! name (plist-get stray 'id))))
                (else
                 (set! *site-app-opening* (alist-put *site-app-opening* name (list k)))
                 (set! *site-app-opening-at* (alist-put *site-app-opening-at* name (monotonic-ms)))
                 (chrome-call "open"
                   (chrome-here
                     ;; the reader's minimized window: the app works the site out of sight
                     (list 'url (site-app-url spec (plist-get spec 'home))
                           'background #t
                           'reader #t))
                   (lambda (reply)
                     (let ((tab (plist-get reply 'tab))
                           (ks (cadr (assoc name *site-app-opening*))))
                       (set! *site-app-opening* (filter (lambda (e) (not (eq? (car e) name))) *site-app-opening*))
                       (site-app-note-tab! name tab)
                       (for-each (lambda (f) (f tab)) (reverse ks)))))))))))))

(define (site-app-select-page! index)
  (let* ((spec (buffer-local (current-buffer) 'site-app-spec))
         (pages (site-app-pages spec)))
    (when (< index (length pages))
      (site-app-open! (plist-get spec 'name) (plist-get (list-ref pages index) 'id)))))

(define (site-app-filter-step! delta)
  ;; walk the section's status tabs, then read the section at the new one
  (let* ((buf (current-buffer))
         (spec (buffer-local buf 'site-app-spec))
         (filters (or (buffer-local buf 'site-app-filters) '()))
         (n (length filters)))
    (if (= n 0)
        (message "This section has no status tabs")
        (let* ((query (buffer-local buf 'site-app-filter))
               (at (let loop ((rest filters) (i 0))
                     (cond ((null? rest) 0)
                           ((equal? (plist-get (car rest) 'query) query) i)
                           (else (loop (cdr rest) (+ i 1))))))
               (next (list-ref filters (modulo (+ at delta) n))))
          (site-app-set-filter! buf (plist-get next 'query))))))

(define (site-app-set-filter! buf query)
  ;; show one status tab of the section, then read the section at it
  (let ((spec (buffer-local buf 'site-app-spec)))
    (buffer-set-local! buf 'site-app-filter query)
    (list-refresh! buf)
    (site-app-read-page! (plist-get spec 'name) (site-app-current-page buf))))

(define-command "site-app-filter-next" "Show the next status tab of this section"
  (lambda () (site-app-filter-step! 1)))

(define (site-app-filter-label tab)
  (let ((count (plist-get tab 'count)))
    (if (or (not count) (equal? count "")) (plist-get tab 'label)
        (string-append (plist-get tab 'label) " " count))))

(define-command "site-app-filter-choose" "Ask for a status tab of this section and show it"
  (lambda ()
    (let* ((buf (current-buffer))
           (filters (or (buffer-local buf 'site-app-filters) '())))
      (if (null? filters)
          (run-command "list-filter")
          (completing-read "State: " (map site-app-filter-label filters)
            (lambda (choice)
              (let loop ((rest filters))
                (cond ((null? rest) (message (string-append "No state " choice)))
                      ((equal? (site-app-filter-label (car rest)) choice)
                       (site-app-set-filter! buf (plist-get (car rest) 'query)))
                      (else (loop (cdr rest))))))
            'require-match #t)))))
(define-command "site-app-filter-prev" "Show the previous status tab of this section"
  (lambda () (site-app-filter-step! -1)))

(for-each
  (lambda (n)
    (let ((i (number->string n)))
      (define-command (string-append "site-app-tab-" i) (string-append "Open section " i " of this website app")
        (lambda () (site-app-select-page! (- n 1))))))
  '(1 2 3 4 5 6 7 8 9))
;; ---------------------------------------------------------------- tabs by key
;; Every page of an app is read-only, so its tabs take plain keys: s opens a menu
;; of the app's sections, t a menu of this buffer's own tabs (a page's tabs on a
;; page, the status tabs on a list). In the menu each tab has a letter from its
;; label, so a tab is two keys away: t then the tab's letter.

(define (site-app-tab-letters labels)
  ;; each label its first word's initial, else another word's, else any of its
  ;; letters, else a digit; q is left to quit the menu
  (let loop ((ls labels) (taken (list "q")) (acc '()))
    (if (null? ls) (reverse acc)
        (let* ((label (string-downcase (car ls)))
               (letters (lambda (s) (filter (lambda (c) (re-match? "^[a-z0-9]$" c))
                                            (map (lambda (i) (substring s i (+ i 1))) (iota (string-length s))))))
               (initials (apply append (map (lambda (w) (let ((ls (letters w))) (if (pair? ls) (list (car ls)) '())))
                                            (string-split label " "))))
               (choices (append initials (letters label) (map number->string '(1 2 3 4 5 6 7 8 9))))
               (key (site-app-find (lambda (c) (not (member c taken))) choices)))
          (loop (cdr ls) (cons key taken) (cons key acc))))))

(define (site-app-tab-suffixes labels actives actions)
  (let loop ((ks (site-app-tab-letters labels)) (ls labels) (as actives) (fs actions) (acc '()))
    (if (null? ls) (reverse acc)
        (loop (cdr ks) (cdr ls) (cdr as) (cdr fs)
              (cons (transient-suffix (car ks) (if (car as) (string-append (car ls) "  ●") (car ls)) (car fs))
                    acc)))))

(define (site-app-tab-groups buf)
  (if (buffer-local buf 'site-app-row)
      ;; a page: its tabs
      (let ((tabs (site-app-detail-tabs buf))
            (active (site-app-detail-active buf)))
        (list (cons "Tabs of this page"
                    (site-app-tab-suffixes
                      (map (lambda (t) (plist-get t 'label)) tabs)
                      (map (lambda (t) (equal? (plist-get t 'id) active)) tabs)
                      (map (lambda (t) (lambda () (site-app-detail-select! buf (plist-get t 'id)))) tabs)))))
      ;; a list: the status tabs its page draws, a menu group for each facet; the
      ;; letters run across the whole menu, so every tab keeps its own
      (let* ((filters (or (buffer-local buf 'site-app-filters) '()))
             (on (buffer-local buf 'site-app-filter))
             (suffixes (site-app-tab-suffixes
                         (map (lambda (f) (plist-get f 'label)) filters)
                         (map (lambda (f) (or (equal? (plist-get f 'active) "yes") (equal? (plist-get f 'query) on))) filters)
                         (map (lambda (f) (lambda () (site-app-set-filter! buf (plist-get f 'query)))) filters)))
             ;; a facet goes by the parameter it sets (q_rating=elite is Rating), a tab is Status
             (group-of (lambda (f)
                         (let* ((q (or (plist-get f 'query) ""))
                                (params (cdr (string-split q "&q_")))
                                (param (and (pair? params) (car (string-split (car (reverse params)) "=")))))
                           (cond ((not (equal? (plist-get f 'group) "facet")) "Status")
                                 (param (site-app-capitalize (re-replace "_" (re-replace "^to_" param "") " ")))
                                 (else "Filters")))))
             (names (let loop ((fs filters) (acc '()))
                      (cond ((null? fs) (reverse acc))
                            ((member (group-of (car fs)) acc) (loop (cdr fs) acc))
                            (else (loop (cdr fs) (cons (group-of (car fs)) acc)))))))
        (map (lambda (name)
               (cons name (let pick ((fs filters) (ss suffixes) (acc '()))
                            (cond ((null? fs) (reverse acc))
                                  ((equal? (group-of (car fs)) name) (pick (cdr fs) (cdr ss) (cons (car ss) acc)))
                                  (else (pick (cdr fs) (cdr ss) acc))))))
             names))))

(define (site-app-section-groups buf)
  ;; the sections open in the list's own window, wherever the menu was asked from
  (let* ((list-buf (or (buffer-local buf 'site-app-list) buf))
         (spec (buffer-local list-buf 'site-app-spec))
         (name (plist-get spec 'name))
         (pages (site-app-pages (site-app-spec name)))
         (here (buffer-local list-buf 'site-app-page)))
    (list (cons "Sections"
                (site-app-tab-suffixes
                  (map (lambda (p) (plist-get p 'label)) pages)
                  (map (lambda (p) (equal? (plist-get p 'id) here)) pages)
                  (map (lambda (p)
                         (lambda ()
                           (let ((w (site-app-find (lambda (x) (equal? (cadr x) list-buf)) (window-list))))
                             (when w (select-window! (car w)))
                             (site-app-open! name (plist-get p 'id)))))
                       pages))))))

(transient-define-prefix "site-app-tabs" "Pick one of this buffer's tabs" site-app-tab-groups)
(transient-define-prefix "site-app-sections" "Pick a section of this website app" site-app-section-groups)

(define-command "site-app-refresh" "Read this website app tab again"
  (lambda ()
    (let* ((buf (current-buffer))
           (spec (buffer-local buf 'site-app-spec)))
      (site-app-read-page! (plist-get spec 'name) (site-app-current-page buf)))))

(define (site-app-imenu-rows buf)
  ;; imenu's index of a section: one entry per row, filed under the row's kind,
  ;; so a list of tracks and albums gives a tab of each
  (with-current-buffer buf
    (lambda ()
      (let loop ((es (list-entries buf)) (os (list-offsets buf)) (out '()))
        (if (or (null? es) (null? os))
            (reverse out)
            (let ((name (or (site-app-field (car es) 'name) ""))
                  (kind (or (site-app-field (car es) 'kind) "")))
              (loop (cdr es) (cdr os)
                    (if (equal? name "") out
                        (cons (list (line-number-at-pos (car os)) (if (equal? kind "") "item" kind) name
                                    (or (site-app-field (car es) 'sub) ""))
                              out)))))))))

(define (site-app-open! name &optional id)
  ;; each section is its own buffer; one already read is shown as it stands, g rereads it
  (let* ((spec (site-app-spec name))
         (page (site-app-page spec (or id (plist-get spec 'home-page))))
         (pid (plist-get page 'id))
         (buf (site-app-page-buffer name pid))
         (mode (site-app-page-mode name pid)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (site-app-join-group! buf name)
    (buffer-set-local! buf 'site-app-spec spec)
    (buffer-set-local! buf 'site-app-page pid)
    (buffer-set-local! buf 'imenu-index-function 'site-app-imenu-rows)
    (unless (buffer-derived-mode? buf mode)
      (with-current-buffer buf (lambda () (set-mode! mode))))
    ;; an app with a group of its own is opened there
    (when (plist-get spec 'own-group) (frame-tab! (app-group (or (plist-get spec 'title) (symbol->string name)))))
    (switch-to-buffer! buf)
    (when (null? (site-app-rows buf))
      (site-app-find-tab! name (lambda (tab) (site-app-read-page! name page))))
    buf))


(define (site-app-detail-buffer name row)
  ;; an app with 'detail-buffer (ROW) keeps every page in the buffer that names: one
  ;; buffer for whatever is looked at, its pages kept aside (site-app-cache-put!)
  (let* ((spec (site-app-spec name))
         (own (and spec (plist-get spec 'detail-buffer)))
         (namer (and spec (plist-get spec 'detail-name)))
         (title (or (and own (own row)) (and namer (namer row)) (site-app-field row 'key))))
    (string-append "*" (symbol->string name) ": " title "*")))

;;; --- caches: what an app has read, kept by key ------------------------------
;;; An app keeps what it read in named stores, each an alist of (KEY VALUE),
;;; newest first. (site-app-cache-store! APP STORE OPTS) says how a store keeps:
;;; 'max bounds it, the oldest let go; 'persist saves it to APP-cache.json in
;;; compos-home, read back by (site-app-cache-load! APP); 'keep? picks the
;;; entries worth saving. Site-app keeps one store of its own, 'pages: what a
;;; row's page last read, for a one-buffer app coming back to the row.

(define *site-app-caches* '())       ; ((APP STORE) ENTRIES)
(define *site-app-cache-opts* '())   ; ((APP STORE) OPTS)
(define site-app-page-cache-size 60)

(define (site-app-cache-store! app store opts)
  (set! *site-app-cache-opts* (alist-put *site-app-cache-opts* (list app store) opts)))

(define (site-app--cache-opts app store)
  (let ((e (assoc (list app store) *site-app-cache-opts*)))
    (cond (e (cadr e))
          ((eq? store 'pages) (list 'max site-app-page-cache-size))
          (else '()))))

(define (site-app-cache-entries app store)
  (let ((e (assoc (list app store) *site-app-caches*))) (if e (cadr e) '())))

(define (site-app-cache-has? app store key)
  (and (assoc key (site-app-cache-entries app store)) #t))

(define (site-app-cache-get app store key)
  ;; the value kept under KEY, else #f
  (let ((e (assoc key (site-app-cache-entries app store)))) (and e (cadr e))))

(define (site-app--cache-set! app store entries)
  (set! *site-app-caches* (alist-put *site-app-caches* (list app store) entries))
  (when (plist-get (site-app--cache-opts app store) 'persist) (site-app-cache-touch! app)))

(define (site-app-cache-put! app store key value)
  ;; VALUE under KEY, newest; answers VALUE
  (let* ((max (plist-get (site-app--cache-opts app store) 'max))
         (all (alist-put (site-app-cache-entries app store) key value)))
    (site-app--cache-set! app store (if (and max (> (length all) max)) (list-head all max) all))
    value))

(define (site-app-cache-drop! app store key)
  (site-app--cache-set! app store (filter (lambda (e) (not (equal? (car e) key))) (site-app-cache-entries app store))))

(define (site-app-cache-file app)
  (string-append (compos-home) "/" (symbol->string app) "-cache.json"))

(define *site-app-cache-loaded* '())   ; the apps whose file has been read

(define (site-app-cache-save! app)
  ;; every store of APP that persists, as one JSON object by store. A save
  ;; before the load reads the file first, so it never writes over a session's worth
  (unless (memq app *site-app-cache-loaded*) (site-app-cache-load! app))
  (let loop ((os *site-app-cache-opts*) (out '()))
    (cond ((null? os) (write-file! (site-app-cache-file app) (json-encode out)))
          ((and (eq? (car (car (car os))) app) (plist-get (cadr (car os)) 'persist))
           (let* ((store (cadr (car (car os))))
                  (keep? (plist-get (cadr (car os)) 'keep?))
                  (es (site-app-cache-entries app store)))
             (loop (cdr os) (append out (list store (if keep? (filter keep? es) es))))))
          (else (loop (cdr os) out)))))

(define (site-app-cache-touch! app)
  ;; many puts at once save once
  (debounce! (string->symbol (string-append "site-app-cache-" (symbol->string app))) 2000 site-app-cache-save! app))

(define (site-app--cache-merge mine theirs)
  ;; MINE, then each entry of THEIRS under a key MINE lacks, once
  (let loop ((ts theirs) (seen (map car mine)) (acc (reverse mine)))
    (cond ((null? ts) (reverse acc))
          ((or (not (pair? (car ts))) (member (car (car ts)) seen)) (loop (cdr ts) seen acc))
          (else (loop (cdr ts) (cons (car (car ts)) seen) (cons (car ts) acc))))))

(define (site-app-cache-load! app)
  ;; what earlier sessions saved. A reload loads again: what is here already
  ;; wins, and nothing doubles
  (let* ((file (site-app-cache-file app))
         (text (and (file-exists? file) (read-file file)))
         (data (and (string? text) (> (string-length text) 2) (json-parse text))))
    (unless (memq app *site-app-cache-loaded*) (set! *site-app-cache-loaded* (cons app *site-app-cache-loaded*)))
    (when (pair? data)
      (let loop ((d data))
        (when (and (pair? d) (pair? (cdr d)))
          (when (and (symbol? (car d)) (pair? (cadr d)))
            (set! *site-app-caches*
              (alist-put *site-app-caches* (list app (car d))
                         (site-app--cache-merge (site-app-cache-entries app (car d)) (cadr d)))))
          (loop (cddr d)))))))


(define-mode "site-app-detail-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      ;; a page is drawn from components; the blocks are rebuilt, never saved
      (buffer-set-local! buf 'desktop-skip-locals '(render-blocks))
      (buffer-set-local! buf 'render-mode "blocks"))))

(define (site-app-real xs) (filter pair? (or xs '())))

;; One node of a page section. c-item is a card: a blank line, its first line
;; strong, the rest indented under it.


;; Ornament the site draws for looks, dropped: the spec's 'ornament is a regex
;; for such text, read from the spec of the page being drawn.
(define (site-app-ornament? text)
  (let* ((spec (and *site-app-folding* (site-app-spec (buffer-local *site-app-folding* 'site-app-name))))
         (re (and spec (plist-get spec 'ornament))))
    (and re (re-match? re text) #t)))

(define (site-app-short-field? node)
  (and (equal? (plist-get node 'tag) "c-field")
       (not (plist-get node 'href))
       (<= (string-length (or (plist-get node 'text) "")) 48)))

(define (site-app-chip? node)
  (and (equal? (plist-get node 'tag) "c-list-item")
       (<= (string-length (or (plist-get node 'text) "")) 28)))

(define (site-app-take-while pred xs)
  (let loop ((xs xs) (acc '()))
    (if (and (pair? xs) (pred (car xs))) (loop (cdr xs) (cons (car xs) acc)) (reverse acc))))

(define (site-app-quote-lines text)
  (let* ((lines (map string-trim (string-split text "\n")))
         (lines (let drop ((ls lines)) (if (and (pair? ls) (equal? (car ls) "")) (drop (cdr ls)) ls)))
         (lines (reverse (let drop ((ls (reverse lines))) (if (and (pair? ls) (equal? (car ls) "")) (drop (cdr ls)) ls)))))
    lines))

(define (site-app-unlabel text)
  ;; "Strengths :" is a heading; the colon was the site's way of saying so
  (if (re-match? "\\s*:\\s*$" text)
      (string-trim (car (string-split text ":")))
      text))





;; What the header shows, from the page's data. The spec's 'detail-head maps
;; the data its sheets make to (title S title-href S state S head NODES): head is
;; the item's own records, an optional rating, its name, then its facts. Without
;; one the sheet names them itself: title, title_href, state and head.
(define (site-app-head spec data)
  (let ((hook (and spec (plist-get spec 'detail-head))))
    (if hook
        (hook data)
        (list 'title (plist-get data 'title) 'title-href (plist-get data 'title_href)
              'state (plist-get data 'state) 'head (plist-get data 'head)))))

;; the head's rating: its first record, when the spec's 'rating regex matches it
(define (site-app-rating spec text)
  (let ((re (and spec (plist-get spec 'rating))))
    (and re text (re-match? re (string-trim text)) #t)))

;; The site prints each button's key on the button ("Approve a"). In the app
;; the keys live in the keys bar, so a button says only what it does.
(define (site-app-without-key text)
  (let ((words (string-split (string-trim text) " ")))
    (if (and (> (length words) 1) (= (string-length (list-ref words (- (length words) 1))) 1))
        (string-join (reverse (cdr (reverse words))) " ")
        (string-trim text))))

(define (site-app-detail-keys buf)
  (let ((n (length (site-app-detail-tabs buf))))
    (append (site-app-card-key-labels buf)
            (site-app-detail-action-keys buf)
            (map (lambda (k) (list (car k) (caddr k))) (site-app-detail-extra-keys buf))
            (if (> n 0) (list (list "t" "tabs")) '())
            (if (site-app-detail-stages buf) (list (list "[ ]" "stages") (list "/" "stage")) '())
            (list (list "s" "sections")
                  (list "M-↑↓" "parts")
                  (list "M-g a" "part by name")
                  (list "f" "fold card")
                  (list "RET" "open link")
                  (list "g" "reload")
                  (list "o" "on the site")
                  (list "q" "quit")))))

;; the page a detail shows, by its minor mode
(define (site-app-detail-page buf)
  (let ((spec (site-app-spec (buffer-local buf 'site-app-name)))
        (kind (buffer-local buf 'site-app-detail-kind)))
    (and spec kind (site-app-find (lambda (p) (equal? (plist-get p 'detail-kind) kind)) (site-app-pages spec)))))

;; keys a page adds of the app's own, beside its buttons: 'detail-extra-keys ((KEY COMMAND LABEL) ...)
(define (site-app-detail-extra-keys buf)
  (let ((page (site-app-detail-page buf)))
    (or (and page (plist-get page 'detail-extra-keys)) '())))


(define site-app-tab-click "site-app-tab:")


(mode-parent! "site-app-detail-mode" "special-mode")

;; A chat made for a detail page is about the thing it shows: its title, where it
;; lives on the site, its row's fields and the parts to read. Facts, never the
;; drawn screen.
(require 'chat-mode)

(define (site-app-chat-facts src)
  (let* ((spec (site-app-spec (buffer-local src 'site-app-name)))
         (data (or (buffer-local src 'site-app-data) '()))
         (row (or (buffer-local src 'site-app-row) '()))
         (href (plist-get row 'href))
         (fields (let loop ((r row) (acc '()))
                   (if (or (null? r) (null? (cdr r))) (reverse acc)
                       (loop (cddr r)
                             (if (and (string? (cadr r)) (not (equal? (cadr r) "")) (not (memq (car r) '(href key))))
                                 (cons (string-append "- " (symbol->string (car r)) ": " (cadr r)) acc)
                                 acc))))))
    (string-join
      (append (list (string-append "The page is " (or (plist-get data 'title) src) "."))
              (if (and spec href) (list (string-append "On the site: " (plist-get spec 'base-url) href)) '())
              fields
              (list (string-append "Its parts, by (buffer-section \"" src "\" NAME): "
                                   (string-join (map car (or (buffer-local src 'site-app-sections) '())) ", "))))
      "\n")))

(mode-chat-setup! "site-app-detail-mode"
  (lambda (chat src) (prompt-part-set! chat "site-app-facts" (site-app-chat-facts src))))




(define (site-app-capitalize s)
  (if (or (not s) (equal? s "")) ""
      (string-append (string-upcase (substring s 0 1)) (substring s 1 (string-length s)))))

(define *site-app-gens* '())
(define (site-app-gen name) (let ((hit (assoc name *site-app-gens*))) (and hit (cadr hit))))
(define (site-app-next-gen! name)
  (let ((gen (+ 1 (or (site-app-gen name) 0))))
    (set! *site-app-gens* (alist-put *site-app-gens* name gen))
    gen))


;; a page's composed tabs ('detail-composed): each drawn from the sections of its
;; other tabs ('from), by its 'build, and read from no URL. They come first, on 0
(define (site-app-composed-tabs buf)
  (let ((page (or (buffer-local buf 'site-app-for-page) (site-app-detail-page buf))))
    (or (and page (plist-get page 'detail-composed)) '())))

(define (site-app-composed-tab buf id)
  (site-app-find (lambda (t) (equal? (plist-get t 'id) id)) (site-app-composed-tabs buf)))

(define *site-app-composing* #f)

(define (site-app-composed-lead buf)
  ;; how many composed tabs come before 1: all of them, on 0 and below, unless
  ;; the page numbers every tab from 1 ('detail-count-from-one)
  (let ((page (or (buffer-local buf 'site-app-for-page) (site-app-detail-page buf))))
    (if (and page (plist-get page 'detail-count-from-one)) 0 (length (site-app-composed-tabs buf)))))

(define (site-app-composed-draw buf id)
  (let ((t (site-app-composed-tab buf id)))
    (and t (plist-get t 'draw))))

(define (site-app-detail-tabs buf)
  (let ((data (buffer-local buf 'site-app-data))
        (lead? (> (site-app-composed-lead buf) 0)))
    (if data
        (append (map (lambda (t) (list 'id (plist-get t 'id) 'label (plist-get t 'label) 'composed lead?))
                     (site-app-composed-tabs buf))
                (site-app-real (plist-get data 'tabs)))
        '())))

(define (site-app-detail-active buf)
  (or (buffer-local buf 'site-app-active)
      (let ((hit (site-app-find (lambda (t) (plist-get t 'active)) (site-app-detail-tabs buf))))
        (and hit (plist-get hit 'id)))))

(define (site-app-detail-section buf id)
  (let ((composed (site-app-composed-tab buf id)))
    (if composed
        ;; loading until every tab it draws from has answered; a failed one adds nothing
        ;; *site-app-composing* names the page being built, for a build that needs its row
        (and (not (member #f (map (lambda (src) (site-app-detail-section buf src)) (plist-get composed 'from))))
             (begin (set! *site-app-composing* buf) #t)
             ((or (plist-get composed 'build) (lambda (section) '()))
              (lambda (src) (let ((s (site-app-detail-section buf src))) (if (equal? s 'failed) '() s)))))
        (let ((hit (assoc id (or (buffer-local buf 'site-app-sections) '()))))
          (and hit (cdr hit))))))

(define (site-app-detail-put-section! buf id nodes &optional quiet)
  (when (buffer-known? buf)
    (buffer-set-local! buf 'site-app-sections
      (cons (cons id (if (equal? nodes 'failed) 'failed (or nodes '())))
            (filter (lambda (e) (not (equal? (car e) id)))
                    (or (buffer-local buf 'site-app-sections) '()))))
    (unless quiet (site-app-draw! buf))
    (site-app-stage-skip-empty! buf id)))

;; a tab that opens on an empty stage while others hold rows (a job's board on
;; "new [0]" with "recommended [22]") takes the first stage that has rows, once
(define (site-app-stage-skip-empty! buf id)
  (when (and (equal? id (site-app-detail-active buf))
             (not (member id (or (buffer-local buf 'site-app-stage-skipped) '()))))
    (let* ((st (site-app-detail-stages buf))
           (items (if st (site-app-real (plist-get st 'items)) '()))
           (count (lambda (s) (or (string->number (or (plist-get s 'count) "")) 0)))
           (on (site-app-find (lambda (s) (plist-get s 'active)) items))
           (full (site-app-find (lambda (s) (> (count s) 0)) items)))
      (when (and on full (= (count on) 0))
        (buffer-set-local! buf 'site-app-stage-skipped
          (cons id (or (buffer-local buf 'site-app-stage-skipped) '())))
        (site-app-stage-select! buf (plist-get full 'status))))))


;; A tab that restates the header (the item's rating and name) says it once.
(define (site-app-drop-repeats section spec data)
  (let* ((head (site-app-real (plist-get (site-app-head spec data) 'head)))
         (said (map (lambda (n) (plist-get n 'text))
                    (if (and (pair? head) (site-app-rating spec (plist-get (car head) 'text)))
                        (if (pair? (cdr head)) (list (car head) (cadr head)) head)
                        (if (pair? head) (list (car head)) '())))))
    (filter (lambda (n) (or (not (pair? n))
                            (plist-get n 'children)
                            ;; a record with no text of its own (a strip of stages) says nothing twice
                            (not (plist-get n 'text))
                            (and (not (member (plist-get n 'text) said))
                                 ;; a rating alone on its line: the header already shows it
                                 (not (site-app-rating spec (plist-get n 'text))))))
            section)))


;;; --- the page as components ------------------------------------------------
;;; The mode turns the stylesheet's records into ui/* components. Under them
;;; the buffer holds the page as plain text, one line per block, and each block
;;; claims its lines: point moves by line, the block at point is current, and
;;; the view follows it. Search and copy read the text.

(define site-app-link-click "site-app-link:")
(define site-app-act-click "site-app-act:")
(define site-app-stage-click "site-app-stage:")

(define (site-app-action-bar buf)
  ;; (LABEL KEY KIND IN-APP?): every button the page has, each with its key
  ;; a button's kind is the tone the spec's 'tones give a word of its label
  (let* ((spec (site-app-spec (buffer-local buf 'site-app-name)))
         (tones (and spec (plist-get spec 'tones))))
    (map (lambda (k)
           (let ((tone (site-app-find (lambda (x) x)
                                      (map (lambda (w) (site-app-tone-class tones w))
                                           (string-split (cadr k) " ")))))
             (list (cadr k) (car k)
                   (if (member tone (list "good" "bad")) tone "plain")
                   (caddr k))))
         (site-app-keyed-actions buf))))

(define (site-app-unanchored blocks)
  (map (lambda (blk)
         (if (pair? blk)
             (let strip ((pl blk) (acc '()))
               (cond ((null? pl) (let ((out (reverse acc)))
                                   (if (plist-get out 'children)
                                       (plist-put out 'children (site-app-unanchored (plist-get out 'children)))
                                       out)))
                     ((eq? (car pl) 'anchor-name) (strip (cddr pl) acc))
                     (else (strip (cddr pl) (cons (cadr pl) (cons (car pl) acc))))))
             blk))
       blocks))

(define (site-app-set-anchors! buf text blocks)
  (anchor-set-blocks! buf text blocks)
  (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode")))

;; a word's tone as a class: the spec's 'tones ((REGEX KIND) ...)
(define (site-app-tone-class tones word)
  ;; a component tone: good, warn, bad or info
  (let loop ((ts (or tones '())))
    (cond ((null? ts) #f)
          ((re-match? (car (car ts)) word) (symbol->string (cadr (car ts))))
          (else (loop (cdr ts))))))

(define (site-app-toned-segs text base tones)
  ;; the words a tone names stand out; every run of plain words between them is
  ;; one seg, so a paragraph draws as one text node and not a span a word
  (let loop ((words (string-split text " ")) (acc '()) (first #t))
    (if (null? words)
        (reverse acc)
        (let* ((stars (and (re-match? "^★+✓?$" (car words)) (site-app-stars (car words))))
               (tone (and (not stars) (site-app-tone-class tones (car words))))
               ;; a rating is a word too: it draws as the one star component
               (class (cond (stars (car (car (site-app-stars-segs (car words))))) (tone (string-append "c-" tone)) (else base)))
               (shown (if stars (site-app-stars-string (car words)) (car words)))
               (word (if first shown (string-append " " shown))))
          (loop (cdr words)
                (cond ((and (pair? acc) (equal? (car (car acc)) class) (equal? class base))
                       (cons (list class (string-append (cadr (car acc)) word)) (cdr acc)))
                      ((and (not first) (not (equal? class base)))
                       ;; the space before a toned word stays plain
                       (cons (list class shown)
                             (if (and (pair? acc) (equal? (car (car acc)) base))
                                 (cons (list base (string-append (cadr (car acc)) " ")) (cdr acc))
                                 (cons (list base " ") acc))))
                      (else (cons (list class word) acc)))
                #f)))))

(define (site-app-one-line text) (string-join (string-split (or text "") "\n") " "))

;; the text under the blocks: 'line adds one and answers its number
(define (site-app-builder)
  (let ((lines '()) (n 0) (links '()))
    (lambda (op text href)
      (cond ((equal? op 'line)
             (set! lines (cons (site-app-one-line text) lines))
             (set! n (+ n 1))
             (when href (set! links (cons (list n href) links)))
             n)
            ((equal? op 'text) (string-join (reverse lines) "\n"))
            ((equal? op 'links) links)
            (else n)))))

(define (site-app-claim block first last &optional name)
  ;; the anchor is what makes the renderer mark the block data-current, and
  ;; the view scrolls to follow that mark. NAME makes the block a stop of
  ;; anchor-mode too, so M-<up> and M-<down> walk the page by its parts
  ;; the anchor is the block's id in the view too, so it must be unique: a
  ;; part starts on its heading's line, and a shared id makes the view patch
  ;; the wrong node. Its span and its kind tell the two apart.
  (append block (list 'lines (list first last) 'mark "current"
                      'anchor (string-append "sa-" (number->string first) "-" (number->string last)
                                             "-" (car (string-split (string-trim (or (plist-get block 'class) "b")) " "))))
          (if name (list 'anchor-name name) '())))

(define (site-app-click-props href)
  (if href (list 'click (string-append site-app-link-click href)) '()))

(define (site-app-part b kind text props href)
  ;; one line of the page's text, drawn as the component KIND
  (let ((n (b 'line text href)))
    (site-app-claim (component kind (append props (site-app-click-props href))) n n)))

(define (site-app-segs-line text tones href &optional link)
  ;; the linked words read as a link, the rest as text with its words' tones;
  ;; a link the sheet did not place reads as one whole
  (let ((at (and href link (not (equal? link "")) (string-index text link))))
    (cond ((not href) (site-app-toned-segs text "" tones))
          ((not at) (list (list "c-info" text)))
          (else
           (let* ((end (+ at (string-byte-length link)))
                  (before (substring-bytes text 0 at))
                  (after (substring-bytes text end (string-byte-length text))))
             (append (if (equal? before "") '() (site-app-toned-segs before "" tones))
                     (list (list "c-info" link))
                     (if (equal? after "") '() (site-app-toned-segs after "" tones))))))))

(define (site-app-meta-segs texts tones)
  ;; facts for ui/meta: each with its words' tones, a dot between
  (let join ((ts texts) (acc '()) (first #t))
    (if (null? ts) acc
        (join (cdr ts)
              (append acc (if first '() (list (list "c-sep" "  ·  ")))
                      (site-app-toned-segs (car ts) "" tones))
              #f))))

(define (site-app-kept nodes)
  (filter (lambda (n) (not (site-app-ornament? (or (plist-get n 'text) "")))) (site-app-real nodes)))

;; One section's records as components: a card per item, a section per heading,
;; one row per run of short facts, badges for tags, a bar for quoted text.
(define site-app-bullet-re "^[-*•]\\s+")
(define (site-app-bulleted? lines)
  ;; most of its lines open with a bullet
  (let ((full (filter (lambda (l) (not (equal? l ""))) lines)))
    (and (pair? full)
         (re-match? site-app-bullet-re (car full))
         (> (* 2 (length (filter (lambda (l) (re-match? site-app-bullet-re l)) full))) (length full)))))

;; A heading and what follows it, up to the next heading, are one part of the
;; page: one anchor, so anchor-mode lights the whole section and not its title
(define (site-app-lead-in? node next)
  ;; a line that names the run under it: Strengths:, or a short label over bullets
  (let ((tag (plist-get node 'tag)) (text (or (plist-get node 'text) "")))
    (and (not (plist-get node 'href))
         (or (and (equal? tag "c-paragraph") (re-match? ":\\s*$" text))
             (and (member tag (list "c-field" "c-paragraph"))
                  (< (string-length text) 40)
                  (not (re-match? "[.:]\\s*$" text))
                  next (equal? (plist-get next 'tag) "c-list-item"))))))

;; what starts a part, and its rank: a heading outranks a lead-in
(define (site-app-rank blk)
  (cond ((not (pair? blk)) #f)
        ((re-match? "\\bc-section\\b" (or (plist-get blk 'class) "")) 1)
        ((plist-get blk 'sa-lead) 2)
        (else #f)))

(define (site-app-all-parts? blocks)
  (let ((real (filter pair? blocks)))
    (and (pair? real) (null? (filter (lambda (x) (not (plist-get x 'anchor-name))) real)))))


(define (site-app-summary blocks &optional name least)
  ;; the loose blocks a run opens with, before its first part, are one part:
  ;; a tab's Summary (headline, where, tags, profile link), or the opening of
  ;; a card or section whose parts are its own (no part holds another)
  (let* ((head (site-app-take-while (lambda (x) (and (pair? x) (not (plist-get x 'anchor-name)) (plist-get x 'lines)
                                                    (null? (anchor-blocks (or (plist-get x 'children) '())))))
                                    blocks))
         (rest (list-tail blocks (length head))))
    (if (< (length head) (or least 2))
        blocks
        (cons (site-app-claim (component 'ui/group (list 'body head))
                              (car (plist-get (car head) 'lines))
                              (cadr (plist-get (car (reverse head)) 'lines))
                              (or name "Summary"))
              rest))))

(define (site-app-with-keys blocks keys fold &optional record)
  ;; the first part of BLOCKS carries KEYS: a card that is no part itself
  ;; is folded from the part it opens with
  (let loop ((bs blocks) (acc '()) (done #f))
    (cond ((null? bs) (reverse acc))
          ((and (not done) (pair? (car bs)) (plist-get (car bs) 'anchor-name))
           (loop (cdr bs) (cons (append (car bs) (list 'anchor-keymap keys 'anchor-data (list 'fold fold 'record record))) acc) #t))
          (else (loop (cdr bs) (cons (car bs) acc) done)))))

(define (site-app-sectioned blocks)
  ;; a heading or a lead-in and what follows it, up to the next one, is one
  ;; part, so the walk, imenu and the highlight take the whole section. Parts
  ;; sit side by side: a section that holds parts (Work Experience's jobs) is
  ;; no part itself, and its heading with any loose lines under it is one
  (let loop ((bs blocks) (acc '()))
    (cond ((null? bs) (reverse acc))
          ((site-app-rank (car bs))
           (let* ((head (car bs))
                  (name (plist-get head 'anchor-name))
                  (body (site-app-take-while (lambda (x) (not (site-app-rank x))) (cdr bs)))
                  (inner (cons (car (site-app-unanchored (list head))) body))
                  (flat? (null? (anchor-blocks body)))
                  (first (car (plist-get head 'lines)))
                  (last (let span ((xs body) (m first))
                          (if (null? xs) m
                              (let ((ls (and (pair? (car xs)) (plist-get (car xs) 'lines))))
                                (span (cdr xs) (if ls (max m (cadr ls)) m)))))))
             (loop (list-tail (cdr bs) (length body))
                   (cons (site-app-claim (component (or (plist-get head 'sa-kind) 'ui/group)
                                                    (list 'body (if flat? inner (site-app-summary inner name 2))))
                                         first last (and flat? name))
                         acc))))
          (else (loop (cdr bs) (cons (car bs) acc))))))

;; folds the reader set on this page's cards, by title: (TITLE OPEN?)
(define *site-app-folding* #f)
(define (site-app-open? title default)
  (let ((hit (and *site-app-folding* (assoc title (or (buffer-local *site-app-folding* 'site-app-folds) '())))))
    (if hit (cadr hit) default)))

;; A kind of card can read more of itself from the site when it opens: the
;; spec's 'card-details is ((CLASS FN) ...), FN taking the card's record to
;; ((LABEL PATH SHEET) ...). Each read lands under its label, on this page's
;; 'site-app-card-more as (TITLE LABEL NODES), NODES being 'loading, 'failed
;; or 'none until the page answers.
(define (site-app-card-details node)
  (let* ((buf *site-app-folding*)
         (spec (and buf (buffer-exists? buf) (site-app-spec (buffer-local buf 'site-app-name))))
         (hit (and spec (assoc (plist-get node 'class) (or (plist-get spec 'card-details) '())))))
    (if hit ((cadr hit) node) '())))

(define (site-app-card-put! buf title label value)
  (buffer-set-local! buf 'site-app-card-more
    (cons (list title label value)
          (filter (lambda (e) (not (and (equal? (car e) title) (equal? (cadr e) label))))
                  (or (buffer-local buf 'site-app-card-more) '())))))

(define (site-app-card-fetch! buf title detail)
  (site-app-card-put! buf title (car detail) 'loading)
  (site-app-fetch-html! (site-app-url (site-app-spec (buffer-local buf 'site-app-name)) (cadr detail))
    (lambda (html)
      (when (buffer-known? buf)
        (let* ((data (and html (site-app-parse (caddr detail) html)))
               (nodes (and data (site-app-real (plist-get data 'section)))))
          (site-app-card-put! buf title (car detail)
                              (cond ((not data) 'failed) ((null? nodes) 'none) (else nodes)))
          (site-app-draw! buf))))))

;; what an open card adds below its own lines: each read under its label,
;; asked for the first time the card is drawn open
(define (site-app-card-more node title)
  (let ((buf *site-app-folding*))
    (apply append
      (map (lambda (detail)
             (let* ((hit (site-app-find (lambda (e) (and (equal? (car e) title) (equal? (cadr e) (car detail))))
                                        (or (buffer-local buf 'site-app-card-more) '())))
                    (got (and hit (caddr hit))))
               (unless hit (site-app-card-fetch! buf title detail))
               (cons (list 'tag "c-heading" 'text (car detail))
                     (cond ((pair? got) got)
                           ((equal? got 'failed) (list (list 'tag "c-field" 'text "The site did not answer. g reads the page again.")))
                           ((equal? got 'none) (list (list 'tag "c-field" 'text "Nothing here.")))
                           (else (list (list 'tag "c-field" 'text "Loading…")))))))
           (site-app-card-details node)))))

;; A spec's 'detail-moves puts a section of a tab before another: the
;; evaluation above the work experience. A section is its heading and what
;; follows it up to the next heading. A move (TAB PROC) instead hands the
;; tab's nodes to PROC, which answers them in the order to draw.
(define (site-app-heading-at nodes title)
  (let loop ((ns nodes) (i 0))
    (cond ((null? ns) #f)
          ((and (pair? (car ns)) (equal? (plist-get (car ns) 'tag) "c-heading")
                (equal? (string-trim (or (plist-get (car ns) 'text) "")) title))
           i)
          (else (loop (cdr ns) (+ i 1))))))

(define (site-app-move-section nodes title before)
  (let ((i (site-app-heading-at nodes title)))
    (if (not i)
        nodes
        (let* ((after (list-tail nodes (+ i 1)))
               (len (let loop ((ns after) (n 1))
                      (if (or (null? ns) (and (pair? (car ns)) (equal? (plist-get (car ns) 'tag) "c-heading")))
                          n (loop (cdr ns) (+ n 1)))))
               (seg (list-head (list-tail nodes i) len))
               (rest (append (list-head nodes i) (list-tail nodes (+ i len))))
               (k (site-app-heading-at rest before)))
          (if (not k) nodes
              (append (list-head rest k) seg (list-tail rest k)))))))

(define (site-app-moved spec tab nodes)
  (let loop ((ms (or (and spec (plist-get spec 'detail-moves)) '())) (ns nodes))
    (cond ((null? ms) ns)
          ((equal? (car (car ms)) tab)
           (loop (cdr ms) (if (procedure? (cadr (car ms)))
                              ((cadr (car ms)) ns)
                              (site-app-move-section ns (cadr (car ms)) (caddr (car ms))))))
          (else (loop (cdr ms) ns)))))

;; a teaser the site keeps folded is dropped when what it folds is on the
;; page already (the Last note, over the Notes it repeats)
(define (site-app-texts nodes)
  (let walk ((ns nodes) (acc '()))
    (if (null? ns) acc
        (walk (cdr ns)
              (if (and (pair? (car ns)) (not (plist-get (car ns) 'folded)))
                  (walk (or (plist-get (car ns) 'children) '())
                        (if (plist-get (car ns) 'text) (cons (plist-get (car ns) 'text) acc) acc))
                  acc)))))

(define (site-app-drop-teasers nodes)
  (let ((seen (site-app-texts nodes)))
    (filter (lambda (n)
              (not (and (pair? n) (plist-get n 'folded)
                        (let ((kids (filter pair? (or (plist-get n 'children) '()))))
                          (and (pair? kids) (pair? (cdr kids))
                               (member (plist-get (cadr kids) 'text) seen))))))
            nodes)))

;; a card's head as the sheet dressed it: the logo (or a letter tile), a grade
;; badge in its tone, and tags
;; the component a record is drawn with: the one the sheet names when a package
;; registered it (ats/work-experience), else DEFAULT
(define (site-app-node-kind node default)
  (let* ((c (plist-get node 'component))
         (k (and (string? c) (not (equal? c "")) (string->symbol c))))
    (if (and k (component-entry k)) k default)))

(define (site-app-card-face node)
  (let ((has (lambda (k) (let ((v (plist-get node k))) (and v (not (equal? v "")) v)))))
    (append (if (has 'logo) (list 'icon (has 'logo)) (if (has 'letter) (list 'letter (has 'letter)) '()))
            (if (has 'tier) (list 'badge (has 'tier) 'badge-class (or (has 'tone) "")) '())
            (if (pair? (plist-get node 'tags)) (list 'tags (plist-get node 'tags)) '()))))

(define (site-app-node-blocks b nodes tones)
  (let loop ((rest (site-app-kept nodes)) (prev #f) (acc '()))
    (if (null? rest)
        (site-app-sectioned (reverse acc))
        (let* ((node (car rest))
               (tag (plist-get node 'tag))
               (text (or (plist-get node 'text) ""))
               (href (plist-get node 'href))
               (next (and (pair? (cdr rest)) (cadr rest))))
          (cond
            ((equal? tag "c-item")
             (let ((kids (site-app-kept (plist-get node 'children))))
               (cond ((null? kids) (loop (cdr rest) prev acc))
                     ((site-app-lead-in? (car kids) (and (pair? (cdr kids)) (cadr kids)))
                      ;; a box whose first line leads into a run is no card: its records, in their parts
                      (loop (cdr rest) 'item (append (reverse (site-app-node-blocks b kids tones)) acc)))
                     (else
                      ;; a card is always a part of the page, named by its title; f on it folds
                      ;; and unfolds it, and a teaser the site keeps folded starts folded
                      (let* ((title (site-app-unlabel (or (plist-get (car kids) 'text) "")))
                             ;; a card that reads more from the site starts folded, and reads it when it opens
                             (more? (pair? (site-app-card-details node)))
                             (open? (site-app-open? title (and (not more?) (not (plist-get node 'folded)))))
                             (first (b 'line title (plist-get (car kids) 'href)))
                             (body (if open? (site-app-node-blocks b (append (cdr kids) (site-app-card-more node title)) tones) '()))
                             ;; a card with parts of its own is no part: they are, and its fold key
                             ;; rides on the first of them
                             (flat? (null? (anchor-blocks body)))
                             (fold (list title open?))
                             (body (if flat? body
                                       (site-app-with-keys (site-app-summary body title 1) (site-app-card-map-for (plist-get node 'class)) fold node)))
                             (card (component (site-app-node-kind node 'ui/card)
                                              (append (list 'title title 'open? open? 'body body)
                                                            (site-app-card-face node)
                                                            ;; the card's own keys, and the record they act on
                                                            (if flat? (list 'anchor-keymap (site-app-card-map-for (plist-get node 'class))
                                                                            'anchor-data (list 'record node))
                                                                '()))))
                             (claimed (site-app-claim card first (max first (b 'count #f #f)) (and flat? title))))
                        (loop (cdr rest) 'item (cons claimed acc)))))))
            ((equal? tag "c-group")
             ;; a run the sheet set apart: the note staff read, or the letter the candidate would
             (let* ((letter? (equal? (plist-get node 'class) "sa-letter"))
                    (kids (site-app-kept (plist-get node 'children)))
                    (lead (if (pair? kids) (or (plist-get (car kids) 'text) "") ""))
                    (first (+ 1 (b 'count #f #f)))
                    ;; the note's first record is its label
                    (label (and (not letter?) (pair? kids) (begin (b 'line lead #f) lead)))
                    (body (site-app-node-blocks b (if label (cdr kids) kids) tones))
                    ;; the note reads as one stop; a letter keeps its sections as stops, its
                    ;; opening then one of them
                    (body (if letter? body (site-app-unanchored body)))
                    (flat? (null? (anchor-blocks body)))
                    (body (if flat? body (site-app-summary body (string-append "Email · " lead) 1))))
               (loop (cdr rest) 'group
                     (if (and (null? body) (not label)) acc
                         (cons (site-app-claim (component (site-app-node-kind node 'ui/callout)
                                                 (append (list 'tone (if letter? "paper" "note") 'body body)
                                                         (if label (list 'label label) '())))
                                               first (max first (b 'count #f #f))
                                               (and flat? (if letter? (string-append "Email · " lead) lead)))
                               acc)))))
            ((equal? tag "c-stages")
             ;; the stages a tab filters by, as tabs with the one showing marked and
             ;; a digit each. Under a heading they make one part with it, and that
             ;; part takes the tabs' keys: a digit takes that stage, the arrows step
             (let ((shown (site-app-stage-shown node)))
               (if (null? shown)
                   (loop (cdr rest) prev acc)
                   (let* ((keyed (let each ((ss shown) (i 1))
                                   (if (null? ss) '()
                                       (cons (list (string-append site-app-stage-click (plist-get (car ss) 'status))
                                                   (site-app-stage-label (car ss))
                                                   (and (plist-get (car ss) 'active) #t)
                                                   (number->string i))
                                             (each (cdr ss) (+ i 1))))))
                          (n (b 'line (string-join (map (lambda (t) (string-append (nth 3 t) " " (cadr t))) keyed) "   ") #f))
                          (tabs (component 'ui/tabs (list 'tabs keyed)))
                          (head (and (equal? prev 'heading) (pair? acc) (car acc)))
                          (name (or (and head (plist-get head 'anchor-name)) "Stages"))
                          (first (if head (car (plist-get head 'lines)) n))
                          (body (if head (list (car (site-app-unanchored (list head))) tabs) (list tabs))))
                     (loop (cdr rest) 'stages
                           (cons (append (site-app-claim (component 'ui/group (list 'body body)) first n name)
                                         (list 'anchor-keymap (plist-get tabs 'anchor-keymap)
                                               'anchor-data (plist-get tabs 'anchor-data)))
                                 (if head (cdr acc) acc)))))))
            ((equal? tag "c-heading")
             (let* ((count (and next (re-match? "^[0-9]+$" (or (plist-get next 'text) "")) (plist-get next 'text)))
                    (n (b 'line (if count (string-append text " " count) text) href))
                    (block (component 'ui/section (append (list 'title text)
                                                          (if count (list 'count (string->number count)) '())))))
               (loop (if count (cddr rest) (cdr rest)) 'heading
                     (cons (append (site-app-claim block n n text)
                                   ;; the component the section it heads is drawn as, when the sheet names one
                                   (list 'sa-kind (site-app-node-kind node 'ui/group)))
                           acc))))
            ((and (site-app-short-field? node) next (site-app-short-field? next))
             (let* ((run (site-app-take-while site-app-short-field? rest))
                    (texts (map (lambda (x) (let ((t (string-trim (plist-get x 'text))))
                                              (if (re-match? "^· " t) (substring t 2 (string-length t)) t)))
                                run)))
               (loop (list-tail rest (length run)) 'facts
                     (cons (site-app-part b 'ui/meta (string-join texts " · ")
                                          (list 'segs (site-app-meta-segs texts tones)) #f)
                           acc))))
            ((and (site-app-chip? node) next (site-app-chip? next))
             (let* ((run (site-app-take-while site-app-chip? rest))
                    (texts (map (lambda (x) (plist-get x 'text)) run)))
               (loop (list-tail rest (length run)) 'chips
                     (cons (site-app-part b 'ui/chips (string-join texts "  ") (list 'items texts) #f) acc))))
            ((or (equal? text prev) (equal? tag "c-action")) (loop (cdr rest) prev acc))
            ((and (equal? tag "c-quote") (site-app-bulleted? (site-app-quote-lines text)))
             ;; a pre-wrapped dash list, a CV's bullets, reads as bullets and not one slab
             (loop (cdr rest) 'quote
                   (let each ((ls (site-app-quote-lines text)) (acc acc))
                     (cond ((null? ls) acc)
                           ((equal? (car ls) "") (each (cdr ls) acc))
                           ((re-match? site-app-bullet-re (car ls))
                            (let ((t (re-replace site-app-bullet-re (car ls) "")))
                              (each (cdr ls) (cons (site-app-part b 'ui/bullet (string-append "• " t) (list 'text t) #f) acc))))
                           (else (each (cdr ls) (cons (site-app-part b 'ui/prose (car ls) (list 'text (car ls)) #f) acc)))))))
            ((equal? tag "c-quote")
             (let* ((lines (site-app-quote-lines text))
                    (first (+ 1 (b 'count #f #f))))
               (for-each (lambda (l) (b 'line l #f)) lines)
               (loop (cdr rest) 'quote
                     (cons (site-app-claim (component 'ui/quote (list 'text (string-join lines "\n")))
                                           first (max first (b 'count #f #f)))
                           acc))))
            ((equal? tag "c-table")
             ;; a table the site draws as a grid (Education): a header row, then one line a row
             (let* ((cols (map (lambda (c) (if (and (pair? (cdr c)) (equal? (cadr c) "right")) (list (car c) 'right) (list (car c))))
                               (or (plist-get node 'columns) '())))
                    (rows (or (plist-get node 'rows) '()))
                    (first (+ 1 (b 'count #f #f))))
               (when (pair? cols) (b 'line (string-join (map car cols) "  ") #f))
               (for-each (lambda (r) (b 'line (string-join r "  ") #f)) rows)
               (loop (cdr rest) 'table
                     (cons (site-app-claim (component 'ui/table (list 'columns cols 'rows rows))
                                           first (max first (b 'count #f #f)))
                           acc))))
            ((equal? tag "c-list-item")
             (loop (cdr rest) text
                   (cons (site-app-part b 'ui/bullet (string-append "• " text)
                                        (list 'segs (site-app-segs-line text tones href (plist-get node 'link))) href)
                         acc)))
            ((site-app-lead-in? node next)
             ;; a lead-in names the run under it (Strengths:, Skills match): it starts a part
             (let ((lead (site-app-unlabel text)))
               (loop (cdr rest) text (cons (append (site-app-part b 'ui/prose lead (list 'segs (list (list "c-strong" lead))) #f)
                                                   (list 'anchor-name lead 'sa-lead #t))
                                           acc))))
            ((and (equal? tag "c-paragraph") (not href) (re-match? "^[A-Z][A-Za-z /_-]{0,24}: " text))
             ;; Type: evidence-gap, the label set off from what it says
             (let ((at (string-index text ": ")))
               (loop (cdr rest) 'paragraph
                     (cons (site-app-part b 'ui/prose text
                                          (list 'segs (list (list "c-strong" (substring text 0 at))
                                                            (list "" (string-append "  " (substring text (+ at 2) (string-length text))))))
                                          #f)
                           acc))))
            (else
             (loop (cdr rest) (if (equal? tag "c-paragraph") 'paragraph text)
                   (cons (site-app-part b 'ui/prose text
                                        (list 'segs (if (equal? tag "c-link") (list (list "c-info" text))
                                                        (site-app-segs-line text tones href (plist-get node 'link))))
                                        href)
                         acc))))))))

;; The header, in the page's order: breadcrumbs, the title with where the item
;; stands, the candidate, their facts, and the tabs.
(define (site-app-head-blocks b spec data tabs active &optional actions)
  (let* ((tones (and spec (plist-get spec 'tones)))
         (h (site-app-head spec data))
         (title (or (plist-get h 'title) ""))
         (state (let ((s (plist-get h 'state))) (and s (not (equal? s "")) s)))
         (profile (site-app-kept (plist-get h 'head)))
         (stars (and (pair? profile) (site-app-rating spec (plist-get (car profile) 'text)) (car profile)))
         (rest (if stars (cdr profile) profile))
         (name (and (pair? rest) (car rest)))
         ;; prose and tags under the facts line: a headline, the specialisations
         (prose? (lambda (n) (member (plist-get n 'tag) (list "c-paragraph" "c-list-item"))))
         (extras (filter prose? (if name (cdr rest) rest)))
         (facts (filter (lambda (n) (and (not (equal? (plist-get n 'tag) "c-action"))
                                         (not (prose? n))
                                         (not (equal? (plist-get n 'text) title))))
                        (if name (cdr rest) rest))))
    ;; no breadcrumbs or position: the list beside the page is the navigation
    (append
      ;; a page with no title has no title row: its name is the heading
      (if (equal? title "")
          '()
      (let ((n (b 'line (if state (string-append title "  " state) title) (plist-get h 'title-href))))
        (list (site-app-claim
                (component 'ui/title (append (list 'text title)
                                             (if state (list 'badge state 'tone (or (site-app-tone-class tones state) "")) '())))
                n n title))))
      ;; the name large, its stars small after it, and the photo beside it when the sheet has one
      (if name
          (let* ((n (b 'line (string-append (plist-get name 'text) (if stars (string-append "  " (site-app-stars-string (plist-get stars 'text))) ""))
                       (plist-get name 'href)))
                 (heading (component 'ui/title
                            (append (list 'level 1
                                          'segs (append (list (list "" (plist-get name 'text)))
                                                        (if stars (cons (list "" "  ") (map (lambda (s) (list (string-append (car s) " sa-head-stars") (cadr s))) (site-app-stars-segs (plist-get stars 'text)))) '())))
                                    (site-app-click-props (plist-get name 'href)))))
                 (src (let ((a (plist-get name 'avatar))) (and a (not (equal? a "")) a)))
                 (face (if src
                           (list 'tag "div" 'class "sa-head-face"
                                 'children (list (list 'tag "img" 'class "sa-head-avatar"
                                                       'attrs (list (list "src" (if (string-prefix? "/" src)
                                                                                     (string-append (or (plist-get spec 'base-url) "") src)
                                                                                     src))
                                                                    (list "alt" "") (list "referrerpolicy" "no-referrer")))
                                                 heading))
                           heading)))
            (list (site-app-claim face n n)))
          '())
      (if (null? facts)
          '()
          (let ((texts (map (lambda (n) (plist-get n 'text)) facts)))
            (list (site-app-part b 'ui/meta (string-join texts " · ") (list 'segs (site-app-meta-segs texts tones)) #f))))
      (site-app-node-blocks b extras tones)
      (if (null? (or actions '()))
          '()
          ;; the site's buttons, each with its key when the app presses it; the rest are o's, on the site
          (let ((n (b 'line (string-join (map (lambda (a) (string-append (cadr a) " " (car a))) actions) "   ") #f)))
            (list (site-app-claim
                    (component 'ui/actions
                      (list 'actions (map (lambda (a)
                                            (list (string-append site-app-act-click (cadr a))
                                                  (if (list-ref a 3) (car a) (string-append (car a) " ↗"))
                                                  (cadr a)
                                                  ;; a key the app presses keeps its tone; one that opens the site is quiet
                                                  (cond ((not (list-ref a 3)) "dim")
                                                        ((member (caddr a) (list "good" "bad")) (caddr a))
                                                        (else ""))))
                                          actions)))
                    n n))))
      (if (null? tabs)
          '()
          (let ((n (b 'line (string-join (map (lambda (t) (site-app-capitalize (plist-get t 'label))) tabs) "   ") #f)))
            (list (site-app-claim
                    (component 'ui/tabs
                      ;; keys as site-app-detail-nth! takes them: the site's tabs from 1, composed ones before
                      (list 'tabs (let loop ((ts tabs)
                                             (i (- 1 (length (filter (lambda (t) (plist-get t 'composed)) tabs))))
                                             (acc '()))
                                    (if (null? ts) (reverse acc)
                                        (loop (cdr ts) (+ i 1)
                                              (cons (list (string-append site-app-tab-click (plist-get (car ts) 'id))
                                                          (site-app-capitalize (plist-get (car ts) 'label))
                                                          (equal? (plist-get (car ts) 'id) active)
                                                          (number->string i))
                                                    acc))))))
                    n n)))))))

;; Up and down go from one piece of the page to the next, not line by line:
;; the top of the page is one stop, then every card, fact row or paragraph of
;; the open tab; a section's heading is not a stop.
(define (site-app-stops blocks)
  ;; up and down go part by part, the same parts anchor-mode walks, at any
  ;; depth (each job of Work Experience), and through any loose block between
  ;; them; a group that only holds parts is no stop of its own
  (let* ((tabs (let find ((bs blocks))
                 (cond ((null? bs) #f)
                       ((not (pair? (car bs))) (find (cdr bs)))
                       ((re-match? "\\bc-tabs\\b" (or (plist-get (car bs) 'class) ""))
                        (car (plist-get (car bs) 'lines)))
                       (else (or (find (or (plist-get (car bs) 'children) '())) (find (cdr bs)))))))
         (past? (lambda (n) (or (not tabs) (> n tabs))))
         (loose (filter (lambda (b)
                          (and (pair? b) (plist-get b 'lines)
                               (past? (car (plist-get b 'lines)))
                               (not (re-match? "\\bc-section\\b" (or (plist-get b 'class) "")))
                               (or (plist-get b 'anchor-name)
                                   (null? (anchor-blocks (or (plist-get b 'children) '()))))))
                        blocks))
         (parts (filter past? (map cadr (anchor-blocks blocks))))
         (lines (append (list 1) (map (lambda (b) (car (plist-get b 'lines))) loose) parts)))
    (let dedupe ((ls (sort lines)) (acc '()))
      (cond ((null? ls) (reverse acc))
            ((and (pair? acc) (= (car acc) (car ls))) (dedupe (cdr ls) acc))
            (else (dedupe (cdr ls) (cons (car ls) acc)))))))

(define (site-app-detail-stop! dir)
  ;; the next stop past point, or a plain line when there is none that way
  (let* ((buf (current-buffer))
         (line (car (buffer-line-at-point buf)))
         (stops (or (buffer-local buf 'site-app-stops) '()))
         (next (if (> dir 0)
                   (let ((after (filter (lambda (n) (> n line)) stops)))
                     (and (pair? after) (car after)))
                   (let ((before (filter (lambda (n) (< n line)) stops)))
                     (and (pair? before) (car (reverse before)))))))
    (cond (next (buffer-goto-line! buf next))
          ((> dir 0) (next-line!))
          (else (previous-line!) (anchor--clamp-top! buf)))))

(define-command "site-app-detail-next" "Go to the next piece of this page"
  (lambda () (site-app-detail-stop! 1)))
(define-command "site-app-detail-prev" "Go to the previous piece of this page"
  (lambda () (site-app-detail-stop! -1)))

(define (site-app-draw! buf)
  (set! *site-app-folding* buf)
  (let* ((data (buffer-local buf 'site-app-data))
         (row (buffer-local buf 'site-app-row))
         (spec (site-app-spec (buffer-local buf 'site-app-name)))
         (tones (and spec (plist-get spec 'tones)))
         (b (site-app-builder))
         (blocks
           (if (not data)
               ;; until the page is read, the row's name as the spec's 'detail-name says it
               (let* ((namer (and spec (plist-get spec 'detail-name)))
                      (name (or (and namer (namer row)) (site-app-field row 'name) "")))
                 (list (site-app-part b 'ui/title name (list 'text name) #f)
                       (site-app-part b 'ui/empty "Loading…" (list 'text "Loading…") #f)))
               (let* ((tabs (site-app-detail-tabs buf))
                      (active (site-app-detail-active buf))
                      (section (site-app-detail-section buf active)))
                 (append
                   (site-app-head-part (site-app-head-blocks b spec data tabs active (site-app-action-bar buf)))
                   (cond ;; a page with no tabs is all head: nothing waits below it
                         ((null? tabs) '())
                         ;; a composed tab that draws itself ('draw BUF BUILDER) gives its claimed blocks
                         ((site-app-composed-draw buf active) ((site-app-composed-draw buf active) buf b))
                         ((not section) (list (site-app-part b 'ui/empty "Loading…" (list 'text "Loading…") #f)))
                         ((equal? section 'failed)
                          (let ((t "The site did not answer for this tab. g reads the page again.")) (list (site-app-part b 'ui/empty t (list 'text t) #f))))
                         ((null? (site-app-real section)) (list (site-app-part b 'ui/empty "Nothing here." (list 'text "Nothing here.") #f)))
                         (else (site-app-summary (site-app-node-blocks b (site-app-drop-repeats (site-app-drop-teasers (site-app-moved spec active section)) spec data) tones)))))))))
    (let* ((line (car (buffer-line-at-point buf)))
           (text (b 'text #f #f)))
      (buffer-set-text! buf text #t)
      (buffer-goto-line! buf (max 1 (min line (b 'count #f #f))))
      (site-app-set-anchors! buf text blocks))
    ;; anchor-mode's f hands a card back to the page, which folds it by its own state
    (buffer-set-local! buf 'anchor-fold-handler site-app-fold-anchor!)
    (buffer-set-local! buf 'site-app-links (b 'links #f #f))
    (buffer-set-local! buf 'site-app-stops (site-app-stops blocks))
    (buffer-set-locals! buf
      (list 'render-mode "blocks"
            'render-blocks (list (component 'ui/page (list 'body blocks)))))
    ;; anchor-mode marks the part point is in on the blocks just drawn
    (anchor-sync! buf)
    ;; the page's keys: the same keys bar a list carries
    (site-app-bind-action-keys! buf)
    (desktop-skip! buf 'footer-line-blocks)
    (buffer-set-local! buf 'footer-line-blocks
      (list (component 'ui/keys-bar (list 'main (site-app-detail-keys buf)))))
    buf))

(define (site-app-detail-link-at buf)
  (let ((hit (assoc (car (buffer-line-at-point buf)) (or (buffer-local buf 'site-app-links) '()))))
    (and hit (list 0 0 (cadr hit)))))

(add-hook! (list 'block-click 'site-app-list)
  ;; a click on a section or status tab is the same move as its key
  (lambda (buf id)
    (let ((spec (buffer-local buf 'site-app-spec)))
      (cond ((not (and spec (string? id))) #f)
            ((string-prefix? site-app-section-click id)
             (site-app-open! (plist-get spec 'name)
                             (string->symbol (substring id (string-length site-app-section-click) (string-length id))))
             #t)
            ((string-prefix? site-app-status-click id)
             (site-app-set-filter! buf (substring id (string-length site-app-status-click) (string-length id)))
             #t)
            (else #f)))))

(add-hook! (list 'block-click 'site-app)
  (lambda (buf id)
    (cond ((not (and (string? id) (buffer-local buf 'site-app-data))) #f)
          ((string-prefix? site-app-tab-click id)
           (site-app-detail-select! buf (substring id (string-length site-app-tab-click) (string-length id)))
           #t)
          ((string-prefix? site-app-stage-click id)
           (site-app-stage-select! buf (substring id (string-length site-app-stage-click) (string-length id)))
           #t)
          ((string-prefix? site-app-act-click id)
           (let ((key (substring id (string-length site-app-act-click) (string-length id))))
             (with-current-buffer buf
               (lambda () (site-app-detail-act! key))))
           #t)
          ((string-prefix? site-app-link-click id)
           (tab-open (site-app-url (site-app-spec (buffer-local buf 'site-app-name))
                                   (substring id (string-length site-app-link-click) (string-length id))))
           #t)
          (else #f))))

(define-style! 'site-app "
.sa-row { display: grid; column-gap: 1ch; align-items: center; container-type: inline-size; padding: 3px 0; font-family: var(--font-sans); font-size: 12.5px; }
.sa-row > .sa-cell { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.sa-stars-cell { font-size: 11px; }
/* one rating everywhere: gold stars, filled once met, hollow until then */
.sa-stars { color: var(--warn-fg); letter-spacing: -1px; white-space: nowrap; }
.sa-head-face { display: flex; gap: 14px; align-items: center; margin: .2em 0 .3em; }
.sa-head-face > .c-title { margin: 0; }
.sa-head-avatar { width: 64px; height: 64px; flex: none; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); }
.sa-head-stars { font-size: .5em; vertical-align: middle; }
.sa-row > img.sa-avatar { width: 28px; height: 28px; border-radius: 50%; object-fit: cover; background: var(--hl-line-bg); justify-self: center; }
.sa-name-cell { font-weight: 600; color: var(--default-fg); }
.sa-badge-cell { display: flex; align-items: center; }
.sa-pill.c-badge { border-radius: 999px; padding: 0 8px; font-size: 10px; font-weight: 600; letter-spacing: .03em; line-height: 17px; text-transform: lowercase; color: var(--dim-fg); background: var(--hl-line-bg); max-width: 100%; overflow: hidden; text-overflow: ellipsis; }
/* a toned pill keeps its tone: good, warn, bad, info from the spec's 'tones */
.sa-pill.c-badge.good { color: var(--ok-fg); background: color-mix(in srgb, var(--ok-fg) 16%, transparent); }
.sa-pill.c-badge.warn { color: var(--warn-fg); background: color-mix(in srgb, var(--warn-fg) 16%, transparent); }
.sa-pill.c-badge.bad { color: var(--alert-fg); background: color-mix(in srgb, var(--alert-fg) 16%, transparent); }
.sa-pill.c-badge.info { color: var(--accent-fg); background: color-mix(in srgb, var(--accent-fg) 16%, transparent); }
@container (max-width: 60ch) { .sa-need-60 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 70ch) { .sa-need-70 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 80ch) { .sa-need-80 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 90ch) { .sa-need-90 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 100ch) { .sa-need-100 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 110ch) { .sa-need-110 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 120ch) { .sa-need-120 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 130ch) { .sa-need-130 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 140ch) { .sa-need-140 > .sa-cell:last-child { grid-column: 1 / -1; } }
")

(define (site-app-render-detail! name row data)
  (let ((buf (site-app-detail-buffer name row)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'site-app-name name)
    (buffer-set-local! buf 'site-app-row row)
    (when data (buffer-set-local! buf 'site-app-data data))
    ;; a page saved before kinds were modes kept its kind as a minor mode
    (let ((old (buffer-local buf 'site-app-detail-minor)))
      (when old
        (buffer-set-local! buf 'site-app-detail-kind old)
        (buffer-set-local! buf 'site-app-detail-minor #f)))
    (let ((minors (buffer-local buf 'minor-modes)))
      (when (pair? minors)
        (buffer-set-local! buf 'minor-modes (filter (lambda (m) (not (equal? (mode-get m 'kind) 'major))) minors))))
    ;; The page's kind is its major mode, derived from the app's detail mode. The
    ;; app's details are one family, so the next row of any list takes their pane.
    (let ((mode (site-app-detail-major buf)))
      (buffer-set-local! buf 'detail-family (or (buffer-local buf 'site-app-detail-mode) "site-app-detail-mode"))
      (unless (equal? (buffer-local buf 'mode-name) mode)
        (with-current-buffer buf (lambda () (set-mode! mode)))))
    (site-app-draw! buf)
    (site-app-join-group! buf)
    buf))








(define (site-app-click-section! tab tab-spec k)
  ;; The spec names the button to press and what the page shows once it is on.
  (tab-press tab (plist-get tab-spec 'click) k (plist-get tab-spec 'wait)))


(define (site-app-navigate! name url wait k)
  ;; an app that reads its pages its own way says so with 'navigate (NAME URL
  ;; WAIT K), K getting (TAB ANSWER) as here; it can fall back to this one
  (let ((own (plist-get (site-app-spec name) 'navigate)))
    (if own (own name url wait k) (site-app-navigate-direct! name url wait k))))

(define (site-app-navigate-direct! name url wait k)
  (site-app-find-tab! name
    (lambda (tab)
      (tab-navigate tab url
        (lambda (answer)
          (if answer
              (k tab answer)
              (begin
                (site-app-replace-tab! name)
                (site-app-find-tab! name
                  (lambda (fresh)
                    (tab-navigate fresh url (lambda (again) (k fresh again)) wait))))))
        wait))))

(define (site-app-detail-tab-spec page id)
  (site-app-find (lambda (t) (equal? (plist-get t 'id) id))
                 (or (plist-get page 'detail-tabs) '())))

;; Press one detail tab in the app's background tab and file its section.
;; A dead tab is replaced by a fresh background tab, the item reloaded, and
;; the press tried again.
(define (site-app-fetch-section! name buf tab url wait page id k)
  (let ((sheet (plist-get page 'detail-sheet))
        (tab-spec (site-app-detail-tab-spec page id)))
    (if (not tab-spec)
        (k tab)
        (let ((keep (lambda (tab html)
                      (let ((data (and html (site-app-parse sheet html))))
                        (site-app-detail-put-section! buf id (and data (plist-get data 'section)))
                        (k tab)))))
          (site-app-click-section! tab tab-spec
            (lambda (html)
              (if html
                  (keep tab html)
                  (begin
                    (site-app-replace-tab! name)
                    (site-app-navigate! name url wait
                      (lambda (fresh answer)
                        (if answer
                            (site-app-click-section! fresh tab-spec
                              (lambda (again) (keep fresh again)))
                            (keep fresh #f))))))))))))

;; Visit every tab the page has not answered yet, one after another, while
;; this item is still the one the app is showing.
(define (site-app-collect-detail! name buf tab url wait page gen)
  (let loop ((rest (site-app-detail-tabs buf)) (tab tab))
    (when (and (pair? rest) (buffer-known? buf) (equal? gen (site-app-gen name)))
      (let ((id (plist-get (car rest) 'id)))
        (if (site-app-detail-section buf id)
            (loop (cdr rest) tab)
            (site-app-fetch-section! name buf tab url wait page id
              (lambda (tab) (loop (cdr rest) tab))))))))

(define (site-app-detail-mode-name spec page)
  ;; one major mode for every detail of the app, so mode affinity sends them all
  ;; to one pane; else the page's own
  (or (plist-get spec 'detail-mode) (plist-get page 'detail-mode) "site-app-detail-mode"))

;; the kind of detail a page makes, as a minor mode under the app's one major
;; mode; it carries the page's own keys
;; the page's major mode: its kind (ats-approval-mode), else the app's detail mode
(define (site-app-detail-major buf)
  (or (buffer-local buf 'site-app-detail-kind)
      (buffer-local buf 'site-app-detail-mode)
      "site-app-detail-mode"))

(define (site-app-prepare-detail! name row page)
  (let ((buf (site-app-detail-buffer name row)))
    (unless (buffer-exists? buf) (buffer-create buf))
    ;; a page a namer reuses for another row starts empty, not with the last row's data
    (let ((old (buffer-local buf 'site-app-row)))
      (when (and old (not (equal? (site-app-field old 'href) (site-app-field row 'href))))
        ;; the page leaves what it read behind, and takes what the new row's last read
        (when (and (buffer-local buf 'site-app-data) (not (buffer-local buf 'site-app-stub)))
          (site-app-cache-put! name 'pages (site-app-field old 'href)
            (list (buffer-local buf 'site-app-data) (buffer-local buf 'site-app-fetched-at) (buffer-local buf 'site-app-sections))))
        (let ((hit (site-app-cache-get name 'pages (site-app-field row 'href))))
          (cond (hit (buffer-set-locals! buf (list 'site-app-data (car hit) 'site-app-fetched-at (cadr hit)
                                                   'site-app-sections (or (caddr hit) '()) 'site-app-stub #f)))
                ;; a page drawn without its read holds nothing of the last row's
                ((buffer-local buf 'site-app-stub) #f)
                (else (buffer-set-locals! buf (list 'site-app-data #f 'site-app-fetched-at #f 'site-app-sections '())))))))
    (buffer-set-local! buf 'site-app-detail-mode (site-app-detail-mode-name (site-app-spec name) page))
    (buffer-set-local! buf 'site-app-detail-kind (plist-get page 'detail-kind))
    (buffer-set-local! buf 'detail-family (site-app-detail-mode-name (site-app-spec name) page))
    buf))

;; A detail tab the site can open from its URL (?tab=assessment) is read with a
;; plain fetch through the extension: your cookies, no tab, no clicks, and every
;; tab at once. The first answer paints the page; each fills its own tab.
(define (site-app-with-param url param id)
  (string-append url (if (string-contains? url "?") "&" "?") param "=" id))

(define (site-app-fetch-html! url k)
  ;; Each Chrome profile is its own socket, and a call that names nothing goes
  ;; to whichever profile registered last -- often not the one logged in to the
  ;; site. The frame's own window names the profile this editor sits in.
  (browser-call "fetch" (chrome-here (list 'url url))
    (lambda (reply)
      (let ((html (plist-get reply 'html)))
        (k (and (string? html) (equal? (plist-get reply 'status) 200) html))))))

(define (site-app-fetch-tab! name buf row url page id gen)
  ;; Each page keeps its own read: an answer lands in its page whenever it comes,
  ;; so moving on wastes nothing. A page on screen redraws; one off screen only files it.
  (let* ((sheet (plist-get page 'detail-sheet))
         (tab-url (site-app-with-param url (plist-get page 'detail-tab-param) id))
         (file! (lambda (html)
                  (when (and (buffer-known? buf) (equal? gen (buffer-local buf 'site-app-gen)))
                    (let ((data (and html (site-app-parse sheet html)))
                          (shown (member buf (get-visible-buffers))))
                      (when (and data (not (equal? (buffer-local buf 'site-app-data-gen) gen)))
                        (buffer-set-local! buf 'site-app-data-gen gen)
                        (if shown (site-app-render-detail! name row data) (buffer-set-local! buf 'site-app-data data)))
                      (when data (buffer-set-local! buf 'site-app-fetched-at (monotonic-ms)))
                      (site-app-detail-put-section! buf id (if data (plist-get data 'section) 'failed) (not shown)))))))
    (site-app-fetch-html! tab-url
      (lambda (html)
        (if html (file! html) (site-app-fetch-html! tab-url file!))))))

(define (site-app-warm! name list-buf row page)
  ;; read a row's page before it is asked for, filed off screen, unless it is fresh
  (let* ((buf (site-app-prepare-detail! name row page))
         (at (buffer-local buf 'site-app-fetched-at)))
    (unless (and at (buffer-local buf 'site-app-data) (< (- (monotonic-ms) at) 60000))
      (let ((gen (monotonic-ms))
            (url (site-app-url (site-app-spec name) (plist-get row 'href))))
        (buffer-set-local! buf 'site-app-name name)
        (buffer-set-local! buf 'site-app-row row)
        (buffer-set-local! buf 'site-app-list list-buf)
        (buffer-set-local! buf 'site-app-gen gen)
        (buffer-set-local! buf 'site-app-data-gen #f)
        (for-each (lambda (t) (site-app-fetch-tab! name buf row url page (plist-get t 'id) gen))
                  (or (plist-get page 'detail-tabs) '()))))))

(define (site-app-warm-around! name list-buf row page)
  ;; the rows a reader goes to next: three below, one above
  (let* ((rows (site-app-rows list-buf))
         (key (plist-get row 'key))
         (i (let loop ((rs rows) (i 0))
              (cond ((null? rs) #f) ((equal? (plist-get (car rs) 'key) key) i) (else (loop (cdr rs) (+ i 1)))))))
    (when i
      (for-each (lambda (j)
                  (when (and (>= j 0) (< j (length rows)))
                    (site-app-warm! name list-buf (list-ref rows j) page)))
                (list (+ i 1) (+ i 2) (+ i 3) (- i 1))))))

(define (site-app-show-detail! list-buf row &optional for-page quiet)
  ;; FOR-PAGE: the page the row belongs to, when the list is not one of the app's sections.
  ;; QUIET makes the page without showing it, and reads it only when that needs no live tab.
  (when row
    (let* ((name (plist-get (buffer-local list-buf 'site-app-spec) 'name))
           (spec (site-app-spec name))
           (page (or for-page (site-app-current-page list-buf)))
           ;; which page the row is shown for: an app with a buffer for each can name it so
           (row (plist-put row 'detail-page (plist-get page 'id)))
           (made (site-app-prepare-detail! name row page))
           (ids (map (lambda (t) (plist-get t 'id)) (or (plist-get page 'detail-tabs) '())))
           ;; every item opens on the tab this group last chose, else the first
           ;; a page's 'detail-default tab wins over the one the group last chose
           (valid (append (map (lambda (t) (plist-get t 'id)) (or (plist-get page 'detail-composed) '())) ids))
           ;; a page drawn again (the music moved on) stays on the tab it was on; a page
           ;; that declares no tabs takes them from its read, so any tab it was on is one
           (kept (buffer-local made 'site-app-active))
           (opened (buffer-set-local! made 'site-app-active
                     (if (and kept (or (member kept valid) (null? ids))) kept
                         (or (plist-get page 'detail-default)
                             (site-app-chosen-tab name page list-buf valid)))))
           ;; what this page last read draws at once; a read under a minute old stands
           (cached (buffer-local made 'site-app-data))
           (fresh (and cached (buffer-local made 'site-app-fetched-at)
                       (< (- (monotonic-ms) (buffer-local made 'site-app-fetched-at)) (or (plist-get spec 'fresh-ms) 60000))))
           ;; a page that would draw just as it last did is left as it is
           (same? (let ((f (plist-get spec 'drawn-same?))) (and f cached (buffer-local made 'site-app-active) (f made row))))
           (buf (if same?
                    (begin (buffer-set-local! made 'site-app-row row) made)
                    (let ((r (site-app-render-detail! name row #f)))
                      (let ((f (plist-get spec 'drawn!))) (when f (f r)))
                      r)))
           (sheet (plist-get page 'detail-sheet))
           (wait (plist-get page 'detail-wait))
           (url (site-app-url spec (plist-get row 'href)))
           (gen (site-app-next-gen! name)))
      (buffer-set-local! buf 'site-app-list list-buf)
      (buffer-set-local! buf 'site-app-for-page for-page)
      (unless fresh
        (buffer-set-local! buf 'site-app-gen gen)
        ;; the old read stays on screen until this one's answers replace it
        (unless cached (buffer-set-local! buf 'site-app-sections '()))
        (buffer-set-local! buf 'site-app-data-gen #f))
      (unless quiet (display-buffer-detail! buf list-buf))
      (cond
        ((not sheet) #f)
        (fresh #f)
        ;; a page that draws its composed tabs from what the app already holds needs no read
        ;; to show one: it draws at once, and reads the page only when its own tab is asked for.
        ;; 'detail-lazy may be a procedure of the row, for a page whose rows do not all hold enough
        ((and (let ((lazy (plist-get page 'detail-lazy))) (if (procedure? lazy) (lazy row) lazy))
              (member (buffer-local made 'site-app-active) valid)
              (or (not cached) (buffer-local made 'site-app-stub))
              (site-app-composed-tab buf (buffer-local made 'site-app-active)))
         (buffer-set-local! buf 'site-app-stub #t)
         (unless same?
           (site-app-render-detail! name row
             (list 'title (or (site-app-field row 'name) "") 'tabs (list (list 'active "yes" 'id "main" 'label "Tracks")) 'section '()))
           (let ((f (plist-get spec 'drawn!))) (when f (f buf)))))
        ((plist-get page 'detail-fetch)
         ;; one plain page with no tabs to press: fetch it, no live tab needed.
         ;; Each item keeps its own page, so only a newer read of this page outdates the answer.
         (site-app-fetch-html! url
           (lambda (html)
             (let ((data (and html (site-app-parse sheet html))))
               (when (and data (buffer-known? buf) (equal? gen (buffer-local buf 'site-app-gen)))
                 (site-app-render-detail! name row data))))))
        ((plist-get page 'detail-tab-param)
         (for-each (lambda (id) (site-app-fetch-tab! name buf row url page id gen)) ids)
         (unless quiet (site-app-warm-around! name list-buf row page)))
        ;; the live tab reads one page at a time; a quiet page waits for its chat to read it
        (quiet #f)
        (else
         ;; no tab URLs: load the page in the live tab and press each tab
         (site-app-navigate! name url wait
           (lambda (tab answer)
             (let ((data (and answer (site-app-parse sheet (plist-get answer 'html)))))
               (when (and data (buffer-known? buf) (equal? gen (site-app-gen name)))
                 (let ((open (site-app-find (lambda (t) (plist-get t 'active))
                                            (site-app-real (plist-get data 'tabs)))))
                   (buffer-set-local! buf 'site-app-sections
                     (if open (list (cons (plist-get open 'id) (plist-get data 'section))) '()))
                   (buffer-set-local! buf 'site-app-stub #f)
                   (site-app-render-detail! name row data)
                   ;; so the page is not read again while it stands
                   (buffer-set-local! buf 'site-app-fetched-at (monotonic-ms))
                   (site-app-collect-detail! name buf tab url wait page gen))))))))
      buf)))

(define (site-app-tab-key name page)
  (string-append "site-app-tab:" (symbol->string name) ":" (let ((id (plist-get page 'id))) (if (symbol? id) (symbol->string id) (or id "")))))

(define (site-app-chosen-tab name page list-buf ids)
  (let* ((g (and list-buf (buffer-group list-buf)))
         (chosen (and g (group-setting g (site-app-tab-key name page)))))
    (cond ((member chosen ids) chosen)
          ((pair? ids) (car ids))
          (else #f))))

(define (site-app-detail-select! buf id)
  (buffer-set-local! buf 'site-app-active id)
  ;; a page drawn without its read reads it now, for a tab that needs it
  (when (and (buffer-local buf 'site-app-stub) (not (site-app-composed-tab buf id)))
    (buffer-set-local! buf 'site-app-stub #f)
    (buffer-set-local! buf 'site-app-data #f)
    (site-app-show-detail! (buffer-local buf 'site-app-list) (buffer-local buf 'site-app-row) (buffer-local buf 'site-app-for-page)))
  (let* ((list-buf (buffer-local buf 'site-app-list))
         (g (and list-buf (buffer-group list-buf))))
    (when g
      (group-setting-set! g (site-app-tab-key (buffer-local buf 'site-app-name) (site-app-current-page list-buf)) id)))
  (site-app-draw! buf)
  ;; The background collection moved on to another item: fetch this one again.
  (let ((name (buffer-local buf 'site-app-name)))
    (when (and (not (site-app-detail-section buf id))
               (not (equal? (buffer-local buf 'site-app-gen) (site-app-gen name))))
      (let* ((list-buf (buffer-local buf 'site-app-list))
             (spec (site-app-spec name))
             (page (site-app-current-page list-buf))
             (wait (plist-get page 'detail-wait))
             (url (site-app-url spec (plist-get (buffer-local buf 'site-app-row) 'href)))
             (gen (site-app-next-gen! name)))
        (buffer-set-local! buf 'site-app-gen gen)
        (if (plist-get page 'detail-tab-param)
            ;; a composed tab reads the tabs it draws from
            (for-each (lambda (src) (site-app-fetch-tab! name buf (buffer-local buf 'site-app-row) url page src gen))
                      (let ((composed (site-app-composed-tab buf id)))
                        (if composed (plist-get composed 'from) (list id))))
            (site-app-navigate! name url wait
              (lambda (tab answer)
                (when answer (site-app-collect-detail! name buf tab url wait page gen)))))))))

(define (site-app-detail-nth! n)
  ;; 1 is the site's first tab; 0 reaches back to the composed tab before it
  (let* ((buf (current-buffer))
         (tabs (site-app-detail-tabs buf))
         (i (+ n (site-app-composed-lead buf) -1)))
    (when (and (>= i 0) (< i (length tabs)))
      (site-app-detail-select! buf (plist-get (list-ref tabs i) 'id)))))

(define (site-app-detail-step! d)
  (let* ((buf (current-buffer))
         (tabs (site-app-detail-tabs buf))
         (active (site-app-detail-active buf))
         (n (length tabs)))
    (when (> n 0)
      (let loop ((ts tabs) (i 0))
        (cond ((null? ts) (site-app-detail-select! buf (plist-get (car tabs) 'id)))
              ((equal? (plist-get (car ts) 'id) active)
               (site-app-detail-select! buf (plist-get (list-ref tabs (modulo (+ i d) n)) 'id)))
              (else (loop (cdr ts) (+ i 1))))))))


;;; --- actions: a key presses the page's own button in the live tab ---------

;; A page may show before it takes clicks; the spec's 'ready is the selector
;; it shows once it does.
(define (site-app-live-tab! name url k)
  (site-app-navigate! name url (plist-get (site-app-spec name) 'ready)
    (lambda (tab answer)
      (if answer (k tab) (begin (message "The site did not open this page") (k #f))))))

;; the sheet gives each button the CSS selector that presses it
(define (site-app-button-selector action) (plist-get action 'selector))

(define (site-app-detail-actions buf)
  (let ((data (buffer-local buf 'site-app-data)))
    (if data
        (filter (lambda (n) (plist-get n 'selector))
                (append (site-app-real (plist-get data 'actions))
                        (site-app-real (plist-get (site-app-head (site-app-spec (buffer-local buf 'site-app-name)) data) 'head))))
        '())))

;; after an action: read the page and the list again, the way the site redraws
(define (site-app-detail-after! buf note &optional advance)
  ;; ADVANCE: the press did its job, so go on to the next row, as the site does
  (message note)
  (let* ((list-buf (buffer-local buf 'site-app-list))
         (name (buffer-local buf 'site-app-name))
         (row (buffer-local buf 'site-app-row))
         (es (list-entries list-buf))
         (i (let loop ((rs es) (i 0))
              ;; a reread row may differ in its timestamps, so its key names it
              (cond ((null? rs) #f)
                    ((or (equal? (car rs) row)
                         (and (plist-get row 'key) (equal? (plist-get (car rs) 'key) (plist-get row 'key))))
                     i)
                    (else (loop (cdr rs) (+ i 1))))))
         (j (and advance i (cond ((< (+ i 1) (length es)) (+ i 1)) ((> i 0) (- i 1)) (else #f)))))
    (cond
      (j (list-goto-index! list-buf j)
         (site-app-show-detail! list-buf (nth j es)))
      ;; the press changed the page: the minute-old read no longer stands
      ((buffer-known? buf)
       (buffer-set-local! buf 'site-app-fetched-at #f)
       (site-app-show-detail! list-buf row)))
    (site-app-read-page! name (site-app-current-page list-buf))))

;; A key finds the button that carries it. The page spec's 'detail-actions maps a
;; button's label to a handler for the buttons that open a form; a handler gets
;; ('buf 'action 'selector 'live 'done). Any other button is pressed as it is.
;; the apps with a button press in flight on their tab
(define *site-app-pressing* '())

(define (site-app-detail-act! key)
  (let* ((buf (current-buffer))
         (keyed (assoc key (site-app-keyed-actions buf)))
         (action (and keyed (caddr keyed) (list-ref keyed 3))))
    (cond
      ((not keyed) (message (string-append "No action on " key " here")))
      ;; a button the app does not press: its form is on the site
      ((not action) (run-command "site-app-detail-open") (message (string-append (cadr keyed) ": on the site")))
      (else
        (let* ((name (buffer-local buf 'site-app-name))
               (spec (site-app-spec name))
               (page (site-app-detail-page buf))
               (url (site-app-url spec (plist-get (buffer-local buf 'site-app-row) 'href)))
               (hit (assoc (site-app-without-key (or (plist-get action 'text) "")) (or (plist-get page 'detail-actions) '())))
               (label (site-app-without-key (or (plist-get action 'text) "")))
               (selector (site-app-button-selector action))
               (live (lambda (k) (site-app-live-tab! name url k)))
               (done (lambda (note &optional advance) (site-app-detail-after! buf note advance))))
          (if hit
              ((cadr hit) (list 'buf buf 'action action 'selector selector 'live live 'done done))
              ;; one press at a time per app: they share one tab, and a second
              ;; navigation pulls the page from under the first ("Frame with ID 0 was removed")
              (if (member name *site-app-pressing*)
                  (message (string-append label ": wait, the last press is still on the site"))
                  (let ((free! (lambda () (set! *site-app-pressing* (filter (lambda (n) (not (equal? n name))) *site-app-pressing*)))))
                    (set! *site-app-pressing* (cons name *site-app-pressing*))
                    (message (string-append label "…"))
                    (live (lambda (tab)
                            (if (not tab)
                                (free!)
                                (tab-press tab selector
                                  (lambda (html)
                                    (free!)
                                    (done (if html (string-append label ": done")
                                              (string-append label ": the site did not answer"))
                                          (and html #t)))))))))))))))

(define site-app-action-letters
  '("a" "b" "c" "d" "e" "f" "h" "i" "j" "k" "l" "m" "n" "p" "r" "u" "v" "w" "x" "y" "z"))

(for-each (lambda (k)
            (define-command (string-append "site-app-detail-key-" k)
              (string-append "Press this page's button on " k)
              (lambda () (site-app-detail-act! k))))
          site-app-action-letters)

;; the page's buttons with keys: bound in its mode and listed in its keys bar
(define (site-app-keyed-actions buf)
  ;; (KEY LABEL IN-APP? ACTION) for every button the page has: no button goes
  ;; without a key. The site's own key comes first, else the first free letter
  ;; of the label. The page spec's 'detail-keys names the buttons the app
  ;; presses itself; the rest open the page on the site, where their forms are
  (let* ((list-buf (buffer-local buf 'site-app-list))
         (page (and list-buf (site-app-current-page list-buf)))
         (allowed (and page (plist-get page 'detail-keys))))
    (let loop ((as (site-app-detail-actions buf)) (used '()) (acc '()))
      (if (null? as) (reverse acc)
          (let* ((a (car as))
                 (label (site-app-without-key (or (plist-get a 'text) "")))
                 (own (plist-get a 'key))
                 (free (lambda (k) (and (member k site-app-action-letters) (not (member k used)) k)))
                 (key (or (and own (free own))
                          (let try ((cs (string-split (string-downcase label) "")))
                            (cond ((null? cs) #f) ((free (car cs)) (car cs)) (else (try (cdr cs)))))
                          (let try ((ls site-app-action-letters))
                            (cond ((null? ls) #f) ((free (car ls)) (car ls)) (else (try (cdr ls))))))))
            (loop (cdr as) (if key (cons key used) used)
                  (if key
                      (cons (list key label (and own (equal? own key) (or (not allowed) (member key allowed)) #t) a) acc)
                      acc)))))))

(define (site-app-detail-action-keys buf)
  ;; the button keys as (KEY WHAT) for the keys bar and the bindings
  (map (lambda (k) (list (car k) (string-append (string-downcase (cadr k)) (if (caddr k) "" " ↗"))))
       (site-app-keyed-actions buf)))

(define (site-app-bind-action-keys! buf)
  ;; the page's own mode holds its button keys
  (let* ((mode (site-app-detail-major buf))
         (keys (append (map (lambda (k) (list (car k) (string-append "site-app-detail-key-" (car k))))
                            (site-app-detail-action-keys buf))
                       (map (lambda (k) (list (car k) (cadr k))) (site-app-detail-extra-keys buf)))))
    (when mode
      (mode-keys! mode keys)
      ;; the index answers the page's button keys too, where it has none of its own
      (when (boundp 'app-detail-keys!)
        (let ((name (buffer-local buf 'site-app-name)))
          (for-each (lambda (page) (app-detail-keys! (site-app-page-mode name (plist-get page 'id)) mode))
                    (site-app-pages (site-app-spec name))))))))

(define-command "site-app-detail-tab-0" "Show this page's composed tab" (lambda () (site-app-detail-nth! 0)))
(define-command "site-app-detail-tab-1" "Show this page's first tab" (lambda () (site-app-detail-nth! 1)))
(define-command "site-app-detail-tab-2" "Show this page's second tab" (lambda () (site-app-detail-nth! 2)))
(define-command "site-app-detail-tab-3" "Show this page's third tab" (lambda () (site-app-detail-nth! 3)))
(define-command "site-app-detail-tab-4" "Show this page's fourth tab" (lambda () (site-app-detail-nth! 4)))
(define-command "site-app-detail-tab-5" "Show this page's fifth tab" (lambda () (site-app-detail-nth! 5)))
(define-command "site-app-detail-next-tab" "Show this page's next tab" (lambda () (site-app-detail-step! 1)))
(define-command "site-app-detail-prev-tab" "Show this page's previous tab" (lambda () (site-app-detail-step! -1)))
(define (site-app-fold-anchor! buf a)
  ;; a card folds by its own state, so the page redraws it shut or open and a
  ;; card that reads more from the site reads it on opening; #f when A is no card
  (let ((fold (and a (plist-get (or (anchor-data a) '()) 'fold))))
    (and fold
         (let ((title (car fold)) (open? (cadr fold)))
           (buffer-set-local! buf 'site-app-folds
             (cons (list title (not open?))
                   (filter (lambda (f) (not (equal? (car f) title))) (or (buffer-local buf 'site-app-folds) '()))))
           (site-app-draw! buf)
           ;; point stays on the card's title
           (let ((back (anchor-find buf (anchor-name a))))
             (when back (goto-char! (anchor-start back)) (anchor-sync! buf)))
           #t))))

(define-command "site-app-detail-fold" "Fold or unfold the card at point"
  (lambda ()
    (let ((buf (current-buffer)))
      (unless (site-app-fold-anchor! buf (anchor-at buf (buffer-point buf)))
        (message "No card here")))))

;; The stages a tab filters its rows by (an application's new, recommended,
;; ...), as its sheet reads them: (tag c-stages mark ACTIVE-CLASS items
;; ((status S selector CSS count N active BOOL) ...)). The site switches
;; stage by a live click, so choosing one presses its button in the app's tab
;; and reads the tab again from what the site then shows.
(define (site-app-detail-stages buf)
  (let ((sec (site-app-detail-section buf (site-app-detail-active buf))))
    (and (pair? sec)
         (let find ((ns sec))
           (cond ((null? ns) #f)
                 ((and (pair? (car ns)) (equal? (plist-get (car ns) 'tag) "c-stages")) (car ns))
                 ((and (pair? (car ns)) (find (or (plist-get (car ns) 'children) '()))))
                 (else (find (cdr ns))))))))

(define (site-app-stage-label s)
  (string-append (string-replace (or (plist-get s 'status) "") "_" " ") " " (or (plist-get s 'count) "")))

;; the stages worth a tab: the one showing, and any with rows
(define (site-app-stage-shown stages)
  (filter (lambda (s) (or (plist-get s 'active) (not (equal? (plist-get s 'count) "0"))))
          (site-app-real (plist-get stages 'items))))

;; the page a detail was drawn for: the one it was opened as (a job opened from a
;; company is a jobs page), else the page its list is on
(define (site-app-detail-page buf)
  (or (buffer-local buf 'site-app-for-page)
      (site-app-current-page (buffer-local buf 'site-app-list))))

(define (site-app-stage-select! buf status)
  (let* ((stages (site-app-detail-stages buf))
         (name (buffer-local buf 'site-app-name))
         (spec (site-app-spec name))
         (page (site-app-detail-page buf))
         (id (site-app-detail-active buf))
         (url (site-app-url spec (plist-get (buffer-local buf 'site-app-row) 'href)))
         (param (plist-get page 'detail-tab-param))
         (tab-url (if param (site-app-with-param url param id) url))
         (label (string-replace status "_" " ")))
    (if (not stages)
        (message "No stages on this tab")
        (let* ((item (site-app-find (lambda (s) (equal? (plist-get s 'status) status))
                                    (site-app-real (plist-get stages 'items))))
               (href (and item (plist-get item 'href)))
               (selector (and item (plist-get item 'selector)))
               (mark (plist-get stages 'mark))
               (wait (and mark (string-append selector "." mark)))
               (file! (lambda (html)
                        (let ((data (and html (site-app-parse (plist-get page 'detail-sheet) html))))
                          (if (not data)
                              (message (string-append label ": the site did not answer"))
                              (begin
                                (site-app-detail-put-section! buf id (plist-get data 'section))
                                (message label)))))))
          (message (string-append label "…"))
          (if href
              ;; a stage the site links to is read from its URL, on this tab
              (let ((stage-url (site-app-url spec href)))
                (site-app-fetch-html! (if param (site-app-with-param stage-url param id) stage-url) file!))
              (site-app-live-tab! name tab-url
                (lambda (tab)
                  (when tab (tab-press tab selector file! wait)))))))))

(define (site-app-stage-step! d)
  (let* ((buf (current-buffer))
         (shown (let ((st (site-app-detail-stages buf))) (if st (site-app-stage-shown st) '()))))
    (if (null? shown)
        (message "No stages on this tab")
        (let* ((n (length shown))
               (i (let loop ((xs shown) (i 0))
                    (cond ((null? xs) 0) ((plist-get (car xs) 'active) i) (else (loop (cdr xs) (+ i 1))))))
               (j (+ i d))
               (j (cond ((< j 0) (- n 1)) ((>= j n) 0) (else j))))
          (site-app-stage-select! buf (plist-get (nth j shown) 'status))))))

(define-command "site-app-detail-stage-next" "Show this tab's next stage" (lambda () (site-app-stage-step! 1)))
(define-command "site-app-detail-stage-prev" "Show this tab's previous stage" (lambda () (site-app-stage-step! -1)))
(define-command "site-app-detail-stage" "Ask for one of this tab's stages and show it"
  (lambda ()
    (let* ((buf (current-buffer))
           (st (site-app-detail-stages buf))
           (items (if st (site-app-real (plist-get st 'items)) '())))
      (if (null? items)
          (message "No stages on this tab")
          (completing-read "Stage: " (map site-app-stage-label items)
            (lambda (choice)
              (let ((hit (site-app-find (lambda (s) (equal? (site-app-stage-label s) choice)) items)))
                (if hit
                    (site-app-stage-select! buf (plist-get hit 'status))
                    (message (string-append "No stage " choice)))))
            'require-match #t)))))


;; a card's own keys, in force while point is on it
(define-keymap! "site-app-card-map")

;; a kind of card can have keys of its own: the spec's 'card-keys is
;; ((CLASS ((KEY COMMAND LABEL) ...)) ...), CLASS the class the sheet puts on the
;; c-item. Each kind gets a map with f folding as on any card, and the keys bar
;; shows its keys while point is on one
(define (site-app-card-map-name class) (string-append "site-app-card-map-" class))

(define (site-app-card-kinds)
  (let* ((buf *site-app-folding*)
         (spec (and buf (buffer-exists? buf) (site-app-spec (buffer-local buf 'site-app-name)))))
    (or (and spec (plist-get spec 'card-keys)) '())))

(define (site-app-card-map-for class)
  (if (and class (assoc class (site-app-card-kinds))) (site-app-card-map-name class) "site-app-card-map"))

(define (site-app-card-keys! spec)
  (for-each (lambda (kind)
              (let ((name (site-app-card-map-name (car kind))))
                (define-keymap! name)
                (for-each (lambda (k) (define-key name (car k) (cadr k))) (cadr kind))))
            (or (plist-get spec 'card-keys) '())))

;; the card point is on: the record its sheet made, or #f
(define (site-app-card-at buf)
  (let ((a (anchor-at buf (buffer-point buf))))
    (and a (anchor-data a) (plist-get (anchor-data a) 'record))))

;; the keys of the card point is on, when its kind has keys of its own
(define (site-app-card-key-labels buf)
  (let* ((at (buffer-at-point-map buf))
         (spec (site-app-spec (buffer-local buf 'site-app-name)))
         (kind (and at spec (site-app-find (lambda (k) (equal? (site-app-card-map-name (car k)) at))
                                           (or (plist-get spec 'card-keys) '())))))
    (if kind (map (lambda (k) (list (car k) (caddr k))) (cadr kind)) '())))

;; the keys bar follows point: on a card with keys of its own it leads with them
(define (site-app-footer-sync!)
  (let ((buf (current-buffer)))
    (when (and (buffer-local buf 'site-app-name) (buffer-local buf 'site-app-data))
      (let ((at (buffer-at-point-map buf)))
        (unless (equal? at (buffer-local buf 'site-app-footer-map))
          (buffer-set-local! buf 'site-app-footer-map at)
          (buffer-set-local! buf 'footer-line-blocks
            (list (component 'ui/keys-bar (list 'main (site-app-detail-keys buf))))))))))

(add-hook! 'post-command-hook 'site-app-footer-sync!)

(define (site-app-href-page spec href)
  ;; the page whose items live under HREF's path, when compos can draw them
  (site-app-find (lambda (page)
                   (let ((path (plist-get page 'path)))
                     (and (string? path) (plist-get page 'detail-sheet)
                          (string-prefix? (string-append path "/") href))))
                 (site-app-pages spec)))

(define-command "site-app-detail-follow" "Open the link at point: an item compos draws opens beside the list, anything else on the site"
  (lambda ()
    (let* ((buf (current-buffer))
           (hit (site-app-detail-link-at buf))
           (href (and hit (caddr hit)))
           (spec (site-app-spec (buffer-local buf 'site-app-name)))
           (page (and href spec (site-app-href-page spec href)))
           (list-buf (buffer-local buf 'site-app-list)))
      (cond ((not hit) (message "No link here"))
            ((and page list-buf (buffer-known? list-buf))
             (let* ((path (car (string-split href "?")))
                    (key (car (reverse (string-split path "/"))))
                    (line (car (buffer-line-at-point buf)))
                    (text (string-trim (list-ref (string-split (buffer-text buf) "\n") (- line 1)))))
               (site-app-show-detail! list-buf (list 'href href 'key key 'name text) page)))
            (else (tab-open (site-app-url spec href)))))))
(define-command "site-app-detail-reload" "Read this page again from the site"
  (lambda ()
    (let ((buf (current-buffer)))
      ;; a reload reads now, and the page the detail was opened as
      (buffer-set-local! buf 'site-app-fetched-at #f)
      ;; and an open card reads its details again
      (buffer-set-local! buf 'site-app-card-more '())
      ;; and a tab that opens on an empty stage may skip it again
      (buffer-set-local! buf 'site-app-stage-skipped '())
      (site-app-show-detail! (buffer-local buf 'site-app-list) (buffer-local buf 'site-app-row)
                             (buffer-local buf 'site-app-for-page)))))
(define-command "site-app-detail-open" "Open this page on the site"
  (lambda ()
    (let ((buf (current-buffer)))
      (tab-open (site-app-url (site-app-spec (buffer-local buf 'site-app-name))
                              (plist-get (buffer-local buf 'site-app-row) 'href))))))

(mode-keys! "site-app-detail-mode"
  (list (list "TAB" "site-app-detail-next-tab")
        (list "S-TAB" "site-app-detail-prev-tab")
        (list "t" "site-app-tabs")
        (list "s" "site-app-sections")
        (list "<down>" "site-app-detail-next")
        (list "<up>" "site-app-detail-prev")
        (list "0" "site-app-detail-tab-0")
        (list "1" "site-app-detail-tab-1")
        (list "2" "site-app-detail-tab-2")
        (list "3" "site-app-detail-tab-3")
        (list "4" "site-app-detail-tab-4")
        (list "5" "site-app-detail-tab-5")
        (list "[" "site-app-detail-stage-prev")
        (list "]" "site-app-detail-stage-next")
        (list "/" "site-app-detail-stage")
        (list "RET" "site-app-detail-follow")
        (list "g" "site-app-detail-reload")
        (list "o" "site-app-detail-open")
        (list "q" "quit-window")))

(define (site-app-list-detail list-buf)
  ;; the page the list shows beside it
  (site-app-find (lambda (b) (equal? (buffer-local b 'site-app-list) list-buf)) (get-visible-buffers)))

(define (site-app-detail-anchor-step! command)
  ;; from the list, walk the page beside it by its parts: the list keeps its row.
  ;; The page's window keeps its own point, so the walk starts there and moves it
  (let* ((d (site-app-list-detail (current-buffer)))
         (w (and d (site-app-find (lambda (x) (equal? (cadr x) d)) (window-list-all)))))
    (if (not d)
        (message "No page beside this list")
        (begin
          (with-current-buffer d
            (lambda ()
              (when w (goto-char! (window-point (car w))))
              (run-command command)))
          (when w (window-set-point! (car w) (buffer-point d)))))))

(define-command "site-app-detail-anchor-next" "Go to the next part of the page beside the list"
  (lambda () (site-app-detail-anchor-step! "anchor-read-next")))
(define-command "site-app-detail-anchor-prev" "Go to the previous part of the page beside the list"
  (lambda () (site-app-detail-anchor-step! "anchor-read-previous")))

(define-command "site-app-detail" "Open the item on this website app row"
  (lambda ()
    (let ((buf (current-buffer)))
      (site-app-show-detail! buf (list-current buf)))))

;; the row's page and the chat of its own, as M-o on the page
(define-command "site-app-agent" "Open the chat of this row's page, as M-o does on the page"
  (lambda ()
    (let* ((buf (current-buffer))
           (page (site-app-show-detail! buf (list-current buf))))
      (when page (llm-companion-open! page)))))

;; M-O: the top rows of the list, each worked by its page's own chat, the one
;; M-o opens, with one orchestrator to report. The app's 'bulk plist tunes it:
;; 'size (10), 'model for the orchestrator, 'rules for every case, 'report.
(define-command "site-app-bulk-agents" "Hand the top rows to their pages' own chats, with one orchestrator to report"
  (lambda ()
    (let* ((buf (current-buffer))
           (spec (site-app-spec (plist-get (buffer-local buf 'site-app-spec) 'name)))
           (bulk (or (plist-get spec 'bulk) '()))
           (size (or (plist-get bulk 'size) 10))
           (rows (let loop ((es (filter (lambda (e) (list-selectable? buf e)) (list-entries buf))) (acc '()))
                   (if (or (null? es) (>= (length acc) size))
                       (reverse acc)
                       (loop (cdr es) (cons (car es) acc)))))
           (page (site-app-current-page buf))
           (pages (filter (lambda (p) p) (map (lambda (row) (site-app-show-detail! buf row #f #t)) rows))))
      (if (null? pages)
          (message "no rows here")
          (let ((orch (bulk-agents! pages
                        (list 'title (string-append "Orchestrate: " (number->string (length pages)) " "
                                                    (or (and page (plist-get page 'label)) "cases"))
                              'model (plist-get bulk 'model)
                              'noun (string-downcase (or (and page (plist-get page 'label)) "items"))
                              'rules (plist-get bulk 'rules)
                              'report (plist-get bulk 'report)))))
            (when orch
              (with-frame-windows (lambda () (display-buffer-other-window! orch)))))))))
(catalog-meta! 'command "site-app-bulk-agents" 'domain 'chat 'effects '(write spend display))

(define (define-site-app spec)
  (let* ((name (plist-get spec 'name))
         (title (or (plist-get spec 'title) (symbol->string name)))
         (pages (site-app-pages spec))
         (list-keys (or (plist-get spec 'list-keys) '())))
    (site-app-put! name spec)
    (site-app-card-keys! spec)
    (let ((major (plist-get spec 'detail-mode)))
      (when major
        (define-mode major (lambda () (buffer-set-read-only! (current-buffer) #t)))
        (mode-parent! major "site-app-detail-mode")))
    (for-each (lambda (page)
                (let ((mode (plist-get page 'detail-mode))
                      (kind (plist-get page 'detail-kind)))
                  (when mode
                    (define-mode mode (lambda () (buffer-set-read-only! (current-buffer) #t)))
                    (mode-parent! mode "site-app-detail-mode"))
                  ;; the page's kind derives from the app's detail mode: an approval
                  ;; page is an ATS page is a site-app page, most specific last
                  (when kind
                    (define-derived-mode kind (site-app-detail-mode-name spec page) (lambda () #t)))))
              pages)
    ;; Every section is an index of its own: its buffer, its mode, its command.
    (for-each
      (lambda (page)
        (let* ((id (plist-get page 'id))
               (mode (site-app-page-mode name id))
               (command (string-append (symbol->string name) "-" (symbol->string id))))
          (define-list-mode! mode
            (list 'doc (string-append title " " (plist-get page 'label)
                                      ", read from the live site. M-number keys switch sections, [ and ] walk the status tabs, / asks for one, number keys switch the tabs of the page beside the list, g rereads, q quits.")
                  'buffer (site-app-page-buffer name id)
                  'transient #f
                  'noun "item"
                  'rows site-app-rows
                  'key site-app-row-key
                  'columns site-app-columns
                  'cells site-app-cells
                  'title site-app-title
                  'header site-app-header
                  ;; rows and head as blocks, so the sections and status tabs are tabs
                  'collection "c-list"
                  'composml site-app-composml
                  'composml-head site-app-composml-head
                  'preview site-app-show-detail!
                  'debounce #t
                  'footer (lambda (b) (append (map (lambda (k) (list (car k) (caddr k))) list-keys) (list (list "s" "sections") (list "t" "status") (list "[ ]" "status") (list "1–5" "page tabs") (list "M-↑↓" "page parts")
                                            (list "/" "state") (list "g" "refresh") (list "q" "quit"))))
                  ;; Digits are left free so they reach the page beside the list, as
                  ;; its tab keys; the sections move to M-digit.
                  'keys (append (list (list "RET" "site-app-detail")
                                      (list "t" "site-app-tabs")
                                      (list "s" "site-app-sections")
                                      (list "[" "site-app-filter-prev")
                                      (list "]" "site-app-filter-next")
                                      (list "g" "site-app-refresh")
                                      ;; the page beside the list, part by part, without leaving the row
                                      (list "M-<down>" "site-app-detail-anchor-next")
                                      (list "M-<up>" "site-app-detail-anchor-prev")
                                      (list "q" "quit-window"))
                                ;; the app's own list keys: 'list-keys ((KEY COMMAND LABEL) ...)
                                (map (lambda (k) (list (car k) (cadr k))) list-keys)
                                (map (lambda (p) (list (string-append "M-" (plist-get p 'key))
                                                       (string-append "site-app-tab-" (plist-get p 'key))))
                                     pages))))
          ;; / asks for a status tab; the list mode's own row filter stays on f
          (define-key (mode-keymap mode) "/" "site-app-filter-choose")
          ;; The index keeps its own bindings; unclaimed detail-page keys run in the
          ;; adjacent detail, just as they do when focus is on the detail itself.
          (when (boundp 'app-detail-keys!)
            (app-detail-keys! mode "site-app-detail-mode"))
          ;; its pages walk it: N and P on a page open the next and previous row
          (when (boundp 'index-declare!)
            (index-declare! mode 'next "list-next" 'prev "list-prev" 'open "site-app-detail"))
          (define-command command (string-append "Open " title " " (plist-get page 'label))
            (lambda () (site-app-open! name id)))))
      pages)
    spec))

(domain! 'web)
(effects! '(write external display))
(public! 'define-site-app
  "(define-site-app SPEC) — register a website app and its list mode")
(public! 'site-app-open!
  "(site-app-open! NAME) — open a registered website app in the current group")
(public! 'site-app-read-page!
  "(site-app-read-page! NAME PAGE) — navigate the app's live tab and redraw PAGE")
