;;; web.scm --- browse the web in a buffer.
;;;
;;; M-x browse fetches a page and renders it as readable text. Links show
;;; their label only; the target rides in 'web-links as byte ranges. RET
;;; follows the link at point, M-RET opens it in another window, TAB and
;;; n/p walk the links, l goes back, r goes forward, g refetches, o opens
;;; the page in the real browser. C-s reaches any link through the
;;; ordinary search.
;;;
;;; Every tab keeps its own way back, with the point on each page, and
;;; the desktop keeps it across a restart. Every page read joins one
;;; history file; H lists it, and the browse prompt completes over it.
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
    ("https://news.ycombinator.com" "hackernews.xsl" #f)
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

;; A hard refresh changes the request URL so the browser and HTTP caches
;; cannot reuse the previous response. The displayed page URL remains clean.
(define *web--hard-refresh-seq* 0)
(define (web--cache-bust-url url)
  (set! *web--hard-refresh-seq* (+ *web--hard-refresh-seq* 1))
  (string-append url
                 (if (string-contains? url "?") "&" "?")
                 "_compos_refresh="
                 (number->string *web--hard-refresh-seq*)))

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

;;; --- history --------------------------------------------------------------------
;;; Every rendered page remembers itself in ONE file that outlives the
;;; session: a "URL <TAB> TIME <TAB> TITLE" line per page, newest first.
;;; The browse prompt completes over it, the title matches what you
;;; type, and `H` lists it. A line with no tab is the old "URL TITLE"
;;; shape; it reads with no time and rewrites in the new shape.

(define *web-visited-file* (string-append (compos-home) "/web-history"))
(define *web-visited-legacy-file* (string-append (compos-home) "/web-visited"))
(define *web-visited-max* 500)

;; one line -> (URL TITLE TIME), or #f for a blank line
(define (web--history-entry line)
  (let ((l (string-trim line)))
    (cond ((equal? l "") #f)
          ((string-contains? l "\t")
           (let* ((parts (string-split l "\t"))
                  (time (and (> (length parts) 1) (string->number (nth 1 parts)))))
             (list (car parts)
                   (if (> (length parts) 2) (string-trim (nth 2 parts)) "")
                   (if (number? time) time 0))))
          (else
            (let ((sp (string-index l " ")))
              (if sp
                  (list (substring-bytes l 0 sp)
                        (substring-bytes l (+ sp 1) (string-byte-length l))
                        0)
                  (list l "" 0)))))))

;; the history, newest first: (URL TITLE TIME) rows. The new file wins;
;; before its first write the old visited file still answers.
(define (web--history)
  (let ((text (or (read-file *web-visited-file*)
                  (read-file *web-visited-legacy-file*))))
    (if (string? text)
        (filter pair? (map web--history-entry (string-split text "\n")))
        '())))

;; the prompt's shape: (URL TITLE)
(define (web--visited)
  (map (lambda (e) (list (car e) (nth 1 e))) (web--history)))

(define (web--history-write! rows)
  (write-file! *web-visited-file*
    (string-append
      (string-join (map (lambda (e)
                          (string-append (car e) "\t"
                                         (number->string (nth 2 e)) "\t"
                                         (nth 1 e)))
                        rows)
                   "\n")
      "\n")))

(define (web--remember-visit! url title)
  (web--history-write!
    (take-n (cons (list url title (current-time))
                  (filter (lambda (e) (not (equal? (car e) url)))
                          (web--history)))
            *web-visited-max*)))

(define (web--forget-visit! url)
  (web--history-write!
    (filter (lambda (e) (not (equal? (car e) url))) (web--history))))

;; seconds -> "just now", "5m ago", "2h ago", "3d ago"; "" for no time
(define (web--age-label time)
  (let ((age (and (number? time) (> time 0) (- (current-time) time))))
    (cond ((not age) "")
          ((< age 60) "just now")
          ((< age 3600) (string-append (number->string (quotient age 60)) "m ago"))
          ((< age 86400) (string-append (number->string (quotient age 3600)) "h ago"))
          (else (string-append (number->string (quotient age 86400)) "d ago")))))

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
      (string-contains? u ".svg") (string-contains? u "/image/")))

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
        (let* ((target (string-trim
                         (substring-bytes m (+ close 2) (- len 1))))
               ;; Pandoc may append a quoted title after the URL.
               (space (string-index target " "))
               (url (if space (substring-bytes target 0 space) target)))
          (list (substring-bytes m (if (string-prefix? "!" m) 2 1) close)
                url))
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
(define *web--link-pattern* "!?\\[([^]]*)\\]\\(([^)]*)\\)")

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
               (raw (substring-bytes md ms me))
               (parts (web--link-parts raw))
               (url (car (cdr parts)))
               ;; An image segment must contain its URL: img-embed uses the
               ;; overlaid text itself as the image source.
               (label (if (string-prefix? "!" raw) url (car parts)))
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
        ;; A rendered Markdown heading link stays on this page.
        ((string-prefix? "#" url)
         (let ((hash (string-index base "#")))
           (string-append
             (if hash (substring-bytes base 0 hash) base)
             url)))
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
  (let ((url (buffer-local buf 'browse-url)))
    ;; The process keeps its stable buffer identity while the visible title
    ;; follows in-place navigation.
    (when url
      (buffer-set-local! buf 'modeline-name
        (string-append "*browse:" (web--slug url) "*")))
    (buffer-set-local! buf 'modeline-info
      (string-append
        (web--reading-label buf)
        (or url "")
        (let ((age (cache-age-label buf)))
          (if age (string-append " · " age) ""))))))



(define (web--markdown-links md)
  ;; Source ranges, not flattened-output ranges. preview-mode renders the
  ;; same bytes, so keyboard navigation and point restoration stay aligned.
  (let loop ((hits (re-find* *web--link-pattern* md)) (out '()))
    (if (null? hits)
        (reverse out)
        (let* ((ms (car (car hits)))
               (me (car (cdr (car hits))))
               (raw (substring-bytes md ms me))
               (image? (string-prefix? "!" raw))
               (parts (web--link-parts raw))
               (label (car parts))
               (url (car (cdr parts)))
               (start (+ ms (if image? 2 1))))
          (loop (cdr hits)
                (if (or (equal? label "")
                        (string-prefix? "![" label)
                        (string-prefix? "#" url))
                    out
                    (cons (list start
                                (+ start (string-byte-length label))
                                url)
                          out)))))))

(define (web--render! buf md)
  (let ((links (web--markdown-links md)))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 md)
    (buffer-set-read-only! buf #t)
    ;; Canonical Markdown stays in the buffer. preview-mode owns rendering;
    ;; web-links only keeps source positions for TAB, n/p and RET.
    (buffer-set-local! buf 'web-links links)
    (overlay-clear! buf 'web)
    (web--apply-meta-faces! buf)
    (web--apply-separator-faces! buf)
    (let ((p (buffer-local buf 'browse-restore-point)))
      (buffer-set-local! buf 'browse-restore-point #f)
      (buffer-goto! buf (min (or p 0) (buffer-size buf)))
      (buffer-windows-follow-point! buf))
    (web--update-modeline! buf)
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
             (hit (and url (web--page-cached b url)))
             (request-url (if (buffer-local b 'web-hard-refresh)
                              (web--cache-bust-url url)
                              url)))
        (if (not url)
            (k #f)
            (begin
              (set! *web--revalidate* (and hit #t))
              (*web-fetch* request-url (web--want b)
                (lambda (found)
                  (let ((md (and (pair? found) (nth 1 found))))
                    (cond (md (k found))
                          (hit (k (list (nth 1 hit) (nth 2 hit) #f)))
                          (else (k #f))))))))))
    ;; a fetch completion is the one moment a page enters the session
    ;; cache — serving from it must not refresh its age
    (lambda (b found)
      (let ((reading (nth 0 found))
            (md (nth 1 found))
            (html (nth 2 found)))
        (buffer-set-local! b 'web-hard-refresh #f)
        (buffer-set-local! b 'browse-reading reading)
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

;;; A tab's history is two stacks in the buffer, 'browse-history behind
;;; and 'browse-forward ahead. An entry is (URL POINT): back and forward
;;; return to the line the reader left, not to the top. Both stacks are
;;; plain data, so the desktop saves them and a restart keeps every tab's
;;; way back. An entry saved before this shape was a bare URL; it still
;;; reads.

(define (web--entry-url e) (if (pair? e) (car e) e))
(define (web--entry-point e) (if (pair? e) (nth 1 e) 0))

(define (web--history-push! buf key here)
  (buffer-set-local! buf key
    (cons (list here (buffer-point buf)) (or (buffer-local buf key) '()))))

;; POINT, when given, is where the page opens once it renders
(define (web--goto-url! buf url push? &optional point)
  (let ((here (buffer-local buf 'browse-url)))
    (when (and push? here (not (equal? here url)))
      (web--history-push! buf 'browse-history here)
      ;; a new page starts a new future: forward clears, like a browser
      (buffer-set-local! buf 'browse-forward '())))
  (buffer-set-local! buf 'browse-url url)
  (buffer-set-local! buf 'browse-restore-point point)
  (web--update-modeline! buf)
  ;; A new destination starts at the top immediately, even while its
  ;; fetch is pending. Back and forward pass an explicit saved point.
  (when (not point)
    (buffer-goto! buf 0)
    (buffer-windows-follow-point! buf))
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
          (message (string-append "fetching " url " …"))
          (cache-refresh! buf)))))

;; the page's URL split at its last path segment: "https://h/a/b" ->
;; "https://h/a/", and the root of the site when nothing is left
(define (web--origin url)
  (let* ((scheme-end (string-index url "://"))
         (host-end (and scheme-end (string-index url "/" (+ scheme-end 3)))))
    (cond ((not scheme-end) url)
          (host-end (substring-bytes url 0 host-end))
          (else url))))

(define (web--parent-url url)
  (let* ((origin (web--origin url))
         (q (string-index url "?"))
         (clean (if q (substring-bytes url 0 q) url))
         (trimmed (if (and (string-suffix? "/" clean)
                           (> (string-byte-length clean) (+ (string-byte-length origin) 1)))
                      (substring-bytes clean 0 (- (string-byte-length clean) 1))
                      clean))
         (slash (string-rindex trimmed "/")))
    (if (and slash (>= slash (+ (string-byte-length origin) 1)))
        (substring-bytes trimmed 0 (+ slash 1))
        (string-append origin "/"))))

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
            (when here (web--history-push! buf 'browse-forward here))
            (buffer-set-local! buf 'browse-history (cdr h))
            (web--goto-url! buf (web--entry-url (car h)) #f
                            (web--entry-point (car h))))))))

(define-command "browse-forward" "Go forward to the page you came back from"
  (lambda ()
    (let* ((buf (current-buffer))
           (f (or (buffer-local buf 'browse-forward) '()))
           (here (buffer-local buf 'browse-url)))
      (if (null? f)
          (message "no later page")
          (begin
            (when here (web--history-push! buf 'browse-history here))
            (buffer-set-local! buf 'browse-forward (cdr f))
            (web--goto-url! buf (web--entry-url (car f)) #f
                            (web--entry-point (car f))))))))

;; the parent path, and the site root: the two directions a URL has
;; besides the links on the page
(define-command "browse-up" "Go to the parent of this page's path"
  (lambda ()
    (let* ((buf (current-buffer))
           (url (buffer-local buf 'browse-url)))
      (cond ((not url) (message "no page here"))
            ((equal? (web--parent-url url) url) (message "at the top"))
            (else (web--goto-url! buf (web--parent-url url) #t))))))

(define-command "browse-top" "Go to the root of this page's site"
  (lambda ()
    (let* ((buf (current-buffer))
           (url (buffer-local buf 'browse-url)))
      (cond ((not url) (message "no page here"))
            (else (web--goto-url! buf (string-append (web--origin url) "/") #t))))))

;; g asks WHERE: this page leads as the default, so a plain RET
;; refetches it — and the visited sites complete, so g also goes
;; elsewhere without leaving the buffer
(define-command "browse-hard-refresh" "Refetch the current page while bypassing cached responses"
  (lambda ()
    (let* ((buf (current-buffer))
           (url (buffer-local buf 'browse-url)))
      (if (not url)
          (message "no page here")
          (begin
            (buffer-set-local! buf 'cache-time #f)
            (buffer-set-local! buf 'browse-restore-point (buffer-point buf))
            (message "hard refreshing…")
            ;; Do not mutate the canonical page URL. The cache-busting
            ;; request is handled by the fetch pipeline instead.
            (buffer-set-local! buf 'web-hard-refresh #t)
            (cache-refresh! buf))))))

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
                                   ;; the same page again: point stays
                                   (buffer-set-local! buf 'browse-restore-point
                                                      (buffer-point buf))
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

;; the link's page beside this one: the tab opens in another window and
;; point stays here, so the reader keeps their place in the page
(define-command "browse-follow-other-window"
  "Open the link at point in another window; point stays here"
  (lambda ()
    (let* ((buf (current-buffer))
           (l (web--link-at buf (point))))
      (if (not l)
          (message "no link here")
          (let ((url (web--resolve (car (cdr (cdr l)))
                                   (or (buffer-local buf 'browse-url) ""))))
            (if (web--image-url? url)
                (tab-open url)
                (web--show-tab-other-window! url)))))))

;; the link at point, else the page: eww's `w` does the same
(define (web--url-at-point buf)
  (let ((l (web--link-at buf (buffer-point buf))))
    (if l
        (web--resolve (car (cdr (cdr l))) (or (buffer-local buf 'browse-url) ""))
        (buffer-local buf 'browse-url))))

(define-command "browse-copy-url" "Copy the link at point, else the page URL"
  (lambda ()
    (let ((url (web--url-at-point (current-buffer))))
      (if (not url)
          (message "no page here")
          (begin
            ;; the kill ring too: a client with no clipboard permission
            ;; still pastes it with C-y
            (kill-push! url)
            (clipboard-put! url)
            (message url))))))

;; the html the tab holds, in a buffer of its own. A page served from
;; the session copy holds markdown only; it says so.
(define-command "browse-view-source" "Show this page's html in a buffer"
  (lambda ()
    (let* ((buf (current-buffer))
           (html (buffer-local buf 'browse-html))
           (url (buffer-local buf 'browse-url)))
      (cond ((not url) (message "no page here"))
            ((not html) (message "no source held for this page; g refetches it"))
            (else
              (let ((name (string-append "*browse-source:" (web--slug url) "*")))
                (buffer-create name)
                (buffer-add-group! name (web--browse-group!))
                (buffer-set-read-only! name #f)
                (buffer-delete-range! name 0 (buffer-size name))
                (buffer-insert! name 0 html)
                (buffer-set-read-only! name #t)
                (buffer-goto! name 0)
                (switch-to-buffer! name)
                (set-mode! "html-mode")))))))

(defcustom 'browse-download-directory (string-append (getenv "HOME") "/Downloads")
  "Where `d` saves a link or a page."
  'group 'web 'type 'string)

;; the URL's last path segment, or the host when the path is empty
(define (web--download-name url)
  (let* ((q (string-index url "?"))
         (clean (if q (substring-bytes url 0 q) url))
         (parts (filter (lambda (p) (not (equal? p "")))
                        (string-split (car (reverse (string-split clean "://"))) "/"))))
    (if (> (length parts) 1)
        (car (reverse parts))
        (string-append (if (pair? parts) (car parts) "page") ".html"))))

(define (web--download! url)
  (let* ((dir (if (boundp 'browse-download-directory)
                  browse-download-directory
                  (string-append (getenv "HOME") "/Downloads")))
         (file (string-append dir "/" (web--download-name url))))
    (message (string-append "downloading " url " …"))
    (shell-command->string
      (string-append "mkdir -p " (web--shell-quote dir) " && curl -sL --max-time 120 "
                     (web--shell-quote url) " -o " (web--shell-quote file)
                     " && printf ok")
      (lambda (out)
        (if (equal? (string-trim (or out "")) "ok")
            (message (string-append "saved " file))
            (message (string-append "download failed: " url)))))))

(define-command "browse-download" "Save the link at point, else the page, to the download directory"
  (lambda ()
    (let ((url (web--url-at-point (current-buffer))))
      (if url (web--download! url) (message "no page here")))))

;; the browse tabs in buffer-list order: M-n and M-p walk them, the way
;; a browser walks its tabs
(define (web--tabs)
  (filter web--buffer? (buffer-list)))

(define (web--tab-step buf step)
  (let* ((tabs (web--tabs))
         (n (length tabs)))
    (let loop ((ts tabs) (i 0))
      (cond ((null? ts) #f)
            ((equal? (car ts) buf)
             (nth (modulo (+ i step n) n) tabs))
            (else (loop (cdr ts) (+ i 1)))))))

(define-command "browse-next-tab" "Switch to the next browse tab"
  (lambda ()
    (let ((next (web--tab-step (current-buffer) 1)))
      (if next (switch-to-buffer! next) (message "no other tab")))))

(define-command "browse-prev-tab" "Switch to the previous browse tab"
  (lambda ()
    (let ((prev (web--tab-step (current-buffer) -1)))
      (if prev (switch-to-buffer! prev) (message "no other tab")))))

;; the switcher, locked to the browse group: every tab, and nothing else
(define-command "browse-list-tabs" "List the browse tabs in the switcher"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if (and g (boundp 'switch-open!))
          (switch-open! (list 'locked g))
          (run-command "switch-to-buffer")))))

(define (web--browse-group!)
  (if (boundp 'group-ensure-record!)
      (group-ensure-record! "browse")
      "browse"))

(define (web--view-label view)
  (cond ((equal? view "mono") "rendered monospace")
        ((equal? view "serif") "rendered serif")
        (else "Markdown source")))

(define (web--apply-view! buf view)
  (buffer-set-local! buf 'browse-view view)
  (if (equal? view "source")
      (when (minor-mode-on? buf "preview-mode")
        (with-current-buffer buf (lambda () (disable-minor-mode! buf "preview-mode"))))
      (begin
        ;; the page stays rendered Markdown; only its type changes
        (preview-typography! view)
        (with-current-buffer buf
          (lambda ()
            (unless (minor-mode-on? buf "preview-mode")
              (enable-minor-mode! buf "preview-mode"))
            (preview-heal! buf)))))
  (web--update-modeline! buf)
  (message (string-append "browse: " (web--view-label view))))

(define-command "browse-cycle-view"
  "Cycle browse between monospace, serif, and Markdown source"
  (lambda ()
    (let* ((buf (current-buffer))
           (view (or (buffer-local buf 'browse-view) "mono"))
           (next (cond ((equal? view "mono") "serif")
                       ((equal? view "serif") "source")
                       (else "mono"))))
      (web--apply-view! buf next))))

(public! 'browse-cycle-view
  "(run-command \"browse-cycle-view\") — cycle rendered monospace, rendered serif, and Markdown source")

(define (web--install-keys! buf)
  
  
  
  
  
  
   #t)

(define-mode "browse-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (desktop-skip! buf 'browse-pages)
      (desktop-skip! buf 'browse-html)
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
      ;; Generated browse buffers have no .md suffix, so declare the
      ;; renderer. A page is rendered Markdown, in the type every rendered
      ;; page uses.
      (buffer-set-local! buf 'preview-renderer "markdown")
      (unless (buffer-local buf 'browse-view)
        (buffer-set-local! buf 'browse-view (preview-typography)))
      (if (equal? (buffer-local buf 'browse-view) "source")
          (when (minor-mode-on? buf "preview-mode")
            (disable-minor-mode! buf "preview-mode"))
          (if (minor-mode-on? buf "preview-mode")
              (preview-heal! buf)
              (enable-minor-mode! buf "preview-mode")))
      (web--install-keys! buf)
      (web--apply-meta-faces! buf)
      (web--apply-separator-faces! buf)
      (web--declare-cache! buf)
      (web--update-modeline! buf)
      (cache-wake! buf))))

(mode-keys! "browse-mode"
  '(
    ("RET" "browse-follow")
    ("s-RET" "browse-follow-new-tab")
    ("M-RET" "browse-follow-other-window")
    ("TAB" "browse-next-link")
    ("n" "browse-next-link")
    ("p" "browse-prev-link")
    ("l" "browse-back")
    ("r" "browse-hard-refresh")
    ("M-<left>" "browse-back")
    ("M-<right>" "browse-forward")
    ("u" "browse-up")
    ("t" "browse-top")
    ("g" "browse-refresh")
    ("o" "browse-open-external")
    ("w" "browse-copy-url")
    ("v" "browse-view-source")
    ("d" "browse-download")
    ("H" "browse-history")
    ("b" "bookmark-set")
    ("B" "list-bookmarks")
    ("s" "browse-list-tabs")
    ("M-n" "browse-next-tab")
    ("M-p" "browse-prev-tab")
    ("R" "browse-toggle-reading")
    ("C-c C-v" "browse-cycle-view")
    ("q" "quit-window")))

(mode-doc! "browse-mode"
  "A web page as readable text, in one of two readings. Calm shows
the article alone; full shows the whole document. R switches
between them without fetching again. RET follows the link at point,
s-RET opens it as its own tab, and M-RET peeks it beside this window:
the next M-RET replaces the peek, and M-RET on the same link keeps
it. TAB and n/p walk the links. l and M-<left>
go back, r and M-<right> go forward, and both return to the line
you left. u goes to the parent path, t to the site root. g asks
where to go: RET refetches this page, a visited site or a fresh URL
goes there. o opens the page in the real browser. w copies the link
at point, else the page URL. v shows the html. d saves the link at
point, else the page. H lists every page you read, b bookmarks this
one, B lists the bookmarks. s lists the tabs, M-n and M-p walk them.
C-s searches to any link.")

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
;; the page's own tab: the one that already shows it, or a fresh one.
;; The tab is made and its fetch starts without a window move, so the
;; caller decides where it shows.
(define (web--tab-for! url)
  (or (web--buffer-for url)
      (let ((name (string-append "*browse:" (web--slug url) "*")))
        (buffer-create name)
        (buffer-add-group! name (web--browse-group!))
        (with-current-buffer name (lambda () (set-mode! "browse-mode")))
        (web--goto-url! name url #t)
        name)))

(define (web--open-tab! url)
  (let ((group (web--browse-group!)))
    (when (boundp 'switch-to-group!) (switch-to-group! group)))
  (let ((tab (web--tab-for! url)))
    (switch-to-buffer! tab)
    tab))

;; the tab beside this window, as a PEEK: the next peek replaces it, and
;; the same link again keeps it. A tab that already existed is only
;; shown. The selected window and its point stay.
(define (web--show-tab-other-window! url)
  (peek-or-keep! (web--buffer-for url) (lambda () (web--tab-for! url)))
  (web--buffer-for url))

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

;; the C-x 4 shape: the page shows in another window, and the window
;; you are in keeps its buffer and its point
(define (browse-other-window url)
  (web--show-tab-other-window! (web--target url)))

;; one prompt for both commands: it completes over the history, a title
;; matches what you type, and a fresh URL still goes through as typed
(define (web--read-url! prompt open)
  (minibuffer-read* prompt (web--visited)
    (list (list 'match-hint 1)
          (list 'confirm
                (lambda (url)
                  (unless (equal? (string-trim url) "")
                    (open (string-trim url))))))))

(define-command "browse" "Open a web page as readable text in a buffer"
  (lambda () (web--read-url! "URL: " browse)))

(define-command "browse-other-window" "Open a web page as readable text in another window"
  (lambda () (web--read-url! "URL in other window: " browse-other-window)))

;;; --- the history list -----------------------------------------------------------
;;; Every page read, newest first, from the file the visits keep. RET
;;; opens the page in its tab, M-RET beside this window, o in the real
;;; browser; d forgets a page, D forgets them all.

(define *web-history-buffer* "*browse-history*")

(define (web--history-cells buf e)
  (list (list (web--age-label (nth 2 e)) "dim")
        (if (equal? (nth 1 e) "") (list (car e) "dim") (nth 1 e))
        (list (car e) "dim")))

(define-command "browse-history" "List every page you read, newest first"
  (lambda () (list-mode-show! "browse-history-mode")))

(define-command "browse-history-open" "Open the page on this row"
  (lambda ()
    (let ((e (list-current *web-history-buffer*)))
      (when e (web--open-tab! (car e))))))

(define-command "browse-history-open-other-window" "Open the page on this row in another window"
  (lambda ()
    (let ((e (list-current *web-history-buffer*)))
      (when e (web--show-tab-other-window! (car e))))))

(define-command "browse-history-open-external" "Open the page on this row in the real browser"
  (lambda ()
    (let ((e (list-current *web-history-buffer*)))
      (when e (tab-open (car e))))))

(define-command "browse-history-forget" "Forget the page on this row"
  (lambda ()
    (let ((e (list-current *web-history-buffer*)))
      (when e
        (web--forget-visit! (car e))
        (list-refresh! *web-history-buffer*)))))

(define-command "browse-history-clear" "Forget every page"
  (lambda ()
    (web--history-write! '())
    (list-refresh! *web-history-buffer*)
    (message "history cleared")))

(define-command "browse-history-refresh" "Read the history file again"
  (lambda () (list-refresh! *web-history-buffer*)))

(define-list-mode! "browse-history-mode"
  (list
    'doc (string-append
           "Every page the reader opened, newest first. RET opens the page "
           "in its tab, M-RET in another window, o in the real browser. "
           "d forgets the page, D forgets them all, / filters.")
    'buffer *web-history-buffer*
    'rows (lambda (buf) (web--history))
    'columns (lambda (buf)
               (list (list "when" 10) (list "title" 48) (list "url" #f)))
    'cells web--history-cells
    'title (lambda (buf) "History")
    'meta (lambda (buf)
            (string-append (number->string (length (web--history))) " pages"))
    'total (lambda (buf) (length (web--history)))
    'footer (lambda (buf)
              '(("RET" "open") ("M-RET" "other window") ("o" "browser")
                ("d" "forget") ("D" "clear") ("/" "filter") ("q" "quit")))
    'key (lambda (buf e) (car e))
    'keys '(("RET" "browse-history-open")
            ("M-RET" "browse-history-open-other-window")
            ("o" "browse-history-open-external")
            ("d" "browse-history-forget")
            ("D" "browse-history-clear")
            ("g" "browse-history-refresh")
            ("q" "quit-window"))))

;;; --- bookmarks ------------------------------------------------------------------
;;; A browse tab bookmarks as its URL and point, not as a buffer name: the
;;; tab may be gone by the time the bookmark jumps, and the page comes
;;; back from the URL. The bookmark package owns the store and the list;
;;; this is the one handler it needs for a page.

(define (web--bookmark-record buf)
  (list 'url (buffer-local buf 'browse-url)
        'title (web--title (buffer-text buf))
        'position (buffer-point buf)))

;; WHERE is "current", "other" or "preview", the bookmark package's three
;; dispositions. Returns the tab.
(define (web--bookmark-jump! record where)
  (let ((url (plist-get record 'url))
        (pos (or (plist-get record 'position) 0)))
    (and url
         (let ((tab (web--tab-for! url)))
           ;; a page that still has to fetch opens at POS when it renders;
           ;; one already drawn moves now
           (if (> (buffer-size tab) 0)
               (buffer-goto! tab (min pos (buffer-size tab)))
               (buffer-set-local! tab 'browse-restore-point pos))
           (cond ((equal? where "current") (switch-to-buffer! tab))
                 ((equal? where "other")
                  (select-window! (display-buffer-other-window! tab)))
                 (else (display-buffer-other-window! tab)))
           tab))))

(when (boundp 'bookmark-register-handler!)
  (bookmark-register-handler! "browse"
    web--bookmark-record
    web--bookmark-jump!
    (lambda (record) (or (plist-get record 'url) "")))
  (bookmark-register-mode-handler! "browse-mode" "browse"))

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

(public! 'browse-other-window
  "(browse-other-window URL) — read URL as text in its tab, shown in another window; the selected window and its point stay")

(public! 'url-resolve
  "(url-resolve URL BASE) — resolve a link target against the page it came from: absolute stays, //host takes the scheme, /path takes the origin, the rest appends to the page's directory")
