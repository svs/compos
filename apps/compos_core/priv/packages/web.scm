;;; web.scm --- browse the web in a buffer.
;;;
;;; M-x browse fetches a page and renders it as readable text. Links show
;;; their label only; the target rides in 'web-links as byte ranges. RET
;;; follows the link at point, TAB and n/p walk the links, l goes back,
;;; g refetches, o opens the page in the real browser. C-s reaches any
;;; link through the ordinary search.
;;;
;;; The fetch is curl, the article extractor (readable), and pandoc,
;;; off the UI lane through the buffer cache: a restored or previewed
;;; buffer draws its saved text and refetches only past the TTL.
;;;
;;; The editor renders TEXT; the browser renders the web. This buffer
;;; is the text reading of a page — `o` hands the page itself to the
;;; real renderer.

(domain! 'web)
(effects! '(read external))

(defface! 'web-link 'fg "#7aa2f7")
(defface! 'web-meta
  'fg "var(--dim-fg)"
  'bg "var(--window-inactive-bg)"
  'weight "600")
(defface! 'web-date 'fg "var(--dim-fg)" 'size "0.82em")
(defface! 'web-separator 'fg "transparent")

;; browser TABS: one buffer per page, every one in the "browse" group.
;; The switcher finds them by mode — typing "browse" narrows to them.
(define (web--buffer? b)
  (equal? (buffer-local b 'mode-name) "browse-mode"))

(define (web--buffer-for url)
  (let loop ((bs (buffer-list-mru)))
    (cond ((null? bs) #f)
          ((and (web--buffer? (car bs))
                (equal? (buffer-local (car bs) 'browse-url) url))
           (car bs))
          (else (loop (cdr bs))))))
(define *web-cache-ttl* 600)

(define (web--shell-quote text)
  (string-append "'" (string-join (string-split text "'") "'\\''") "'"))
;;; --- the two readings -----------------------------------------------------------
;;; One page, one path, two readings.
;;;
;;;   CALM  the page distilled: a site parser when the site has one,
;;;         else Readability. The article, without the nav, the
;;;         subscribe box and the like counts.
;;;   FULL  the whole document as text.
;;;
;;; `R` switches between them. The switch re-reads the html the buffer
;;; already holds, so it costs one conversion and no network.
;;;
;;; A reading is a CHOICE, not a discovery. The reader asks for one in
;;; 'browse-want and gets one in 'browse-reading. The two differ when
;;; calm finds no article: the buffer shows full, and the modeline says
;;; why.

(defcustom 'browse-reading "calm"
  "Which reading a page opens in: \"calm\" for the article alone, \"full\" for the whole document."
  'group 'web 'type 'string)

;; the reading name, normalized. Anything that is not full is calm.
(define (web--reading name)
  (if (equal? name "full") "full" "calm"))

(define (web--want buf)
  (web--reading
    (or (buffer-local buf 'browse-want)
        (if (boundp 'browse-reading) browse-reading "calm"))))

;;; --- sites ----------------------------------------------------------------------
;;; One row per site the readings get wrong on their own. Two sites need
;;; two different things, so a row says both.

;;   PARSER   a stylesheet under web/parsers, or #f for Readability
;;   RENDER?  #t when the server answers a fetch with a script shell, so
;;            the reading needs a real tab. substack.com sends 9 KB of
;;            scaffolding to a fetch and 123 KB of feed to a tab.
(define *web--sites*
  '(("https://substack.com" "substack.xsl" #t)
    ("https://html.duckduckgo.com" "duckduckgo.xsl" #f)
    ("https://mukeshbishnoi.com" "mukeshbishnoi.xsl" #f)
    ("https://www.mukeshbishnoi.com" "mukeshbishnoi.xsl" #f)))

(define (web--site url)
  (let loop ((sites *web--sites*))
    (cond ((null? sites) #f)
          ((let ((base (car (car sites))))
             (or (equal? url base)
                 (string-prefix? (string-append base "/") url)))
           (car sites))
          (else (loop (cdr sites))))))

(define (web--site-parser url)
  (let ((site (web--site url)))
    (and site (car (cdr site)))))

(define (web--site-render? url)
  (let ((site (web--site url)))
    (and site (car (cdr (cdr site))) #t)))

;;; --- reading the html -----------------------------------------------------------

;; no hard wrap: a paragraph is ONE line, and the window wraps it at its
;; own width like any buffer text
(define *web--pandoc*
  " | pandoc --wrap=none -f html-native_divs-native_spans -t gfm-raw_html")

;; A reading is ONE command over one file. No cascade lives inside it: a
;; short answer is not an error here, and what a short answer means is
;; web--attempt's decision, above.
(define (web--calm-command url file)
  (let ((sheet (web--site-parser url)))
    (string-append
      (if sheet
          (string-append
            "xsltproc --html "
            (web--shell-quote
              (string-append (compos-priv-dir) "/packages/web/parsers/" sheet))
            " ")
          (string-append "readable --base " (web--shell-quote url) " "))
      (web--shell-quote file) " 2>/dev/null" *web--pandoc*)))

(define (web--full-command file)
  (string-append "cat " (web--shell-quote file) *web--pandoc*))

;; A nested table layout defeats pandoc, which writes a "[TABLE]"
;; placeholder instead of the rows. Flattening the table tags gives the
;; page back as lines, with its links intact.
(define (web--flatten-command file)
  (string-append
    "perl -pe 's{</?(?:table|tbody|thead|tr|td|th)\\b[^>]*>}{ }gi' < "
    (web--shell-quote file) *web--pandoc*))

;; under this many bytes a reading found nothing worth showing
(define *web--thin-bytes* 200)

(define (web--thin? md)
  (or (not (string? md))
      (< (string-byte-length (string-trim md)) *web--thin-bytes*)))

;; Every read gets its own file. Two tabs that fetch at once must not
;; read each other's page.
(define *web--read-seq* 0)

(define (web--write-html! html)
  (set! *web--read-seq* (+ *web--read-seq* 1))
  (let ((file (string-append (compos-home) "/browse-fetch-"
                             (number->string *web--read-seq*) ".html")))
    (write-file! file html)
    file))

;; FILE of html -> markdown for one READING. K gets the markdown, or #f.
(define (web--read url file reading k)
  (shell-command->string
    (if (equal? reading "full")
        (web--full-command file)
        (web--calm-command url file))
    (lambda (md)
      (cond
        ;; The table rescue comes FIRST. A page laid out in nested
        ;; tables — news.ycombinator.com is one — reads as the eight
        ;; bytes "[TABLE]\n", which the thin test would throw away.
        ((and (equal? reading "full")
              (string? md)
              (string-contains? md "[TABLE]"))
         (shell-command->string (web--flatten-command file)
           (lambda (flat) (k (if (web--thin? flat) #f flat)))))
        ((web--thin? md) (k #f))
        (else (k md))))))

;;; --- fetching -------------------------------------------------------------------
;;; The browser fetches, not curl: the user's cookies and Chrome's http
;;; cache ride along, so a page that knows them logged in reads logged
;;; in, and a search that refuses curl answers a browser. A plain fetch
;;; costs about a quarter second.
;;;
;;; A SNAPSHOT loads the page in a real background tab, so scripts and
;;; SSO redirects run and the reader gets the rendered document. It
;;; costs about ten times a fetch, so only a page that needs it pays:
;;; a site the registry marks, or a server that sent no document at all.

;; the cache fetch sets this when it holds a copy to fall back on: the
;; fetch then sends the page's saved ETag, and a 304 costs headers only
(define *web--revalidate* #f)

;; URL -> the raw html. Tests replace this seam. REVALIDATE? sends the
;; page's saved ETag (curl --etag-compare): an unchanged page answers
;; 304 with no body — headers only — and the caller serves its copy.
(define (web--curl-html url k revalidate?)
  (let ((u (web--shell-quote url))
        (dir (web--shell-quote (string-append (compos-home) "/web-etags"))))
    (shell-command->string
      (string-append
        "mkdir -p " dir "; "
        "e=" dir "/$(printf %s " u " | cksum | cut -d' ' -f1); "
        "t=$(mktemp); "
        "curl -sL --max-time 20 --etag-save \"$e.new\" "
        (if revalidate? "--etag-compare \"$e\" " "")
        u " -o \"$t\"; "
        "if [ -s \"$t\" ]; then mv -f \"$e.new\" \"$e\"; cat \"$t\"; fi; "
        "rm -f \"$t\" \"$e.new\"")
      (lambda (out) (k (if (equal? (string-trim out) "") #f out))))))

;; RENDER? asks for the rendered document, from a real tab. With no
;; browser at all, curl answers either way.
(define (web--html-pipeline url k &optional revalidate? render?)
  ((if render? browser-snapshot browser-fetch) url
    (lambda (html)
      (if html (k html) (web--curl-html url k revalidate?)))))

(define *web-fetch-html* web--html-pipeline)

;;; --- the pipeline ---------------------------------------------------------------

;; URL and the WANTed reading -> the reading that was found, its
;; markdown, and the html it came from. K gets that list, or (#f #f #f).
(define (web--pipeline url want k)
  (web--attempt url (web--reading want) (web--site-render? url) k))

;; Fetch, then read. RENDERED? says this html came from a real tab, so
;; an empty answer stops instead of asking for a tab again.
(define (web--attempt url want rendered? k)
  (*web-fetch-html* url
    (lambda (html)
      (if (not html)
          (k (list #f #f #f))
          (let ((file (web--write-html! html)))
            (web--read url file want
              (lambda (md)
                (cond
                  (md (web--answer file (list want md html) k))
                  ;; Calm found no article. That is an answer, not a
                  ;; failure: an index page IS its links, so read it
                  ;; whole. Full finding nothing is the real failure.
                  ((equal? want "calm")
                   (web--read url file "full"
                     (lambda (full)
                       (if full
                           (web--answer file (list "full" full html) k)
                           (web--retry url want file rendered? k)))))
                  (else (web--retry url want file rendered? k))))))))
    *web--revalidate*
    rendered?))

(define (web--answer file result k)
  (delete-file! file)
  (k result))

;; No document at all: the server sent a script shell, and only a real
;; tab renders one.
(define (web--retry url want file rendered? k)
  (delete-file! file)
  (if rendered?
      (k (list #f #f #f))
      (web--attempt url want #t k)))

(define *web-fetch* web--pipeline)

;;; --- visited sites --------------------------------------------------------------
;;; Every rendered page remembers itself: one "URL TITLE" line, newest
;;; first. The browse prompt completes over them, and the title matches
;;; what you type.

(define *web-visited-file* (string-append (compos-home) "/web-visited"))
(define *web-visited-max* 200)

(define (web--visited)
  (let ((text (read-file *web-visited-file*)))
    (if (string? text)
        (filter pair?
          (map (lambda (line)
                 (let ((l (string-trim line)))
                   (if (equal? l "")
                       #f
                       (let ((sp (string-index l " ")))
                         (if sp
                             (list (substring-bytes l 0 sp)
                                   (substring-bytes l (+ sp 1)
                                                    (string-byte-length l)))
                             (list l ""))))))
               (string-split text "\n")))
        '())))

(define (web--remember-visit! url title)
  (let ((all (take-n (cons (list url title)
                           (filter (lambda (e) (not (equal? (car e) url)))
                                   (web--visited)))
                     *web-visited-max*)))
    (write-file! *web-visited-file*
      (string-append
        (string-join (map (lambda (e)
                            (string-trim
                              (string-append (car e) " " (car (cdr e)))))
                          all)
                     "\n")
        "\n"))))

;; the page's title: its first heading, else its first line of text
(define (web--title md)
  (let loop ((ls (string-split md "\n")) (first #f))
    (cond ((null? ls) (or first ""))
          ((string-prefix? "# " (car ls))
           (string-trim
             (substring-bytes (car ls) 2 (string-byte-length (car ls)))))
          (else
            (let ((t (string-trim (car ls))))
              (loop (cdr ls)
                    (or first
                        (and (not (equal? t ""))
                             (if (> (string-length t) 80)
                                 (substring t 0 80)
                                 t)))))))))

;;; --- markdown -> text + links ---------------------------------------------------
;;; The editor renders TEXT — that is the one thing it does well, so it
;;; is the one thing the reader asks of it. The markdown becomes plain
;;; text: link labels stay and wear the link face, the targets ride in
;;; 'web-links as byte ranges, and the page furniture of markdown
;;; syntax — heading marks, rules, escapes — goes. A page that needs
;;; more than text wants `o` and the real browser.

;; the markdown, before the links strip: heading marks and rules drop,
;; pandoc's escapes unescape, blank runs collapse
(define (web--unescape s)
  (fold (lambda (acc p) (string-join (string-split acc (car p)) (cadr p)))
        s
        '(("\\|" "|") ("\\[" "[") ("\\]" "]") ("\\*" "*")
          ("\\_" "_") ("\\`" "`") ("\\$" "$") ("\\#" "#"))))

(define (web--rule-line? l)
  (and (> (string-length l) 3)
       (equal? "" (string-join (string-split l "-") ""))))

;; a label-less link renders as nothing — an image, an icon anchor.
;; An IMAGE stays, as a link the reader can follow into the browser;
;; the rest goes, before the blank collapse leaves their empty lines
;; behind. A link-wrapped image is one image, not two.
(define (web--image-url? u)
  (or (string-contains? u ".png") (string-contains? u ".jpg")
      (string-contains? u ".jpeg") (string-contains? u ".gif")
      (string-contains? u ".webp") (string-contains? u ".avif")
      (string-contains? u "/image/")))

(define *web--empty-link-pattern* "!?\\[\\]\\(([^)\\s]*)\\)")

;;; Both link passes below walk ONE list of match ranges and collect
;;; their output in chunks. The two habits they avoid each cost the
;;; square of the page size:
;;;
;;;   re-find from a moving offset — Regex.run(offset:) scans from the
;;;     start every call. One re-find* pass over a 640 KB page finds
;;;     1896 matches in 7 ms; 1896 offset calls take 520 ms.
;;;   string-append onto one growing answer — every match copies the
;;;     whole page written so far.
;;;
;;; A match is "[label](target)", or the same with a leading "!". The
;;; label holds no "]" and the target holds no ")", so one index inside
;;; the match finds both.

(define (web--link-parts m)
  (let ((close (string-index m "]"))
        (len (string-byte-length m)))
    (if (and close (< (+ close 2) len))
        (list (substring-bytes m (if (string-prefix? "!" m) 2 1) close)
              (substring-bytes m (+ close 2) (- len 1)))
        (list "" ""))))

(define (web--fix-empty-links s)
  (let loop ((hits (re-find* *web--empty-link-pattern* s))
             (pos 0) (chunks '()) (last-wrapper? #f))
    (if (null? hits)
        (string-join
          (reverse (cons (substring-bytes s pos (string-byte-length s)) chunks))
          "")
        (let* ((ms (car (car hits)))
               (me (car (cdr (car hits))))
               (url (car (cdr (web--link-parts (substring-bytes s ms me)))))
               (before (substring-bytes s pos ms))
               (between (string-trim before))
               (head (cons before chunks))
               (image-syntax? (equal? (substring-bytes s ms (+ ms 1)) "!"))
               (img? (web--image-url? url)))
          (cond
            ;; Drop only an image nested in an empty link wrapper.
            ;; Adjacent standalone images are separate content.
            ((and img? last-wrapper? image-syntax? (equal? between ""))
             (loop (cdr hits) me head #f))
            ;; The URL becomes the label. The img-embed face draws it.
            (img?
             (loop (cdr hits) me
                   (cons (string-append "[" url "](" url ")") head)
                   (not image-syntax?)))
            (else
             (loop (cdr hits) me head
                   (and last-wrapper? (equal? between "")))))))))

(define (web--tidy md)
  (let loop ((ls (string-split (web--unescape (web--fix-empty-links md)) "\n"))
             (out '()) (blanks 0))
    (if (null? ls)
        (string-join (reverse out) "\n")
        (let* ((l (car ls))
               (l (if (string-prefix? "#" l)
                      (let strip ((s l))
                        (cond ((string-prefix? "#" s)
                               (strip (substring-bytes s 1 (string-byte-length s))))
                              ((string-prefix? " " s)
                               (substring-bytes s 1 (string-byte-length s)))
                              (else s)))
                      l))
               (l (if (web--rule-line? (string-trim l)) "" l))
               (blank? (equal? (string-trim l) "")))
          (loop (cdr ls)
                (if (and blank? (>= blanks 1)) out (cons l out))
                (if blank? (+ blanks 1) 0))))))

;; [label](url) and ![label](url) become the label; the output byte
;; range and the target collect in LINKS. Anchors (#...) stay plain.
(define *web--link-pattern* "!?\\[([^]]*)\\]\\(([^)\\s]*)\\)")

;; LEN counts the output bytes written so far, so a label's range is
;; arithmetic. Measuring one growing string instead rebuilds the page
;; per link — see web--link-parts above for both traps.
(define (web--parse md)
  (let loop ((hits (re-find* *web--link-pattern* md))
             (pos 0) (chunks '()) (len 0) (links '()))
    (if (null? hits)
        (list (string-join
                (reverse (cons (substring-bytes md pos (string-byte-length md)) chunks))
                "")
              (reverse links))
        (let* ((ms (car (car hits)))
               (me (car (cdr (car hits))))
               (parts (web--link-parts (substring-bytes md ms me)))
               (label (car parts))
               (url (car (cdr parts)))
               (before (substring-bytes md pos ms))
               (start (+ len (string-byte-length before)))
               (end (+ start (string-byte-length label))))
          (loop (cdr hits) me
                (cons label (cons before chunks))
                end
                (if (or (equal? label "") (string-prefix? "#" url))
                    links
                    (cons (list start end url) links)))))))

;; a link target against the page it came from: absolute stays, //host
;; takes the scheme, /path takes the origin, anything else appends to the
;; page's directory
;; A search engine wraps every result in a redirect of its own.
;; The reader follows the RESULT: DuckDuckGo carries the real target
;; in a uddg= parameter, so RET lands on the page, not on the hop.
(define *web--redirect-pattern* "[?&]uddg=([^&]*)")

(define (web--unwrap url)
  (let ((hit (re-find *web--redirect-pattern* url 0)))
    (if (not hit)
        url
        (let* ((gs (re-groups *web--redirect-pattern* url (car hit)))
               (r (car (cdr gs)))
               (target (url-decode (substring-bytes url (car r) (car (cdr r))))))
          (if (string-contains? target "://") target url)))))

(define (web--resolve raw base)
  (let ((url (web--unwrap raw)))
  (cond ((string-contains? url "://") url)
        ((string-prefix? "//" url)
         (string-append (car (string-split base "://")) ":" url))
        ((string-prefix? "/" url)
         (let* ((scheme-end (+ (string-index base "://") 3))
                (host-end (string-index base "/" scheme-end)))
           (string-append
             (if host-end (substring-bytes base 0 host-end) base)
             url)))
        (else
          (let* ((q (string-index base "?"))
                 (clean (if q (substring-bytes base 0 q) base))
                 (slash (string-rindex clean "/")))
            (if (and slash (> slash (+ (string-index clean "://") 2)))
                (string-append (substring-bytes clean 0 (+ slash 1)) url)
                (string-append clean "/" url)))))))

;; the public name: other packages (feeds) resolve their links the
;; same one way
(define (url-resolve url base) (web--resolve url base))

;;; --- rendering ------------------------------------------------------------------

;; The modeline names the reading on screen. When that is not the
;; reading the person asked for, it says why — otherwise `R` looks
;; broken on a page that has no article to show.
(define (web--reading-label buf)
  (let ((reading (buffer-local buf 'browse-reading)))
    (cond ((not reading) "")
          ((equal? reading (web--want buf)) (string-append reading " · "))
          (else (string-append reading " (no article) · ")))))

(define (web--update-modeline! buf)
  (buffer-set-local! buf 'modeline-info
    (string-append
      (web--reading-label buf)
      (or (buffer-local buf 'browse-url) "")
      (let ((age (cache-age-label buf)))
        (if age (string-append " · " age) "")))))

(define (web--render! buf md)
  (let* ((parsed (web--parse (web--tidy md)))
         (text (car parsed))
         (links (car (cdr parsed))))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 text)
    (buffer-set-read-only! buf #t)
    (buffer-set-local! buf 'web-links links)
    (buffer-set-local! buf 'render-mode #f)
    (web--apply-link-faces! buf)
    (web--apply-meta-faces! buf)
    (web--apply-separator-faces! buf)
    (buffer-goto! buf 0)
    (web--update-modeline! buf)
    ;; the page is real now: it joins the visited list, title and all
    (let ((url (buffer-local buf 'browse-url)))
      (when url (web--remember-visit! url (web--title md))))))

;; overlays are runtime: the mode setup rebuilds them from 'web-links.
;; Image links embed pictures. Short note links use the compact date face.
(define (web--date-link? link)
  (let ((start (car link))
        (end (car (cdr link)))
        (url (car (cdr (cdr link)))))
    (and (string-contains? url "/note/")
         (<= (- end start) 12))))

(define (web--meta-offset line)
  (let ((like (re-find "♥ " line 0))
        (comment (re-find "💬 " line 0))
        (restack (re-find "↻ " line 0)))
    (cond (like (car like))
          (comment (car comment))
          (restack (car restack))
          (else #f))))
(define (web--apply-link-faces! buf)
  (overlay-set! buf 'web
    (map (lambda (l)
           (list (car l) (car (cdr l))
                 (cond
                   ((web--image-url? (car (cdr (cdr l)))) "img-embed")
                   ((web--date-link? l) "web-date")
                   (else "web-link"))))
         (or (buffer-local buf 'web-links) '()))))

(define (web--meta-ranges text)
  (let loop ((lines (string-split text "\n"))
             (pos 0)
             (ranges '()))
    (if (null? lines)
        (reverse ranges)
        (let* ((line (car lines))
               (len (string-byte-length line))
               (next (+ pos len 1))
               (offset (web--meta-offset line)))
          (loop (cdr lines)
                next
                (if offset
                    (cons (list (+ pos offset) (+ pos len) "web-meta") ranges)
                    ranges))))))

(define (web--apply-meta-faces! buf)
  (overlay-set! buf 'web-meta
    (web--meta-ranges (buffer-text buf))))

(define *web--article-separator* "COMPOS-ARTICLE-SEPARATOR")

(define (web--article-separator-ranges text)
  (let loop ((lines (string-split text "\n"))
             (pos 0)
             (ranges '()))
    (if (null? lines)
        (reverse ranges)
        (let* ((line (car lines))
               (len (string-byte-length line))
               (next (+ pos len 1)))
          (loop (cdr lines)
                next
                (if (equal? line *web--article-separator*)
                    (cons (list pos (+ pos len) "web-separator") ranges)
                    ranges))))))

(define (web--apply-separator-faces! buf)
  (overlay-set! buf 'web-separator
    (web--article-separator-ranges (buffer-text buf))))

(define (web--declare-cache! buf)
  (cache-declare! buf
    ;; the mode can wake before its first URL — nothing to fetch yet.
    ;; Holding a session copy, the fetch revalidates; a 304 — or a
    ;; failed network — serves the copy we hold.
    (lambda (b k)
      (let* ((url (buffer-local b 'browse-url))
             (hit (and url (web--page-cached b url))))
        (if (not url)
            (k #f)
            (begin
              (set! *web--revalidate* (and hit #t))
              (*web-fetch* url (web--want b)
                (lambda (found)
                  (let ((md (and (pair? found) (nth 1 found))))
                    (cond (md (k found))
                          ;; the copy we hold beats an empty view
                          (hit (k (list (nth 1 hit) (nth 2 hit) #f)))
                          (else (k #f))))))))))
    ;; a fetch completion is the one moment a page enters the session
    ;; cache — serving from it must not refresh its age
    (lambda (b found)
      (let ((reading (nth 0 found))
            (md (nth 1 found))
            (html (nth 2 found)))
        (buffer-set-local! b 'browse-reading reading)
        ;; the html stays so `R` can re-read it without a fetch
        (buffer-set-local! b 'browse-html html)
        (web--page-remember! b (buffer-local b 'browse-url) reading md)
        (web--render! b md)))
    *web-cache-ttl*))

;;; --- navigation -----------------------------------------------------------------

;;; every page read this session keeps its markdown: back, forward and
;;; a jump to a visited URL serve instantly, like a browser's cache.
;;; `g` on the page refetches for real. The store is session-only —
;;; the desktop skips it, and a restart reads fresh.

(define *web-page-cache-max* 20)

;; an entry is (URL READING MD TIME): a served copy still names the
;; reading it was read in
(define (web--page-remember! buf url reading md)
  (buffer-set-local! buf 'browse-pages
    (take-n (cons (list url reading md (current-time))
                  (filter (lambda (e) (not (equal? (car e) url)))
                          (or (buffer-local buf 'browse-pages) '())))
            *web-page-cache-max*)))

(define (web--page-cached buf url)
  (assoc url (or (buffer-local buf 'browse-pages) '())))

(define (web--goto-url! buf url push?)
  (let ((here (buffer-local buf 'browse-url)))
    (when (and push? here (not (equal? here url)))
      (buffer-set-local! buf 'browse-history
        (cons here (or (buffer-local buf 'browse-history) '())))
      ;; a new page starts a new future: forward clears, like a browser
      (buffer-set-local! buf 'browse-forward '())))
  (buffer-set-local! buf 'browse-url url)
  (let ((hit (web--page-cached buf url)))
    (if hit
        (begin
          ;; the page's own age drives the TTL: a wake still refreshes
          ;; one that has grown old
          (buffer-set-local! buf 'cache-time (nth 3 hit))
          (buffer-set-local! buf 'browse-reading (nth 1 hit))
          ;; a served copy is markdown, not html: `R` on it must fetch
          (buffer-set-local! buf 'browse-html #f)
          (web--render! buf (nth 2 hit)))
        (begin
          ;; a new page: the old stamp must not satisfy the TTL
          (buffer-set-local! buf 'cache-time #f)
          (web--update-modeline! buf)
          (message (string-append "fetching " url " …"))
          (cache-refresh! buf)))))

(define (web--link-at buf p)
  (let loop ((ls (or (buffer-local buf 'web-links) '())))
    (cond ((null? ls) #f)
          ((and (>= p (car (car ls))) (< p (car (cdr (car ls))))) (car ls))
          (else (loop (cdr ls))))))

;; the first link starting after P, or the last one starting before it —
;; the two directions of TAB
(define (web--link-after buf p)
  (let loop ((ls (or (buffer-local buf 'web-links) '())) (best #f))
    (cond ((null? ls) best)
          ((and (> (car (car ls)) p)
                (or (not best) (< (car (car ls)) (car best))))
           (loop (cdr ls) (car ls)))
          (else (loop (cdr ls) best)))))

(define (web--link-before buf p)
  (let loop ((ls (or (buffer-local buf 'web-links) '())) (best #f))
    (cond ((null? ls) best)
          ((and (< (car (car ls)) p)
                (or (not best) (> (car (car ls)) (car best))))
           (loop (cdr ls) (car ls)))
          (else (loop (cdr ls) best)))))

(effects! '(write external))

(define-command "browse-follow" "Follow the link at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (l (web--link-at buf (point))))
      (if (not l)
          (message "no link here")
          (let ((url (web--resolve (car (cdr (cdr l)))
                                   (or (buffer-local buf 'browse-url) ""))))
            ;; an image is not text: the browser renders it
            (if (web--image-url? url)
                (tab-open url)
                (web--goto-url! buf url #t)))))))

;; Cmd-RET, the browser reflex: the link at point opens as its own tab
(define-command "browse-follow-new-tab" "Open the link at point in a new tab"
  (lambda ()
    (let* ((buf (current-buffer))
           (l (web--link-at buf (point))))
      (if (not l)
          (message "no link here")
          (let ((url (web--resolve (car (cdr (cdr l)))
                                   (or (buffer-local buf 'browse-url) ""))))
            (if (web--image-url? url)
                (tab-open url)
                (web--open-tab! url)))))))

(define-command "browse-next-link" "Move point to the next link"
  (lambda ()
    (let* ((buf (current-buffer))
           (l (web--link-after buf (point))))
      (if l (goto-char! (car l)) (message "no more links")))))

(define-command "browse-prev-link" "Move point to the previous link"
  (lambda ()
    (let* ((buf (current-buffer))
           (l (web--link-before buf (point))))
      (if l (goto-char! (car l)) (message "no earlier links")))))

(define-command "browse-back" "Go back to the previous page"
  (lambda ()
    (let* ((buf (current-buffer))
           (h (or (buffer-local buf 'browse-history) '()))
           (here (buffer-local buf 'browse-url)))
      (if (null? h)
          (message "no earlier page")
          (begin
            (when here
              (buffer-set-local! buf 'browse-forward
                (cons here (or (buffer-local buf 'browse-forward) '()))))
            (buffer-set-local! buf 'browse-history (cdr h))
            (web--goto-url! buf (car h) #f))))))

(define-command "browse-forward" "Go forward to the page you came back from"
  (lambda ()
    (let* ((buf (current-buffer))
           (f (or (buffer-local buf 'browse-forward) '()))
           (here (buffer-local buf 'browse-url)))
      (if (null? f)
          (message "no later page")
          (begin
            (when here
              (buffer-set-local! buf 'browse-history
                (cons here (or (buffer-local buf 'browse-history) '()))))
            (buffer-set-local! buf 'browse-forward (cdr f))
            (web--goto-url! buf (car f) #f))))))

;; g asks WHERE: this page leads as the default, so a plain RET
;; refetches it — and the visited sites complete, so g also goes
;; elsewhere without leaving the buffer
(define-command "browse-refresh" "Fetch a page: this one again, or another"
  (lambda ()
    (let* ((buf (current-buffer))
           (cur (buffer-local buf 'browse-url)))
      (if (not cur)
          (run-command "browse")
          (minibuffer-read* "Go to (default this page): "
            (cons (list cur "this page — refetch")
                  (filter (lambda (e) (not (equal? (car e) cur)))
                          (web--visited)))
            (list (list 'match-hint 1)
                  (list 'confirm
                        (lambda (url)
                          (let ((u (string-trim url)))
                            (cond ((or (equal? u "") (equal? u cur))
                                   (buffer-set-local! buf 'cache-time #f)
                                   (message "fetching…")
                                   (cache-refresh! buf))
                                  (else (browse u))))))))))))

;; the ORIGINAL page is the browser's job — the editor renders text,
;; and for everything else there is a real renderer one key away
;; The switch re-reads the html this buffer already holds: one
;; conversion, no network. Only a page served from the session copy —
;; which keeps markdown, not html — has to fetch again.
(define (web--reread! buf)
  (let ((html (buffer-local buf 'browse-html))
        (url (buffer-local buf 'browse-url))
        (want (web--want buf)))
    (message (string-append "reading " want " …"))
    (cond
      ((not url) (message "no page here"))
      ((not html)
       (buffer-set-local! buf 'cache-time #f)
       (cache-refresh! buf))
      (else
        (let ((file (web--write-html! html)))
          (web--read url file want
            (lambda (md)
              (delete-file! file)
              (if md
                  (begin
                    (buffer-set-local! buf 'browse-reading want)
                    (web--page-remember! buf url want md)
                    (web--render! buf md))
                  ;; the page has no article: it stays whole, and the
                  ;; modeline says so
                  (begin
                    (web--update-modeline! buf)
                    (message "no article on this page — showing it whole"))))))))))

(define-command "browse-toggle-reading" "Switch between the calm and the full reading"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'browse-want
        (if (equal? (web--want buf) "calm") "full" "calm"))
      (web--reread! buf))))

(define-command "browse-open-external" "Open this page in the real browser"
  (lambda ()
    (let ((url (buffer-local (current-buffer) 'browse-url)))
      (when url (tab-open url)))))

(define (web--install-keys! buf)
  (local-set-key* buf "RET" "browse-follow")
  (local-set-key* buf "s-RET" "browse-follow-new-tab")
  (local-set-key* buf "TAB" "browse-next-link")
  (local-set-key* buf "n" "browse-next-link")
  (local-set-key* buf "p" "browse-prev-link")
  (local-set-key* buf "l" "browse-back")
  (local-set-key* buf "M-<left>" "browse-back")
  (local-set-key* buf "M-<right>" "browse-forward")
  (local-set-key* buf "g" "browse-refresh")
  (local-set-key* buf "o" "browse-open-external")
  ;; eww binds R to eww-readable; the same key, the same idea
  (local-set-key* buf "R" "browse-toggle-reading")
  ;; the preview chord: "show me the rendered thing" — the browser
  (local-set-key* buf "C-c C-v" "browse-open-external")
  (local-set-key* buf "q" "quit-window"))

(define-mode "browse-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      ;; the session page cache and the held html are both heavy and
      ;; both derive from the URL: a restart refetches, and the desktop
      ;; must not carry either
      (desktop-skip! buf 'browse-pages)
      (desktop-skip! buf 'browse-html)
      ;; the reading look is the WRITING look: one centered measure for
      ;; prose everywhere — writing-mode owns the class and the setting
      (buffer-set-local! buf 'window-class "writing")
      (buffer-set-local! buf 'line-numbers "off")
      (buffer-set-local! buf 'visual-line-mode #t)
      (when (boundp 'writing-measure)
        (face-remap-in! buf 'writing (list 'measure writing-measure)))
      (when (boundp 'writing-font-family)
        (face-remap-in! buf 'default
          (list 'family writing-font-family
                'size writing-font-size
                'line-height writing-line-height)))
      (web--install-keys! buf)
      (web--apply-link-faces! buf)
      (web--apply-meta-faces! buf)
      (web--apply-separator-faces! buf)
      (web--declare-cache! buf)
      (web--update-modeline! buf)
      ;; a restored page draws its saved text; only a stale one refetches
      (cache-wake! buf))))

(mode-doc! "browse-mode"
  "A web page as readable text, in one of two readings. Calm shows
the article alone; full shows the whole document. R switches
between them without fetching again. RET follows the link at point
and s-RET opens it as its own tab, TAB and n/p walk the links,
M-<left> and l go back, M-<right> goes forward, g asks where to go
- RET refetches this page, a visited site or a fresh URL goes
there - o opens the page in the real browser, and C-s searches to
any link.")

;; the one entry point: normalize, enter the mode, fetch
;; a tab's name: the host, and the page's last path segment
(define (web--slug url)
  (let ((q (web--query url)))
    (if q
        ;; a search names itself by what was asked, not by the engine
        (string-append "search: " q)
        (let* ((tail (car (reverse (string-split url "://"))))
               (parts (filter (lambda (p) (not (equal? p "")))
                              (string-split tail "/")))
               (host (if (pair? parts) (car parts) tail)))
          (if (> (length parts) 1)
              (string-append host "/" (car (reverse parts)))
              host)))))

;; the question a search URL carries, or #f for an ordinary page
(define (web--query url)
  (let ((base (if (boundp 'browse-search-url)
                  browse-search-url
                  "https://html.duckduckgo.com/html/?q=")))
    (and (string-prefix? base url)
         (not (equal? url base))
         (url-decode (substring-bytes url (string-byte-length base)
                                      (string-byte-length url))))))

;; browser-tab semantics: inside a browse buffer the URL navigates IN
;; PLACE; outside, the page's own tab comes up — the one that already
;; shows it, or a fresh one, joined to the "browse" group
;; the page's own tab: the one that already shows it, or a fresh one
(define (web--open-tab! url)
  (let ((existing (web--buffer-for url)))
    (if existing
        (begin (switch-to-buffer! existing) existing)
        (let ((name (string-append "*browse:" (web--slug url) "*")))
          (buffer-create name)
          (buffer-set-local! name 'group "browse")
          (switch-to-buffer! name)
          (set-mode! "browse-mode")
          (web--goto-url! name url #t)
          name))))

;;; --- what the person typed ------------------------------------------------------
;;; One prompt takes both a page and a question, the way a browser's
;;; address bar does. A name that could be a host is one; anything else
;;; is a search.

(defcustom 'browse-search-url "https://html.duckduckgo.com/html/?q="
  "Where a search goes. The query is percent-encoded and appended."
  'group 'web 'type 'string)

;; A host has a dot in its first segment and no space: "gnu.org" and
;; "gnu.org/software" are hosts, "emacs lisp manual" and "readable" are
;; not. localhost is the one host with no dot.
(define (web--url? text)
  (let* ((first (car (string-split text "/")))
         (host (car (string-split first "?"))))
    (and (not (string-contains? text " "))
         (or (equal? host "localhost")
             (string-prefix? "localhost:" host)
             (and (string-contains? host ".")
                  (not (string-prefix? "." host))
                  (not (string-suffix? "." host)))))))

;; the address bar rule: a host gets a scheme, a question gets a search
(define (web--target text)
  (let ((t (string-trim text)))
    (cond ((string-contains? t "://") t)
          ((web--url? t) (string-append "https://" t))
          (else (string-append (if (boundp 'browse-search-url)
                                   browse-search-url
                                   "https://html.duckduckgo.com/html/?q=")
                               (url-encode t))))))

(define (browse url)
  (let ((full (web--target url)))
    (if (web--buffer? (current-buffer))
        (begin (web--goto-url! (current-buffer) full #t)
               (current-buffer))
        (web--open-tab! full))))

;; the prompt completes over the visited sites, and a title matches
;; what you type; a fresh URL still goes through as typed
(define-command "browse" "Open a web page as readable text in a buffer"
  (lambda ()
    (minibuffer-read* "URL: " (web--visited)
      (list (list 'match-hint 1)
            (list 'confirm
                  (lambda (url)
                    (unless (equal? (string-trim url) "")
                      (browse (string-trim url)))))))))

;;; --- catalog ------------------------------------------------------------------

(category! 'web)

;; a design note in the catalog: apropos "custom parser" answers the
;; next agent before they rebuild what was already decided
(catalog-register! 'note 'custom-site-parser
  (string-append
    "Use XSLT for site-specific parsers; do not add a Scheme wrapper for a transform-only parser. "
    "Put the stylesheet under web/parsers. "
    "Add (BASE-URL STYLESHEET RENDER?) to *web--sites*; the stylesheet becomes the calm reading. "
    "Set RENDER? to #t only when the server answers a fetch with a script shell: it costs a real browser tab. "
    "web--calm-command runs xsltproc --html before pandoc. "
    "Preserve useful links, content images, and semantic text in transformed HTML. "
    "Unregistered sites read through readable, and a short calm reading falls back to the full page.")
  'domain 'web
  'effects '(pure)
  'use "create web/parsers/example.xsl; add (\"https://example.com\" \"example.xsl\" #f) to *web--sites*")

(public! 'browse
  "(browse URL) — read URL as text in its own tab buffer (*browse:host/page*); a name that is not a host becomes a search; in a browse buffer it navigates in place")

(public! 'url-resolve
  "(url-resolve URL BASE) — resolve a link target against the page it came from: absolute stays, //host takes the scheme, /path takes the origin, the rest appends to the page's directory")
