;;; morg.scm --- markdown with org habits.
;;;
;;; morg-mode is a superset of the plain markdown experience. TAB folds a
;;; `#` heading's subtree or a fenced code block. S-TAB folds the whole
;;; file. morg-babel runs fenced blocks, off the editor lane. morg-tangle
;;; writes marked blocks to source files. Fenced code renders with the theme's ts-* faces through
;;; (ts-highlight-string LANG TEXT) when the grammar is loaded.
;;;
;;; OFFSET RULE: every index that touches the buffer, an overlay, or a
;;; re-find/re-groups result is a BYTE offset. Use string-byte-length and
;;; substring-bytes on such indexes — never string-length/substring, which
;;; count graphemes and desync on non-ASCII text.
;;;
;;; Keys (buffer-local):
;;;   TAB fold cycle (heading subtree or code block) · S-TAB overview/show all
;;;   C-c C-t cycle the heading's TODO state
;;;   C-c C-c run the code block at point · C-c C-x tangle marked blocks
;;;   C-x n n narrow to the heading · C-x n w widen

(package! 'morg)
(category! 'writing)
(domain! 'writing)
(effects! '(read))

;;; --- line model --------------------------------------------------------------

;; -> ((start-byte line-string) ...), in buffer order
(define (morg-lines buf)
  (let loop ((ls (split-lines (buffer-text buf))) (pos 0) (acc '()))
    (if (null? ls)
        (reverse acc)
        (loop (cdr ls)
              (+ pos (string-byte-length (car ls)) 1)
              (cons (list pos (car ls)) acc)))))

;; opening fence info string ("" for a bare ```), or #f
(define (morg-fence-info line)
  (let ((g (re-groups "^[ \t]*```[ \t]*([A-Za-z0-9_+.-]*)" line 0)))
    (if g
        (let ((r (cadr g)))
          (substring-bytes line (car r) (cadr r)))
        #f)))

;; what follows the language on an open fence: ":tangle out.scm", a
;; rewrite's instruction, ":sync" — the block's own arguments, trimmed
(define (morg-fence-args line)
  (let ((g (re-groups "^[ \t]*```[ \t]*[A-Za-z0-9_+.-]*[ \t]*(.*)$" line 0)))
    (if g
        (let ((r (cadr g)))
          (string-trim (substring-bytes line (car r) (cadr r))))
        "")))

(define (morg-fence-close? line)
  (re-match "^[ \t]*```[ \t]*$" line))

;; A block directive occupies one complete line: #+name: value.
(define (morg-directive-info line)
  (let ((g (re-groups "^#\\+([A-Za-z0-9_-]+):[ \t]*(.*)$" line 0)))
    (if g
        (let ((name (nth 1 g)) (value (nth 2 g)))
          (list
            (string-downcase (substring-bytes line (car name) (cadr name)))
            (substring-bytes line (car value) (cadr value))))
        #f)))

;; entry accessors: an entry is (start line kind info)
;;   kind 'heading — info is the level (1..6)
;;   kind 'open    — info is the block's language ("" when unnamed)
;;   kind 'code    — info is the enclosing block's language
;;   kind 'directive — info is (name value)
;;   kind 'close / 'text — info is #f
(define (morg-kind e) (caddr e))
(define (morg-info e) (car (cdr (cdr (cdr e)))))

;; classify every line, by the walk with the fence state carried through,
;; so a `# comment` inside a code block never reads as a heading. This is
;; the answer where the reader has no markdown grammar; morg-scan itself
;; asks tree-sitter first.
(define (morg-scan--walk buf)
  (let loop ((ls (morg-lines buf)) (in #f) (acc '()))
    (if (null? ls)
        (reverse acc)
        (let* ((e (car ls)) (start (car e)) (line (cadr e)))
          (cond
            ((and in (morg-fence-close? line))
             (loop (cdr ls) #f (cons (list start line 'close #f) acc)))
            (in
             (loop (cdr ls) in (cons (list start line 'code in) acc)))
            ((morg-fence-info line)
             (let ((lang (morg-fence-info line)))
               (loop (cdr ls) lang (cons (list start line 'open lang) acc))))
            ((morg-directive-info line)
             (loop (cdr ls) #f
                   (cons (list start line 'directive
                               (morg-directive-info line)) acc)))
            ((re-match "^#{1,6}[ \t]" line)
             (let ((m (re-groups "^(#+)" line 0)))
               (loop (cdr ls) #f
                     (cons (list start line 'heading
                                 (- (cadr (cadr m)) (car (cadr m))))
                           acc))))
            (else
             (loop (cdr ls) #f (cons (list start line 'text #f) acc))))))))

;; The scan, from the grammar. Tree-sitter parses the document — it
;; already knows a # inside a fence is not a heading — and every line is
;; classified from its tree: the blocks from block--ts-list, the headings
;; from their markers. The entries are the same shape the walk answers,
;; so every consumer reads either. Directives are our own syntax, which
;; markdown reads as a paragraph, so their line regex stays.
(define morg--heading-query
  "(atx_h1_marker) @1 (atx_h2_marker) @2 (atx_h3_marker) @3 (atx_h4_marker) @4 (atx_h5_marker) @5 (atx_h6_marker) @6")

(define (morg-scan--ts buf)
  (let* ((text (buffer-text buf))
         (blocks (block--ts-list text))
         (heads (map (lambda (h) (list (cadr h) (string->number (car h))))
                     (ts-query-string "markdown" text morg--heading-query))))
    (let loop ((ls (morg-lines buf)) (bs blocks) (acc '()))
      (if (null? ls)
          (reverse acc)
          (let* ((e (car ls)) (start (car e)) (line (cadr e))
                 (bs (let drop ((bs bs))
                       (if (and (pair? bs) (< (nth 1 (car bs)) start))
                           (drop (cdr bs))
                           bs)))
                 (b (and (pair? bs)
                         (<= (nth 0 (car bs)) start)
                         (<= start (nth 1 (car bs)))
                         (car bs)))
                 (head (assoc start heads))
                 (entry
                   (cond
                     ((and b (= start (nth 0 b)))
                      (list start line 'open (block-lang b)))
                     ((and b (morg-fence-close? line)
                           (let ((le (+ start (string-byte-length line))))
                             (and (<= start (nth 1 b)) (<= (nth 1 b) le))))
                      (list start line 'close #f))
                     (b (list start line 'code (block-lang b)))
                     (head (list start line 'heading (cadr head)))
                     ((morg-directive-info line)
                      (list start line 'directive (morg-directive-info line)))
                     (else (list start line 'text #f)))))
            (loop (cdr ls) bs (cons entry acc)))))))

(define (morg-scan buf)
  (if (member "markdown" (ts-langs))
      (morg-scan--ts buf)
      (morg-scan--walk buf)))

;; the scan entry whose line contains byte pos
(define (morg-entry-at scan pos)
  (let loop ((es scan) (prev #f))
    (cond ((null? es) prev)
          ((> (car (car es)) pos) prev)
          (else (loop (cdr es) (car es))))))

;; nearest heading entry at or before pos, or #f
(define (morg-enclosing-heading scan pos)
  (let loop ((es scan) (best #f))
    (cond ((null? es) best)
          ((> (car (car es)) pos) best)
          (else (loop (cdr es)
                      (if (equal? (morg-kind (car es)) 'heading) (car es) best))))))

;; end of the subtree headed at hstart: the byte just before the next
;; heading of level <= level, else buffer end
(define (morg-subtree-end scan buf hstart level)
  (let loop ((es scan))
    (cond ((null? es) (buffer-size buf))
          ((<= (car (car es)) hstart) (loop (cdr es)))
          (else
            (let ((e (car es)))
              (if (and (equal? (morg-kind e) 'heading) (<= (morg-info e) level))
                  (- (car e) 1)
                  (loop (cdr es))))))))

;;; --- structural document API -------------------------------------------------
;;; A sandboxed agent edits the live Markdown buffer through these functions.
;;; LINE comes from markdown-outline. It avoids title matching and byte offsets.

(effects! '(read))

(define (markdown--title e)
  (string-trim
    (substring-bytes (cadr e) (morg-info e) (string-byte-length (cadr e)))))

(define (markdown-outline buf)
  (if (not (buffer-exists? buf))
      (string-append "no such buffer: " buf)
      (with-current-buffer buf
        (lambda ()
          (map (lambda (e)
                 (list (line-number-at-pos (car e))
                       (morg-info e)
                       (markdown--title e)))
               (filter (lambda (e) (equal? (morg-kind e) 'heading))
                       (morg-scan buf)))))))

(define (markdown-find buf text)
  (let ((rows (markdown-outline buf)))
    (if (string? rows)
        rows
        (filter (lambda (row) (if (string-index (caddr row) text) #t #f)) rows))))

;; Unlike morg-subtree-end, this returns an exclusive edit boundary. It keeps
;; the newline before the next peer section inside the selected section.
(define (markdown--section-end scan buf heading)
  (let ((start (car heading)) (level (morg-info heading)))
    (let loop ((entries scan))
      (cond ((null? entries) (buffer-size buf))
            ((<= (car (car entries)) start) (loop (cdr entries)))
            ((and (equal? (morg-kind (car entries)) 'heading)
                  (<= (morg-info (car entries)) level))
             (car (car entries)))
            (else (loop (cdr entries)))))))

;; The end of this heading's own text. Any child starts another section.
(define (markdown--section-body-end scan buf heading)
  (let ((start (car heading)))
    (let loop ((entries scan))
      (cond ((null? entries) (buffer-size buf))
            ((<= (car (car entries)) start) (loop (cdr entries)))
            ((equal? (morg-kind (car entries)) 'heading) (car (car entries)))
            (else (loop (cdr entries)))))))

(define (markdown--line-count buf)
  (line-number-at-pos (buffer-size buf)))

(define (markdown--with-section buf line fn)
  (cond
    ((not (buffer-exists? buf)) (string-append "no such buffer: " buf))
    ((or (not (number? line)) (< line 1)) "line must be a positive number")
    (else
      (with-current-buffer buf
        (lambda ()
          (let ((count (markdown--line-count buf)))
            (if (> line count)
                (string-append "line " (number->string line)
                               " is outside the buffer — it has "
                               (number->string count) " lines")
                (let* ((scan (morg-scan buf))
                       (heading (morg-enclosing-heading scan
                                  (line-start-position line))))
                  (if (not heading)
                      (string-append "no Markdown section holds line "
                                     (number->string line)
                                     " — call (markdown-outline BUF)")
                      (fn heading (markdown--section-end scan buf heading)
                          scan))))))))))

(define (markdown-read buf line &optional subtree?)
  (markdown--with-section buf line
    (lambda (heading subtree-end scan)
      (let ((end (if subtree?
                     subtree-end
                     (markdown--section-body-end scan buf heading))))
        (substring-bytes (buffer-text buf) (car heading) end)))))

(effects! '(write))

(define (markdown--terminated text end size)
  (if (and (< end size) (not (equal? text ""))
           (not (string-suffix? "\n" text)))
      (string-append text "\n")
      text))

(define (markdown-replace! buf line new)
  (markdown--with-section buf line
    (lambda (heading end _scan)
      (let* ((start (car heading))
             (replacement (markdown--terminated new end (buffer-size buf))))
        (buffer-delete-range! buf start (- end start))
        (buffer-insert! buf start replacement)
        (string-append "replaced the Markdown section at line "
                       (number->string line))))))

(define (markdown-insert-after! buf line text)
  (markdown--with-section buf line
    (lambda (_heading end _scan)
      (let* ((source (buffer-text buf))
             (prefix (if (and (> end 0)
                              (not (equal? (substring-bytes source (- end 1) end)
                                           "\n")))
                         "\n" ""))
             (suffix (if (or (equal? text "") (string-suffix? "\n" text))
                         "" "\n")))
        (buffer-insert! buf end (string-append prefix text suffix))
        (string-append "inserted Markdown after the section at line "
                       (number->string line))))))

(effects! '(read))
(public! 'markdown-outline
  "(markdown-outline BUF) — every Markdown heading as (LINE LEVEL TITLE)")
(public! 'markdown-find
  "(markdown-find BUF TEXT) — heading rows whose title contains TEXT")
(public! 'markdown-read
  "(markdown-read BUF LINE [SUBTREE?]) — read one Markdown section; include descendants only when SUBTREE? is true")
(effects! '(write))
(public! 'markdown-replace!
  "(markdown-replace! BUF LINE NEW) — replace the complete section that holds LINE")
(public! 'markdown-insert-after!
  "(markdown-insert-after! BUF LINE TEXT) — insert TEXT after the complete section that holds LINE")

(effects! '(read))

(define-tool! 'markdown-outline
  "List a live Markdown document as (LINE LEVEL TITLE). Always call this first, then read only relevant sections."
  (list (list 'buffer "string" "live Markdown buffer name"))
  (lambda (args)
    (value->string (markdown-outline (custom--plist-get args 'buffer))))
  '(read))

(define-tool! 'markdown-read
  "Read one Markdown section. Call markdown-outline first. The default excludes child sections; set subtree true only when descendants are required."
  (list (list 'buffer "string" "live Markdown buffer name")
        (list 'line "number" "1-based line from markdown-outline")
        (list 'subtree "boolean" "include child sections" 'optional))
  (lambda (args)
    (markdown-read (custom--plist-get args 'buffer)
                   (custom--plist-get args 'line)
                   (custom--plist-get args 'subtree)))
  '(read))

;;; --- block geometry ----------------------------------------------------------

;; open-fence start of the block containing pos, or #f. A pos on the
;; close fence line still belongs to its block.
(define (morg-block-open scan pos)
  (let loop ((es scan) (open #f))
    (cond ((null? es) open)
          ((> (car (car es)) pos) open)
          (else
            (let* ((e (car es)) (k (morg-kind e)))
              (loop (cdr es)
                    (cond ((equal? k 'open) (car e))
                          ((equal? k 'code) open)
                          ((and (equal? k 'close) (= (car e) pos)) open)
                          (else #f))))))))

;; -> (body-start body-end) for the block opened at fstart; an unclosed
;; fence runs to buffer end
(define (morg-block-body scan buf fstart)
  (let* ((e (morg-entry-at scan fstart))
         (bstart (min (+ fstart (string-byte-length (cadr e)) 1)
                      (buffer-size buf))))
    (let loop ((es scan))
      (cond ((null? es) (list bstart (buffer-size buf)))
            ((<= (car (car es)) fstart) (loop (cdr es)))
            ((equal? (morg-kind (car es)) 'close)
             (list bstart (car (car es))))
            (else (loop (cdr es)))))))

;; end byte of the close fence line for the block opened at fstart, or
;; buffer end when the fence never closes
(define (morg-block-close-end scan buf fstart)
  (let loop ((es scan))
    (cond ((null? es) (buffer-size buf))
          ((<= (car (car es)) fstart) (loop (cdr es)))
          ((equal? (morg-kind (car es)) 'close)
           (+ (car (car es)) (string-byte-length (cadr (car es)))))
          (else (loop (cdr es))))))

;; ((open-start lang body-start body-end) ...) in buffer order
(define (morg-blocks scan buf)
  (let loop ((es scan) (acc '()))
    (cond ((null? es) (reverse acc))
          ((equal? (morg-kind (car es)) 'open)
           (let* ((e (car es))
                  (body (morg-block-body scan buf (car e))))
             (loop (cdr es)
                   (cons (cons (car e) (cons (morg-info e) body)) acc))))
          (else (loop (cdr es) acc)))))

;;; --- folding -----------------------------------------------------------------
;;; Fold state: buffer-local 'morg-folds = anchor offsets (heading starts
;;; and open-fence starts). The Buffer's hidden ranges are DERIVED from it
;;; under the 'morg tag; the change hook re-anchors and revalidates the
;;; list, and the mode setup fn re-derives the ranges after a restart.

(effects! '(write))

(define (morg-folds buf)
  (let ((f (buffer-local buf 'morg-folds)))
    (if f f '())))

(define (morg-outline? buf)
  (equal? (buffer-local buf 'morg-outline) #t))

;; End of this heading's own body. A child heading starts a new visible line.
(define (morg-heading-body-end scan buf hstart)
  (let loop ((es scan))
    (cond ((null? es) (buffer-size buf))
          ((<= (car (car es)) hstart) (loop (cdr es)))
          ((equal? (morg-kind (car es)) 'heading) (- (car (car es)) 1))
          (else (loop (cdr es))))))

(define (morg-apply-folds! buf)
  (let* ((scan (morg-scan buf))
         (outline? (morg-outline? buf))
         (valid (filter
                  (lambda (h)
                    (let ((e (morg-entry-at scan h)))
                      (and e (= (car e) h)
                           (or (equal? (morg-kind e) 'heading)
                               (equal? (morg-kind e) 'open)))))
                  (morg-folds buf)))
         (ranges
           (map
             (lambda (h)
               (let* ((e (morg-entry-at scan h))
                      (eol (+ h (string-byte-length (cadr e)))))
                 (cond
                   ((and outline? (equal? (morg-kind e) 'heading))
                    (list eol (morg-heading-body-end scan buf h)))
                   ((equal? (morg-kind e) 'heading)
                    (list eol (morg-subtree-end scan buf h (morg-info e))))
                   (else
                    (list eol (morg-block-close-end scan buf h))))))
             valid)))
    (buffer-set-local! buf 'morg-folds valid)
    (fold-set! buf 'morg
      (filter (lambda (r) (< (car r) (cadr r))) ranges))))

(define (morg-set-folds! buf folds)
  (buffer-set-local! buf 'morg-outline #f)
  (buffer-set-local! buf 'morg-folds folds)
  (morg-apply-folds! buf))

(define (morg-toggle-fold buf h)
  (let ((folds
          (if (member h (morg-folds buf))
              (filter (lambda (x) (not (equal? x h))) (morg-folds buf))
              (cons h (morg-folds buf)))))
    (if (morg-outline? buf)
        (begin
          ;; Keep body-only geometry while one heading changes visibility.
          (buffer-set-local! buf 'morg-folds folds)
          (morg-apply-folds! buf))
        (morg-set-folds! buf folds))))

;;; --- cosmetic narrowing ------------------------------------------------------
;;; Narrowing changes the visible document only. The context provider adds a
;;; small focus hint. The agent reads the outline and selected sections.

(define (morg-narrow-anchor buf)
  (buffer-local buf 'morg-narrow-anchor))

(define (morg-clear-narrow! buf)
  (buffer-set-local! buf 'morg-narrow-anchor #f)
  ;; Narrowing briefly used folds before it became a core buffer concept.
  ;; A hot-loaded buffer can still carry that tag, which would keep hiding
  ;; text after the real narrowing is widened and make TAB look ineffective.
  (fold-clear! buf 'morg-narrow)
  (buffer-widen! buf))

(define (morg-apply-narrow! buf)
  ;; Migrate live buffers created by the fold-based implementation.
  (fold-clear! buf 'morg-narrow)
  (let* ((anchor (morg-narrow-anchor buf))
         (scan (morg-scan buf))
         (entry (and anchor (morg-entry-at scan anchor))))
    (if (not (and entry (= (car entry) anchor)
                  (equal? (morg-kind entry) 'heading)))
        (morg-clear-narrow! buf)
        (let* ((end (markdown--section-end scan buf entry))
               (size (buffer-size buf)))
          (buffer-narrow! buf anchor (min end size))
          entry))))

(define-command "morg-narrow" "Show only the Morg heading at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (entry (morg-enclosing-heading (morg-scan buf) (point))))
      (if (not entry)
          (message "No Morg heading holds point")
          (begin
            (buffer-set-local! buf 'morg-narrow-anchor (car entry))
            (morg-apply-narrow! buf)
            (message (string-append "Narrowed to " (markdown--title entry))))))))

(define-command "morg-widen" "Show the complete Morg document"
  (lambda ()
    (morg-clear-narrow! (current-buffer))
    (message "Widened Morg document")))

(define-command "morg-cycle" "Fold the heading or the code block at point, else indent"
  (lambda ()
    (let* ((buf (current-buffer))
           (scan (morg-scan buf))
           (e (morg-entry-at scan (point)))
           (anchor
             (and e
                  (cond ((equal? (morg-kind e) 'heading) (car e))
                        ((equal? (morg-kind e) 'open) (car e))
                        (else (morg-block-open scan (point)))))))
      (if anchor
          (morg-toggle-fold buf anchor)
          (run-command "indent-for-tab")))))

(define-command "morg-outline" "Hide body text and keep every heading visible"
  (lambda ()
    (let* ((buf (current-buffer))
           (scan (morg-scan buf))
           (headings
             (map car (filter (lambda (e) (equal? (morg-kind e) 'heading)) scan))))
      (buffer-set-local! buf 'morg-folds headings)
      (buffer-set-local! buf 'morg-outline #t)
      (morg-apply-folds! buf)
      ;; Point may be in a now-hidden body. Surface it on its heading.
      (let ((h (morg-enclosing-heading scan (point))))
        (when h (goto-char! (car h))))
      (message "OUTLINE"))))

(define-command "morg-global-cycle" "Cycle global visibility: overview or show all"
  (lambda ()
    (let* ((buf (current-buffer))
           (scan (morg-scan buf)))
      (if (null? (morg-folds buf))
          (begin
            (morg-set-folds! buf
              (map car (filter (lambda (e) (equal? (morg-kind e) 'heading)) scan)))
            ;; point may be in a now-hidden body — surface it on its heading
            (let ((h (morg-enclosing-heading scan (point))))
              (when h (goto-char! (car h))))
            (message "OVERVIEW"))
          (begin
            (morg-set-folds! buf '())
            (message "SHOW ALL"))))))

;;; A folded line stands for more source than its visible text. When the
;;; complete visible line is selected, copy and cut must use that source range.
(define (morg-folded-entry-end scan buf anchor)
  (let ((e (morg-entry-at scan anchor)))
    (cond
      ((and e (= (car e) anchor) (equal? (morg-kind e) 'heading))
       (markdown--section-end scan buf e))
      ((and e (= (car e) anchor) (equal? (morg-kind e) 'open))
       (min (buffer-size buf) (+ (morg-block-close-end scan buf anchor) 1)))
      (else #f))))

(define (morg-lift-folded-region buf start end)
  (let ((scan (morg-scan buf)))
    (let loop ((folds (morg-folds buf)) (lifted-end end))
      (if (null? folds)
          (list start lifted-end)
          (let* ((anchor (car folds))
                 (entry (morg-entry-at scan anchor))
                 (line-end (and entry
                                 (+ anchor (string-byte-length (cadr entry)))))
                 (block-end (morg-folded-entry-end scan buf anchor)))
            (loop (cdr folds)
                  (if (and line-end block-end
                           (<= start anchor) (>= lifted-end line-end))
                      (max lifted-end block-end)
                      lifted-end)))))))

(register-region-lifter! "morg-mode" morg-lift-folded-region)

;;; --- TODO --------------------------------------------------------------------

;; Replace one whole line as one undo step. Keep point at its byte column
;; when point is on that line.
(define (morg-replace-line! buf start old new)
  (unless (equal? old new)
    (let ((p (buffer-point buf))
          (old-len (string-byte-length old)))
      (buffer-replace-range! buf start old-len new)
      (when (and (>= p start) (<= p (+ start old-len)))
        (buffer-goto! buf (min p (+ start (string-byte-length new))))))))

;; Cycle the heading at POS through none, TODO, and DONE.
;; Return the new state string, or #f when POS is not on a heading.
(define (morg-toggle-todo-at! buf pos)
  (let* ((e (morg-entry-at (morg-scan buf) pos)))
    (if (not (and e (equal? (morg-kind e) 'heading)))
        #f
        (let* ((start (car e))
               (line (cadr e))
               (g (re-groups "^(#{1,6}[ \t]+)(TODO[ \t]+|DONE[ \t]+)?" line 0))
               (pre (nth 1 g))
               (kw (nth 2 g))
               (head (substring-bytes line 0 (cadr pre)))
               (rest (substring-bytes line (if kw (cadr kw) (cadr pre))
                                      (string-byte-length line)))
               (cur (if kw
                        (substring-bytes line (car kw) (+ (car kw) 4))
                        ""))
               (next (cond ((equal? cur "") "TODO")
                           ((equal? cur "TODO") "DONE")
                           (else "NONE")))
               (new (string-append head
                      (cond ((equal? next "TODO") "TODO ")
                            ((equal? next "DONE") "DONE ")
                            (else ""))
                      rest)))
          (morg-replace-line! buf start line new)
          (when (equal? (buffer-local buf 'mode-name) "morg-mode")
            (morg-refontify! buf))
          next))))

(define-command "morg-todo" "Cycle the TODO state of the heading at point"
  (lambda ()
    (let ((state (morg-toggle-todo-at! (current-buffer) (point))))
      (if state
          (message (if (equal? state "NONE") "TODO state cleared" state))
          (message "Point is not on a heading")))))

;;; --- fontification -----------------------------------------------------------

(defface! 'morg-code
  'fg "#3d6b4f"
  'family "'IBM Plex Mono',ui-monospace,Menlo,monospace")
(defface! 'morg-bold 'weight "700")
(defface! 'morg-italic 'style "italic")
(defface! 'morg-result 'fg "#8a857a")

;; markdown info string -> loaded tree-sitter language, or #f.
;; The fence-kind registry (morg-kinds.scm) owns the mapping.
(define (morg-ts-lang lang) (fence-kind-ts-lang lang))

;; spans for one scan entry; block BODIES are highlighted per block in
;; morg-refontify!, because a multi-line construct needs the whole body.
;; This is the plain source view: every marker stays visible. preview-mode
;; draws the page in place, and its painter replaces this when it is on.
(define (morg-line-spans e &optional fence-args buf)
  (let* ((start (car e)) (line (cadr e)) (k (morg-kind e))
         (len (string-byte-length line))
         (abs (lambda (r) (list (+ start (car r)) (+ start (cadr r))))))
    (cond
      ((= len 0) '())
      ((equal? k 'heading)
       (let* ((face (string-append "org-level-"
                      (number->string (+ 1 (modulo (- (morg-info e) 1) 4)))))
              (g (re-groups "^#{1,6}[ \t]+(TODO|DONE)[ \t]" line 0)))
         (if (not g)
             (list (list start (+ start len) face))
             (let* ((r (nth 1 g))
                    (ks (+ start (car r)))
                    (ke (+ start (cadr r)))
                    (todo (substring-bytes line (car r) (cadr r))))
               (append
                 (if (> ks start) (list (list start ks face)) '())
                 (list (list ks ke (if (equal? todo "TODO")
                                       "org-todo" "org-done")))
                 (if (< ke (+ start len))
                     (list (list ke (+ start len) face))
                     '()))))))
      ;; the open fence is the block's header: a kind that declares a
      ;; fence-face colors it apart from the plain markers
      ((equal? k 'open)
       (list (list start (+ start len)
                   (or (fence-kind-get (morg-info e) 'fence-face #f)
                       "org-meta"))))
      ((equal? k 'close) (list (list start (+ start len) "org-meta")))
      ((equal? k 'directive) (list (list start (+ start len) "org-meta")))
      ((equal? k 'code)
       (let ((f (fence-kind-line-face (morg-info e) line fence-args)))
         (if f (list (list start (+ start len) f)) '())))
      (else
       (append
         (map (lambda (r) (append (abs r) '("morg-code")))
              (re-find* "`[^`\n]+`" line))
         (map (lambda (r) (append (abs r) '("morg-bold")))
              (re-find* "\\*\\*[^*\n]+\\*\\*" line))
         (map (lambda (r) (append (abs r) '("morg-italic")))
              (re-find* "\\b_[^_\n]+_\\b" line))
         (map (lambda (r) (append (abs r) '("link")))
              (re-find* "\\[[^\\]\n]+\\]\\([^)\n]+\\)" line)))))))

(define (morg-refontify! buf)
  ;; preview-mode's painter (drawn in place) has its own hook when it is on
  (when (and (buffer-exists? buf)
             (not (equal? (buffer-local buf 'markdown-paint) #t)))
    (let* ((scan (morg-scan buf))
           (text (buffer-text buf))
           ;; each body line sees its open fence's arguments, so a kind
           ;; can paint by them (a live diff's one-sided views stay prose)
           (line-spans
             (car (fold (lambda (acc e)
                          (let* ((k (morg-kind e))
                                 (args (cond ((equal? k 'open)
                                              (morg-fence-args (cadr e)))
                                             ((equal? k 'code) (cadr acc))
                                             (else #f))))
                            (list (append (car acc)
                                          (morg-line-spans
                                            e (and (equal? k 'code) args) buf))
                                  args)))
                        (list '() #f) scan)))
           (block-spans (fence-kind-body-spans text (morg-blocks scan buf))))
      (overlay-set! buf 'morg (append line-spans block-spans)))))

;;; --- change hook -------------------------------------------------------------

;; "locals" is the phantom change a buffer-set-local! broadcasts. This
;; handler writes 'morg-folds itself, so reacting to the phantom is a
;; feedback loop. Folds and overlays depend on the text only.
(define (morg-after-change buf pos inserted deleted source)
  (when (and (buffer-exists? buf) (not (equal? source "locals")))
    ;; re-anchor folds through the edit, then validation prunes the dead
    (let ((delta (- (string-byte-length inserted) deleted)))
      (unless (= delta 0)
        (buffer-set-local! buf 'morg-folds
          (map (lambda (h) (if (>= h pos) (max pos (+ h delta)) h))
               (morg-folds buf)))
        (let ((anchor (morg-narrow-anchor buf)))
          (when anchor
            (buffer-set-local! buf 'morg-narrow-anchor
              (if (>= anchor pos) (max pos (+ anchor delta)) anchor))))))
    (morg-apply-folds! buf)
    (morg-apply-narrow! buf)
    (morg-refontify! buf)))

;;; --- the mode ----------------------------------------------------------------

(effects! '(write))

;;; --- motion -----------------------------------------------------------------
;;; A note is read by jumping: heading to heading, sibling to sibling, link to
;;; link. A motion that finds nothing leaves point where it is and says so, so
;;; a held key cannot walk off the end of the document.

(define morg--link-pattern "\\[([^\\]\n]+)\\]\\(([^)\n]+)\\)")

(define (morg--headings buf)
  (filter (lambda (e) (equal? (morg-kind e) 'heading)) (morg-scan buf)))

(define (morg--land! pos what)
  (if pos
      (begin (goto-char! pos) pos)
      (begin (message (string-append "No " what)) #f)))

;; LEVEL #f accepts the next heading of any depth. A number accepts one
;; exactly that deep and gives up at a shallower one, so same-level motion
;; stays inside its own parent instead of jumping to the next section.
(define (morg--heading-after buf pos level)
  (let loop ((es (morg--headings buf)))
    (cond ((null? es) #f)
          ((<= (car (car es)) pos) (loop (cdr es)))
          ((not level) (car (car es)))
          ((< (morg-info (car es)) level) #f)
          ((equal? (morg-info (car es)) level) (car (car es)))
          (else (loop (cdr es))))))

(define (morg--heading-before buf pos level)
  (let loop ((es (morg--headings buf)) (best #f))
    (cond ((null? es) best)
          ((>= (car (car es)) pos) best)
          ((not level) (loop (cdr es) (car (car es))))
          ((< (morg-info (car es)) level) (loop (cdr es) #f))
          ((equal? (morg-info (car es)) level) (loop (cdr es) (car (car es))))
          (else (loop (cdr es) best)))))

(define (morg--level-here buf pos)
  (let ((h (morg-enclosing-heading (morg-scan buf) pos)))
    (and h (morg-info h))))

(define (morg--link-positions buf)
  (apply append
    (map (lambda (e)
           (let ((start (car e)) (line (cadr e)))
             (map (lambda (r) (+ start (car r)))
                  (re-find* morg--link-pattern line))))
         (morg-lines buf))))

(define (morg--first-after ps pos)
  (let loop ((ps ps))
    (cond ((null? ps) #f)
          ((> (car ps) pos) (car ps))
          (else (loop (cdr ps))))))

(define (morg--last-before ps pos)
  (let loop ((ps ps) (best #f))
    (cond ((null? ps) best)
          ((< (car ps) pos) (loop (cdr ps) (car ps)))
          (else best))))

;; What the reader means by "this": the code inside the fences when point
;; is in a block, else the whole section under its heading. The fences stay
;; out of the region, so the selection is the code itself.
(define (morg--block-bounds buf pos)
  (let* ((scan (morg-scan buf))
         (open (morg-block-open scan pos)))
    (and open (morg-block-body scan buf open))))

(define (morg--section-bounds buf pos)
  (let* ((scan (morg-scan buf))
         (h (morg-enclosing-heading scan pos)))
    (and h (list (car h) (morg-heading-body-end scan buf (car h))))))

(define-command "morg-select-block"
  "Select the code block at point, else the whole section"
  (lambda ()
    (let* ((buf (current-buffer))
           (b (or (morg--block-bounds buf (point))
                  (morg--section-bounds buf (point)))))
      (if b
          (begin (set-mark! (car b)) (goto-char! (cadr b)) b)
          (begin (message "No block or section here") #f)))))

;; The interesting places in a note: every heading, every paragraph, every
;; fenced block whatever its language, and every link. One key walks them
;; all, so a reader who does not know what lies above point still lands
;; somewhere worth reading. Each list is already in document order, so the
;; merge keeps them there and one position lands once.
(define (morg--merge a b)
  (cond ((null? a) b)
        ((null? b) a)
        ((< (car a) (car b)) (cons (car a) (morg--merge (cdr a) b)))
        ((> (car a) (car b)) (cons (car b) (morg--merge a (cdr b))))
        (else (cons (car a) (morg--merge (cdr a) (cdr b))))))

(define (morg--blank-line? line) (and (re-match "^[ \t]*$" line) #t))

;; A paragraph starts at a line with text on it that follows nothing, a
;; blank line, a heading, or a closing fence.
(define (morg--paragraph-starts scan)
  (let loop ((es scan) (prev #f) (acc '()))
    (if (null? es)
        (reverse acc)
        (let* ((e (car es))
               (start?
                 (and (equal? (morg-kind e) 'text)
                      (not (morg--blank-line? (cadr e)))
                      (or (not prev)
                          (member (morg-kind prev) '(heading close))
                          (and (equal? (morg-kind prev) 'text)
                               (morg--blank-line? (cadr prev)))))))
          (loop (cdr es) e (if start? (cons (car e) acc) acc))))))

(define (morg--landmarks buf)
  (let ((scan (morg-scan buf)))
    (morg--merge
      (morg--merge
        (map car
             (filter (lambda (e) (member (morg-kind e) '(heading open))) scan))
        (morg--paragraph-starts scan))
      (morg--link-positions buf))))

(define-command "morg-next-heading"
  "Move to the next heading"
  (lambda ()
    (morg--land! (morg--heading-after (current-buffer) (point) #f)
                 "next heading")))

(define-command "morg-previous-heading"
  "Move to the previous heading"
  (lambda ()
    (morg--land! (morg--heading-before (current-buffer) (point) #f)
                 "previous heading")))

(define-command "morg-forward-same-level"
  "Move to the next heading at this level"
  (lambda ()
    (let* ((buf (current-buffer))
           (level (morg--level-here buf (point))))
      (morg--land! (and level (morg--heading-after buf (point) level))
                   "next heading at this level"))))

(define-command "morg-backward-same-level"
  "Move to the previous heading at this level"
  (lambda ()
    (let* ((buf (current-buffer))
           (level (morg--level-here buf (point))))
      (morg--land! (and level (morg--heading-before buf (point) level))
                   "previous heading at this level"))))

(define-command "morg-next-link"
  "Move to the next link"
  (lambda ()
    (morg--land! (morg--first-after (morg--link-positions (current-buffer))
                                    (point))
                 "next link")))

(define-command "morg-previous-link"
  "Move to the previous link"
  (lambda ()
    (morg--land! (morg--last-before (morg--link-positions (current-buffer))
                                    (point))
                 "previous link")))

(define-command "morg-next-landmark"
  "Move down to the next heading, block or link"
  (lambda ()
    (morg--land! (morg--first-after (morg--landmarks (current-buffer)) (point))
                 "next landmark")))

(define-command "morg-previous-landmark"
  "Move up to the previous heading, block or link"
  (lambda ()
    (morg--land! (morg--last-before (morg--landmarks (current-buffer)) (point))
                 "previous landmark")))

(define (morg-install-keys)
  (local-set-key "TAB" "morg-cycle")
  (local-set-key "S-TAB" "morg-global-cycle")
  (local-set-key "C-c C-t" "morg-todo")
  ;; motion, org's own spelling: C-n/C-p walk every heading, C-f/C-b walk
  ;; the siblings. Links take M-n and M-p, because C-c C-x is the tangler.
  (local-set-key "C-c C-n" "morg-next-heading")
  (local-set-key "C-c C-p" "morg-previous-heading")
  (local-set-key "C-c C-f" "morg-forward-same-level")
  (local-set-key "C-c C-b" "morg-backward-same-level")
  ;; M-<up> and M-<down> shadow the global scroll-other-window pair here,
  ;; the way org-mode shadows them for subtree motion. In a note, moving is
  ;; what the reader wants from that key.
  (local-set-key "M-<up>" "morg-previous-landmark")
  (local-set-key "M-<down>" "morg-next-landmark")
  (local-set-key "C-c SPC" "morg-select-block")
  (local-set-key "M-n" "morg-next-link")
  (local-set-key "M-p" "morg-previous-link")
  (local-set-key "C-c C-c" "morg-babel")
  (local-set-key "C-c C-x" "morg-tangle")
  ;; The core chords keep their meaning while the mode supplies its own
  ;; structural unit: heading instead of an arbitrary marked region.
  (local-set-key "C-x n n" "morg-narrow")
  (local-set-key "C-x n w" "morg-widen")
  ;; prose names many definitions: look first, go on the second press
  (local-set-key "M-." "definition-peek"))

;; The reactor binds a rule to one buffer process. A killed and recreated
;; buffer has a new reference, so mode setup replaces the old rule.
(define *morg-hooks* '())

(define (morg-ensure-hook! buf)
  (let ((old (assoc buf *morg-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *morg-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (morg-after-change buf pos inserted deleted source))
                    'eager))
            (remove (lambda (entry) (equal? (car entry) buf))
                    *morg-hooks*)))))

(mode-doc! "morg-mode"
  "Markdown with org habits. `TAB` folds a heading or code block. `C-x n n` shows one heading, and `C-x n w` widens. Narrowing gives chat an outline hint, not document text. `C-c C-c` runs a block. `C-c C-x` tangles marked blocks. `C-c C-v` renders the page.")

(mode-icon! "morg-mode" "")

(define-mode "morg-mode"
  (lambda ()
    ;; Morg owns structure and the plain faces. The prose presentation is
    ;; writing-mode's; preview-mode draws the page in place.
    (when (boundp 'preview-heal!) (preview-heal! (current-buffer)))
    (enable-minor-mode! (current-buffer) "writing-mode")
    (morg-install-keys)
    (morg-ensure-hook! (current-buffer))
    ;; Hidden ranges die with the daemon; the 'morg-folds local survives.
    ;; Re-derive them here, or a restored buffer comes back unfolded.
    (morg-apply-folds! (current-buffer))
    (morg-apply-narrow! (current-buffer))
    (morg-refontify! (current-buffer))))

(register-context-provider! "morg-mode"
  (lambda (buf)
    (let* ((anchor (morg-narrow-anchor buf))
           (entry (and anchor (morg-entry-at (morg-scan buf) anchor))))
      (and entry
           (string-append
             "Morg buffer \"" buf "\" is visually narrowed to \""
             (markdown--title entry) "\" at line "
             (number->string
               (length (string-split
                         (substring-bytes (buffer-text buf) 0 anchor) "\n")))
             ". No document text is attached. Call (markdown-outline \""
             buf "\"), then call (markdown-read \"" buf
             "\" LINE) for relevant sections.")))))
