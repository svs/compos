;;; feeds-test.scm --- packages/feeds.scm: subscriptions as a list buffer.
;;;
;;; Every test replaces the two seams (*feeds-fetch*, *feeds-discover*)
;;; and the two files, so nothing here reads the network and nothing
;;; touches the person's own subscriptions. The last test is the one
;;; exception: it runs the real feed.xsl through xsltproc, because that
;;; stylesheet is what turns a feed into the lines the rest reads.

(domain! 'testing)
(effects! '(read))

(define t--feeds-dir (string-append (aimax-home) "/zz-feeds"))
(define t--feeds-lines
  (string-append
    "Ars\tTue, 19 Aug 2026 10:00:05 GMT\thttps://site.test/a\tAlpha article\n"
    "Blog\t2026-08-20T09:30:00Z\thttps://site.test/b\tBeta post\n"
    "Blog\t\thttps://site.test/c\tUndated post\n"))

(define t--feeds-held '())

(effects! '(write))

;; The person's own feed file, read list and seams are globals. Hold each
;; one, point the files at a directory of ours, and put every one back.
(define (t--feeds-setup!)
  (set! t--feeds-held
        (list *feeds-file* *feeds-read-file* *feeds-fetch* *feeds-discover*
              *web-fetch* *feeds--read* *web-visited-file*))
  (shell-command->string (string-append "rm -rf " t--feeds-dir))
  (make-directory! t--feeds-dir)
  (set! *feeds-file* (string-append t--feeds-dir "/feeds"))
  (set! *feeds-read-file* (string-append t--feeds-dir "/feeds-read"))
  (set! *feeds--read* #f)
  (write-file! *feeds-file* "https://site.test/feed.xml\n")
  (write-file! *feeds-read-file* "")
  ;; the reader writes what it visits; a test must not write that into
  ;; the person's own browsing history
  (set! *web-visited-file* (string-append t--feeds-dir "/web-visited"))
  (set! *feeds-fetch*
    (lambda (urls k) (k (feeds--parse-lines t--feeds-lines))))
  (set! *web-fetch*
    (lambda (url want k) (k (list want "# An article\n\nbody text\n" #f)))))

(define (t--feeds-teardown!)
  (for-each (lambda (b)
              (when (or (equal? b *feeds-buffer*)
                        (equal? (buffer-local b 'mode-name) "browse-mode"))
                (buffer-kill! b)))
            (buffer-list))
  (set! *feeds-file* (nth 0 t--feeds-held))
  (set! *feeds-read-file* (nth 1 t--feeds-held))
  (set! *feeds-fetch* (nth 2 t--feeds-held))
  (set! *feeds-discover* (nth 3 t--feeds-held))
  (set! *web-fetch* (nth 4 t--feeds-held))
  (set! *feeds--read* (nth 5 t--feeds-held))
  (set! *web-visited-file* (nth 6 t--feeds-held))
  (shell-command->string (string-append "rm -rf " t--feeds-dir)))

;; the list fetches on a callback, so the rows arrive after the call
(define (t--feeds-show!)
  (list-mode-show! "feeds-mode")
  (wait-until (lambda () (string-contains? (buffer-text *feeds-buffer*) "Beta post"))
              5000 25))

(deftest 'feed-dates-in-both-readings-become-one-sortable-key
  "RSS carries RFC 822 and Atom carries ISO 8601; one key sorts both"
  (lambda ()
    (check-equal! (feeds--date-key "Tue, 19 Aug 2026 10:00:05 GMT") "20260819100005" "RFC 822")
    (check-equal! (feeds--date-key "19 Aug 2026 10:00 +0200") "20260819100000" "no weekday")
    (check-equal! (feeds--date-key "2026-08-20T09:30:00Z") "20260820093000" "ISO 8601")
    (check-equal! (feeds--date-key "2026-08-20") "20260820000000" "a date alone")
    (check-equal! (feeds--date-key "not a date") "00000000000000" "an unreadable date")
    (check-equal! (feeds--date-label "20260820093000") "2026-08-20" "the label")))

(deftest 'items-render-newest-first-with-normalized-dates
  "the key decides the order, and an undated item sorts last"
  (lambda ()
    (t--feeds-setup!)
    (check-true! (t--feeds-show!) "the rows arrive")
    (let* ((text (buffer-text *feeds-buffer*))
           (beta (string-index text "Beta post"))
           (alpha (string-index text "Alpha article"))
           (undated (string-index text "Undated post")))
      (check-true! (< beta alpha) "the newer item comes first")
      (check-true! (< alpha undated) "an undated item sorts last")
      (check-contains! text "2026-08-20" "the newer date")
      (check-contains! text "2026-08-19" "the older date"))
    (t--feeds-teardown!)))

(deftest 'the-row-command-reads-the-item-in-the-browse-reader-and-marks-it-read
  "RET names feeds-open, and feeds-open is what the behaviour is"
  (lambda ()
    (t--feeds-setup!)
    (check-true! (t--feeds-show!) "the rows arrive")
    (check-equal! (cadr (assoc "RET" (plist-get (list-mode-opts "feeds-mode") 'keys)))
                  "feeds-open" "RET names the command")
    ;; the first row is the newest item: Beta, at https://site.test/b
    (run-command "feeds-open")
    (let ((buf "*browse:site.test/b*"))
      (check-true! (wait-until (lambda ()
                                 (and (buffer-known? buf)
                                      (string-contains? (buffer-text buf) "An article")))
                               5000 25)
                   "the reader shows the item")
      (check-equal! (buffer-local buf 'browse-url) "https://site.test/b" "under its own url"))
    (check-true! (feeds--read? "https://site.test/b") "the item is marked read")
    (check-false! (feeds--read? "https://site.test/a") "and the one below it is not")
    (t--feeds-teardown!)))

(deftest 'subscribe-finds-a-pages-feed-link-and-unsubscribe-removes-the-line
  "a person subscribes to a page; the discover seam finds the feed"
  (lambda ()
    (t--feeds-setup!)
    (set! *feeds-discover* (lambda (url k) (k "/blog/feed.xml")))
    (feeds--subscribe! "https://ex.test/blog/post")
    (check-equal! (feeds--subscriptions)
                  '("https://site.test/feed.xml" "https://ex.test/blog/feed.xml")
                  "the relative link resolves against the page")

    ;; a body that already is a feed subscribes as given, and only once
    (set! *feeds-discover* (lambda (url k) (k url)))
    (feeds--subscribe! "https://ex.test/blog/feed.xml")
    (check-equal! (feeds--subscriptions)
                  '("https://site.test/feed.xml" "https://ex.test/blog/feed.xml")
                  "the second subscribe adds no row")

    (feeds--save-subscriptions!
      (filter (lambda (u) (not (equal? u "https://ex.test/blog/feed.xml")))
              (feeds--subscriptions)))
    (check-equal! (feeds--subscriptions) '("https://site.test/feed.xml")
                  "and unsubscribe removes the line")
    (t--feeds-teardown!)))

(deftest 'feed-xsl-turns-rss-and-atom-xml-into-item-lines
  "one stylesheet reads both dialects, and the entity comes back decoded"
  (lambda ()
    (if (equal? (string-trim (shell-command->string "command -v xsltproc || true")) "")
        (check-true! #t "xsltproc is not installed, so the stylesheet is not read here")
        (let ((xsl (priv-path "packages/web/parsers/feed.xsl")))
          (shell-command->string (string-append "rm -rf " t--feeds-dir))
          (make-directory! t--feeds-dir)
          (write-file! (string-append t--feeds-dir "/rss.xml")
            (string-append
              "<?xml version=\"1.0\"?>\n"
              "<rss version=\"2.0\"><channel>\n"
              "  <title>The RSS Blog</title>\n"
              "  <item>\n"
              "    <title>First &amp; foremost</title>\n"
              "    <link>https://rss.test/one</link>\n"
              "    <pubDate>Tue, 19 Aug 2026 10:00:05 GMT</pubDate>\n"
              "  </item>\n"
              "</channel></rss>\n"))
          (write-file! (string-append t--feeds-dir "/atom.xml")
            (string-append
              "<?xml version=\"1.0\"?>\n"
              "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
              "  <title>The Atom Blog</title>\n"
              "  <entry>\n"
              "    <title>Atom entry</title>\n"
              "    <link rel=\"alternate\" type=\"text/html\" href=\"https://atom.test/one\"/>\n"
              "    <link rel=\"self\" href=\"https://atom.test/feed\"/>\n"
              "    <updated>2026-08-20T09:30:00Z</updated>\n"
              "  </entry>\n"
              "</feed>\n"))
          (check-equal!
            (string-trim (shell-command->string
                           (string-append "xsltproc --novalid " xsl " " t--feeds-dir "/rss.xml")))
            "The RSS Blog\tTue, 19 Aug 2026 10:00:05 GMT\thttps://rss.test/one\tFirst & foremost"
            "the RSS item")
          (check-equal!
            (string-trim (shell-command->string
                           (string-append "xsltproc --novalid " xsl " " t--feeds-dir "/atom.xml")))
            "The Atom Blog\t2026-08-20T09:30:00Z\thttps://atom.test/one\tAtom entry"
            "the Atom entry, by its alternate link")
          (shell-command->string (string-append "rm -rf " t--feeds-dir))))))
