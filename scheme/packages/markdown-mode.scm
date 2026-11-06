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

;; A span at byte offsets S..E of LINE, which starts at byte START.
(define (md--span start s e face)
  (list (+ start s) (+ start e) face))

;; the share sheet appends ?s=20 and friends; a query or fragment after
;; the status id still names the same post
(define md--x-pattern
  "^https?://(mobile\\.)?(x|twitter)\\.com/[A-Za-z0-9_]+/status(es)?/[0-9]+/?([?#][^ \t]*)?$")
(define md--youtube-url-pattern
  "https://((www|m)\\.)?(youtube\\.com/(watch\\?[^ \\t]*v=[A-Za-z0-9_-]{11}[^ \\t]*|(shorts|live|embed)/[A-Za-z0-9_-]{11}[^ \\t]*)|youtu\\.be/[A-Za-z0-9_-]{11}[^ \\t]*)")
(define md--embed-pattern
  (string-append "^#\\+embed:[ \\t]+(" md--youtube-url-pattern ")[ \\t]*$"))

;;; The markup comes from the grammar (morg-markup): each line receives the
;;; captures that start on it, in document bytes. A construct OPEN bytes
;;; long at its head and CLOSE bytes at its tail steps its markers back,
;;; and FACE covers what is between them.
(define (md--wrapped s e open close face)
  (if (> (- e s) (+ open close))
      (list (list s (+ s open) "md-marker")
            (list (+ s open) (- e close) face)
            (list (- e close) e "md-marker"))
      '()))

;; the number of backticks at byte I of LINE: a code span's delimiter
(define (md--ticks line i n)
  (if (and (< (+ i n) (string-byte-length line))
           (equal? (substring-bytes line (+ i n) (+ i n 1)) "`"))
      (md--ticks line i (+ n 1))
      n))

;; true when LINE holds only white space from byte I to its end
(define (md--blank-from? line i)
  (equal? (string-trim (substring-bytes line i (string-byte-length line))) ""))

;; [text](url): the text is the link; the brackets and the target step
;; back. The drawn text carries its own target, so a reader can click it.
;; A span has one channel, its class, so the URL travels percent-encoded
;; and the client decodes it. A target in angle brackets is a target with
;; a space.
(define (md--link-class url)
  (let ((u (if (and (string-prefix? "<" url) (string-suffix? ">" url))
               (substring url 1 (- (string-length url) 1))
               url)))
    (string-append "link link-to:" (url-encode u))))

(define (md--link start line caps s e)
  (let* ((text (morg-markup-find caps "link-text" s e))
         (url (and text (morg-markup-find caps "link-destination" (caddr text) e))))
    (if (not url)
        '()
        (list (list s (cadr text) "md-marker")
              (list (cadr text) (caddr text)
                    (md--link-class
                      (substring-bytes line (- (cadr url) start) (- (caddr url) start))))
              (list (caddr text) e "md-marker")))))

;; ![alt](url): the URL draws as the picture; everything else steps back
(define (md--image caps s e)
  (let ((url (morg-markup-find caps "link-destination" s e)))
    (if (not url)
        '()
        (list (list s (cadr url) "md-marker")
              (list (cadr url) (caddr url) "img-embed")
              (list (caddr url) e "md-marker")))))

;; A kramdown inline attribute list right after a code span gives it
;; classes: `C-x`{:.key} draws the code with the face key as well, and the
;; list itself steps back as markup. AT is the byte in LINE after the span;
;; the answer is (LENGTH CLASSES), or #f.
(define (md--ial line at)
  (let ((len (string-byte-length line)))
    (and (< (+ at 3) len)
         (equal? (substring-bytes line at (+ at 2)) "{:")
         (let loop ((i (+ at 2)))
           (cond ((>= i len) #f)
                 ((equal? (substring-bytes line i (+ i 1)) "}")
                  (let ((names (filter (lambda (w) (not (equal? w "")))
                                       (string-split (substring-bytes line (+ at 2) i) " "))))
                    (and (pair? names)
                         (null? (filter (lambda (w) (not (and (string-prefix? "." w) (> (string-length w) 1)))) names))
                         (list (- (+ i 1) at) (map (lambda (w) (substring w 1 (string-length w))) names)))))
                 (else (loop (+ i 1))))))))

(define (md--inline-spans start line caps)
  (apply append
    (map (lambda (c)
           (let ((kind (car c)) (s (cadr c)) (e (caddr c)))
             (cond
               ((equal? kind "code")
                (let* ((n (md--ticks line (- s start) 0))
                       (spans (md--wrapped s e n n "morg-code"))
                       (ial (md--ial line (- e start))))
                  (if ial
                      (append spans
                              (map (lambda (c) (list (+ s n) (- e n) c)) (cadr ial))
                              (list (list e (+ e (car ial)) "md-marker")))
                      spans)))
               ((equal? kind "strong") (md--wrapped s e 2 2 "morg-bold"))
               ((equal? kind "emphasis") (md--wrapped s e 1 1 "morg-italic"))
               ((equal? kind "link") (md--link start line caps s e))
               ((equal? kind "image") (md--image caps s e))
               (else '()))))
         caps)))

;; a heading: the marker steps back, the text wears the level's face, and
;; a TODO keyword keeps its own face
(define (md--heading start line e len)
  (let* ((face (string-append "md-h"
                 (number->string (+ 1 (modulo (- (morg-info e) 1) 4)))))
         (text-start (morg-heading-text-start line (morg-info e)))
         (marker (if (> text-start 0) (list (md--span start 0 text-start "md-marker")) '()))
         (kw (morg-heading-keyword line text-start)))
    (append
      marker
      (cond
        ((>= text-start len) '())
        ((not kw) (list (md--span start text-start len face)))
        (else
         (let ((ks (nth 1 kw)) (ke (nth 2 kw)))
           (append
             (list (md--span start ks ke (if (equal? (car kw) "TODO") "org-todo" "org-done")))
             (if (< ke len) (list (md--span start ke len face)) '()))))))))

;; the marker that opens a line: a bullet, a number, or a quote's >
(define (md--line-marker caps)
  (cond ((null? caps) #f)
        ((member (car (car caps)) '("bullet" "ordered" "quote")) (car caps))
        (else (md--line-marker (cdr caps)))))

;; a bullet or a quote marker steps back and the row takes the shape; an
;; ordered item keeps its number, which is content
(define (md--block-marker start line len caps)
  (let ((m (md--line-marker caps))
        (le (+ start len)))
    (cond
      ((not m) '())
      ((equal? (car m) "bullet")
       (list (list (cadr m) (caddr m) "md-marker") (list start le "row-li")))
      ((equal? (car m) "ordered") (list (list start le "row-oli")))
      (else
       (list (list (cadr m) (min (caddr m) le) "md-marker") (list start le "row-quote"))))))

;; the capture of KIND that starts LINE and leaves only white space after
;; it: a line that is one picture, or one run of emphasis
(define (md--whole-line caps kind line start)
  (let ((c (morg-markup-find caps kind start (+ start (string-byte-length line)))))
    (and c (= (cadr c) start) (md--blank-from? line (- (caddr c) start)) c)))

;; Markdown has no caption syntax of its own. The shape most renderers
;; agree on, and the one the page draws as a figure (docs/MARKDOWN.md):
;; a picture on a line of its own, and under it a line that is only
;; emphasis. The stars step back, the words wear md-caption, and the row
;; wears row-caption: the page centres it under the picture.
(define (md--caption? line start caps prev prev-caps)
  (and prev
       (md--whole-line prev-caps "image" (cadr prev) (car prev))
       (let ((c (md--whole-line caps "emphasis" line start)))
         (and c (equal? (substring-bytes line 0 1) "*") c))))

(define (md--caption start len c)
  (list (list start (+ (cadr c) 1) "md-marker")
        (list (+ (cadr c) 1) (- (caddr c) 1) "md-caption")
        (list (- (caddr c) 1) (+ start len) "md-marker")
        (list start (+ start len) "row-caption")))

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
                                 (list start (+ start len) "row-conceal"))
                           acc)
                     #t)))
            ((and open (md--table-row? line))
             (loop (cdr es) (cons (md--table-row-spans start line '("row-table")) acc) #t))
            (else (loop (cdr es) acc #f)))))))

;;; --- indented code, and aligned tables inside it -------------------------
;;; A block indented four spaces is code (CommonMark). The grammar finds it,
;;; so a list item's indented paragraph stays text. The page draws the block
;;; in the code face, and the indent steps back.
;;;
;;; A run of lines in such a block whose words stand in shared columns is an
;;; aligned table. The page keeps it monospace, so the spaces keep the
;;; columns. The head row draws bold with a line under it, and a row never
;;; wraps. A column is a stretch of bytes where some line has a word; a gap
;;; is a stretch where every line has space or a bar.

(define md--icode-indent 4)

(define (md--icode-ranges caps)
  (map cdr (filter (lambda (c) (equal? (car c) "icode")) caps)))

;; the words of one line, (START END) in bytes; a bar is not a word
(define (md--aligned-words body) (re-find* "[^ \t|]+" body))

;; the union of the words of every line, as sorted, merged (START END)
(define (md--aligned-merge spans)
  (let loop ((ss (sort spans)) (acc '()))
    (cond ((null? ss) (reverse acc))
          ((and (pair? acc) (<= (car (car ss)) (cadr (car acc))))
           (loop (cdr ss)
                 (cons (list (car (car acc)) (max (cadr (car acc)) (cadr (car ss))))
                       (cdr acc))))
          (else (loop (cdr ss) (cons (car ss) acc))))))

;; the gaps between the columns of WORDS (the merged union), as (START END)
(define (md--aligned-gaps cols)
  (if (or (null? cols) (null? (cdr cols)))
      '()
      (cons (list (cadr (car cols)) (car (cadr cols)))
            (md--aligned-gaps (cdr cols)))))

;; Take rows from BODIES while the columns hold. A row joins when the table
;; keeps at least two gaps and loses no more than one. Prose under a table
;; fills the gaps, so it ends the table. -> the number of rows taken.
(define (md--aligned-take bodies)
  (let loop ((bs (cdr bodies))
             (words (md--aligned-words (car bodies)))
             (gaps (length (md--aligned-gaps (md--aligned-merge (md--aligned-words (car bodies))))))
             (n 1))
    (if (null? bs)
        n
        (let* ((w (append words (md--aligned-words (car bs))))
               (g (length (md--aligned-gaps (md--aligned-merge w)))))
          (if (and (>= g 2) (>= g (- gaps 1)))
              (loop (cdr bs) w g (+ n 1))
              n)))))

;; three rows, two gaps, and one gap two spaces wide: a table, not code
(define (md--aligned-table? bodies)
  (and (>= (length bodies) 3)
       (let ((gaps (md--aligned-gaps
                     (md--aligned-merge (apply append (map md--aligned-words bodies))))))
         (and (>= (length gaps) 2)
              (pair? (filter (lambda (g) (>= (- (cadr g) (car g)) 2)) gaps))))))

;; the first row is a head when it holds no digit and a later row does
(define (md--aligned-head? bodies)
  (and (not (re-match "[0-9]" (car bodies)))
       (pair? (filter (lambda (b) (re-match "[0-9]" b)) (cdr bodies)))))

;; the spans of one indented line; TABLE is #f, 'head, or 'row
(define (md--icode-line-spans start line table)
  (let* ((len (string-byte-length line))
         (ind (min md--icode-indent len)))
    (append
      (list (list start (+ start len) "row-code"))
      (if (> ind 0) (list (md--span start 0 ind "md-marker")) '())
      (if table
          (append
            (list (list start (+ start len) "row-table-aligned"))
            (if (equal? table 'head)
                (list (list start (+ start len) "row-table-aligned-head"))
                '())
            (map (lambda (b) (md--span start (car b) (cadr b) "md-table-pipe"))
                 (re-find* "[|]" line)))
          '()))))

;; one run of non-blank lines, ENTRIES from the scan: find the tables in it
(define (md--icode-run-spans es)
  (if (null? es)
      '()
      (let* ((bodies (map (lambda (e)
                            (let ((l (cadr e)))
                              (substring-bytes l (min md--icode-indent (string-byte-length l))
                                               (string-byte-length l))))
                          es))
             (n (md--aligned-take bodies))
             (table? (md--aligned-table? (list-head bodies n)))
             (head? (and table? (md--aligned-head? (list-head bodies n))))
             (took (if table? n 1)))
        (append
          (apply append
            (map (lambda (i)
                   (let ((e (list-ref es i)))
                     (md--icode-line-spans (car e) (cadr e)
                       (cond ((not table?) #f) ((and head? (= i 0)) 'head) (else 'row)))))
                 (iota took)))
          (md--icode-run-spans (list-tail es took))))))

;; split ENTRIES on blank lines into runs
(define (md--icode-runs es)
  (let loop ((es es) (run '()) (acc '()))
    (cond ((null? es) (reverse (if (pair? run) (cons (reverse run) acc) acc)))
          ((equal? (string-trim (cadr (car es))) "")
           (loop (cdr es) '() (if (pair? run) (cons (reverse run) acc) acc)))
          (else (loop (cdr es) (cons (car es) run) acc)))))

;; the spans of every indented code block in SCAN; CAPS carry the blocks
(define (markdown--icode-spans scan caps)
  (apply append
    (map (lambda (r)
           (let ((in (filter (lambda (e) (and (>= (car e) (car r)) (< (car e) (cadr r))
                                              (equal? (morg-kind e) 'text)))
                             scan)))
             (apply append (map md--icode-run-spans (md--icode-runs in)))))
         (md--icode-ranges caps))))


;; A kind that draws its own rows owns the whole block, so the page hides
;; its fence lines the way it hides every other marker. The walk needs the
;; scan: a closing fence names no language, only the open fence above it.
(define (markdown--own-rows-fence-spans scan)
  (let loop ((es scan) (own #f) (acc '()))
    (cond
      ((null? es) (apply append (reverse acc)))
      (else
        (let* ((e (car es))
               (k (morg-kind e))
               (start (car e))
               (len (string-byte-length (cadr e)))
               (conceal (list (list start (+ start len) "md-marker")
                              (list start (+ start len) "row-conceal"))))
          (cond
            ((equal? k 'open)
             (let ((own? (and (fence-kind-get (morg-info e) 'row-spans #f) #t)))
               (loop (cdr es) own? (if own? (cons conceal acc) acc))))
            ((equal? k 'close)
             (loop (cdr es) #f (if own (cons conceal acc) acc)))
            (else (loop (cdr es) own acc))))))))

;; the spans for one scan entry; block BODIES are highlighted per block in
;; markdown-refontify!, because a multi-line construct needs the whole body.
;; CAPS are the grammar's captures on the line. PREV is the entry above
;; and PREV-CAPS its captures, or #f and () on the first line.
(define (markdown--line-spans e caps prev prev-caps fence-args)
  ;; one frame: this runs on every line of every edit
  (let ((start (car e)) (line (car (cdr e))) (k (car (cdr (cdr e))))
        (len (string-byte-length (car (cdr e))))
        (embed (re-groups md--embed-pattern (car (cdr e)) 0)))
    (cond
      ((= len 0) '())
      ((and (pair? caps) (pair? prev-caps) (equal? k 'text)
            (md--caption? line start caps prev prev-caps))
       (md--caption start len (md--caption? line start caps prev prev-caps)))
      ;; a line that is one picture: the row centres it, as the page does
      ((and (pair? caps) (md--whole-line caps "image" line start))
       (cons (list start (+ start len) "row-picture") (md--inline-spans start line caps)))
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
        start line len (and prev (string-prefix? "```" (string-trim (cadr prev))) #t)))
      ((equal? k 'code)
       (cons (list start (+ start len) "row-code")
             (let ((f (fence-kind-line-face (morg-info e) line fence-args)))
               (if f (list (list start (+ start len) f)) '()))))
      ;; a rule: the dashes step back, the row draws the line
      ((and (pair? caps) (equal? (car (car caps)) "rule") (= (car (cdr (car caps))) start))
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
      ((null? caps) '())
      (else
       (append
         (md--block-marker start line len caps)
         (md--inline-spans start line caps))))))

(define (markdown-refontify! buf)
  (when (buffer-exists? buf)
    (let* ((both (morg-scan-markup buf))
           (scan (car both))
           ;; each line sees its captures, the entry above it with that
           ;; entry's captures, and the open fence's args: a caption knows
           ;; its picture, and a body line its block
           (line-spans (morg-markup-spans scan (cadr both) markdown--line-spans))
           (table-spans (markdown--table-spans scan))
           (icode-spans (markdown--icode-spans scan (cadr both)))
           (fence-spans (markdown--own-rows-fence-spans scan))
           (block-spans (fence-kind-body-spans (buffer-text buf) (morg-blocks scan buf))))
      (overlay-set! buf 'markdown
        (append line-spans table-spans icode-spans fence-spans block-spans)))))

;;; --- the mode ----------------------------------------------------------------

;; The reactor binds a rule to one buffer process. A killed and recreated
;; buffer has a new reference, so setup replaces the old rule.
(define *markdown-hooks* '())

(define (markdown--ensure-hook! buf)
  (let ((old (assoc buf *markdown-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *markdown-hooks* (alist-put *markdown-hooks* buf (on-change! buf
                    (lambda (pos inserted deleted source)
                      (unless (equal? source "locals")
                        (markdown-refontify! buf)))
                    'eager)))))

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
