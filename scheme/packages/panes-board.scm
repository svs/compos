;;; panes-board.scm --- the window model as a list: groups, their panes, the
;;; panes' windows, the windows' buffers. C-x w lists them. Two views: All,
;;; a section for every group as ibuffer has, and Group, this group's model. + zooms one
;;; level towards the row at point, - zooms back out; the verbs edit the model
;;; and the frame follows.

(require 'panes-mode)

(domain! 'windows)
(effects! '(write display))

(define *panes-board-buffer* "*panes*")

;; one window list per group, a member of it like any buffer: the one shown
;; here, else the group's own, made the first time
(define (panes-board-buffer)
  (let ((here (current-buffer)) (g (frame-group)))
    (if (and here (buffer-derived-mode? here "panes-list-mode"))
        here
        (or (find (lambda (b) (and (buffer-derived-mode? b "panes-list-mode") (equal? (buffer-group b) g))) (buffer-list))
            (let loop ((n 1))
              (let ((name (if (= n 1) *panes-board-buffer* (string-append *panes-board-buffer* "<" (number->string n) ">"))))
                (if (buffer-known? name)
                    (loop (+ n 1))
                    (begin (buffer-create name)
                           (when g (buffer-move-to-group! name g))
                           (with-current-buffer name (lambda () (set-mode! "panes-list-mode")))
                           name))))))))

;; the model the board shows: the group's, else the frame read in
(define (panes-board-layout) (or (panes-layout) (panes-adopt)))

;; row ids: g|GROUP, p|GROUP|PANE, w|GROUP|KEY, b|GROUP|KEY|BUFFER
(define (panes-board--gs g) (if (symbol? g) (symbol->string g) g))
(define (panes-board--g s) (if (equal? s "none") 'none s))
(define (panes-board--id kind g &rest more)
  (string-join (cons kind (cons (panes-board--gs g) more)) "|"))
(define (panes-board--split id)
  ;; at most four parts: a buffer name may hold the separator itself
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= (length acc) 3) (reverse (cons (substring id start (string-length id)) acc)))
          ((>= i (string-length id)) (reverse (cons (substring id start i) acc)))
          ((equal? (substring id i (+ i 1)) "|") (loop (+ i 1) (+ i 1) (cons (substring id start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (panes-board-kind id) (car (panes-board--split id)))
(define (panes-board-group id) (panes-board--g (cadr (panes-board--split id))))
;; the pane id of a p row, the window key of a w or b row
(define (panes-board-key id) (let ((ps (panes-board--split id))) (and (> (length ps) 2) (caddr ps))))
(define (panes-board-buffer-of id) (let ((ps (panes-board--split id))) (and (> (length ps) 3) (cadddr ps))))

(define (panes-board-here-group) (panes--group-key))
(define (panes-board-layout-of g)
  (if (equal? g (panes-board-here-group)) (panes-board-layout) (panes-layout-of g)))
(define (panes-board-row-layout id) (panes-board-layout-of (panes-board-group id)))

(define (panes-board-pane-of id)
  (let ((kind (panes-board-kind id)))
    (cond ((equal? kind "p") (panes-board-key id))
          ((member kind '("w" "b")) (let ((l (panes-board-row-layout id))) (and l (panes-pane-of l (panes-board-key id)))))
          (else #f))))

(define (panes-board-view buf) (or (buffer-local buf 'panes-board-view) 'all))
(define (panes-board-root buf) (buffer-local buf 'panes-board-root))

;; every group, as ibuffer lists them: this one first, then the rest most
;; recent first; a group with no model yet is a heading with nothing under it
(define (panes-board--groups)
  (let* ((here (panes-board-here-group))
         (all (append (group-ids-mru-all)
                      (filter (lambda (g) (panes-layout-of g)) (map car (panes--store))))))
    (cons here (reverse (fold (lambda (acc g) (if (or (equal? g here) (member g acc)) acc (cons g acc))) '() all)))))

(define (panes-board--open? buf id) (and (member id (or (buffer-local buf 'panes-board-open) '())) #t))
(define (panes-board--shut? buf id) (and (member id (or (buffer-local buf 'panes-board-shut) '())) #t))

(define (panes-board--toggle! buf var x)
  (let ((xs (or (buffer-local buf var) '())))
    (buffer-set-local! buf var (if (member x xs) (filter (lambda (y) (not (equal? y x))) xs) (cons x xs)))))

(define (panes-board--window-rows buf g l k force)
  (let ((id (panes-board--id "w" g k)))
    (cons id (if (or force (panes-board--open? buf id))
                 (map (lambda (b) (panes-board--id "b" g k b)) (panes-window-buffers l k))
                 '()))))

(define (panes-board--pane-rows buf g l pid force)
  (let ((id (panes-board--id "p" g pid)))
    (cons id (if (and (not force) (panes-board--shut? buf id))
                 '()
                 (apply append (map (lambda (k) (panes-board--window-rows buf g l k #f))
                                    (or (plist-get (panes-pane l pid) 'windows) '())))))))

(define (panes-board--group-rows buf g)
  (let ((l (panes-board-layout-of g)))
    (if (not l)
        '()
        (apply append (map (lambda (p) (panes-board--pane-rows buf g l (plist-get p 'id) #f)) (panes-panes l))))))

(define (panes-board--root-valid? root)
  (let* ((kind (panes-board-kind root)) (l (panes-board-row-layout root)))
    (cond ((equal? kind "g") (and l #t))
          ((equal? kind "p") (and l (panes-pane l (panes-board-key root)) #t))
          ((equal? kind "w") (and l (panes-window l (panes-board-key root)) #t))
          (else #f))))

;; the rows of the view, or of what it is zoomed to
(define (panes-board-ids buf)
  (let ((root (panes-board-root buf)))
    (cond ((and root (not (panes-board--root-valid? root)))
           ;; what it zoomed to is gone: back to the whole view
           (buffer-set-local! buf 'panes-board-root #f)
           (panes-board-ids buf))
          (root
           (let* ((kind (panes-board-kind root)) (g (panes-board-group root)) (l (panes-board-layout-of g)))
             (cond ((equal? kind "g") (cons root (panes-board--group-rows buf g)))
                   ((equal? kind "p") (panes-board--pane-rows buf g l (panes-board-key root) #t))
                   (else (panes-board--window-rows buf g l (panes-board-key root) #t)))))
          ((equal? (panes-board-view buf) 'all)
           (apply append
             (map (lambda (g)
                    (let ((id (panes-board--id "g" g)))
                      (cons id (if (panes-board--shut? buf id) '() (panes-board--group-rows buf g)))))
                  (panes-board--groups))))
          (else (panes-board--group-rows buf (panes-board-here-group))))))

;;; --- zoom ------------------------------------------------------------------------

;; the way from the top of the view down to a row: g p w. A buffer row's way
;; ends at its window
(define (panes-board--chain buf id)
  (let* ((kind (panes-board-kind id)) (g (panes-board-group id))
         (top (if (equal? (panes-board-view buf) 'all) (list (panes-board--id "g" g)) '())))
    (cond ((equal? kind "g") (list id))
          ((equal? kind "p") (append top (list id)))
          (else (let ((pid (panes-board-pane-of id)))
                  (append top (if pid (list (panes-board--id "p" g pid)) '())
                          (list (panes-board--id "w" g (panes-board-key id)))))))))

;; one level below the root on the way to the row; a buffer row in a view not
;; zoomed at all goes straight to its window
(define (panes-board-zoom-target buf id)
  (let* ((chain (panes-board--chain buf id))
         (root (panes-board-root buf))
         (below (if root (let ((m (member root chain))) (and m (cdr m))) chain)))
    (cond ((and (equal? (panes-board-kind id) "b") (not root)) (car (reverse chain)))
          ((pair? below) (car below))
          (else #f))))

(define (panes-board-zoom-parent buf root)
  (let ((kind (panes-board-kind root)) (g (panes-board-group root)))
    (cond ((equal? kind "w") (let ((pid (panes-board-pane-of root))) (and pid (panes-board--id "p" g pid))))
          ((equal? kind "p") (and (equal? (panes-board-view buf) 'all) (panes-board--id "g" g)))
          (else #f))))

(define (panes-board--label id)
  (let ((kind (panes-board-kind id)) (l (panes-board-row-layout id)))
    (cond ((equal? kind "g") (let ((g (panes-board-group id))) (or (and (string? g) (group-name g)) "no group")))
          ((equal? kind "p") (string-append "pane " (number->string (+ 1 (panes--index-of (panes-board-key id) (panes-pane-ids l))))))
          (else (let* ((k (panes-board-key id)) (h (panes-handle l k)))
                  (or (and h (window-exists? h) (boundp 'window-name) (window-name h))
                      (let ((m (panes-board--short (panes-window-mode l k)))) (and (not (equal? m "")) m))
                      k))))))

;; the trail from the view down to the root, for the title
(define (panes-board-trail buf)
  (let loop ((r (panes-board-root buf)) (acc '()))
    (if (not r) acc (loop (panes-board-zoom-parent buf r) (cons (panes-board--label r) acc)))))

(define (panes-board--depth buf id)
  ;; how far in a row sits below the top of what is shown
  (let* ((kind (panes-board-kind id))
         (d (cond ((equal? kind "g") 0) ((equal? kind "p") 1) ((equal? kind "w") 2) (else 3)))
         (root (panes-board-root buf))
         (top (cond (root (let ((k (panes-board-kind root))) (cond ((equal? k "g") 0) ((equal? k "p") 1) (else 2))))
                    ((equal? (panes-board-view buf) 'all) 0)
                    (else 1))))
    (max 0 (- d top))))

(define (panes-board--indent buf id)
  (let loop ((n (* 2 (panes-board--depth buf id))) (s ""))
    (if (<= n 0) s (loop (- n 1) (string-append s " ")))))

(define (panes-board--pct share) (string-append (number->string (round (* 100 share))) "%"))

(define (panes-board--short mode)
  (let ((m (or mode "")))
    (if (string-suffix? "-mode" m) (substring m 0 (- (string-length m) 5)) m)))

(define (panes-board-cells buf id)
  (let* ((kind (panes-board-kind id))
         (g (panes-board-group id))
         (here? (equal? g (panes-board-here-group)))
         (l (panes-board-layout-of g))
         (pad (panes-board--indent buf id)))
    (cond ((equal? kind "g")
           ;; a section heading, as ibuffer draws one
           (list (list (if (or (not l) (panes-board--shut? buf id)) "▸" "▾") (if here? "ok" "dim"))
                 (list (string-append pad (panes-board--label id)) "list-section-name")
                 (list (if here? "this group" "") "faint")
                 (list (if l
                           (string-append (number->string (length (panes-window-keys l))) " windows")
                           "no layout yet")
                       "dim")))
          ((not l) (list (list "" #f) (list id "faint") (list "" #f) (list "" #f)))
          ((equal? kind "p")
           (let* ((pid (panes-board-key id))
                  (p (panes-pane l pid))
                  (i (panes--index-of pid (panes-pane-ids l)))
                  ;; this group's panes as the frame draws them, the layout target's share included
                  (shares (if (and here? (= (length (panes--top-shares l)) (panes-pane-count l))) (panes--top-shares l) (panes-shares l)))
                  (share (list-ref shares i))
                  (me (and here? (any (lambda (k) (equal? (panes-handle l k) (active-window))) (or (plist-get p 'windows) '())))))
             (list (list (if here? "■" "□") (if here? "ok" "faint"))
                   (list (string-append pad (if (panes-board--shut? buf id) "▸ " "▾ ") (panes-board--label id)) (if me "accent" #f))
                   (list (panes-board--pct share) "faint")
                   (list (let ((n (length (or (plist-get p 'windows) '())))) (if (= n 0) "empty" (string-append (number->string n) " windows"))) "dim"))))
          ((equal? kind "w")
           (let* ((k (panes-board-key id))
                  (h (and here? (panes-handle l k)))
                  (on (and here? (member k (panes-top-windows l))))
                  (me (and h (equal? h (active-window)))))
             (list (list (cond (me "●") (on "■") (else "□")) (if on "ok" "faint"))
                   (list (string-append pad (if (or (panes-board--open? buf id) (equal? id (panes-board-root buf))) "▾ " "▸ ") (panes-board--label id)) (if me "accent" #f))
                   (list (panes-board--short (panes-window-mode l k)) "dim")
                   (list (string-append (number->string (length (panes-window-buffers l k))) " buffers") "faint"))))
          (else
            (let* ((k (panes-board-key id))
                   (b (panes-board-buffer-of id))
                   (top (equal? b (panes-window-buffer l k)))
                   (me (and top here? (equal? (panes-handle l k) (active-window)))))
              (list (list (if top "·" "") "faint")
                    (list (string-append pad (if (buffer-known? b) (buffer-modeline-name b) b)) (cond (me "accent") (top #f) (else "faint")))
                    (list (panes-board--short (panes--buffer-mode b)) "dim")
                    (list (if (and (buffer-known? b) (buffer-modified? b)) "modified" "") "faint")))))))

;; narrow, the name is the row: the mode column goes, and a name too long
;; gives up its "kind: " prefix before its end, never its middle
(define (panes-board-narrow-cells buf id)
  (let ((cells (panes-board-cells buf id)))
    (list (nth 0 cells) (nth 1 cells))))

(define (panes-board--trim s w)
  (let loop ((i 0))
    (if (and (< i (string-length s)) (member (substring s i (+ i 1)) '(" " "▸" "▾")))
        (loop (+ i 1))
        (let* ((lead (substring s 0 i))
               (parts (string-split (substring s i (string-length s)) ": ")))
          (list-fit (if (null? (cdr parts)) s (string-append lead "…" (string-join (cdr parts) ": ")))
                    w 'end)))))

(define (panes-board-refresh!) (list-refresh! (panes-board-buffer)))

;; edit the model with FN (layout id) -> layout, lay the frame out, redraw. Only
;; this group's model edits: another group's is drawn when that group is entered
(define (panes-board-edit! fn)
  (let ((id (list-current (panes-board-buffer))))
    (cond ((not id) (message "no row here"))
          ((not (equal? (panes-board-group id) (panes-board-here-group)))
           (message "That is another group's layout; enter the group to change it"))
          (else
            (let* ((l (panes-board-layout))
                   (next (fn l id)))
              (when (and next (not (equal? next l)))
                (let ((me (active-window)))
                  (panes-apply! next)
                  (when (window-exists? me) (select-window! me))))
              (panes-board-refresh!))))))

;;; --- the verbs -------------------------------------------------------------------

(define-command "panes-board-visit" "Show this window, or this buffer in its window, and go there"
  (lambda ()
    (let ((id (list-current (panes-board-buffer))))
      (cond ((not id) (message "no row here"))
            ((not (equal? (panes-board-group id) (panes-board-here-group)))
             (message "That window is in another group"))
            ((equal? (panes-board-kind id) "g") (message "This is the group you are in"))
            (else
              (let* ((l (panes-board-layout))
                     (kind (panes-board-kind id))
                     (key (if (equal? kind "p")
                              (let ((ks (plist-get (panes-pane l (panes-board-key id)) 'windows))) (and (pair? ks) (car ks)))
                              (panes-board-key id)))
                     ;; here: the pane the list stands in; the window takes its place
                     (me (panes-key-of-handle l (active-window)))
                     (pid (and me (panes-pane-of l me)))
                     (l (if (and me key (not (equal? me key))) (car (panes-pop l me)) l))
                     (l (if (and pid key (panes-pane l pid)) (panes-move-window l key pid 0) l))
                     (next (cond ((not key) l)
                                 ((equal? kind "b") (panes-show l key (panes-board-buffer-of id)))
                                 (else (panes-raise l key)))))
                (when key
                  (let* ((applied (panes-apply! next))
                         (h (panes-handle applied key)))
                    (when (and h (window-exists? h)) (select-window! h))))))))))

;; move the window on this row one pane over, on top of that pane's windows; a
;; pane row moves the pane. At the edge a window takes a new pane while there is room
(define (panes-board-shift! dir)
  (panes-board-edit!
    (lambda (l id)
      (let ((kind (panes-board-kind id)))
        (cond ((equal? kind "g") l)
              ((equal? kind "p")
               (let* ((pid (panes-board-key id)) (i (panes--index-of pid (panes-pane-ids l))))
                 (panes-move-pane l pid (+ i dir))))
              (else
                (let* ((key (panes-board-key id))
                       (from (panes-pane-of l key))
                       (ids (panes-pane-ids l))
                       (i (+ dir (panes--index-of from ids))))
                  (cond ((and (>= i 0) (< i (length ids))) (panes-move-window l key (list-ref ids i)))
                        ((not (panes-under-capacity? l)) (message "no pane that way") l)
                        (else
                          (let ((added (panes-add-pane l (if (< i 0) 0 (length ids)))))
                            (panes-move-window (car added) key (cadr added))))))))))))

(define-command "panes-board-left" "Move this window to the pane on its left; a pane row moves the pane"
  (lambda () (panes-board-shift! -1)))
(define-command "panes-board-right" "Move this window to the pane on its right; a pane row moves the pane"
  (lambda () (panes-board-shift! 1)))

(define-command "panes-board-close"
  "Close this window (its buffers stay open), take this buffer out of its window, or remove this pane"
  (lambda ()
    (panes-board-edit!
      (lambda (l id)
        (let ((kind (panes-board-kind id)))
          (cond ((equal? kind "g") l)
                ((equal? kind "p") (panes-remove-pane l (panes-board-key id)))
                ((equal? kind "w") (panes-close-window l (panes-board-key id)))
                (else
                  (let* ((key (panes-board-key id)) (b (panes-board-buffer-of id))
                         (left (panes--without b (panes-window-buffers l key))))
                    (if (null? left) (panes-close-window l key) (panes-set-buffers l key left))))))))))

(define-command "panes-board-add-pane" "Add an empty pane after the pane on this row"
  (lambda ()
    (panes-board-edit! (lambda (l id) (car (panes-add-empty-pane l (panes-board-pane-of id)))))))

(define-command "panes-board-kill" "Kill the buffer on this row"
  (lambda ()
    (let ((id (list-current (panes-board-buffer))))
      (if (and id (equal? (panes-board-kind id) "b"))
          (kill-buffer-confirm! (panes-board-buffer-of id) (lambda (done) (panes-board-refresh!)))
          (message "K on a buffer row kills it")))))

(define-command "panes-board-consolidate" "Give every mode one window"
  (lambda ()
    (panes-board-edit! (lambda (l id) (panes-consolidate l panes--buffer-mode)))))

(define (panes-board-resize! factor)
  (panes-board-edit!
    (lambda (l id)
      (let* ((pid (panes-board-pane-of id))
             (p (and pid (panes-pane l pid)))
             (share (and p (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1)))))
        (if p (panes-set-share l pid (* share factor)) l)))))

(define-command "panes-board-wider" "Give this pane more of the width" (lambda () (panes-board-resize! 1.25)))
(define-command "panes-board-narrower" "Give this pane less of the width" (lambda () (panes-board-resize! 0.8)))
(define-command "panes-board-equalize" "Every pane an equal share"
  (lambda () (panes-board-edit! (lambda (l id) (panes-equalize l)))))
(define-command "panes-board-refresh" "Redraw the board" (lambda () (panes-board-refresh!)))

(define-command "panes-board-fold" "Fold or unfold the group, pane or window on this row"
  (lambda ()
    (let* ((buf (panes-board-buffer))
           (id (list-current buf)))
      (when id
        (let ((kind (panes-board-kind id)))
          (cond ((member kind '("g" "p")) (panes-board--toggle! buf 'panes-board-shut id))
                ((equal? kind "w") (panes-board--toggle! buf 'panes-board-open id))
                (else (panes-board--toggle! buf 'panes-board-open (panes-board--id "w" (panes-board-group id) (panes-board-key id))))))
        (panes-board-refresh!)))))

(define-command "panes-board-fold-all" "Unfold every window, or fold them all when any is open"
  (lambda ()
    (let ((buf (panes-board-buffer)))
      (buffer-set-local! buf 'panes-board-shut '())
      (buffer-set-local! buf 'panes-board-open
        (if (pair? (or (buffer-local buf 'panes-board-open) '()))
            '()
            (apply append
              (map (lambda (g) (let ((l (panes-board-layout-of g)))
                                 (if l (map (lambda (k) (panes-board--id "w" g k)) (panes-window-keys l)) '())))
                   (panes-board--groups)))))
      (panes-board-refresh!))))

(define (panes-board--rezoom! buf root keep)
  ;; the row KEEP stays under the cursor when it is still shown
  (buffer-set-local! buf 'panes-board-root root)
  (when keep (buffer-set-local! buf 'list-selection-key keep))
  (list-refresh! buf))

(define-command "panes-board-zoom-in" "Zoom one level towards this row: a pane, a window"
  (lambda ()
    (let* ((buf (panes-board-buffer))
           (id (list-current buf))
           (target (and id (panes-board-zoom-target buf id))))
      (if target
          (panes-board--rezoom! buf target id)
          (message "Zoomed in as far as it goes")))))

(define-command "panes-board-zoom-out" "Zoom back out one level"
  (lambda ()
    (let* ((buf (panes-board-buffer))
           (root (panes-board-root buf)))
      (if root
          (panes-board--rezoom! buf (panes-board-zoom-parent buf root) root)
          (message "Zoomed out as far as it goes")))))

(define (panes-board--set-view! buf view)
  (buffer-set-local! buf 'panes-board-view view)
  (buffer-set-local! buf 'panes-board-root #f)
  (list-refresh! buf))

(define-command "panes-board-next-group" "Go to the next group's heading"
  (lambda () (list-move-section! (panes-board-buffer) 1)))
(define-command "panes-board-previous-group" "Go to the previous group's heading"
  (lambda () (list-move-section! (panes-board-buffer) -1)))

(define-command "panes-board-view-next" "Switch between the views: All, Group"
  (lambda () (let ((buf (panes-board-buffer)))
               (panes-board--set-view! buf (if (equal? (panes-board-view buf) 'all) 'group 'all)))))

(define-list-mode! "panes-list-mode"
  (list
    'doc (string-append
           "The windows as the model holds them, one section for every group, as ibuffer has: this group first, then the rest most recent first. `<left>`/`<right>` switch to Group, this group's panes alone, and back to All. `M-n`/`M-p` go from group to group. "
           "A pane holds windows (■ on screen, ● the one you are in, □ behind) and a window its buffers (· the one it shows). "
           "`+` zooms one level towards the row: a pane, then a window; on a buffer row it zooms to its window. `-` zooms back out. "
           "`<left>`/`<right>` switch the view. `TAB` folds a row, `S-TAB` every window. `RET` goes there, `k` closes a window or takes a buffer out of one, `K` kills a buffer, `c` gives every mode one window, `a` adds an empty pane, `{`/`}` resize a pane, `=` equalizes.")
    'buffer *panes-board-buffer*
    'rows panes-board-ids
    'section? (lambda (buf id) (equal? (panes-board-kind id) "g"))
    'layouts (list (list 'name 'wide 'min-cols 70
                         'columns (lambda (buf) (list (list "" 2) (list "what" 38) (list "mode" 16) (list "" #f)))
                         'cells panes-board-cells)
                   (list 'name 'narrow 'default #t
                         'columns (lambda (buf) (list (list "" 2) (list "what" #f 'left panes-board--trim)))
                         'cells panes-board-narrow-cells))
    'cells panes-board-cells
    'title (lambda (buf) (string-join (cons (if (equal? (panes-board-view buf) 'all) "Windows · All" "Windows · Group")
                                            (panes-board-trail buf))
                                      " › "))
    'meta (lambda (buf) (let ((l (panes-board-layout)))
                          (string-append (number->string (panes-pane-count l)) " panes, "
                                         (number->string (length (panes-window-keys l))) " windows here")))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "go") ("+/-" "zoom") ("<left>/<right>" "view") ("M-n/M-p" "group") ("TAB" "fold") ("k" "close")
                ("K" "kill") ("a" "add pane") ("c" "consolidate") ("{/}" "resize") ("q" "quit")))
    'keys '(("RET" "panes-board-visit") ("+" "panes-board-zoom-in") ("-" "panes-board-zoom-out")
            ("<left>" "panes-board-view-next") ("<right>" "panes-board-view-next")
            ("TAB" "panes-board-fold") ("S-TAB" "panes-board-fold-all")
            ("M-n" "panes-board-next-group") ("M-p" "panes-board-previous-group")
            ("k" "panes-board-close") ("K" "panes-board-kill") ("a" "panes-board-add-pane") ("c" "panes-board-consolidate")
            ("}" "panes-board-wider") ("{" "panes-board-narrower") ("=" "panes-board-equalize")
            ("g" "panes-board-refresh") ("q" "quit-window"))))

;; the list opened on VIEW, zoomed to ROOT (#f: the whole view)
(define (panes-board-open! view root)
  (let ((buf (panes-board-buffer))
        (here (and (panes-layout) (panes-key-of-handle (panes-layout) (active-window)))))
    (buffer-create buf)
    (with-current-buffer buf (lambda () (set-mode! "panes-list-mode")))
    (buffer-set-local! buf 'panes-board-view view)
    (buffer-set-local! buf 'panes-board-root root)
    ;; a buffer like any other: it opens in this window, and q goes back
    (switch-to-buffer! buf)
    (list-refresh! buf)
    ;; the list opens on the window you are in
    (let ((i (and here (list-index-of buf (list-entries buf) (panes-board--id "w" (panes-board-here-group) here)))))
      (when i (list-goto-index! buf i)))
    buf))

(define-command "windows-list" "List this group's panes and their windows; - zooms out to every group, + zooms in, <left>/<right> switch to Group"
  (lambda () (panes-board-open! 'all (panes-board--id "g" (panes-board-here-group)))))

;; the board follows the frame while it is on screen
(define (panes-board-follow!)
  (when (and (buffer-known? (panes-board-buffer)) (window-showing (panes-board-buffer)))
    (panes-board-refresh!)))
(add-hook! 'window-state-change-hook 'panes-board-follow!)
