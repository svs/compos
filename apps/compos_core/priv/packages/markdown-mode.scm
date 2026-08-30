;;; markdown-mode.scm --- Markdown drawn in place: the markup steps back.
;;;
;;; This is preview-mode's painter for Markdown. It paints faces on the
;;; source and changes no byte. A marker (the # of a heading, the ** of
;;; bold, the ]( of a link) wears md-marker, and the page hides md-marker
;;; on every line but the one point is on. A heading wears its level's
;;; face, and that face carries a size. An image URL wears img-embed and
;;; draws as the picture. A line that is one X post URL wears x-embed and
;;; draws as the card. A line that is one YouTube URL wears youtube-embed
;;; and draws as a video card.
;;;
;;; preview-mode turns the paint on and off (markdown-paint-on!,
;;; markdown-paint-off!). morg-mode owns structure and the plain faces.

(domain! 'writing)
(effects! '(write))

(defface! 'md-marker 'fg "#b3ac9c")
;; the drawn headings: a size per level. morg's plain org-level faces keep
;; the source view one size, as they always were.
(defface! 'md-h1 'size "1.6em" 'weight "700")
(defface! 'md-h2 'size "1.3em" 'weight "700")
(defface! 'md-h3 'size "1.12em" 'weight "600")
(defface! 'md-h4 'size "1em" 'weight "600")
;; a picture's caption: the line of emphasis under the picture
(defface! 'md-caption 'fg "#8a857a" 'style "italic")

(define (md--span start s e face)
  (list (+ start s) (+ start e) face))

;; A construct OPEN bytes long at its head and CLOSE bytes at its tail:
;; the markers step back, FACE covers what is between them.
(define (md--wrapped start line pattern open close face)
  (apply append
    (map (lambda (r)
           (let ((s (car r)) (e (cadr r)))
             (list (md--span start s (+ s open) "md-marker")
                   (md--span start (+ s open) (- e close) face)
                   (md--span start (- e close) e "md-marker"))))
         (re-find* pattern line))))

(define md--link-pattern "\\[([^\\]\n]+)\\]\\(([^)\n]+)\\)")
(define md--image-pattern "!\\[([^\\]\n]*)\\]\\(([^)\n]+)\\)")
;; *text*: one star each side, and not the star of a **bold** pair
(define md--emphasis-pattern "(?<!\\*)\\*(?!\\*)[^*\n]+(?<!\\*)\\*(?!\\*)")
;; a line that is one picture, and a line that is one run of emphasis
(define md--image-line-pattern "^!\\[[^\\]\n]*\\]\\([^)\n]+\\)[ \t]*$")
(define md--caption-line-pattern "^\\*([^*\n]+)\\*[ \t]*$")
(define md--x-pattern "^https://(x|twitter)\\.com/[A-Za-z0-9_]+/status/[0-9]+/?$")
(define md--youtube-url-pattern
  "https://((www|m)\\.)?(youtube\\.com/(watch\\?[^ \\t]*v=[A-Za-z0-9_-]{11}[^ \\t]*|(shorts|live|embed)/[A-Za-z0-9_-]{11}[^ \\t]*)|youtu\\.be/[A-Za-z0-9_-]{11}[^ \\t]*)")
(define md--embed-pattern
  (string-append "^#\\+embed:[ \\t]+(" md--youtube-url-pattern ")[ \\t]*$"))

;; [text](url): the text is the link; the brackets and the target step
;; back. An image's link is not a link.
(define (md--links start line)
  (apply append
    (map (lambda (r)
           (let* ((s (car r)) (e (cadr r))
                  (image? (and (> s 0) (equal? (substring-bytes line (- s 1) s) "!")))
                  (g (re-groups md--link-pattern line s))
                  (text (and g (nth 1 g))))
             (if (or image? (not text))
                 '()
                 (list (md--span start s (car text) "md-marker")
                       (md--span start (car text) (cadr text) "link")
                       (md--span start (cadr text) e "md-marker")))))
         (re-find* md--link-pattern line))))

;; ![alt](url): the URL draws as the picture; everything else steps back
(define (md--images start line)
  (apply append
    (map (lambda (r)
           (let* ((s (car r)) (e (cadr r))
                  (g (re-groups md--image-pattern line s))
                  (url (and g (nth 2 g))))
             (if (not url)
                 '()
                 (list (md--span start s (car url) "md-marker")
                       (md--span start (car url) (cadr url) "img-embed")
                       (md--span start (cadr url) e "md-marker")))))
         (re-find* md--image-pattern line))))

;; a heading: the marker steps back, the text wears the level's face, and
;; a TODO keyword keeps its own face
(define (md--heading start line e len)
  (let* ((face (string-append "md-h"
                 (number->string (+ 1 (modulo (- (morg-info e) 1) 4)))))
         (m (re-groups "^(#{1,6}[ \t]+)" line 0))
         (text-start (if m (cadr (nth 1 m)) 0))
         (marker (if m (list (md--span start 0 text-start "md-marker")) '()))
         (g (re-groups "^#{1,6}[ \t]+(TODO|DONE)[ \t]" line 0)))
    (append
      marker
      (if (not g)
          (list (md--span start text-start len face))
          (let* ((r (nth 1 g))
                 (ks (car r))
                 (ke (cadr r))
                 (todo (substring-bytes line ks ke)))
            (append
              (if (> ks text-start) (list (md--span start text-start ks face)) '())
              (list (md--span start ks ke (if (equal? todo "TODO") "org-todo" "org-done")))
              (if (< ke len) (list (md--span start ke len face)) '())))))))

;; a bullet or a quote marker steps back and the row takes the shape; an
;; ordered item keeps its number, which is content
(define (md--block-marker start line)
  (let ((bullet (re-groups "^([ \t]*[-*+][ \t]+)" line 0))
        (ordered (re-groups "^([ \t]*[0-9]+[.)][ \t]+)" line 0))
        (quote (re-groups "^(>[ \t]?)" line 0)))
    (cond
      (bullet
       (let ((m (nth 1 bullet)))
         (list (md--span start (car m) (cadr m) "md-marker")
               (list start (+ start (string-byte-length line)) "row-li"))))
      (ordered
       (list (list start (+ start (string-byte-length line)) "row-oli")))
      (quote
       (let ((m (nth 1 quote)))
         (list (md--span start (car m) (cadr m) "md-marker")
               (list start (+ start (string-byte-length line)) "row-quote"))))
      (else '()))))

;; Markdown has no caption syntax of its own. The shape most renderers
;; agree on, and the one the page draws as a figure (docs/MARKDOWN.md):
;; a picture on a line of its own, and under it a line that is only
;; emphasis. The stars step back, the words wear md-caption, and the row
;; wears row-caption: the page centres it under the picture.
(define (md--caption? line prev)
  (and prev
       (not (null? (re-find* md--image-line-pattern prev)))
       (not (null? (re-find* md--caption-line-pattern line)))))

(define (md--caption start line len)
  (let* ((g (re-groups md--caption-line-pattern line 0))
         (words (nth 1 g)))
    (list (md--span start 0 (car words) "md-marker")
          (md--span start (car words) (cadr words) "md-caption")
          (md--span start (cadr words) len "md-marker")
          (list start (+ start len) "row-caption"))))

;; the spans for one scan entry; block BODIES are highlighted per block in
;; markdown-refontify!, because a multi-line construct needs the whole body.
;; PREV is the text of the line above, or #f on the first line.
(define (markdown--line-spans e &optional prev)
  (let* ((start (car e)) (line (cadr e)) (k (morg-kind e))
         (len (string-byte-length line))
         (embed (re-groups md--embed-pattern line 0)))
    (cond
      ((= len 0) '())
      ((and (equal? k 'text) (md--caption? line prev)) (md--caption start line len))
      ((equal? k 'heading) (md--heading start line e len))
      ;; a row face (row-*) shapes the whole row: the page reads it off the
      ;; line, not the segment
      ((equal? k 'open)
       (list (list start (+ start len) "org-meta") (list start (+ start len) "row-fence")))
      ((equal? k 'close)
       (list (list start (+ start len) "org-meta") (list start (+ start len) "row-fence")))
      ((equal? k 'code)
       (cons (list start (+ start len) "row-code")
             (cond ((equal? (morg-info e) "result-scheme") '())
                   ((member (morg-info e) '("result" "result-csv"))
                    (list (list start (+ start len) "morg-result")))
                   (else '()))))
      ;; a rule: the dashes step back, the row draws the line
      ((not (null? (re-find* "^(---+|\\*\\*\\*+|___+)[ \t]*$" line)))
       (list (list start (+ start len) "md-marker") (list start (+ start len) "row-hr")))
      ;; re-find* answers '() for no match, and '() is true: ask null?
      ((not (null? (re-find* md--x-pattern line)))
       (list (list start (+ start len) "x-embed")))
      ((not (null? (re-find* md--youtube-pattern line)))
       (list (list start (+ start len) "youtube-embed")))
      (else
       (append
         (md--block-marker start line)
         (md--wrapped start line "`[^`\n]+`" 1 1 "morg-code")
         (md--wrapped start line "\\*\\*[^*\n]+\\*\\*" 2 2 "morg-bold")
         (md--wrapped start line "\\b_[^_\n]+_\\b" 1 1 "morg-italic")
         (md--wrapped start line md--emphasis-pattern 1 1 "morg-italic")
         (md--images start line)
         (md--links start line))))))

(define (markdown-refontify! buf)
  (when (buffer-exists? buf)
    (let* ((scan (morg-scan buf))
           (text (buffer-text buf))
           ;; each line sees the line above it: a caption is known by the
           ;; picture over it
           (line-spans
             (car (fold (lambda (acc e)
                          (list (append (car acc) (markdown--line-spans e (cadr acc)))
                                (cadr e)))
                        (list '() #f) scan)))
           (blocks (morg-blocks scan buf))
           (code-spans
             (fold
               (lambda (acc b)
                 (let* ((lang (cadr b))
                        (bs (caddr b))
                        (be (car (cdr (cdr (cdr b)))))
                        (tsl (morg-ts-lang lang)))
                   (if (and tsl (> be bs))
                       (append acc
                         (map (lambda (sp)
                                (list (+ bs (car sp)) (+ bs (cadr sp))
                                      (string-append "ts-" (caddr sp))))
                              (ts-highlight-string tsl (substring-bytes text bs be))))
                       acc)))
               '()
               blocks))
           (csv-header-spans
             (fold
               (lambda (acc b)
                 (let ((lang (cadr b)) (bs (caddr b))
                       (be (car (cdr (cdr (cdr b))))))
                   (if (and (equal? lang "result-csv") (> be bs))
                       (let* ((body (substring-bytes text bs be))
                              (header (car (split-lines body))))
                         (cons (list bs (+ bs (string-byte-length header)) "morg-bold") acc))
                       acc)))
               '()
               blocks)))
      (overlay-set! buf 'markdown (append line-spans code-spans csv-header-spans)))))

;;; --- the mode ----------------------------------------------------------------

;; The reactor binds a rule to one buffer process. A killed and recreated
;; buffer has a new reference, so setup replaces the old rule.
(define *markdown-hooks* '())

(define (markdown--ensure-hook! buf)
  (let ((old (assoc buf *markdown-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *markdown-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals")
                        (markdown-refontify! buf)))
                    'eager))
            (remove (lambda (entry) (equal? (car entry) buf))
                    *markdown-hooks*)))))

(define (markdown--remove-hook! buf)
  (let ((old (assoc buf *markdown-hooks*)))
    (when old
      (remove-on-change! (cadr old))
      (set! *markdown-hooks*
        (remove (lambda (entry) (equal? (car entry) buf)) *markdown-hooks*)))))

(define (markdown--apply! buf)
  (markdown--ensure-hook! buf)
  (markdown-refontify! buf))

(define (markdown--teardown! buf)
  (markdown--remove-hook! buf)
  (overlay-set! buf 'markdown '()))

(define (markdown-paint-on! buf)
  (buffer-set-local! buf 'markdown-paint #t)
  (markdown--apply! buf))

(define (markdown-paint-off! buf)
  (buffer-set-local! buf 'markdown-paint #f)
  (markdown--teardown! buf))

(public! 'markdown-paint-on! "(markdown-paint-on! BUF) — draw BUF's Markdown in place (preview-mode's painter)")
(public! 'markdown-paint-off! "(markdown-paint-off! BUF) — take the in-place drawing off BUF")
(public! 'markdown-refontify! "(markdown-refontify! BUF) — repaint the Markdown faces of BUF")
