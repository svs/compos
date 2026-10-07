;;; amazon.scm --- the storefront as an app: a listing, a page per row.
;;;
;;; Amazon is a website, but a website is a poor place to compare eight
;;; things. The listing is a table you walk with n and p; every row you
;;; land on renders as its own buffer beside it, so C-` flips between the
;;; three you are actually choosing between without going back to the list.
;;;
;;; The app reads the signed-in session through a background tab, which
;;; carries the browser's cookies, so the prices here are the account's own
;;; and so are the delivery promises. Nothing is read from a logged-out page.
;;;
;;; Rows come from web/parsers/amazon-rows.xsl through xslt-apply: the sheet
;;; parses, and no line in this file reads markup. It anchors on
;;; puis-card-container, which is products only -- Amazon marks its ad
;;; carousels s-result-item too, and anchoring there pulls them into the
;;; listing as if they were things you had searched for.
;;;
;;; The app opens where you already are: the listing and every product page
;;; join the group the frame is in, so that group saves the layout and
;;; gives it back. Actions that leave the editor -- the cart -- are the
;;; reader pressing a button, never a render.

(domain! 'web)
(effects! '(read))

(defcustom 'amazon-host "www.amazon.in"
  "The Amazon storefront the app reads. Change it to shop another country's site."
  'group 'amazon)

(defcustom 'amazon-default-query "scientific calculator"
  "The search the app opens with the first time, before you have run one."
  'group 'amazon)

;; How many times the app looks for the search page before giving up. Each look is 400ms.

(define *amazon-buffer* "*amazon*")
(define *amazon-log* "*amazon-log*")

;;; --- reading the page ----------------------------------------------------
;;; The reader hands us Markdown, not HTML: one blank-line-separated
;;; paragraph per thing the page says. A result begins at its photo and ends
;;; at the next one, so the whole parser is a walk over paragraphs.

(define (amz-after s sub) (let ((p (string-split s sub))) (if (pair? (cdr p)) (car (cdr p)) #f)))
(define (amz-before s sub) (car (string-split s sub)))
(define (amz-has? s sub) (pair? (cdr (string-split s sub))))
(define (amz-clip s n) (if (> (string-length s) n) (substring s 0 n) s))

(define (amz-replace s from to)
  (let ((ps (string-split s from)))
    (let loop ((l (cdr ps)) (acc (car ps)))
      (if (null? l) acc (loop (cdr l) (string-append acc to (car l)))))))

(define (amz-clean s) (amz-replace (amz-replace s "\\|" "|") "  " " "))

;; when it lands. The page writes "Sun, 20 Sept", "23 - 25 Sept" or
;; "Tomorrow 6 am - 10 am", and never a year.
(define *amz-months*
  '(("Jan" 1) ("Feb" 2) ("Mar" 3) ("Apr" 4) ("May" 5) ("Jun" 6)
    ("Jul" 7) ("Aug" 8) ("Sep" 9) ("Oct" 10) ("Nov" 11) ("Dec" 12)))

(define (amz-day s)
  (let ((n (string->number s)))
    (and (number? n) (not (amz-has? s ".")) (equal? (number->string n) s)
         (>= n 1) (<= n 31) n)))

(define (amz-month tok)
  (let loop ((ms *amz-months*))
    (cond ((null? ms) #f)
          ((and (>= (string-length tok) 3)
                (equal? (substring tok 0 3) (car (car ms))))
           (car (cdr (car ms))))
          (else (loop (cdr ms))))))

(define (amz-month-name n)
  (let loop ((ms *amz-months*))
    (cond ((null? ms) "")
          ((equal? n (car (cdr (car ms)))) (car (car ms)))
          (else (loop (cdr ms))))))

(define (amz-today) (string->number (format-time (current-time) "%Y%m%d")))
(define (amz-tomorrow) (string->number (format-time (+ (current-time) 86400) "%Y%m%d")))

;; the day it lands as YYYYMMDD; a range counts from its first day and an
;; unreadable line sorts last
(define (amz-delivery-key text)
  (if (not (string? text))
      99999999
      (let ((dated (let loop ((ts (string-split (amz-replace text "," " ") " ")) (day #f))
                     (cond ((null? ts) #f)
                           ((and day (amz-month (car ts))) (list day (amz-month (car ts))))
                           ((and (not day) (amz-day (car ts))) (loop (cdr ts) (amz-day (car ts))))
                           (else (loop (cdr ts) day))))))
        (cond (dated
               (let* ((mon (car (cdr dated)))
                      (now (amz-today))
                      (year (quotient now 10000)))
                 ;; no year on the page, so a month behind us is next year's
                 (+ (* 10000 (if (< mon (modulo (quotient now 100) 100)) (+ year 1) year))
                    (* 100 mon) (car dated))))
              ((amz-has? text "Tomorrow") (amz-tomorrow))
              ((amz-has? text "Today") (amz-today))
              (else 99999999)))))

(define (amz-delivery-label text)
  (let ((k (amz-delivery-key text)))
    (cond ((>= k 99999999) "—")
          ((equal? k (amz-today)) "today")
          ((equal? k (amz-tomorrow)) "tomorrow")
          (else (string-append (number->string (modulo k 100)) " "
                               (amz-month-name (modulo (quotient k 100) 100)))))))

;; soonest first, stable, so one day's products keep the order Amazon gave them
(define (amz-sort-by-delivery rows)
  (let* ((keyed (map (lambda (r) (list (amz-delivery-key (plist-get r 'delivery)) r)) rows))
         (sorted (let ins-all ((ks keyed) (acc '()))
                   (if (null? ks)
                       acc
                       (ins-all (cdr ks)
                                (let place ((xs acc) (out '()))
                                  (cond ((null? xs) (reverse (cons (car ks) out)))
                                        ((< (car (car ks)) (car (car xs)))
                                         (append (reverse out) (cons (car ks) xs)))
                                        (else (place (cdr xs) (cons (car xs) out))))))))))
    (map (lambda (p) (car (cdr p))) sorted)))

;;; --- the group -----------------------------------------------------------
;;; The app takes you nowhere. It opens in the group the frame is already in,
;;; and every buffer it makes joins that one: a pane holding a member is a
;;; place, so the group saves this layout and gives it back. An app opened
;;; from an ungrouped frame has no group to join and so has no saved layout.
;;; That is the reader's position to be in, not the app's to correct.

(effects! '(write display))

(define (amazon-home-group!)
  (frame-group))

(define (amazon-join-group! buf)
  (when (and buf (buffer-exists? buf))
    (let ((id (amazon-home-group!)))
      (when (and id (not (buffer-in-group? buf id)))
        (buffer-add-group! buf id))))
  buf)

(define (amazon-log! line)
  (unless (buffer-exists? *amazon-log*) (buffer-create *amazon-log*))
  (buffer-append! *amazon-log* (string-append line "\n")))

;;; --- fetching ------------------------------------------------------------
;;; (browse URL) reads the page through the reader and fills its buffer off
;;; the lane, so the answer is not here when the call returns. Look again
;;; until it lands: a search is one round trip to Amazon, not a stream.

(effects! '(read write external))

(define (amazon-search-url query)
  (string-append "https://" amazon-host "/s?k=" (url-encode query)))

(define (amazon-product-url asin)
  (string-append "https://" amazon-host "/dp/" asin))

(define *amazon-sheet* "web/parsers/amazon-rows.xsl")

(define (amazon-page-url query page)
  (let ((base (amazon-search-url query)))
    (if (<= page 1) base (string-append base "&page=" (number->string page)))))

;; ONE way to read an Amazon page: a url, a sheet, and what a good answer
;; looks like. K gets the parsed record and the html it came from, or #f.
;;
;; RENDER says what the page needs, because the three pages need three
;; different things and the difference is measured, not guessed:
;;
;;   #f       a plain fetch. Amazon renders /dp/ on its own server, so the
;;            bullets, both specification tables, the histogram and the
;;            reviews are all in the bytes: about 2s against about 5s for a
;;            background tab that renders them again, and the two parse to
;;            the same record. A throttled fetch answers about 2KB with an
;;            empty title, so an answer that is not good is read again in a
;;            tab rather than shown as nothing.
;;   #t       a tab, with no fetch tried first. The search page answers a
;;            plain fetch with that 2KB stub nearly every time, so probing
;;            it only spends a second to learn what we already know.
;;   SELECTOR a tab that waits for SELECTOR. A load event is not an answer:
;;            the cart replies complete with an empty basket and fills it
;;            afterwards, so the read waits for a real line to arrive.
(define (amazon-read! url sheet ok? k &optional render)
  (if render
      (amazon--read-rendered! url sheet ok? k (and (string? render) render))
      (browser-fetch url
        (lambda (reply)
          (let* ((html (and (pair? reply) (car (cdr reply))))
                 (data (amazon--parse sheet html)))
            (if (and data (ok? data))
                (k data html)
                (amazon--read-rendered! url sheet ok? k #f)))))))

(define (amazon--read-rendered! url sheet ok? k wait)
  (browser-snapshot url
    (lambda (html)
      (let ((data (amazon--parse sheet html)))
        (if (and data (ok? data)) (k data html) (k #f html))))
    wait))

(define (amazon--parse sheet html)
  (let ((out (and (string? html) (xslt-apply sheet html))))
    (and (string? out) (> (string-length out) 2) (json-parse out))))

(define (amazon-fetch! query k)
  (amazon-fetch-page! query 1 k))

;; The rendered page, not the fetched one: Amazon answers a plain fetch with
;; a script shell, so the reading has to come from a real tab. The sheet does
;; the parsing, and nothing in this file reads markup any more.
;;
;; The sheet anchors on puis-card-container, which is products only. Amazon
;; marks its ad carousels s-result-item too: on one page, 24 s-result-item
;; nodes were 16 products, 2 ad carousels, 3 labels, the facet rail, related
;; searches and a help line.
(define (amazon-fetch-page! query page k)
  ;; a tab: the search page is the one that will not answer a fetch
  (amazon-read! (amazon-page-url query page) *amazon-sheet* pair?
    (lambda (rows html)
      ;; The s-pagination-* classes are absent from the rendered
      ;; snapshot. The next page's own url is in it, so that is the
      ;; signal that another page exists.
      (k (and (pair? rows) rows)
         (and (string? html)
              (string-contains? html
                (string-append "page=" (number->string (+ page 1))))
              #t)))
    #t))

;;; --- the product page ----------------------------------------------------
;;; A detail is one buffer per row, named after the ASIN, so the details
;;; opened from one listing are siblings and C-` walks them. It renders as
;;; HTML: the preview iframe runs no scripts, so every button on the page is
;;; a compos: link the editor hands back to Scheme.

