;;; web.scm --- browse the web in a buffer.
;;;
;;; M-x browse fetches a page and renders it as readable text. Links show
;;; their label only; the target rides in 'web-links as byte ranges. RET
;;; follows the link at point, TAB and n/p walk the links, l goes back,
;;; g refetches, o opens the page in the real browser. C-s reaches any
;;; link through the ordinary search.
;;;
;;; The fetch is curl piped through pandoc, off the UI lane through the
;;; buffer cache: a restored or previewed buffer draws its saved text and
;;; refetches only past the TTL.

(domain! 'web)
(effects! '(read external))

(set-face-attribute! 'web-link 'fg "#7aa2f7")

(define *web-buffer* "*browse*")
(define *web-cache-ttl* 600)

(define (web--shell-quote text)
  (string-append "'" (string-join (string-split text "'") "'\\''") "'"))

;; a table-layout page (Hacker News), with the table tags flattened —
;; pandoc's markdown writer cannot express nested tables and answers
;; only a "[TABLE]" placeholder for the whole page
(define (web--flat-pipeline url k)
  (shell-command->string
    (string-append
      "curl -sL --max-time 20 " (web--shell-quote url)
      " | perl -pe 's{</?(?:table|tbody|thead|tr|td|th)\\b[^>]*>}{ }gi'"
      " | pandoc -f html-native_divs-native_spans -t gfm-raw_html")
    (lambda (out) (k (if (equal? (string-trim out) "") #f out)))))

;; URL -> markdown, in a Task. Tests replace this seam.
(define (web--pipeline url k)
  (shell-command->string
    (string-append
      "curl -sL --max-time 20 " (web--shell-quote url)
      " | pandoc -f html-native_divs-native_spans -t gfm-raw_html")
    (lambda (out)
      (cond ((equal? (string-trim out) "") (k #f))
            ((string-contains? out "[TABLE]") (web--flat-pipeline url k))
            (else (k out))))))

(define *web-fetch* web--pipeline)

;; URL -> the raw html, for the original view. Tests replace this too.
(define (web--html-pipeline url k)
  (shell-command->string
    (string-append "curl -sL --max-time 20 " (web--shell-quote url))
    (lambda (out) (k (if (equal? (string-trim out) "") #f out)))))

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

;; [label](url) and ![label](url) become the label; the output byte range
;; and the target collect in LINKS. Anchors (#...) stay plain text.
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

(define (web--update-modeline! buf)
  (buffer-set-local! buf 'modeline-info
    (string-append
      (or (buffer-local buf 'browse-url) "")
      (let ((age (cache-age-label buf)))
        (if age (string-append " · " age) "")))))

(define (web--render! buf md)
  (let* ((parsed (web--parse md))
         (text (car parsed))
         (links (car (cdr parsed))))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 text)
    (buffer-set-read-only! buf #t)
    (buffer-set-local! buf 'web-links links)
    ;; a render is the READER view; the original toggle reads this back
    (buffer-set-local! buf 'web-md md)
    (buffer-set-local! buf 'render-mode #f)
    (web--apply-link-faces! buf)
    (buffer-goto! buf 0)
    (web--update-modeline! buf)
    ;; the page is real now: it joins the visited list, title and all
    (let ((url (buffer-local buf 'browse-url)))
      (when url (web--remember-visit! url (web--title md))))))

;; overlays are runtime: the mode setup rebuilds them from 'web-links
(define (web--apply-link-faces! buf)
  (overlay-set! buf 'web
    (map (lambda (l) (list (car l) (car (cdr l)) "web-link"))
         (or (buffer-local buf 'web-links) '()))))

(define (web--declare-cache! buf)
  (cache-declare! buf
    ;; the mode can wake before its first URL — nothing to fetch yet
    (lambda (b k)
      (let ((url (buffer-local b 'browse-url)))
        (if url (*web-fetch* url k) (k #f))))
    (lambda (b md) (web--render! b md))
    *web-cache-ttl*))

;;; --- navigation -----------------------------------------------------------------

(define (web--goto-url! buf url push?)
  (let ((here (buffer-local buf 'browse-url)))
    (when (and push? here (not (equal? here url)))
      (buffer-set-local! buf 'browse-history
        (cons here (or (buffer-local buf 'browse-history) '())))))
  (buffer-set-local! buf 'browse-url url)
  ;; a new page: the old stamp must not satisfy the TTL, and the old
  ;; page's original html means nothing here
  (buffer-set-local! buf 'web-html #f)
  (buffer-set-local! buf 'cache-time #f)
  (web--update-modeline! buf)
  (message (string-append "fetching " url " …"))
  (cache-refresh! buf))

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
      (if l
          (web--goto-url! buf
            (web--resolve (car (cdr (cdr l))) (or (buffer-local buf 'browse-url) ""))
            #t)
          (message "no link here")))))

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

(define-command "browse-back" "Return to the previous page"
  (lambda ()
    (let* ((buf (current-buffer))
           (h (or (buffer-local buf 'browse-history) '())))
      (if (null? h)
          (message "no earlier page")
          (begin
            (buffer-set-local! buf 'browse-history (cdr h))
            (web--goto-url! buf (car h) #f))))))

(define-command "browse-refresh" "Fetch this page again"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'cache-time #f)
      (message "fetching…")
      (cache-refresh! buf))))

;; the ORIGINAL page: the raw html, rendered as authored. Reading is
;; still all it does — scripts never run; a page that needs them wants
;; `o` and the real browser.
(define (web--show-original! buf html)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-insert! buf 0 html)
  (buffer-set-read-only! buf #t)
  (overlay-set! buf 'web '())
  (buffer-set-local! buf 'web-links '())
  (buffer-set-local! buf 'web-html html)
  (buffer-set-local! buf 'preview-authored #t)
  (buffer-set-local! buf 'render-mode "html")
  (buffer-goto! buf 0))

(define-command "browse-toggle-original"
  "Show the original page; again shows the reader view"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond
        ((equal? (buffer-local buf 'render-mode) "html")
         ;; back to the reader: the saved markdown re-renders, no fetch
         (let ((md (buffer-local buf 'web-md)))
           (if md
               (web--render! buf md)
               (begin (buffer-set-local! buf 'render-mode #f)
                      (buffer-set-local! buf 'cache-time #f)
                      (cache-refresh! buf)))))
        (else
          (let ((html (buffer-local buf 'web-html))
                (url (buffer-local buf 'browse-url)))
            (cond
              ((string? html) (web--show-original! buf html))
              ((not url) (message "no page yet"))
              (else
                (message (string-append "fetching original " url " …"))
                (*web-fetch-html* url
                  (lambda (html)
                    (if (and html (buffer-known? buf))
                        (web--show-original! buf html)
                        (message "original fetch failed"))))))))))))

(define-command "browse-open-external" "Open this page in the real browser"
  (lambda ()
    (let ((url (buffer-local (current-buffer) 'browse-url)))
      (when url (tab-open url)))))

(define (web--install-keys! buf)
  (local-set-key* buf "RET" "browse-follow")
  (local-set-key* buf "TAB" "browse-next-link")
  (local-set-key* buf "n" "browse-next-link")
  (local-set-key* buf "p" "browse-prev-link")
  (local-set-key* buf "l" "browse-back")
  (local-set-key* buf "g" "browse-refresh")
  (local-set-key* buf "o" "browse-open-external")
  (local-set-key* buf "C-x C-v" "browse-toggle-original")
  (local-set-key* buf "q" "quit-window"))

(define-mode "browse-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      ;; both derive from the URL: a restart refetches, not restores
      (desktop-skip! buf 'web-md)
      (desktop-skip! buf 'web-html)
      (web--install-keys! buf)
      (web--apply-link-faces! buf)
      (web--declare-cache! buf)
      (web--update-modeline! buf)
      ;; a restored page draws its saved text; only a stale one refetches
      (cache-wake! buf))))

(mode-doc! "browse-mode"
  "A web page as readable text. RET follows the link at point, TAB and
n/p walk the links, l goes back, g refetches, C-x C-v shows the
original page and again the reader view, o opens the page in the real
browser, and C-s searches to any link.")

;; the one entry point: normalize, enter the mode, fetch
(define (browse url)
  (let ((full (if (string-contains? url "://")
                  url
                  (string-append "https://" url))))
    (buffer-create *web-buffer*)
    (display-buffer *web-buffer*)
    (with-current-buffer *web-buffer*
      (lambda ()
        (unless (equal? (buffer-local *web-buffer* 'mode-name) "browse-mode")
          (set-mode! "browse-mode"))
        (web--goto-url! *web-buffer* full #t)))
    *web-buffer*))

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
(public! 'browse
  "(browse URL) — fetch URL and render it as readable text in *browse*; links follow with RET")
