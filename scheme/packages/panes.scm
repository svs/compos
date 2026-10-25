;;; panes.scm --- the window model: a row of panes, each a stack of windows,
;;; each a stack of buffers. One value per (group, frame).
;;;
;;; The value is plain data, so it saves with the group and reads back:
;;;
;;;   LAYOUT = (panes (PANE ...) focus ID next-pane N next-window N capacity C)
;;;   PANE   = (id ID share S windows (WINDOW ...))    the first WINDOW is on
;;;                                                   screen; none is an empty pane
;;;            column C vshare V                      optional: panes next to each
;;;                                                   other with one C stack, top to
;;;                                                   bottom, V their heights; the
;;;                                                   first one's S is the width
;;;   WINDOW = (key KEY win HANDLE mode MODE buffers (B ...) preferred BOOL)
;;;                                                   the first B is shown
;;;
;;; A window lives in its pane, so removing a pane or moving a window is one
;;; change. The layout is a tree (tree.scm) of the shape panes--shape, and
;;; the adds, removes, moves and lookups here are tree calls with the
;;; model's rules around them.
;;;
;;; A window's KEY is its identity; HANDLE is the renderer's window id,
;;; attached while the window is on screen and dropped when the value is
;;; saved. Every function here is pure: it takes a layout and answers a
;;; new one. The applier (panes-apply!) is the one place that touches the
;;; frame. panes-show-buffer says where a buffer opens: in its mode's
;;; window, else in a new window where the user is.

