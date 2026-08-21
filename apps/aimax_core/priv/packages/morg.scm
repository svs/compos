;;; morg.scm --- markdown with org habits.
;;;
;;; morg-mode is a superset of the plain markdown experience. TAB folds a
;;; `#` heading's subtree or a fenced code block. S-TAB folds the whole
;;; file. morg-babel runs fenced blocks. morg-tangle writes marked blocks
;;; to source files. Fenced code renders with the theme's ts-* faces through
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

(define (morg-fence-close? line)
  (re-match "^[ \t]*```[ \t]*$" line))

;; entry accessors: an entry is (start line kind info)
;;   kind 'heading — info is the level (1..6)
;;   kind 'open    — info is the block's language ("" when unnamed)
;;   kind 'code    — info is the enclosing block's language
;;   kind 'close / 'text — info is #f
(define (morg-kind e) (caddr e))
(define (morg-info e) (car (cdr (cdr (cdr e)))))

;; classify every line with the fence state carried through the walk, so
;; a `# comment` inside a code block never reads as a heading
(define (morg-scan buf)
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
            ((re-match "^#{1,6}[ \t]" line)
             (let ((m (re-groups "^(#+)" line 0)))
               (loop (cdr ls) #f
                     (cons (list start line 'heading
                                 (- (cadr (cadr m)) (car (cadr m))))
                           acc))))
            (else
             (loop (cdr ls) #f (cons (list start line 'text #f) acc))))))))

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

(set-face-attribute! 'morg-code 'fg "#3d6b4f")
(set-face-attribute! 'morg-bold 'weight "700")
(set-face-attribute! 'morg-italic 'style "italic")
(set-face-attribute! 'morg-result 'fg "#8a857a")

;; markdown info string -> loaded tree-sitter language, or #f
(define *morg-ts-aliases*
  '(("js" "javascript") ("jsx" "javascript") ("ts" "typescript")
    ("py" "python") ("sh" "bash") ("shell" "bash")
    ("ex" "elixir") ("exs" "elixir")))

(define (morg-ts-lang lang)
  (let* ((l (string-downcase lang))
         (a (assoc l *morg-ts-aliases*))
         (l2 (if a (cadr a) l)))
    (if (member l2 (ts-langs)) l2 #f)))

;; spans for one scan entry; block BODIES are highlighted per block in
;; morg-refontify!, because a multi-line construct needs the whole body
(define (morg-line-spans e)
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
      ((equal? k 'open) (list (list start (+ start len) "org-meta")))
      ((equal? k 'close) (list (list start (+ start len) "org-meta")))
      ((equal? k 'code)
       (if (equal? (morg-info e) "result")
           (list (list start (+ start len) "morg-result"))
           '()))
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
  (when (buffer-exists? buf)
    (let* ((scan (morg-scan buf))
           (text (buffer-text buf))
           (line-spans
             (fold (lambda (acc e) (append acc (morg-line-spans e))) '() scan))
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
               (morg-blocks scan buf))))
      (overlay-set! buf 'morg (append line-spans code-spans)))))

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
               (morg-folds buf)))))
    (morg-apply-folds! buf)
    (morg-refontify! buf)))

;;; --- the mode ----------------------------------------------------------------

(effects! '(write))

(define (morg-install-keys)
  (local-set-key "TAB" "morg-cycle")
  (local-set-key "S-TAB" "morg-global-cycle")
  (local-set-key "C-c C-t" "morg-todo")
  (local-set-key "C-c C-c" "morg-babel")
  (local-set-key "C-c C-x" "morg-tangle"))

;; change-hook registry keyed by buffer NAME in global state (not a
;; buffer-local): rules outlive buffer kill + recreate (revert-buffer),
;; so re-entering the mode must not stack duplicates
(define *morg-hooks* '())

(define (morg-ensure-hook! buf)
  (unless (assoc buf *morg-hooks*)
    (set! *morg-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (morg-after-change buf pos inserted deleted source))))
            *morg-hooks*))))

(mode-doc! "morg-mode"
  "Markdown with org habits. `TAB` folds a heading or code block. `C-c C-c` runs a block. `C-c C-x` tangles marked blocks. `C-c C-v` renders the page.")

(mode-icon! "morg-mode" "")

(define-mode "morg-mode"
  (lambda ()
    ;; Morg includes prose presentation, but not workspace layout.
    (enable-minor-mode! (current-buffer) "writing-mode")
    (morg-install-keys)
    (morg-ensure-hook! (current-buffer))
    ;; Hidden ranges die with the daemon; the 'morg-folds local survives.
    ;; Re-derive them here, or a restored buffer comes back unfolded.
    (morg-apply-folds! (current-buffer))
    (morg-refontify! (current-buffer))))
