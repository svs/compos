;;; panes.scm --- the window model: a row of panes, each a stack of windows,
;;; each a stack of buffers. One value per (group, frame).
;;;
;;; The value is plain data, so it saves with the group and reads back:
;;;
;;;   LAYOUT = (panes (PANE ...) windows (WINDOW ...) next N capacity C)
;;;   PANE   = (id ID share S windows (KEY ...))       the first KEY is on screen
;;;   WINDOW = (key KEY win HANDLE mode MODE buffers (B ...) preferred BOOL)
;;;                                                   the first B is shown
;;;
;;; A window's KEY is its identity; HANDLE is the renderer's window id,
;;; attached while the window is on screen and dropped when the value is
;;; saved. Every function here is pure: it takes a layout and answers a
;;; new one. The applier (panes-apply!) is the one place that touches the
;;; frame. A policy (define-window-policy!) decides where a buffer opens;
;;; the model does not.

(domain! 'windows)
(effects! '(pure))

;;; --- small helpers --------------------------------------------------------

(define (panes--put plist key val) (plist-put plist key val))

(define (panes--index-of x lst)
  (let loop ((l lst) (i 0))
    (cond ((null? l) #f)
          ((equal? (car l) x) i)
          (else (loop (cdr l) (+ i 1))))))

(define (panes--without x lst) (filter (lambda (y) (not (equal? y x))) lst))

(define (panes--insert-at lst i x)
  (let ((i (max 0 (min i (length lst)))))
    (append (take lst i) (list x) (list-tail lst i))))

(define (panes--uniq lst)
  (let loop ((l lst) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) acc) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

;;; --- the layout -------------------------------------------------------------

(define panes-default-capacity 3)

;; an empty layout: no pane, no window
(define (panes-empty &optional capacity)
  (list 'panes '() 'windows '() 'next-pane 1 'next-window 1 'capacity (or capacity panes-default-capacity)))

(define (panes-capacity layout) (or (plist-get layout 'capacity) panes-default-capacity))
(define (panes-set-capacity layout n) (panes--put layout 'capacity n))

(define (panes-panes layout) (or (plist-get layout 'panes) '()))
(define (panes-windows layout) (or (plist-get layout 'windows) '()))
(define (panes-pane-ids layout) (map (lambda (p) (plist-get p 'id)) (panes-panes layout)))
(define (panes-pane-count layout) (length (panes-panes layout)))

(define (panes-pane layout id)
  (find (lambda (p) (equal? (plist-get p 'id) id)) (panes-panes layout)))

(define (panes-window layout key)
  (find (lambda (w) (equal? (plist-get w 'key) key)) (panes-windows layout)))

;; the keys of every window, pane by pane, the one on screen first in each
(define (panes-window-keys layout)
  (apply append (map (lambda (p) (or (plist-get p 'windows) '())) (panes-panes layout))))

;; the pane that holds window KEY, or #f
(define (panes-pane-of layout key)
  (let ((p (find (lambda (p) (member key (or (plist-get p 'windows) '()))) (panes-panes layout))))
    (and p (plist-get p 'id))))

(define (panes--set-panes layout panes) (panes--put layout 'panes panes))
(define (panes--set-windows layout windows) (panes--put layout 'windows windows))

(define (panes--update-pane layout id fn)
  (panes--set-panes layout
    (map (lambda (p) (if (equal? (plist-get p 'id) id) (fn p) p)) (panes-panes layout))))

(define (panes--update-window layout key fn)
  (panes--set-windows layout
    (map (lambda (w) (if (equal? (plist-get w 'key) key) (fn w) w)) (panes-windows layout))))

(define (panes--fresh layout counter prefix)
  ;; (NAME LAYOUT): a new id and the layout with COUNTER moved on
  (let ((n (or (plist-get layout counter) 1)))
    (list (string-append prefix (number->string n)) (panes--put layout counter (+ n 1)))))

;;; --- panes ------------------------------------------------------------------

;; add a pane at AT (the end when absent) with an equal share: (LAYOUT ID)
(define (panes-add-pane layout &optional at)
  (let* ((made (panes--fresh layout 'next-pane "p"))
         (id (car made))
         (layout (cadr made))
         ;; the average share, so an equal row stays equal and a widened
         ;; pane keeps its width
         (shares (map (lambda (p) (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1)))
                      (panes-panes layout)))
         (share (if (null? shares) 1 (/ (apply + shares) (length shares))))
         (pane (list 'id id 'share share 'windows '()))
         (panes (panes--insert-at (panes-panes layout)
                                  (if (number? at) at (panes-pane-count layout))
                                  pane)))
    (list (panes--set-panes layout panes) id)))

;; the pane goes; its windows go with it. The last pane stays.
(define (panes-remove-pane layout id)
  (let ((pane (panes-pane layout id)))
    (if (or (not pane) (<= (panes-pane-count layout) 1))
        layout
        (let ((keys (or (plist-get pane 'windows) '())))
          (panes--set-windows
            (panes--set-panes layout
              (filter (lambda (p) (not (equal? (plist-get p 'id) id))) (panes-panes layout)))
            (filter (lambda (w) (not (member (plist-get w 'key) keys))) (panes-windows layout)))))))

;; the shares of the panes in pane order, normalized to sum 1
(define (panes-shares layout)
  (let* ((raw (map (lambda (p) (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1)))
                   (panes-panes layout)))
         (total (apply + raw)))
    (if (or (null? raw) (<= total 0))
        '()
        (map (lambda (s) (/ s total)) raw))))

(define (panes-set-share layout id share)
  (if (and (number? share) (> share 0))
      (panes--update-pane layout id (lambda (p) (panes--put p 'share share)))
      layout))

;; every pane an equal share
(define (panes-equalize layout)
  (panes--set-panes layout (map (lambda (p) (panes--put p 'share 1)) (panes-panes layout))))

;; move pane ID to position AT among the panes
(define (panes-move-pane layout id at)
  (let ((pane (panes-pane layout id)))
    (if (not pane)
        layout
        (panes--set-panes layout
          (panes--insert-at (filter (lambda (p) (not (equal? (plist-get p 'id) id))) (panes-panes layout))
                            at pane)))))

;;; --- windows ----------------------------------------------------------------

;; a new window on BUF in pane PANE-ID, on screen unless BEHIND: (LAYOUT KEY).
;; The first window of a mode is that mode's preferred window.
(define (panes-new-window layout pane-id buf mode &optional behind)
  (let* ((made (panes--fresh layout 'next-window "w"))
         (key (car made))
         (layout (cadr made))
         (first-of-mode (and mode (not (panes-mode-window layout mode))))
         (window (list 'key key 'win #f 'mode mode
                       'buffers (if buf (list buf) '())
                       'preferred (and first-of-mode #t)))
         (layout (panes--set-windows layout (append (panes-windows layout) (list window))))
         (layout (panes--update-pane layout pane-id
                   (lambda (p)
                     (let ((keys (or (plist-get p 'windows) '())))
                       (panes--put p 'windows (if behind (append keys (list key)) (cons key keys))))))))
    (list layout key)))

;; the window goes; a pane it leaves empty goes too, unless it is the last
;; a window waiting behind the front window of a pane other than ID, from the
;; nearest pane out; #f when every other pane shows its only window
(define (panes--waiting-window layout id)
  (let* ((ids (panes-pane-ids layout))
         (at (or (panes--index-of id ids) 0))
         (waits? (lambda (pid)
                   (let ((ws (or (plist-get (panes-pane layout pid) 'windows) '())))
                     (and (not (equal? pid id)) (pair? ws) (pair? (cdr ws)))))))
    (let loop ((d 1))
      (if (> d (length ids))
          #f
          (let ((hit (find (lambda (pid) (and (= (abs (- (panes--index-of pid ids) at)) d) (waits? pid))) ids)))
            (if hit
                (cadr (plist-get (panes-pane layout hit) 'windows))
                (loop (+ d 1))))))))

;; the first of the layout's 'spares, ((WIN BUFFER STACK MODE) ...): the frame's hidden
;; windows outside the model, most recently used first. It becomes a window of PANE
;; with its own handle, so the frame shows it again; #f when there is none
(define (panes--take-spare layout pane)
  (let ((spares (or (plist-get layout 'spares) '())))
    (and (pair? spares)
         (let* ((s (car spares))
                (made (panes-new-window (panes--put layout 'spares (cdr spares)) pane (cadr s) (list-ref s 3)))
                (l (panes-set-buffers (car made) (cadr made) (caddr s))))
           (panes-set-handle l (cadr made) (car s))))))

;; windows A and B trade places: each takes the other's spot in the other's pane
(define (panes-swap-windows layout a b)
  (let ((pa (panes-pane-of layout a)) (pb (panes-pane-of layout b)))
    (if (or (not pa) (not pb) (equal? a b))
        layout
        (let ((trade (lambda (k) (cond ((equal? k a) b) ((equal? k b) a) (else k)))))
          (fold (lambda (l id) (panes--update-pane l id (lambda (p) (panes--put p 'windows (map trade (or (plist-get p 'windows) '()))))))
                layout
                (panes--uniq (list pa pb)))))))

;; a buffer is in one window: the window that shows it on screen, else one that
;; has it in front, else the first that holds it. Every other window lets it go,
;; and a window left with nothing closes
;; no buffer is without a window: each of BUFS the layout does not hold joins
;; the back of its mode's window (MODE-OF), else a window of its own behind the
;; last pane
(define (panes-adopt-buffers layout bufs mode-of)
  (let ((held (panes-buffers layout)))
    (panes--adopt-missing layout (panes--uniq (filter (lambda (b) (not (member b held))) bufs)) mode-of)))

(define (panes--adopt-missing layout missing mode-of)
  (fold (lambda (l b)
          (let ((m (mode-of b)))
            (cond ((and m (panes-mode-window l m))
                   (panes--update-window l (panes-mode-window l m)
                     (lambda (w) (panes--put w 'buffers (append (or (plist-get w 'buffers) '()) (list b))))))
                  ((pair? (panes-panes l))
                   (car (panes-new-window l (plist-get (car (reverse (panes-panes l))) 'id) b m #t)))
                  (else l))))
        layout missing))

(define (panes-unique-buffers layout)
  (let* ((keys (panes-window-keys layout))
         (tops (panes-top-windows layout))
         (order (append tops (filter (lambda (k) (not (member k tops))) keys)))
         (fronts (fold (lambda (acc k)
                         (let ((b (panes-window-buffer layout k)))
                           (if (and b (not (assoc b acc))) (cons (list b k) acc) acc)))
                       '() order))
         (owner (fold (lambda (acc k)
                        (fold (lambda (a b) (if (assoc b a) a (cons (list b k) a)))
                              acc (panes-window-buffers layout k)))
                      fronts order)))
    (fold (lambda (l k)
            (let* ((bufs (panes-window-buffers l k))
                   (mine (filter (lambda (b) (equal? (cadr (assoc b owner)) k)) bufs)))
              (cond ((= (length mine) (length bufs)) l)
                    ((null? mine) (panes-close-window l k))
                    (else (panes--update-window l k (lambda (w) (panes--put w 'buffers mine)))))))
          layout keys)))

(define (panes-close-window layout key)
  (let ((pane (panes-pane-of layout key)))
    (if (not pane)
        layout
        (let* ((layout (panes--set-windows layout
                         (filter (lambda (w) (not (equal? (plist-get w 'key) key))) (panes-windows layout))))
               (layout (panes--update-pane layout pane
                         (lambda (p) (panes--put p 'windows (panes--without key (or (plist-get p 'windows) '()))))))
               (left (plist-get (panes-pane layout pane) 'windows)))
          (cond
            ((not (and (null? left) (> (panes-pane-count layout) 1))) layout)
            ;; a 'bare layout keeps no count of panes (the overview's): the emptied pane goes
            ((plist-get layout 'bare) (panes-remove-pane layout pane))
            (else
              ;; the layout keeps its panes: an emptied pane takes a window that waits
              ;; behind another pane's front one, else one of the frame's hidden
              ;; windows ('spares), and goes only when no window is left
              (let ((waiting (panes--waiting-window layout pane)))
                (if waiting
                    (panes-move-window layout waiting pane)
                    (or (panes--take-spare layout pane)
                        (panes-remove-pane layout pane))))))))))

;; KEY comes to the front of its pane
(define (panes-raise layout key)
  (let ((pane (panes-pane-of layout key)))
    (if (not pane)
        layout
        (panes--update-pane layout pane
          (lambda (p) (panes--put p 'windows (cons key (panes--without key (or (plist-get p 'windows) '())))))))))

;; BUF comes to the front of window KEY, and KEY to the front of its pane
(define (panes-show layout key buf)
  (if (not (panes-window layout key))
      layout
      (panes-raise
        (panes--update-window layout key
          (lambda (w) (panes--put w 'buffers (cons buf (panes--without buf (or (plist-get w 'buffers) '()))))))
        key)))

;; the shown buffer of window KEY leaves that window; the next one shows.
;; An emptied window closes. Answers (LAYOUT NEXT-BUFFER-OR-#f).
(define (panes-pop layout key)
  (let ((w (panes-window layout key)))
    (cond ((not w) (list layout #f))
          (else
            (let ((rest (cdr (or (plist-get w 'buffers) '(#f)))))
              (if (null? rest)
                  (list (panes-close-window layout key) #f)
                  (list (panes--update-window layout key (lambda (w) (panes--put w 'buffers rest)))
                        (car rest))))))))

;; BUF leaves every window; emptied windows close (a kill)
(define (panes-drop-buffer layout buf)
  (let loop ((keys (panes-window-keys layout)) (layout layout))
    (if (null? keys)
        layout
        (let* ((w (panes-window layout (car keys)))
               (bufs (or (plist-get w 'buffers) '()))
               (left (panes--without buf bufs)))
          (loop (cdr keys)
                (cond ((= (length left) (length bufs)) layout)
                      ((null? left) (panes-close-window layout (car keys)))
                      (else (panes--update-window layout (car keys) (lambda (w) (panes--put w 'buffers left))))))))))

;; window KEY moves to pane PANE-ID, at INDEX (the front when absent); a
;; pane it leaves empty goes
(define (panes-move-window layout key pane-id &optional index)
  (let ((from (panes-pane-of layout key)))
    (cond ((or (not from) (not (panes-pane layout pane-id))) layout)
          ((equal? from pane-id)
           (panes--update-pane layout pane-id
             (lambda (p) (panes--put p 'windows (panes--insert-at (panes--without key (plist-get p 'windows)) (or index 0) key)))))
          (else
            (let* ((layout (panes--update-pane layout from
                             (lambda (p) (panes--put p 'windows (panes--without key (plist-get p 'windows))))))
                   (layout (panes--update-pane layout pane-id
                             (lambda (p) (panes--put p 'windows (panes--insert-at (or (plist-get p 'windows) '()) (or index 0) key)))))
                   (left (plist-get (panes-pane layout from) 'windows)))
              (if (and (null? left) (> (panes-pane-count layout) 1))
                  (panes-remove-pane layout from)
                  layout))))))

;; BUF leaves window FROM and shows in window TO; an emptied FROM closes
(define (panes-move-buffer layout buf from to)
  (if (or (not (panes-window layout from)) (not (panes-window layout to)) (equal? from to))
      layout
      (let* ((w (panes-window layout from))
             (left (panes--without buf (or (plist-get w 'buffers) '())))
             (layout (if (null? left)
                         (panes-close-window layout from)
                         (panes--update-window layout from (lambda (w) (panes--put w 'buffers left))))))
        (panes-show layout to buf))))

;; a renamed buffer keeps its places
(define (panes-rename layout old new)
  (panes--set-windows layout
    (map (lambda (w) (panes--put w 'buffers (map (lambda (b) (if (equal? b old) new b)) (or (plist-get w 'buffers) '()))))
         (panes-windows layout))))

;; the whole stack of KEY, the shown buffer first
(define (panes-set-buffers layout key bufs)
  (panes--update-window layout key (lambda (w) (panes--put w 'buffers (panes--uniq bufs)))))

(define (panes-set-mode layout key mode)
  (panes--update-window layout key (lambda (w) (panes--put w 'mode mode))))

;; KEY is the preferred window of its mode; the others of that mode are not
(define (panes-set-preferred layout key)
  (let* ((w (panes-window layout key))
         (mode (and w (plist-get w 'mode))))
    (if (not w)
        layout
        (panes--set-windows layout
          (map (lambda (x)
                 (cond ((equal? (plist-get x 'key) key) (panes--put x 'preferred #t))
                       ((equal? (plist-get x 'mode) mode) (panes--put x 'preferred #f))
                       (else x)))
               (panes-windows layout))))))

;;; --- questions --------------------------------------------------------------

;; the keys of the windows on screen, in pane order
(define (panes-top-windows layout)
  (filter (lambda (k) k)
          (map (lambda (p) (let ((ks (or (plist-get p 'windows) '()))) (and (pair? ks) (car ks))))
               (panes-panes layout))))

(define (panes-window-buffer layout key)
  (let ((w (panes-window layout key)))
    (and w (pair? (plist-get w 'buffers)) (car (plist-get w 'buffers)))))

(define (panes-window-buffers layout key)
  (let ((w (panes-window layout key))) (if w (or (plist-get w 'buffers) '()) '())))

(define (panes-window-mode layout key)
  ;; fundamental-mode is what a window was read with when its buffer named no
  ;; mode yet; the buffer it shows names the mode once it has one
  (let* ((w (panes-window layout key))
         (m (and w (plist-get w 'mode))))
    (if (and w (or (not m) (equal? m "fundamental-mode")))
        (let* ((top (let ((bs (plist-get w 'buffers))) (and (pair? bs) (car bs))))
               (tm (and top (buffer-known? top) (buffer-local top 'mode-name))))
          (or tm m))
        m)))

;; ((PANE KEY BUFFER) ...): what each pane shows, in pane order
(define (panes-visible layout)
  (filter (lambda (row) (cadr row))
          (map (lambda (p)
                 (let ((ks (or (plist-get p 'windows) '())))
                   (list (plist-get p 'id) (and (pair? ks) (car ks))
                         (and (pair? ks) (panes-window-buffer layout (car ks))))))
               (panes-panes layout))))

;; the window that shows BUF, else #f
(define (panes-window-showing layout buf)
  (find (lambda (k) (equal? (panes-window-buffer layout k) buf)) (panes-window-keys layout)))

;; every window that holds BUF anywhere in its stack, in pane order
(define (panes-windows-holding layout buf)
  (filter (lambda (k) (member buf (panes-window-buffers layout k))) (panes-window-keys layout)))

;; the window BUF belongs to: the one showing it, else the first holding it
(define (panes-find layout buf)
  (or (panes-window-showing layout buf)
      (let ((ks (panes-windows-holding layout buf))) (and (pair? ks) (car ks)))))

;; the preferred window of MODE, else the first window of MODE in pane order
(define (panes-mode-window layout mode)
  (and mode
       (let ((of-mode (filter (lambda (k) (equal? (panes-window-mode layout k) mode)) (panes-window-keys layout))))
         (or (find (lambda (k) (plist-get (panes-window layout k) 'preferred)) of-mode)
             (and (pair? of-mode) (car of-mode))))))

(define (panes-buffers layout)
  (panes--uniq (apply append (map (lambda (k) (panes-window-buffers layout k)) (panes-window-keys layout)))))

(define (panes-under-capacity? layout)
  (< (panes-pane-count layout) (panes-capacity layout)))

;; panes past the capacity fold into the last one that fits: their windows
;; wait behind it, in order, and the panes left share the frame equally
(define (panes-fit-capacity layout)
  (let ((ps (panes-panes layout)) (cap (panes-capacity layout)))
    (if (<= (length ps) cap)
        layout
        (let* ((kept (list-head ps cap))
               (extra (list-tail ps cap))
               (moved (apply append (map (lambda (p) (or (plist-get p 'windows) '())) extra)))
               (last (car (reverse kept)))
               (last (panes--put last 'windows (append (or (plist-get last 'windows) '()) moved))))
          (panes-equalize (panes--set-panes layout (append (list-head kept (- cap 1)) (list last))))))))

;;; --- consolidation ------------------------------------------------------------
;;; Every mode has one window: the preferred window of a mode gathers every
;;; buffer of that mode from every other window, its own first and then
;;; the others' in pane order. MODE-OF answers a buffer's mode; without it
;;; a buffer has the mode of the window that holds it. A window that gives
;;; up every buffer closes. MODES limits the work to those modes.

;; before a consolidate: a window takes the mode of the buffer it shows now,
;; not the one it was made with; each of EXTRA joins the back of its mode's window,
;; or a new window behind the last pane; and a mode with buffers but no window gets
;; one, behind the pane of the first window that holds such a buffer. Only with
;; MODE-OF, which reads the buffers' own modes
(define (panes--consolidate-homes layout mode-of modes &optional extra)
  (if (not mode-of)
      layout
      (let* ((layout (fold (lambda (l k)
                             (let* ((top (panes-window-buffer l k)) (m (and top (mode-of top))))
                               (if m (panes-set-mode l k m) l)))
                           layout (panes-window-keys layout)))
             (layout (fold (lambda (l b)
                             (let ((m (mode-of b)))
                               (cond ((or (not m) (member b (panes-buffers l)) (and modes (not (member m modes)))) l)
                                     ((panes-mode-window l m)
                                      (panes--update-window l (panes-mode-window l m)
                                        (lambda (w) (panes--put w 'buffers (append (or (plist-get w 'buffers) '()) (list b))))))
                                     ((pair? (panes-panes l))
                                      (car (panes-new-window l (plist-get (car (reverse (panes-panes l))) 'id) b m #t)))
                                     (else l))))
                           layout (or extra '())))
             (wanted (panes--uniq (filter (lambda (m) (and m (or (not modes) (member m modes))))
                                          (map mode-of (panes-buffers layout))))))
        (fold (lambda (l m)
                (if (panes-mode-window l m)
                    l
                    (let ((k (find (lambda (k) (find (lambda (b) (equal? (mode-of b) m)) (panes-window-buffers l k)))
                                   (panes-window-keys l))))
                      (if k (car (panes-new-window l (panes-pane-of l k) #f m #t)) l))))
              layout wanted))))

(define (panes-consolidate layout &optional mode-of modes extra)
  ;; the mode of every buffer is read once, from the layout as it stands:
  ;; the window showing it first, else the first window holding it. The
  ;; walk below only looks it up, so a 12-window frame consolidates in
  ;; milliseconds instead of a quarter of a second. EXTRA are buffers the
  ;; layout does not hold yet, such as the rest of the group: they join too
  (let* ((layout (panes--consolidate-homes layout mode-of modes extra))
         (keys (panes-window-keys layout))
         (index (let loop ((ks keys) (acc '()))
                  (if (null? ks)
                      (let loop2 ((ks keys) (acc acc))
                        (if (null? ks)
                            acc
                            (loop2 (cdr ks)
                                   (fold (lambda (a b) (if (assoc b a) a (cons (list b (panes-window-mode layout (car ks))) a)))
                                         acc (panes-window-buffers layout (car ks))))))
                      (let ((top (panes-window-buffer layout (car ks))))
                        (loop (cdr ks) (if (and top (not (assoc top acc))) (cons (list top (panes-window-mode layout (car ks))) acc) acc))))))
         (indexed-mode-of (lambda (b) (let ((e (assoc b index))) (and e (cadr e)))))
         (mode-of (or mode-of indexed-mode-of))
         (all (panes--uniq (filter (lambda (m) (and m (or (not modes) (member m modes))))
                                   (map (lambda (k) (panes-window-mode layout k)) keys)))))
    (let loop ((ms all) (layout layout))
      (if (null? ms)
          layout
          (let* ((mode (car ms))
                 (home (panes-mode-window layout mode))
                 (mine (lambda (b) (equal? (mode-of b) mode)))
                 (gathered (panes--uniq
                             (append (filter mine (panes-window-buffers layout home))
                                     (apply append
                                            (map (lambda (k) (if (equal? k home) '() (filter mine (panes-window-buffers layout k))))
                                                 (panes-window-keys layout))))))
                 ;; the other windows give those buffers up; one left empty closes
                 (layout (fold (lambda (l k)
                                 (if (equal? k home)
                                     l
                                     (let ((left (filter (lambda (b) (not (mine b))) (panes-window-buffers l k))))
                                       (cond ((= (length left) (length (panes-window-buffers l k))) l)
                                             ((null? left) (panes-close-window l k))
                                             (else (panes--update-window l k (lambda (w) (panes--put w 'buffers left))))))))
                               layout (panes-window-keys layout)))
                 (layout (if (panes-window layout home)
                             (panes--update-window layout home
                               (lambda (w) (panes--put w 'buffers (append gathered (filter (lambda (b) (not (mine b))) (plist-get w 'buffers))))))
                             layout)))
            (loop (cdr ms) layout))))))

;;; --- housekeeping ---------------------------------------------------------------

;; buffers LIVE? rejects leave every stack; emptied windows close
(define (panes-validate layout live?)
  (fold (lambda (l b) (if (live? b) l (panes-drop-buffer l b))) layout (panes-buffers layout)))

;; the renderer's handles
(define (panes-handle layout key)
  (let ((w (panes-window layout key))) (and w (plist-get w 'win))))

(define (panes-set-handle layout key handle)
  (panes--update-window layout key (lambda (w) (panes--put w 'win handle))))

(define (panes-key-of-handle layout handle)
  (and handle
       (let ((w (find (lambda (w) (equal? (plist-get w 'win) handle)) (panes-windows layout))))
         (and w (plist-get w 'key)))))

;; the value as it is saved: no handle outlives the frame
(define (panes-strip-handles layout)
  (panes--set-windows layout (map (lambda (w) (panes--put w 'win #f)) (panes-windows layout))))

;; a well-formed layout, or #f
(define (panes-layout? x)
  ;; a plist whose panes and windows, when present, are lists of plists
  ;; with an id and a key. This Scheme has no list?, so the shapes are
  ;; walked by hand
  (let* ((plist? (lambda (v)
                   (let loop ((v v))
                     (cond ((null? v) #t)
                           ((and (pair? v) (symbol? (car v)) (pair? (cdr v))) (loop (cddr v)))
                           (else #f)))))
         (rows? (lambda (v key)
                  (or (not v)
                      (and (or (null? v) (pair? v))
                           (null? (filter (lambda (r) (not (and (plist? r) (plist-get r key)))) v)))))))
    (and (plist? x)
         (rows? (plist-get x 'panes) 'id)
         (rows? (plist-get x 'windows) 'key)
         #t)))

;;; --- policies ---------------------------------------------------------------------
;;; A policy answers one question: where does BUF open? It reads the layout
;;; and a context, and answers a decision; the model applies it. So a
;;; policy is swappable, and every door (a visit, a display, a list row,
;;; an agent) asks the same one.
;;;
;;; CTX is a plist:
;;;   mode          BUF's major mode, or #f
;;;   selected      the key of the selected window, or #f
;;;   kind          visit (the user goes there) or display (a result shows)
;;;   inhibit-same  #t when the selected window may not take it
;;;   recent        window keys, most recently used first; a pane is as
;;;                 recent as its newest window
;;;
;;; A decision is one of:
;;;   (window KEY)       BUF comes to the front of KEY, and KEY to its pane's front
;;;   (new-window PANE)  a new window on BUF at the front of PANE
;;;   (new-pane)         a new pane at the end, with a new window on BUF

(domain! 'windows)
(effects! '(write))

(define (define-window-policy! name doc place)
  (registry-register! 'window-policy name (list 'doc doc 'place place)))

(define (window-policy-names) (registry-names 'window-policy))

(define (window-policy-place name)
  (let ((e (registry-lookup 'window-policy name)))
    (and e (plist-get e 'place))))

(domain! 'windows)
(effects! '(pure))

;; the pane of the least recently used window that is not in pane EXCEPT
(define (panes--lru-pane layout ctx except)
  (let* ((recent (or (plist-get ctx 'recent) '()))
         (keys (panes-window-keys layout))
         (unseen (filter (lambda (k) (not (member k recent))) keys))
         (order (append unseen (reverse (filter (lambda (k) (member k keys)) recent))))
         (panes (panes--uniq (map (lambda (k) (panes-pane-of layout k)) order)))
         (other (filter (lambda (p) (not (equal? p except))) panes)))
    (cond ((pair? other) (car other))
          ((pair? panes) (car panes))
          (else #f))))

(define (panes--selected-pane layout ctx)
  (let ((sel (plist-get ctx 'selected)))
    (or (and sel (panes-pane-of layout sel))
        (let ((ids (panes-pane-ids layout))) (and (pair? ids) (car ids))))))

;; mode-affinity: a buffer belongs with its kind. The window that holds it,
;; else the preferred window of its mode, else a pane of its own while the
;; layout is under capacity, else a new window in the selected pane; a
;; display takes the least recently used other pane instead.
(define (panes-place-mode-affinity layout buf ctx)
  (let* ((mode (plist-get ctx 'mode))
         (selected (plist-get ctx 'selected))
         (inhibit (plist-get ctx 'inhibit-same))
         (display? (equal? (plist-get ctx 'kind) 'display))
         ;; a window holds the buffer when it shows it, or keeps it in its
         ;; stack and is of its mode; a stack another mode kept from a stray
         ;; display does not pull the buffer back
         (held (or (panes-window-showing layout buf)
                   (find (lambda (k) (equal? (panes-window-mode layout k) mode))
                         (panes-windows-holding layout buf))))
         (kin (panes-mode-window layout mode))
         (sel-pane (panes--selected-pane layout ctx)))
    (cond ((and held (not (and inhibit (equal? held selected)))) (list 'window held))
          ((and kin (not (and inhibit (equal? kin selected)))) (list 'window kin))
          ((or (null? (panes-panes layout)) (panes-under-capacity? layout)) '(new-pane))
          ((or display? inhibit)
           (list 'new-window (or (panes--lru-pane layout ctx sel-pane) sel-pane)))
          (else (list 'new-window sel-pane)))))

;; emacs: a visit takes the selected window; a display reuses the window
;; that shows the buffer, pops a pane while there is room, else takes the
;; least recently used other window, else the selected one.
(define (panes-place-emacs layout buf ctx)
  (let* ((selected (plist-get ctx 'selected))
         (inhibit (plist-get ctx 'inhibit-same))
         (display? (equal? (plist-get ctx 'kind) 'display))
         (shown (panes-window-showing layout buf))
         (sel-pane (panes--selected-pane layout ctx)))
    (cond ((null? (panes-panes layout)) '(new-pane))
          ((and (not display?) (not inhibit) selected) (list 'window selected))
          ((and shown (not (and inhibit (equal? shown selected)))) (list 'window shown))
          ((panes-under-capacity? layout) '(new-pane))
          (else
            (let* ((lru (panes--lru-pane layout ctx sel-pane))
                   (ks (and lru (plist-get (panes-pane layout lru) 'windows))))
              (cond ((and ks (pair? ks) (not (equal? lru sel-pane))) (list 'window (car ks)))
                    ((and selected (not inhibit)) (list 'window selected))
                    (else (list 'new-window (or lru sel-pane)))))))))

(define-window-policy! 'mode-affinity
  "Each mode has one window: a buffer opens in the window of its mode, a new mode takes a pane while there is room, else a window of its own in the selected pane."
  panes-place-mode-affinity)

(define-window-policy! 'emacs
  "Emacs placement: a visit takes the selected window; a display reuses, pops a pane while there is room, else takes the least recently used window."
  panes-place-emacs)

(defcustom 'window-policy 'mode-affinity
  "Where a buffer opens: 'mode-affinity keeps one window per mode, 'emacs places as Emacs does. define-window-policy! adds another."
  'group 'windows 'type 'symbol)

;; the decision for BUF under POLICY (the chosen one when absent)
(define (panes-decide layout buf ctx &optional policy)
  (let ((place (or (window-policy-place (or policy window-policy))
                   panes-place-mode-affinity)))
    (place layout buf ctx)))

;; apply DECISION: (LAYOUT KEY) with BUF on screen in KEY
(define (panes-apply-decision layout buf mode decision)
  (let ((what (car decision)))
    (cond ((equal? what 'window) (list (panes-show layout (cadr decision) buf) (cadr decision)))
          ((equal? what 'new-window) (panes-new-window layout (cadr decision) buf mode))
          (else
            (let ((added (panes-add-pane layout)))
              (panes-new-window (car added) (cadr added) buf mode))))))

;; BUF opens where the policy says: (LAYOUT KEY)
(define (panes-open layout buf ctx &optional policy)
  (panes-apply-decision layout buf (plist-get ctx 'mode) (panes-decide layout buf ctx policy)))

(public! 'panes-open "(panes-open LAYOUT BUF CTX [POLICY]) -> (LAYOUT KEY): BUF opens where the window policy says; pure")
(catalog-meta! 'function "panes-open" 'effects '(pure))
(public! 'panes-decide "(panes-decide LAYOUT BUF CTX [POLICY]) -> (window KEY) | (new-window PANE) | (new-pane): where BUF would open; pure")
(catalog-meta! 'function "panes-decide" 'effects '(pure))
(public! 'define-window-policy! "(define-window-policy! NAME DOC PLACE) -- register a window policy; PLACE is (lambda (layout buf ctx) decision)")
