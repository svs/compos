;;; site-app.scm --- turn a live website into a compos list-and-detail app

(package! 'site-app)
(origin! 'bundled)

(domain! 'web)
(effects! '(read))

(define *site-apps* '())
(define *site-app-tabs* '())

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
  (set! *site-app-tabs* (alist-put *site-app-tabs* name tab)) tab)

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
    (and (string? out) (> (string-length out) 1) (json-parse out))))

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

(define (site-app-composml-head buf head)
  ;; the site's navbar, then the section's status tabs, each a row of tabs
  (let* ((spec (buffer-local buf 'site-app-spec))
         (current (buffer-local buf 'site-app-page))
         (filters (or (buffer-local buf 'site-app-filters) '()))
         (query (buffer-local buf 'site-app-filter)))
    (append
      (list (component 'ui/tabs
              (list 'class "sa-sections"
                    'tabs (map (lambda (page)
                                 (list (string-append site-app-section-click (symbol->string (plist-get page 'id)))
                                       (plist-get page 'label)
                                       (equal? current (plist-get page 'id))
                                       (string-append "M-" (plist-get page 'key))))
                               (site-app-pages spec)))))
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

(define (site-app-cell buf col row)
  ;; one cell; a column's 'kind draws it as a status pill, gold stars or a name.
  ;; A cell draws its segs and text, never nested blocks, so a pill is a seg
  (let ((text (or (site-app-field row (plist-get col 'field)) ""))
        (kind (plist-get col 'kind))
        (class (if (plist-get col 'face) (string-append "sa-cell c-" (plist-get col 'face)) "sa-cell")))
    (cond ((equal? text "") (list 'tag "span" 'class class 'text ""))
          ((eq? kind 'badge)
           (let ((tone (site-app-tone-class (plist-get (buffer-local buf 'site-app-spec) 'tones) text)))
             (list 'tag "span" 'class (string-append class " sa-badge-cell")
                   'segs (list (list (if tone (string-append "c-badge sa-pill " tone) "c-badge sa-pill") text)))))
          ((eq? kind 'stars) (list 'tag "span" 'class (string-append class " sa-stars-cell") 'text text))
          ((eq? kind 'name) (list 'tag "span" 'class (string-append class " sa-name-cell") 'text text))
          (else (list 'tag "span" 'class class 'text text)))))

(define (site-app-composml buf row)
  ;; a row as blocks: one cell per column, on the column widths. Its class
  ;; names the width the fixed columns need with room left for the one that
  ;; takes the rest; the stylesheet moves that one to a line of its own in a
  ;; narrower window rather than squeezing it into a sliver
  (let* ((cols (or (plist-get (site-app-current-page buf) 'columns) '()))
         (fixed (fold (lambda (sum col) (+ sum 1 (or (plist-get col 'width) 0))) 0 cols))
         (need (* 10 (quotient (+ fixed 30 9) 10))))
    (list 'tag "div" 'class (string-append "sa-row sa-need-" (number->string (min 140 (max 60 need))))
          'attrs (list (list "style"
                             (string-append "grid-template-columns:"
                                            (string-join (map (lambda (col)
                                                                (let ((w (plist-get col 'width)))
                                                                  (if w (string-append (number->string w) "ch") "minmax(0,1fr)")))
                                                              cols)
                                                         " "))))
          'children (map (lambda (col) (site-app-cell buf col row))
                         cols))))

(define (site-app-title buf)
  (let* ((spec (buffer-local buf 'site-app-spec))
         (page (site-app-current-page buf)))
    (string-append (or (plist-get spec 'title) (symbol->string (plist-get spec 'name)))
                   " · " (or (plist-get page 'label) ""))))

(define (site-app-header buf)
  ;; the site's navbar, then the section's own status tabs when it has them
  (let* ((spec (buffer-local buf 'site-app-spec))
         (current (buffer-local buf 'site-app-page))
         (nav (string-join
                (map (lambda (page)
                       (let ((text (string-append "M-" (plist-get page 'key) " " (plist-get page 'label))))
                         (if (equal? current (plist-get page 'id))
                             (string-append "[" text "]")
                             (string-append " " text " "))))
                     (site-app-pages spec))
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

(define (site-app-rows buf) (or (buffer-local buf 'site-app-rows) '()))

(define (site-app-join-group! buf)
  (let ((group (frame-group)))
    (when (and group (not (buffer-in-group? buf group)))
      (buffer-add-group! buf group)))
  buf)

(effects! '(write external))

(define (site-app-html! name tab page k)
  ;; The site renders its pages whole before any script runs, so a plain fetch
  ;; through the extension (your cookies, no tab) reads them. The live tab is
  ;; kept for what only a live page can do: pressing its buttons.
  (let* ((url (site-app-url (site-app-spec name) (plist-get page 'path)))
         (query (buffer-local (site-app-page-buffer name (plist-get page 'id)) 'site-app-filter)))
    (site-app-fetch-html! (if (and (string? query) (> (string-length query) 0))
                              (string-append url "?" query)
                              url)
                          k)))

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

(define (site-app-find-tab! name k)
  (let ((spec (site-app-spec name))
        (remembered (site-app-tab name)))
    (tabs-here
      (lambda (tabs)
        (let ((live (and remembered
                         (site-app-find
                           (lambda (tab) (equal? (plist-get tab 'id) remembered))
                           tabs))))
          (if live
              (k remembered)
              (chrome-call "open"
                (chrome-here
                  (append (list 'url (site-app-url spec (plist-get spec 'home))
                                'background #t)
                          (let ((after (chrome-tab-resolve!)))
                            (if after (list 'after after) '()))))
                (lambda (reply)
                  (let ((tab (plist-get reply 'tab)))
                    (site-app-note-tab! name tab)
                    (k tab))))))))))

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
(define-command "site-app-refresh" "Read this website app tab again"
  (lambda ()
    (let* ((buf (current-buffer))
           (spec (buffer-local buf 'site-app-spec)))
      (site-app-read-page! (plist-get spec 'name) (site-app-current-page buf)))))

(define (site-app-open! name &optional id)
  ;; each section is its own buffer; one already read is shown as it stands, g rereads it
  (let* ((spec (site-app-spec name))
         (page (site-app-page spec (or id (plist-get spec 'home-page))))
         (pid (plist-get page 'id))
         (buf (site-app-page-buffer name pid))
         (mode (site-app-page-mode name pid)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (site-app-join-group! buf)
    (buffer-set-local! buf 'site-app-spec spec)
    (buffer-set-local! buf 'site-app-page pid)
    (unless (buffer-derived-mode? buf mode)
      (with-current-buffer buf (lambda () (set-mode! mode))))
    (switch-to-buffer! buf)
    (when (null? (site-app-rows buf))
      (site-app-find-tab! name (lambda (tab) (site-app-read-page! name page))))
    buf))


(define (site-app-detail-buffer name row)
  ;; the spec's 'detail-name says what a row's page is called; the key is the fallback
  (let* ((spec (site-app-spec name))
         (namer (and spec (plist-get spec 'detail-name)))
         (title (or (and namer (namer row)) (site-app-field row 'key))))
    (string-append "*" (symbol->string name) ": " title "*")))


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


;; Ornament the site draws for looks: Devanagari labels and section numerals.
(define (site-app-ornament? text)
  (and (re-match? "[\\x{0900}-\\x{097F}]" text)
       (not (re-match? "[A-Za-z]" text))))

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





;; The profile's state line ("withdrawn → pending: withdrawn scheduled 2 Sep"):
;; its first word is where the item stands, and that belongs in the title.
(define (site-app-state-node data)
  (site-app-find (lambda (n) (re-match? " → " (or (plist-get n 'text) "")))
                 (site-app-real (plist-get data 'profile))))

;; The site prints each button's key on the button ("Approve a"). In the app
;; the keys live in the keys bar, so a button says only what it does.
(define (site-app-without-key text)
  (let ((words (string-split (string-trim text) " ")))
    (if (and (> (length words) 1) (= (string-length (list-ref words (- (length words) 1))) 1))
        (string-join (reverse (cdr (reverse words))) " ")
        (string-trim text))))

(define (site-app-detail-keys buf)
  (let ((n (length (site-app-detail-tabs buf))))
    (append (site-app-detail-action-keys buf)
            (if (> n 0) (list (list (string-append "1–" (number->string n)) "tabs")) '())
            (list (list "M-↑↓" "parts")
                  (list "M-g a" "part by name")
                  (list "f" "fold card")
                  (list "RET" "open link")
                  (list "g" "reload")
                  (list "o" "on the site")
                  (list "q" "quit")))))


(define site-app-tab-click "site-app-tab:")


(mode-parent! "site-app-detail-mode" "special-mode")




(define (site-app-capitalize s)
  (if (or (not s) (equal? s "")) ""
      (string-append (string-upcase (substring s 0 1)) (substring s 1 (string-length s)))))

(define *site-app-gens* '())
(define (site-app-gen name) (let ((hit (assoc name *site-app-gens*))) (and hit (cadr hit))))
(define (site-app-next-gen! name)
  (let ((gen (+ 1 (or (site-app-gen name) 0))))
    (set! *site-app-gens* (alist-put *site-app-gens* name gen))
    gen))

(define (site-app-detail-tabs buf)
  (let ((data (buffer-local buf 'site-app-data)))
    (if data (site-app-real (plist-get data 'tabs)) '())))

(define (site-app-detail-active buf)
  (or (buffer-local buf 'site-app-active)
      (let ((hit (site-app-find (lambda (t) (plist-get t 'active)) (site-app-detail-tabs buf))))
        (and hit (plist-get hit 'id)))))

(define (site-app-detail-section buf id)
  (let ((hit (assoc id (or (buffer-local buf 'site-app-sections) '()))))
    (and hit (cdr hit))))

(define (site-app-detail-put-section! buf id nodes &optional quiet)
  (when (buffer-known? buf)
    (buffer-set-local! buf 'site-app-sections
      (cons (cons id (if (equal? nodes 'failed) 'failed (or nodes '())))
            (filter (lambda (e) (not (equal? (car e) id)))
                    (or (buffer-local buf 'site-app-sections) '()))))
    (unless quiet (site-app-draw! buf))))


;; A tab that restates the header (the candidate's stars and name) says it once.
(define (site-app-drop-repeats section data)
  (let* ((profile (site-app-real (plist-get data 'profile)))
         (said (append (list (plist-get data 'candidate))
                       (if (pair? profile) (list (plist-get (car profile) 'text)) '()))))
    (filter (lambda (n) (or (not (pair? n))
                            (plist-get n 'children)
                            (and (not (member (plist-get n 'text) said))
                                 ;; a rating alone on its line: the header already shows it
                                 (not (re-match? "^\\s*★+\\s*$" (or (plist-get n 'text) ""))))))
            section)))


;;; --- the page as components ------------------------------------------------
;;; The mode turns the stylesheet's records into ui/* components. Under them
;;; the buffer holds the page as plain text, one line per block, and each block
;;; claims its lines: point moves by line, the block at point is current, and
;;; the view follows it. Search and copy read the text.

(define site-app-link-click "site-app-link:")
(define site-app-act-click "site-app-act:")

(define (site-app-action-bar buf)
  ;; (LABEL KEY KIND IN-APP?): every button the page has, each with its key
  (map (lambda (k)
         (let ((click (or (plist-get (list-ref k 3) 'click) "")))
           (list (cadr k) (car k)
                 (cond ((re-match? "approve" click) "good")
                       ((re-match? "reject|delete" click) "bad")
                       (else "plain"))
                 (caddr k))))
       (site-app-keyed-actions buf)))

(define (site-app-unanchored blocks)
  (map (lambda (blk)
         (if (pair? blk)
             (let strip ((pl blk) (acc '()))
               (cond ((null? pl) (let ((out (reverse acc)))
                                   (if (plist-get out 'children)
                                       (plist-put out 'children (site-app-unanchored (plist-get out 'children)))
                                       out)))
                     ((eq? (car pl) 'sa-anchor) (strip (cddr pl) acc))
                     (else (strip (cddr pl) (cons (cadr pl) (cons (car pl) acc))))))
             blk))
       blocks))

(define (site-app-anchors blocks)
  ;; (NAME FIRST LAST [KEYMAP DATA]) for every block that names itself a stop, in page order
  (let walk ((bs blocks) (acc '()))
    (if (null? bs) acc
        (let* ((blk (car bs))
               (acc (if (and (pair? blk) (plist-get blk 'sa-anchor) (plist-get blk 'lines))
                        (append acc (list (append (cons (plist-get blk 'sa-anchor) (plist-get blk 'lines))
                                                  ;; a part with keys of its own: its keymap, and what they act on
                                                  (if (plist-get blk 'sa-keys)
                                                      (list (plist-get blk 'sa-keys) (list 'fold (plist-get blk 'sa-fold)))
                                                      '()))))
                        acc)))
          (walk (cdr bs) (if (pair? blk) (walk (or (plist-get blk 'children) '()) acc) acc))))))

(define (site-app-set-anchors! buf text blocks)
  ;; anchors are byte ranges: a block's first line to the end of its last
  (let* ((starts (let loop ((ls (string-split text "\n")) (at 0) (acc '()))
                   (if (null? ls) (reverse (cons at acc))
                       (loop (cdr ls) (+ at (string-byte-length (car ls)) 1) (cons at acc)))))
         (n (- (length starts) 1))
         (at (lambda (line) (list-ref starts (max 0 (min n (- line 1)))))))
    (anchor-set! buf (map (lambda (a)
                            (let ((name (car a)))
                              (append (list name
                                            (at (cadr a)) (max (+ 1 (at (cadr a))) (- (at (+ 1 (caddr a))) 1)))
                                      (list-tail a 3))))
                          (site-app-anchors blocks)))
    (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))))

;; a word's tone as a class: the spec's 'tones ((REGEX KIND) ...) and gold stars
(define (site-app-tone-class tones word)
  ;; a component tone: good, warn, bad or info
  (if (re-match? "^★+$" word)
      "warn"
      (let loop ((ts (or tones '())))
        (cond ((null? ts) #f)
              ((re-match? (car (car ts)) word) (symbol->string (cadr (car ts))))
              (else (loop (cdr ts)))))))

(define (site-app-toned-segs text base tones)
  (let loop ((words (string-split text " ")) (acc '()) (first #t))
    (if (null? words)
        (reverse acc)
        (let ((acc (if first acc (cons (list base " ") acc))))
          (loop (cdr words)
                (cons (list (let ((tone (site-app-tone-class tones (car words)))) (if tone (string-append "c-" tone) base))
                            (car words))
                      acc)
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
          (if name (list 'sa-anchor name) '())))

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
    (and (pair? real) (null? (filter (lambda (x) (not (plist-get x 'sa-anchor))) real)))))

(define (site-app-header blocks)
  ;; the page's head, title through the tabs, is its top part: the header
  (let* ((real (filter (lambda (x) (and (pair? x) (plist-get x 'lines))) blocks))
         (name (let find ((bs real)) (cond ((null? bs) "Header") ((plist-get (car bs) 'sa-anchor) (plist-get (car bs) 'sa-anchor)) (else (find (cdr bs)))))))
    (if (null? real)
        blocks
        (list (site-app-claim (component 'ui/group (list 'body (site-app-unanchored blocks)))
                              (apply min (map (lambda (x) (car (plist-get x 'lines))) real))
                              (apply max (map (lambda (x) (cadr (plist-get x 'lines))) real))
                              name)))))

(define (site-app-summary blocks)
  ;; the loose blocks a tab opens with, before its first part (a headline,
  ;; where and how long, the tags, the profile link), are one part: Summary
  (let* ((head (site-app-take-while (lambda (x) (and (pair? x) (not (plist-get x 'sa-anchor)) (plist-get x 'lines))) blocks))
         (rest (list-tail blocks (length head))))
    (if (< (length head) 2)
        blocks
        (cons (site-app-claim (component 'ui/group (list 'body head))
                              (car (plist-get (car head) 'lines))
                              (cadr (plist-get (car (reverse head)) 'lines))
                              "Summary")
              rest))))

(define (site-app-sectioned blocks)
  ;; a heading or a lead-in and what follows it, up to the next of its rank or
  ;; higher, are one part: one anchor, so the walk, imenu and the highlight
  ;; take the whole section and not its title
  (let loop ((bs blocks) (acc '()))
    (cond ((null? bs) (reverse acc))
          ((site-app-rank (car bs))
           (let* ((head (car bs))
                  (r (site-app-rank head))
                  (body (site-app-take-while (lambda (x) (let ((q (site-app-rank x))) (or (not q) (> q r)))) (cdr bs)))
                  (first (car (plist-get head 'lines)))
                  (last (let span ((xs body) (m first))
                          (if (null? xs) m
                              (let ((ls (and (pair? (car xs)) (plist-get (car xs) 'lines))))
                                (span (cdr xs) (if ls (max m (cadr ls)) m)))))))
             (let ((parts (site-app-sectioned body)))
               (loop (list-tail (cdr bs) (length body))
                     (cons (site-app-claim (component 'ui/group (list 'body (cons (car (site-app-unanchored (list head))) parts)))
                                           first last
                                           ;; a section of nothing but cards (Work Experience) is no stop of
                                           ;; its own: the walk goes card by card
                                           (and (not (site-app-all-parts? parts)) (plist-get head 'sa-anchor)))
                           acc)))))
          (else (loop (cdr bs) (cons (car bs) acc))))))

;; folds the reader set on this page's cards, by title: (TITLE OPEN?)
(define *site-app-folding* #f)
(define (site-app-open? title default)
  (let ((hit (and *site-app-folding* (assoc title (or (buffer-local *site-app-folding* 'site-app-folds) '())))))
    (if hit (cadr hit) default)))

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
                             (open? (site-app-open? title (not (plist-get node 'folded))))
                             (first (b 'line title (plist-get (car kids) 'href)))
                             (body (if open? (site-app-node-blocks b (cdr kids) tones) '()))
                             (card (component 'ui/card (list 'title title 'open? open? 'body body))))
                        (loop (cdr rest) 'item (cons (append (site-app-claim card first (max first (b 'count #f #f)) title)
                                                             (list 'sa-keys "site-app-card-map" 'sa-fold (list title open?)))
                                                     acc)))))))
            ((equal? tag "c-group")
             ;; a run the sheet set apart: the note staff read, or the letter the candidate would
             (let* ((letter? (equal? (plist-get node 'class) "sa-letter"))
                    (kids (site-app-kept (plist-get node 'children)))
                    (lead (if (pair? kids) (or (plist-get (car kids) 'text) "") ""))
                    (first (+ 1 (b 'count #f #f)))
                    ;; the note's first record is its label
                    (label (and (not letter?) (pair? kids) (begin (b 'line lead #f) lead)))
                    (body (site-app-node-blocks b (if label (cdr kids) kids) tones))
                    ;; the note reads as one stop; a letter keeps its sections as stops
                    (body (if letter? body (site-app-unanchored body))))
               (loop (cdr rest) 'group
                     (if (and (null? body) (not label)) acc
                         (cons (site-app-claim (component 'ui/callout
                                                 (append (list 'tone (if letter? "paper" "note") 'body body)
                                                         (if label (list 'label label) '())))
                                               first (max first (b 'count #f #f))
                                               (if letter? (string-append "Email · " lead) lead))
                               acc)))))
            ((equal? tag "c-heading")
             (let* ((count (and next (re-match? "^[0-9]+$" (or (plist-get next 'text) "")) (plist-get next 'text)))
                    (n (b 'line (if count (string-append text " " count) text) href))
                    (block (component 'ui/section (append (list 'title text)
                                                          (if count (list 'count (string->number count)) '())))))
               (loop (if count (cddr rest) (cdr rest)) 'heading (cons (site-app-claim block n n text) acc))))
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
            ((equal? tag "c-list-item")
             (loop (cdr rest) text
                   (cons (site-app-part b 'ui/bullet (string-append "• " text)
                                        (list 'segs (site-app-segs-line text tones href (plist-get node 'link))) href)
                         acc)))
            ((site-app-lead-in? node next)
             ;; a lead-in names the run under it (Strengths:, Skills match): it starts a part
             (let ((lead (site-app-unlabel text)))
               (loop (cdr rest) text (cons (append (site-app-part b 'ui/prose lead (list 'segs (list (list "c-strong" lead))) #f)
                                                   (list 'sa-anchor lead 'sa-lead #t))
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
(define (site-app-head-blocks b data tones tabs active &optional actions)
  (let* ((title (string-append (or (plist-get data 'job) "") " at " (or (plist-get data 'company) "")))
         (state-node (site-app-state-node data))
         (state (and state-node (car (string-split (string-trim (plist-get state-node 'text)) " "))))
         (profile (site-app-kept (plist-get data 'profile)))
         (stars (and (pair? profile) (re-match? "^★+$" (or (plist-get (car profile) 'text) "")) (car profile)))
         (rest (if stars (cdr profile) profile))
         (name (and (pair? rest) (car rest)))
         ;; prose and tags under the facts line: a headline, the specialisations
         (prose? (lambda (n) (member (plist-get n 'tag) (list "c-paragraph" "c-list-item"))))
         (extras (filter prose? (if name (cdr rest) rest)))
         (facts (filter (lambda (n) (and (not (equal? (plist-get n 'tag) "c-action"))
                                         (not (prose? n))
                                         (not (member (plist-get n 'text)
                                                      (list title (and state-node (plist-get state-node 'text)))))))
                        (if name (cdr rest) rest))))
    ;; no breadcrumbs or position: the list beside the page is the navigation
    (append
      ;; a page that is no job's (a candidate) has no title row: its name is the heading
      (if (equal? (or (plist-get data 'job) "") "")
          '()
      (let ((n (b 'line (if state (string-append title "  " state) title) (plist-get data 'job_href))))
        (list (site-app-claim
                (component 'ui/title (append (list 'text title)
                                             (if state (list 'badge state 'tone (or (site-app-tone-class tones state) "")) '())))
                n n title))))
      (if name
          (list (site-app-part b 'ui/title (string-append (if stars (string-append (plist-get stars 'text) "  ") "") (plist-get name 'text))
                               (list 'level 2
                                     'segs (append (if stars (list (list "c-warn" (plist-get stars 'text)) (list "" "  ")) '())
                                                   (list (list "" (plist-get name 'text)))))
                               (plist-get name 'href)))
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
                      (list 'tabs (let loop ((ts tabs) (i 1) (acc '()))
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
                               (or (plist-get b 'sa-anchor)
                                   (null? (site-app-anchors (or (plist-get b 'children) '()))))))
                        blocks))
         (parts (filter past? (map cadr (site-app-anchors blocks))))
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
               (let ((title (string-append (or (site-app-field row 'job) "") " at " (or (site-app-field row 'company) "")))
                     (name (or (site-app-field row 'candidate) "")))
                 (list (site-app-part b 'ui/title title (list 'text title) #f)
                       (site-app-part b 'ui/title name (list 'text name 'level 2) #f)
                       (site-app-part b 'ui/empty "Loading…" (list 'text "Loading…") #f)))
               (let* ((tabs (site-app-detail-tabs buf))
                      (active (site-app-detail-active buf))
                      (section (site-app-detail-section buf active)))
                 (append
                   (site-app-header (site-app-head-blocks b data tones tabs active (site-app-action-bar buf)))
                   (cond ((not section) (list (site-app-part b 'ui/empty "Loading…" (list 'text "Loading…") #f)))
                         ((equal? section 'failed)
                          (let ((t "The site did not answer for this tab. g reads the page again.")) (list (site-app-part b 'ui/empty t (list 'text t) #f))))
                         ((null? (site-app-real section)) (list (site-app-part b 'ui/empty "Nothing here." (list 'text "Nothing here.") #f)))
                         (else (site-app-summary (site-app-node-blocks b (site-app-drop-repeats section data) tones)))))))))
    (let* ((line (car (buffer-line-at-point buf)))
           (text (b 'text #f #f)))
      (buffer-set-text! buf text #t)
      (buffer-goto-line! buf (max 1 (min line (b 'count #f #f))))
      (site-app-set-anchors! buf text blocks))
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
.sa-stars-cell { color: var(--warn-fg); font-size: 11px; letter-spacing: -1px; }
.sa-name-cell { font-weight: 600; color: var(--default-fg); }
.sa-badge-cell { display: flex; align-items: center; }
.sa-pill.c-badge { border-radius: 999px; padding: 0 8px; font-size: 10px; font-weight: 600; letter-spacing: .03em; line-height: 17px; text-transform: lowercase; color: var(--dim-fg); background: var(--hl-line-bg); max-width: 100%; overflow: hidden; text-overflow: ellipsis; }
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
    ;; An app's details share one major mode (ats-detail-mode), so mode affinity
    ;; sends every one of them to the same pane; the page is a minor mode.
    (let ((mode (or (buffer-local buf 'site-app-detail-mode) "site-app-detail-mode")))
      (unless (equal? (buffer-local buf 'mode-name) mode)
        (with-current-buffer buf (lambda () (set-mode! mode)))))
    (site-app-detail-minor! buf)
    (site-app-draw! buf)
    (site-app-join-group! buf)
    buf))








(define (site-app-click-section! tab tab-spec k)
  ;; The spec names the button to press and what the page shows once it is on.
  (tab-press tab (plist-get tab-spec 'click) k (plist-get tab-spec 'wait)))


(define (site-app-navigate! name url wait k)
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
(define (site-app-detail-minor! buf)
  (let ((minor (buffer-local buf 'site-app-detail-minor))
        (spec (site-app-spec (buffer-local buf 'site-app-name))))
    (for-each (lambda (page)
                (let ((m (plist-get page 'detail-minor)))
                  (when (and m (not (equal? m minor)) (minor-mode-on? buf m))
                    (disable-minor-mode! buf m))))
              (if spec (site-app-pages spec) '()))
    (when (and minor (not (minor-mode-on? buf minor)))
      (enable-minor-mode! buf minor))))

(define (site-app-prepare-detail! name row page)
  (let ((buf (site-app-detail-buffer name row)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'site-app-detail-mode (site-app-detail-mode-name (site-app-spec name) page))
    (buffer-set-local! buf 'site-app-detail-minor (plist-get page 'detail-minor))
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

(define (site-app-show-detail! list-buf row)
  (when row
    (let* ((name (plist-get (buffer-local list-buf 'site-app-spec) 'name))
           (spec (site-app-spec name))
           (page (site-app-current-page list-buf))
           (made (site-app-prepare-detail! name row page))
           ;; what this page last read draws at once; a read under a minute old stands
           (cached (buffer-local made 'site-app-data))
           (fresh (and cached (buffer-local made 'site-app-fetched-at)
                       (< (- (monotonic-ms) (buffer-local made 'site-app-fetched-at)) 60000)))
           (buf (site-app-render-detail! name row #f))
           (sheet (plist-get page 'detail-sheet))
           (wait (plist-get page 'detail-wait))
           (url (site-app-url spec (plist-get row 'href)))
           (ids (map (lambda (t) (plist-get t 'id)) (or (plist-get page 'detail-tabs) '())))
           (gen (site-app-next-gen! name)))
      (buffer-set-local! buf 'site-app-list list-buf)
      (unless fresh
        (buffer-set-local! buf 'site-app-gen gen)
        ;; the old read stays on screen until this one's answers replace it
        (unless cached (buffer-set-local! buf 'site-app-sections '()))
        (buffer-set-local! buf 'site-app-data-gen #f))
      (unless (buffer-local buf 'site-app-active)
        (buffer-set-local! buf 'site-app-active (and (pair? ids) (car ids))))
      (display-buffer-detail! buf list-buf)
      (cond
        ((not sheet) #f)
        (fresh #f)
        ((plist-get page 'detail-fetch)
         ;; one plain page with no tabs to press: fetch it, no live tab needed
         (site-app-fetch-html! url
           (lambda (html)
             (let ((data (and html (site-app-parse sheet html))))
               (when (and data (buffer-known? buf) (equal? gen (site-app-gen name)))
                 (site-app-render-detail! name row data))))))
        ((plist-get page 'detail-tab-param)
         (for-each (lambda (id) (site-app-fetch-tab! name buf row url page id gen)) ids)
         (site-app-warm-around! name list-buf row page))
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
                   (site-app-render-detail! name row data)
                   (site-app-collect-detail! name buf tab url wait page gen))))))))
      buf)))

(define (site-app-detail-select! buf id)
  (buffer-set-local! buf 'site-app-active id)
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
            (site-app-fetch-tab! name buf (buffer-local buf 'site-app-row) url page id gen)
            (site-app-navigate! name url wait
              (lambda (tab answer)
                (when answer (site-app-collect-detail! name buf tab url wait page gen)))))))))

(define (site-app-detail-nth! n)
  (let* ((buf (current-buffer)) (tabs (site-app-detail-tabs buf)))
    (when (and (> n 0) (<= n (length tabs)))
      (site-app-detail-select! buf (plist-get (list-ref tabs (- n 1)) 'id)))))

(define (site-app-detail-step! d)
  (let* ((buf (current-buffer))
         (tabs (site-app-detail-tabs buf))
         (active (site-app-detail-active buf))
         (n (length tabs)))
    (when (> n 0)
      (let loop ((ts tabs) (i 0))
        (cond ((null? ts) (site-app-detail-nth! 1))
              ((equal? (plist-get (car ts) 'id) active)
               (site-app-detail-nth! (+ 1 (modulo (+ i d) n))))
              (else (loop (cdr ts) (+ i 1))))))))


;;; --- actions: a key presses the page's own button in the live tab ---------

;; LiveView ignores a click until its socket joins; this is the mark it sets.
(define site-app-live-wait "[data-phx-main].phx-connected")

(define (site-app-live-tab! name url k)
  (site-app-navigate! name url site-app-live-wait
    (lambda (tab answer)
      (if answer (k tab) (begin (message "The site did not open this page") (k #f))))))

(define (site-app-button-selector action)
  (let ((v (plist-get action 'value)))
    (string-append "button[phx-click=\"" (plist-get action 'click) "\"]"
                   (if (and v (not (equal? v ""))) (string-append "[phx-value-id=\"" v "\"]") ""))))

(define (site-app-detail-actions buf)
  (let ((data (buffer-local buf 'site-app-data)))
    (if data
        (filter (lambda (n) (plist-get n 'click))
                (append (site-app-real (plist-get data 'actions)) (site-app-real (plist-get data 'profile))))
        '())))

;; after an action: read the page and the list again, the way the site redraws
(define (site-app-detail-after! buf note)
  (message note)
  (let* ((list-buf (buffer-local buf 'site-app-list))
         (name (buffer-local buf 'site-app-name)))
    (when (buffer-known? buf)
      (site-app-show-detail! list-buf (buffer-local buf 'site-app-row)))
    (site-app-read-page! name (site-app-current-page list-buf))))

;; A key finds the button that carries it. The page spec's 'detail-actions maps a
;; button's event to a handler for the buttons that open a form; a handler gets
;; ('buf 'action 'selector 'live 'done). Any other button is pressed as it is.
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
               (page (site-app-current-page (buffer-local buf 'site-app-list)))
               (url (site-app-url spec (plist-get (buffer-local buf 'site-app-row) 'href)))
               (hit (assoc (plist-get action 'click) (or (plist-get page 'detail-actions) '())))
               (label (site-app-without-key (or (plist-get action 'text) "")))
               (selector (site-app-button-selector action))
               (live (lambda (k) (site-app-live-tab! name url k)))
               (done (lambda (note) (site-app-detail-after! buf note))))
          (if hit
              ((cadr hit) (list 'buf buf 'action action 'selector selector 'live live 'done done))
              (begin
                (message (string-append label "…"))
                (live (lambda (tab)
                        (when tab
                          (tab-press tab selector
                            (lambda (html)
                              (done (if html (string-append label ": done")
                                        (string-append label ": the site did not answer")))))))))))))))

(define site-app-action-letters
  '("a" "b" "c" "d" "e" "f" "h" "i" "j" "k" "l" "m" "n" "p" "r" "s" "t" "u" "v" "w" "x" "y" "z"))

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
  ;; the page's minor mode holds its button keys, else its major mode does
  (let* ((minor (buffer-local buf 'site-app-detail-minor))
         (mode (or minor (buffer-local buf 'site-app-detail-mode)))
         (keys (map (lambda (k) (list (car k) (string-append "site-app-detail-key-" (car k))))
                    (site-app-detail-action-keys buf))))
    (when mode
      (if minor (minor-mode-keys! minor keys) (mode-keys! mode keys))
      ;; the index answers the page's button keys too, where it has none of its own
      (when (boundp 'app-detail-keys!)
        (let ((name (buffer-local buf 'site-app-name)))
          (for-each (lambda (page) (app-detail-keys! (site-app-page-mode name (plist-get page 'id)) mode))
                    (site-app-pages (site-app-spec name))))))))

(define-command "site-app-detail-tab-1" "Show this page's first tab" (lambda () (site-app-detail-nth! 1)))
(define-command "site-app-detail-tab-2" "Show this page's second tab" (lambda () (site-app-detail-nth! 2)))
(define-command "site-app-detail-tab-3" "Show this page's third tab" (lambda () (site-app-detail-nth! 3)))
(define-command "site-app-detail-tab-4" "Show this page's fourth tab" (lambda () (site-app-detail-nth! 4)))
(define-command "site-app-detail-tab-5" "Show this page's fifth tab" (lambda () (site-app-detail-nth! 5)))
(define-command "site-app-detail-next-tab" "Show this page's next tab" (lambda () (site-app-detail-step! 1)))
(define-command "site-app-detail-prev-tab" "Show this page's previous tab" (lambda () (site-app-detail-step! -1)))
(define-command "site-app-detail-fold" "Fold or unfold the card at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (a (anchor-at buf (buffer-point buf)))
           (fold (and a (plist-get (or (anchor-data a) '()) 'fold))))
      (if (not fold)
          (message "No card here")
          (let ((title (car fold)) (open? (cadr fold)))
            (buffer-set-local! buf 'site-app-folds
              (cons (list title (not open?))
                    (filter (lambda (f) (not (equal? (car f) title))) (or (buffer-local buf 'site-app-folds) '()))))
            (site-app-draw! buf)
            ;; point stays on the card's title
            (let ((back (anchor-find buf (anchor-name a))))
              (when back (goto-char! (anchor-start back)) (anchor-sync! buf))))))))

;; a card's own keys, in force while point is on it
(define-keymap! "site-app-card-map")
(define-key "site-app-card-map" "f" "site-app-detail-fold")

(define-command "site-app-detail-follow" "Open the link at point on the site"
  (lambda ()
    (let* ((buf (current-buffer)) (hit (site-app-detail-link-at buf)))
      (if hit
          (tab-open (site-app-url (site-app-spec (buffer-local buf 'site-app-name)) (caddr hit)))
          (message "No link here")))))
(define-command "site-app-detail-reload" "Read this page again from the site"
  (lambda ()
    (let ((buf (current-buffer)))
      (site-app-show-detail! (buffer-local buf 'site-app-list) (buffer-local buf 'site-app-row)))))
(define-command "site-app-detail-open" "Open this page on the site"
  (lambda ()
    (let ((buf (current-buffer)))
      (tab-open (site-app-url (site-app-spec (buffer-local buf 'site-app-name))
                              (plist-get (buffer-local buf 'site-app-row) 'href))))))

(mode-keys! "site-app-detail-mode"
  (list (list "TAB" "site-app-detail-next-tab")
        (list "S-TAB" "site-app-detail-prev-tab")
        (list "<down>" "site-app-detail-next")
        (list "<up>" "site-app-detail-prev")
        (list "1" "site-app-detail-tab-1")
        (list "2" "site-app-detail-tab-2")
        (list "3" "site-app-detail-tab-3")
        (list "4" "site-app-detail-tab-4")
        (list "5" "site-app-detail-tab-5")
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

(define (define-site-app spec)
  (let* ((name (plist-get spec 'name))
         (title (or (plist-get spec 'title) (symbol->string name)))
         (pages (site-app-pages spec)))
    (site-app-put! name spec)
    (let ((major (plist-get spec 'detail-mode)))
      (when major
        (define-mode major (lambda () (buffer-set-read-only! (current-buffer) #t)))
        (mode-parent! major "site-app-detail-mode")))
    (for-each (lambda (page)
                (let ((mode (plist-get page 'detail-mode))
                      (minor (plist-get page 'detail-minor)))
                  (when mode
                    (define-mode mode (lambda () (buffer-set-read-only! (current-buffer) #t)))
                    (mode-parent! mode "site-app-detail-mode"))
                  (when minor
                    (register-minor-mode! minor (lambda (buf) #t) (lambda (buf) #t))
                    ;; the map exists before a buffer turns the mode on; keys land in it later
                    (minor-mode-keys! minor '()))))
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
                  'footer (lambda (b) (list (list "M-1–9" "sections") (list "[ ]" "status") (list "1–5" "page tabs") (list "M-↑↓" "page parts")
                                            (list "/" "state") (list "g" "refresh") (list "q" "quit")))
                  ;; Digits are left free so they reach the page beside the list, as
                  ;; its tab keys; the sections move to M-digit.
                  'keys (append (list (list "RET" "site-app-detail")
                                      (list "[" "site-app-filter-prev")
                                      (list "]" "site-app-filter-next")
                                      (list "g" "site-app-refresh")
                                      ;; the page beside the list, part by part, without leaving the row
                                      (list "M-<down>" "site-app-detail-anchor-next")
                                      (list "M-<up>" "site-app-detail-anchor-prev")
                                      (list "q" "quit-window"))
                                (map (lambda (p) (list (string-append "M-" (plist-get p 'key))
                                                       (string-append "site-app-tab-" (plist-get p 'key))))
                                     pages))))
          ;; / asks for a status tab; the list mode's own row filter stays on f
          (define-key (mode-keymap mode) "/" "site-app-filter-choose")
          ;; The index keeps its own bindings; unclaimed detail-page keys run in the
          ;; adjacent detail, just as they do when focus is on the detail itself.
          (when (boundp 'app-detail-keys!)
            (app-detail-keys! mode "site-app-detail-mode"))
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