(define-style! 'amazon-detail "
.amazon-head { padding: 8px 12px 2px; }
.amazon-title { font-family: var(--font-sans); font-size: 14px; font-weight: 600; line-height: 1.3; color: var(--fg); margin-bottom: 2px; }
.amazon-price { font-family: var(--font-mono); font-size: 13px; color: var(--fg); }
.amazon-chips { display: flex; flex-wrap: wrap; gap: 4px; margin: 6px 0 2px; }
.amazon-note { margin: 8px 12px; padding: 8px 10px; border-left: 3px solid var(--accent-fg); background: var(--hl-line-bg); white-space: pre-wrap; color: var(--fg); }
.amazon-reviews { padding: 4px 0; font-family: var(--font-sans); color: var(--fg); }
.amazon-photo { display: block; max-width: 200px; max-height: 200px; width: auto; height: auto; object-fit: contain; border: 1px solid var(--border-bg); border-radius: 3px; margin: 2px 0 6px; }
.amazon-bullets { margin: 2px 0 4px; padding: 0; list-style: none; }
.amazon-bullet { position: relative; padding-left: 14px; margin: 3px 0; font-family: var(--font-sans); line-height: 1.4; color: var(--fg); }
.amazon-bullet:before { content: '•'; position: absolute; left: 3px; color: var(--accent-fg); }
.amazon-prose { font-family: var(--font-sans); line-height: 1.45; color: var(--fg); white-space: pre-wrap; margin: 2px 0 4px; }
.amazon-hist { margin: 4px 0 8px; }
.amazon-hist-row { display: flex; align-items: center; gap: 6px; margin: 2px 0; }
.amazon-hist-star { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg); min-width: 26px; }
.amazon-hist-track { flex: 1; height: 8px; background: var(--hl-line-bg); border-radius: 2px; overflow: hidden; }
.amazon-hist-fill { display: block; height: 100%; background: var(--accent-fg); }
.amazon-hist-pct { font-family: var(--font-mono); font-size: 11px; color: var(--dim-fg); min-width: 34px; text-align: right; }
.amazon-review { margin: 6px 0; padding: 8px 10px; border: 1px solid var(--border-bg); border-radius: 3px; }
.amazon-review-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; }
.amazon-review-stars { font-family: var(--font-mono); font-size: 11px; color: var(--accent-fg); }
.amazon-review-title { font-family: var(--font-sans); font-size: 13px; font-weight: 600; color: var(--fg); }
.amazon-review-meta { font-family: var(--font-sans); font-size: 11px; color: var(--dim-fg); margin: 2px 0 4px; }
.amazon-review-body { font-family: var(--font-sans); line-height: 1.45; color: var(--fg); white-space: pre-wrap; }
.amazon-review-helpful { font-family: var(--font-sans); font-size: 11px; color: var(--dim-fg); margin-top: 4px; }
")

(define (amazon--row-field row key alt) (or (plist-get row key) alt))