(require 'tree)

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

;;; --- buffer ids -------------------------------------------------------------
;;; A window's stack holds buffer ids, not names: a name changes when the
;;; buffer is renamed, and a new buffer can take a dead one's name. The
;;; model's calls take and give names; these turn one into the other. A
;;; name no buffer has is its own id, so a layout of made-up names (a
;;; test's) still works.

(effects! '(read))

(define (panes--ids bufs)
  "The ids of the buffers BUFS, in order, in one read. An entry no
   buffer is named stays as it is: an id already, or a made-up name."
  (if (null? bufs)
      '()
      (map (lambda (row) (or (cadr row) (car row))) (buffer-read-many bufs '(id) '()))))

(define (panes--id buf)
  "The id of buffer BUF; BUF itself when no buffer has that name."
  (car (panes--ids (list buf))))

;; ((ID NAME) ...) and the buffer count it was read at. A miss reads it
;; again only when buffers came or went; a rename clears it
(define panes--names '())
(define panes--names-count -1)
(define panes--names-missed '())

(define (panes--names-forget!)
  "Forget the id-to-name map; the next panes--name reads it again."
  (set! panes--names '())
  (set! panes--names-count -1)
  (set! panes--names-missed '()))

(define (panes--name id)
  "The name of the buffer whose id is ID; ID itself when no buffer has
   that id."
  (let ((e (assoc id panes--names)))
    (if e
        (cadr e)
        ;; every buffer, dormant ones too: a model window holds a dormant
        ;; buffer as well, and buffer-list names only the live ones
        (let ((all (map car (cadr (buffer-rows '(hidden #t context-only #t fields (name)))))))
          ;; a kill and a create keep the count, so a new id reads the map
          ;; again too; an id that missed once waits for the count to change
          (unless (and (= (length all) panes--names-count) (member id panes--names-missed))
            (unless (= (length all) panes--names-count) (set! panes--names-missed '()))
            (set! panes--names-count (length all))
            (set! panes--names
              (map (lambda (r) (list (cadr r) (car r)))
                   (filter cadr (buffer-read-many all '(id) '())))))
          (let ((e (assoc id panes--names)))
            (if e
                (cadr e)
                (begin (unless (member id panes--names-missed)
                         (set! panes--names-missed (cons id panes--names-missed)))
                       id)))))))

(define (panes--with-ids layout)
  "LAYOUT with every stack entry an id: a name some buffer has becomes
   that buffer's id, in one read. A layout saved with names reads this
   way."
  (let* ((all (panes--uniq (apply append (map (lambda (w) (or (plist-get w 'buffers) '())) (panes-windows layout)))))
         (ids (panes--ids all)))
    (if (equal? all ids)
        layout
        (let ((pairs (let zip ((a all) (i ids)) (if (null? a) '() (cons (list (car a) (car i)) (zip (cdr a) (cdr i)))))))
          (panes--map-windows layout
            (lambda (w) (panes--put w 'buffers (panes--uniq (map (lambda (b) (cadr (assoc b pairs))) (or (plist-get w 'buffers) '()))))))))))

(define (panes--entry-is? entry buf id)
  "#t when stack ENTRY stands for buffer BUF, whose id is ID: the id
   itself, or an id whose name is BUF (a killed buffer keeps its name
   in the map until it is read again)."
  (or (equal? entry id) (equal? (panes--name entry) buf)))

(effects! '(pure))

;;; --- the layout -------------------------------------------------------------

(define panes-default-capacity 3)

(define (panes-empty &optional capacity)
  "An empty layout: no pane, no window. CAPACITY is the most panes it
   shows, panes-default-capacity when absent. The pane and window
   counters start at 1."
  (list 'panes '() 'next-pane 1 'next-window 1 'capacity (or capacity panes-default-capacity)))

(define (panes-capacity layout)
  "The most panes LAYOUT shows side by side, panes-default-capacity
   when the layout names none."
  (or (plist-get layout 'capacity) panes-default-capacity))
(define (panes-set-capacity layout n)
  "LAYOUT with its capacity set to N. It does not fold panes:
   panes-fit-capacity does that."
  (panes--put layout 'capacity n))

(define (panes-panes layout)
  "The panes of LAYOUT, left to right; () when it has none. A layout
   saved in the old shape, its windows in a list of their own and its
   panes naming them by key, reads in the new shape."
  (let ((ps (or (plist-get layout 'panes) '()))
        (old (plist-get layout 'windows)))
    (if (pair? old)
        (map (lambda (p)
               (panes--put p 'windows
                 (filter (lambda (w) w)
                         (map (lambda (k) (if (string? k) (find (lambda (w) (equal? (plist-get w 'key) k)) old) k))
                              (or (plist-get p 'windows) '())))))
             ps)
        ps)))
(define panes--shape '((panes id) (windows key) (buffers #f)))

(define (panes--normal layout)
  "LAYOUT in the current shape: one saved with its windows in a list of
   their own reads as a tree."
  (if (pair? (plist-get layout 'windows)) (panes--set-panes layout (panes-panes layout)) layout))

(define (panes-windows layout)
  "Every window of LAYOUT, pane by pane, left to right; in each pane
   the window on screen comes first. () when it has none."
  (tree-nodes panes--shape (panes--normal layout) 2))
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
  (map (lambda (w) (plist-get w 'key)) (panes-windows layout)))

(define (panes--pane-windows pane)
  "The windows of PANE, the one on screen first."
  (or (plist-get pane 'windows) '()))

(define (panes-keys pane)
  "The keys of the windows of PANE, the one on screen first."
  (map (lambda (w) (plist-get w 'key)) (panes--pane-windows pane)))

(define (panes-pane-keys layout id)
  "The keys of the windows of pane ID, the one on screen first; () for
   an unknown ID."
  (let ((p (panes-pane layout id))) (if p (panes-keys p) '())))

(define (panes-pane-of layout key)
  "The id of the pane that holds window KEY, or #f."
  (let ((p (tree-parent panes--shape (panes--normal layout) key)))
    (and (string? p) (panes-pane layout p) p)))

(define (panes--set-panes layout panes)
  "LAYOUT with PANES as its panes. The old shape's list of windows goes:
   the windows are in the panes now."
  (let loop ((l layout) (out '()))
    (cond ((or (null? l) (null? (cdr l))) (panes--put (reverse out) 'panes panes))
          ((equal? (car l) 'windows) (loop (cddr l) out))
          (else (loop (cddr l) (cons (cadr l) (cons (car l) out)))))))
(define (panes--map-windows layout fn)
  "LAYOUT with every window replaced by (FN WINDOW), each in its place."
  (tree-map panes--shape (panes--normal layout) 2 fn))

(define (panes--update-pane layout id fn)
  "LAYOUT with the pane whose id is ID replaced by (FN PANE). The other
   panes stay."
  (tree-update panes--shape (panes--normal layout) id fn))

(define (panes--update-window layout key fn)
  "LAYOUT with the window whose key is KEY replaced by (FN WINDOW). The
   other windows stay."
  (tree-update panes--shape (panes--normal layout) key fn))

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
         (shares (map (lambda (c) (panes--positive (plist-get (car c) 'share))) (panes-columns layout)))
         (share (if (null? shares) 1 (/ (apply + shares) (length shares))))
         (pane (list 'id id 'share share 'windows '())))
    (list (tree-insert panes--shape (panes--normal layout) 'root pane at) id)))

(define (panes-remove-pane layout id)
  "Pane ID goes, and its windows go with it. The last pane stays. When
   ID had the focus, the pane that takes its place does, else the new
   last pane. An unknown ID changes nothing."
  (if (or (not (panes-pane layout id)) (<= (panes-pane-count layout) 1))
      layout
      (let* ((i (panes--index-of id (panes-pane-ids layout)))
             (focused (equal? (panes-focus layout) id))
             (layout (tree-remove panes--shape (panes--normal (panes--detach layout id)) id))
             (left (panes-pane-ids layout)))
        (if focused
            (panes-set-focus layout (list-ref left (min i (- (length left) 1))))
            layout))))

;;; --- focus ------------------------------------------------------------------
;;; The layout knows the pane the user is in. Its front window is the
;;; focused window: only a front window is on screen. A command changes
;;; the focus here and the draw selects it; nothing else selects.

(define (panes-focus layout)
  "The id of the focused pane. A layout that names none, or a pane it
   no longer has, answers its first pane; #f with no pane. A focus saved
   in the old shape, (window KEY) or (pane ID), reads too."
  (let* ((f (plist-get layout 'focus))
         (id (cond ((string? f) f)
                   ((and (pair? f) (eq? (car f) 'window)) (panes-pane-of layout (cadr f)))
                   ((and (pair? f) (eq? (car f) 'pane)) (cadr f))
                   (else #f))))
    (if (and id (panes-pane layout id))
        id
        (let ((ids (panes-pane-ids layout))) (and (pair? ids) (car ids))))))

(define (panes-set-focus layout id)
  "LAYOUT with pane ID focused. An unknown ID changes nothing."
  (if (panes-pane layout id) (panes--put layout 'focus id) layout))

(define (panes-focus-window layout key)
  "Window KEY comes to the front of its pane, and its pane takes the
   focus. An unknown KEY changes nothing."
  (let ((p (panes-pane-of layout key)))
    (if p (panes-set-focus (panes-raise layout key) p) layout)))


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
  "Every pane takes an equal share, and every stacked pane an equal
   height."
  (tree-map panes--shape (panes--normal layout) 1 (lambda (p) (panes--put (panes--put p 'share 1) 'vshare 1))))

;;; --- columns ------------------------------------------------------------
;;; Panes next to each other with the same column stack top to bottom, as
;;; Emacs's C-x 2 stacks windows. A pane without a column is a column of
;;; its own, so a layout with no column draws as a row of panes.

(define (panes-column-of pane)
  "The column PANE stands in: its column, else its own id."
  (or (plist-get pane 'column) (plist-get pane 'id)))

(define (panes-columns layout)
  "The panes of LAYOUT in columns, left to right: a list of columns, each
   the list of its panes, top to bottom."
  (let loop ((ps (panes-panes layout)) (acc '()))
    (cond ((null? ps) (reverse (map reverse acc)))
          ((and (pair? acc) (equal? (panes-column-of (car ps)) (panes-column-of (caar acc))))
           (loop (cdr ps) (cons (cons (car ps) (car acc)) (cdr acc))))
          (else (loop (cdr ps) (cons (list (car ps)) acc))))))

(define (panes-column-count layout)
  "How many columns LAYOUT has."
  (length (panes-columns layout)))

(define (panes--positive v)
  "V when it is a positive number, else 1."
  (if (and (number? v) (> v 0)) v 1))

(define (panes-vshares column)
  "The heights of the panes of COLUMN, top to bottom, normalized to
   sum 1. A height that is not a positive number counts as 1."
  (let* ((raw (map (lambda (p) (panes--positive (plist-get p 'vshare))) column))
         (total (apply + raw)))
    (map (lambda (v) (/ v total)) raw)))

(define (panes--detach layout id)
  "LAYOUT with pane ID out of its column: the pane above it takes its
   height, else the pane below; a pane that was stacked under it takes
   its width; and ID has no column."
  (let* ((col (find (lambda (c) (member id (map (lambda (p) (plist-get p 'id)) c))) (panes-columns layout)))
         (ids (if col (map (lambda (p) (plist-get p 'id)) col) '()))
         (i (panes--index-of id ids))
         (me (and col (list-ref col i)))
         (heir (and col (pair? (cdr col)) (list-ref ids (if (> i 0) (- i 1) 1))))
         (layout (if heir
                     (panes--update-pane layout heir
                       (lambda (p) (panes--put p 'vshare (+ (panes--positive (plist-get p 'vshare))
                                                             (panes--positive (plist-get me 'vshare))))))
                     layout))
         (layout (if (and heir (= i 0))
                     (panes-set-share layout heir (panes--positive (plist-get me 'share)))
                     layout)))
    (if col (panes--update-pane layout id (lambda (p) (panes--put p 'column #f))) layout)))

(define (panes-split-below layout id)
  "A new empty pane under pane ID, in ID's column: (LAYOUT NEW-ID). ID
   and the new pane share ID's height, as C-x 2 halves a window. An
   unknown ID answers (LAYOUT #f)."
  (let ((pane (panes-pane layout id)))
    (if (not pane)
        (list layout #f)
        (let* ((col (panes-column-of pane))
               (half (/ (panes--positive (plist-get pane 'vshare)) 2))
               (made (panes--fresh layout 'next-pane "p"))
               (layout (panes--update-pane (cadr made) id
                         (lambda (p) (panes--put (panes--put p 'column col) 'vshare half))))
               (new (list 'id (car made) 'column col 'vshare half 'windows '()))
               (at (+ 1 (panes--index-of id (panes-pane-ids layout)))))
          (list (tree-insert panes--shape (panes--normal layout) 'root new at) (car made))))))

(define (panes-move-pane layout id at)
  "Pane ID moves to index AT among the panes, with all its windows, as a
   column of its own. An AT inside another column goes to that column's
   end, and an AT out of range to the start or the end. An unknown ID
   changes nothing."
  (if (panes-pane layout id)
      (let* ((layout (panes--detach layout id))
             (others (tree-remove panes--shape (panes--normal layout) id))
             ;; the indexes between columns: 0, then the end of each column
             (edges (let loop ((cs (panes-columns others)) (n 0) (acc '(0)))
                      (if (null? cs) (reverse acc) (let ((n (+ n (length (car cs))))) (loop (cdr cs) n (cons n acc))))))
             (at (or (find (lambda (e) (>= e (max 0 at))) edges) (car (reverse edges)))))
        (tree-move panes--shape (panes--normal layout) id 'root at))
      layout))

(define (panes-swap-panes layout a b)
  "Panes A and B trade their windows. Each pane keeps its place and its
   size, so a move never splits a column. An unknown pane, or A and B
   the same, changes nothing."
  (let ((pa (panes-pane layout a)) (pb (panes-pane layout b)))
    (if (and pa pb (not (equal? a b)))
        (panes--update-pane
          (panes--update-pane layout a (lambda (p) (panes--put p 'windows (or (plist-get pb 'windows) '()))))
          b (lambda (p) (panes--put p 'windows (or (plist-get pa 'windows) '()))))
        layout)))

(define (panes-move-column layout id step)
  "The column of pane ID moves STEP columns, -1 left or 1 right, with
   every pane in it. At the edge nothing changes."
  (let* ((cols (panes-columns layout))
         (ci (panes--index-of #t (map (lambda (c) (and (member id (map (lambda (p) (plist-get p 'id)) c)) #t)) cols)))
         (to (and ci (+ ci step))))
    (if (or (not to) (< to 0) (>= to (length cols)))
        layout
        (let ((col (list-ref cols ci)))
          (panes--set-panes layout (apply append (panes--insert-at (panes--without col cols) to col)))))))

;;; --- windows ----------------------------------------------------------------

(define panes-key-source #f)

(define (panes--new-key layout)
  "A key for a new window and LAYOUT: (KEY LAYOUT). The key is the
   frame window id that panes-key-source mints (panes-mode.scm sets it
   to window-id-new!); without one, wN from LAYOUT's counter, as the
   pure tests use."
  (if (procedure? panes-key-source)
      (list (panes-key-source) layout)
      (panes--fresh layout 'next-window "w")))

(define (panes-add-window layout pane-id buf mode &optional behind)
  "A new window of MODE on BUF in pane PANE-ID: (LAYOUT KEY). It goes to
   the front of the pane, so it is on screen, or to the back when
   BEHIND. The first window of a mode is that mode's preferred window.
   A #f BUF gives a window with an empty stack."
  (let* ((made (panes--new-key layout))
         (key (car made))
         (layout (cadr made))
         (first-of-mode (and mode (not (panes-mode-window layout mode))))
         (window (list 'key key 'mode mode
                       'buffers (if buf (list (panes--id buf)) '())
                       'preferred (and first-of-mode #t))))
    (list (tree-insert panes--shape (panes--normal layout) pane-id window (if behind #f 0)) key)))

(define (panes-swap-windows layout a b)
  "Windows A and B trade places: each takes the other's spot in the
   other's pane. Nothing changes when A and B are the same, or when no
   pane holds one of them."
  (let ((wa (panes-window layout a)) (wb (panes-window layout b)))
    (if (or (not wa) (not wb) (equal? a b))
        layout
        (panes--map-windows layout
          (lambda (w) (let ((k (plist-get w 'key))) (cond ((equal? k a) wb) ((equal? k b) wa) (else w))))))))

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
                     (lambda (w) (panes--put w 'buffers (append (or (plist-get w 'buffers) '()) (list (panes--id b)))))))
                  ((pair? (panes-panes l))
                   (car (panes-add-window l (plist-get (car (reverse (panes-panes l))) 'id) b m #t)))
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
                    ((null? mine) (panes-remove-window l k))
                    (else (panes--update-window l k (lambda (w) (panes--put w 'buffers (panes--ids mine))))))))
          layout keys)))

(define (panes-remove-window layout key)
  "Window KEY goes; its pane stays, empty when it held nothing else. An
   unknown KEY changes nothing."
  (if (panes-pane-of layout key)
      (tree-remove panes--shape (panes--normal layout) key)
      layout))


(define (panes-raise layout key)
  "KEY comes to the front of its pane, so it is on screen. Its stack
   does not change. An unknown KEY changes nothing."
  (let ((pane (panes-pane-of layout key)))
    (if pane (tree-move panes--shape (panes--normal layout) key pane 0) layout)))

(define (panes-show layout key buf)
  "BUF comes to the front of window KEY, and KEY to the front of its
   pane. BUF leaves its old place in that stack. An unknown KEY changes
   nothing."
  (if (not (panes-window layout key))
      layout
      (panes-raise
        (panes--update-window layout key
          (lambda (w) (let ((id (panes--id buf))) (panes--put w 'buffers (cons id (panes--without id (or (plist-get w 'buffers) '())))))))
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
                  (list (panes-remove-window layout key) #f)
                  (list (panes--update-window layout key (lambda (w) (panes--put w 'buffers rest)))
                        (panes--name (car rest)))))))))

(define (panes-drop-buffer layout buf)
  "BUF leaves every window, as for a kill. Emptied windows close; their
   panes stay."
  (let loop ((keys (panes-window-keys layout)) (layout layout) (id (panes--id buf)))
    (if (null? keys)
        layout
        (let* ((w (panes-window layout (car keys)))
               (bufs (or (plist-get w 'buffers) '()))
               (left (filter (lambda (e) (not (panes--entry-is? e buf id))) bufs)))
          (loop (cdr keys)
                (cond ((= (length left) (length bufs)) layout)
                      ((null? left) (panes-remove-window layout (car keys)))
                      (else (panes--update-window layout (car keys) (lambda (w) (panes--put w 'buffers left)))))
                id)))))

(define (panes-move-window layout key pane-id &optional index)
  "Window KEY moves to pane PANE-ID, at INDEX (the front when absent);
   in its own pane it only moves to INDEX. A pane it leaves empty
   stays, as after panes-remove-window. An unknown KEY or PANE-ID
   changes nothing."
  (let ((from (panes-pane-of layout key)))
    (if (and from (panes-pane layout pane-id))
        (tree-move panes--shape (panes--normal layout) key pane-id (or index 0))
        layout)))

(define (panes-move-buffer layout buf to)
  "BUF leaves the window that holds it and comes to the front of window
   TO, and TO to the front of its pane. A window BUF leaves empty
   closes. An unknown TO changes nothing."
  (cond ((not (panes-window layout to)) layout)
        ((member buf (panes-window-buffers layout to)) (panes-show layout to buf))
        (else (panes-show (panes-drop-buffer layout buf) to buf))))
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
               (made (panes-add-window (car added) (cadr added) (car bufs) (plist-get w 'mode))))
          (list (panes-set-buffers (car made) (cadr made) bufs) (cadr made))))))


(define (panes-set-buffers layout key bufs)
  "BUFS become the whole stack of KEY, the shown buffer first. Repeats
   go. The pane order does not change."
  (panes--update-window layout key (lambda (w) (panes--put w 'buffers (panes--uniq (panes--ids bufs))))))

(define (panes-window-point layout key)
  "The point window KEY had in the buffer it shows when it last left
   the screen, or #f: also when it shows another buffer now."
  (let* ((w (panes-window layout key)) (p (and w (plist-get w 'point))))
    (and (pair? p) (equal? (car p) (panes-window-buffer layout key)) (cadr p))))

(define (panes-set-window-point layout key buf pos)
  "Window KEY keeps POS as its point in BUF while it is off the screen.
   An unknown KEY changes nothing."
  (panes--update-window layout key (lambda (w) (panes--put w 'point (list buf pos)))))

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
        (panes--map-windows layout
          (lambda (x)
            (cond ((equal? (plist-get x 'key) key) (panes--put x 'preferred #t))
                  ((equal? (plist-get x 'mode) mode) (panes--put x 'preferred #f))
                  (else x)))))))

;;; --- questions --------------------------------------------------------------

(define (panes-top-windows layout)
  "The keys of the windows on screen, one for each pane that holds a
   window, in pane order. An empty pane gives none."
  (filter (lambda (k) k)
          (map (lambda (p) (let ((ks (panes-keys p))) (and (pair? ks) (car ks))))
               (panes-panes layout))))

(define (panes-window-buffer layout key)
  "The buffer window KEY shows, the front of its stack, or #f."
  (let ((w (panes-window layout key)))
    (and w (pair? (plist-get w 'buffers)) (panes--name (car (plist-get w 'buffers))))))

(define (panes-window-buffers layout key)
  "The stack of window KEY, the shown buffer first; () for an unknown
   KEY."
  (let ((w (panes-window layout key))) (if w (map panes--name (or (plist-get w 'buffers) '())) '())))

(define (panes-window-mode layout key)
  "The mode of window KEY, or #f. A window with no mode, or with
   fundamental-mode, takes the mode-name of the buffer it shows, when
   that buffer is known. This reads the buffers, so it is not pure."
  ;; fundamental-mode is what a window was read with when its buffer named no
  ;; mode yet; the buffer it shows names the mode once it has one
  (let* ((w (panes-window layout key))
         (m (and w (plist-get w 'mode))))
    (if (and w (or (not m) (equal? m "fundamental-mode")))
        (let* ((top (let ((bs (plist-get w 'buffers))) (and (pair? bs) (panes--name (car bs)))))
               (tm (and top (buffer-known? top) (buffer-local top 'mode-name))))
          (or tm m))
        m)))

(define (panes-visible layout)
  "((PANE KEY BUFFER) ...): what each pane shows, in pane order. An
   empty pane gives no row."
  (filter (lambda (row) (cadr row))
          (map (lambda (p)
                 (let ((ks (panes-keys p)))
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
  "#t when LAYOUT has fewer columns than its capacity: one more pane
   fits beside them. Panes stacked in a column count once."
  (< (panes-column-count layout) (panes-capacity layout)))

(define (panes-fit-capacity layout)
  "Columns past the capacity fold into the last pane that fits: their
   windows go behind the windows of that pane, in order, so they are
   hidden. Then the panes left share the frame equally. A layout within
   its capacity does not change, its shares included."
  (let ((cols (panes-columns layout)) (cap (panes-capacity layout)))
    (if (<= (length cols) cap)
        layout
        (let* ((kept (apply append (list-head cols cap)))
               (extra (apply append (list-tail cols cap)))
               (moved (apply append (map (lambda (p) (or (plist-get p 'windows) '())) extra)))
               (last (car (reverse kept)))
               (last (panes--put last 'windows (append (or (plist-get last 'windows) '()) moved))))
          (panes-equalize (panes--set-panes layout (append (list-head kept (- (length kept) 1)) (list last))))))))

;;; --- consolidation ------------------------------------------------------------
;;; Every mode has one window: the preferred window of a mode gathers every
;;; buffer of that mode from every other window, its own first and then
;;; the others' in pane order. MODE-OF answers a buffer's mode; without it
;;; a buffer has the mode of the window that holds it. A window that gives
;;; up every buffer closes. MODES limits the work to those modes.

;;; --- layouts -------------------------------------------------------------------
;;; A layout is a named shape: how many panes the frame shows, and the share
;;; of each. The model of a group names its layout in 'layout; panes keeps
;;; the rest (stacks, focus, history, where a buffer goes).

(define panes--layout-specs '())

(define (define-layout! name &rest props)
  "NAME is a layout of PROPS, a plist: 'capacity, a count of panes or a
   procedure that answers one; 'shares, a procedure of a pane count that
   answers a share for each pane, or #f for equal shares; 'doc, one line
   for the prompt. Defining NAME again replaces it. Answers NAME."
  (set! panes--layout-specs
    (append (filter (lambda (e) (not (equal? (car e) name))) panes--layout-specs)
            (list (list name props))))
  name)

(define (panes-layout-spec name)
  "The plist of layout NAME, or #f."
  (let ((e (assoc name panes--layout-specs))) (and e (cadr e))))

(define (panes-layout-names)
  "Every layout, in the order defined."
  (map car panes--layout-specs))

(define (panes-layout-capacity name)
  "How many panes layout NAME shows, or #f for an unknown NAME."
  (let* ((s (panes-layout-spec name)) (c (and s (plist-get s 'capacity))))
    (if (procedure? c) (c) c)))

(define (panes-layout-name layout)
  "The name of the layout LAYOUT is in, or #f."
  (plist-get layout 'layout))

(define (panes-set-layout layout name)
  "LAYOUT in layout NAME: the capacity becomes NAME's, panes past it
   fold into the last one, and every pane takes the default share, so
   NAME's shares hold. An unknown NAME changes nothing."
  (let ((cap (panes-layout-capacity name)))
    (if (not cap)
        layout
        (panes-equalize (panes-fit-capacity (panes-set-capacity (panes--put layout 'layout name) cap))))))

(define (panes-layout-shares layout &optional columns?)
  "The share of each pane, normalized to sum 1; with COLUMNS?, the width
   of each column, its first pane's share. A pane resized by hand keeps
   its own share; while every one keeps the default, the shares of
   LAYOUT's layout hold, else they are equal. A share that is not a
   positive number counts as 1."
  (let* ((ps (if columns? (map car (panes-columns layout)) (panes-panes layout)))
         (raw (map (lambda (p) (panes--positive (plist-get p 'share))) ps))
         (n (length raw))
         (plain (null? (filter (lambda (s) (not (= s 1))) raw)))
         (spec (panes-layout-spec (panes-layout-name layout)))
         (f (and spec (plist-get spec 'shares)))
         (given (and plain (procedure? f) (> n 0) (f n)))
         (raw (if (and (pair? given) (= (length given) n)) given raw))
         (total (apply + raw)))
    (map (lambda (s) (/ s total)) raw)))

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
                                        (lambda (w) (panes--put w 'buffers (append (or (plist-get w 'buffers) '()) (list (panes--id b)))))))
                                     ((pair? (panes-panes l))
                                      (car (panes-add-window l (plist-get (car (reverse (panes-panes l))) 'id) b m #t)))
                                     (else l))))
                           layout (or extra '())))
             (wanted (panes--uniq (filter (lambda (m) (and m (or (not modes) (member m modes))))
                                          (map mode-of (panes-buffers layout))))))
        (fold (lambda (l m)
                (if (panes-mode-window l m)
                    l
                    (let ((k (find (lambda (k) (find (lambda (b) (equal? (mode-of b) m)) (panes-window-buffers l k)))
                                   (panes-window-keys l))))
                      (if k (car (panes-add-window l (panes-pane-of l k) #f m #t)) l))))
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
                                             ((null? left) (panes-remove-window l k))
                                             (else (panes--update-window l k (lambda (w) (panes--put w 'buffers (panes--ids left)))))))))
                               layout (panes-window-keys layout)))
                 (layout (if (panes-window layout home)
                             (panes--update-window layout home
                               (lambda (w) (panes--put w 'buffers (panes--ids (append gathered (filter (lambda (b) (not (mine b))) (map panes--name (plist-get w 'buffers))))))))
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
  "The frame window of window KEY: KEY itself, the key is the frame
   window id; #f for an unknown KEY."
  (and (panes-window layout key) key))

(define (panes-set-handle layout key handle)
  "Window KEY takes HANDLE as its key: the frame gave its window another
   id than the one asked for. LAYOUT as it is for an unknown KEY, a #f
   HANDLE, or a HANDLE another window already has."
  (if (or (not handle) (equal? key handle) (not (panes-window layout key)) (panes-window layout handle))
      layout
      (panes--update-window layout key (lambda (w) (panes--put w 'key handle)))))

(define (panes-key-of-handle layout handle)
  "The key of the window whose frame window is HANDLE: HANDLE itself
   when LAYOUT has that window, else #f. A #f HANDLE answers #f."
  (and handle (panes-window layout handle) handle))

(define (panes-strip-handles layout)
  "LAYOUT as it is saved. A window's key is its frame window id, so
   there is nothing to strip."
  layout)

(define (panes-rekey-legacy layout)
  "LAYOUT with every window keyed by its frame window id. A layout saved
   before keys were ids has keys like w3 and the id in 'win: a window
   takes its 'win when no other window has it, else a new key from
   panes-key-source. 'win goes. With no key source, LAYOUT."
  (if (not (procedure? panes-key-source))
      layout
      (let loop ((ws (panes-windows layout)) (l layout) (used (filter integer? (panes-window-keys layout))))
        (if (null? ws)
            l
            (let* ((w (car ws)) (k (plist-get w 'key)) (h (plist-get w 'win)))
              (if (integer? k)
                  (loop (cdr ws) l used)
                  (let ((new (if (and (integer? h) (not (member h used))) h (panes-key-source))))
                    (loop (cdr ws)
                          (panes--update-window l k (lambda (w) (panes--put (panes--put w 'win #f) 'key new)))
                          (cons new used)))))))))

(define (panes-layout? x)
  "#t when X is a well-formed layout, else #f. A layout saved in the
   old shape, its windows in a list of their own, is well formed too."
  ;; a plist whose panes are plists with an id, each holding windows that
  ;; are plists with a key (or keys, in the old shape). This Scheme has no
  ;; list?, so the shapes are walked by hand
  (let* ((plist? (lambda (v)
                   (let loop ((v v))
                     (cond ((null? v) #t)
                           ((and (pair? v) (symbol? (car v)) (pair? (cdr v))) (loop (cddr v)))
                           (else #f)))))
         (rows? (lambda (v ok?)
                  (or (not v)
                      (and (or (null? v) (pair? v))
                           (null? (filter (lambda (r) (not (ok? r))) v))))))
         (window? (lambda (w) (or (string? w) (and (plist? w) (plist-get w 'key) #t))))
         (pane? (lambda (p) (and (plist? p) (plist-get p 'id) (rows? (plist-get p 'windows) window?)))))
    (and (plist? x)
         (rows? (plist-get x 'panes) pane?)
         (rows? (plist-get x 'windows) (lambda (w) (and (plist? w) (plist-get w 'key) #t)))
         #t)))

;;; --- the api ------------------------------------------------------------
;;; Each level of the data has the same verbs. Every call takes a layout
;;; and answers a new one; one that makes something answers (LAYOUT NEW).
;;;
;;;   panes    panes-add-pane LAYOUT [AT]           -> (LAYOUT ID)
;;;            panes-remove-pane LAYOUT ID          its windows go with it
;;;            panes-move-pane LAYOUT ID AT         reorder
;;;   windows  panes-add-window LAYOUT PANE BUF MODE [BEHIND] -> (LAYOUT KEY)
;;;            panes-remove-window LAYOUT KEY       its pane stays
;;;            panes-move-window LAYOUT KEY PANE [AT]
;;;   buffers  panes-show-buffer LAYOUT BUF MODE [PANE] -> (LAYOUT KEY)
;;;            panes-remove-buffer LAYOUT BUF
;;;            panes-move-buffer LAYOUT BUF KEY
;;;   focus    panes-focus LAYOUT                   -> the focused pane's ID
;;;            panes-set-focus LAYOUT ID
;;;            panes-focus-window LAYOUT KEY        raise KEY, focus its pane
;;;
;;; A window is locked to its mode, so panes-show-buffer puts a buffer in
;;; its mode's window; a pane mixes modes by holding windows of different
;;; modes. panes-move-buffer is the explicit exception.

(domain! 'windows)
(effects! '(pure))

(define (panes-show-buffer layout buf mode &optional pane)
  "BUF shows, new or known: (LAYOUT KEY). The window of MODE that holds
   BUF, else MODE's window, takes BUF to its front and comes to the
   front of its pane; it does not leave that pane. When MODE has no
   window, a new one opens where the user is: in PANE, else in the
   first pane, else in a new pane."
  (let ((key (or (find (lambda (k) (equal? (panes-window-mode layout k) mode))
                       (panes-windows-holding layout buf))
                 (panes-mode-window layout mode)))
        (ids (panes-pane-ids layout)))
    (cond (key (list (panes-show layout key buf) key))
          ((and pane (panes-pane layout pane)) (panes-add-window layout pane buf mode))
          ((pair? ids) (panes-add-window layout (car ids) buf mode))
          (else (let ((added (panes-add-pane layout)))
                  (panes-add-window (car added) (cadr added) buf mode))))))

(define (panes-remove-buffer layout buf)
  "BUF leaves its window, and the next buffer of that window shows. A
   window it leaves empty closes, and the next window of its pane comes
   to the front; the pane stays."
  (panes-drop-buffer layout buf))

(public! 'panes-show-buffer "(panes-show-buffer LAYOUT BUF MODE [PANE]) -> (LAYOUT KEY): BUF to the front of its mode's window, that window to the front of its pane; a mode with no window gets a new one in PANE")
(catalog-meta! 'function "panes-show-buffer" 'effects '(read))
(public! 'panes-remove-buffer "(panes-remove-buffer LAYOUT BUF) -> LAYOUT: BUF leaves its window; the next buffer shows, an emptied window closes and the next window of its pane shows; pure")
(catalog-meta! 'function "panes-remove-buffer" 'effects '(pure))
(public! 'panes-split-off "(panes-split-off LAYOUT BUFS FROM) -> (LAYOUT KEY) | #f: BUFS move to a new window of FROM's mode beside FROM; pure")
(catalog-meta! 'function "panes-split-off" 'effects '(pure))
(public! 'panes-keys "(panes-keys PANE) -> (KEY ...): the keys of PANE's windows, the one on screen first; pure")
(catalog-meta! 'function "panes-keys" 'effects '(pure))
(public! 'panes-pane-keys "(panes-pane-keys LAYOUT ID) -> (KEY ...): the keys of pane ID's windows, the one on screen first; pure")
(catalog-meta! 'function "panes-pane-keys" 'effects '(pure))
(public! 'panes-add-pane "(panes-add-pane LAYOUT [AT]) -> (LAYOUT ID): a new empty pane at index AT, the end when absent; pure")
(catalog-meta! 'function "panes-add-pane" 'effects '(pure))
(public! 'panes-remove-pane "(panes-remove-pane LAYOUT ID) -> LAYOUT: pane ID goes with its windows; the last pane stays; pure")
(catalog-meta! 'function "panes-remove-pane" 'effects '(pure))
(public! 'panes-move-pane "(panes-move-pane LAYOUT ID AT) -> LAYOUT: pane ID moves to index AT with its windows; pure")
(catalog-meta! 'function "panes-move-pane" 'effects '(pure))
(public! 'panes-columns "(panes-columns LAYOUT) -> ((PANE ...) ...): the panes in columns, left to right, each top to bottom; pure")
(catalog-meta! 'function "panes-columns" 'effects '(pure))
(public! 'panes-split-below "(panes-split-below LAYOUT ID) -> (LAYOUT NEW-ID): an empty pane under pane ID in its column, the two halving ID's height; pure")
(catalog-meta! 'function "panes-split-below" 'effects '(pure))
(public! 'panes-move-column "(panes-move-column LAYOUT ID STEP) -> LAYOUT: pane ID's column moves STEP columns with all its panes; pure")
(catalog-meta! 'function "panes-move-column" 'effects '(pure))
(public! 'panes-swap-panes "(panes-swap-panes LAYOUT A B) -> LAYOUT: panes A and B trade their windows, each keeping its place and size; pure")
(catalog-meta! 'function "panes-swap-panes" 'effects '(pure))
(public! 'panes-add-window "(panes-add-window LAYOUT PANE BUF MODE [BEHIND]) -> (LAYOUT KEY): a new window of MODE on BUF at the front of PANE, or the back when BEHIND")
(catalog-meta! 'function "panes-add-window" 'effects '(read))
(public! 'panes-remove-window "(panes-remove-window LAYOUT KEY) -> LAYOUT: window KEY goes with its stack; its pane stays; pure")
(catalog-meta! 'function "panes-remove-window" 'effects '(pure))
(public! 'panes-move-window "(panes-move-window LAYOUT KEY PANE [AT]) -> LAYOUT: window KEY moves to PANE at index AT, the front when absent; the pane it leaves stays; pure")
(catalog-meta! 'function "panes-move-window" 'effects '(pure))
(public! 'panes-move-buffer "(panes-move-buffer LAYOUT BUF KEY) -> LAYOUT: BUF leaves its window for the front of window KEY; a window left empty closes")
(catalog-meta! 'function "panes-move-buffer" 'effects '(read))
(public! 'panes-focus "(panes-focus LAYOUT) -> ID: the focused pane; its front window is the focused window; pure")
(catalog-meta! 'function "panes-focus" 'effects '(pure))
(public! 'panes-set-focus "(panes-set-focus LAYOUT ID) -> LAYOUT: pane ID takes the focus; the draw selects it; pure")
(catalog-meta! 'function "panes-set-focus" 'effects '(pure))
(public! 'panes-focus-window "(panes-focus-window LAYOUT KEY) -> LAYOUT: KEY to the front of its pane, and its pane takes the focus; pure")
(catalog-meta! 'function "panes-focus-window" 'effects '(pure))
