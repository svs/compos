;;; feeds.scm --- RSS and Atom subscriptions as a list buffer.
;;;
;;; M-x feeds shows the items of every subscribed feed, newest first.
;;; RET reads an item in the browse reader; o opens it in the real
;;; browser. `a` subscribes a feed — a page URL also works: the
;;; subscribe finds the page's feed link. `d` unsubscribes, `g`
;;; refetches, `/` filters.
;;;
;;; The fetch is curl and xsltproc (web/parsers/feed.xsl), off the UI
;;; lane through the buffer cache. Read items dim. The subscriptions
;;; live in ~/.compos/feeds, one URL per line; the read links live in
;;; ~/.compos/feeds-read.

(domain! 'web)
(effects! '(read external))

(define *feeds-buffer* "*feeds*")
(define *feeds-file* (string-append (compos-home) "/feeds"))
(define *feeds-read-file* (string-append (compos-home) "/feeds-read"))
(define *feeds-read-max* 500)

(defgroup 'feeds "Feeds: read RSS and Atom subscriptions in the editor.")

(defcustom 'feeds-cache-ttl 900
  "Seconds before the feeds list refetches on wake." 'group 'feeds)

(defcustom 'feeds-max-items 200
  "The maximum number of items the feeds list shows." 'group 'feeds)

;;; --- subscriptions --------------------------------------------------------------

(define (feeds--file-lines file)
  (let ((text (read-file file)))
    (if (string? text)
        (filter (lambda (l) (not (equal? l "")))
                (map string-trim (string-split text "\n")))
        '())))

(define (feeds--subscriptions) (feeds--file-lines *feeds-file*))

(define (feeds--save-subscriptions! urls)
  (write-file! *feeds-file*
    (if (null? urls) "" (string-append (string-join urls "\n") "\n"))))

;;; --- read links -----------------------------------------------------------------
;;; The read list loads once and stays in memory; a mark writes it back.
;;; A restart reads the file again.

(define *feeds--read* #f)

(define (feeds--read-urls)
  (unless *feeds--read*
    (set! *feeds--read* (feeds--file-lines *feeds-read-file*)))
  *feeds--read*)

(define (feeds--read? url) (pair? (member url (feeds--read-urls))))

(define (feeds--mark-read! url)
  (let ((all (take-n (cons url (filter (lambda (u) (not (equal? u url)))
                                       (feeds--read-urls)))
                     *feeds-read-max*)))
    (set! *feeds--read* all)
    (write-file! *feeds-read-file*
      (string-append (string-join all "\n") "\n"))))

;;; --- dates ----------------------------------------------------------------------
;;; RSS carries RFC 822 dates ("Tue, 19 Aug 2026 10:00:05 GMT"); Atom
;;; carries ISO 8601 ("2026-08-20T09:30:00Z"). Both become one sortable
;;; key, "YYYYMMDDHHMMSS". An unreadable date sorts oldest.

(define *feeds--no-date* "00000000000000")

(define *feeds--months*
  '(("Jan" "01") ("Feb" "02") ("Mar" "03") ("Apr" "04") ("May" "05")
    ("Jun" "06") ("Jul" "07") ("Aug" "08") ("Sep" "09") ("Oct" "10")
    ("Nov" "11") ("Dec" "12")))

(define (feeds--pad2 s)
  (if (= (string-length s) 1) (string-append "0" s) s))

(define (feeds--time-key part)
  (cond ((re-find "^[0-9]{2}:[0-9]{2}:[0-9]{2}" part 0)
         (string-append (substring-bytes part 0 2)
                        (substring-bytes part 3 5)
                        (substring-bytes part 6 8)))
        ((re-find "^[0-9]{2}:[0-9]{2}" part 0)
         (string-append (substring-bytes part 0 2)
                        (substring-bytes part 3 5)
                        "00"))
        (else "000000")))

(define (feeds--iso-key date)
  (and (re-find "^[0-9]{4}-[0-9]{2}-[0-9]{2}" date 0)
       (string-append
         (string-join (string-split (substring-bytes date 0 10) "-") "")
         (if (> (string-byte-length date) 10)
             (feeds--time-key
               (substring-bytes date 11 (string-byte-length date)))
             "000000"))))

(define (feeds--rfc822-key date)
  (let* ((parts (filter (lambda (p) (not (equal? p "")))
                        (string-split date " ")))
         ;; the leading weekday ("Tue,") is decoration
         (parts (if (and (pair? parts) (string-contains? (car parts) ","))
                    (cdr parts)
                    parts)))
    (and (>= (length parts) 3)
         (let ((m (assoc (nth 1 parts) *feeds--months*)))
           (and m
                (re-find "^[0-9]{4}$" (nth 2 parts) 0)
                (string-append
                  (nth 2 parts)
                  (car (cdr m))
                  (feeds--pad2 (car parts))
                  (if (> (length parts) 3)
                      (feeds--time-key (nth 3 parts))
                      "000000")))))))

(define (feeds--date-key date)
  (or (feeds--iso-key date) (feeds--rfc822-key date) *feeds--no-date*))

(define (feeds--date-label key)
  (if (equal? key *feeds--no-date*)
      ""
      (string-append (substring-bytes key 0 4) "-"
                     (substring-bytes key 4 6) "-"
                     (substring-bytes key 6 8))))

;;; --- the fetch ------------------------------------------------------------------
;;; One shell command fetches every subscription: curl the XML, and
;;; feed.xsl turns it into FEED \t DATE \t LINK \t TITLE lines. A feed
;;; that fails answers nothing and the others still land.

(define (feeds--shell-quote text)
  (string-append "'" (string-join (string-split text "'") "'\\''") "'"))

(define (feeds--item-date e) (nth 1 e))
(define (feeds--item-feed e) (nth 2 e))
(define (feeds--item-link e) (nth 3 e))
(define (feeds--item-title e) (nth 4 e))

;; an entry sorts by its car: (KEY DATE FEED LINK TITLE), newest first
(define (feeds--parse-lines out)
  (let loop ((ls (string-split (or out "") "\n")) (items '()))
    (if (null? ls)
        (reverse (sort items))
        (let ((cells (string-split (car ls) "\t")))
          (loop (cdr ls)
                (if (and (= (length cells) 4)
                         (not (equal? (nth 2 cells) "")))
                    (let ((key (feeds--date-key (nth 1 cells))))
                      (cons (list key (feeds--date-label key)
                                  (nth 0 cells) (nth 2 cells) (nth 3 cells))
                            items))
                    items))))))

(define (feeds--fetch-command urls)
  (let ((xsl (feeds--shell-quote
               (string-append (compos-priv-dir)
                              "/packages/web/parsers/feed.xsl"))))
    (string-join
      (map (lambda (u)
             (string-append
               "curl -sL --max-time 15 " (feeds--shell-quote u)
               " 2>/dev/null | xsltproc --novalid " xsl " - 2>/dev/null"))
           urls)
      "; ")))

;; URLS -> sorted entries, in a Task. Tests replace this seam.
(define (feeds--curl-items urls k)
  (if (null? urls)
      (k '())
      (shell-command->string (feeds--fetch-command urls)
        (lambda (out) (k (feeds--parse-lines out))))))

(define *feeds-fetch* feeds--curl-items)

;; the cache fetch: (k #f) on an empty answer keeps the rows the buffer
;; already shows — a dead network must not blank the list
(define (feeds--fetch buf k)
  (let ((subs (feeds--subscriptions)))
    (*feeds-fetch* subs
      (lambda (items)
        (cond ((pair? items) (k (take-n items feeds-max-items)))
              ((null? subs) (k '()))
              (else (k #f)))))))

;;; --- the list -------------------------------------------------------------------

(define (feeds--cells buf e)
  (let ((read? (feeds--read? (feeds--item-link e))))
    (list
      (list (feeds--item-date e) "dim")
      (list (feeds--item-feed e) (if read? "dim" "accent"))
      (if read?
          (list (feeds--item-title e) "dim")
          (feeds--item-title e)))))

(define (feeds--meta buf)
  (string-append
    (number->string (length (list-entries buf))) " items · "
    (number->string (length (feeds--subscriptions))) " feeds"
    (let ((age (cache-age-label buf)))
      (if age (string-append " · " age) ""))))

(effects! '(write external))

;;; --- subscribe ------------------------------------------------------------------
;;; A feed URL subscribes as given. A page URL subscribes its feed: the
;;; page body names it in a rel="alternate" application/rss+xml or
;;; application/atom+xml link, and the href resolves against the page.

(define (feeds--discover-command url)
  (let ((u (feeds--shell-quote url)))
    (string-append
      "body=$(curl -sL --max-time 15 " u " 2>/dev/null); "
      "case \"$body\" in "
      "*'<rss'*|*'<feed'*|*'<rdf'*|*'<RDF'*) printf %s " u ";; "
      "*) printf '%s' \"$body\" | perl -0777 -ne '"
      "while (/<link\\b([^>]*)>/gi) { my $a = $1; "
      "next unless $a =~ m{application/(?:rss|atom)\\+xml}i; "
      "if ($a =~ /href=[\"\\x27]([^\"\\x27]+)/i) { print $1; last } }'"
      " ;; esac")))

;; URL -> the feed URL as printed by the shell, "" when none. Tests
;; replace this seam.
(define (feeds--curl-discover url k)
  (shell-command->string (feeds--discover-command url)
    (lambda (out) (k (string-trim (or out ""))))))

(define *feeds-discover* feeds--curl-discover)

(define (feeds--subscribe! url)
  (let ((full (if (string-contains? url "://")
                  url
                  (string-append "https://" url))))
    (*feeds-discover* full
      (lambda (found)
        (let ((feed (if (equal? found "") full (url-resolve found full))))
          (feeds--save-subscriptions!
            (append (filter (lambda (u) (not (equal? u feed)))
                            (feeds--subscriptions))
                    (list feed)))
          (message (string-append "subscribed " feed))
          ;; the list may not be open yet — a dormant name has no cache
          (when (buffer-known? *feeds-buffer*)
            (cache-refresh! *feeds-buffer*)))))))

;;; --- commands -------------------------------------------------------------------

(define-command "feeds" "Read your RSS and Atom feeds"
  (lambda () (list-mode-show! "feeds-mode")))

(define-command "feeds-refresh" "Refetch every subscribed feed"
  (lambda ()
    (message "fetching feeds…")
    (cache-refresh! *feeds-buffer*)))

(define-command "feeds-open" "Read the item on this row in the browse reader"
  (lambda ()
    (let ((e (list-current *feeds-buffer*)))
      (when e
        (feeds--mark-read! (feeds--item-link e))
        (list-redraw! *feeds-buffer*)
        (browse (feeds--item-link e))))))

(define-command "feeds-open-external" "Open the item on this row in the real browser"
  (lambda ()
    (let ((e (list-current *feeds-buffer*)))
      (when e
        (feeds--mark-read! (feeds--item-link e))
        (list-redraw! *feeds-buffer*)
        (tab-open (feeds--item-link e))))))

(define-command "feeds-subscribe" "Subscribe to a feed — a feed URL, or a page with one"
  (lambda ()
    (minibuffer-read* "Feed URL: " '()
      (list (list 'confirm
                  (lambda (url)
                    (let ((u (string-trim url)))
                      (unless (equal? u "")
                        (message "looking for the feed…")
                        (feeds--subscribe! u)))))))))

(define-command "feeds-unsubscribe" "Unsubscribe a feed"
  (lambda ()
    (let ((subs (feeds--subscriptions)))
      (if (null? subs)
          (message "no subscriptions")
          (minibuffer-read* "Unsubscribe: "
            (map (lambda (u) (list u "")) subs)
            (list (list 'confirm
                        (lambda (url)
                          (let ((u (string-trim url)))
                            (unless (equal? u "")
                              (feeds--save-subscriptions!
                                (filter (lambda (s) (not (equal? s u))) subs))
                              (message (string-append "unsubscribed " u))
                              (when (buffer-known? *feeds-buffer*)
                                (cache-refresh! *feeds-buffer*))))))))))))

(define-list-mode! "feeds-mode"
  (list
    'doc (string-append
           "Items from your subscribed RSS and Atom feeds, newest first. "
           "RET reads the item as text in the browse reader. `o` opens it "
           "in the real browser. `a` subscribes a feed, `d` unsubscribes, "
           "`g` refetches, `/` filters.")
    'buffer *feeds-buffer*
    'rows (lambda (buf) (list-entries buf))
    'cache-fetch feeds--fetch
    'cache-ttl feeds-cache-ttl
    'columns (lambda (buf)
               (list (list "date" 10) (list "feed" 18) (list "title" #f)))
    'cells feeds--cells
    'title (lambda (buf) "Feeds")
    'meta feeds--meta
    'total (lambda (buf) (length (list-entries buf)))
    'footer (lambda (buf)
              '(("RET" "read") ("o" "browser") ("a" "subscribe")
                ("d" "unsubscribe") ("/" "filter") ("g" "refresh")
                ("q" "quit")))
    'key (lambda (buf e) (feeds--item-link e))
    'keys '(("RET" "feeds-open") ("o" "feeds-open-external")
            ("a" "feeds-subscribe") ("d" "feeds-unsubscribe")
            ("g" "feeds-refresh") ("q" "quit-window"))))

;;; --- catalog --------------------------------------------------------------------

(category! 'web)

(public! 'feeds
  "M-x feeds — list the items of every subscribed RSS/Atom feed, newest first; RET reads one as text")
(public! 'feeds-subscribe
  "M-x feeds-subscribe — subscribe a feed URL, or a page URL whose feed link the subscribe finds")

(defrecipe! "read my rss feeds"
  "(feeds)")