(define (amazon-in-cart? asin)
  (member asin (or (buffer-local *amazon-buffer* 'amazon-cart) '())))

;; saved products and their notes live on the listing buffer, so they survive
;; the next search and come back with the desktop
(define (amazon-saved-list) (or (buffer-local *amazon-buffer* 'amazon-saved) '()))
(define (amazon-saved? asin) (and (member asin (amazon-saved-list)) #t))

;; a hidden product stays in the rows but out of the listing, so a search is
;; never re-read to get it back; X shows the hidden ones again, marked ⊘
(define (amazon-hidden-list) (or (buffer-local *amazon-buffer* 'amazon-hidden) '()))
(define (amazon-hidden? asin) (and (member asin (amazon-hidden-list)) #t))
(define (amazon-showing-hidden?) (and (buffer-local *amazon-buffer* 'amazon-show-hidden) #t))

(define (amazon-notes) (or (buffer-local *amazon-buffer* 'amazon-notes) '()))
(define (amazon-note asin)
  (let ((hit (assoc asin (amazon-notes)))) (and hit (car (cdr hit)))))

;; redraw the row, and the product's own page when it is open
(define (amazon-touch! asin)
  (let ((row (amazon-row-by-asin asin)))
    (when (and row (buffer-exists? (amazon-detail-buffer row)))
      (amazon-render-detail! (amazon-detail-buffer row) row)))
  (list-refresh! *amazon-buffer*))

(define (amazon-save-toggle! asin)
  (buffer-set-local! *amazon-buffer* 'amazon-saved
                     (if (amazon-saved? asin)
                         (filter (lambda (a) (not (equal? a asin))) (amazon-saved-list))
                         (cons asin (amazon-saved-list))))
  (amazon-touch! asin)
  (amazon-saved? asin))

(define (amazon-hide-toggle! asin)
  (buffer-set-local! *amazon-buffer* 'amazon-hidden
                     (if (amazon-hidden? asin)
                         (filter (lambda (a) (not (equal? a asin))) (amazon-hidden-list))
                         (cons asin (amazon-hidden-list))))
  (amazon-touch! asin)
  (amazon-hidden? asin))

(define (amazon-note-set! asin text)
  (let ((rest (filter (lambda (n) (not (equal? (car n) asin))) (amazon-notes))))
    (buffer-set-local! *amazon-buffer* 'amazon-notes
                       (if (or (not (string? text)) (equal? text ""))
                           rest
                           (cons (list asin text) rest))))
  (amazon-touch! asin))

(define (amazon-tab buf) (or (buffer-local buf 'amazon-tab) "overview"))

(define (amazon-tab-set! buf tab)
  (buffer-set-local! buf 'amazon-tab tab)
  (let ((row (buffer-local buf 'amazon-row)))
    (when row
      ;; asking for a tab is asking for the page behind it
      (amazon-detail-load! buf row)
      (buffer-set-local! buf 'render-blocks (amazon--detail-blocks buf row)))))

;; the tab bar's number hints are real keys: 1, 2 and 3 switch the tab
;; without the mouse; the click handler takes the same ids
(define (amazon-tab-here! tab)
  (let ((buf (current-buffer)))
    (if (buffer-local buf 'amazon-row)
        (begin (amazon-tab-set! buf tab)
               (message (string-append "Showing " tab)))
        (message "Not a product page"))))

(define-command "amazon-tab-overview" "Show the product's Overview tab"
  (lambda () (amazon-tab-here! "overview")))

(define-command "amazon-tab-specs" "Show the product's Specs tab"
  (lambda () (amazon-tab-here! "specs")))

(define-command "amazon-tab-reviews" "Show the product's Reviews tab"
  (lambda () (amazon-tab-here! "reviews")))

(define-command "amazon-reload-detail" "Read this product's page again"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (buffer-local buf 'amazon-row)))
      (if row
          (begin (amazon-detail-reload! buf row)
                 (amazon-detail-refresh! buf)
                 (message "Reading the product page again"))
          (message "Not a product page")))))

(define (amazon--tab-entry buf id label key)
  (list id label (equal? (amazon-tab buf) id) key))

(define (amazon--tabs-block buf)
  (component 'ui/tabs
    (list 'class "amazon-tabs"
          'tabs (list (amazon--tab-entry buf "overview" "Overview" "1")
                      (amazon--tab-entry buf "specs" "Specs" "2")
                      (amazon--tab-entry buf "reviews" "Reviews" "3")))))

;; the search page gives one photo per row; block mode draws it as an <img>,
;; so the detail page keeps the product picture the listing page dropped
(define (amazon--photo-url src)
  ;; The listing hands over a thumbnail cropped for a table cell
  ;; (._AC_..._SF516.0,327.0_PQ65_.jpg). Amazon serves any size from the same
  ;; image id, so keep the id, drop the size token, and ask for a big one.
  (let ((parts (and (string? src) (string-split src "/I/"))))
    (if (or (not parts) (null? (cdr parts)))
        src
        (string-append (car parts) "/I/"
                       (car (string-split (car (cdr parts)) "."))
                       "._AC_SL1000_.jpg"))))

(define (amazon--photo-block row)
  (let ((src (amazon--photo-url (plist-get row 'image))))
    (and src
         (list 'tag "img"
               'class "amazon-photo"
               'attrs (list (list "src" src)
                            (list "alt" (or (plist-get row 'title) "")))))))

(define (amazon--actions row)
  (let* ((asin (plist-get row 'asin))
         (kept? (amazon-saved? asin))
         (in? (amazon-in-cart? asin))
         (note (amazon-note asin)))
    (component 'ui/actions
      (list 'actions
            (list (list "amazon-cart" (if in? "✓ in cart · add another" "Add to cart") "c")
                  (list "amazon-save" (if kept? "★ saved" "Save") "m")
                  (list "amazon-note" (if note "Edit note" "Add a note") "N")
                  (list "amazon-open" "Open in browser" "o"))))))

(define (amazon--head-block row)
  (let* ((asin (plist-get row 'asin))
         (mrp (plist-get row 'mrp))
         (rating (plist-get row 'rating))
         (revs (plist-get row 'reviews))
         (kept? (amazon-saved? asin))
         (in? (amazon-in-cart? asin))
         (photo (amazon--photo-block row)))
    (list 'tag "div" 'class "amazon-head"
          'children
          (append
            (if photo (list photo) '())
            (list
            (list 'tag "div" 'class "amazon-title" 'text (plist-get row 'title))
            (list 'tag "div" 'class "amazon-price"
                  'text (string-append
                          "₹" (amazon--row-field row 'price "—")
                                        (if mrp (string-append "  ·  M.R.P. ₹" mrp) "")))
            (list 'tag "div" 'class "amazon-chips"
                  'children
                  (filter (lambda (b) b)
                    (list
                      (and rating (component 'ui/badge
                                     (list 'text (string-append "★ " rating
                                                (if revs (string-append " · " revs) "")))))
                      (and (plist-get row 'sponsored) (component 'ui/badge (list 'text "sponsored")))
                      (and kept? (component 'ui/badge (list 'text "saved")))
                      (and in? (component 'ui/badge (list 'text "in your cart"))))))
            (amazon--actions row))))))

(define (amazon--overview-blocks buf row)
  (let* ((asin (plist-get row 'asin))
         (data (amazon-detail-data buf))
         (rating (or (and data (plist-get data 'rating)) (plist-get row 'rating)))
         (revs (or (and data (plist-get data 'reviewCount)) (plist-get row 'reviews)))
         (deliv (or (and data (plist-get data 'delivery)) (plist-get row 'delivery)))
         (bullets (amazon--uniq (or (and data (plist-get data 'bullets)) '())))
         (desc (and data
                    (let ((ps (amazon--uniq (or (plist-get data 'descParas) '()))))
                      (if (pair? ps) (string-join ps "\n\n") (plist-get data 'description)))))
         (note (amazon-note asin)))
    (append
      (list
        (component 'ui/group
          (list 'title "At a glance"
                'body (list
                  (component 'ui/kv
                    (list 'pairs
                      (filter (lambda (p) p)
                        (list
                          (list "Price" (string-append "₹" (amazon--row-field row 'price "—")))
                          (list "Rating" (if rating (string-append (amazon--stars rating) " / 5") "—"))
                          (list "Reviews" (if revs (string-append (amazon--count revs) " ratings") "—"))
                          (list "Delivery" (or deliv "—"))
                          (and data (list "Brand" (or (amazon--brand data) "—")))
                          (and data (list "Seller" (or (plist-get data 'seller) "—")))
                          (and data (list "Availability" (or (plist-get data 'availability) "—")))))))))))
      (if (pair? bullets)
          (list (component 'ui/group
                  (list 'title "About this item"
                        'body (list
                          (list 'tag "div" 'class "amazon-bullets"
                                'children
                                (map (lambda (b)
                                       (list 'tag "div" 'class "amazon-bullet" 'text b))
                                     bullets))))))
          '())
      (if (and desc (> (string-length desc) 0))
          (list (component 'ui/group
                  (list 'title "From the maker"
                        'body (list (list 'tag "div" 'class "amazon-prose"
                                          'text (amz-clip desc 2000))))))
          '())
      ;; the overview reads well from the row alone, so it only speaks up
      ;; while a read is actually running
      (if (and (null? bullets) (equal? (amazon-detail-state buf) 'loading))
          (list (amazon--waiting buf "the description"))
          '())
      (if note (list (list 'tag "div" 'class "amazon-note" 'text note)) '()))))

;; The product page, read once per product and kept on its buffer.
;; A listing row carries a title, a price and a star count; everything
;; else the page shows -- the About-this-item bullets, the specification
;; tables, the star histogram and the reviews Amazon prints on the page
;; itself -- comes from the product page, read on demand. The read is a
;; rendered snapshot, so it is never done for a preview: only an opened
;; page and a tab the reader asked for start one.
(define *amazon-detail-sheet* "web/parsers/amazon-detail.xsl")

(define (amazon-detail-data buf) (buffer-local buf 'amazon-detail))
(define (amazon-detail-state buf) (or (buffer-local buf 'amazon-detail-state) 'cold))

(define (amazon-detail-refresh! buf)
  (let ((row (and (buffer-exists? buf) (buffer-local buf 'amazon-row))))
    (when row
      (buffer-set-local! buf 'render-blocks (amazon--detail-blocks buf row)))))

(define (amazon-detail-load! buf row)
  ;; a fetch: /dp/ arrives whole, and a tab only if that answer is thin
  (let ((asin (and row (plist-get row 'asin))))
    (when (and asin (equal? (amazon-detail-state buf) 'cold))
      (buffer-set-local! buf 'amazon-detail-state 'loading)
      (amazon-read! (amazon-product-url asin) *amazon-detail-sheet*
        amazon-detail-whole?
        (lambda (data html)
          (buffer-set-local! buf 'amazon-detail data)
          (buffer-set-local! buf 'amazon-detail-state (if data 'ready 'failed))
          (amazon-detail-refresh! buf))))))

;; A throttled read parses to a record with every field empty. A real
;; product page has a title and at least one of the three things the tabs
;; are made of -- some products carry no specification table at all, so no
;; single block can stand for the page.
(define (amazon-detail-whole? d)
  (and (> (string-length (or (plist-get d 'title) "")) 0)
       (or (pair? (or (plist-get d 'specs) '()))
           (pair? (or (plist-get d 'bullets) '()))
           (pair? (or (plist-get d 'reviews) '())))
       #t))

;; read the page again: the buffer keeps its name, its tab and its notes
(define (amazon-detail-reload! buf row)
  (buffer-set-local! buf 'amazon-detail-state 'cold)
  (buffer-set-local! buf 'amazon-detail #f)
  (amazon-detail-load! buf row))

;; a specification table as (KEY VALUE) rows: the page repeats keys
;; across its tables, and the first mention is the one that reads best
;; the rating and the ASIN are already on the page's own head and in
;; Listing, and the page prints the rating as a run of three copies
(define *amazon-spec-skip* (list "Customer Reviews" "ASIN"))

(define (amazon--pairs data key)
  (let loop ((ps (or (plist-get data key) '())) (seen '()) (out '()))
    (if (null? ps)
        (reverse out)
        (let ((k (amz-clean (or (plist-get (car ps) 'k) "")))
              (v (amz-clean (or (plist-get (car ps) 'v) ""))))
          (if (or (equal? k "") (equal? v "")
                  (member k seen) (member k *amazon-spec-skip*))
              (loop (cdr ps) seen out)
              (loop (cdr ps) (cons k seen)
                    (cons (list k (amz-clip v 300)) out)))))))

;; the same line twice is Amazon's expander, not two bullets
(define (amazon--uniq strs)
  (let loop ((ss strs) (seen '()) (out '()))
    (cond ((null? ss) (reverse out))
          ((or (equal? (car ss) "") (member (car ss) seen)) (loop (cdr ss) seen out))
          (else (loop (cdr ss) (cons (car ss) seen) (cons (car ss) out))))))

;; the page writes a rating count as "(1,234)" and the listing as "1,234"
(define (amazon--count s)
  (and s (amz-replace (amz-replace s "(" "") ")" "")))

;; Amazon writes the byline as "Visit the Acme Store" or "Brand: Acme"
(define (amazon--brand data)
  (let ((s (amz-clean (or (plist-get data 'brand) ""))))
    (cond ((equal? s "") #f)
          ((amz-has? s "Visit the ")
           (let ((rest (amz-after s "Visit the ")))
             (if (amz-has? rest " Store") (amz-before rest " Store") rest)))
          ((amz-has? s "Brand: ") (amz-after s "Brand: "))
          (else s))))

(define (amazon--waiting buf what)
  ;; a preview never reads the page, so a cold tab says how to read it
  ;; rather than pretending a read is under way
  (let ((state (amazon-detail-state buf)))
    (cond ((equal? state 'ready) #f)
          ((equal? state 'loading)
           (component 'ui/empty
             (list 'text (string-append "Reading " what " from the product page…"))))
          ((equal? state 'failed)
           (component 'ui/empty
             (list 'text "Could not read the product page. g reads it again.")))
          (else
           (component 'ui/empty
             (list 'text (string-append "g reads the product page for " what ".")))))))

(define (amazon--specs-blocks buf row)
  (let* ((asin (plist-get row 'asin))
         (mrp (plist-get row 'mrp))
         (data (amazon-detail-data buf))
         (rating (or (and data (plist-get data 'rating)) (plist-get row 'rating)))
         (revs (or (and data (plist-get data 'reviewCount)) (plist-get row 'reviews)))
         (deliv (or (and data (plist-get data 'delivery)) (plist-get row 'delivery)))
         (overview (and data (amazon--pairs data 'overview)))
         (specs (and data (amazon--pairs data 'specs)))
         (wait (amazon--waiting buf "the specifications")))
    (append
      (list
        (component 'ui/group
          (list 'title "Listing"
                'body (list
                  (component 'ui/kv
                    (list 'pairs
                      (filter (lambda (p) p)
                        (list
                          (list "Price" (string-append "₹" (amazon--row-field row 'price "—")))
                          (list "M.R.P." (if mrp (string-append "₹" mrp) "—"))
                          (and data (plist-get data 'discount)
                               (list "Discount" (plist-get data 'discount)))
                          (list "Rating" (if rating (string-append (amazon--stars rating) " / 5") "—"))
                          (list "Reviews" (if revs (string-append (amazon--count revs) " ratings") "—"))
                          (list "Delivery" (or deliv "—"))
                          (and data (list "Sold by" (or (plist-get data 'seller) "—")))
                          (list "ASIN" asin)
                          (list "Sponsored" (if (plist-get row 'sponsored) "yes" "no"))))))))))
      (if (and overview (pair? overview))
          (list (component 'ui/group
                  (list 'title "Product overview"
                        'body (list (component 'ui/kv (list 'pairs overview))))))
          '())
      (if (and specs (pair? specs))
          (list (component 'ui/group
                  (list 'title "Technical details"
                        'body (list (component 'ui/kv (list 'pairs specs))))))
          '())
      (if wait (list wait) '()))))

(define (amazon--hist-block data)
  (let ((h (or (plist-get data 'histogram) '())))
    (and (pair? h)
         (list 'tag "div" 'class "amazon-hist"
               'children
               (let loop ((ps h) (star 5) (out '()))
                 (if (or (null? ps) (< star 1))
                     (reverse out)
                     (loop (cdr ps) (- star 1)
                           (cons (list 'tag "div" 'class "amazon-hist-row"
                                       'children
                                       (list
                                         (list 'tag "span" 'class "amazon-hist-star"
                                               'text (string-append (number->string star) "★"))
                                         (list 'tag "span" 'class "amazon-hist-track"
                                               'children
                                               (list (list 'tag "span" 'class "amazon-hist-fill"
                                                           'attrs (list (list "style"
                                                                              (string-append "width:" (car ps)))))))
                                         (list 'tag "span" 'class "amazon-hist-pct" 'text (car ps))))
                                 out))))))))

(define (amazon--review-block r)
  (let* ((stars (amazon--stars (plist-get r 'stars)))
         (title (or (plist-get r 'title) ""))
         (author (or (plist-get r 'author) ""))
         (date (or (plist-get r 'date) ""))
         (variant (amazon--uniq (or (plist-get r 'variant) '())))
         (verified (or (plist-get r 'verified) ""))
         (helpful (or (plist-get r 'helpful) ""))
         ;; the paragraphs as the writer broke them, or the flat run
         (paras (amazon--uniq (or (plist-get r 'paras) '())))
         (body (if (pair? paras)
                   (string-join paras "\n\n")
                   (or (plist-get r 'body) ""))))
    (list 'tag "div" 'class "amazon-review"
          'children
          (filter (lambda (b) b)
            (list
              (list 'tag "div" 'class "amazon-review-head"
                    'children
                    (filter (lambda (b) b)
                      (list
                        (and (> (string-length stars) 0)
                             (list 'tag "span" 'class "amazon-review-stars"
                                   'text (string-append stars "★")))
                        (and (> (string-length title) 0)
                             (list 'tag "span" 'class "amazon-review-title" 'text title))
                        (and (> (string-length verified) 0)
                             (component 'ui/badge (list 'text "verified"))))))
              (list 'tag "div" 'class "amazon-review-meta"
                    'text (string-join
                            (filter (lambda (s) (> (string-length s) 0))
                                    (append (list author date) variant))
                            "  ·  "))
              (and (> (string-length body) 0)
                   (list 'tag "div" 'class "amazon-review-body" 'text (amz-clip body 1600)))
              (and (> (string-length helpful) 0)
                   (list 'tag "div" 'class "amazon-review-helpful" 'text helpful)))))))

(define (amazon--reviews-blocks buf row)
  (let* ((data (amazon-detail-data buf))
         (rating (or (and data (plist-get data 'rating)) (plist-get row 'rating)))
         (revs (or (and data (plist-get data 'reviewCount)) (plist-get row 'reviews)))
         (reviews (or (and data (plist-get data 'reviews)) '()))
         (hist (and data (amazon--hist-block data)))
         (wait (amazon--waiting buf "the reviews")))
    (append
      (list
        (component 'ui/group
          (list 'title "Customer reviews"
                'body (filter (lambda (b) b)
                        (list
                          (list 'tag "div" 'class "amazon-reviews"
                                'text (string-append
                                        (if rating (string-append "★ " (amazon--stars rating) " / 5") "No rating yet")
                                        (if revs (string-append "  ·  " (amazon--count revs) " ratings") "")))
                          hist)))))
      (if (pair? reviews)
          (list (component 'ui/group
                  (list 'title (string-append "Top reviews (" (number->string (length reviews)) ")")
                        'body (map amazon--review-block reviews))))
          '())
      (if wait (list wait) '())
      (if (and (not wait) (null? reviews))
          (list (component 'ui/empty
                  (list 'text "The product page prints no reviews for this one.")))
          '()))))

(define (amazon--detail-blocks buf row)
  (let ((tab (amazon-tab buf)))
    (append
      (list (amazon--tabs-block buf)
            (amazon--head-block row))
      (cond ((equal? tab "specs") (amazon--specs-blocks buf row))
            ((equal? tab "reviews") (amazon--reviews-blocks buf row))
            (else (amazon--overview-blocks buf row))))))

(define (amz-page-title row)
  (let ((title (amz-clip (string-trim (amz-replace (or (plist-get row 'title) "") "*" "")) 48)))
    (if (equal? title "") (string-append "amazon:" (plist-get row 'asin)) title)))

;; two products can share the first 48 characters of a title; the second one
;; keeps its ASIN, so no page is ever shown under another product's name
(define (amazon-detail-buffer row)
  (let* ((base (string-append "*" (amz-page-title row) "*"))
         (mine (plist-get row 'asin))
         (held (let ((r (and (buffer-exists? base) (buffer-local base 'amazon-row))))
                 (and r (plist-get r 'asin)))))
    (if (or (not held) (equal? held mine))
        base
        (string-append "*" (amz-page-title row) " " mine "*"))))

(define (amazon-render-detail! buf row)
  (unless (buffer-exists? buf) (buffer-create buf))
  (buffer-set-read-only! buf #f)
  (let ((old (buffer-text buf)) (title (plist-get row 'title)))
    (if (> (string-length old) 0)
        (buffer-replace! buf old title)
        (buffer-append! buf title)))
  (buffer-set-local! buf 'amazon-row row)
  (buffer-set-local! buf 'amazon-title (amz-page-title row))
  (unless (buffer-derived-mode? buf "amazon-detail-mode")
    (with-current-buffer buf (lambda () (set-mode! "amazon-detail-mode"))))
  (when (minor-mode-on? buf "preview-mode") (disable-minor-mode! buf "preview-mode"))
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks (amazon--detail-blocks buf row))
  (buffer-set-read-only! buf #t)
  buf)

(define (amazon-show-detail! row)
  (when row
    (let ((buf (amazon-render-detail! (amazon-detail-buffer row) row)))
      (amazon-join-group! buf)
      (display-buffer-detail! buf *amazon-buffer*)
      buf)))

;;; --- the cart ------------------------------------------------------------
;;; The add goes through the reader's own browser tab, so it lands in the
;;; signed-in cart and nothing on screen navigates. The answer is the cart
;;; page, which says whether the ASIN is in it.

(define (amazon-row-by-asin asin)
  (let loop ((rs (or (buffer-local *amazon-buffer* 'amazon-rows) '())))
    (cond ((null? rs) #f)
          ((equal? (plist-get (car rs) 'asin) asin) (car rs))
          (else (loop (cdr rs))))))

(define (amazon-name-of asin)
  (let ((r (amazon-row-by-asin asin))) (if r (amz-clip (plist-get r 'title) 48) asin)))

;; The listing is read from a snapshot, which leaves no tab behind. The cart
;; cannot work that way: it clicks a real page carrying your cookies. So the
;; cart opens the storefront once when no tab is there, and every later add
;; reuses it.
;; A tab is no use until its page has stopped loading: inject into a tab that
;; is still arriving and the load wipes the globals you just set, so the answer
;; never comes and the caller waits out its whole poll for nothing. That is a
;; readyState away, and cheaper than guessing with a timer.




(define (amazon--tab k)
  (tab-list (lambda (ts)
    (let loop ((ts ts))
      (cond ((null? ts) (k #f))
            ((amz-has? (or (plist-get (car ts) 'url) "") amazon-host) (k (plist-get (car ts) 'id)))
            (else (loop (cdr ts))))))))


;;; Amazon no longer adds from a plain fetch. /gp/aws/cart/add.html answers the
;;; cart page while adding nothing, and the detail page's own form 404s when it
;;; is posted without the product page as referer -- a referer fetch cannot set.
;;; So load the product page in a hidden iframe on the amazon tab and press the
;;; real Add to cart button: same origin, same cookies, Amazon's own javascript.
;;; Whether it landed is the cart badge and nothing else -- read it before, read
;;; it after the click, and the add worked when the count moved. Anything else,
;;; including a page titled Shopping Cart, is a failure. A sign-in page is its
;;; own answer. The click needs seconds, not milliseconds; the caller polls.




;; The cart itself, in the browser. Pressing C is the reader asking to go
;; there, so the tab comes to the front -- this is the one place the app is
;; allowed to take the screen, because that is what was asked for.
;; The cart, in the app, as rows. Read from the tab's own DOM rather than a
;; fresh snapshot: a snapshot of the cart comes back half-hydrated and drops
;; lines, and the tab is already sitting on a fully rendered page.
;;
;; Only lines that carry a data-asin count. A cart page holds sc-active-* and
;; sc-saved-*, and some sc-active-* elements are wrappers with no product in
;; them at all -- on one real cart, 4 active elements were 2 products.


(define (amazon--in-cart-view?)
  (and (buffer-known? *amazon-buffer*)
       (equal? (buffer-local *amazon-buffer* 'amazon-query) "cart")))

;; The cart takes the listing over, so the listing it took over is kept and
;; C puts it back. Without this the cart is a one-way door and the only way
;; out is running the search again.
(define (amazon--restore-search!)
  (let ((rows (buffer-local *amazon-buffer* 'amazon-prev-rows))
        (q (buffer-local *amazon-buffer* 'amazon-prev-query)))
    (if (not (and rows q))
        (message "No search to go back to -- s starts one")
        (begin
          (buffer-set-local! *amazon-buffer* 'amazon-rows rows)
          (buffer-set-local! *amazon-buffer* 'amazon-query q)
          (buffer-set-local! *amazon-buffer* 'amazon-page
                             (or (buffer-local *amazon-buffer* 'amazon-prev-page) 1))
          (buffer-set-local! *amazon-buffer* 'list-layout-cache #f)
          (list-refresh! *amazon-buffer*)
          (message (string-append "back to " q))))))

(define (amazon--cart-show! rows)
  (when (and rows (buffer-known? *amazon-buffer*))
    (unless (amazon--in-cart-view?)
      (buffer-set-local! *amazon-buffer* 'amazon-prev-rows
                         (buffer-local *amazon-buffer* 'amazon-rows))
      (buffer-set-local! *amazon-buffer* 'amazon-prev-query
                         (buffer-local *amazon-buffer* 'amazon-query))
      (buffer-set-local! *amazon-buffer* 'amazon-prev-page
                         (buffer-local *amazon-buffer* 'amazon-page)))
    (buffer-set-local! *amazon-buffer* 'amazon-rows rows)
    (buffer-set-local! *amazon-buffer* 'amazon-query "cart")
    (buffer-set-local! *amazon-buffer* 'amazon-page 1)
    (buffer-set-local! *amazon-buffer* 'amazon-more #f)
    (buffer-set-local! *amazon-buffer* 'amazon-cart
                       (map (lambda (r) (plist-get r 'asin)) rows))
    (buffer-set-local! *amazon-buffer* 'list-layout-cache #f)
    (list-refresh! *amazon-buffer*)
    (message (string-append (number->string (length rows)) " in the cart"))))



(define *amazon-cart-sheet* "web/parsers/amazon-cart.xsl")

;; The cart in the app, parsed by the same kind of sheet the listing uses.
;; It reads through a snapshot, so nothing of the reader's browser moves --
;; and it names the selector the cart is finished by, because Amazon answers
;; "complete" with an empty basket and fills it afterwards.
(define (amazon-goto-cart!)
  (if (amazon--in-cart-view?) (amazon--restore-search!) (amazon--cart-fetch!)))

(define (amazon--cart-fetch!)
  (message "Reading the cart...")
  ;; a tab that waits: the cart fills itself after the load completes
  (amazon-read! (string-append "https://" amazon-host "/gp/cart/view.html")
    *amazon-cart-sheet* pair?
    (lambda (rows html)
      (if (pair? rows)
          (amazon--cart-show! rows)
          (message (if (string? html) "The cart read empty" "Could not read the cart"))))
    "[id^='sc-active-'] .sc-quantity-textfield"))

;; Read the real cart and mark the listing from it.
(define (amazon-cart-sync!)
  ;; Marks the listing from the real cart. It reads the same sheet the cart
  ;; view does, so it counts what the cart holds and not what the page
  ;; mentions: a cart page also carries saved-for-later, and scraping every
  ;; data-asin on it once marked seventeen rows for a cart holding one.
  (task-run!
    (lambda ()
      (let* ((html (app-await
                     (lambda (k)
                       (browser-snapshot (string-append "https://" amazon-host "/gp/cart/view.html")
                                         k "[id^='sc-active-'] .sc-quantity-textfield"))
                     30))
             (out (and (string? html) (xslt-apply *amazon-cart-sheet* html))))
        (and out (json-parse out))))
    (lambda (ok rows)
      (when (and ok rows (pair? rows) (buffer-known? *amazon-buffer*))
        (buffer-set-local! *amazon-buffer* 'amazon-cart
                           (map (lambda (r) (plist-get r 'asin)) rows))
        (list-refresh! *amazon-buffer*)
        (amazon-log! (string-append "cart holds " (number->string (length rows)) " items"))))
    60000))

(define (amazon--cart-js asin)
  ;; Click the button, then ask the cart whether the thing is in it. No before
  ;; count: a count that moved says something was added, not that THIS was,
  ;; and a stale count says nothing at all. The cart page naming the ASIN is
  ;; the whole answer.
  (string-append
   "(function(){window.__amzcart='pending';"
   "var A='" asin "';"
   "var fr=document.createElement('iframe');"
   "fr.style.cssText='position:fixed;left:-9999px;top:0;width:1280px;height:1000px;opacity:0';"
   "var done=false,step=0,tries=0;"
   "function say(o){if(done)return;done=true;"
   "window.__amzcart=JSON.stringify(o);try{fr.remove()}catch(e){}}"
   "setTimeout(function(){say({added:false,error:'timed out'})},30000);"
   "function inCart(){return fetch('/gp/cart/view.html',{credentials:'include'})"
   ".then(function(r){return r.text()}).then(function(t){return t.indexOf(A)>=0})}"
   "function verify(){if(done)return;tries++;inCart().then(function(yes){"
   "if(yes){say({added:true,checks:tries})}"
   "else if(tries>10){say({added:false,error:'not in the cart after the click'})}"
   "else{setTimeout(verify,700)}}).catch(function(e){say({added:false,error:String(e.message)})})}"
   "fr.onload=function(){if(done||step>0)return;try{var d=fr.contentDocument;"
   "var title=(d.title||'');step=1;"
   "if(/sign ?in/i.test(title)||/\\/ap\\/signin/.test(String(fr.contentWindow.location.href)))"
   "{say({added:false,signin:true});return}"
   "var btn=d.querySelector('#add-to-cart-button')"
   "||d.querySelector('input[name=\"submit.add-to-cart\"]');"
   "if(!btn){say({added:false,error:'no add-to-cart button',title:title.slice(0,60)});return}"
   "btn.click();setTimeout(verify,800)}"
   "catch(e){say({added:false,error:String(e.message)})}};"
   "fr.src='/dp/" asin "';document.body.appendChild(fr);"
   "return 'started'})()"))

(define (amazon--cart-done! asin answer)
  (let* ((text (if (string? answer) answer ""))
         (ok (amz-has? text "\"added\":true"))
         (signin (amz-has? text "\"signin\":true")))
    (cond
     (ok
      (unless (amazon-in-cart? asin)
        (buffer-set-local! *amazon-buffer* 'amazon-cart
                           (cons asin (or (buffer-local *amazon-buffer* 'amazon-cart) '()))))
      (amazon-log! (string-append asin " added -- " text))
      (message (string-append (amazon-name-of asin) " added to the cart"))
      (let ((row (amazon-row-by-asin asin)))
        (when (and row (buffer-exists? (amazon-detail-buffer row)))
          (amazon-render-detail! (amazon-detail-buffer row) row)))
      (list-refresh! *amazon-buffer*))
     (signin
      (amazon-log! (string-append asin " not added -- signed out -- " text))
      (message (string-append "Sign in to " amazon-host " in your browser, then try again")))
     (else
      (amazon-log! (string-append asin " not added -- " (if (string? answer) answer "no answer")))
      (message (string-append "The cart did not move -- " (amazon-name-of asin)
                              " was not added. See " *amazon-log*))))))



(define (amazon--cart-tab)
  ;; inside a task: find a tab, open one if there is none, and do not hand it
  ;; back until its page has stopped loading -- injecting into a tab that is
  ;; still arriving loses the globals to the load that follows
  (let ((tab (app-await (lambda (k) (amazon--tab k)) 10)))
    (unless tab
      (tab-open (string-append "https://" amazon-host "/") #f #t)
      (app-pause 800)
      (set! tab (app-await (lambda (k) (amazon--tab k)) 10)))
    (and tab
         (let ready ((n 40))
           (let ((state (app-await (lambda (k) (tab-eval tab "document.readyState" k)) 10)))
             (cond ((equal? state "complete") tab)
                   ((<= n 0) tab)
                   (else (app-pause 300) (ready (- n 1)))))))))

(define (amazon--cart-answer tab)
  ;; String() so an undefined global reads as "undefined" rather than arriving
  ;; as a non-string: "pending" means still working, "undefined" means the page
  ;; reloaded out from under the script and no answer is ever coming.
  (let poll ((n 80))
    (let ((v (app-await (lambda (k) (tab-eval tab "String(window.__amzcart)" k)) 10)))
      (cond ((and (string? v)
                  (not (equal? v "pending"))
                  (not (equal? v "undefined"))
                  (not (equal? v "")))
             v)
            ((<= n 0)
             (string-append "{\"added\":false,\"error\":\"no answer\",\"last\":\""
                            (if (string? v) v "nil") "\"}"))
            (else (app-pause 400) (poll (- n 1)))))))

;; One sequence, read top to bottom, run off the lane so the editor stays
;; live: get a loaded tab, inject, wait for the answer, report it.
(define (amazon-cart-add! asin)
  (message (string-append "Adding " (amazon-name-of asin) " to the cart..."))
  (task-run!
    (lambda ()
      (let ((tab (amazon--cart-tab)))
        (if (not tab)
            (list 'no-tab #f)
            (begin
              (app-await (lambda (k) (tab-eval tab (amazon--cart-js asin) k)) 10)
              (list 'answer (amazon--cart-answer tab))))))
    (lambda (ok result)
      (cond ((not ok)
             (amazon-log! (string-append asin " not added -- task failed"))
             (message "The cart add failed"))
            ((equal? (car result) 'no-tab)
             (amazon-log! (string-append asin ": could not open a " amazon-host " tab"))
             (message (string-append "Could not open a " amazon-host " tab")))
            (else (amazon--cart-done! asin (cadr result)))))
    120000))

(define (amazon-open-external! asin)
  (begin (tab-open (amazon-product-url asin))
             (message (string-append "Opened " asin " in the browser"))))

;; the page's own blocks, pressed in Scheme
(add-hook! (list 'block-click 'amazon)
  (lambda (buf id)
    (let ((row (buffer-local buf 'amazon-row)))
      (and row
           (let ((asin (plist-get row 'asin)))
             (cond ((equal? id "overview") (amazon-tab-set! buf "overview"))
                   ((equal? id "specs") (amazon-tab-set! buf "specs"))
                   ((equal? id "reviews") (amazon-tab-set! buf "reviews"))
                   ((equal? id "amazon-cart") (amazon-cart-add! asin))
                   ((equal? id "amazon-save") (amazon-save-toggle! asin))
                   ((equal? id "amazon-note") (amazon-ask-note! asin))
                   ((equal? id "amazon-open") (amazon-open-external! asin))
                   (else #f))
             #t)))))

;;; --- actions, on the listing and on the page -----------------------------
;;; The same verb under the same key in both places: the listing reads the
;;; row at point, the page keeps its own.

(define (amazon-row-here)
  (or (buffer-local (current-buffer) 'amazon-row)
      (list-current *amazon-buffer*)))

(define-command "amazon-detail" "Show the product on this row beside the listing"
  (lambda ()
    ;; opening a page is the ask that pays for reading it; a preview is not
    (let ((row (amazon-row-here)))
      (let ((buf (amazon-show-detail! row)))
        (when buf (amazon-detail-load! buf row))))))

(define-command "amazon-cart" "Add this product to the Amazon cart"
  (lambda () (let ((r (amazon-row-here))) (when r (amazon-cart-add! (plist-get r 'asin))))))

(define-command "amazon-open" "Open this product's page in the real browser"
  (lambda () (let ((r (amazon-row-here))) (when r (amazon-open-external! (plist-get r 'asin))))))

(define-command "amazon-copy-link" "Copy this product's link"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r (let ((u (amazon-product-url (plist-get r 'asin))))
                (kill-new u) (message (string-append "Copied " u)))))))

;; a note is one line you write about the product; an empty answer clears it
(define (amazon-ask-note! asin)
  (read-string (string-append "Note on " (amz-clip (amazon-name-of asin) 34) ": ")
               (lambda (text)
                 (amazon-note-set! asin text)
                 (message (if (or (not (string? text)) (equal? text ""))
                              "Note cleared"
                              "Noted")))))

(define-command "amazon-save" "Save this product, marking it in the listing"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r
        (let ((asin (plist-get r 'asin)))
          (message (string-append (amz-clip (amazon-name-of asin) 34)
                                  (if (amazon-save-toggle! asin) " saved" " no longer saved"))))))))

(define-command "amazon-note" "Write a note on this product"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r (amazon-ask-note! (plist-get r 'asin))))))

(define-command "amazon-sort-delivery" "Order the listing by soonest delivery, or back to Amazon's order"
  (lambda ()
    (let ((on (not (equal? (buffer-local *amazon-buffer* 'amazon-sort) 'delivery))))
      (buffer-set-local! *amazon-buffer* 'amazon-sort (if on 'delivery 'relevance))
      (list-refresh! *amazon-buffer*)
      (message (if on "Soonest delivery first" "Amazon's order")))))

(define-command "amazon-hide" "Take this product out of the listing"
  (lambda ()
    (let ((r (amazon-row-here)))
      (when r
        (let ((asin (plist-get r 'asin)))
          (message (string-append (amz-clip (amazon-name-of asin) 34)
                                  (if (amazon-hide-toggle! asin) " hidden" " back in the listing"))))))))

(define-command "amazon-hidden" "Show the hidden products too, or put them away"
  (lambda ()
    (let ((on (not (amazon-showing-hidden?))))
      (buffer-set-local! *amazon-buffer* 'amazon-show-hidden on)
      (list-refresh! *amazon-buffer*)
      (message (if on
                   (string-append (number->string (length (amazon-hidden-list))) " hidden, shown")
                   "Hidden products put away")))))

;;; --- the listing ---------------------------------------------------------

(define (amazon--when s)
  ;; "FREE delivery Tomorrow, 22 Sept" -> "Tomorrow, 22 Sept": the column is
  ;; narrow and every row says FREE delivery, so the words carry nothing
  (let* ((s (or s ""))
         (cut (if (string-contains? s "delivery ")
                  (car (cdr (string-split s "delivery ")))
                  s))
         ;; "Today 4 pm - 8 pm on ₹399 of items" -- the threshold is a
         ;; condition on the order, not a time, and it costs half the column
         (cut (car (string-split (or cut s) " on "))))
    (amz-clip cut 22)))

(define (amazon--stars s)
  ;; the sheet hands over "4.8 out of 5 stars"; a column wants "4.8"
  (car (string-split (or s "") " out of")))

(define (amazon--cells buf row)
  (let ((asin (plist-get row 'asin)))
    (list (string-append (if (amazon-hidden? asin) "⊘" " ")
                         (if (amazon-saved? asin) "★" " ")
                         (if (amazon-note asin) "✎" " ")
                         (if (amazon-in-cart? asin) "✓" " "))
          (let* ((p (or (plist-get row 'price) ""))
                 (p (if (string-suffix? "." p) (substring p 0 (- (string-length p) 1)) p)))
            (if (equal? p "") "—" (string-append "₹" p)))
          ;; the cart's basis-price carries a literal "null" in an offscreen span
          (let ((m (or (plist-get row 'mrp) "")))
            (list (if (string-prefix? "null" m) (substring m 4 (string-length m)) m) "dim"))
          (list (amazon--stars (plist-get row 'rating)) "dim")
          (list (amazon--when (plist-get row 'delivery)) "dim")
          (amz-clip (or (plist-get row 'title) "") 80))))

(define (amazon--columns buf)
  ;; widest last and unbounded: the title takes whatever the frame leaves
  (list (list "" 4) (list "₹" 9) (list "m.r.p" 9)
        (list "★" 5) (list "delivery" 22) (list "product" #f)))

;;; A three-column app leaves the listing about 59 columns wide, which cuts the
;;; price, delivery and asin off the right edge and packs the key hints down to
;;; the first five. The narrow profile drops the columns that repeat on the
;;; product page and shortens the hints so the ones worth pressing survive; ?
;;; still shows every key.
(define (amazon--narrow-columns buf)
  ;; delivery earns its width even here: when a thing lands is half of why
  ;; one row beats another, and a narrow frame is still a frame
  (list (list "" 4) (list "₹" 9) (list "delivery" 19) (list "product" #f)))

(define (amazon--narrow-cells buf row)
  (let ((cs (amazon--cells buf row)))
    (list (list-ref cs 0) (list-ref cs 1) (list-ref cs 4)
          (amz-clip (or (plist-get row 'title) "") 40))))

(define (amazon--narrow-footer buf)
  (list (list "RET" "open") (list "c" "cart") (list "m" "save")
        (list "N" "note") (list "n/p" "pg") (list "x" "hide")
        (list "d" "sort") (list "o" "web") (list "q" "quit")))

(define-list-mode! "amazon-mode"
  (list 'doc "Amazon search results as the signed-in account sees them, with the retail price beside the one you pay. The delivery column is the day it lands, and d orders the listing by the soonest. Moving shows that product as a page beside the listing, and C-` there flips through the pages you have opened. RET shows it again, m saves it and marks the row, N writes a note on it, n and p walk to the next and previous page of results, x takes it out of the listing and X shows the hidden ones again marked ⊘, c adds it to the cart and C opens the cart itself, o opens it in the real browser, w copies its link, s runs another search, g reads this page again, q quits."
        'buffer *amazon-buffer*
        'transient #f
        'noun "product"
        'rows (lambda (buf)
                (let* ((all (or (buffer-local buf 'amazon-rows) '()))
                       (rows (if (amazon-showing-hidden?)
                                 all
                                 (filter (lambda (r) (not (amazon-hidden? (plist-get r 'asin)))) all))))
                  (if (equal? (buffer-local buf 'amazon-sort) 'delivery)
                      (amz-sort-by-delivery rows)
                      rows)))
        'key (lambda (buf row) (plist-get row 'asin))
        'columns amazon--columns
        'cells amazon--cells
        'layouts (list (list 'name 'narrow
                             'max-cols 74
                             'columns amazon--narrow-columns
                             'cells amazon--narrow-cells
                             'footer amazon--narrow-footer)
                       (list 'name 'wide
                             'default #t
                             'columns amazon--columns
                             'cells amazon--cells))
        'title (lambda (buf) (or (buffer-local buf 'amazon-query) "Amazon"))
        'meta (lambda (buf)
                (string-append amazon-host
                               (let ((p (or (buffer-local buf 'amazon-page) 1)))
                                 (if (> p 1) (string-append " · page " (number->string p)) ""))
                               (if (buffer-local buf 'amazon-more) "" " · last page")
                               (if (equal? (buffer-local buf 'amazon-sort) 'delivery)
                                   " · soonest delivery first"
                                   "")
                               (let ((n (length (amazon-hidden-list))))
                                 (cond ((= n 0) "")
                                       ((amazon-showing-hidden?)
                                        (string-append " · showing " (number->string n) " hidden"))
                                       (else (string-append " · " (number->string n) " hidden"))))))
        'total (lambda (buf)
                 (let ((all (or (buffer-local buf 'amazon-rows) '())))
                   (if (amazon-showing-hidden?)
                       (length all)
                       (length (filter (lambda (r) (not (amazon-hidden? (plist-get r 'asin)))) all)))))
        'footer (lambda (buf) (list (list "RET" "open") (list "c" "cart") (list "m" "save")
                                    (list "n/p" "page") (list "N" "note") (list "x" "hide")
                                    (list "C" "cart") (list "d" "sort") (list "o" "browser")
                                    (list "X" (if (amazon-showing-hidden?) "hide hidden" "show hidden"))
                                    (list "s" "search") (list "q" "quit")))
        'preview (lambda (buf row) (amazon-show-detail! row))
        'keys (list (list "RET" "amazon-detail")
                    (list "m" "amazon-save")
                    (list "N" "amazon-note")
                    (list "n" "amazon-next-page")
                    (list "p" "amazon-prev-page")
                    (list "x" "amazon-hide")
                    (list "X" "amazon-hidden")
                    (list "d" "amazon-sort-delivery")
                    (list "c" "amazon-cart")
                    (list "o" "amazon-open")
                    (list "w" "amazon-copy-link")
                    (list "s" "amazon-search")
                    (list "g" "amazon-refresh")
                    (list "q" "quit-window"))))

;;; --- the page's mode -----------------------------------------------------
;;; detail-mode arrives with the buffer (display-buffer-detail!) and brings
;;; C-`, C-M-` and M-RET. This mode adds the app's own verbs, so the page
;;; answers the same keys as the row it came from.

(define-mode "amazon-detail-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (buffer-set-local! buf 'desktop-skip-locals '(render-blocks))
      (buffer-set-local! buf 'render-mode "blocks")
      (let ((row (buffer-local buf 'amazon-row)))
        (when row
          (buffer-set-local! buf 'render-blocks (amazon--detail-blocks buf row)))))))
(mode-parent! "amazon-detail-mode" "special-mode")
(mode-doc! "amazon-detail-mode"
  "One product, as its own page. 1, 2 and 3 switch the Overview, Specs and Reviews tabs; m saves it and marks it in the listing, N writes a note that stays on this page, n and p walk the listing's pages, c adds it to the cart and C opens the cart itself, o opens it in the real browser, w copies its link, g reads the listing again, q puts it away. C-` walks the other pages opened from this listing, C-M-` walks back, and M-RET keeps this one so the next row opens a fresh page.")
(mode-keys! "amazon-detail-mode"
  (list (list "1" "amazon-tab-overview")
        (list "2" "amazon-tab-specs")
        (list "3" "amazon-tab-reviews")
        (list "c" "amazon-cart")
        (list "m" "amazon-save")
        (list "N" "amazon-note")
        (list "n" "amazon-next-page")
        (list "p" "amazon-prev-page")
        (list "o" "amazon-open")
        (list "w" "amazon-copy-link")
        (list "g" "amazon-reload-detail")
        (list "C" "amazon-goto-cart")
        (list "q" "quit-window")))

(define-command "amazon-goto-cart" "Show the cart in the listing; again goes back to the search"
  (lambda () (amazon-goto-cart!)))

(mode-keys! "amazon-mode" (list (list "C" "amazon-goto-cart")))

;; The listing and the page are one surface: a key the listing does not claim
;; runs in the page beside it, so 1, 2 and 3 turn the product's tabs from the
;; row that opened it and the focus never leaves the list.
(when (boundp 'app-detail-keys!)
  (app-detail-keys! "amazon-mode" "amazon-detail-mode"))

;; a kept page takes the product's name, not a number
(detail-name! "amazon-detail-mode"
  (lambda (buf) (string-append "*" (or (buffer-local buf 'amazon-title) "amazon") "*")))

;; the listing and every page it opens wear the Amazon mark
(mode-icon! "amazon-mode" "")
(mode-icon! "amazon-detail-mode" "")


;;; --- the layout ----------------------------------------------------------
;;; Three panes -- the group's chat, the listing, the page -- handed to the
;;; responsive tiler, which makes them three columns on a wide frame and
;;; stacks them on a narrow one. No split here decides a width.

(define (amazon-current-detail)
  (let ((row (list-current *amazon-buffer*)))
    (and row (amazon-detail-buffer row))))

;;; The third column is whichever product page is already on screen -- the one
;;; you are reading keeps its place. Only when none is showing does the listing's
;;; current row decide, and a page opened before a rename still counts: every
;;; detail buffer carries its row, whatever it is called.
(define (amazon--detail-pane)
  (let ((shown (let loop ((ws (window-list)))
                 (cond ((null? ws) #f)
                       ((and (not (equal? (car (cdr (car ws))) *amazon-buffer*))
                             (buffer-local (car (cdr (car ws))) 'amazon-row))
                        (car (cdr (car ws))))
                       (else (loop (cdr ws)))))))
    (or shown
        (let ((want (amazon-current-detail)))
          (and want (buffer-exists? want) want)))))

(define (amazon-layout!)
  (let* ((id (amazon-home-group!))
         (chat (and id (boundp 'group-chat) (group-chat id)))
         (panes (filter (lambda (b) (and b (buffer-exists? b)))
                        (list *amazon-buffer* (amazon--detail-pane) chat))))
    ;; three columns: the app names the layout it wants, so the panes do not
    ;; depend on what the frame happened to hold. The listing leads because tile-windows!
    ;; clears the frame and fills from the selected window outward: the first
    ;; buffer lands in the pane you were already in and keeps the focus. Lead
    ;; with the chat and the app opens beside you instead of under your hands.
    (when (pair? (cdr panes)) (tile-windows! 'columns panes))
    (let ((home (window-showing *amazon-buffer*)))
      (when home (select-window! home)))
    panes))

;;; --- opening it ----------------------------------------------------------

(define (amazon-open! query)
  (amazon-open-page! query 1 #t))

;;; One page of a search. FIRST? opens the app around the listing -- the group,
;;; the mode, the layout; paging with n and p only swaps the rows underneath.
(define (amazon-open-page! query page first?)
  (unless (buffer-exists? *amazon-buffer*) (buffer-create *amazon-buffer*))
  (amazon-join-group! *amazon-buffer*)
  (buffer-set-local! *amazon-buffer* 'amazon-query query)
  (message (string-append "Amazon: " query
                          (if (> page 1) (string-append " page " (number->string page)) "")
                          "..."))
  (amazon-fetch-page! query page
    (lambda (rows next)
      (if (or (not rows) (null? rows))
          (message (if rows
                       (string-append "No results on page " (number->string page))
                       "Amazon did not answer -- try again"))
          (begin
            (buffer-set-local! *amazon-buffer* 'amazon-rows rows)
            (buffer-set-local! *amazon-buffer* 'amazon-page page)
            (buffer-set-local! *amazon-buffer* 'amazon-more (and next #t))
            (unless (buffer-derived-mode? *amazon-buffer* "amazon-mode")
              (with-current-buffer *amazon-buffer* (lambda () (set-mode! "amazon-mode"))))
            (list-refresh! *amazon-buffer*)
            ;; mark the rows the cart already holds, not just the ones this
            ;; session put there
            (amazon-cart-sync!)
            (when first? (switch-to-buffer! *amazon-buffer*))
            (amazon-show-detail! (list-current *amazon-buffer*))
            (when first?
              (amazon-layout!)
              (let ((id (amazon-home-group!))) (when id (group-layout-save! id))))
            (message (string-append (number->string (length rows))
                                    " results for " query
                                    " · page " (number->string page))))))))

;;;###autoload
(define-command "amazon" "Open the Amazon app"
  (lambda ()
    (amazon-open! (or (buffer-local *amazon-buffer* 'amazon-query) amazon-default-query))))

;;;###autoload
(define-command "amazon-search" "Search Amazon and fill the listing"
  (lambda ()
    (read-string "Amazon: "
                 (lambda (q)
                   (when (and (string? q) (not (equal? q "")))
                     (amazon-open! q))))))

(define-command "amazon-refresh" "Read the search again"
  (lambda ()
    (amazon-open-page! (or (buffer-local *amazon-buffer* 'amazon-query) amazon-default-query)
                       (amazon-page) #f)))

(define (amazon-page) (or (buffer-local *amazon-buffer* 'amazon-page) 1))
(define (amazon-more?) (buffer-local *amazon-buffer* 'amazon-more))

(define-command "amazon-next-page" "Read the next page of results"
  (lambda ()
    (let ((query (buffer-local *amazon-buffer* 'amazon-query)))
      (cond ((not query) (message "Nothing searched yet"))
            ((not (amazon-more?)) (message "This is the last page"))
            (else (amazon-open-page! query (+ (amazon-page) 1) #f))))))

(define-command "amazon-prev-page" "Read the page before this one"
  (lambda ()
    (let ((query (buffer-local *amazon-buffer* 'amazon-query)))
      (cond ((not query) (message "Nothing searched yet"))
            ((<= (amazon-page) 1) (message "This is the first page"))
            (else (amazon-open-page! query (- (amazon-page) 1) #f))))))

;;; --- the catalog ---------------------------------------------------------

(public! 'amazon-read!
  "(amazon-read! URL SHEET OK? K [RENDER]) — read one Amazon page through SHEET; RENDER #f fetches and falls back to a tab, #t goes straight to a tab, a string waits for that selector")
(public! 'amazon-open!
  "(amazon-open! QUERY) — search the storefront and fill the listing, in the group you are in")
(public! 'amazon-open-page!
  "(amazon-open-page! QUERY PAGE FIRST?) — fill the listing from one page of a search; FIRST? also lays out the three panes")
(public! 'amazon-cart-add!
  "(amazon-cart-add! ASIN) — add one of a product to the signed-in cart, through the reader's browser tab")
(public! 'amazon-show-detail!
  "(amazon-show-detail! ROW) — render ROW as its own page beside the listing")

(public! 'amz-delivery-key
  "(amz-delivery-key TEXT) — the day a delivery line names, as YYYYMMDD; 99999999 when it names none")

(public! 'amazon-save-toggle!
  "(amazon-save-toggle! ASIN) — save or unsave a product; a saved one is marked ★ in the listing")

(public! 'amazon-note-set!
  "(amazon-note-set! ASIN TEXT) — write the note shown on the product's page; \"\" clears it")

(public! 'amazon-hide-toggle!
  "(amazon-hide-toggle! ASIN) — take a product out of the listing, or put it back; a hidden one is marked ⊘ when X shows them")

(catalog-meta! 'function "amazon-read!" 'domain 'web 'effects '(read external))
(catalog-meta! 'function "amazon-open!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "amazon-open-page!" 'domain 'web 'effects '(read write external display))
(catalog-meta! 'function "amazon-cart-add!" 'domain 'web 'effects '(write external))
(catalog-meta! 'function "amazon-show-detail!" 'domain 'web 'effects '(write display))
(catalog-meta! 'function "amz-delivery-key" 'domain 'web 'effects '(read))
(catalog-meta! 'function "amazon-save-toggle!" 'domain 'web 'effects '(write))
(catalog-meta! 'function "amazon-note-set!" 'domain 'web 'effects '(write))
(catalog-meta! 'function "amazon-hide-toggle!" 'domain 'web 'effects '(write))
