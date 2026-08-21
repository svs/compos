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

(set-face-attribute! 'web-link 'fg "#7aa2f7")

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

;; the fetched html, converted three ways in order from one file:
;;   1. the ARTICLE — `readable` (Mozilla's readability) extracts it,
;;      which drops the page furniture: nav, subscribe boxes, like
;;      counts, audio players. Absent or empty (a page that is not an
;;      article, or the tool is not installed), then
;;   2. the WHOLE page through pandoc, and
;;   3. when pandoc answers only a "[TABLE]" placeholder (a nested
;;      table layout), the page again with the table tags flattened,
;;      so it reads as lines with its links intact.
(define (web--substack-feed? url)
  (or (equal? url "https://substack.com")
      (string-prefix? "https://substack.com/" url)))

(define (web--convert-html url html k)
  (let ((f (string-append (aimax-home) "/browse-fetch.html"))
        (u (web--shell-quote url))
        ;; no hard wrap: a paragraph is ONE line, and the window wraps
        ;; it at its own width like any buffer text
        (p " | pandoc --wrap=none -f html-native_divs-native_spans -t gfm-raw_html"))
    (write-file! f html)
    (shell-command->string
      (string-append
        ;; the first output line NAMES the reading that won — "feed",
        ;; "article", or "page" — and the modeline shows it
        (if (web--substack-feed? url)
            (string-append
              "m=feed; out=$(xmllint --html --xpath "
              "'//*[@role=\"article\" and (@aria-label=\"Note\" or @aria-label=\"Post\")]' "
              (web--shell-quote f) " 2>/dev/null" p "); ")
            (string-append
              "m=article; out=$(readable --base " u " " (web--shell-quote f)
              " 2>/dev/null" p "); "))
        "if [ \"${#out}\" -lt 200 ]; then m=article; out=$(readable --base " u " "
        (web--shell-quote f) " 2>/dev/null" p "); fi; "
        "if [ \"${#out}\" -lt 200 ]; then m=page; out=$(cat " (web--shell-quote f) p "); fi; "
        "case \"$out\" in *'[TABLE]'*) m=page; "
        "out=$(perl -pe 's{</?(?:table|tbody|thead|tr|td|th)\\b[^>]*>}{ }gi'"
        " < " (web--shell-quote f) p ");; esac; "
        "printf '%s\\n%s' \"$m\" \"$out\"")
      (lambda (out)
        (let ((nl (and (string? out) (string-index out "\n"))))
          (cond
            ((or (not nl) (equal? (string-trim out) "")) (k #f))
            (else
              (set! *web--last-kind* (substring-bytes out 0 nl))
              (let ((md (substring-bytes out (+ nl 1) (string-byte-length out))))
                (k (if (equal? (string-trim md) "") #f md))))))))))

;; URL -> markdown, in a Task. Tests replace this seam. ONE download;
;; the conversion reads the same bytes from a file. Holding a session
;; copy of the page, the fetch revalidates instead: a 304 costs only
;; headers, and the copy serves again with a fresh stamp.
;; the cache fetch sets *web--revalidate* when it holds a copy to fall
;; back on: the fetch then sends the ETag, and a 304 costs headers only
(define *web--revalidate* #f)

;; which reading the last conversion produced: "article" or "page".
;; A stubbed or served fetch leaves the default.
(define *web--last-kind* "page")

(define (web--pipeline url k)
  (*web-fetch-html* url
    (lambda (html)
      (if html (web--convert-html url html k) (k #f)))
    *web--revalidate*))

(define *web-fetch* web--pipeline)

;; URL -> the raw html. Tests replace this seam. REVALIDATE? sends the
;; page's saved ETag (curl --etag-compare): an unchanged page answers
;; 304 with no body — headers only — and the caller serves its copy.
(define (web--curl-html url k revalidate?)
  (let ((u (web--shell-quote url))
        (dir (web--shell-quote (string-append (aimax-home) "/web-etags"))))
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

;; the browser first: logged in on a site there means logged in here.
;; A SNAPSHOT, not a plain fetch — a real background tab loads the
;; page, so per-site sessions (Substack keeps one per publication
;; subdomain), SSO redirects and scripts all run, and the reader gets
;; the RENDERED document. No browser, or no answer — curl, with the
;; ETag discipline.
(define (web--html-pipeline url k &optional revalidate?)
  (browser-snapshot url
    (lambda (html)
      (if html (k html) (web--curl-html url k revalidate?)))))

(define *web-fetch-html* web--html-pipeline)

;;; --- visited sites --------------------------------------------------------------
;;; Every rendered page remembers itself: one "URL TITLE" line, newest
;;; first. The browse prompt completes over them, and the title matches
;;; what you type.

(define *web-visited-file* (string-append (aimax-home) "/web-visited"))
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

(define (web--fix-empty-links s)
  (let loop ((pos 0) (out "") (last-img #f))
    (let ((hit (re-find *web--empty-link-pattern* s pos)))
      (if (not hit)
          (string-append out (substring-bytes s pos (string-byte-length s)))
          (let* ((ms (car hit))
                 (me (car (cdr hit)))
                 (gs (re-groups *web--empty-link-pattern* s ms))
                 (ur (car (cdr gs)))
                 (url (substring-bytes s (car ur) (car (cdr ur))))
                 (between (string-trim (substring-bytes s pos ms)))
                 (head (string-append out (substring-bytes s pos ms)))
                 (img? (web--image-url? url)))
            (cond
              ;; the inner image of a wrapped pair: the wrapper said it
              ((and img? last-img (equal? between "")) (loop me head #t))
              ;; the URL is the label: the buffer text stays the truth,
              ;; and the img-embed face renders the picture over it
              (img? (loop me (string-append head "[" url "](" url ")") #t))
              (else (loop me head (and last-img (equal? between ""))))))))))

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

(define (web--parse md)
  (let loop ((pos 0) (out "") (links '()))
    (let ((hit (re-find *web--link-pattern* md pos)))
      (if (not hit)
          (list (string-append out (substring-bytes md pos (string-byte-length md)))
                (reverse links))
          (let* ((ms (car hit))
                 (me (car (cdr hit)))
                 ;; pair 0 is the whole match; the label and target follow
                 (gs (re-groups *web--link-pattern* md ms))
                 (lr (car (cdr gs)))
                 (ur (car (cdr (cdr gs))))
                 (label (substring-bytes md (car lr) (car (cdr lr))))
                 (url (substring-bytes md (car ur) (car (cdr ur))))
                 (head (string-append out (substring-bytes md pos ms)))
                 (start (string-byte-length head))
                 (end (+ start (string-byte-length label))))
            (loop me
                  (string-append head label)
                  (if (or (equal? label "") (string-prefix? "#" url))
                      links
                      (cons (list start end url) links))))))))

;; a link target against the page it came from: absolute stays, //host
;; takes the scheme, /path takes the origin, anything else appends to the
;; page's directory
(define (web--resolve url base)
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
                (string-append clean "/" url))))))

;;; --- rendering ------------------------------------------------------------------

;; the modeline says WHICH reading this is: "article" when readability
;; extracted one, "page" for the whole page, "feed" for a feed parse
(define (web--update-modeline! buf)
  (buffer-set-local! buf 'modeline-info
    (string-append
      (let ((kind (buffer-local buf 'browse-kind)))
        (if kind (string-append kind " · ") ""))
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
    (buffer-goto! buf 0)
    (web--update-modeline! buf)
    ;; the page is real now: it joins the visited list, title and all
    (let ((url (buffer-local buf 'browse-url)))
      (when url (web--remember-visit! url (web--title md))))))

;; overlays are runtime: the mode setup rebuilds them from 'web-links.
;; An image link wears img-embed — the client renders the picture in
;; the line, and the text underneath stays the URL.
(define (web--apply-link-faces! buf)
  (overlay-set! buf 'web
    (map (lambda (l)
           (list (car l) (car (cdr l))
                 (if (web--image-url? (car (cdr (cdr l))))
                     "img-embed"
                     "web-link")))
         (or (buffer-local buf 'web-links) '()))))

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
              (*web-fetch* url
                (lambda (md)
                  (cond (md (k md))
                        (hit (set! *web--last-kind* (web--page-kind hit))
                             (k (nth 1 hit)))
                        (else (k #f)))))))))
    ;; a fetch completion is the one moment a page enters the session
    ;; cache — serving from it must not refresh its age
    (lambda (b md)
      (buffer-set-local! b 'browse-kind *web--last-kind*)
      (web--page-remember! b (buffer-local b 'browse-url) md)
      (web--render! b md))
    *web-cache-ttl*))

;;; --- navigation -----------------------------------------------------------------

;;; every page read this session keeps its markdown: back, forward and
;;; a jump to a visited URL serve instantly, like a browser's cache.
;;; `g` on the page refetches for real. The store is session-only —
;;; the desktop skips it, and a restart reads fresh.

(define *web-page-cache-max* 20)

;; an entry keeps the reading's KIND too, so a served copy still says
;; article or page in the modeline
(define (web--page-remember! buf url md)
  (buffer-set-local! buf 'browse-pages
    (take-n (cons (list url md (current-time) *web--last-kind*)
                  (filter (lambda (e) (not (equal? (car e) url)))
                          (or (buffer-local buf 'browse-pages) '())))
            *web-page-cache-max*)))

(define (web--page-kind hit)
  (if (> (length hit) 3) (nth 3 hit) "page"))

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
          (buffer-set-local! buf 'cache-time (nth 2 hit))
          (buffer-set-local! buf 'browse-kind (web--page-kind hit))
          (web--render! buf (nth 1 hit)))
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
  ;; the preview chord: "show me the rendered thing" — the browser
  (local-set-key* buf "C-c C-v" "browse-open-external")
  (local-set-key* buf "q" "quit-window"))

(define-mode "browse-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      ;; the session page cache is heavy and derives from the URL: a
      ;; restart refetches, the desktop must not carry it
      (desktop-skip! buf 'browse-pages)
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
      (web--declare-cache! buf)
      (web--update-modeline! buf)
      ;; a restored page draws its saved text; only a stale one refetches
      (cache-wake! buf))))

(mode-doc! "browse-mode"
  "A web page as readable text — the article, extracted. RET follows
the link at point and s-RET opens it as its own tab, TAB and n/p
walk the links, M-<left> and l go back, M-<right> goes forward, g
asks where to go — RET refetches this page, a visited site or a
fresh URL goes there — o opens the page in the real browser, and
C-s searches to any link.")

;; the one entry point: normalize, enter the mode, fetch
;; a tab's name: the host, and the page's last path segment
(define (web--slug url)
  (let* ((tail (car (reverse (string-split url "://"))))
         (parts (filter (lambda (p) (not (equal? p "")))
                        (string-split tail "/")))
         (host (if (pair? parts) (car parts) tail)))
    (if (> (length parts) 1)
        (string-append host "/" (car (reverse parts)))
        host)))

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

(define (browse url)
  (let ((full (if (string-contains? url "://")
                  url
                  (string-append "https://" url))))
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
    "Substack now uses the first site-specific reader. "
    "The parser selects semantic Note and Post article nodes before pandoc, "
    "so the signed-in feed omits navigation, suggestions, and subscriptions. "
    "Other sites still use readable, pandoc, and the table fallback. "
    "A public parser registry does not exist yet.")
  'domain 'web
  'effects '(pure)
  'use "browse https://substack.com; web--convert-html selects feed articles")

(public! 'browse
  "(browse URL) — read URL as text in its own tab buffer (*browse:host/page*); in a browse buffer it navigates in place")
