;;; anchor.scm --- go from anchor to anchor, and each anchor carries its keys.
;;;
;;; A page that is not a table still has parts. An application has a
;;; header, a tab row, an assessment, a candidate, a job. Point moving a
;;; character at a time says nothing about which part it is in, and a list
;;; mode is the wrong shape for a page whose parts are not rows.
;;;
;;; An anchor is a named byte range in a buffer. A page declares its
;;; anchors with anchor-set!, TAB and S-TAB walk them, and the anchor at
;;; point puts its OWN keymap in front of the buffer's maps. That is
;;; buffer-at-point-map!, the same mechanism a morg block already uses to
;;; give a fence its language's keys. So `o` can mean open the candidate
;;; inside the candidate anchor and open the job inside the job anchor,
;;; with no dispatch written by hand: the keymap is the dispatch.
;;;
;;; An anchor is declared against the text as it stands, not against a
;;; marker. A page that redraws declares them again, and anchor-set! is
;;; the whole of that update. anchor-goto! by name is how a redraw puts
;;; point back where it was.
;;;
;;;   (define-keymap! "app-candidate-map")
;;;   (define-key "app-candidate-map" "RET" "app-open-candidate")
;;;   (anchor-set! buf `(("header" 1 ,tabs-at)
;;;                      ("candidate" ,tabs-at ,end "app-candidate-map")))
;;;   (enable-minor-mode! buf "anchor-mode")

(domain! 'navigation)
(effects! '(read))

;;; --- the record ------------------------------------------------------------

;; (NAME START END KEYMAP DATA LEVELS). NAME is the handle a redraw comes
;; back to, START and END are byte offsets with END exclusive, KEYMAP is the
;; map in force while point is inside, DATA is the page's own, and LEVELS
;; is how the part zooms, ((N REDUCTION) ...), which content-scale reads.
(define (anchor--norm a)
  (let ((n (length a)))
    (list (list-ref a 0)
          (list-ref a 1)
          (list-ref a 2)
          (and (> n 3) (list-ref a 3))
          (and (> n 4) (list-ref a 4))
          (and (> n 5) (list-ref a 5)))))

(define (anchor-name a) (list-ref a 0))
(define (anchor-start a) (list-ref a 1))
(define (anchor-end a) (list-ref a 2))
(define (anchor-keymap a) (list-ref a 3))
(define (anchor-data a) (list-ref a 4))
(define (anchor-levels a) (and (> (length a) 5) (list-ref a 5)))

(define (anchor-list buf)
  (or (and (buffer-known? buf) (buffer-local buf 'anchors)) '()))

;; The innermost anchor holding POS: of the ones that contain it, the one
;; that starts last. Nesting is allowed and the inner keymap wins.
(define (anchor-at buf pos)
  (fold (lambda (best a)
          (if (and (<= (anchor-start a) pos)
                   (< pos (anchor-end a))
                   (or (not best) (>= (anchor-start a) (anchor-start best))))
              a
              best))
        #f
        (anchor-list buf)))

(define (anchor-find buf name)
  (let loop ((as (anchor-list buf)))
    (cond ((null? as) #f)
          ((equal? (anchor-name (car as)) name) (car as))
          (else (loop (cdr as))))))

(define (anchor--after buf pos)
  (let loop ((as (anchor-list buf)))
    (cond ((null? as) #f)
          ((> (anchor-start (car as)) pos) (car as))
          (else (loop (cdr as))))))

;; the list is sorted, so the last one that starts before POS is the one
(define (anchor--before buf pos)
  (fold (lambda (best a) (if (< (anchor-start a) pos) a best))
        #f
        (anchor-list buf)))

;; A page drawn as blocks names its own stops: a block with an anchor-name
;; and the lines it covers is one, with its anchor-keymap and anchor-data.
;; The answer is (NAME FIRST-LINE LAST-LINE [KEYMAP DATA]), in page order.
(effects! '(pure))

(define (anchor-blocks blocks)
  (let walk ((bs blocks) (acc '()))
    (if (null? bs) acc
        (let* ((blk (car bs))
               (acc (if (and (pair? blk) (plist-get blk 'anchor-name) (plist-get blk 'lines))
                        (append acc (list (append (cons (plist-get blk 'anchor-name) (plist-get blk 'lines))
                                                  (if (or (plist-get blk 'anchor-keymap) (plist-get blk 'anchor-data))
                                                      (list (plist-get blk 'anchor-keymap) (plist-get blk 'anchor-data))
                                                      '()))))
                        acc)))
          (walk (cdr bs) (if (pair? blk) (walk (or (plist-get blk 'children) '()) acc) acc))))))

(effects! '(write))

;;; --- declaring -------------------------------------------------------------

(define (anchor--sorted as)
  (map cadr
       (sort (map (lambda (a) (list (anchor-start a) a))
                  (map anchor--norm as)))))

;; The whole update. A page that redraws calls this again with the new
;; offsets; nothing else has to be undone.
(define (anchor-set! buf as)
  (buffer-set-local! buf 'anchors (anchor--sorted as))
  (anchor-sync! buf)
  ;; a zoomed part folds against the new offsets
  (when (boundp 'anchor-scale-redraw!) ((symbol-value 'anchor-scale-redraw!) buf))
  (anchor-list buf))

;; Parts declared for the index alone: imenu and the outline read them, and
;; nothing marks, walks or keys them unless the buffer has anchor-mode on.
;; A list declares its rows so on every draw
(define (anchor-index! buf as)
  (let ((sorted (anchor--sorted as)))
    (unless (equal? sorted (buffer-local buf 'anchors))
      (buffer-set-local! buf 'anchors sorted)
      (when (minor-mode-on? buf "anchor-mode") (anchor-sync! buf)))
    sorted))

(define (anchor-add! buf name start end &optional keymap data levels)
  (anchor-set! buf (cons (list name start end keymap data levels) (anchor-list buf))))

(define (anchor-clear! buf)
  (buffer-set-local! buf 'anchors '())
  (anchor-sync! buf)
  '())

;; the stops BLOCKS name, set on BUF whose text is TEXT: a block's first
;; line to the end of its last, as bytes
(define (anchor-set-blocks! buf text blocks)
  (let* ((starts (let loop ((ls (string-split text "\n")) (at 0) (acc '()))
                   (if (null? ls) (reverse (cons at acc))
                       (loop (cdr ls) (+ at (string-byte-length (car ls)) 1) (cons at acc)))))
         (n (- (length starts) 1))
         (at (lambda (line) (list-ref starts (max 0 (min n (- line 1)))))))
    (anchor-set! buf (map (lambda (a)
                            (append (list (car a) (at (cadr a)) (max (+ 1 (at (cadr a))) (- (at (+ 1 (caddr a))) 1)))
                                    (list-tail a 3)))
                          (anchor-blocks blocks)))))

;;; --- the keymap at point ---------------------------------------------------

;; The anchor at point owns the keys, and the highlight says which anchor
;; that is. Both are set after every command, so they follow point; a
;; position in no anchor has neither.
(define (anchor-sync! buf)
  (and (buffer-exists? buf)
       (let* ((a (anchor-at buf (buffer-point buf)))
              (map (and a (anchor-keymap a))))
         (unless (equal? map (buffer-at-point-map buf))
           (buffer-at-point-map! buf map))
         (overlay-set! buf 'anchor
           (if a (list (list (anchor-start a) (anchor-end a) "anchor-current")) '()))
         (anchor--mark-blocks! buf a)
         a)))

;; A page drawn as blocks shows no text overlay, so there the highlight is
;; the block the anchor spans: the outermost one whose lines are the anchor's
;; carries anchor-current. The tree is rewritten only when the anchor or the
;; page changes.
(define (anchor--span-lines buf a)
  (and a (with-current-buffer buf
           (lambda () (list (line-number-at-pos (anchor-start a))
                            (line-number-at-pos (max (anchor-start a) (- (anchor-end a) 1))))))))

(define (anchor--unclass class)
  (string-trim (string-join (filter (lambda (c) (not (member c (list "anchor-current" "anchor-top"))))
                                    (string-split (or class "") " "))
                            " ")))

(define (anchor--marked blocks lines &optional top?)
  (let ((done #f))
    (let walk ((bs blocks))
      (map (lambda (blk)
             (if (not (pair? blk)) blk
                 (let* ((class (anchor--unclass (plist-get blk 'class)))
                        (hit (and lines (not done) (equal? (plist-get blk 'lines) lines)))
                        (blk (if (or hit (plist-get blk 'class))
                                 (plist-put blk 'class (if hit (string-append class (if top? " anchor-current anchor-top" " anchor-current")) class))
                                 blk)))
                   (when hit (set! done #t))
                   (if (pair? (plist-get blk 'children))
                       (plist-put blk 'children (walk (plist-get blk 'children)))
                       blk))))
           bs))))

(define (anchor--mark-blocks! buf a &optional force)
  ;; The page's own draw is kept as anchor-drawn, and every mark starts from
  ;; it, so a part content-scale folded away comes back when it unfolds.
  (let* ((blocks (buffer-local buf 'render-blocks))
         (last (buffer-local buf 'anchor-marked))
         (fresh (not (and last (eq? (cdr last) blocks))))
         (lines (anchor--span-lines buf a))
         (key (list lines (buffer-local buf 'anchor-scale))))
    (when (and (equal? (buffer-local buf 'render-mode) "blocks") (pair? blocks)
               (or fresh force (not (equal? (car last) key))))
      (when fresh (buffer-set-local! buf 'anchor-drawn blocks))
      ;; the top part is where a page opens: it marks itself, and dims nothing
      (let* ((marked (anchor--marked (buffer-local buf 'anchor-drawn) lines
                                     (and a (equal? (anchor-start a) (anchor--top buf)))))
             (new (if (boundp 'anchor-scale-blocks)
                      ((symbol-value 'anchor-scale-blocks) buf marked)
                      marked)))
        (buffer-set-local! buf 'anchor-marked (cons key new))
        (buffer-set-local! buf 'render-blocks new)))))

(define (anchor--post-command!)
  (let ((buf (current-buffer)))
    (when (and (buffer-exists? buf) (minor-mode-on? buf "anchor-mode"))
      (anchor-sync! buf))))

(add-hook! 'post-command-hook 'anchor--post-command!)

;; a click on a part of a block page selects it: the renderer gives an anchored block
;; that has no click of its own the id anchor-line:N, N its first line
(add-hook! (list 'block-click 'anchor)
  (lambda (buf id)
    (and (string? id) (string-prefix? "anchor-line:" id)
         (let ((n (string->number (substring id 12 (string-length id)))))
           (and n
                (begin (buffer-goto-line! buf n)
                       (anchor-sync! buf)
                       #t))))))

(defcustom 'anchor-wrap #t
  "Whether TAB past the last anchor comes back to the first one."
  'group 'anchor 'type 'boolean)

;;; --- walking ---------------------------------------------------------------

(define (anchor--land! buf a what)
  (cond ((not a) (message (string-append "No " what)) #f)
        (else
          (goto-char! (anchor-start a))
          (anchor-sync! buf)
          (message (anchor-name a))
          (anchor-start a))))

(define (anchor-goto! buf name)
  (anchor--land! buf (anchor-find buf name) (string-append "anchor " name)))

(define (anchor--step! dir)
  (let* ((buf (current-buffer))
         (as (anchor-list buf))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos)))
         ;; the walk is a ring: the last anchor's TAB is the first one
         (target (or hit
                     (and anchor-wrap (pair? as)
                          (if (> dir 0) (car as) (car (reverse as)))))))
    (anchor--land! buf target (if (> dir 0) "next anchor" "previous anchor"))))

(define-command "anchor-next" "Move point to the next anchor"
  (lambda () (anchor--step! 1)))

(define-command "anchor-previous" "Move point to the previous anchor"
  (lambda () (anchor--step! -1)))

;; The arrows' walk: a page whose parts are anchors moves from part to part,
;; and past the last one (or in a buffer with none) the arrow is a line again.
;; It does not wrap; a ring is TAB's, an arrow stops at the end.
(define (anchor--arrow! dir)
  (let* ((buf (current-buffer))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos))))
    (cond (hit (goto-char! (anchor-start hit)) (anchor-sync! buf))
          ((> dir 0) (next-line!))
          (else (previous-line!) (anchor--clamp-top! buf)))))

;; nothing above the top anchor is a place to go: the walk up stops there
(define (anchor--top buf)
  (let ((as (anchor-list buf))) (and (pair? as) (anchor-start (car as)))))

(define (anchor--clamp-top! buf)
  (let ((top (anchor--top buf)))
    (when (and top (< (buffer-point buf) top))
      (goto-char! top)
      (anchor-sync! buf))))

(define-command "anchor-down" "Move point to the next anchor, or down a line when there is none"
  (lambda () (anchor--arrow! 1)))
(define-command "anchor-up" "Move point to the previous anchor, or up a line when there is none"
  (lambda () (anchor--arrow! -1)))
;; Columns. A page that lays its parts out side by side hangs (column N) on
;; an anchor's data; the others are column 1. Left and right cross to the
;; next column the way the arrows do, landing on the same place down the
;; page (the Nth stop of that column), else its last. On a page without
;; columns the arrow is a character again.
(define (anchor--column a)
  (let ((d (anchor-data a)))
    (or (and (pair? d) (plist-get d 'column)) 1)))

(define (anchor--sideways! dir)
  (let* ((buf (current-buffer))
         (as (anchor-list buf))
         (cur (anchor-at buf (buffer-point buf))))
    (cond
      ((not (find (lambda (a) (not (= 1 (anchor--column a)))) as))
       (run-command (if (> dir 0) "forward-char" "backward-char")))
      ((not cur) (message "No anchor here"))
      (else
       (let* ((col (anchor--column cur))
              (cols (filter (lambda (c) (if (> dir 0) (> c col) (< c col))) (map anchor--column as))))
         (if (null? cols)
             (message (if (> dir 0) "No column to the right" "No column to the left"))
             (let* ((target (fold (lambda (best c) (if (> dir 0) (min best c) (max best c))) (car cols) cols))
                    (mine (filter (lambda (a) (= col (anchor--column a))) as))
                    (theirs (filter (lambda (a) (= target (anchor--column a))) as))
                    (n (let loop ((xs mine) (i 0)) (cond ((null? xs) 0) ((equal? (anchor-name (car xs)) (anchor-name cur)) i) (else (loop (cdr xs) (+ i 1))))))
                    (a (list-ref theirs (min n (- (length theirs) 1)))))
               (anchor--land! buf a "anchor"))))))))

(define-command "anchor-right" "Move to the same place in the column to the right, or a character right on a page without columns"
  (lambda () (anchor--sideways! 1)))
(define-command "anchor-left" "Move to the same place in the column to the left, or a character left on a page without columns"
  (lambda () (anchor--sideways! -1)))

;; The reading walk, M-<up> and M-<down>. An anchor always comes first,
;; however far: the page chose its stops. Past the last one the key pages,
;; so the rest of a long part still reads. A page is counted in rows as
;; drawn: a line wraps at the window's width, so one paragraph can be many.
(define (anchor--lines buf)
  ;; (START ROWS) for each line of BUF
  (let ((cols (max 20 (or (buffer-cols buf) 80))))
    (let loop ((ls (string-split (buffer-text buf) "\n")) (at 0) (acc '()))
      (if (null? ls) (reverse acc)
          (let ((n (string-length (car ls))))
            (loop (cdr ls) (+ at (string-byte-length (car ls)) 1)
                  (cons (list at (max 1 (quotient (+ n cols -1) cols))) acc)))))))

(define (anchor--rows lines from to)
  ;; rows drawn from the line holding FROM up to the line holding TO
  (let ((lo (min from to)) (hi (max from to)))
    (fold (lambda (sum l)
            (if (and (>= (car l) (anchor--line-start lines lo)) (< (car l) (anchor--line-start lines hi)))
                (+ sum (cadr l)) sum))
          0 lines)))

(define (anchor--line-start lines pos)
  (fold (lambda (best l) (if (<= (car l) pos) (car l) best)) 0 lines))

(define (anchor--page-from lines pos dir page)
  ;; the line start one page of rows from POS
  (let walk ((ls (if (> dir 0)
                     (filter (lambda (l) (> (car l) pos)) lines)
                     (reverse (filter (lambda (l) (< (car l) (anchor--line-start lines pos))) lines))))
             (rows 0) (last #f))
    (cond ((null? ls) last)
          ((>= rows page) (car (car ls)))
          (else (walk (cdr ls) (+ rows (cadr (car ls))) (car (car ls)))))))

(define (anchor--read! dir)
  (let* ((buf (current-buffer))
         (pos (buffer-point buf))
         (hit (if (> dir 0) (anchor--after buf pos) (anchor--before buf pos)))
         (lines (anchor--lines buf))
         (page (max 1 (- (window-rows) 3)))
         (edge (if (> dir 0) (car (car (reverse lines))) 0)))
    (cond (hit (goto-char! (anchor-start hit)) (anchor-sync! buf) (message (anchor-name hit)))
          ((> (anchor--rows lines pos edge) 0)
           (let ((to (anchor--page-from lines pos dir page)))
             (when to (goto-char! to) (anchor-sync! buf))
             (when (< dir 0) (anchor--clamp-top! buf))))
          (else (message (if (> dir 0) "No next anchor" "No previous anchor"))))))

(define-command "anchor-read-next" "Move to the next anchor, or one page down past the last"
  (lambda () (anchor--read! 1)))
(define-command "anchor-read-previous" "Move to the previous anchor, or one page up before the first"
  (lambda () (anchor--read! -1)))

(define-command "anchor-jump" "Go to an anchor of this buffer by name"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (map anchor-name (anchor-list buf))))
      (if (null? names)
          (message "This buffer declares no anchors")
          (completing-read "Anchor: " names
            (lambda (name)
              (when (and (string? name) (not (equal? name "")))
                (anchor-goto! buf name))))))))

;;; --- the mode --------------------------------------------------------------

;; Subtle on purpose: an anchor is a section, not a match, so its whole
;; range wears this. A theme that names the face wins.
(defface! 'anchor-current 'inherit 'lazy-highlight)
;; the same mark on a block page: the part point is in is framed a little
;; way out from its text, and the rest of the page steps back a little, still
;; readable. Outline and ring, not padding, so nothing on the page moves. Each level of the page dims what is beside the path down to the
;; part.
(define-style! 'anchor "
.anchor-current { border-radius: 2px; background-image: linear-gradient(color-mix(in srgb, var(--accent-fg) 12%, transparent), color-mix(in srgb, var(--accent-fg) 12%, transparent)); }
.anchor-current .current:not(.anchor-current) { background-color: transparent; }
.anchor-current:is(.c-prose, .c-bullet, .c-meta, .c-title, .c-row).current { background-color: transparent; }
")

(define (anchor--block-span blk)
  ;; the lines a block spans: its own, else from the first of the blocks in it to the last
  (let ((own (plist-get blk 'lines)))
    (if own
        (list (car own) (cadr own))
        (let loop ((cs (or (plist-get blk 'children) '())) (span #f))
          (if (null? cs)
              span
              (let ((s (and (pair? (car cs)) (anchor--block-span (car cs)))))
                (loop (cdr cs)
                      (cond ((not s) span)
                            ((not span) s)
                            (else (list (min (car span) (car s)) (max (cadr span) (cadr s))))))))))))

;; The index a block page gives imenu, as its components name it: each block
;; with an imenu-name, or else an anchor-name, and lines, its own or those of
;; the blocks in it, with the entries inside it a level under it. An entry
;; named as the one it is in is that one: a part and its own heading are one
;; entry. A row of tabs gives one entry for each tab, taken by its click.
;; -> (LINE DEPTH NAME LAST PATH CLICK KIND DOC), in page order
(define (anchor-block-entries blocks)
  (reverse
    (let walk ((bs blocks) (path '()) (acc '()))
      (cond ((null? bs) acc)
            ((not (pair? (car bs))) (walk (cdr bs) path acc))
            (else
             (let* ((blk (car bs))
                    (name (or (plist-get blk 'imenu-name) (plist-get blk 'anchor-name)))
                    (name (and (string? name) (not (equal? (string-trim name) "")) (string-trim name)))
                    (span (and name (anchor--block-span blk)))
                    (new? (and span (not (and (pair? path) (equal? (car path) name)))))
                    (data (let ((d (plist-get blk 'anchor-data))) (and (pair? d) (symbol? (car d)) d)))
                    (tabs (and data (plist-get data 'tabs)))
                    (row (and (pair? tabs) (plist-get blk 'lines) (car (plist-get blk 'lines))))
                    (inner (if new? (cons name path) path))
                    (acc (if new?
                             (cons (list (car span) (length path) name (cadr span) (reverse inner) #f
                                         (or (and data (plist-get data 'kind)) "")
                                         (and data (plist-get data 'doc)))
                                   acc)
                             acc))
                    (acc (let each ((ts (if row tabs '())) (acc acc))
                           (if (null? ts)
                               acc
                               (each (cdr ts)
                                     (cons (list row (length inner) (cadr (car ts)) row
                                                 (reverse (cons (cadr (car ts)) inner)) (car (car ts)) "" "")
                                           acc))))))
               (walk (cdr bs) path (walk (or (plist-get blk 'children) '()) inner acc))))))))

(define (anchor--gist text)
  ;; a preview's first sentence
  (let* ((t (string-trim text))
         (parts (string-split t ". ")))
    (if (pair? (cdr parts)) (string-append (car parts) ".") t)))

;; imenu rows from those entries: (LINE KIND NAME DOC TARGET WHERE), the name
;; indented by its depth, the preview the first sentence under its first line,
;; TARGET a thunk that takes a tab, and WHERE the entries it is in, which tell
;; one name from another. OPTS: 'text the text the lines are of (BUF's), 'depth
;; to add, 'rename a name's shorter say, 'where the path above them all,
;; 'line every row's line, 'target (ENTRY -> thunk or #f)
(define (anchor-entry-rows buf entries &optional opts)
  (let* ((opts (or opts '()))
         (lines (string-split (or (plist-get opts 'text) (buffer-text buf)) "\n"))
         (n (length lines))
         (rename (or (plist-get opts 'rename) (lambda (s) s)))
         (base (or (plist-get opts 'depth) 0))
         (above (or (plist-get opts 'where) ""))
         (target (plist-get opts 'target)))
    (map (lambda (e)
           (let* ((line (nth 0 e)) (last (nth 3 e)) (click (nth 5 e))
                  (body (if (and (< line last) (< line n))
                            (string-join (list-head (list-tail lines line) (- (min last n) line)) " ")
                            ""))
                  (doc (or (nth 7 e) (anchor--gist body)))
                  (parents (map rename (reverse (cdr (reverse (nth 4 e))))))
                  (where (string-join (filter (lambda (s) (not (equal? s ""))) (cons above parents)) " / ")))
             (list (or (plist-get opts 'line) line)
                   (nth 6 e)
                   (string-append (string-join (map (lambda (i) "   ") (iota (+ base (nth 1 e)))) "") (rename (nth 2 e)))
                   doc
                   (cond (target (target e))
                         (click (lambda () (run-hook-with-args-until-success 'block-click buf click)))
                         (else #f))
                   where)))
         entries)))

(define (anchor-imenu-rows buf)
  ;; imenu's index of an anchored page: its parts, a part inside another
  ;; indented under it, its first words for the preview. A part whose DATA
  ;; names its 'kind is filed under it, so imenu gives each kind a tab; its
  ;; 'doc, when it has one, is the preview. A page drawn as blocks is indexed
  ;; as its components name it, when that names every part
  (let* ((entries (and (equal? (buffer-local buf 'render-mode) "blocks")
                       (anchor-block-entries (or (buffer-local buf 'render-blocks) '()))))
         (names (map (lambda (e) (nth 2 e)) (or entries '())))
         (text (buffer-text buf)))
    (if (and (pair? entries)
             (null? (filter (lambda (a) (not (member (string-trim (anchor-name a)) names))) (anchor-list buf))))
        (anchor-entry-rows buf entries)
    (let loop ((as (anchor-list buf)) (open '()) (acc '()))
      (if (null? as)
          (reverse acc)
          (let* ((a (car as))
                 (open (filter (lambda (o) (and (<= (anchor-start o) (anchor-start a))
                                                (>= (anchor-end o) (anchor-end a))))
                               open))
                 (path (string-append (string-join (map (lambda (o) "   ") open) "") (anchor-name a)))
                 (body (substring-bytes text (anchor-start a) (anchor-end a)))
                 (lines (cdr (string-split body "\n")))
                 (data (let ((d (anchor-data a))) (and (pair? d) (symbol? (car d)) d)))
                 (kind (or (and data (plist-get data 'kind)) ""))
                 (doc (or (and data (plist-get data 'doc))
                          (if (pair? lines) (string-join lines " ") ""))))
            (loop (cdr as) (cons a open)
                  (cons (list (with-current-buffer buf (lambda () (line-number-at-pos (anchor-start a))))
                              kind path doc)
                        acc))))))))

(define (anchor--apply! buf)
  (buffer-set-local! buf 'imenu-index-function 'anchor-imenu-rows)
  ;; Anchor navigation must win over generic scrolling in other minor maps.
  (let ((maps (buffer-minor-maps buf)))
    (buffer-minor-maps! buf
      (cons "anchor-mode-map"
            (filter (lambda (name) (not (equal? name "anchor-mode-map"))) maps))))
  (anchor-sync! buf)
  #t)

(define (anchor--teardown! buf)
  (when (buffer-exists? buf)
    (buffer-at-point-map! buf #f)
    (when (eq? (buffer-local buf 'imenu-index-function) 'anchor-imenu-rows)
      (buffer-set-local! buf 'imenu-index-function #f))
    (overlay-set! buf 'anchor '())
    (anchor--mark-blocks! buf #f))
  #t)

;; TAB and S-TAB are the page's walk, the way they are a browser's. A mode
;; that turns anchor-mode on in an editable buffer is saying TAB means
;; this here; the anchors' own keymaps come in front of these.
(register-minor-mode! "anchor-mode" anchor--apply! anchor--teardown!)
(minor-mode-keys! "anchor-mode"
  '(("TAB" "anchor-next")
    ("S-TAB" "anchor-previous")
    ("M-<down>" "anchor-read-next")
    ("M-<up>" "anchor-read-previous")
    ("M-down" "anchor-read-next")
    ("M-up" "anchor-read-previous")
    ("M-g a" "anchor-jump")
    ("<right>" "anchor-right")
    ("<left>" "anchor-left")
    ("f" "anchor-fold")
    ;; zoom the part at point; content-scale owns the commands
    ("-" "anchor-scale-decrease")
    ("+" "anchor-scale-increase")
    ("=" "anchor-scale-increase")))

(mode-doc! "anchor-mode"
  "The page's parts, one key apart. `TAB` goes to the next anchor and `S-TAB` to the previous one. `M-<down>` and `M-<up>` do too, and page past the last anchor. `M-g a` goes to one by name. `-` shows less of the part at point and `+` more, as far as it declares; outside a part they zoom the page. The anchor point stands in puts its own keys in front of the buffer's, so the same letter can mean a different thing in each part of the page.")

(define-command "anchor-mode" "Walk this buffer's anchors, each with its own keys"
  (lambda () (toggle-minor-mode! "anchor-mode")))

;;; --- reading a buffer by its parts -----------------------------------------

;; What an agent asks first of any buffer: its parts, the way a reader walks
;; them. A page that declares anchors answers with them; a file answers with
;; its headings or its definitions.
(define (buffer-outline buf)
  (let ((as (anchor-list buf)))
    (cond ((pair? as)
           (with-current-buffer buf
             (lambda ()
               (map (lambda (a) (list (anchor-name a)
                                      (line-number-at-pos (anchor-start a))
                                      (line-number-at-pos (max (anchor-start a) (- (anchor-end a) 1)))))
                    as))))
          ((or (buffer-derived-mode? buf "markdown-mode") (buffer-derived-mode? buf "morg-mode"))
           (markdown-outline buf))
          (else (code-outline buf)))))

(define (buffer-section buf key)
  ;; one part, by the name or the line buffer-outline gave
  (cond ((number? key)
         (if (or (buffer-derived-mode? buf "markdown-mode") (buffer-derived-mode? buf "morg-mode"))
             (markdown-read buf key)
             (code-read buf key)))
        (else
         (let ((a (anchor-find buf key)))
           (and a (with-current-buffer buf (lambda () (buffer-substring (anchor-start a) (anchor-end a)))))))))

(define (anchor--with-file path f)
  ;; F on a buffer that holds PATH: its live buffer, else a hidden copy
  ;; in the file's mode that is killed after, so reading leaves nothing
  (if (buffer-exists? path)
      (f path)
      (let ((b (string-append " *outline " (number->string (monotonic-ms)) " " path)))
        (buffer-create b)
        (unwind-protect
          (lambda ()
            (buffer-append! b (or (read-file path) ""))
            (let ((mode (auto-mode-for-buffer b path)))
              (when mode
                (with-current-buffer b (lambda () (set-mode! mode)))
                ;; a grammar the mode names and nobody installed: install
                ;; it, and set the mode again so the copy parses with it
                (let ((lang (buffer-local b 'ts-lang)))
                  (when (and lang (not (member lang (ts-langs))) (ts-ensure-grammar! lang))
                    (with-current-buffer b (lambda () (set-mode! mode)))))))
            (f b))
          (lambda () (buffer-kill! b))))))

(define (file-outline path)
  (anchor--with-file path buffer-outline))

(define (file-section path key)
  (anchor--with-file path (lambda (b) (buffer-section b key))))

;;; --- the surface -----------------------------------------------------------

(public! 'anchor-set!
  "(anchor-set! BUF ((NAME START END [KEYMAP [DATA [LEVELS]]]) ...)) — declare BUF's anchors, replacing the old ones; a page that redraws calls this again. LEVELS is ((N REDUCTION) ...), REDUCTION fold, elide, (summarize STYLE) or (aggregate FN), FN (BUF ANCHOR) -> text")
(public! 'anchor-add!
  "(anchor-add! BUF NAME START END [KEYMAP [DATA [LEVELS]]]) — add one anchor to BUF")
(public! 'anchor-clear! "(anchor-clear! BUF) — BUF has no anchors")
(public! 'anchor-blocks "(anchor-blocks BLOCKS) — the stops a block tree names: (NAME FIRST-LINE LAST-LINE [KEYMAP DATA]) for each block with anchor-name and lines")
(public! 'anchor-set-blocks! "(anchor-set-blocks! BUF TEXT BLOCKS) — set BUF's anchors from the stops BLOCKS name, TEXT being BUF's text")
(public! 'anchor-list "(anchor-list BUF) — BUF's anchors, in the order they appear")
(public! 'anchor-at "(anchor-at BUF POS) — the innermost anchor holding byte POS, or #f")
(public! 'anchor-find "(anchor-find BUF NAME) — BUF's anchor called NAME, or #f")
(public! 'anchor-goto! "(anchor-goto! BUF NAME) — put point at the start of that anchor")
(public! 'anchor-sync! "(anchor-sync! BUF) — put the anchor at point's keymap and highlight in force now; the post-command hook already does this")
(public! 'anchor-name "(anchor-name ANCHOR) — its name")
(public! 'anchor-start "(anchor-start ANCHOR) — its first byte")
(public! 'anchor-end "(anchor-end ANCHOR) — the byte after its last")
(public! 'anchor-keymap "(anchor-keymap ANCHOR) — the keymap in force inside it, or #f")
(public! 'anchor-data "(anchor-data ANCHOR) — whatever the page hung on it")
(public! 'anchor-levels "(anchor-levels ANCHOR) — how it zooms, ((N REDUCTION) ...), or #f for the default fold")
(public! 'anchor-imenu-rows "(anchor-imenu-rows BUF) — imenu's index of BUF: one row per anchor, or the nested entries its components name")
(public! 'anchor-block-entries "(anchor-block-entries BLOCKS) — the imenu entries a block tree names, nested: (LINE DEPTH NAME LAST PATH CLICK KIND DOC)")
(public! 'anchor-entry-rows "(anchor-entry-rows BUF ENTRIES [OPTS]) — imenu rows (LINE KIND NAME DOC TARGET WHERE) from anchor-block-entries; OPTS 'text 'depth 'rename 'where 'line 'target")

(domain! 'navigation)
(effects! '(read))
(public! 'buffer-outline
  "(buffer-outline BUF) — BUF's parts, read first: its anchors as (NAME FIRST-LINE LAST-LINE); with none, its markdown headings or code definitions")
(public! 'buffer-section "(buffer-section BUF KEY) — one part: KEY a NAME buffer-outline gave answers that anchor's text, a LINE answers the heading's section or the definition there; #f when none")
(public! 'file-outline "(file-outline PATH) — buffer-outline of the file at PATH, opening no buffer: read many at once with chat-parallel-map")
(public! 'file-section "(file-section PATH LINE) — buffer-section of the file at PATH, opening no buffer")
