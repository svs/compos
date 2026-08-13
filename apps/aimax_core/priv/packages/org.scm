;;; org.scm --- org-mode, written entirely in userland Scheme.
;;;
;;; Outline folding, headline fontification, TODO states, priorities,
;;; structure editing, checkboxes with statistics cookies. Built from the
;;; same primitives as dired plus overlays (overlay-set!), hidden ranges
;;; (fold-set!) and the change hook (on-change!).
;;;
;;; OFFSET RULE: every index that touches the buffer, an overlay, or a
;;; re-find/re-groups result is a BYTE offset. Use string-byte-length and
;;; substring-bytes on such indexes — never string-length/substring, which
;;; count graphemes and desync on non-ASCII text.
;;;
;;; De-dent extension (not in og org): a continuation line under a list
;;; item may sit at a shallower indent than the item's text — down to the
;;; bullet column — and still belongs to that item:
;;;   - foo
;;;     - bar
;;;       - baz
;;;       bing        <- continuation of baz, aligned with its bullet
;;; Scope scans only stop below the bullet's own indent, so normal org
;;; files parse identically. M-<left>/M-<right> on non-headline lines
;;; de-dent/indent by 2 columns.
;;;
;;; Keys (buffer-local):
;;;   TAB fold cycle · S-TAB overview/show-all · C-c C-t todo
;;;   M-RET new headline · C-RET headline after subtree
;;;   M-<left>/<right> promote/demote (or de-dent/indent a plain line)
;;;   M-S-<left>/<right> promote/demote subtree
;;;   M-<up>/<down> move subtree · S-<up>/<down> priority
;;;   C-c C-c toggle checkbox + recount cookies

;;; --- line model --------------------------------------------------------------

