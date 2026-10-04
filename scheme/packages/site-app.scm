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
  (if query
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
      (if (null? filters)
          '()
          (list (component 'ui/tabs
                  (list 'class "sa-status"
                        'tabs (map (lambda (tab)
                                     (let ((count (plist-get tab 'count)))
                                       (list (string-append site-app-status-click (plist-get tab 'query))
                                             (if (equal? count "") (plist-get tab 'label)
                                                 (string-append (plist-get tab 'label) " " count))
                                             (site-app-filter-on? tab query))))
                                   filters))))))))

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
          'children (map (lambda (col)
                           (list 'tag "span"
                                 'class (if (plist-get col 'face) (string-append "sa-cell c-" (plist-get col 'face)) "sa-cell")
                                 'text (or (site-app-field row (plist-get col 'field)) "")))
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
         (sheet (plist-get (site-app-spec name) 'tabs-sheet))
         (tabs (or (and sheet (site-app-parse sheet html)) '()))
         (on (and (pair? tabs) (site-app-find (lambda (t) (equal? (plist-get t 'active) "yes")) tabs))))
    (if (not (or (pair? rows) (null? rows)))
        (message (string-append (symbol->string name) ": stylesheet did not return rows"))
        (begin
          (buffer-set-local! buf 'site-app-page (plist-get page 'id))
          (buffer-set-local! buf 'site-app-rows rows)
          (buffer-set-local! buf 'site-app-filters (if (pair? tabs) tabs '()))
          ;; the page says which of its tabs it drew; that is the one we are on
          (when on (buffer-set-local! buf 'site-app-filter (plist-get on 'query)))
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
            (list (list "TAB" "next tab")
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

(define (site-app-detail-put-section! buf id nodes)
  (when (buffer-known? buf)
    (buffer-set-local! buf 'site-app-sections
      (cons (cons id (if (equal? nodes 'failed) 'failed (or nodes '())))
            (filter (lambda (e) (not (equal? (car e) id)))
                    (or (buffer-local buf 'site-app-sections) '()))))
    (site-app-draw! buf)))


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

;; a word's tone as a class: the spec's 'tones ((REGEX KIND) ...) and gold stars
(define (site-app-tone-class tones word)
  (if (re-match? "^★+$" word)
      "sa-stars"
      (let loop ((ts (or tones '())))
        (cond ((null? ts) #f)
              ((re-match? (car (car ts)) word) (string-append "sa-" (symbol->string (cadr (car ts)))))
              (else (loop (cdr ts)))))))

(define (site-app-toned-segs text base tones)
  (let loop ((words (string-split text " ")) (acc '()) (first #t))
    (if (null? words)
        (reverse acc)
        (let ((acc (if first acc (cons (list base " ") acc))))
          (loop (cdr words)
                (cons (list (or (site-app-tone-class tones (car words)) base) (car words)) acc)
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

(define (site-app-claim block first last)
  ;; the anchor is what makes the renderer mark the block data-current, and
  ;; the view scrolls to follow that mark
  (append block (list 'lines (list first last) 'mark "current"
                      'anchor (string-append "sa-" (number->string first)))))

(define (site-app-click-props href)
  (if href (list 'click (string-append site-app-link-click href)) '()))

(define (site-app-row-block b text segs class href)
  (let ((n (b 'line text href)))
    (append (component 'ui/row (append (list 'segs segs 'class class 'lines (list n n) 'mark "current")
                                       (site-app-click-props href)))
            (list 'anchor (string-append "sa-" (number->string n))))))

(define (site-app-text-block b class text href)
  (let ((n (b 'line text href)))
    (site-app-claim (append (list 'tag "div" 'class class 'text text) (site-app-click-props href)) n n)))

(define (site-app-kept nodes)
  (filter (lambda (n) (not (site-app-ornament? (or (plist-get n 'text) "")))) (site-app-real nodes)))

;; One section's records as components: a card per item, a section per heading,
;; one row per run of short facts, badges for tags, a bar for quoted text.
(define (site-app-node-blocks b nodes tones)
  (let loop ((rest (site-app-kept nodes)) (prev #f) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let* ((node (car rest))
               (tag (plist-get node 'tag))
               (text (or (plist-get node 'text) ""))
               (href (plist-get node 'href))
               (next (and (pair? (cdr rest)) (cadr rest))))
          (cond
            ((equal? tag "c-item")
             (let ((kids (site-app-kept (plist-get node 'children))))
               (if (null? kids)
                   (loop (cdr rest) prev acc)
                   (let* ((title (site-app-unlabel (or (plist-get (car kids) 'text) "")))
                          (first (b 'line title (plist-get (car kids) 'href)))
                          (body (site-app-node-blocks b (cdr kids) tones))
                          (card (component 'ui/card (list 'title title 'open? #t 'body body
                                                           ;; a sheet may name the kind of card, for its own look
                                                           'class (let ((kind (plist-get node 'class)))
                                                                    (if kind (string-append "sa-card " kind) "sa-card"))))))
                     (loop (cdr rest) 'item (cons (site-app-claim card first (max first (b 'count #f #f))) acc))))))
            ((equal? tag "c-heading")
             (let* ((count (and next (re-match? "^[0-9]+$" (or (plist-get next 'text) "")) (plist-get next 'text)))
                    (n (b 'line (if count (string-append text " " count) text) href))
                    (block (component 'ui/section (append (list 'title text 'class "sa-section")
                                                          (if count (list 'count (string->number count)) '())))))
               (loop (if count (cddr rest) (cdr rest)) 'heading (cons (site-app-claim block n n) acc))))
            ((and (site-app-short-field? node) next (site-app-short-field? next))
             (let* ((run (site-app-take-while site-app-short-field? rest))
                    (texts (map (lambda (x) (let ((t (string-trim (plist-get x 'text))))
                                              (if (re-match? "^· " t) (substring t 2 (string-length t)) t)))
                                run))
                    (segs (let join ((ts texts) (acc '()) (first #t))
                            (if (null? ts) acc
                                (join (cdr ts)
                                      (append acc (if first '() (list (list "sa-sep" "  ·  ")))
                                              (site-app-toned-segs (car ts) "sa-fact" tones))
                                      #f)))))
               (loop (list-tail rest (length run)) 'facts
                     (cons (site-app-row-block b (string-join texts " · ") segs "sa-facts" #f) acc))))
            ((and (site-app-chip? node) next (site-app-chip? next))
             (let* ((run (site-app-take-while site-app-chip? rest))
                    (texts (map (lambda (x) (plist-get x 'text)) run))
                    (n (b 'line (string-join texts "  ") #f)))
               (loop (list-tail rest (length run)) 'chips
                     (cons (site-app-claim (list 'tag "div" 'class "sa-chips"
                                                 'children (map (lambda (t) (component 'ui/badge (list 'text t 'class "sa-chip"))) texts))
                                           n n)
                           acc))))
            ((or (equal? text prev) (equal? tag "c-action")) (loop (cdr rest) prev acc))
            ((equal? tag "c-quote")
             (let* ((lines (site-app-quote-lines text))
                    (first (+ 1 (b 'count #f #f))))
               (for-each (lambda (l) (b 'line l #f)) lines)
               (loop (cdr rest) 'quote
                     (cons (site-app-claim (list 'tag "div" 'class "sa-quote" 'text (string-join lines "\n"))
                                           first (max first (b 'count #f #f)))
                           acc))))
            ((equal? tag "c-list-item")
             (loop (cdr rest) text
                   (cons (site-app-row-block b (string-append "• " text)
                                             (cons (list "sa-bullet" "•") (cons (list "" " ") (site-app-toned-segs text "" tones)))
                                             "sa-li" href)
                         acc)))
            ((and (equal? tag "c-paragraph") (re-match? ":\\s*$" text))
             (loop (cdr rest) text (cons (site-app-text-block b "sa-sub" (site-app-unlabel text) #f) acc)))
            ((equal? tag "c-paragraph")
             (loop (cdr rest) 'paragraph (cons (site-app-text-block b (if href "sa-p sa-link" "sa-p") text href) acc)))
            (else
             (loop (cdr rest) text
                   (cons (site-app-row-block b text
                                             (if (or href (equal? tag "c-link")) (list (list "sa-link" text))
                                                 (site-app-toned-segs text "" tones))
                                             "sa-field" href)
                         acc))))))))

;; The header, in the page's order: breadcrumbs, the title with where the item
;; stands, the candidate, their facts, and the tabs.
(define (site-app-head-blocks b data tones tabs active)
  (let* ((position (or (plist-get data 'position) ""))
         (title (string-append (or (plist-get data 'job) "") " at " (or (plist-get data 'company) "")))
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
    (append
      (list (site-app-row-block b (string-append (or (plist-get data 'title) "") "   " position)
                                (list (list "sa-crumbs" (or (plist-get data 'title) ""))
                                      (list "sa-position" position))
                                "sa-crumb-row" #f))
      ;; a page that is no job's (a candidate) has no title row: its name is the heading
      (if (equal? (or (plist-get data 'job) "") "")
          '()
      (let ((n (b 'line (if state (string-append title "  " state) title) (plist-get data 'job_href))))
        (list (site-app-claim
                (list 'tag "div" 'class "sa-title"
                      'children (append (list (list 'tag "span" 'class "sa-title-text" 'text title))
                                        (if state
                                            (list (component 'ui/badge (list 'text state 'class
                                                    (string-append "sa-state " (or (site-app-tone-class tones state) "")))))
                                            '())))
                n n))))
      (if name
          (list (site-app-row-block b (string-append (if stars (string-append (plist-get stars 'text) "  ") "") (plist-get name 'text))
                                    (append (if stars (list (list "sa-stars" (plist-get stars 'text)) (list "" "  ")) '())
                                            (list (list "sa-name" (plist-get name 'text))))
                                    "sa-candidate" (plist-get name 'href)))
          '())
      (if (null? facts)
          '()
          (let* ((texts (map (lambda (n) (plist-get n 'text)) facts))
                 (segs (let join ((ts texts) (acc '()) (first #t))
                         (if (null? ts) acc
                             (join (cdr ts)
                                   (append acc (if first '() (list (list "sa-sep" "  ·  ")))
                                           (site-app-toned-segs (car ts) "sa-fact" tones))
                                   #f)))))
            (list (site-app-row-block b (string-join texts " · ") segs "sa-facts" #f))))
      (site-app-node-blocks b extras tones)
      (if (null? tabs)
          '()
          (let ((n (b 'line (string-join (map (lambda (t) (site-app-capitalize (plist-get t 'label))) tabs) "   ") #f)))
            (list (site-app-claim
                    (component 'ui/tabs
                      (list 'class "sa-tabs"
                            'tabs (let loop ((ts tabs) (i 1) (acc '()))
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
  (let loop ((bs blocks) (past-tabs #f) (acc (list 1)))
    (if (null? bs)
        (reverse acc)
        (let* ((block (car bs))
               (class (or (plist-get block 'class) ""))
               (lines (plist-get block 'lines)))
          (cond ((re-match? "\\bsa-tabs\\b" class) (loop (cdr bs) #t acc))
                ((or (not past-tabs) (not lines) (re-match? "\\bsa-section\\b" class))
                 (loop (cdr bs) past-tabs acc))
                (else (loop (cdr bs) past-tabs
                            (if (member (car lines) acc) acc (cons (car lines) acc)))))))))

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
          (else (previous-line!)))))

(define-command "site-app-detail-next" "Go to the next piece of this page"
  (lambda () (site-app-detail-stop! 1)))
(define-command "site-app-detail-prev" "Go to the previous piece of this page"
  (lambda () (site-app-detail-stop! -1)))

(define (site-app-draw! buf)
  (let* ((data (buffer-local buf 'site-app-data))
         (row (buffer-local buf 'site-app-row))
         (spec (site-app-spec (buffer-local buf 'site-app-name)))
         (tones (and spec (plist-get spec 'tones)))
         (b (site-app-builder))
         (blocks
           (if (not data)
               (list (site-app-text-block b "sa-title-text"
                                          (string-append (or (site-app-field row 'job) "") " at " (or (site-app-field row 'company) "")) #f)
                     (site-app-text-block b "sa-name" (or (site-app-field row 'candidate) "") #f)
                     (site-app-text-block b "sa-loading" "Loading…" #f))
               (let* ((tabs (site-app-detail-tabs buf))
                      (active (site-app-detail-active buf))
                      (section (site-app-detail-section buf active)))
                 (append
                   (site-app-head-blocks b data tones tabs active)
                   (cond ((not section) (list (site-app-text-block b "sa-loading" "Loading…" #f)))
                         ((equal? section 'failed)
                          (list (site-app-text-block b "sa-loading" "The site did not answer for this tab. g reads the page again." #f)))
                         ((null? (site-app-real section)) (list (site-app-text-block b "sa-loading" "Nothing here." #f)))
                         (else (site-app-node-blocks b (site-app-drop-repeats section data) tones))))))))
    (let* ((line (car (buffer-line-at-point buf)))
           (text (b 'text #f #f)))
      (buffer-set-text! buf text #t)
      (buffer-goto-line! buf (max 1 (min line (b 'count #f #f)))))
    (buffer-set-local! buf 'site-app-links (b 'links #f #f))
    (buffer-set-local! buf 'site-app-stops (site-app-stops blocks))
    (buffer-set-locals! buf
      (list 'render-mode "blocks"
            'render-blocks (list (list 'tag "div" 'class "sa-page" 'children blocks))))
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
          ((string-prefix? site-app-link-click id)
           (tab-open (site-app-url (site-app-spec (buffer-local buf 'site-app-name))
                                   (substring id (string-length site-app-link-click) (string-length id))))
           #t)
          (else #f))))

(define-style! 'site-app "
.sa-page { padding: 6px 4px 24px; line-height: 1.45; font-size: 12px; }
.sa-row { display: grid; column-gap: 1ch; container-type: inline-size; }
.sa-row > .sa-cell { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
@container (max-width: 60ch) { .sa-need-60 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 70ch) { .sa-need-70 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 80ch) { .sa-need-80 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 90ch) { .sa-need-90 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 100ch) { .sa-need-100 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 110ch) { .sa-need-110 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 120ch) { .sa-need-120 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 130ch) { .sa-need-130 > .sa-cell:last-child { grid-column: 1 / -1; } }
@container (max-width: 140ch) { .sa-need-140 > .sa-cell:last-child { grid-column: 1 / -1; } }
.sa-page .c-tab, .sa-page .c-section { font-size: 10.5px; }
.sa-page .c-badge { font-size: 9.5px; }
.sa-crumb-row { padding: 0; font-size: 10.5px; }
.sa-crumbs, .sa-position { color: var(--dim-fg); font-family: var(--font-mono); }
.sa-position { margin-left: 12px; }
.sa-title { display: flex; align-items: baseline; gap: 10px; margin: 4px 0 2px; }
.sa-title-text { font-family: ui-serif, Georgia, 'Times New Roman', serif; font-size: 19px; font-weight: 700; color: var(--fg); }
.sa-state { font-family: var(--font-mono); font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; }
.sa-candidate { padding: 0; font-size: 13px; }
.sa-name { font-family: ui-serif, Georgia, serif; font-weight: 700; color: var(--fg); }
.sa-stars { color: #e0af68; }
.sa-facts { padding: 0; font-size: 11.5px; color: var(--dim-fg); }
.sa-sep { color: var(--border-bg); }
.sa-tabs { margin-top: 8px; }
.sa-good { color: var(--success-fg, #4f9a61); font-weight: 600; }
.sa-bad { color: var(--error-fg, #c9544d); font-weight: 600; }
.sa-warn { color: var(--warning-fg, #c28a2e); font-weight: 600; }
.sa-info { color: var(--accent-fg); font-weight: 600; }
.c-badge.sa-good { background: rgba(79,154,97,.16); }
.c-badge.sa-bad { background: rgba(201,84,77,.16); }
.c-badge.sa-warn { background: rgba(194,138,46,.16); }
.c-badge.sa-info { background: rgba(122,162,247,.16); }
.sa-card { margin: 0 0 8px; }
.sa-job .c-caret { display: none; }
.sa-job .c-fold-head { background: transparent; }
.sa-job.current { background: var(--hl-line-bg); }
.sa-job .c-fold-title { font-family: ui-serif, Georgia, serif; font-size: 14px; font-weight: 700; color: var(--fg); }
.sa-job .sa-facts .sa-fact:nth-child(-n+3) { color: var(--accent-fg); font-weight: 600; }
.sa-card > :not(.c-fold-head) { padding-left: 12px; padding-right: 12px; }
.sa-section { margin-top: 6px; }
.sa-field, .sa-li { padding: 1px 0; }
.sa-bullet { color: var(--accent-fg); }
.sa-p { margin: 2px 0 6px; }
.sa-sub { font-weight: 700; margin-top: 6px; }
.sa-link { color: var(--accent-fg); cursor: pointer; }
.sa-quote { border-left: 2px solid var(--accent-fg); padding: 2px 10px; margin: 4px 0 8px; white-space: pre-wrap; }
.sa-chips { display: flex; flex-wrap: wrap; gap: 4px; margin: 4px 0; }
.sa-loading { color: var(--dim-fg); padding: 8px 0; }
.sa-page .current:not(.c-card):not(.sa-title) { background: var(--hl-line-bg); }
")

(define (site-app-render-detail! name row data)
  (let ((buf (site-app-detail-buffer name row)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'site-app-name name)
    (buffer-set-local! buf 'site-app-row row)
    (when data (buffer-set-local! buf 'site-app-data data))
    ;; A page's details share one major mode of their own (ats-approval-mode),
    ;; so mode affinity sends every one of them to the same pane.
    (let ((mode (or (buffer-local buf 'site-app-detail-mode) "site-app-detail-mode")))
      (unless (equal? (buffer-local buf 'mode-name) mode)
        (with-current-buffer buf (lambda () (set-mode! mode)))))
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

(define (site-app-detail-mode-name page)
  (or (plist-get page 'detail-mode) "site-app-detail-mode"))

(define (site-app-prepare-detail! name row page)
  (let ((buf (site-app-detail-buffer name row)))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-local! buf 'site-app-detail-mode (site-app-detail-mode-name page))
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
  (let* ((sheet (plist-get page 'detail-sheet))
         (tab-url (site-app-with-param url (plist-get page 'detail-tab-param) id))
         (file! (lambda (html)
                  (when (and (buffer-known? buf) (equal? gen (site-app-gen name)))
                    (let ((data (and html (site-app-parse sheet html))))
                      (when (and data (not (equal? (buffer-local buf 'site-app-data-gen) gen)))
                        (buffer-set-local! buf 'site-app-data-gen gen)
                        (site-app-render-detail! name row data))
                      (site-app-detail-put-section! buf id
                        (if data (plist-get data 'section) 'failed)))))))
    (site-app-fetch-html! tab-url
      (lambda (html)
        (if html (file! html) (site-app-fetch-html! tab-url file!))))))

(define (site-app-show-detail! list-buf row)
  (when row
    (let* ((name (plist-get (buffer-local list-buf 'site-app-spec) 'name))
           (spec (site-app-spec name))
           (page (site-app-current-page list-buf))
           (made (site-app-prepare-detail! name row page))
           (buf (site-app-render-detail! name row #f))
           (sheet (plist-get page 'detail-sheet))
           (wait (plist-get page 'detail-wait))
           (url (site-app-url spec (plist-get row 'href)))
           (ids (map (lambda (t) (plist-get t 'id)) (or (plist-get page 'detail-tabs) '())))
           (gen (site-app-next-gen! name)))
      (buffer-set-local! buf 'site-app-list list-buf)
      (buffer-set-local! buf 'site-app-gen gen)
      (buffer-set-local! buf 'site-app-sections '())
      ;; a fresh read: this page's data is stale until an answer of this read lands
      (buffer-set-local! buf 'site-app-data-gen #f)
      (unless (buffer-local buf 'site-app-active)
        (buffer-set-local! buf 'site-app-active (and (pair? ids) (car ids))))
      (display-buffer-detail! buf list-buf)
      (cond
        ((not sheet) #f)
        ((plist-get page 'detail-fetch)
         ;; one plain page with no tabs to press: fetch it, no live tab needed
         (site-app-fetch-html! url
           (lambda (html)
             (let ((data (and html (site-app-parse sheet html))))
               (when (and data (buffer-known? buf) (equal? gen (site-app-gen name)))
                 (site-app-render-detail! name row data))))))
        ((plist-get page 'detail-tab-param)
         (for-each (lambda (id) (site-app-fetch-tab! name buf row url page id gen)) ids))
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
         (action (and (assoc key (site-app-detail-action-keys buf))
                      (site-app-find (lambda (a) (equal? (plist-get a 'key) key)) (site-app-detail-actions buf)))))
    (if (not action)
        (message (string-append "No action on " key " here"))
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
                                        (string-append label ": the site did not answer"))))))))))))))

(define site-app-action-letters
  '("a" "b" "c" "d" "e" "f" "h" "i" "j" "k" "l" "m" "n" "p" "r" "s" "t" "u" "v" "w" "x" "y" "z"))

(for-each (lambda (k)
            (define-command (string-append "site-app-detail-key-" k)
              (string-append "Press this page's button on " k)
              (lambda () (site-app-detail-act! k))))
          site-app-action-letters)

;; the page's buttons with keys: bound in its mode and listed in its keys bar
(define (site-app-detail-action-keys buf)
  ;; the page spec's 'detail-keys names the buttons the app presses; the rest
  ;; are done on the site itself, which o opens
  (let* ((list-buf (buffer-local buf 'site-app-list))
         (page (and list-buf (site-app-current-page list-buf)))
         (allowed (and page (plist-get page 'detail-keys))))
    (filter (lambda (k) (and (member (car k) site-app-action-letters)
                             (or (not allowed) (member (car k) allowed))))
            (map (lambda (a) (list (plist-get a 'key) (string-downcase (site-app-without-key (plist-get a 'text)))))
                 (filter (lambda (a) (let ((k (plist-get a 'key))) (and k (not (equal? k "")))))
                         (site-app-detail-actions buf))))))

(define (site-app-bind-action-keys! buf)
  (let ((mode (buffer-local buf 'site-app-detail-mode)))
    (when mode
      (mode-keys! mode (map (lambda (k) (list (car k) (string-append "site-app-detail-key-" (car k))))
                            (site-app-detail-action-keys buf)))
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

(define-command "site-app-detail" "Open the item on this website app row"
  (lambda ()
    (let ((buf (current-buffer)))
      (site-app-show-detail! buf (list-current buf)))))

(define (define-site-app spec)
  (let* ((name (plist-get spec 'name))
         (title (or (plist-get spec 'title) (symbol->string name)))
         (pages (site-app-pages spec)))
    (site-app-put! name spec)
    (for-each (lambda (page)
                (let ((mode (plist-get page 'detail-mode)))
                  (when mode
                    (define-mode mode (lambda () (buffer-set-read-only! (current-buffer) #t)))
                    (mode-parent! mode "site-app-detail-mode"))))
              pages)
    ;; Every section is an index of its own: its buffer, its mode, its command.
    (for-each
      (lambda (page)
        (let* ((id (plist-get page 'id))
               (mode (site-app-page-mode name id))
               (command (string-append (symbol->string name) "-" (symbol->string id))))
          (define-list-mode! mode
            (list 'doc (string-append title " " (plist-get page 'label)
                                      ", read from the live site. M-number keys switch sections, [ and ] walk the status tabs, number keys switch the tabs of the page beside the list, / filters rows, g rereads, q quits.")
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
                  'footer (lambda (b) (list (list "M-1–9" "sections") (list "[ ]" "status") (list "1–5" "page tabs")
                                            (list "/" "filter") (list "g" "refresh") (list "q" "quit")))
                  ;; Digits are left free so they reach the page beside the list, as
                  ;; its tab keys; the sections move to M-digit.
                  'keys (append (list (list "RET" "site-app-detail")
                                      (list "[" "site-app-filter-prev")
                                      (list "]" "site-app-filter-next")
                                      (list "g" "site-app-refresh")
                                      (list "q" "quit-window"))
                                (map (lambda (p) (list (string-append "M-" (plist-get p 'key))
                                                       (string-append "site-app-tab-" (plist-get p 'key))))
                                     pages))))
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
