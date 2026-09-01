;;; markdown-mode.scm --- Markdown drawn in place: the markup steps back.
;;;
;;; This is preview-mode's painter for Markdown. It paints faces on the
;;; source and changes no byte. Markup wears md-marker and stays hidden.
;;; A heading wears its level's face, and that face carries a size. An
;;; image URL wears img-embed and draws as the picture. A line that is one
;;; X post URL wears x-embed and draws as the card. A standalone YouTube
;;; URL or #+embed directive wears youtube-embed and draws a video card.
;;;
;;; preview-mode turns the paint on and off (markdown-paint-on!,
;;; markdown-paint-off!). morg-mode owns structure and the plain faces.

(domain! 'writing)
(effects! '(write))

(defface! 'md-marker 'fg "#b3ac9c")
;; the visible half of an open fence: the block's own info string, worn
;; dim on the shrunken fence row — the chrome IS the text
(defface! 'md-fence 'fg "#8a857a")
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
;; The drawn text carries its own target, so a reader can click it. A span
;; has one channel, its class, so the URL travels percent-encoded and the
;; client decodes it. A target in angle brackets is a target with a space.
(define (md--link-class url)
  (let ((u (if (and (string-prefix? "<" url) (string-suffix? ">" url))
               (substring url 1 (- (string-length url) 1))
               url)))
    (string-append "link link-to:" (url-encode u))))

(define (md--links start line)
  (apply append
    (map (lambda (r)
           (let* ((s (car r)) (e (cadr r))
                  (image? (and (> s 0) (equal? (substring-bytes line (- s 1) s) "!")))
                  (g (re-groups md--link-pattern line s))
                  (text (and g (nth 1 g)))
                  (url (and g (nth 2 g))))
             (if (or image? (not text) (not url))
                 '()
                 (list (md--span start s (car text) "md-marker")
                       (md--span start (car text) (cadr text)
                                 (md--link-class
                                   (substring-bytes line (car url) (cadr url))))
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

;;; --- tables ------------------------------------------------------------
;;; A table is a head row, a rule row of dashes under it, and the body rows
;;; that follow. A line of bars with no rule row under it is ordinary text,
;;; so a row is known only by reading the line below. That context belongs
;;; to the run, not to one line, so markdown--table-spans walks the scan
;;; instead of markdown--line-spans.
;;;
;;; The page draws one source line per row, so each row is its own table
;;; box and the columns divide the width evenly. The bars carry those
;;; columns: every bar is a cell box of its own, so the text between two
;;; bars falls into a column of its own whatever faces the inline markup
;;; left on it.

(define md--table-row-pattern "^[ \t]*[|]")
(define md--table-rule-cell-pattern "^[ \t]*:?-+:?[ \t]*$")

(define (md--table-row? line) (re-match md--table-row-pattern line))

;; the byte offset of every bar that divides cells. A bar the author
;; escaped is text inside a cell.
(define (md--table-bars line)
  (filter (lambda (b)
            (or (= b 0)
                (not (equal? (substring-bytes line (- b 1) b) "\\"))))
          (map car (re-find* "[|]" line))))

;; (START END) per cell, in bytes. A row that closes with a bar ends
;; there; a row without one keeps its last cell to the end of the line.
(define (md--table-cells line)
  (let ((len (string-byte-length line)) (bars (md--table-bars line)))
    (let loop ((bs bars) (acc '()))
      (cond ((null? bs) (reverse acc))
            ((null? (cdr bs))
             (let ((s (+ (car bs) 1)))
               (reverse (if (< s len) (cons (list s len) acc) acc))))
            (else (loop (cdr bs) (cons (list (+ (car bs) 1) (car (cdr bs))) acc)))))))

(define (md--table-cell-text line cell)
  (substring-bytes line (car cell) (cadr cell)))

;; the rule row: every cell it holds is dashes, with an optional colon for
;; the column's alignment. Trailing space after the last bar is not a cell.
(define (md--table-rule? line)
  (and (md--table-row? line)
       (let ((cells (filter (lambda (c)
                              (not (equal? (string-trim (md--table-cell-text line c)) "")))
                            (md--table-cells line))))
         (and (pair? cells)
              (null? (filter (lambda (c)
                               (not (re-match md--table-rule-cell-pattern
                                              (md--table-cell-text line c))))
                             cells))))))

;; the space that pads a cell steps back, so a column starts at its text.
;; A cell that is only space keeps it: the blank column must still draw a
;; box, or the row loses a column and stops lining up with the rows above.
(define (md--table-cell-spans start line cell)
  (let* ((s (car cell)) (e (cadr cell))
         (text (md--table-cell-text line cell)))
    (if (equal? (string-trim text) "")
        '()
        (append
          (let ((lead (re-find* "^[ \t]+" text)))
            (if (null? lead)
                '()
                (list (md--span start s (+ s (cadr (car lead))) "md-marker"))))
          (let ((trail (re-find* "[ \t]+$" text)))
            (if (null? trail)
                '()
                (list (md--span start (+ s (car (car trail))) e "md-marker"))))))))

(define (md--table-row-spans start line faces)
  (let* ((len (string-byte-length line))
         (bars (md--table-bars line))
         (tail (+ (car (reverse bars)) 1)))
    (append
      (map (lambda (face) (list start (+ start len) face)) faces)
      ;; what indents the row, and any space after the closing bar
      (if (> (car bars) 0) (list (md--span start 0 (car bars) "md-marker")) '())
      (if (and (< tail len) (equal? (string-trim (substring-bytes line tail len)) ""))
          (list (md--span start tail len "md-marker"))
          '())
      (map (lambda (b) (md--span start b (+ b 1) "md-table-bar")) bars)
      (apply append
        (map (lambda (c) (md--table-cell-spans start line c)) (md--table-cells line))))))

(define (md--table-entry-line es)
  (and (pair? es) (equal? (morg-kind (car es)) 'text) (cadr (car es))))

;; the spans every table row in the buffer takes. A run opens on a head row
;; with a rule row under it and closes on the first line that is not a row.
(define (markdown--table-spans scan)
  (let loop ((es scan) (acc '()) (open #f))
    (if (null? es)
        (apply append (reverse acc))
        (let* ((e (car es))
               (start (car e))
               (line (cadr e))
               (next (md--table-entry-line (cdr es))))
          (cond
            ((not (equal? (morg-kind e) 'text)) (loop (cdr es) acc #f))
            ((and (md--table-row? line) (not (md--table-rule? line))
                  next (md--table-rule? next))
             (loop (cdr es)
                   (cons (md--table-row-spans start line '("row-table" "row-table-head")) acc)
                   #t))
            ((and open (md--table-rule? line))
             (let ((len (string-byte-length line)))
               (loop (cdr es)
                     (cons (list (list start (+ start len) "md-marker")
                                 (list start (+ start len) "row-table-rule"))
                           acc)
                     #t)))
            ((and open (md--table-row? line))
             (loop (cdr es) (cons (md--table-row-spans start line '("row-table")) acc) #t))
            (else (loop (cdr es) acc #f)))))))

;; the spans for one scan entry; block BODIES are highlighted per block in
;; markdown-refontify!, because a multi-line construct needs the whole body.
;; PREV is the text of the line above, or #f on the first line.
(define (markdown--line-spans e &optional prev fence-args)
  (let* ((start (car e)) (line (cadr e)) (k (morg-kind e))
         (len (string-byte-length line))
         (embed (re-groups md--embed-pattern line 0)))
    (cond
      ((= len 0) '())
      ((and (equal? k 'text) (md--caption? line prev)) (md--caption start line len))
      ;; a line that is one picture: the row centres it, as the page does
      ((not (null? (re-find* md--image-line-pattern line)))
       (cons (list start (+ start len) "row-picture") (md--images start line)))
      ((equal? k 'heading) (md--heading start line e len))
      ;; a row face (row-*) shapes the whole row: the page reads it off the
      ;; line, not the segment
      ;; the fence line renders as its own text: the backticks step back
      ;; and the info string stays — the language, a result's name, a diff
      ;; block's state and keys are text, and the preview draws them. The
      ;; kind's fence-face colors it, else it wears the dim fence face; a
      ;; bare fence has nothing to say and conceals whole.
      ((equal? k 'open)
       (let* ((lang (morg-info e))
              (le (+ start len))
              (face (or (fence-kind-get lang 'fence-face #f) "md-fence"))
              (m (re-groups "^([ \t]*```[ \t]*)" line 0))
              (info-start (if m (cadr (nth 1 m)) 0)))
         (if (equal? (string-trim (substring-bytes line info-start len)) "")
             (list (list start le "md-marker")
                   (list start le "row-fence"))
             (list (md--span start 0 info-start "md-marker")
                   (md--span start info-start len face)
                   (list start le "row-fence")))))
      ((equal? k 'close)
       (list (list start (+ start len) "md-marker") (list start (+ start len) "row-fence")))
      ;; a kind may draw its own rows (blocks/csv-block.scm draws a table):
      ;; (FN START LINE LEN HEAD?), HEAD? on the first row after the fence
      ((and (equal? k 'code) (fence-kind-get (morg-info e) 'row-spans #f))
       ((fence-kind-get (morg-info e) 'row-spans #f)
        start line len (and prev (string-prefix? "```" (string-trim prev)) #t)))
      ((equal? k 'code)
       (cons (list start (+ start len) "row-code")
             (let ((f (fence-kind-line-face (morg-info e) line fence-args)))
               (if f (list (list start (+ start len) f)) '()))))
      ;; a rule: the dashes step back, the row draws the line
      ((not (null? (re-find* "^(---+|\\*\\*\\*+|___+)[ \t]*$" line)))
       (list (list start (+ start len) "md-marker") (list start (+ start len) "row-hr")))
      ;; re-find* answers '() for no match, and '() is true: ask null?
      ((not (null? (re-find* md--x-pattern line)))
       (list (list start (+ start len) "x-embed")))
      (embed
       (let ((url (nth 1 embed)))
         (append
           (if (> (car url) 0)
               (list (md--span start 0 (car url) "md-marker")) '())
           (list (md--span start (car url) (cadr url) "youtube-embed"))
           (if (< (cadr url) len)
               (list (md--span start (cadr url) len "md-marker")) '()))))
      ((re-match (string-append "^" md--youtube-url-pattern "$") line)
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
           ;; each line sees the line above it and the open fence's args,
           ;; so a caption knows its picture and a body line its block
           (line-spans
             (car (fold (lambda (acc e)
                          (let* ((k (morg-kind e))
                                 (args (cond ((equal? k 'open)
                                              (morg-fence-args (cadr e)))
                                             ((equal? k 'code) (caddr acc))
                                             (else #f))))
                            (list (append (car acc)
                                          (markdown--line-spans
                                            e (cadr acc)
                                            (and (equal? k 'code) args)))
                                  (cadr e)
                                  args)))
                        (list '() #f #f) scan)))
           (table-spans (markdown--table-spans scan))
           (block-spans (fence-kind-body-spans text (morg-blocks scan buf))))
      (overlay-set! buf 'markdown
        (append line-spans table-spans block-spans)))))

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