;; -> ((start-byte line-string) ...), in buffer order
(define (org-lines buf)
  (let loop ((ls (split-lines (buffer-text buf))) (pos 0) (acc '()))
    (if (null? ls)
        (reverse acc)
        (loop (cdr ls)
              (+ pos (string-byte-length (car ls)) 1)
              (cons (list pos (car ls)) acc)))))

;; the (start line) entry containing byte pos
(define (org-line-at buf pos)
  (let loop ((ls (org-lines buf)) (prev #f))
    (cond ((null? ls) prev)
          ((> (car (car ls)) pos) prev)
          (else (loop (cdr ls) (car ls))))))

;; headline level (count of leading stars) or #f
(define (org-heading-level line)
  (let ((m (re-match "^(\\*+)[ \t]" line)))
    (if m (string-byte-length (cadr m)) #f)))

;; leading-whitespace width in bytes
(define (org-indent line)
  (let ((g (re-groups "^([ \t]*)" line 0)))
    (cadr (cadr g))))

;; nearest headline at or before pos -> (start level) or #f
(define (org-enclosing-heading buf pos)
  (let loop ((ls (org-lines buf)) (best #f))
    (cond ((null? ls) best)
          ((> (car (car ls)) pos) best)
          (else
            (let ((lv (org-heading-level (cadr (car ls)))))
              (loop (cdr ls) (if lv (list (car (car ls)) lv) best)))))))

;; end of the subtree headed at hstart: the byte just before the next
;; headline of level <= level, else buffer end
(define (org-subtree-end buf hstart level)
  (let loop ((ls (org-lines buf)))
    (cond ((null? ls) (buffer-size buf))
          ((<= (car (car ls)) hstart) (loop (cdr ls)))
          (else
            (let ((lv (org-heading-level (cadr (car ls)))))
              (if (and lv (<= lv level))
                  (- (car (car ls)) 1)
                  (loop (cdr ls))))))))

;; replace one whole line; if point was on that line keep it in place
;; (clamped to the new end) — elsewhere the buffer's own adjustment wins
(define (org-replace-line! buf start old new)
  (unless (equal? old new)
    (let ((p (point))
          (old-len (string-byte-length old)))
      (buffer-delete-range! buf start old-len)
      (buffer-insert! buf start new)
      (when (and (>= p start) (<= p (+ start old-len)))
        (goto-char! (min p (+ start (string-byte-length new))))))))

;;; --- folding -----------------------------------------------------------------
;;; Fold state: buffer-local 'org-folds = headline start offsets. The
;;; Buffer's hidden ranges are DERIVED from it (org-apply-folds!) under the
;;; 'org tag, and the fold list is re-anchored + revalidated by the change
;;; hook — that's also what heals after undo swaps the rope underneath us.
;;; The local is the truth; the tag is only how it reaches the display, so
;;; the mode setup fn re-derives it after a restart.

(define (org-folds buf)
  (let ((f (buffer-local buf 'org-folds)))
    (if f f '())))

(define (org-valid-folds buf)
  (filter
    (lambda (h)
      (let ((ln (org-line-at buf h)))
        (and ln (= (car ln) h) (org-heading-level (cadr ln)))))
    (org-folds buf)))

(define (org-apply-folds! buf)
  (let ((folds (org-valid-folds buf)))
    (buffer-set-local! buf 'org-folds folds)
    (fold-set! buf 'org
      (map
        (lambda (h)
          (let* ((ln (org-line-at buf h))
                 (lv (org-heading-level (cadr ln)))
                 (eol (+ h (string-byte-length (cadr ln)))))
            (list eol (org-subtree-end buf h lv))))
        folds))))

(define (org-set-folds! buf folds)
  (buffer-set-local! buf 'org-folds folds)
  (org-apply-folds! buf))

(define (org-toggle-fold buf h)
  (if (member h (org-folds buf))
      (org-set-folds! buf (filter (lambda (x) (not (equal? x h))) (org-folds buf)))
      (org-set-folds! buf (cons h (org-folds buf)))))

(define-command "org-cycle" "Toggle folding of the headline at point, else indent"
  (lambda ()
    (let* ((buf (current-buffer))
           (ln (org-line-at buf (point))))
      (if (and ln (org-heading-level (cadr ln)))
          (org-toggle-fold buf (car ln))
          (run-command "indent-for-tab")))))

(define-command "org-global-cycle" "Cycle global visibility: overview or show all"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (null? (org-folds buf))
          (begin
            (org-set-folds! buf
              (map car (filter (lambda (ln) (org-heading-level (cadr ln)))
                               (org-lines buf))))
            ;; point may be in a now-hidden body — surface it on its headline
            (let ((h (org-enclosing-heading buf (point))))
              (when h (goto-char! (car h))))
            (message "OVERVIEW"))
          (begin
            (org-set-folds! buf '())
            (message "SHOW ALL"))))))

(define (org-unfold-all! buf)
  (org-set-folds! buf '()))

;;; --- fontification -----------------------------------------------------------

(set-face-attribute! 'org-level-1 'fg "#26356b" 'weight "700")
(set-face-attribute! 'org-level-2 'fg "#7a5a1a" 'weight "600")
(set-face-attribute! 'org-level-3 'fg "#3d6b4f" 'weight "600")
(set-face-attribute! 'org-level-4 'fg "#6b3d5b" 'weight "600")
(set-face-attribute! 'org-todo 'fg "#a03020" 'weight "700")
(set-face-attribute! 'org-done 'fg "#3d6b4f" 'decoration "line-through")
(set-face-attribute! 'org-priority 'fg "#7a5a1a" 'weight "600")
(set-face-attribute! 'org-date 'fg "#26356b" 'style "italic")
(set-face-attribute! 'org-tag 'fg "#8a857a")
(set-face-attribute! 'org-checkbox 'fg "#26356b" 'weight "600")
(set-face-attribute! 'org-cookie 'fg "#7a5a1a")
(set-face-attribute! 'org-meta 'fg "#8a857a")
(set-face-attribute! 'fold-marker 'fg "#8a857a")

;; sub-spans (todo/priority/tags/dates...) REPLACE the headline face over
;; their range rather than stacking on it — overlapping classes would
;; leave the winner to CSS rule order. Gaps between spans get `face`.
(define (org-fill-gaps spans s e face)
  (let loop ((sp (sort spans)) (cur s) (acc '()))
    (cond ((null? sp)
           (reverse (if (< cur e) (cons (list cur e face) acc) acc)))
          (else
            (let* ((one (car sp)) (os (car one)) (oe (cadr one)))
              (loop (cdr sp)
                    (max cur oe)
                    (cons one
                          (if (< cur os) (cons (list cur os face) acc) acc))))))))

;; absolute spans for one line at byte offset `start`
(define (org-line-spans start line)
  (let ((lv (org-heading-level line))
        (len (string-byte-length line))
        (abs (lambda (r) (list (+ start (car r)) (+ start (cadr r))))))
    (cond
      ((= len 0) '())
      (lv
       (let* ((face (string->symbol
                      (string-append "org-level-"
                        (number->string (+ 1 (modulo (- lv 1) 4))))))
              (kw (re-groups "^\\*+[ \t]+(TODO|DONE)[ \t]" line 0))
              (pr (re-find "\\[#[A-Z]\\]" line 0))
              (tg (re-groups "[ \t](:[A-Za-z0-9_@:]+:)[ \t]*$" line 0))
              (subs '()))
         (when kw
           (let ((r (cadr kw)))
             (set! subs (cons (list (+ start (car r)) (+ start (cadr r))
                                    (if (equal? (substring-bytes line (car r) (cadr r)) "TODO")
                                        "org-todo" "org-done"))
                              subs))))
         (when pr
           (set! subs (cons (append (abs pr) '("org-priority")) subs)))
         (when tg
           (let ((r (cadr tg)))
             (set! subs (cons (list (+ start (car r)) (+ start (cadr r)) "org-tag") subs))))
         (for-each
           (lambda (r) (set! subs (cons (append (abs r) '("org-cookie")) subs)))
           (re-find* "\\[[0-9]*(/[0-9]*|[0-9]*%)\\]" line))
         (org-fill-gaps subs start (+ start len) (symbol->string face))))
      ((re-match "^[ \t]*#\\+" line)
       (list (list start (+ start len) "org-meta")))
      (else
       (let ((boxes
               (let ((m (re-groups "^[ \t]*[-+] (\\[[ xX]\\])" line 0)))
                 (if m
                     (let ((r (cadr m)))
                       (list (list (+ start (car r)) (+ start (cadr r)) "org-checkbox")))
                     '())))
             (dates (map (lambda (r) (append (abs r) '("org-date")))
                         (re-find* "[<\\[][0-9]{4}-[0-9]{2}-[0-9]{2}[^\\]>\n]*[>\\]]" line)))
             (cookies (map (lambda (r) (append (abs r) '("org-cookie")))
                           (re-find* "\\[([0-9]*/[0-9]*|[0-9]+%)\\]" line))))
         (append boxes dates cookies))))))

(define (org-refontify! buf)
  (when (buffer-exists? buf)
    (overlay-set! buf 'org
      (fold (lambda (acc ln)
              (append acc (org-line-spans (car ln) (cadr ln))))
            '()
            (org-lines buf)))))

;;; --- change hook -------------------------------------------------------------

(define (org-after-change buf pos inserted deleted source)
  (when (buffer-exists? buf)
    ;; re-anchor folds through the edit, then validation prunes the dead
    (let ((delta (- (string-byte-length inserted) deleted)))
      (unless (= delta 0)
        (buffer-set-local! buf 'org-folds
          (map (lambda (h) (if (>= h pos) (max pos (+ h delta)) h))
               (org-folds buf)))))
    (org-apply-folds! buf)
    (org-refontify! buf)))

;;; --- TODO / priority ---------------------------------------------------------

(define (org-on-heading-line f)
  ;; run (f buf start line level) with point's line if it is a headline
  (let* ((buf (current-buffer))
         (ln (org-line-at buf (point))))
    (if (and ln (org-heading-level (cadr ln)))
        (f buf (car ln) (cadr ln) (org-heading-level (cadr ln)))
        (message "Not on a headline"))))

(define-command "org-todo" "Cycle the TODO state of the headline at point"
  (lambda ()
    (org-on-heading-line
      (lambda (buf start line lv)
        (let* ((g (re-groups "^(\\*+[ \t]+)(TODO[ \t]+|DONE[ \t]+)?" line 0))
               (pre (cadr g))
               (kw (caddr g))
               (head (substring-bytes line 0 (cadr pre)))
               (rest (substring-bytes line (if kw (cadr kw) (cadr pre))
                                      (string-byte-length line)))
               (cur (if kw (substring-bytes line (car kw) (+ (car kw) 4)) "")))
          (org-replace-line! buf start line
            (string-append head
              (cond ((equal? cur "") "TODO ")
                    ((equal? cur "TODO") "DONE ")
                    (else ""))
              rest))
          (org-refontify! buf))))))

(define (org-priority-cycle dir)
  (org-on-heading-line
    (lambda (buf start line lv)
      (let* ((g (re-groups "^(\\*+[ \t]+(?:TODO[ \t]+|DONE[ \t]+)?)(\\[#[A-Z]\\][ \t]*)?" line 0))
             (pre (cadr g))
             (pri (caddr g))
             (head (substring-bytes line 0 (cadr pre)))
             (rest (substring-bytes line (if pri (cadr pri) (cadr pre))
                                    (string-byte-length line)))
             (cur (if pri (substring-bytes line (+ (car pri) 2) (+ (car pri) 3)) #f))
             (next (if (equal? dir 'up)
                       (cond ((equal? cur #f) "A")
                             ((equal? cur "A") "B")
                             ((equal? cur "B") "C")
                             (else #f))
                       (cond ((equal? cur #f) "C")
                             ((equal? cur "C") "B")
                             ((equal? cur "B") "A")
                             (else #f)))))
        (org-replace-line! buf start line
          (string-append head (if next (string-append "[#" next "] ") "") rest))
        (org-refontify! buf)))))

(define-command "org-priority-up" "Increase the priority of the current item"
  (lambda () (org-priority-cycle 'up)))
(define-command "org-priority-down" "Decrease the priority of the current item"
  (lambda () (org-priority-cycle 'down)))

;;; --- structure editing -------------------------------------------------------

(define (org-star-shift line n)
  ;; add (n=1) or strip (n=-1) one leading star
  (if (= n 1)
      (string-append "*" line)
      (substring-bytes line 1 (string-byte-length line))))

(define (org-shift-indent line n)
  ;; de-dent/indent a plain line by 2 columns (the de-dent extension)
  (if (> n 0)
      (string-append "  " line)
      (let ((i (org-indent line)))
        (substring-bytes line (min i 2) (string-byte-length line)))))

(define (org-promote-demote n)
  (let* ((buf (current-buffer))
         (ln (org-line-at buf (point))))
    (cond ((not ln) #f)
          ((org-heading-level (cadr ln))
           (let ((lv (org-heading-level (cadr ln))))
             (if (and (= n -1) (= lv 1))
                 (message "Already a top-level headline")
                 (begin
                   (org-replace-line! buf (car ln) (cadr ln)
                                      (org-star-shift (cadr ln) n))
                   (org-apply-folds! buf)
                   (org-refontify! buf)))))
          (else
            (org-replace-line! buf (car ln) (cadr ln)
                               (org-shift-indent (cadr ln) n))
            (org-refontify! buf)))))

(define-command "org-promote" "Promote the headline at point, or de-dent the line"
  (lambda () (org-promote-demote -1)))
(define-command "org-demote" "Demote the headline at point, or indent the line"
  (lambda () (org-promote-demote 1)))

(define (org-subtree-shift n)
  (org-on-heading-line
    (lambda (buf start line lv)
      (if (and (= n -1) (= lv 1))
          (message "Already a top-level headline")
          (let ((end (org-subtree-end buf start lv)))
            (org-unfold-all! buf)
            ;; bottom-up so earlier offsets stay valid
            (for-each
              (lambda (ln2)
                (when (and (>= (car ln2) start)
                           (org-heading-level (cadr ln2)))
                  (org-replace-line! buf (car ln2) (cadr ln2)
                                     (org-star-shift (cadr ln2) n))))
              (reverse
                (filter (lambda (l) (and (>= (car l) start) (<= (car l) end)))
                        (org-lines buf))))
            (org-refontify! buf))))))

(define-command "org-promote-subtree" "Promote the entire subtree at point"
  (lambda () (org-subtree-shift -1)))
(define-command "org-demote-subtree" "Demote the entire subtree at point"
  (lambda () (org-subtree-shift 1)))

;; swap [s1,e1) with the adjacent [e1,e2); returns nothing useful.
;; Normalizes a missing trailing newline on the second block (last
;; subtree of a file that doesn't end in \n).
(define (org-swap-adjacent! buf s1 e1 e2)
  (let* ((t (buffer-text buf))
         (a (substring-bytes t s1 e1))
         (b0 (substring-bytes t e1 e2))
         (added (not (string-suffix? "\n" b0)))
         (b (if added (string-append b0 "\n") b0))
         (combined (string-append b a))
         (out (if added
                  (substring-bytes combined 0 (- (string-byte-length combined) 1))
                  combined)))
    (buffer-delete-range! buf s1 (- e2 s1))
    (buffer-insert! buf s1 out)
    (string-byte-length b)))

(define (org-next-sibling buf h lv)
  (let ((end (org-subtree-end buf h lv)))
    (if (>= (+ end 1) (buffer-size buf))
        #f
        (let* ((ln (org-line-at buf (+ end 1)))
               (l2 (org-heading-level (cadr ln))))
          (if (and l2 (= l2 lv)) (car ln) #f)))))

(define (org-prev-sibling buf h lv)
  (let loop ((ls (org-lines buf)) (cand #f))
    (cond ((null? ls) cand)
          ((>= (car (car ls)) h) cand)
          (else
            (let ((l2 (org-heading-level (cadr (car ls)))))
              (cond ((and l2 (= l2 lv)) (loop (cdr ls) (car (car ls))))
                    ((and l2 (< l2 lv)) (loop (cdr ls) #f))
                    (else (loop (cdr ls) cand))))))))

(define (org-block-end buf h lv)
  ;; subtree end as an EXCLUSIVE offset (past the trailing newline)
  (min (+ (org-subtree-end buf h lv) 1) (buffer-size buf)))

(define-command "org-move-subtree-down" "Move the subtree down past its next sibling"
  (lambda ()
    (org-on-heading-line
      (lambda (buf start line lv)
        (let ((sib (org-next-sibling buf start lv)))
          (if (not sib)
              (message "No following same-level subtree")
              (begin
                (org-unfold-all! buf)
                (let* ((e1 (org-block-end buf start lv))
                       (e2 (org-block-end buf sib lv))
                       (blen (org-swap-adjacent! buf start e1 e2)))
                  (goto-char! (+ start blen))
                  (org-refontify! buf)))))))))

(define-command "org-move-subtree-up" "Move the subtree up past its previous sibling"
  (lambda ()
    (org-on-heading-line
      (lambda (buf start line lv)
        (let ((sib (org-prev-sibling buf start lv)))
          (if (not sib)
              (message "No preceding same-level subtree")
              (begin
                (org-unfold-all! buf)
                (let* ((e1 start)
                       (e2 (org-block-end buf start lv)))
                  (org-swap-adjacent! buf sib e1 e2)
                  (goto-char! sib)
                  (org-refontify! buf)))))))))

;;; --- new headlines -----------------------------------------------------------

(define (org-current-level buf)
  (let ((h (org-enclosing-heading buf (point))))
    (if h (cadr h) 1)))

(define-command "org-meta-return" "Insert a new headline at the current level"
  (lambda ()
    (let* ((buf (current-buffer))
           (lv (org-current-level buf)))
      (end-of-line!)
      (insert! (string-append "\n" (string-repeat "*" lv) " ")))))

(define-command "org-insert-heading-after-subtree" "Insert a headline after the subtree"
  (lambda ()
    (let* ((buf (current-buffer))
           (h (org-enclosing-heading buf (point))))
      (if (not h)
          (begin (end-of-buffer!) (insert! "\n* "))
          (let* ((end (org-block-end buf (car h) (cadr h)))
                 (at-eob (= end (buffer-size buf)))
                 (ends-nl (or (= end 0)
                              (equal? (substring-bytes (buffer-text buf) (- end 1) end) "\n"))))
            (goto-char! end)
            (insert! (string-append
                       (if ends-nl "" "\n")
                       (string-repeat "*" (cadr h)) " "))
            (unless at-eob (begin (insert! "\n") (backward-char!))))))))

;;; --- checkboxes + statistics cookies ----------------------------------------

(define (org-checkbox-parts line)
  ;; -> ((box-start box-end) state-char) or #f — box includes the brackets
  (let ((g (re-groups "^[ \t]*[-+] (\\[([ xX])\\])" line 0)))
    (if g
        (list (cadr g)
              (substring-bytes line (car (caddr g)) (cadr (caddr g))))
        #f)))

;; scope of a parent line: for a headline its subtree; for a list item,
;; following lines until indent drops below the ITEM'S OWN indent (the
;; de-dent rule: continuation may sit as shallow as the bullet column)
(define (org-scope-lines buf start line)
  (let ((lv (org-heading-level line)))
    (if lv
        (let ((end (org-subtree-end buf start lv)))
          (filter (lambda (l) (and (> (car l) start) (<= (car l) end)))
                  (org-lines buf)))
        (let ((i (org-indent line)))
          (let loop ((ls (org-lines buf)) (acc '()))
            (cond ((null? ls) (reverse acc))
                  ((<= (car (car ls)) start) (loop (cdr ls) acc))
                  (else
                    (let ((l2 (car ls)))
                      (if (or (org-heading-level (cadr l2))
                              (and (not (equal? (string-trim (cadr l2)) ""))
                                   (< (org-indent (cadr l2)) i)))
                          (reverse acc)
                          (loop (cdr ls) (cons l2 acc)))))))))))

;; recount [n/m] / [p%] cookies on the nearest enclosing parent (a lesser-
;; indented bullet line with a cookie, else the enclosing headline)
(define (org-update-cookies! buf item-start item-line)
  (let* ((i (org-indent item-line))
         (parent
           (let loop ((ls (org-lines buf)) (cand #f))
             (cond ((null? ls) cand)
                   ((>= (car (car ls)) item-start) cand)
                   (else
                     (let* ((l2 (car ls)) (txt (cadr l2)))
                       (loop (cdr ls)
                             (if (and (re-match "\\[([0-9]*/[0-9]*|[0-9]*%)\\]" txt)
                                      (or (org-heading-level txt)
                                          (and (re-match "^[ \t]*[-+] " txt)
                                               (< (org-indent txt) i))))
                                 l2
                                 cand))))))))
    (when parent
      (let* ((kids (filter (lambda (l) (org-checkbox-parts (cadr l)))
                           (org-scope-lines buf (car parent) (cadr parent))))
             (total (length kids))
             (done (length (filter (lambda (l)
                                     (let ((p (org-checkbox-parts (cadr l))))
                                       (not (equal? (cadr p) " "))))
                                   kids)))
             (txt (cadr parent))
             (old (re-find "\\[([0-9]*/[0-9]*|[0-9]*%)\\]" txt 0))
             (is-pct (string-contains? (substring-bytes txt (car old) (cadr old)) "%"))
             (new-cookie
               (if is-pct
                   (string-append "["
                     (number->string (if (= total 0) 0 (quotient (* done 100) total))) "%]")
                   (string-append "[" (number->string done) "/" (number->string total) "]"))))
        (org-replace-line! buf (car parent) txt
          (string-append (substring-bytes txt 0 (car old))
                         new-cookie
                         (substring-bytes txt (cadr old) (string-byte-length txt))))))))

(define-command "org-ctrl-c-ctrl-c" "Toggle the checkbox at point and update cookies"
  (lambda ()
    (let* ((buf (current-buffer))
           (ln (org-line-at buf (point)))
           (cb (and ln (org-checkbox-parts (cadr ln)))))
      (if (not cb)
          (message "Nothing to do here")
          (let* ((line (cadr ln))
                 (r (car cb))
                 (new-state (if (equal? (cadr cb) " ") "X" " "))
                 (new (string-append (substring-bytes line 0 (car r))
                                     (string-append "[" new-state "]")
                                     (substring-bytes line (cadr r) (string-byte-length line)))))
            (org-replace-line! buf (car ln) line new)
            (org-update-cookies! buf (car ln) new)
            (org-refontify! buf))))))

;;; --- the mode ----------------------------------------------------------------

(define (org-install-keys)
  (local-set-key "TAB" "org-cycle")
  (local-set-key "S-TAB" "org-global-cycle")
  (local-set-key "C-c C-t" "org-todo")
  (local-set-key "M-RET" "org-meta-return")
  (local-set-key "C-RET" "org-insert-heading-after-subtree")
  (local-set-key "M-<left>" "org-promote")
  (local-set-key "M-<right>" "org-demote")
  (local-set-key "M-S-<left>" "org-promote-subtree")
  (local-set-key "M-S-<right>" "org-demote-subtree")
  (local-set-key "M-<up>" "org-move-subtree-up")
  (local-set-key "M-<down>" "org-move-subtree-down")
  (local-set-key "S-<up>" "org-priority-up")
  (local-set-key "S-<down>" "org-priority-down")
  (local-set-key "C-c C-c" "org-ctrl-c-ctrl-c"))

;; change-hook registry keyed by buffer NAME in global state (not a
;; buffer-local): rules outlive buffer kill + recreate (revert-buffer),
;; so re-entering the mode must not stack duplicates
(define *org-hooks* '())

(define (org-ensure-hook! buf)
  (unless (assoc buf *org-hooks*)
    (set! *org-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (org-after-change buf pos inserted deleted source))))
            *org-hooks*))))

(defgroup 'org "Org mode.")

;; re-apply the font remap to every live org buffer so customize changes
;; (including ones made by the LLM's tools) repaint immediately
(define (org--apply-fonts! _v)
  (for-each
    (lambda (buf)
      (if (equal? (buffer-local buf 'mode-name) "org-mode")
          (face-remap-in! buf 'default
            (list 'family org-font-family
                  'size org-font-size
                  'line-height "1.75"))))
    (buffer-list)))

(defcustom 'org-font-family "Spectral, Georgia, serif"
  "Font family for org-mode buffer text."
  'group 'org 'type 'string 'set org--apply-fonts!)

(defcustom 'org-font-size "14.5px"
  "Font size for org-mode buffer text (any CSS size)."
  'group 'org 'type 'string 'set org--apply-fonts!)

(define-mode "org-mode"
  (lambda ()
    (org-install-keys)
    (org-ensure-hook! (current-buffer))
    ;; prose reads better in the serif at a roomier measure; customizable
    ;; (already-open org buffers pick changes up on revisit or set-mode!)
    (buffer-face! 'family org-font-family
                  'size org-font-size
                  'line-height "1.75")
    ;; Hidden ranges die with the daemon; the 'org-folds local survives.
    ;; Re-derive them here, or a restored org buffer comes back fully
    ;; unfolded and stays that way until the next edit.
    (org-apply-folds! (current-buffer))
    (org-refontify! (current-buffer))))
