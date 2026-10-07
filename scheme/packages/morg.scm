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

;; the morg block kinds come first
(require 'morg-kinds "morg/morg-kinds.scm")

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

;; The scan, from the grammar. Tree-sitter parses the document — it
;; already knows a # inside a fence is not a heading — and every line is
;; classified from its tree: the blocks from block--ts-list, the headings
;; from their markers. The Markdown grammars are built into the NIF, so
;; this is the only scan. Directives are our own syntax, which markdown
;; reads as a paragraph, so their line regex stays.
(define morg--heading-query
  "(atx_h1_marker) @1 (atx_h2_marker) @2 (atx_h3_marker) @3 (atx_h4_marker) @4 (atx_h5_marker) @5 (atx_h6_marker) @6")

;; heading captures -> ((START LEVEL) ...). A recursion, not map over a
;; lambda: a lambda handed to a primitive publishes the frames it closes
;; over, and this frame holds the document.
(define (morg--heads hits acc)
  (if (null? hits)
      (reverse acc)
      (morg--heads (cdr hits)
                   (cons (list (car (cdr (car hits))) (string->number (car (car hits)))) acc))))

;; HITS, when given, are the captures of block--query and of the heading
;; query, from a parse the caller shares.
;; No frame here binds the document text: a long string in a live frame
;; makes every later step of the scan slower.
(define (morg-scan--ts buf &optional hits)
  (morg--scan-hits buf (or hits (ts-query-string "markdown" (buffer-text buf)
                                                  (list block--query morg--heading-query)))))

(define (morg--scan-hits buf hits)
  (morg--scan-lines (morg-lines buf)
                    (block--ts-list (buffer-text buf) (car hits))
                    (morg--heads (cadr hits) '())
                    '()))

;; The scan runs on every edit, over every line. Each step is a top-level
;; procedure with few bindings: a variable lookup walks every frame
;; between it and the global one.
(define (morg--scan-lines ls bs heads acc)
  (if (null? ls)
      (reverse acc)
      (morg--scan-step ls (morg--drop-blocks bs (car (car ls))) heads acc)))

(define (morg--scan-step ls bs heads acc)
  (morg--scan-lines (cdr ls) bs heads
                    (cons (morg--scan-entry (car (car ls)) (car (cdr (car ls))) bs heads)
                          acc)))

;; the blocks that do not end before START
(define (morg--drop-blocks bs start)
  (if (and (pair? bs) (< (car (cdr (car bs))) start))
      (morg--drop-blocks (cdr bs) start)
      bs))

(define (morg--scan-entry start line bs heads)
  (let ((b (and (pair? bs) (<= (car (car bs)) start) (car bs)))
        (head (assoc start heads)))
    (cond
      ((and b (= start (car b)))
       (list start line 'open (block-lang b)))
      ((and b (morg-fence-close? line)
            (<= (car (cdr b)) (+ start (string-byte-length line))))
       (list start line 'close #f))
      (b (list start line 'code (block-lang b)))
      (head (list start line 'heading (car (cdr head))))
      ((morg-directive-info line)
       (list start line 'directive (morg-directive-info line)))
      (else (list start line 'text #f)))))

(define (morg-scan buf) (morg-scan--ts buf))

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
  (when (boundp (quote llm-context-clear!)) (llm-context-clear! buf))
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

;;; A checkbox item is a line whose first content, after an optional list
;;; bullet at any depth, is a marker in brackets: "[ ]" is open, "[@]" is
;;; in progress, "[x]" is done, and "[@:NAME]" is in progress with the
;;; person who has it. Any other single character is a status of the
;;; writer's own: it is displayed, and the cycle leaves it alone.

(define morg--checkbox-pattern "^[ \t]*(?:[-*+][ \t]+)?[[]([^]\n]+)[]]")

;; A marker is one character, or "@:" and a name. Anything longer is
;; prose: "[see below] ..." opens no task.
(define (morg-checkbox-marker? m)
  (or (= (string-length m) 1)
      (and (string-prefix? "@:" m) (> (string-byte-length m) 2))))

;; the person a "[@:NAME]" marker hands the item to, or #f
(define (morg-checkbox-name marker)
  (and (string-prefix? "@:" marker)
       (let ((n (substring-bytes marker 2 (string-byte-length marker))))
         (and (not (equal? n "")) n))))

;; "[@]" and "[@:NAME]" are one state: in progress
(define (morg-checkbox-doing? marker)
  (and (or (equal? marker "@") (morg-checkbox-name marker)) #t))

;; -> (OPEN MARKER CLOSE TEXT-START) in bytes, else #f. The marker must be
;; followed by a space or the line end, so "[a](url)" stays a link.
(define (morg-checkbox-at line)
  (let ((g (re-groups morg--checkbox-pattern line 0)))
    (and g
         (let* ((r (nth 1 g))
                (len (string-byte-length line))
                (close (cadr r))
                (marker (substring-bytes line (car r) close))
                (space? (lambda (i)
                          (and (< i len)
                               (member (substring-bytes line i (+ i 1))
                                       '(" " "\t"))
                               #t))))
           (and (morg-checkbox-marker? marker)
                (or (= (+ close 1) len) (space? (+ close 1)))
                (list (- (car r) 1)
                      marker
                      close
                      (let skip ((i (+ close 1)))
                        (if (space? i) (skip (+ i 1)) i))))))))

;; the marker the cycle moves to, or #f for a freeform status. Cycling
;; INTO doing gives a plain "@": a name is the user's to type, never the
;; toggle's to invent.
(define (morg-checkbox-next marker)
  (cond ((equal? marker " ") "@")
        ((morg-checkbox-doing? marker) "x")
        ((equal? marker "x") " ")
        (else #f)))

;; the state a marker names
(define (morg-checkbox-state marker)
  (cond ((equal? marker " ") "TODO")
        ((morg-checkbox-doing? marker) "DOING")
        ((equal? marker "x") "DONE")
        (else #f)))

;; (MARKER-FACE TEXT-FACE) — a freeform status reads as metadata, and the
;; text beside it stays plain prose
(define (morg-checkbox-faces marker)
  (cond ((equal? marker " ") '("morg-task-open" "morg-task-open-text"))
        ((morg-checkbox-doing? marker) '("morg-task-doing" "morg-task-doing-text"))
        ((equal? marker "x") '("morg-task-done" "morg-task-done-text"))
        (else '("org-meta" #f))))

(define (morg--todo-line! buf start line new)
  (morg-replace-line! buf start line new)
  (when (equal? (buffer-local buf 'mode-name) "morg-mode")
    (morg-refontify! buf)))

;; the heading cycle: none, TODO, DONE
(define (morg--cycle-heading! buf e)
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
    (morg--todo-line! buf start line new)
    next))

;; the checkbox cycle: [ ], [@], [x]. The indentation and the bullet are
;; the line's own, so only the one marker character is rewritten.
(define (morg--cycle-checkbox! buf e)
  (let* ((start (car e))
         (line (cadr e))
         (box (morg-checkbox-at line)))
    (cond
      ((not box) #f)
      ((not (morg-checkbox-next (cadr box))) 'freeform)
      (else
        (let* ((next (morg-checkbox-next (cadr box)))
               (new (string-append (substring-bytes line 0 (+ (car box) 1))
                                   next
                                   (substring-bytes line (caddr box)
                                                    (string-byte-length line)))))
          (morg--todo-line! buf start line new)
          (morg-checkbox-state next))))))

;; Cycle the heading at POS through none, TODO and DONE, or the checkbox
;; item at POS through open, in progress and done. Return the new state
;; string, 'freeform when the marker is the writer's own, or #f when POS
;; is on neither.
(define (morg-toggle-todo-at! buf pos)
  (let ((e (morg-entry-at (morg-scan buf) pos)))
    (cond ((not e) #f)
          ((equal? (morg-kind e) 'heading) (morg--cycle-heading! buf e))
          ((equal? (morg-kind e) 'text) (morg--cycle-checkbox! buf e))
          (else #f))))

(define-command "morg-todo" "Cycle the TODO state of the heading or checkbox at point"
  (lambda ()
    (let ((state (morg-toggle-todo-at! (current-buffer) (point))))
      (cond ((equal? state 'freeform)
             (message "Freeform checkbox status — left alone"))
            ((equal? state "NONE") (message "TODO state cleared"))
            (state (message state))
            (else (message "Point is not on a heading or a checkbox"))))))

;;; --- fontification -----------------------------------------------------------

(defface! 'morg-code
  'fg "#3d6b4f"
  'family "'IBM Plex Mono',ui-monospace,Menlo,monospace")
(defface! 'morg-bold 'weight "700")
(defface! 'morg-italic 'style "italic")
(defface! 'morg-result 'fg "#8a857a");; Each checkbox state carries its own marker face and its own text face,
;; so open, in progress and done read apart at a glance. The colours are
;; morg's own defaults; a theme that names these faces wins over them.
(defface! 'morg-task-open 'fg "#a03020" 'weight "700")
(defface! 'morg-task-open-text 'weight "500")
(defface! 'morg-task-doing 'fg "#7a5a1a" 'weight "700")
(defface! 'morg-task-doing-text 'fg "#7a5a1a" 'style "italic")
(defface! 'morg-task-done 'fg "#3d6b4f" 'weight "700")
(defface! 'morg-task-done-text 'fg "#8a857a" 'decoration "line-through")

;; markdown info string -> loaded tree-sitter language, or #f.
;; The fence-kind registry (morg-kinds.scm) owns the mapping.
(define (morg-ts-lang lang) (fence-kind-ts-lang lang))

;;; --- markup, from the grammar ----------------------------------------------
;;; The block grammar names the list, quote and rule markers, and the ranges
;;; of inline text. The inline grammar reads every inline range in one call.
;;; The answer is one list of (KIND START END) in document bytes, sorted by
;;; START. Both painters read it, so no painter matches markup by regex.
;;;
;;; The painters run on every edit of a long document, so the hot loops
;;; below call car and cdr, which are primitives, and few procedures.

;; A continuation is the indent a block carries onto its next line; it is
;; a quote marker when it holds a >.
(define morg--block-markup-query
  "(list_marker_minus) @bullet (list_marker_star) @bullet (list_marker_plus) @bullet (list_marker_dot) @ordered (list_marker_parenthesis) @ordered (block_quote_marker) @quote ((block_continuation) @quote (#match? @quote \">\")) (thematic_break) @rule (setext_h2_underline) @rule (inline) @inline (pipe_table_cell) @inline (indented_code_block) @icode")

(define morg--inline-markup-query
  "(code_span) @code (strong_emphasis) @strong (emphasis) @emphasis (inline_link) @link (link_text) @link-text (link_destination) @link-destination (image) @image")

;; two capture lists, each sorted by START, as one sorted list
(define (morg--merge-captures a b acc)
  (cond ((null? a) (append (reverse acc) b))
        ((null? b) (append (reverse acc) a))
        ((<= (car (cdr (car a))) (car (cdr (car b))))
         (morg--merge-captures (cdr a) b (cons (car a) acc)))
        (else (morg--merge-captures a (cdr b) (cons (car b) acc)))))

(define (morg--inline-capture? c) (equal? (car c) "inline"))

(define (morg-markup text &optional blocks)
  (let* ((blocks (or blocks (ts-query-string "markdown" text morg--block-markup-query)))
         (ranges (map cdr (filter morg--inline-capture? blocks)))
         (inlines (ts-query-ranges "markdown-inline" text ranges
                                   morg--inline-markup-query)))
    (morg--merge-captures (remove morg--inline-capture? blocks) inlines '())))

;; -> (SCAN MARKUP) for BUF, from one parse of its text
(define (morg-scan-markup buf)
  (morg--scan-markup-hits buf
    (ts-query-string "markdown" (buffer-text buf)
      (list block--query morg--heading-query morg--block-markup-query))))

(define (morg--scan-markup-hits buf hits)
  (list (morg--scan-hits buf hits)
        (morg-markup (buffer-text buf) (car (cdr (cdr hits))))))

;; -> (LINE-CAPTURES . REST): the captures that start at or before byte END
(define (morg--take-line caps end acc)
  (if (and (pair? caps) (<= (car (cdr (car caps))) end))
      (morg--take-line (cdr caps) end (cons (car caps) acc))
      (cons (reverse acc) caps)))

;; the first capture of KIND in CAPS that lies inside START..END, or #f
(define (morg-markup-find caps kind start end)
  (cond ((null? caps) #f)
        ((and (equal? (car (car caps)) kind)
              (>= (car (cdr (car caps))) start)
              (<= (car (cdr (cdr (car caps)))) end))
         (car caps))
        (else (morg-markup-find (cdr caps) kind start end))))

;; Run FN over every scan entry with the captures that start on its line.
;; FN is (FN ENTRY LINE-CAPS PREV-ENTRY PREV-CAPS FENCE-ARGS) -> spans. The
;; fence args reach a body line from its open fence. The spans come back in
;; one list, in scan order.
(define (morg-markup-spans scan caps fn)
  (morg--markup-walk scan caps fn #f '() #f '()))

;; The walk runs on every edit, over every line. Each step is a top-level
;; procedure with one frame: a variable lookup walks every frame between
;; it and the global one.
(define (morg--markup-walk es caps fn prev prev-caps args acc)
  (if (null? es)
      (apply append (reverse acc))
      (morg--markup-line es (car es) caps fn prev prev-caps
                         (morg--fence-args-at (car es) args) acc)))

(define (morg--markup-line es e caps fn prev prev-caps args acc)
  (let ((split (morg--take-line caps (+ (car e) (string-byte-length (car (cdr e)))) '())))
    (morg--markup-walk (cdr es) (cdr split) fn e (car split) args
                       (cons (fn e (car split) prev prev-caps
                                 (and (equal? (car (cdr (cdr e))) 'code) args))
                             acc))))

;; the fence arguments a line carries on: its own on an open fence, the
;; open fence's ARGS on a body line, else #f
(define (morg--fence-args-at e args)
  (let ((k (car (cdr (cdr e)))))
    (cond ((equal? k 'code) args)
          ((equal? k 'open) (morg-fence-args (car (cdr e))))
          (else #f))))

;; the byte where a heading's words start: after the LEVEL marks the
;; grammar counted, and the blanks after them
(define (morg-heading-text-start line level)
  (morg--skip-blanks line level (string-byte-length line)))

(define (morg--skip-blanks line i len)
  (if (and (< i len) (member (substring-bytes line i (+ i 1)) '(" " "\t")))
      (morg--skip-blanks line (+ i 1) len)
      i))

;; The source view's inline faces: the construct and its markers wear one
;; face, so every marker stays visible. A capture that starts inside a
;; SKIP range, (START END) sorted, keeps no face.
(define morg--source-faces
  '(("code" "morg-code") ("strong" "morg-bold") ("emphasis" "morg-italic")
    ("link" "link")))

(define (morg--source-markup caps skip acc)
  (cond ((null? caps) (reverse acc))
        ((and (pair? skip) (> (car (cdr (car caps))) (car (cdr (car skip)))))
         (morg--source-markup caps (cdr skip) acc))
        ((and (pair? skip) (>= (car (cdr (car caps))) (car (car skip))))
         (morg--source-markup (cdr caps) skip acc))
        (else
         (let ((f (assoc (car (car caps)) morg--source-faces)))
           (morg--source-markup (cdr caps) skip
             (if f
                 (cons (list (car (cdr (car caps))) (car (cdr (cdr (car caps)))) (car (cdr f))) acc)
                 acc))))))

;; a heading's TODO or DONE keyword at TEXT-START: (KEYWORD START END), or #f
(define (morg-heading-keyword line text-start)
  (let ((len (string-byte-length line)))
    (cond ((< (- len text-start) 4) #f)
          ((not (member (substring-bytes line text-start (+ text-start 4)) '("TODO" "DONE"))) #f)
          ((or (= (+ text-start 4) len)
               (member (substring-bytes line (+ text-start 4) (+ text-start 5)) '(" " "\t")))
           (list (substring-bytes line text-start (+ text-start 4))
                 text-start (+ text-start 4)))
          (else #f))))

;; spans for one scan entry; block BODIES are highlighted per block in
;; morg-refontify!, because a multi-line construct needs the whole body,
;; and the inline markup comes from the grammar in one pass
;; (morg--source-markup). BOX is the line's checkbox, or #f.
;; This is the plain source view: every marker stays visible. preview-mode
;; draws the page in place, and its painter replaces this when it is on.
(define (morg-line-spans e fence-args box)
  (let* ((start (car e)) (line (car (cdr e))) (k (car (cdr (cdr e))))
         (len (string-byte-length line)))
    (cond
      ((= len 0) '())
      ((equal? k 'heading)
       (let* ((face (string-append "org-level-"
                      (number->string (+ 1 (modulo (- (morg-info e) 1) 4)))))
              (kw (morg-heading-keyword line (morg-heading-text-start line (morg-info e)))))
         (if (not kw)
             (list (list start (+ start len) face))
             (let ((ks (+ start (nth 1 kw)))
                   (ke (+ start (nth 2 kw))))
               (append
                 (if (> ks start) (list (list start ks face)) '())
                 (list (list ks ke (if (equal? (car kw) "TODO")
                                       "org-todo" "org-done")))
                 (if (< ke (+ start len))
                     (list (list ke (+ start len) face))
                     '()))))))
      ;; the open fence is the block's header: a kind that declares a
      ;; fence-face colors it apart from the plain markers
      ;; row-morg-fence draws both fence lines in small type
      ((equal? k 'open)
       (list (list start (+ start len)
                   (or (fence-kind-get (morg-info e) 'fence-face #f)
                       "org-meta"))
             (list start (+ start len) "row-morg-fence")))
      ((equal? k 'close)
       (list (list start (+ start len) "org-meta")
             (list start (+ start len) "row-morg-fence")))
      ((equal? k 'directive) (list (list start (+ start len) "org-meta")))
      ((equal? k 'code)
       (let ((f (fence-kind-line-face (morg-info e) line fence-args)))
         (if f (list (list start (+ start len) f)) '())))
      ;; a checkbox line: the marker takes its state's face and the text
      ;; after it takes the state's text face. Like a heading's keyword,
      ;; these spans REPLACE rather than stack: morg-refontify! paints no
      ;; inline markup over the item's own state.
      (box
       (let* ((open (car box))
              (close (caddr box))
              (text-start (nth 3 box))
              (faces (morg-checkbox-faces (cadr box))))
         (append
           (if (> open 0) (list (list start (+ start open) "org-meta")) '())
           (list (list (+ start open) (+ start close 1) (car faces)))
           (if (and (cadr faces) (< text-start len))
               (list (list (+ start text-start) (+ start len) (cadr faces)))
               '()))))
      (else '()))))

(define (morg-refontify! buf)
  ;; preview-mode's painter (drawn in place) has its own hook when it is on
  (when (and (buffer-exists? buf)
             (not (equal? (buffer-local buf 'markdown-paint) #t)))
    (let* ((both (morg-scan-markup buf))
           (scan (car both))
           ;; each body line sees its open fence's arguments, so a kind
           ;; can paint by them (a live diff's one-sided views stay prose)
           (r (morg--source-walk scan #f '() '()))
           (markup (morg--source-markup (cadr both) (cadr r) '()))
           (block-spans (fence-kind-body-spans (buffer-text buf) (morg-blocks scan buf))))
      (overlay-set! buf 'morg (append (car r) markup block-spans)))))

;; -> (SPANS CHECKBOX-LINES): the line spans of the scan ES, and the
;; (START END) of every checkbox line, where no inline markup paints
(define (morg--source-walk es args boxes acc)
  (if (null? es)
      (list (apply append (reverse acc)) (reverse boxes))
      (morg--source-line es (car es) (morg--fence-args-at (car es) args) boxes acc)))

(define (morg--source-line es e args boxes acc)
  (let ((box (and (equal? (car (cdr (cdr e))) 'text) (morg-checkbox-at (car (cdr e))))))
    (morg--source-walk
      (cdr es) args
      (if box
          (cons (list (car e) (+ (car e) (string-byte-length (car (cdr e))))) boxes)
          boxes)
      (cons (morg-line-spans e (and (equal? (car (cdr (cdr e))) 'code) args) box) acc))))

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
    (morg-refontify! buf)
    (morg-arm-block-keys! buf)))

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

;; the links in the prose. A link inside a fenced block is code, not an
;; anchor: in the page a block is one place to land, and M-<up> must not
;; step into its body.
(define (morg--link-positions buf)
  (apply append
    (map (lambda (e)
           (let ((start (car e)) (line (cadr e)))
             (map (lambda (r) (+ start (car r)))
                  (re-find* morg--link-pattern line))))
         (filter (lambda (e) (equal? (morg-kind e) 'text)) (morg-scan buf)))))

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

;; The anchors of a note: every heading at any level, every paragraph,
;; every fenced block whatever its language, and every link. One key
;; walks them all, so a reader who does not know what lies above point
;; still lands somewhere worth reading. Each list is already in document
;; order, so the merge keeps them there and one position lands once.
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

;; A page is what the reader sees. An anchor farther away than one page
;; is a leap over text nobody read, so the key pages there instead, and
;; the next press finds the anchor from the new place. With no anchor in
;; that direction the key still pages while a page of text remains.
(define (morg--page-lines) (max 1 (- (window-rows) 2)))

(define (morg--lines-between a b)
  (abs (- (line-number-at-pos a) (line-number-at-pos b))))

(define (morg--landmark-step! dir what)
  (let* ((buf (current-buffer))
         (pos (point))
         (marks (morg--landmarks buf))
         (target (if (> dir 0)
                     (morg--first-after marks pos)
                     (morg--last-before marks pos)))
         (edge (if (> dir 0) (buffer-size buf) 0))
         (page (morg--page-lines)))
    (cond ((and target (<= (morg--lines-between pos target) page))
           (goto-char! target)
           target)
          ((> (morg--lines-between pos edge) page)
           (visual-page! dir)
           (point))
          (else (morg--land! target what)))))

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
  "Move down to the next heading, paragraph, block or link, or one page when none is that near"
  (lambda () (morg--landmark-step! 1 "next landmark")))

(define-command "morg-previous-landmark"
  "Move up to the previous heading, paragraph, block or link, or one page when none is that near"
  (lambda () (morg--landmark-step! -1 "previous landmark")))

(define-command "morg-newline"
  "Close a freshly typed fence, or insert the newline RET means here"
  (lambda ()
    (if (block-electric-close!)
        #t
        (run-command "preview-newline"))))

(define (morg-install-keys buf)
  
  ;; motion, org's own spelling: C-n/C-p walk every heading, C-f/C-b walk
  ;; the siblings. Links take M-n and M-p, because C-c C-x is the tangler.
  
  ;; M-<up> and M-<down> shadow the global scroll-other-window pair here,
  ;; the way org-mode shadows them for subtree motion. In a note, moving is
  ;; what the reader wants from that key.
  
  ;; The core chords keep their meaning while the mode supplies its own
  ;; structural unit: heading instead of an arbitrary marked region.
  ;; prose names many definitions: look first, go on the second press
  #t)

;; The reactor binds a rule to one buffer process. A killed and recreated
;; buffer has a new reference, so mode setup replaces the old rule.
(define *morg-hooks* '())

(define (morg-ensure-hook! buf)
  (let ((old (assoc buf *morg-hooks*)))
    (when old (remove-on-change! (cadr old)))
    (set! *morg-hooks* (alist-put *morg-hooks* buf (on-change! buf
                    (lambda (pos inserted deleted source)
                      (morg-after-change buf pos inserted deleted source))
                    'eager)))))

(mode-doc! "morg-mode"
  "Markdown with org habits. `TAB` folds a heading or code block. `C-x n n` shows one heading, and `C-x n w` widens. Narrowing gives chat an outline hint, not document text. `C-c C-c` runs a block, or fills a `:show-source PATH::NAME` block from its file. `C-c C-x` tangles marked blocks. `C-c C-v` renders the page. A ```table fence colors its cells by rules on the fence: `green=strong,1.00` matches a value, and `red<.4` or `green>=.7` match a number. The first rule that matches wins. Colors: red, green, yellow, blue, purple, cyan, gray.")

(mode-icon! "morg-mode" "")

;; A block's keys are its kind's keymap, in force while point is inside
;; the block: the keymap at point, ahead of the buffer's own map. It is
;; set after every command, so it follows point; a buffer with no block
;; at point has none.
(define (morg-point-map! buf)
  (let* ((b (and (buffer-exists? buf) (block-at buf (point))))
         (map (and b (fence-kind-keymap (block-lang b)))))
    (unless (equal? map (buffer-at-point-map buf))
      (buffer-at-point-map! buf map))))

(define (morg--post-command-point-map!)
  (let ((buf (current-buffer)))
    (when (buffer-derived-mode? buf "morg-mode") (morg-point-map! buf))))

(add-hook! 'post-command-hook 'morg--post-command-point-map!)

;; the older name: the keys are the keymap at point now
(define (morg-arm-block-keys! buf) (morg-point-map! buf))

(define-mode "morg-mode"
  (lambda ()
    ;; Morg owns structure and the plain faces. It wraps prose at words and
    ;; turns on no presentation: writing-mode and preview-mode are the
    ;; user's to turn on.
    (preview-heal! (current-buffer))
    (enable-minor-mode! (current-buffer) "visual-line-mode")
    (morg-install-keys (current-buffer))
    (morg-arm-block-keys! (current-buffer))
    (morg-ensure-hook! (current-buffer))
    ;; Hidden ranges die with the daemon; the 'morg-folds local survives.
    ;; Re-derive them here, or a restored buffer comes back unfolded.
    (morg-apply-folds! (current-buffer))
    (morg-apply-narrow! (current-buffer))
    (morg-refontify! (current-buffer))))

(mode-keys! "morg-mode"
  '(
    ("RET" "morg-newline")
    ("TAB" "morg-cycle")
    ("S-TAB" "morg-global-cycle")
    ("C-c C-t" "morg-todo")
    ("C-c C-n" "morg-next-heading")
    ("C-c C-p" "morg-previous-heading")
    ("C-c C-f" "morg-forward-same-level")
    ("C-c C-b" "morg-backward-same-level")
    ("M-<up>" "morg-previous-landmark")
    ("M-<down>" "morg-next-landmark")
    ("C-c SPC" "morg-select-block")
    ("M-n" "morg-next-link")
    ("M-p" "morg-previous-link")
    ("C-c C-c" "morg-babel")
    ("C-c C-x" "morg-tangle")
    ("C-x n n" "morg-narrow")
    ("C-x n N" "narrow-context-also")
    ("C-x n w" "morg-widen")
    ("M-." "definition-peek")))

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
