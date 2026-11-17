;;; html-element.scm --- structural editing of HTML elements, as web-mode does.
;;;
;;; The tree-sitter html grammar knows every element, so the commands
;;; here work on whole elements: move to one, select it, kill, clone,
;;; move it past its neighbour, wrap, rename or unwrap it. Positions are
;;; byte offsets, as point and ts-node give them. Each command that
;;; changes the text makes one buffer-replace-range!, so it is one undo
;;; step.
;;;
;;; The keys live in html-mode-map: C-c C-e and a letter, as in web-mode,
;;; and the paredit chords for motion and for moving an element.

(category! 'edit)
(domain! 'edit)
(effects! '(write))

;;; --- the tree --------------------------------------------------------------

(define *html-element-kinds* '("element" "script_element" "style_element"))

(define (html-element--el? n) (and n (member (car n) *html-element-kinds*) #t))

(define (html-element--rel n op) (ts-node (car n) (cadr n) (caddr n) op))

(define (html-element-at pos)
  (let loop ((n (ts-node "" pos pos 'at)))
    (cond ((not n) #f)
          ((html-element--el? n) n)
          (else (loop (html-element--rel n 'parent))))))

(define (html-element-parent n)
  (let loop ((m (html-element--rel n 'parent)))
    (cond ((not m) #f)
          ((html-element--el? m) m)
          (else (loop (html-element--rel m 'parent))))))

;; the element or comment beside N; text between them does not count
(define (html-element-sibling n op)
  (let loop ((m (html-element--rel n op)))
    (cond ((not m) #f)
          ((or (html-element--el? m) (equal? (car m) "comment")) m)
          (else (loop (html-element--rel m op))))))

(define (html-element--kids n) (ts-children (car n) (cadr n) (caddr n)))

(define (html-element-child n)
  (let ((ks (filter html-element--el? (html-element--kids n))))
    (if (null? ks) #f (car ks))))

(define (html-element--part n kind)
  (let ((ks (filter (lambda (k) (equal? (car k) kind)) (html-element--kids n))))
    (if (null? ks) #f (car ks))))

;; the bytes between the start tag and the end tag
(define (html-element-inner n)
  (let ((st (html-element--part n "start_tag")) (et (html-element--part n "end_tag")))
    (and st et (list (caddr st) (cadr et)))))

(define (html-element--text n) (buffer-substring (cadr n) (caddr n)))

(define (html-element--line-start pos) (line-start-position (line-number-at-pos pos)))

(define (html-element--line-end pos)
  (let ((next (line-start-position (+ 1 (line-number-at-pos pos)))))
    (if (and next (> next pos)) (- next 1) (buffer-size (current-buffer)))))

(define (html-element--blank? s) (string=? (string-trim s) ""))

;; the indentation before N when N starts its line, else #f
(define (html-element--indent n)
  (let ((pre (buffer-substring (html-element--line-start (cadr n)) (cadr n))))
    (and (html-element--blank? pre) pre)))

(define (html-element--own-lines? n)
  (and (html-element--indent n)
       (html-element--blank? (buffer-substring (caddr n) (html-element--line-end (caddr n))))))

(define (html-element--pos)
  (let* ((p (point))
         (ls (html-element--line-start p))
         (le (html-element--line-end p))
         (fs (html-element--first-char ls))
         (tail (string-trim (buffer-substring p le))))
    (if (or (<= p fs) (string=? tail "")) (min fs le) p)))

(define (html-element--with fn)
  (let ((n (html-element-at (html-element--pos))))
    (if n (fn n) (message "No element here"))))

(define (html-element--replace! s e text) (buffer-replace-range! (current-buffer) s (- e s) text))

;;; --- motion ----------------------------------------------------------------

(define-command "html-element-beginning" "Go to the start of this element"
  (lambda () (html-element--with (lambda (n) (goto-char! (cadr n))))))

(define-command "html-element-end" "Go to the end of this element"
  (lambda () (html-element--with (lambda (n) (goto-char! (caddr n))))))

(define (html-element--go! n op what)
  (let ((m (html-element-sibling n op)))
    (if m (goto-char! (cadr m)) (message (string-append "No " what " element")))))

(define-command "html-element-next" "Go to the next element at this level"
  (lambda () (html-element--with (lambda (n) (html-element--go! n 'next "next")))))

(define-command "html-element-previous" "Go to the previous element at this level"
  (lambda () (html-element--with (lambda (n) (html-element--go! n 'prev "previous")))))

(define-command "html-element-parent" "Go to the start of the element around point"
  (lambda ()
    (html-element--with
      (lambda (n)
        ;; in an element's content its own start is the way out; on its
        ;; start tag, the parent's
        (let* ((st (html-element--part n "start_tag"))
               (m (if (and st (>= (point) (caddr st))) n (html-element-parent n))))
          (if m (goto-char! (cadr m)) (message "No parent element")))))))

(define-command "html-element-child" "Go to the first element inside this one"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((c (html-element-child n)))
          (if c (goto-char! (cadr c)) (message "No child element")))))))

;; the elements at point's level: the children of the innermost element
;; whose content holds POS, or of the document
(define (html-element--level pos)
  (let loop ((n (html-element-at pos)))
    (cond ((not n)
           ;; the document: ts-children over 0..SIZE names the whole file
           (or (ts-children "document" 0 (buffer-size (current-buffer))) '()))
          ((let ((in (html-element-inner n))) (and in (>= pos (car in)) (<= pos (cadr in))))
           (html-element--kids n))
          (else (loop (html-element-parent n))))))

(define (html-element--level-nodes pos)
  (filter (lambda (k) (or (html-element--el? k) (equal? (car k) "comment"))) (html-element--level pos)))

(define-command "html-element-forward" "Move over the element after point, as forward-sexp"
  (lambda ()
    (let ((ks (filter (lambda (k) (> (caddr k) (point))) (html-element--level-nodes (point)))))
      (if (null? ks) (message "No element after point") (goto-char! (caddr (car ks)))))))

(define-command "html-element-backward" "Move back over the element before point, as backward-sexp"
  (lambda ()
    (let ((ks (filter (lambda (k) (< (cadr k) (point))) (html-element--level-nodes (point)))))
      (if (null? ks) (message "No element before point") (goto-char! (cadr (car (reverse ks))))))))

;; M-up and M-down go by parent: from an element's text the step is the
;; element around it, so a heading's text walks its section and the ones
;; beside it; from a tag, where these leave point, the element itself
(define (html-element--walk-unit pos)
  (let ((n (html-element-at pos))
        (here (ts-node "" pos pos 'at)))
    (cond ((not n) #f)
          ((and here (equal? (car here) "text")) (or (html-element-parent n) n))
          (else n))))

(define-command "html-element-down" "Go to the next element, by parent from text"
  (lambda ()
    (let ((n (html-element--walk-unit (html-element--pos))))
      (if (not n) (message "No element here")
          (let ((m (html-element-sibling n 'next)))
            (if m (goto-char! (cadr m)) (message "No next element")))))))

(define-command "html-element-up" "Go to the start of this element, or the one before, by parent from text"
  (lambda ()
    (let ((n (html-element--walk-unit (html-element--pos))))
      (cond ((not n) (message "No element here"))
            ((> (html-element--pos) (cadr n)) (goto-char! (cadr n)))
            (else (let ((m (html-element-sibling n 'prev)))
                    (if m (goto-char! (cadr m)) (message "No previous element"))))))))

(define-command "html-tag-match" "Jump between the start tag and the end tag"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((st (html-element--part n "start_tag")) (et (html-element--part n "end_tag")))
          (cond ((not et) (message "This element has no end tag"))
                ((and st (< (point) (caddr st))) (goto-char! (cadr et)))
                (else (goto-char! (cadr n)))))))))

;;; --- selection -------------------------------------------------------------

(define-command "html-element-select" "Select this element; again selects its parent"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let* ((m (mark))
               (n (if (and m (= (point) (cadr n)) (= m (caddr n)))
                      (or (html-element-parent n) n)
                      n)))
          (set-mark! (caddr n))
          (goto-char! (cadr n)))))))

(define-command "html-element-content-select" "Select what is inside this element"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((in (html-element-inner n)))
          (if in (begin (set-mark! (cadr in)) (goto-char! (car in)))
              (message "This element has no content")))))))

;;; --- folding ---------------------------------------------------------------
;;; A fold hides what is between an element's tags, so <head> folds to
;;; <head>…</head>. The ranges live under the 'html-element fold tag.

(define (html-element--fold-range n)
  (let ((in (html-element-inner n)))
    (and in (< (car in) (cadr in)) in)))

;; the element at point, or the nearest one around it, that has content
(define (html-element--foldable pos)
  (let loop ((n (html-element-at pos)))
    (cond ((not n) #f)
          ((html-element--fold-range n) n)
          (else (loop (html-element-parent n))))))

(define-command "html-element-fold" "Fold or unfold what is inside this element"
  (lambda ()
    (let* ((buf (current-buffer))
           (n (html-element--foldable (point))))
      (if (not n)
          (message "Nothing to fold here")
          (begin
            (fold-toggle! buf 'html-element (html-element--fold-range n))
            (goto-char! (cadr n)))))))

(define-command "html-element-tab" "Fold the element at point in a read-only buffer, else indent"
  (lambda ()
    (if (buffer-read-only? (current-buffer))
        (run-command "html-element-fold")
        (run-command "indent-for-tab"))))

(define-command "html-element-unfold-all" "Unfold every folded element"
  (lambda () (fold-set! (current-buffer) 'html-element '())))

;;; --- edits -----------------------------------------------------------------

(define-command "html-element-kill" "Kill this element, and its line when it stands alone"
  (lambda ()
    (html-element--with
      (lambda (n)
        (if (html-element--own-lines? n)
            (let ((s (html-element--line-start (cadr n)))
                  (e (min (+ 1 (html-element--line-end (caddr n))) (buffer-size (current-buffer)))))
              (kill-new (html-element--text n))
              (html-element--replace! s e "")
              (goto-char! s))
            (kill-region-1 (cadr n) (caddr n)))))))

(define-command "html-element-clone" "Put a copy of this element after it"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let* ((ind (html-element--indent n))
               (gap (if ind (string-append "\n" ind) " "))
               (text (html-element--text n)))
          (html-element--replace! (caddr n) (caddr n) (string-append gap text))
          (goto-char! (+ (caddr n) (string-byte-length gap))))))))

;; swap N with its neighbour on OP's side, keeping the text between them
(define (html-element--swap! n op)
  (let ((m (html-element-sibling n op)))
    (if (not m)
        (message (if (eq? op 'prev) "Already the first element" "Already the last element"))
        (let* ((a (if (eq? op 'prev) m n))
               (b (if (eq? op 'prev) n m))
               (between (buffer-substring (caddr a) (cadr b)))
               (at (- (point) (cadr n)))
               (ta (html-element--text a))
               (tb (html-element--text b)))
          (html-element--replace! (cadr a) (caddr b) (string-append tb between ta))
          (goto-char! (+ at (if (eq? op 'prev)
                                (cadr a)
                                (+ (cadr a) (string-byte-length tb) (string-byte-length between)))))))))

(define-command "html-element-move-up" "Move this element before the one above it"
  (lambda ()
    (html-element--with (lambda (n) (html-element--swap! n 'prev)))))

(define-command "html-element-move-down" "Move this element after the one below it"
  (lambda ()
    (html-element--with (lambda (n) (html-element--swap! n 'next)))))

(define-command "html-element-vanish" "Remove this element's tags and keep what is inside"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((in (html-element-inner n)))
          (if (not in)
              (message "This element has no content to keep")
              (begin
                (html-element--replace! (cadr n) (caddr n) (buffer-substring (car in) (cadr in)))
                (goto-char! (cadr n)))))))))

(define-command "html-element-raise" "Put this element in place of the element around it"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((up (html-element-parent n)))
          (if (not up)
              (message "No element around this one")
              (begin
                (html-element--replace! (cadr up) (caddr up) (html-element--text n))
                (goto-char! (cadr up)))))))))

(define (html-element--tag-name spec)
  (let ((t (string-trim spec)))
    (car (string-split t " "))))

(define-command "html-element-wrap" "Wrap this element in a new one"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let ((buf (current-buffer))
              (s (cadr n)) (e (caddr n))
              (text (html-element--text n))
              (ind (and (html-element--own-lines? n) (html-element--indent n))))
          (minibuffer-read "Wrap in (tag and attributes): " '()
            (lambda (spec)
              (when (and (string? spec) (not (html-element--blank? spec)))
                (let* ((open (string-append "<" (string-trim spec) ">"))
                       (close (string-append "</" (html-element--tag-name spec) ">"))
                       (new (if ind
                                (string-append open "\n" ind "  " (string-replace text "\n" "\n  ") "\n" ind close)
                                (string-append open text close))))
                  (buffer-replace-range! buf s (- e s) new)
                  (buffer-goto! buf s))))))))))

(define-command "html-element-rename" "Rename this element's tag"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let* ((buf (current-buffer))
               (st (html-element--part n "start_tag"))
               (et (html-element--part n "end_tag"))
               (sn (and st (html-element--part st "tag_name")))
               (en (and et (html-element--part et "tag_name")))
               (s (cadr n)) (text (html-element--text n)))
          (if (not sn)
              (message "No tag to rename")
              (minibuffer-read (string-append "Rename " (buffer-substring (cadr sn) (caddr sn)) " to: ") '()
                (lambda (name)
                  (when (and (string? name) (not (html-element--blank? name)))
                    (let* ((name (string-trim name))
                           (cut (lambda (str from to) (substring-bytes str (- from s) (- to s))))
                           (len (string-byte-length text))
                           (new (if en
                                    (string-append (substring-bytes text 0 (- (cadr sn) s)) name
                                                   (cut text (caddr sn) (cadr en)) name
                                                   (substring-bytes text (- (caddr en) s) len))
                                    (string-append (substring-bytes text 0 (- (cadr sn) s)) name
                                                   (substring-bytes text (- (caddr sn) s) len)))))
                      (buffer-replace-range! buf s (string-byte-length text) new)))))))))))

;;; --- indentation -----------------------------------------------------------
;;; A line goes two spaces deeper than the line its enclosing element starts
;;; on; a line that starts with that element's end tag goes level with it.
;;; Lines inside <script> and <style> keep their own indentation.

(define html-element-indent-offset 2)

;; the innermost element whose content holds POS
(define (html-element--container pos)
  (let loop ((n (html-element-at pos)))
    (cond ((not n) #f)
          ((let ((in (html-element-inner n))) (and in (>= pos (car in)) (<= pos (cadr in)))) n)
          (else (loop (html-element-parent n))))))

(define (html-element--first-char ls)
  (let* ((le (html-element--line-end ls))
         (line (buffer-substring ls le))
         (lead (let count ((i 0))
                 (if (and (< i (string-length line)) (memv (string-ref line i) '(#\space #\tab)))
                     (count (+ i 1))
                     i))))
    (+ ls lead)))

(define (html-element--line-indent pos)
  (let ((ls (html-element--line-start pos)))
    (- (html-element--first-char ls) ls)))

;; the column the line starting at LS should start at, or #f to leave it
(define (html-element--indent-target ls)
  (let* ((fs (html-element--first-char ls))
         (c (html-element--container fs)))
    (cond ((not c) 0)
          ((and (member (car c) '("script_element" "style_element"))
                (not (= fs (cadr (html-element-inner c)))))
           #f)
          ((= fs (cadr (html-element-inner c))) (html-element--line-indent (cadr c)))
          (else (+ (html-element--line-indent (cadr c)) html-element-indent-offset)))))

;; indent the line holding POS; answers how far its first char moved
(define (html-element--indent-line! pos)
  (let* ((ls (html-element--line-start pos))
         (fs (html-element--first-char ls))
         (want (html-element--indent-target ls)))
    (if (or (not want) (= want (- fs ls)))
        0
        (begin
          (html-element--replace! ls fs (make-string want #\space))
          (- want (- fs ls))))))

(define-command "html-indent-line" "Indent this line by the element it is in; with a region, every line of it"
  (lambda ()
    (if (and (mark) (not (= (mark) (point))))
        (let* ((buf (current-buffer))
               (whole (and (= (point) 0) (= (mark) (buffer-size buf))))
               (from (and whole (buffer-local-value 'select-all-from buf))))
          (run-command "html-indent-region")
          (set-mark! #f)
          ;; after C-x h (or Cmd-A) and TAB, point goes back where it was
          (when (number? from) (goto-char! (buffer-local-value 'select-all-from buf))))
        (html-element--indent-line-at-point!))))

(define (html-element--indent-line-at-point!)
    (let* ((p (point))
           (ls (html-element--line-start p))
           (in-lead (<= p (html-element--first-char ls)))
           (d (html-element--indent-line! p)))
      (goto-char! (if in-lead (html-element--first-char ls) (+ p d)))))

(define-command "html-indent-region" "Indent every line of the region by its element"
  (lambda ()
    (let ((m (mark)))
      (if (not m)
          (message "No region")
          (let* ((a (min m (point))) (b (max m (point)))
                 (first (line-number-at-pos a)) (last (line-number-at-pos b)))
            (let loop ((l first))
              (when (<= l last)
                (html-element--indent-line! (line-start-position l))
                (loop (+ l 1))))
            (message (string-append "Indented " (number->string (+ 1 (- last first))) " lines")))))))

;;; --- imenu -----------------------------------------------------------------
;;; imenu lists the elements at point's level: the siblings of the element
;;; at point, each as its tag with its id or first class, and its text.

(define (html-element--attr head name)
  (let loop ((qs '("'" "\"")))
    (if (null? qs) #f
        (let ((i (string-index head (string-append " " name "=" (car qs)))))
          (if (not i) (loop (cdr qs))
              (let* ((from (+ i (string-length name) 3))
                     (end (string-index head (car qs) from)))
                (and end (substring head from end))))))))

(define (html-element--label n)
  (let* ((st (html-element--part n "start_tag"))
         (tn (and st (html-element--part st "tag_name")))
         (tag (if tn (buffer-substring (cadr tn) (caddr tn)) (car n)))
         (head (if st (buffer-substring (cadr st) (caddr st)) ""))
         (id (html-element--attr head "id"))
         (cls (html-element--attr head "class")))
    (cond (id (string-append tag "#" id))
          ((and cls (not (html-element--blank? cls))) (string-append tag "." (car (string-split (string-trim cls) " "))))
          (else tag))))

(define *html-element-entities*
  '(("&nbsp;" . " ") ("&middot;" . "·") ("&sect;" . "§") ("&rarr;" . "→")
    ("&times;" . "×") ("&mdash;" . "—") ("&apos;" . "'") ("&quot;" . "\"")
    ("&lt;" . "<") ("&gt;" . ">") ("&amp;" . "&")))

(define (html-element--summary n)
  (if (member (car n) '("script_element" "style_element")) ""
      (let* ((t (re-replace-all "<[^>]*>" (html-element--text n) " "))
             (t (let loop ((s t) (es *html-element-entities*)) (if (null? es) s (loop (string-replace s (caar es) (cdar es)) (cdr es)))))
             (t (string-trim (re-replace-all "\\s+" t " "))))
        (if (> (string-length t) 80) (string-append (substring t 0 79) "…") t))))

(define (html-element-imenu-rows buf)
  (with-current-buffer buf
    (lambda ()
      (map (lambda (n)
             (list (line-number-at-pos (cadr n))
                   (if (equal? (car n) "comment") "comment" "element")
                   (if (equal? (car n) "comment") "<!-- -->" (html-element--label n))
                   (html-element--summary n)))
           (html-element--level-nodes (buffer-point buf))))))

(define (html-element--mode-hook!)
  (buffer-set-local! (current-buffer) 'imenu-index-function 'html-element-imenu-rows)
  (when (boundp 'html-element-check!) (html-element-check! (current-buffer))))

(add-hook! 'html-mode-hook 'html-element--mode-hook!)

;;; --- checking, as flymake does ----------------------------------------------
;;; The grammar's own view of the file, as diagnostics: syntax errors, end
;;; tags that close nothing, elements left open, ids used twice. They go
;;; where the language servers' go, so the underline, the modeline count,
;;; lsp-next-diagnostic and lsp-diagnostics-list all show them. A save
;;; checks the file again.

(define *html-element-void*
  '("area" "base" "br" "col" "embed" "hr" "img" "input" "link" "meta" "param" "source" "track" "wbr"))

;; elements HTML lets end without an end tag
(define *html-element-optional-end*
  '("p" "li" "dt" "dd" "option" "optgroup" "tr" "td" "th" "thead" "tbody" "tfoot"
    "rp" "rt" "colgroup" "caption" "html" "head" "body"))

(define (html-element--diag s e sev msg) (list 'startByte s 'endByte e 'severity sev 'message msg))

(define (html-element--tag-of s)
  (let* ((head (buffer-substring s (min (+ s 40) (buffer-size (current-buffer)))))
         (m (re-find "<([A-Za-z][A-Za-z0-9-]*)" head 0)))
    ;; re-find answers the match as (START END) byte offsets
    (if m (string-downcase (substring-bytes head 1 (cadr m))) "")))

(define (html-element-diagnostics)
  (let* ((errors (map (lambda (c) (html-element--diag (cadr c) (caddr c) 1 "Syntax error"))
                      (ts-query "(ERROR) @e")))
         (stray (map (lambda (c) (html-element--diag (cadr c) (caddr c) 1
                                   (string-append (buffer-substring (cadr c) (caddr c)) " closes no open element")))
                     (ts-query "(erroneous_end_tag) @x")))
         (closed (map cdr (filter (lambda (c) (equal? (car c) "el")) (ts-query "(element (end_tag) @et) @el"))))
         (open (filter (lambda (c) (and (equal? (car c) "el") (not (member (cdr c) closed))))
                       (ts-query "(element) @el")))
         (unclosed (filter (lambda (d) d)
                     (map (lambda (c)
                            (let ((tag (html-element--tag-of (cadr c))))
                              (and (not (member tag *html-element-void*))
                                   (not (member tag *html-element-optional-end*))
                                   (let ((st-end (let ((t (buffer-substring (cadr c) (caddr c)))) (string-index t ">"))))
                                     (not (and st-end (> st-end 0) (equal? (buffer-substring (+ (cadr c) st-end -1) (+ (cadr c) st-end)) "/"))))
                                   (html-element--diag (cadr c) (+ (cadr c) 1 (string-byte-length tag)) 1
                                                       (string-append "<" tag "> is never closed")))))
                          open)))
         (ids (let loop ((cs (ts-query "(attribute (attribute_name) @an (quoted_attribute_value (attribute_value) @av))"))
                         (seen '()) (out '()))
                (cond ((or (null? cs) (null? (cdr cs))) (reverse out))
                      ((and (equal? (car (car cs)) "an") (equal? (car (cadr cs)) "av")
                            (equal? (buffer-substring (cadr (car cs)) (caddr (car cs))) "id"))
                       (let* ((v (cadr cs)) (val (buffer-substring (cadr v) (caddr v))))
                         (if (member val seen)
                             (loop (cddr cs) seen (cons (html-element--diag (cadr v) (caddr v) 2 (string-append "The id '" val "' is used twice")) out))
                             (loop (cddr cs) (cons val seen) out))))
                      (else (loop (cdr cs) seen out))))))
    (append errors stray unclosed ids)))

(define (html-element-check! buf)
  (when (and (buffer-exists? buf) (buffer-derived-mode? buf "html-mode") (boundp 'lsp--diagnostics!))
    (let ((ds (with-current-buffer buf (lambda () (html-element-diagnostics)))))
      (lsp--diagnostics! #f (list 'buffer buf 'diagnostics ds))
      (length ds))))

(define-command "html-check" "Check this HTML file and show what is wrong in it"
  (lambda ()
    (let ((n (html-element-check! (current-buffer))))
      (message (cond ((not n) "html-check needs the lsp package")
                     ((= n 0) "No problems")
                     (else (string-append (number->string n) " problem" (if (= n 1) "" "s") ": lsp-next-diagnostic walks them")))))))

(define (html-element--check-after-save!)
  (when (buffer-derived-mode? (current-buffer) "html-mode") (html-element-check! (current-buffer))))

(add-hook! 'after-save-hook 'html-element--check-after-save!)

;;; --- the rest of web-mode's keys --------------------------------------------

(define-command "html-element-children-fold" "Fold or unfold every element inside this one"
  (lambda ()
    (html-element--with
      (lambda (n)
        (let* ((buf (current-buffer))
               (rs (filter (lambda (r) r) (map html-element--fold-range (filter html-element--el? (html-element--kids n)))))
               (folded (fold-get buf 'html-element))
               (any (find (lambda (r) (member r folded)) rs)))
          (fold-set! buf 'html-element
                     (if any
                         (filter (lambda (r) (not (member r rs))) folded)
                         (append rs (filter (lambda (r) (not (member r rs))) folded)))))))))

(define-command "html-indent-buffer" "Indent every line of the buffer by its element"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-marker-local! buf 'html-indent-from)
      (buffer-set-local! buf 'html-indent-from (point)))
    (let loop ((l 1) (last (line-number-at-pos (buffer-size (current-buffer)))))
      (when (<= l last)
        (html-element--indent-line! (line-start-position l))
        (loop (+ l 1) last)))
    (goto-char! (buffer-local-value 'html-indent-from (current-buffer)))
    (message "Indented the buffer")))

(define (html-element--tags)
  (map cdr (filter (lambda (c) (equal? (car c) "t"))
                   (map (lambda (q) (cons (car q) (cdr q)))
                        (ts-query "[(start_tag) (end_tag) (self_closing_tag)] @t")))))

(define (html-element--tag-at pos)
  (find (lambda (r) (and (<= (car r) pos) (< pos (cadr r)))) (html-element--tags)))

(define-command "html-tag-beginning" "Go to the start of the tag at point"
  (lambda () (let ((r (html-element--tag-at (point)))) (if r (goto-char! (car r)) (message "No tag here")))))

(define-command "html-tag-end" "Go to the end of the tag at point"
  (lambda () (let ((r (html-element--tag-at (point)))) (if r (goto-char! (cadr r)) (message "No tag here")))))

(define-command "html-tag-next" "Go to the next tag"
  (lambda () (let ((r (find (lambda (r) (> (car r) (point))) (html-element--tags)))) (if r (goto-char! (car r)) (message "No next tag")))))

(define-command "html-tag-previous" "Go to the previous tag"
  (lambda () (let ((rs (filter (lambda (r) (< (car r) (point))) (html-element--tags))))
               (if (null? rs) (message "No previous tag")
                   (let ((r (car (reverse rs))))
                     ;; from inside a tag, the one before it
                     (goto-char! (car (if (and (<= (car r) (point)) (< (point) (cadr r)) (pair? (cdr (reverse rs)))) (cadr (reverse rs)) r))))))))

(define-command "html-tag-select" "Select the tag at point"
  (lambda () (let ((r (html-element--tag-at (point)))) (if r (begin (set-mark! (cadr r)) (goto-char! (car r))) (message "No tag here")))))

;; C-M-k and C-M-SPC reach as far as C-M-f goes, as kill-sexp and mark-sexp do
(define (html-element--forward-end)
  (let ((ks (filter (lambda (k) (> (caddr k) (point))) (html-element--level-nodes (point)))))
    (and (pair? ks) (caddr (car ks)))))

(define-command "html-element-kill-sexp" "Kill from point over the element after it, as kill-sexp"
  (lambda () (let ((e (html-element--forward-end))) (if e (kill-region-1 (point) e) (message "No element after point")))))

(define-command "html-element-mark-sexp" "Set the mark after the element after point, as mark-sexp"
  (lambda () (let ((e (html-element--forward-end))) (if e (begin (set-mark! e) (message "Mark set")) (message "No element after point")))))

;;; --- keys ------------------------------------------------------------------

;; web-mode's keymap: C-c C-e for elements, C-c C-t for tags, and the
;; sexp keys over elements, as web-mode's forward-sexp-function gives them
(define *html-element-keys*
  '(("C-c C-e a" "html-element-content-select")
    ("C-c C-e b" "html-element-beginning")
    ("C-c C-e c" "html-element-clone")
    ("C-c C-e d" "html-element-child")
    ("C-c C-e e" "html-element-end")
    ("C-c C-e f" "html-element-children-fold")
    ("C-c C-e k" "html-element-kill")
    ("C-c C-e n" "html-element-next")
    ("C-c C-e p" "html-element-previous")
    ("C-c C-e r" "html-element-rename")
    ("C-c C-e s" "html-element-select")
    ("C-c C-e t" "html-element-move-down")
    ("C-c C-e u" "html-element-parent")
    ("C-c C-e v" "html-element-vanish")
    ("C-c C-e w" "html-element-wrap")
    ("C-c C-t b" "html-tag-beginning")
    ("C-c C-t e" "html-tag-end")
    ("C-c C-t m" "html-tag-match")
    ("C-c C-t n" "html-tag-next")
    ("C-c C-t p" "html-tag-previous")
    ("C-c C-t s" "html-tag-select")
    ("C-c C-f" "html-element-fold")
    ;; not web-mode's, which has no way back from many folds
    ("C-c C-e F" "html-element-unfold-all")
    ("C-c C-i" "html-indent-buffer")
    ("C-c C-m" "html-element-select")
    ("C-c C-n" "html-tag-match")
    ("C-c ! n" "lsp-next-diagnostic")
    ("C-c ! p" "lsp-prev-diagnostic")
    ("C-c ! l" "lsp-diagnostics-list")
    ("TAB" "html-indent-line")
    ("C-M-\\" "html-indent-region")
    ("C-M-f" "html-element-forward")
    ("C-M-b" "html-element-backward")
    ("C-M-k" "html-element-kill-sexp")
    ("C-M-SPC" "html-element-mark-sexp")
    ("M-<up>" "html-element-up")
    ("M-<down>" "html-element-down")
    ;; html-edit's page and the source meet at the element at point
    ("M-." "html-edit-sync")))

(for-each (lambda (k) (define-key (mode-keymap "html-mode") (car k) (cadr k))) *html-element-keys*)

(public! 'html-element-imenu-rows "(html-element-imenu-rows BUF) — imenu rows (LINE KIND NAME DOC) for the elements at point's level in html buffer BUF")
(catalog-meta! 'function "html-element-imenu-rows" 'domain 'edit 'effects '(read))
(public! 'html-element-at "(html-element-at POS) — the smallest element around byte POS as (KIND START END), or #f; the current buffer must have the html grammar")
(public! 'html-element-parent "(html-element-parent NODE) — the element around NODE, or #f")
(public! 'html-element-sibling "(html-element-sibling NODE OP) — the element or comment beside NODE, OP 'next or 'prev, or #f")
(public! 'html-element-child "(html-element-child NODE) — the first element inside NODE, or #f")
(public! 'html-element-inner "(html-element-inner NODE) — (START END) of the bytes between NODE's tags, or #f")
(catalog-meta! 'function "html-element-at" 'domain 'edit 'effects '(read))
(catalog-meta! 'function "html-element-parent" 'domain 'edit 'effects '(read))
(catalog-meta! 'function "html-element-sibling" 'domain 'edit 'effects '(read))
(catalog-meta! 'function "html-element-child" 'domain 'edit 'effects '(read))
(catalog-meta! 'function "html-element-inner" 'domain 'edit 'effects '(read))

(provide 'html-element)
