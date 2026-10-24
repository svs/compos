;;; panes.scm --- the window model: a row of panes, each a stack of windows,
;;; each a stack of buffers. One value per (group, frame).
;;;
;;; The value is plain data, so it saves with the group and reads back:
;;;
;;;   LAYOUT = (panes (PANE ...) windows (WINDOW ...) next N capacity C)
;;;   PANE   = (id ID share S windows (KEY ...))       the first KEY is on screen;
;;;                                                   no KEY is an empty pane
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

(define (panes--put plist key val)
  "PLIST with KEY set to VAL: a short name for plist-put."
  (plist-put plist key val))

(define (panes--index-of x lst)
  "The index of X in LST, from 0, or #f when LST does not hold X.
   It compares with equal?."
  (let loop ((l lst) (i 0))
    (cond ((null? l) #f)
          ((equal? (car l) x) i)
          (else (loop (cdr l) (+ i 1))))))

(define (panes--without x lst)
  "LST without the elements that are equal? to X."
  (filter (lambda (y) (not (equal? y x))) lst))

(define (panes--insert-at lst i x)
  "LST with X at index I. An I out of range goes to the start or the
   end."
  (let ((i (max 0 (min i (length lst)))))
    (append (take lst i) (list x) (list-tail lst i))))

(define (panes--uniq lst)
  "LST without repeats: the first of each element stays, in order."
  (let loop ((l lst) (acc '()))
    (cond ((null? l) (reverse acc))
          ((member (car l) acc) (loop (cdr l) acc))
          (else (loop (cdr l) (cons (car l) acc))))))

;;; --- the layout -------------------------------------------------------------

(define panes-default-capacity 3)

(define (panes-empty &optional capacity)
  "An empty layout: no pane, no window. CAPACITY is the most panes it
   shows, panes-default-capacity when absent. The pane and window
   counters start at 1."
  (list 'panes '() 'windows '() 'next-pane 1 'next-window 1 'capacity (or capacity panes-default-capacity)))

(define (panes-capacity layout)
  "The most panes LAYOUT shows side by side, panes-default-capacity
   when the layout names none."
  (or (plist-get layout 'capacity) panes-default-capacity))
(define (panes-set-capacity layout n)
  "LAYOUT with its capacity set to N. It does not fold panes:
   panes-fit-capacity does that."
  (panes--put layout 'capacity n))

(define (panes-panes layout)
  "The panes of LAYOUT, left to right; () when it has none."
  (or (plist-get layout 'panes) '()))
(define (panes-windows layout)
  "Every window of LAYOUT, in the order they were made; () when it has
   none. The order on screen is in the panes, not here."
  (or (plist-get layout 'windows) '()))
(define (panes-pane-ids layout)
  "The ids of the panes of LAYOUT, left to right."
  (map (lambda (p) (plist-get p 'id)) (panes-panes layout)))
(define (panes-pane-count layout)
  "How many panes LAYOUT has, empty panes included."
  (length (panes-panes layout)))

(define (panes-pane layout id)
  "The pane of LAYOUT whose id is ID, or #f."
  (find (lambda (p) (equal? (plist-get p 'id) id)) (panes-panes layout)))

(define (panes-window layout key)
  "The window of LAYOUT whose key is KEY, or #f."
  (find (lambda (w) (equal? (plist-get w 'key) key)) (panes-windows layout)))

(define (panes-window-keys layout)
  "The keys of every window, pane by pane, left to right. In each pane
   the window on screen comes first."
  (apply append (map (lambda (p) (or (plist-get p 'windows) '())) (panes-panes layout))))

(define (panes-pane-of layout key)
  "The id of the pane that holds window KEY, or #f."
  (let ((p (find (lambda (p) (member key (or (plist-get p 'windows) '()))) (panes-panes layout))))
    (and p (plist-get p 'id))))

(define (panes--set-panes layout panes)
  "LAYOUT with PANES as its panes."
  (panes--put layout 'panes panes))
(define (panes--set-windows layout windows)
  "LAYOUT with WINDOWS as its windows."
  (panes--put layout 'windows windows))

(define (panes--update-pane layout id fn)
  "LAYOUT with the pane whose id is ID replaced by (FN PANE). The other
   panes stay."
  (panes--set-panes layout
    (map (lambda (p) (if (equal? (plist-get p 'id) id) (fn p) p)) (panes-panes layout))))

(define (panes--update-window layout key fn)
  "LAYOUT with the window whose key is KEY replaced by (FN WINDOW). The
   other windows stay."
  (panes--set-windows layout
    (map (lambda (w) (if (equal? (plist-get w 'key) key) (fn w) w)) (panes-windows layout))))

(define (panes--fresh layout counter prefix)
  "A new id and LAYOUT with COUNTER moved on: (NAME LAYOUT). NAME is
   PREFIX and the count, such as p3 or w12."
  ;; (NAME LAYOUT): a new id and the layout with COUNTER moved on
  (let ((n (or (plist-get layout counter) 1)))
    (list (string-append prefix (number->string n)) (panes--put layout counter (+ n 1)))))

;;; --- panes ------------------------------------------------------------------

(define (panes-add-pane layout &optional at)
  "A new empty pane at index AT, the end when AT is absent: (LAYOUT ID).
   Its share is the average share of the panes, so an equal row stays
   equal and a widened pane keeps its width."
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

(define (panes-remove-pane layout id)
  "Pane ID goes, and its windows go with it. The last pane stays. An
   unknown ID changes nothing."
  (let ((pane (panes-pane layout id)))
    (if (or (not pane) (<= (panes-pane-count layout) 1))
        layout
        (let ((keys (or (plist-get pane 'windows) '())))
          (panes--set-windows
            (panes--set-panes layout
              (filter (lambda (p) (not (equal? (plist-get p 'id) id))) (panes-panes layout)))
            (filter (lambda (w) (not (member (plist-get w 'key) keys))) (panes-windows layout)))))))

(define (panes-shares layout)
  "The shares of the panes in pane order, normalized to sum 1. A share
   that is not a positive number counts as 1. () when there is no pane."
  (let* ((raw (map (lambda (p) (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1)))
                   (panes-panes layout)))
         (total (apply + raw)))
    (if (or (null? raw) (<= total 0))
        '()
        (map (lambda (s) (/ s total)) raw))))

(define (panes-set-share layout id share)
  "Pane ID takes SHARE. Shares are relative: panes-shares normalizes
   them. A SHARE that is not a positive number changes nothing."
  (if (and (number? share) (> share 0))
      (panes--update-pane layout id (lambda (p) (panes--put p 'share share)))
      layout))

(define (panes-equalize layout)
  "Every pane takes an equal share."
  (panes--set-panes layout (map (lambda (p) (panes--put p 'share 1)) (panes-panes layout))))

(define (panes-move-pane layout id at)
  "Pane ID moves to index AT among the panes, with all its windows. An
   AT out of range goes to the start or the end. An unknown ID changes
   nothing."
  (let ((pane (panes-pane layout id)))
    (if (not pane)
        layout
        (panes--set-panes layout
          (panes--insert-at (filter (lambda (p) (not (equal? (plist-get p 'id) id))) (panes-panes layout))
                            at pane)))))

;;; --- windows ----------------------------------------------------------------

(define (panes-new-window layout pane-id buf mode &optional behind)
  "A new window of MODE on BUF in pane PANE-ID: (LAYOUT KEY). It goes to
   the front of the pane, so it is on screen, or to the back when
   BEHIND. The first window of a mode is that mode's preferred window.
   A #f BUF gives a window with an empty stack."
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

(define (panes-swap-windows layout a b)
  "Windows A and B trade places: each takes the other's spot in the
   other's pane. Nothing changes when A and B are the same, or when no
   pane holds one of them."
  (let ((pa (panes-pane-of layout a)) (pb (panes-pane-of layout b)))
    (if (or (not pa) (not pb) (equal? a b))
        layout
        (let ((trade (lambda (k) (cond ((equal? k a) b) ((equal? k b) a) (else k)))))
          (fold (lambda (l id) (panes--update-pane l id (lambda (p) (panes--put p 'windows (map trade (or (plist-get p 'windows) '()))))))
                layout
                (panes--uniq (list pa pb)))))))

(define (panes-adopt-buffers layout bufs mode-of)
  "No buffer is without a window: each of BUFS the layout does not hold
   joins the back of its mode's window (MODE-OF), else a window of its
   own behind the last pane. With no pane, nothing joins."
  (let ((held (panes-buffers layout)))
    (panes--adopt-missing layout (panes--uniq (filter (lambda (b) (not (member b held))) bufs)) mode-of)))

(define (panes--adopt-missing layout missing mode-of)
  "Each of MISSING joins LAYOUT, in order: at the back of the stack of
   the window of its mode (MODE-OF), else in a new window at the back
   of the last pane. With no pane, the buffer stays out."
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
  "A buffer is in one window: the window that shows it on screen, else
   one that has it in front, else the first that holds it, the windows
   on screen first. Every other window lets it go, and a window left
   with nothing closes. The pane of a closed window stays."
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
  "Window KEY goes; its pane stays, empty when it held nothing else.
   In a bare layout (the overview's) an emptied pane goes too. An
   unknown KEY changes nothing."
  (let ((pane (panes-pane-of layout key)))
    (if (not pane)
        layout
        (let* ((layout (panes--set-windows layout
                         (filter (lambda (w) (not (equal? (plist-get w 'key) key))) (panes-windows layout))))
               (layout (panes--update-pane layout pane
                         (lambda (p) (panes--put p 'windows (panes--without key (or (plist-get p 'windows) '()))))))
               (left (plist-get (panes-pane layout pane) 'windows)))
          ;; an emptied pane stays, empty, as a group with no buffers stays; a
          ;; 'bare layout keeps no count of panes (the overview's): there it goes
          (if (and (null? left) (plist-get layout 'bare))
              (panes-remove-pane layout pane)
              layout)))))

(define (panes-raise layout key)
  "KEY comes to the front of its pane, so it is on screen. Its stack
   does not change. An unknown KEY changes nothing."
  (let ((pane (panes-pane-of layout key)))
    (if (not pane)
        layout
        (panes--update-pane layout pane
          (lambda (p) (panes--put p 'windows (cons key (panes--without key (or (plist-get p 'windows) '())))))))))

(define (panes-show layout key buf)
  "BUF comes to the front of window KEY, and KEY to the front of its
   pane. BUF leaves its old place in that stack. An unknown KEY changes
   nothing."
  (if (not (panes-window layout key))
      layout
      (panes-raise
        (panes--update-window layout key
          (lambda (w) (panes--put w 'buffers (cons buf (panes--without buf (or (plist-get w 'buffers) '()))))))
        key)))

(define (panes-pop layout key)
  "The shown buffer of window KEY leaves that window; the next one
   shows. An emptied window closes. Answers (LAYOUT NEXT-BUFFER-OR-#f);
   an unknown KEY answers (LAYOUT #f)."
  (let ((w (panes-window layout key)))
    (cond ((not w) (list layout #f))
          (else
            (let ((rest (cdr (or (plist-get w 'buffers) '(#f)))))
              (if (null? rest)
                  (list (panes-close-window layout key) #f)
                  (list (panes--update-window layout key (lambda (w) (panes--put w 'buffers rest)))
                        (car rest))))))))

(define (panes-drop-buffer layout buf)
  "BUF leaves every window, as for a kill. Emptied windows close; their
   panes stay."
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

(define (panes-move-window layout key pane-id &optional index)
  "Window KEY moves to pane PANE-ID, at INDEX (the front when absent).
   A pane it leaves empty goes, unless it is the last pane. In its own
   pane it only moves to INDEX. An unknown KEY or PANE-ID changes
   nothing."
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

(define (panes-move-buffer layout buf from to)
  "BUF leaves window FROM and shows in window TO; an emptied FROM
   closes. Nothing changes when FROM or TO is not a window, or when
   they are the same."
  (if (or (not (panes-window layout from)) (not (panes-window layout to)) (equal? from to))
      layout
      (let* ((w (panes-window layout from))
             (left (panes--without buf (or (plist-get w 'buffers) '())))
             (layout (if (null? left)
                         (panes-close-window layout from)
                         (panes--update-window layout from (lambda (w) (panes--put w 'buffers left))))))
        (panes-show layout to buf))))
(define (panes-split-off layout bufs from)
  "BUFS leave every window for a new window beside FROM, of FROM's mode.
   The new window goes in a new pane to the right of FROM's pane while
   there is room, else to the front of the next pane, else of the pane
   before, else of FROM's own pane. The first of BUFS shows. FROM keeps
   the rest of its stack and its preference, so new buffers of the mode
   still open there. Answers (LAYOUT KEY), or #f when FROM is not a
   window, BUFS is empty, or FROM would be left empty."
  (let* ((w (panes-window layout from))
         (left (and w (filter (lambda (b) (not (member b bufs))) (panes-window-buffers layout from)))))
    (if (or (not w) (null? bufs) (null? left))
        #f
        (let* ((layout (fold (lambda (l b) (panes-drop-buffer l b)) layout bufs))
               (pid (panes-pane-of layout from))
               (ids (panes-pane-ids layout))
               (i (panes--index-of pid ids))
               (added (cond ((panes-under-capacity? layout) (panes-add-pane layout (+ i 1)))
                            ((< (+ i 1) (length ids)) (list layout (list-ref ids (+ i 1))))
                            ((> i 0) (list layout (list-ref ids (- i 1))))
                            (else (list layout pid))))
               (made (panes-new-window (car added) (cadr added) (car bufs) (plist-get w 'mode))))
          (list (panes-set-buffers (car made) (cadr made) bufs) (cadr made))))))

(define (panes-rename layout old new)
  "A renamed buffer keeps its places: OLD becomes NEW in every stack."
  (panes--set-windows layout
    (map (lambda (w) (panes--put w 'buffers (map (lambda (b) (if (equal? b old) new b)) (or (plist-get w 'buffers) '()))))
         (panes-windows layout))))

(define (panes-set-buffers layout key bufs)
  "BUFS become the whole stack of KEY, the shown buffer first. Repeats
   go. The pane order does not change."
  (panes--update-window layout key (lambda (w) (panes--put w 'buffers (panes--uniq bufs)))))

(define (panes-set-mode layout key mode)
  "Window KEY takes MODE as its mode. Its stack and its preference do
   not change, so a window can be preferred for a mode it is no longer
   of. An unknown KEY changes nothing."
  (panes--update-window layout key (lambda (w) (panes--put w 'mode mode))))

(define (panes-set-preferred layout key)
  "KEY becomes the preferred window of its mode; the others of that
   mode are not. An unknown KEY changes nothing."
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

(define (panes-top-windows layout)
  "The keys of the windows on screen, one for each pane that holds a
   window, in pane order. An empty pane gives none."
  (filter (lambda (k) k)
          (map (lambda (p) (let ((ks (or (plist-get p 'windows) '()))) (and (pair? ks) (car ks))))
               (panes-panes layout))))

(define (panes-window-buffer layout key)
  "The buffer window KEY shows, the front of its stack, or #f."
  (let ((w (panes-window layout key)))
    (and w (pair? (plist-get w 'buffers)) (car (plist-get w 'buffers)))))

(define (panes-window-buffers layout key)
  "The stack of window KEY, the shown buffer first; () for an unknown
   KEY."
  (let ((w (panes-window layout key))) (if w (or (plist-get w 'buffers) '()) '())))

(define (panes-window-mode layout key)
  "The mode of window KEY, or #f. A window with no mode, or with
   fundamental-mode, takes the mode-name of the buffer it shows, when
   that buffer is known. This reads the buffers, so it is not pure."
  ;; fundamental-mode is what a window was read with when its buffer named no
  ;; mode yet; the buffer it shows names the mode once it has one
  (let* ((w (panes-window layout key))
         (m (and w (plist-get w 'mode))))
    (if (and w (or (not m) (equal? m "fundamental-mode")))
        (let* ((top (let ((bs (plist-get w 'buffers))) (and (pair? bs) (car bs))))
               (tm (and top (buffer-known? top) (buffer-local top 'mode-name))))
          (or tm m))
        m)))

(define (panes-visible layout)
  "((PANE KEY BUFFER) ...): what each pane shows, in pane order. An
   empty pane gives no row."
  (filter (lambda (row) (cadr row))
          (map (lambda (p)
                 (let ((ks (or (plist-get p 'windows) '())))
                   (list (plist-get p 'id) (and (pair? ks) (car ks))
                         (and (pair? ks) (panes-window-buffer layout (car ks))))))
               (panes-panes layout))))

(define (panes-window-showing layout buf)
  "The first window, in pane order, that has BUF at the front of its
   stack, else #f. A window behind its pane counts too: it shows BUF
   when it comes to the front."
  (find (lambda (k) (equal? (panes-window-buffer layout k) buf)) (panes-window-keys layout)))

(define (panes-windows-holding layout buf)
  "Every window that holds BUF anywhere in its stack, in pane order."
  (filter (lambda (k) (member buf (panes-window-buffers layout k))) (panes-window-keys layout)))

(define (panes-find layout buf)
  "The window BUF belongs to: the one showing it (panes-window-showing),
   else the first holding it, else #f."
  (or (panes-window-showing layout buf)
      (let ((ks (panes-windows-holding layout buf))) (and (pair? ks) (car ks)))))

(define (panes-mode-window layout mode)
  "The preferred window of MODE, else the first window of MODE in pane
   order, else #f. The mode is panes-window-mode. A #f MODE answers #f."
  (and mode
       (let ((of-mode (filter (lambda (k) (equal? (panes-window-mode layout k) mode)) (panes-window-keys layout))))
         (or (find (lambda (k) (plist-get (panes-window layout k) 'preferred)) of-mode)
             (and (pair? of-mode) (car of-mode))))))

(define (panes-buffers layout)
  "Every buffer LAYOUT holds, once, in pane order and then stack order."
  (panes--uniq (apply append (map (lambda (k) (panes-window-buffers layout k)) (panes-window-keys layout)))))

(define (panes-under-capacity? layout)
  "#t when LAYOUT has fewer panes than its capacity: one more pane fits."
  (< (panes-pane-count layout) (panes-capacity layout)))

(define (panes-fit-capacity layout)
  "Panes past the capacity fold into the last pane that fits: their
   windows go behind the windows of that pane, in order, so they are
   hidden. Then the panes left share the frame equally. A layout within
   its capacity does not change, its shares included."
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

(define (panes--consolidate-homes layout mode-of modes &optional extra)
  "Before a consolidate, a home for every mode. It runs only with
   MODE-OF, which reads the buffers' own modes; without it the layout
   does not change. In this order:
   1. A window takes the mode of the buffer it shows now, not the one
      it was made with.
   2. Each of EXTRA that the layout does not hold, of a mode in MODES,
      joins the back of its mode's window, else a new window behind
      the last pane.
   3. A mode with buffers but no window gets an empty window, behind
      the pane of the first window that holds a buffer of that mode.
   MODES, when given, limits steps 2 and 3 to those modes."
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
  "Every mode has one window. In this order:
   1. panes--consolidate-homes gives every mode a window (only with
      MODE-OF).
   2. For each mode, its home is the preferred window of the mode when
      it is on screen, else the first window of the mode on screen,
      else the preferred window.
   3. The home gathers every buffer of the mode: its own first, then
      the others' in pane order. A window on screen of another mode
      keeps its buffers, and a buffer it shows stays there.
   4. Every other window gives those buffers up, a second window of
      the mode on screen too; a window left empty closes.
   5. panes--fill-empty-panes fills the panes left empty.
   Without MODE-OF a buffer has the mode of the window that shows it,
   else of the first window that holds it. MODES limits the work to
   those modes. EXTRA are buffers the layout does not hold yet; they
   join in step 1."
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
                                   (map (lambda (k) (panes-window-mode layout k)) keys))))
         ;; a window on screen keeps its place; a second one of the same mode
         ;; gives its buffers to the first, and its pane takes a hidden mode
         (tops (panes-top-windows layout)))
    (let loop ((ms all) (layout layout))
      (if (null? ms)
          ;; a pane left empty shows a mode no pane shows, from behind another pane
          (panes--fill-empty-panes layout)
          (let* ((mode (car ms))
                 (home (let ((h (panes-mode-window layout mode)))
                         (if (member h tops) h (or (find (lambda (k) (equal? (panes-window-mode layout k) mode)) tops) h))))
                 (mine (lambda (b) (equal? (mode-of b) mode)))
                 (kept (lambda (l k) (or (equal? k home) (and (member k tops) (not (equal? (panes-window-mode l k) mode))))))
                 (fronts (filter (lambda (b) b) (map (lambda (k) (and (not (equal? k home)) (kept layout k) (panes-window-buffer layout k))) tops)))
                 (gathered (panes--uniq
                             (append (filter mine (panes-window-buffers layout home))
                                     (apply append
                                            (map (lambda (k) (if (kept layout k) '() (filter mine (panes-window-buffers layout k))))
                                                 (panes-window-keys layout))))))
                 (gathered (filter (lambda (b) (not (member b fronts))) gathered))
                 ;; the hidden windows give those buffers up; one left empty closes
                 (layout (fold (lambda (l k)
                                 (if (kept l k)
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

(define (panes--fill-empty-panes layout)
  "Each empty pane, left to right, takes a hidden window of a mode that
   no pane shows: the first such window in pane order moves to the
   front of the empty pane. A pane with no such window stays empty."
  (let loop ((ps (panes-panes layout)) (l layout))
    (cond ((null? ps) l)
          ((pair? (or (plist-get (car ps) 'windows) '())) (loop (cdr ps) l))
          (else
           (let* ((shown (map (lambda (k) (panes-window-mode l k)) (panes-top-windows l)))
                  (spare (find (lambda (k) (and (not (member k (panes-top-windows l)))
                                                (not (member (panes-window-mode l k) shown))))
                               (panes-window-keys l))))
             (loop (cdr ps) (if spare (panes-move-window l spare (plist-get (car ps) 'id)) l)))))))

;;; --- housekeeping ---------------------------------------------------------------

(define (panes-validate layout live?)
  "Buffers that LIVE? rejects leave every stack; emptied windows close.
   Their panes stay."
  (fold (lambda (l b) (if (live? b) l (panes-drop-buffer l b))) layout (panes-buffers layout)))

(define (panes-handle layout key)
  "The renderer's handle of window KEY: its frame window, or #f."
  (let ((w (panes-window layout key))) (and w (plist-get w 'win))))

(define (panes-set-handle layout key handle)
  "Window KEY takes HANDLE as its frame window; #f drops it."
  (panes--update-window layout key (lambda (w) (panes--put w 'win handle))))

(define (panes-key-of-handle layout handle)
  "The key of the window whose handle is HANDLE, or #f. A #f HANDLE
   answers #f."
  (and handle
       (let ((w (find (lambda (w) (equal? (plist-get w 'win) handle)) (panes-windows layout))))
         (and w (plist-get w 'key)))))

(define (panes-strip-handles layout)
  "LAYOUT as it is saved: every handle is #f, so no handle outlives the
   frame."
  (panes--set-windows layout (map (lambda (w) (panes--put w 'win #f)) (panes-windows layout))))

(define (panes-layout? x)
  "#t when X is a well-formed layout, else #f."
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
  "Registers window policy NAME with DOC. PLACE is
   (lambda (layout buf ctx) decision); panes-decide calls it."
  (registry-register! 'window-policy name (list 'doc doc 'place place)))

(define (window-policy-names)
  "The names of every registered window policy."
  (registry-names 'window-policy))

(define (window-policy-place name)
  "The PLACE procedure of window policy NAME, or #f when no policy has
   that name."
  (let ((e (registry-lookup 'window-policy name)))
    (and e (plist-get e 'place))))

(domain! 'windows)
(effects! '(pure))

(define (panes--lru-pane layout ctx except)
  "The pane of the least recently used window that is not in pane
   EXCEPT. A window that CTX recent does not name counts as older than
   every one it names. When every window is in EXCEPT, that pane; #f
   when the layout has no window. Empty panes do not count."
  (let* ((recent (or (plist-get ctx 'recent) '()))
         (keys (panes-window-keys layout))
         (unseen (filter (lambda (k) (not (member k recent))) keys))
         (order (append unseen (reverse (filter (lambda (k) (member k keys)) recent))))
         (panes (panes--uniq (map (lambda (k) (panes-pane-of layout k)) order)))
         (other (filter (lambda (p) (not (equal? p except))) panes)))
    (cond ((pair? other) (car other))
          ((pair? panes) (car panes))
          (else #f))))

(define (panes--empty-pane layout ctx)
  "An empty pane a buffer can open in: the selected one (CTX
   selected-pane) when it is empty, else the first empty one; #f when
   every pane holds a window."
  (let ((sel (plist-get ctx 'selected-pane))
        (empty (filter (lambda (id) (null? (or (plist-get (panes-pane layout id) 'windows) '())))
                       (panes-pane-ids layout))))
    (cond ((null? empty) #f)
          ((member sel empty) sel)
          (else (car empty)))))

(define (panes--selected-pane layout ctx)
  "The pane the selection is in: the pane of the selected window (CTX
   selected), else the empty pane the selection stands in (CTX
   selected-pane) when the layout still has it, else the first pane,
   else #f."
  (let ((sel (plist-get ctx 'selected)))
    (or (and sel (panes-pane-of layout sel))
        (let ((p (plist-get ctx 'selected-pane))) (and p (panes-pane layout p) p))
        (let ((ids (panes-pane-ids layout))) (and (pair? ids) (car ids))))))

(define (panes-place-mode-affinity layout buf ctx)
  "The mode-affinity policy: a buffer belongs with its kind. The rules,
   in order; the first that matches decides:
   1. A visit from the selected empty pane fills that pane with a new
      window, unless a window has BUF in front already.
   2. The window that holds BUF: one that has it in front, else one of
      its mode that keeps it in its stack. A window of another mode
      that kept it from a stray display does not pull it back.
   3. The preferred window of BUF's mode.
   4. An empty pane: a new window in it.
   5. No pane, or the layout is under capacity: a new pane.
   6. A display, or inhibit-same: a new window in the least recently
      used pane other than the selected one, else the selected pane.
   7. Else a new window in the selected pane.
   With inhibit-same, rule 1 does not apply, and rules 2 and 3 do not
   take the selected window."
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
         (sel-pane (panes--selected-pane layout ctx))
         (empty (panes--empty-pane layout ctx)))
    (cond ;; a visit from an empty pane fills it
          ((and empty (not display?) (not inhibit) (equal? empty (plist-get ctx 'selected-pane))
                (not (panes-window-showing layout buf)))
           (list 'new-window empty))
          ((and held (not (and inhibit (equal? held selected)))) (list 'window held))
          ((and kin (not (and inhibit (equal? kin selected)))) (list 'window kin))
          (empty (list 'new-window empty))
          ((or (null? (panes-panes layout)) (panes-under-capacity? layout)) '(new-pane))
          ((or display? inhibit)
           (list 'new-window (or (panes--lru-pane layout ctx sel-pane) sel-pane)))
          (else (list 'new-window sel-pane)))))

(define (panes-place-emacs layout buf ctx)
  "The emacs policy: placement as Emacs does it. The rules, in order;
   the first that matches decides:
   1. No pane: a new pane.
   2. A visit with a selected window: that window.
   3. A visit from the selected empty pane: a new window in it.
   4. The window that has BUF in front.
   5. An empty pane: a new window in it.
   6. The layout is under capacity: a new pane.
   7. The front window of the least recently used pane other than the
      selected one, else the selected window, else a new window in the
      least recently used pane or the selected pane.
   With inhibit-same, rules 2 and 3 do not apply, and rules 4 and 7
   do not take the selected window."
  (let* ((selected (plist-get ctx 'selected))
         (inhibit (plist-get ctx 'inhibit-same))
         (display? (equal? (plist-get ctx 'kind) 'display))
         (shown (panes-window-showing layout buf))
         (sel-pane (panes--selected-pane layout ctx))
         (empty (panes--empty-pane layout ctx)))
    (cond ((null? (panes-panes layout)) '(new-pane))
          ((and (not display?) (not inhibit) selected) (list 'window selected))
          ((and empty (not display?) (not inhibit) (equal? empty (plist-get ctx 'selected-pane))) (list 'new-window empty))
          ((and shown (not (and inhibit (equal? shown selected)))) (list 'window shown))
          (empty (list 'new-window empty))
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

(define (panes-decide layout buf ctx &optional policy)
  "The decision for BUF under POLICY, window-policy when absent. A name
   no policy has falls back to mode-affinity. It only decides;
   panes-apply-decision applies."
  (let ((place (or (window-policy-place (or policy window-policy))
                   panes-place-mode-affinity)))
    (place layout buf ctx)))

(define (panes-apply-decision layout buf mode decision)
  "Applies DECISION: (LAYOUT KEY) with BUF at the front of KEY, and KEY
   at the front of its pane.
   (window KEY): BUF comes to the front of KEY.
   (new-window PANE): a new window of MODE on BUF, at the front of PANE.
   Any other decision, (new-pane) too: a new pane at the end, with a
   new window of MODE on BUF."
  (let ((what (car decision)))
    (cond ((equal? what 'window) (list (panes-show layout (cadr decision) buf) (cadr decision)))
          ((equal? what 'new-window) (panes-new-window layout (cadr decision) buf mode))
          (else
            (let ((added (panes-add-pane layout)))
              (panes-new-window (car added) (cadr added) buf mode))))))

(define (panes-open layout buf ctx &optional policy)
  "BUF opens where the policy says: (LAYOUT KEY). It is panes-decide,
   then panes-apply-decision with the mode in CTX."
  (panes-apply-decision layout buf (plist-get ctx 'mode) (panes-decide layout buf ctx policy)))

;;; --- the panes api -------------------------------------------------------
;;; Four calls are the whole of what a caller does to the model:
;;; panes-show-buffer, panes-remove-buffer, panes-move-window and
;;; panes-move-pane. A window is locked to its mode, so every buffer goes
;;; to its mode's window; a pane mixes modes by holding windows of
;;; different modes.

(define (panes-show-buffer layout buf mode &optional pane)
  "BUF shows, new or known: (LAYOUT KEY). The window of MODE that holds
   BUF, else MODE's window, takes BUF to its front and comes to the
   front of its pane; it does not leave that pane. Only when MODE has no
   window does a new one open: in PANE when given, else in an empty pane,
   else in a new pane when one fits, else in the last pane."
  (let ((key (or (find (lambda (k) (equal? (panes-window-mode layout k) mode))
                       (panes-windows-holding layout buf))
                 (panes-mode-window layout mode))))
    (if key
        (list (panes-show layout key buf) key)
        (let* ((ids (panes-pane-ids layout))
               (home (or (and pane (panes-pane layout pane) pane)
                         (find (lambda (id) (null? (or (plist-get (panes-pane layout id) 'windows) '()))) ids))))
          (cond (home (panes-new-window layout home buf mode))
                ((or (null? ids) (panes-under-capacity? layout))
                 (let ((added (panes-add-pane layout)))
                   (panes-new-window (car added) (cadr added) buf mode)))
                (else (panes-new-window layout (list-ref ids (- (length ids) 1)) buf mode)))))))

(define (panes-remove-buffer layout buf)
  "BUF leaves its window, and the next buffer of that window shows. A
   window it leaves empty closes, and the next window of its pane comes
   to the front; the pane stays."
  (panes-drop-buffer layout buf))

(public! 'panes-open "(panes-open LAYOUT BUF CTX [POLICY]) -> (LAYOUT KEY): BUF opens where the window policy says; pure")
(catalog-meta! 'function "panes-open" 'effects '(pure))
(public! 'panes-show-buffer "(panes-show-buffer LAYOUT BUF MODE [PANE]) -> (LAYOUT KEY): BUF to the front of its mode's window, that window to the front of its pane; a new window only when MODE has none")
(catalog-meta! 'function "panes-show-buffer" 'effects '(read))
(public! 'panes-remove-buffer "(panes-remove-buffer LAYOUT BUF) -> LAYOUT: BUF leaves its window; the next buffer shows, an emptied window closes and the next window of its pane shows; pure")
(catalog-meta! 'function "panes-remove-buffer" 'effects '(pure))
(public! 'panes-decide "(panes-decide LAYOUT BUF CTX [POLICY]) -> (window KEY) | (new-window PANE) | (new-pane): where BUF would open; pure")
(catalog-meta! 'function "panes-decide" 'effects '(pure))
(public! 'panes-split-off "(panes-split-off LAYOUT BUFS FROM) -> (LAYOUT KEY) | #f: BUFS move to a new window of FROM's mode beside FROM; pure")
(catalog-meta! 'function "panes-split-off" 'effects '(pure))
(public! 'define-window-policy! "(define-window-policy! NAME DOC PLACE) -- register a window policy; PLACE is (lambda (layout buf ctx) decision)")
