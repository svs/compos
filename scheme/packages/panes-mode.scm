;;; panes-mode.scm --- the window model (panes.scm) on the frame.
;;;
;;; One layout per (frame, group). The applier lays the frame out as the
;;; model says: one window on screen per pane, in a row, with the pane's
;;; share of the width; every other window waits behind its pane with its
;;; stack, its point and its history. Every door asks the one policy:
;;; a visit, a display, a quit, a kill, a rename, a group switch.
;;;
;;;   M-x panes-adopt    read the frame as it stands into the model
;;;
;;; The model is the only window system: it is always on.

(require 'panes)
(require 'groups)
(require 'window-log)

(domain! 'windows)
(effects! '(write display))

;; a new model window's key is a fresh frame window id
(set! panes-key-source window-id-new!)
(define panes--applying #f)

;;; --- the store: one layout per (frame, group) -----------------------------------

(define (panes--store)
  "The layouts of this frame, ((GROUP LAYOUT) ...), from its frame-local
   panes-layouts."
  (or (frame-local 'panes-layouts) '()))
(define (panes--group-key)
  "The group of this frame, or none when it has none: the key of its
   layout in the store."
  (or (frame-group) 'none))

(define (panes-layout)
  "The layout of this frame's group, or #f."
  (panes-layout-of (panes--group-key)))

(define (panes-layout-of g)
  "The layout of group G on this frame, or #f. A #f G is the key none.
   A frame whose store has no entry for G, as after a restart, reads
   G's record (group-layout)."
  (let ((e (assoc (or g 'none) (panes--store))))
    (cond (e (cadr e))
          ((and (string? g) (group-resolve-id g)) (group-layout g))
          (else #f))))

(define (panes--sealed layout g)
  "Groups are sealed: a buffer another group holds never enters the
   model of G, whatever window showed it when the layout changed. A
   buffer of no group stays. Only a string G seals; another key keeps
   LAYOUT as it is."
  (if (string? g)
      (panes-validate layout (lambda (b) (or (not (buffer-group b)) (buffer-in-group? b g))))
      layout))

(define (panes--layout-store! g layout)
  "The raw write: LAYOUT, sealed to G, becomes the layout of G on this
   frame, and, when G is a group, the layout in G's record (group-layout). A change records in the layout
   history only through panes-layout-set!. Every stack entry is stored
   as a buffer id, and a layout that names no layout takes its group's. It draws nothing. Answers the sealed layout."
  (let* ((layout (panes--with-ids (panes--sealed layout g)))
         ;; a model saved before layouts were data takes its group's old setting
         (layout (if (panes-layout-name layout)
                     layout
                     (panes--put layout 'layout
                       (or (and (string? g) (group-setting g 'layout)) window-layout-default)))))
    (set-frame-local! 'panes-layouts (alist-put (panes--store) (or g 'none) layout))
    ;; the newest layout of a group, whichever frame made it, is its record's
    (when (and (string? g) (group-resolve-id g)) (group-layout-set! g layout))
    layout))

(define (panes--seed g)
  "The layout group G takes on a frame that has none: G's layout
   (group-layout), else the one of G on the first frame that has one;
   #f when there is none."
  (or (and g (group-layout g))
      (let loop ((fs (frame-list)))
        (if (null? fs)
            #f
            (let ((e (and g (assoc g (or (frame-local-in (car fs) 'panes-layouts) '())))))
              (if e (cadr e) (loop (cdr fs))))))))

(define (panes--seed! g)
  "The seed of group G, without the buffers that are no longer known,
   goes through panes-apply!. Answers the applied layout, or #f when G
   has no seed."
  (let ((seed (panes--seed g)))
    (and seed (panes-apply! (panes-validate seed buffer-known?)))))

(define (panes-layout-set! layout)
  "LAYOUT becomes the model of this frame's group. First each buffer
   goes to one window (panes-unique-buffers); then the layout is stored
   sealed (panes--layout-store!) and checked (panes--check-model!). It
   does not draw the frame: panes-apply! does that."
  (let ((layout (panes-unique-buffers layout)))
    (panes--layout-store! (panes--group-key) layout)
    (panes--check-model! layout)))

(define (panes-model-faults model)
  "What MODEL breaks of its own rules, as a list of text; () is none.
   Pure. The rule: one model window to each key, and a key is a frame
   window id, so one frame window to one model window."
  (let* ((keys (panes-window-keys model))
         (count (lambda (x xs) (length (filter (lambda (y) (equal? x y)) xs)))))
    (map (lambda (k) (format "model window ~a is in ~a places" k (count k keys)))
         (panes--uniq (filter (lambda (k) (> (count k keys) 1)) keys)))))

(define panes--last-faults '())

(define (panes--check-model! layout)
  "A broken LAYOUT is noted in the window log, and the echo area shows
   its first fault. The same faults are noted once, until they change.
   A #f LAYOUT has no faults. It does not repair the layout."
  ;; a model that breaks its rules is noted in the window log with the
  ;; command that broke it, once, so the break can be found
  (let ((faults (if layout (panes-model-faults layout) '())))
    (unless (or (null? faults) (equal? faults panes--last-faults))
      (window-log-note! "panes model broken" (string-join faults "; "))
      (message (string-append "panes: the window model broke: " (car faults))))
    (set! panes--last-faults faults)))

(define (panes-layout-forget!)
  "This frame's group loses its layout on this frame. Other frames and
   the group record keep theirs."
  (set-frame-local! 'panes-layouts (alist-delete (panes--store) (panes--group-key))))

;; --- across restarts -------------------------------------------------------
(define (panes-layouts-state)
  "Every frame's layouts as the desktop saves them: ((FRAME STORE) ...).
   A window id survives a restart (the desktop names it), and a model
   window whose frame window did not come back gets a frame window with
   its id when the frame next draws the layout."
  (map (lambda (frame) (list frame (or (frame-local-in frame 'panes-layouts) '())))
       (frame-list)))

(define (panes-layouts-restore! saved)
  "SAVED comes back: each frame that still exists takes its store, its
   windows keyed by frame window id (panes-rekey-legacy). An entry of
   another frame, or a malformed one, is ignored."
  (for-each (lambda (entry)
              (when (and (pair? entry) (pair? (cdr entry)) (member (car entry) (frame-list)))
                (set-frame-local-in! (car entry) 'panes-layouts
                  (map (lambda (e) (if (and (pair? e) (pair? (cdr e))) (list (car e) (panes-rekey-legacy (cadr e))) e))
                       (cadr entry)))))
            (or saved '())))

(persist-global! 'panes-layouts panes-layouts-state panes-layouts-restore!)
;; a restart brings new frame ids; the group records carry each group's
;; layout across

;;; --- the frame as a layout ---------------------------------------------------------

(define (panes--buffer-mode b)
  "The mode of buffer B, fundamental-mode when it names none; #f when B
   is not the name of a known buffer."
  (and (string? b) (buffer-known? b) (or (buffer-local b 'mode-name) "fundamental-mode")))

(define (panes--live-handle? h)
  "#t when H is a frame window on screen, else #f. A window off the
   screen is the model's alone: it has no frame window."
  (and h (window-exists? h) #t))

(define (panes--frame-row)
  "The work windows on screen, left to right by their left edge:
   (WIN BUF WIDTH) rows. Hidden windows do not count."
  (let* ((work (display--work-windows))
         (rects (filter (lambda (r) (member (car r) work)) (window-rects))))
    (let sort-x ((rows rects) (out '()))
      (if (null? rows)
          (map (lambda (r) (list (car r) (cadr r) (list-ref r 4))) out)
          (let ((r (car rows)))
            (sort-x (cdr rows)
                    (let ins ((os out))
                      (cond ((null? os) (list r))
                            ((< (list-ref r 2) (list-ref (car os) 2)) (cons r os))
                            (else (cons (car os) (ins (cdr os))))))))))))

(define (panes--window-stack win buf)
  "A window's stack as the model keeps it: what it shows, BUF, then its
   history. The history keeps only known buffers that fill-candidate?
   accepts; repeats go."
  (panes--uniq (cons buf (filter (lambda (b) (and (buffer-known? b) (fill-candidate? b)))
                                 (window-prev-buffers win)))))

(define (panes-waiting-windows)
  "The windows of this frame's layout that wait off the screen, pane by
   pane, as (KEY BUFFER) rows. A window off the screen has no frame
   window: the model alone keeps it."
  (let ((l (panes-layout)))
    (if (not l)
        '()
        (filter (lambda (r) (cadr r))
                (map (lambda (k) (list k (panes-window-buffer l k)))
                     (filter (lambda (k) (not (window-exists? k))) (panes-window-keys l)))))))

(define (panes-adopt)
  "The frame as it stands: one pane per window on screen, left to right,
   each holding that window, with the window's width as its share. It
   reads the frame and stores nothing: panes-adopt! stores."
  (let loop ((rows (panes--frame-row)) (layout (panes-empty)))
    (if (null? rows)
        layout
        (let* ((win (car (car rows))) (buf (cadr (car rows))) (width (caddr (car rows)))
               (added (panes-add-pane layout))
               (l (panes-set-share (car added) (cadr added) width))
               (made (panes-add-window l (cadr added) buf (panes--buffer-mode buf)))
               (l (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))))
          (loop (cdr rows) (panes-set-handle l (cadr made) win))))))

(define (panes-adopt!)
  "The frame as it stands (panes-adopt), folded to the capacity, becomes
   this group's model through panes-layout-set!. It does not draw."
  (panes-layout-set! (panes-fit-capacity (panes-adopt))))

;;; --- apply: the frame becomes the model -----------------------------------------------

;; an empty pane holds no window of the model; the frame shows it as a window
;; on the blank buffer. The pane keeps that window's id in 'blank
(define panes-empty-buffer " *pane*")

;; the blank window says what it is and shows its keymap: the text muted, the keys not
(defface! 'pane-empty-text 'fg "var(--dim-fg)")
(defface! 'pane-empty-key 'inherit 'mono 'fg "var(--default-fg)" 'weight "600" 'priority 10)

(define (panes--empty-keys)
  "The keymap of pane-empty-mode as ((COMMAND (KEY ...)) ...), in the
   order the keys were bound."
  (let loop ((bs (reverse (keymap-bindings (mode-keymap "pane-empty-mode")))) (rows '()))
    (if (null? bs)
        (reverse rows)
        (let* ((k (car (car bs))) (c (cadr (car bs))))
          (loop (cdr bs)
                (if (assoc c rows)
                    (map (lambda (r) (if (equal? (car r) c) (list c (append (cadr r) (list k))) r)) rows)
                    (cons (list c (list k)) rows)))))))

(define panes--empty-labels
  ;; the short words a key wears in the empty pane; a command not here shows its doc
  '(("pane-take-window" "Move a window here")
    ("find-file" "Open a file")
    ("pane-remove" "Remove this pane")))

(define (panes--empty-blocks)
  "The blank buffer as blocks: a dashed frame, a title, one line on what
   the pane is, and one action for each command of pane-empty-mode, its
   first key beside it. A click runs the command (block-click panes)."
  (list
    (list 'tag "div" 'class "pane-empty"
          'children
          (list (list 'tag "div" 'class "pane-empty-frame" 'text "")
                (list 'tag "div" 'class "pane-empty-title" 'text "Empty pane")
                (list 'tag "div" 'class "pane-empty-sub" 'text "Move a window in, or open something here.")
                (component 'ui/actions
                  (list 'class "pane-empty-actions"
                        'actions (map (lambda (row)
                                        (let* ((cmd (car row)) (e (assoc cmd panes--empty-labels)))
                                          (append (list (string-append "pane:" cmd)
                                                        (if e (cadr e) (or (command-doc cmd) cmd))
                                                        (string-join (cadr row) " "))
                                                  (if (equal? cmd "pane-remove") '("quiet") '()))))
                                      (panes--empty-keys))))))))

(define (panes--empty-render!)
  "Writes the blank buffer: blocks for the page (panes--empty-blocks),
   and under them a text of a title and one line for each command of
   pane-empty-mode, its keys and its doc, for a client that draws text.
   The keys take the face pane-empty-key, all the text pane-empty-text."
  (let loop ((rows (panes--empty-keys)) (text "\n   Empty pane\n\n") (spans '()))
    (if (null? rows)
        (begin
          (buffer-set-text! panes-empty-buffer text #t)
          (overlay-set! panes-empty-buffer 'pane-empty
                        (cons (list 0 (string-length text) "pane-empty-text") spans))
          (buffer-set-local! panes-empty-buffer 'render-blocks (panes--empty-blocks))
          (buffer-set-local! panes-empty-buffer 'render-mode "blocks"))
        (let* ((keys (string-join (cadr (car rows)) " "))
               (start (+ (string-length text) 3))
               (doc (or (command-doc (car (car rows))) (car (car rows)))))
          (loop (cdr rows)
                (string-append text "   " (string-pad-right keys (max 8 (+ 2 (string-length keys)))) doc "\n")
                (cons (list start (+ start (string-length keys)) "pane-empty-key") spans))))))

;; an action of the empty pane runs its command in the pane clicked
(add-hook! (list 'block-click 'panes)
  (lambda (buf id)
    (and (equal? buf panes-empty-buffer)
         (string-prefix? "pane:" id)
         (begin (run-command (substring id 5 (string-length id))) #t))))

(define-style! 'pane-empty "
.pane-empty { display: flex; flex-direction: column; align-items: center;
  padding: 18vh 24px 24px; gap: 6px; text-align: center; }
.pane-empty-frame { width: 64px; height: 44px; margin-bottom: 14px;
  border: 1.5px dashed var(--dim-fg); border-radius: 8px; opacity: 0.55; }
.pane-empty-title { font-size: 1.15em; font-weight: 600; color: var(--default-fg); }
.pane-empty-sub { color: var(--dim-fg); font-size: 0.92em; margin-bottom: 16px; }
.pane-empty-actions { display: flex; flex-direction: column; align-items: stretch;
  gap: 4px; min-width: 220px; }
.pane-empty-actions .c-action { justify-content: flex-start; }
.pane-empty-actions .c-action.quiet { opacity: 0.7; }
")

(define-mode "pane-empty-mode"
  (lambda () (panes--empty-render!)))

(define-command "pane-take-window" "Move a window of this group into this pane"
  (lambda ()
    (let* ((l (panes--ensure-layout!))
           (pid (panes--current-pane l))
           (rows (filter (lambda (r) (car r))
                         (map (lambda (k) (list (panes-window-buffer l k) k))
                              (filter (lambda (k) (not (equal? (panes-pane-of l k) pid))) (panes-window-keys l))))))
      (if (or (not pid) (null? rows))
          (message "No window to move here")
          (completing-read "Move window here: " (map car rows)
            (lambda (choice)
              (let ((row (assoc choice rows)))
                (when row
                  (let ((l (panes-layout)))
                    (panes-apply! (panes-focus-window (panes-move-window l (cadr row) pid) (cadr row)))))))
            'require-match #t)))))

(define-command "pane-remove" "Remove this empty pane"
  (lambda () (run-command "delete-window")))

(mode-keys! "pane-empty-mode"
  '(("b" "pane-take-window") ("RET" "pane-take-window")
    ("f" "find-file") ("k" "pane-remove")))

(define (panes--empty-buffer!)
  "Makes the blank buffer in pane-empty-mode, unless it is there in that
   mode already."
  (unless (and (buffer-exists? panes-empty-buffer)
               (equal? (buffer-local panes-empty-buffer 'mode-name) "pane-empty-mode"))
    (buffer-create panes-empty-buffer)
    (with-current-buffer panes-empty-buffer (lambda () (set-mode! "pane-empty-mode")))))

(define (panes--blank l pid)
  "The blank window pane PID of L keeps, or #f."
  (let ((pane (panes-pane l pid))) (and pane (plist-get pane 'blank))))

(define (panes--empty-handle pid)
  "The blank window of pane PID in this frame's model, or #f when it has
   none or the window is gone."
  (let* ((l (panes-layout)) (h (and l (panes--blank l pid))))
    (and h (panes--live-handle? h) h)))

(define (panes--empty-pane-of win)
  "The pane of this frame's model that frame window WIN stands for while
   the pane is empty, or #f."
  (let* ((l (panes-layout))
         (p (and l win (find (lambda (p) (and (equal? (plist-get p 'blank) win) (null? (panes-keys p))))
                             (panes-panes l)))))
    (and p (plist-get p 'id))))

(define (panes--blanks layout)
  "LAYOUT with a blank window id on every empty pane: the one it keeps,
   else a new one. The draw makes the frame window on the blank buffer."
  (fold (lambda (l p)
          (let ((pid (plist-get p 'id)) (h (plist-get p 'blank)))
            (cond ((pair? (panes-keys p)) l)
                  (else
                    (panes--empty-buffer!)
                    (if h l (panes--update-pane l pid (lambda (p) (panes--put p 'blank (window-id-new!)))))))))
        layout (panes-panes layout)))

(define (panes--claim-empty-windows layout)
  "A pane that took a window gives its blank window to that window, so
   the frame window stays: the front window takes the blank id as its key
   when it has no live frame window. A pane with a window keeps no
   blank; a blank window nothing took leaves the screen with the draw."
  (fold (lambda (l p)
          (let* ((ks (panes-keys p)) (pid (plist-get p 'id)) (h (plist-get p 'blank)))
            (cond ((or (not h) (null? ks)) l)
                  ((and (panes--live-handle? h) (not (panes--live-handle? (car ks))))
                   (panes--update-pane (panes-set-handle l (car ks) h) pid (lambda (p) (panes--put p 'blank #f))))
                  (else (panes--update-pane l pid (lambda (p) (panes--put p 'blank #f)))))))
        layout (panes-panes layout)))

(define (panes--pane-handles layout)
  "A line item for every pane, left to right: the frame window of its
   front window, else of its blank one (panes--blanks gave the id). A
   window off the screen gives (ID BUFFER), so the arrange makes it. A
   front window whose buffer is not known gives #f."
  (map (lambda (p)
         (let* ((ks (panes-keys p))
                (h (if (pair? ks) (panes-handle layout (car ks)) (plist-get p 'blank)))
                (buf (if (pair? ks) (panes-window-buffer layout (car ks)) panes-empty-buffer)))
           (cond ((not h) #f)
                 ((window-exists? h) h)
                 ((and buf (buffer-known? buf)) (list h buf))
                 (else #f))))
       (panes-panes layout)))

(define (panes--focus-follows! win)
  "A selection is a focus change in the model: the pane of WIN, an
   empty pane's blank window included, takes the focus, and WIN comes
   to the front of that pane. The select-window! door calls it before
   the frame selects WIN. It writes with panes--layout-store!, so the
   layout history does not record it."
  (let* ((l (panes-layout))
         (k (and l (panes-key-of-handle l win)))
         (p (and l (if k (panes-pane-of l k) (panes--empty-pane-of win)))))
    (when p
      (let ((after (if k (panes-focus-window l k) (panes-set-focus l p))))
        (unless (equal? after l)
          (panes--layout-store! (panes--group-key) after))))))

(define (panes--focus-handle layout handles)
  "The frame window of the focused pane: its front window, or its blank
   window when it is empty. The first of HANDLES when that is not among
   them."
  (let* ((p (panes-focus layout))
         (ks (and p (panes-pane-keys layout p)))
         (h (and p (if (pair? ks) (panes-handle layout (car ks)) (panes--blank layout p)))))
    (if (and h (member h handles)) h (car handles))))

(define (panes--park-points! layout leaving)
  "Every window in LEAVING that a layout of this frame holds keeps its
   point there, as LAYOUT does: the window leaves the screen and only
   the model remembers it. Answers LAYOUT with the points."
  (let ((park (lambda (l)
                (fold (lambda (l h)
                        (if (panes-window l h) (panes-set-window-point l h (window-buffer h) (window-point h)) l))
                      l leaving))))
    (for-each (lambda (e)
                (let ((after (park (cadr e))))
                  (unless (equal? after (cadr e)) (panes--layout-store! (car e) after))))
              (panes--store))
    (park layout)))

(define (panes--column-items layout items)
  "ITEMS, one line item for each pane in pane order, as one arrange spec
   for each column: a column of one pane is its item, a stacked column
   is a line, top to bottom, of its items at their heights."
  (let loop ((cols (panes-columns layout)) (items items) (acc '()))
    (if (null? cols)
        (reverse acc)
        (let* ((n (length (car cols))) (mine (list-head items n)))
          (loop (cdr cols) (list-tail items n)
                (cons (if (= n 1) (car mine) (list 'v (panes-vshares (car cols)) mine)) acc))))))

(define (panes--draw! layout)
  "The frame drawn as LAYOUT: every top window on screen with its
   pane's share, showing the front of its stack, the rest waiting
   behind; an empty pane shows its blank window. First the panes take
   their blank windows. A window that leaves the screen keeps its point
   in the model (panes--park-points!) and its frame window goes; one
   that comes back is made with its id and takes that point again. It
   arranges the frame only when every pane has a line item; else the
   screen stays as it was. The focused pane's window is selected
   (panes--focus-handle), whatever was selected before. Answers the
   layout with the handles the draw took or made. Nothing is recorded:
   panes-apply! stores the model anyway, also when the draw did not
   arrange."
  (let* ((layout (panes--blanks (panes--claim-empty-windows layout)))
         (tops (panes-top-windows layout))
         (items (panes--pane-handles layout))
         (handles (map (lambda (i) (if (pair? i) (car i) i)) items))
         (drawn layout))
    (set! panes--applying #t)
    (unwind-protect
      (lambda ()
        (when (and (pair? items) (null? (filter (lambda (i) (not i)) items)))
            (let* ((float (and (boundp 'float-window) (float-window)))
                   (leaving (filter (lambda (w) (not (or (member w handles) (equal? w float))))
                                    (map car (window-list))))
                   (layout (panes--park-points! layout leaving))
                   (made (filter (lambda (h) (not (window-exists? h))) handles)))
              ;; the floating preview is no pane: it stays on screen, first in the
              ;; line, where its split takes no room and it floats over the frame
              (let ((shares (panes-layout-shares layout #t)) (cols (panes--column-items layout items)))
                (if (and float (not (member float handles)))
                    (window-arrange! (list 'h (cons 0.001 shares) (cons float cols)))
                    (window-arrange! (list 'h shares cols))))
              (for-each
                (lambda (k)
                  (let ((h (panes-handle layout k)) (bufs (panes-window-buffers layout k)))
                    ;; an id no buffer has is no name: showing it would make a buffer of it
                    (when (and h (pair? bufs) (window-exists? h) (buffer-known? (car bufs)))
                      (unless (equal? (window-buffer h) (car bufs))
                        (window-set-buffer! h (car bufs)))
                      (set-window-prev-buffers! h (cdr bufs))
                      (let ((pos (and (member h made) (panes-window-point layout k))))
                        (when pos (window-set-point! h pos))))))
                tops)
              ;; the screen is a projection of the model: whatever the arrange
              ;; selected, the draw ends on the focused pane's window
              (let ((target (panes--focus-handle layout handles)))
                (unless (or (not target) (not (window-exists? target)) (equal? (active-window) target))
                  (select-window! target)))
              (set! drawn layout))))
      (lambda () (set! panes--applying #f)))
    drawn))

(define (panes--group-buffers &optional held)
  "The open buffers of this frame's group, each to be in a window. The
   read model answers the group's names; only the ones not in HELD are
   checked further: no leading space, fill-candidate?, and not
   context-only."
  (let* ((group (or (frame-group) (and (boundp 'group-cycle-group) (group-cycle-group))))
         (names (if group (group-buffers group #t) '())))
    (filter (lambda (b) (or (and held (member b held))
                            (and (not (string-prefix? " " b))
                                 (fill-candidate? b)
                                 (not (buffer-context-only? b)))))
            names)))

(define (panes-apply! layout)
  "The frame follows LAYOUT and it becomes this group's model. In
   order: each buffer goes to one window, the frame is drawn
   (panes--draw!), the layout is stored (panes-layout-set!), and
   window-state-changed! runs. It stores the layout also when the draw
   did not arrange the frame. Answers the drawn layout."
  ;; a buffer is in one window, whatever made this layout. Only the
  ;; layout's own windows are drawn: a member of the group with no window
  ;; stays without one until the user opens it
  (let ((layout (panes--draw! (panes-unique-buffers layout))))
    (panes-layout-set! layout)
    (window-state-changed!)
    layout))

(define (panes-look! layout &optional g)
  "A look: the frame shows LAYOUT and nothing is recorded as a change.
   The model of group G keeps the handles the look made, so the switch
   into G finds its windows on screen already. Without G nothing is
   stored. It does not run window-state-changed!."
  (let ((layout (panes--draw! layout)))
    (when g (panes--layout-store! g layout))
    layout))

;;; --- the doors ------------------------------------------------------------------------

(define (panes--recent layout)
  "Window keys, the most recently seen first, by the buffer each shows.
   A window whose buffer was never seen counts as the oldest."
  (let ((seen (lambda (k) (let ((b (panes-window-buffer layout k))) (or (and b (buffer-last-seen b)) 0)))))
    (let sort-seen ((ks (panes-window-keys layout)) (out '()))
      (if (null? ks)
          out
          (sort-seen (cdr ks)
                     (let ins ((os out))
                       (cond ((null? os) (list (car ks)))
                             ((> (seen (car ks)) (seen (car os))) (cons (car ks) os))
                             (else (cons (car os) (ins (cdr os)))))))))))

(define (panes--selected-pane layout)
  "The pane the user is in: the pane of the selected window, else the
   empty pane the selection stands in, else #f."
  (let ((key (panes-key-of-handle layout (active-window))))
    (or (and key (panes-pane-of layout key))
        (panes--empty-pane-of (active-window)))))

(define (panes--ensure-layout!)
  "The layout of this frame's group. When it has none: the group's seed
   (panes--seed!), else the frame as it stands (panes-adopt!)."
  (or (panes-layout) (panes--seed! (frame-group)) (panes-adopt!)))

(define (panes-place! buf kind)
  "BUF shows where panes-show-buffer says: its mode's window, else a
   new window in the pane the user is in. A visit (KIND visit) also
   gives that window the focus; a display leaves the focus. panes-apply!
   draws and stores the layout, and the window log notes KIND. Answers
   the window's handle, or #f."
  (let* ((layout (panes--ensure-layout!))
         (mode (panes--buffer-mode buf))
         (shown (panes-show-buffer layout buf mode (panes--selected-pane layout)))
         (after (if (equal? kind 'visit) (panes-focus-window (car shown) (cadr shown)) (car shown)))
         (layout (panes-apply! after)))
    (window-log-note! "panes" kind buf mode "->" (cadr shown))
    (panes-handle layout (cadr shown))))

(define (panes-display-beside! buf owner)
  "A display of BUF in the pane beside OWNER's, never on top of OWNER:
   the pane after it, else a new pane after it while the layout has
   room, else the pane before it. In that pane BUF takes the window of
   its mode, else a new window at the front. The focus stays. Without
   a pane beside, or when OWNER is in no window, a plain display.
   Answers the window's handle, or #f."
  (let* ((l (panes--ensure-layout!))
         (ok (and owner (panes-find l owner)))
         (from (and ok (panes-pane-of l ok)))
         (ids (panes-pane-ids l))
         (i (and from (panes--index-of from ids)))
         (to (cond ((not i) #f)
                   ((< (+ i 1) (length ids)) (list l (list-ref ids (+ i 1))))
                   ((panes-under-capacity? l) (panes-add-pane l (+ i 1)))
                   ((> i 0) (list l (list-ref ids (- i 1))))
                   (else #f))))
    (if (not to)
        (panes-display! buf)
        (let* ((mode (panes--buffer-mode buf))
               (l (car to)) (pid (cadr to))
               (same (find (lambda (k) (equal? (panes-window-mode l k) mode)) (panes-pane-keys l pid)))
               (placed (if same
                           (list (if (member buf (panes-window-buffers l same))
                                     (panes-show l same buf)
                                     (panes-show (panes-drop-buffer l buf) same buf))
                                 same)
                           (panes-add-window (panes-drop-buffer l buf) pid buf mode)))
               ;; the window comes to the front of its pane; the focus stays
               (l (panes-raise (car placed) (cadr placed)))
               (drawn (panes-apply! l)))
          (window-log-note! "panes display beside" buf owner "->" (cadr placed))
          (panes-handle drawn (cadr placed))))))

(define (panes-visit! buf)
  "A visit: BUF shows and its window takes the focus. Answers the
   handle, or #f."
  (panes-place! buf 'visit))

(define (panes-display! buf)
  "A display: BUF shows, the selection stays."
  (panes-place! buf 'display))

(define (panes-consolidate!)
  "Consolidate on the model: every mode one window. The buffers of the frame's group that
   no window holds join too, except context-only ones. The selected
   window stays selected when it still exists. Answers that window."
  (let* ((me (active-window))
         ;; the group's buffers no window holds any more join behind their mode's window
         (g (frame-group))
         (after (panes-consolidate (panes--ensure-layout!) panes--buffer-mode #f
                                   (filter (lambda (b) (not (buffer-context-only? b))) (group-buffers g #t)))))
    (window-log-note! "panes consolidate")
    (panes-apply! (let ((k (panes-key-of-handle after me))) (if k (panes-focus-window after k) after)))
    (message (string-append "Consolidated into " (number->string (length (panes-window-keys after))) " windows"))
    me))

(define (panes-quit! win)
  "q in WIN: its shown buffer leaves that window and the next one shows;
   an exhausted window closes. The pane where the buffer stood keeps
   the focus. The buffer is not killed. #t when the
   model knew the window; #f, and nothing changes, when it did not."
  (let* ((layout (panes-layout))
         (k (and layout (panes-key-of-handle layout win))))
    (and k
         (let ((popped (panes-pop layout k)) (pid (panes-pane-of layout k)))
           (window-log-note! "panes quit" k "->" (or (cadr popped) "window closes"))
           ;; quitting leaves you where the buffer stood
           (panes-apply! (if pid (panes-set-focus (car popped) pid) (car popped)))
           #t))))

(define (panes--kill-repair! name)
  "A buffer dies: it leaves every stack before the core looks for a
   stand-in. The keyed hook (buffer-kill-repair KEY) answers a thunk for
   after the kill, or #f when it has nothing to say; the first answer
   wins, so the group repair stands down. #f when the layout does not
   hold NAME. An emptied pane stays, empty."
  (let ((layout (panes-layout)))
    (and layout (member name (panes-buffers layout))
         (begin
           (window-log-note! "panes kill" name)
           (panes-apply! (panes-drop-buffer layout name))
           (lambda () (window-state-changed!))))))

(define (panes--rename! old new)
  "A renamed buffer keeps its id, so no layout changes: the model holds
   ids. The id-to-name map is read again on the next lookup."
  (panes--names-forget!))

(define (panes--enter-group!)
  "The frame enters a group: its layout comes back, or the frame is
   read in. The layout target stands down: the model owns the shape
   now. A stored layout is applied without the buffers that are no
   longer known; else the group's seed, else the frame as it stands.
   Then layout-modeline! runs."
  (window-log-note! "panes enter group" (or (frame-group) "none"))
  (let ((layout (panes-layout)))
    (if layout
        (panes-apply! (panes-validate layout buffer-known?))
        (or (panes--seed! (frame-group)) (panes-adopt!))))
  (layout-modeline!))

;;; --- the mode ---------------------------------------------------------------------------

(define (panes--door?)
  "#t when a door goes through the model: buffer-context? is #f and the
   model does not draw."
  (and (not (buffer-context?)) (not panes--applying)))

(define (panes--default-layout bufs)
  "One pane per buffer of BUFS, left to right, equal shares: a group's
   first layout. It does not fold to the capacity."
  (fold (lambda (l b)
          (let* ((added (panes-add-pane l))
                 (made (panes-add-window (car added) (cadr added) b (panes--buffer-mode b))))
            (car made)))
        (panes-empty)
        bufs))

;;; --- the frame primitives are doors ----------------------------------------------
;;; A primitive that changes the frame changes the
;;; model instead, and the draw shows it. Nothing reads the frame back
;;; after a change: no hook writes the model, so no hook can loop.

(define (panes--show-follows! win buf)
  "window-set-buffer!: BUF comes to the front of the model window that
   WIN draws. In an empty pane's blank window, BUF fills that pane with
   a new window on WIN. Another window changes nothing here."
  (let* ((l (panes-layout))
         (k (and l (panes-key-of-handle l win)))
         (pid (and l (not k) (panes--empty-pane-of win))))
    (cond ((not (and l (fill-candidate? buf))) #f)
          (k (unless (equal? (panes-window-buffer l k) buf)
               (panes-layout-set! (panes-show l k buf))))
          ((and pid (panes-pane l pid))
           ;; the blank window becomes the pane's window: it takes its id
           (let ((made (panes-add-window l pid buf (panes--buffer-mode buf))))
             (panes-layout-set!
               (panes--update-pane (panes-set-handle (car made) (cadr made) win) pid
                 (lambda (p) (panes--put p 'blank #f)))))))))

(define (panes--delete-window!)
  "C-x 0: the pane of the selected window goes with its windows; in the
   last pane only the window goes, when another window waits behind it.
   An empty pane's blank window takes its pane. Answers #f, and nothing
   changes, for the sole window."
  (let* ((l (panes--ensure-layout!))
         (me (active-window))
         (k (panes-key-of-handle l me))
         (pid (if k (panes-pane-of l k) (panes--empty-pane-of me)))
         (gone (and pid (panes-remove-pane l pid)))
         (after (cond ((not pid) l)
                      ((not (equal? gone l)) gone)
                      ;; the last pane loses a window only when another waits behind it
                      ((and k (> (length (panes-pane-keys l pid)) 1)) (panes-remove-window l k))
                      (else l))))
    ;; Emacs deletes the window: its frame window goes, its buffers stay open
    (and (not (equal? after l))
         (begin (panes-apply! after) #t))))

(define (panes--delete-other-windows!)
  "C-x 1: the focused pane is the one pane. The windows of the other
   panes wait behind its windows, in pane order, so no buffer closes."
  (let* ((l (panes--ensure-layout!))
         (me (active-window))
         (k (panes-key-of-handle l me))
         (pid (or (and k (panes-pane-of l k)) (panes--empty-pane-of me) (panes-focus l)))
         (others (filter (lambda (p) (not (equal? p pid))) (panes-pane-ids l)))
         (moved (fold (lambda (l p)
                        (panes-remove-pane
                          (fold (lambda (l key) (panes-move-window l key pid (length (panes-pane-keys l pid))))
                                l (panes-pane-keys l p))
                          p))
                      l others)))
    (panes-apply! (panes-set-focus moved pid))
    #t))

(define (panes--split-window! &optional dir)
  "C-x 3, and C-x 2 when DIR is v: an empty pane opens right of the
   focused pane, or under it in its column, and the next fill buffer
   shows in it when the fill rule names one. The selection stays.
   Answers the new pane's frame window, or #f."
  (let* ((l (panes--ensure-layout!))
         (me (active-window))
         (k (panes-key-of-handle l me))
         (pid (or (and k (panes-pane-of l k)) (panes--empty-pane-of me) (panes-focus l)))
         (added (if (equal? dir 'v) (panes-split-below l pid) (panes-add-empty-pane l pid)))
         (action (window-fill-decide (list 'shown (panes-buffers l)) (window-fill-buffers)))
         (buf (and (equal? (car action) 'show) (cadr action)))
         (after (if buf
                    (car (panes-add-window (car added) (cadr added) buf (panes--buffer-mode buf)))
                    (car added)))
         (drawn (panes-apply! (panes-set-focus after pid)))
         (ks (panes-pane-keys drawn (cadr added))))
    (if (pair? ks) (panes-handle drawn (car ks)) (panes--empty-handle (cadr added)))))

(define (panes--panes-tile! algorithm buffers)
  "C-x l and every caller of panes-tile!: a layout is a capacity and
   an order. The capacity becomes that of ALGORITHM, and BUFFERS, up to
   it, front the panes from the left: a buffer of a window already used
   leaves it for a new window. Panes past the buffers fold into the
   last one, and the first pane takes the focus. Answers the front
   buffers, or #f for an unknown layout or no buffer."
  (let* ((cap (panes-layout-capacity algorithm))
         (bufs (let cut ((bs (panes--uniq (filter (lambda (b) (and (string? b) (buffer-known? b))) buffers)))
                         (n (or cap 0)))
                 (if (or (null? bs) (<= n 0)) '() (cons (car bs) (cut (cdr bs) (- n 1)))))))
    (cond
      ((not cap) (message "Unknown window layout") #f)
      ((null? bufs) (message "No live buffers to arrange") #f)
      (else
        (let* ((l (let place ((l (panes--ensure-layout!)) (i 0) (bs bufs) (used '()))
                    (if (null? bs)
                        l
                        (let* ((l (let grow ((l l))
                                    (if (> (panes-pane-count l) i) l (grow (car (panes-add-pane l))))))
                               (pid (list-ref (panes-pane-ids l) i))
                               (b (car bs))
                               (k (panes-find l b)))
                          (if (and k (not (member k used)))
                              (place (panes-move-window (panes-show l k b) k pid 0) (+ i 1) (cdr bs) (cons k used))
                              (let ((made (panes-add-window (panes-remove-buffer l b) pid b (panes--buffer-mode b))))
                                (place (car made) (+ i 1) (cdr bs) (cons (cadr made) used))))))))
               (l (panes--put (panes-set-capacity (panes-fit-capacity (panes-set-capacity l (length bufs))) cap) 'layout algorithm))
               (drawn (panes-apply! (panes-set-focus (panes-equalize l) (car (panes-pane-ids l))))))
          (map (lambda (k) (panes-window-buffer drawn k)) (panes-top-windows drawn)))))))

;;; --- layouts -------------------------------------------------------------------
;;; The layouts a group can take (define-layout!, panes.scm). The model of
;;; a group names its layout; panes-current-layout reads it and
;;; panes-choose-layout! sets it.

(define (panes--even-but-last n r)
  ;; N shares: the last is R, the others split what is left
  (let loop ((i 1) (acc (list r)))
    (if (>= i n) acc (loop (+ i 1) (cons (/ (- 1 r) (- n 1)) acc)))))

(define-layout! 'single 'capacity 1 'doc "one window")
(define-layout! 'two-pane 'capacity 2 'doc "2/3 + 1/3 side by side"
  'shares (lambda (n)
            (and (= n 2) (number? window-layout-main-ratio)
                 (list window-layout-main-ratio (- 1 window-layout-main-ratio)))))
(define-layout! 'halves 'capacity 2 'doc "two equal panes side by side")
(define-layout! 'columns 'capacity (lambda () window-layout-columns) 'doc "equal columns")
(define-layout! 'two-chat 'capacity 3 'doc "two equal panes and a narrow chat"
  'shares (lambda (n)
            (and (> n 1) (number? window-layout-chat-ratio)
                 (panes--even-but-last n window-layout-chat-ratio))))
(define-layout! 'free 'capacity 8 'doc "as many panes as you open")

(define (panes--layout-default)
  "The layout a model with none takes: the group's old layout setting,
   else window-layout-default."
  (let ((g (frame-group)))
    (or (and g (group-setting g 'layout)) window-layout-default)))

(define (panes-current-layout)
  "The layout of this frame's group, from its model; #f when it is free."
  (let* ((l (panes-layout))
         (n (or (and l (panes-layout-name l)) (panes--layout-default))))
    (if (equal? n 'free) #f n)))

(define (panes-choose-layout! name)
  "NAME, #f for free, becomes the layout of this frame's group, and the
   frame draws it. Answers NAME."
  (panes-apply! (panes-set-layout (panes--ensure-layout!) (or name 'free)))
  (layout-modeline!)
  name)

(define (panes-shown-buffers)
  "What the panes show, left to right."
  (let ((l (panes-layout))) (if l (map caddr (panes-visible l)) '())))

(define (panes-tile! algorithm buffers)
  "BUFFERS front the panes of layout ALGORITHM (panes--panes-tile!)."
  (panes--panes-tile! algorithm buffers))

(define (layout-for-count count)
  (cond ((<= count 1) 'single) ((<= count 2) 'two-pane) (else 'columns)))

(define (panes-tile-default! buffers)
  "BUFFERS front the panes of this group's layout, else of the layout that
   holds them."
  (panes-tile! (or (panes-current-layout) (layout-for-count (length buffers))) buffers))

(define (panes-raise-window! win)
  "Frame window WIN comes to the front of its pane and takes the focus;
   #f when the model holds no such window."
  (let* ((l (panes--ensure-layout!)) (k (panes-key-of-handle l win)))
    (and k (panes-apply! (panes-focus-window l k)))))

(public! 'panes-current-layout "(panes-current-layout) -> the layout of this frame's group, or #f when free")
(catalog-meta! 'function "panes-current-layout" 'effects '(read))
(public! 'panes-choose-layout! "(panes-choose-layout! NAME) -> NAME becomes this group's layout and the frame draws it; #f is free")
(public! 'panes-shown-buffers "(panes-shown-buffers) -> the buffers the panes show, left to right")
(catalog-meta! 'function "panes-shown-buffers" 'effects '(read))
(public! 'panes-tile! "(panes-tile! LAYOUT BUFFERS) -> BUFFERS front the panes of LAYOUT")
(public! 'panes-tile-default! "(panes-tile-default! BUFFERS) -> BUFFERS front the panes of this group's layout")
(public! 'panes-raise-window! "(panes-raise-window! WIN) -> WIN comes to the front of its pane and takes the focus")

(define (apply-layout! anchor spec)
  "The frame as SPEC says (define-mode-layout!): its buffers front the
   panes, left to right, the first at SPEC's ratio and the rest equal;
   the window of ANCHOR takes the focus. The group keeps its layout
   while it has room for them, else it goes free. Answers the buffers."
  (let ((bufs (layout--panes anchor spec)))
    (when (pair? bufs)
      (let* ((name (panes-current-layout))
             (cap (and name (panes-layout-capacity name)))
             (algorithm (if (and cap (>= cap (length bufs))) name 'free)))
        (panes--panes-tile! algorithm bufs)
        (let* ((l (panes-layout))
               (n (length bufs))
               (r (layout--ratio spec))
               (r (if (and (number? r) (> r 0) (< r 1)) r (/ 1 n)))
               (ids (panes-pane-ids l))
               (l (if (> n 1)
                      (let loop ((ids ids) (i 0) (l l))
                        (if (or (null? ids) (>= i n))
                            l
                            (loop (cdr ids) (+ i 1)
                                  (panes-set-share l (car ids) (if (= i 0) r (/ (- 1 r) (- n 1)))))))
                      l))
               (k (panes-find l anchor)))
          (panes-apply! (if k (panes-focus-window l k) l)))))
    bufs))

(define (panes--layout-prompt!)
  "C-x l: a layout for this group. Moving through the list shows each
   one; the choice keeps it, and C-g gives back the layout you had."
  (let ((before (panes--ensure-layout!)))
    (minibuffer-read-preview "Window layout: "
      (map (lambda (n) (list (symbol->string n) (or (plist-get (panes-layout-spec n) 'doc) "")))
           (panes-layout-names))
      (lambda (name) (panes-look! (panes-set-layout before (string->symbol name))))
      (lambda (name) (panes-choose-layout! (string->symbol name)) (message (string-append "Layout " name)))
      (lambda () (panes-apply! before))
      #f #f #f #f
      '(("1" "single") ("2" "two-pane") ("=" "halves") ("c" "columns") ("+" "two-chat") ("f" "free")))))

(define-command "window-layout" "Choose this group's layout; each one shows as you move to it"
  panes--layout-prompt!)
(define-command "window-layout-single" "One window" (lambda () (panes-choose-layout! 'single)))
(define-command "window-layout-two-pane" "Two panes, the first two thirds" (lambda () (panes-choose-layout! 'two-pane)))
(define-command "window-layout-halves" "Two equal panes" (lambda () (panes-choose-layout! 'halves)))
(define-command "window-layout-columns" "Equal columns" (lambda () (panes-choose-layout! 'columns)))
(define-command "window-layout-two-chat" "Two equal panes and a narrow chat" (lambda () (panes-choose-layout! 'two-chat)))
(define-command "window-layout-free" "As many panes as you open" (lambda () (panes-choose-layout! #f)))
;; the strip scroll walks the stack of this pane
(define-command "layout-forward" "Bring the next window of this pane to the front" (lambda () (panes--cycle-pane-window! 1)))
(define-command "layout-backward" "Bring the previous window of this pane to the front" (lambda () (panes--cycle-pane-window! -1)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("window-layout" "window-layout-free" "window-layout-single" "window-layout-two-pane"
    "window-layout-halves" "window-layout-columns" "window-layout-two-chat"
    "layout-forward" "layout-backward"))

(define panes--joined '())

(define (panes--joined! buf id)
  "group-joined-hook: BUF joined group ID. It goes into a window of ID's
   model when the command ends (panes--place-joined!), when its mode is
   set and the command has shown it or not."
  (set! panes--joined (cons (list buf id) panes--joined)))

(define (panes--place-joined!)
  "post-command-hook: a buffer that joined a group and that no window of
   the group's model holds joins the back of its mode's window, else a
   new window behind the last pane (panes--consolidate-homes). A buffer
   panes--group-buffers leaves out stays out. It does not draw."
  (unless (null? panes--joined)
    (let ((joined (reverse panes--joined)))
      (set! panes--joined '())
      (for-each
        (lambda (e)
          (let* ((buf (car e)) (id (cadr e)) (l (panes-layout-of id)))
            (when (and l (buffer-known? buf)
                       (equal? (group-resolve-id (buffer-group buf)) id)
                       (not (string-prefix? " " buf))
                       (fill-candidate? buf)
                       (not (buffer-context-only? buf))
                       (not (member buf (panes-buffers l))))
              (let ((after (panes--consolidate-homes l panes--buffer-mode
                             (list (panes--buffer-mode buf)) (list buf))))
                (if (equal? id (frame-group))
                    (panes-layout-set! after)
                    (panes--layout-store! id (panes-unique-buffers after)))))))
        joined))))

(define (panes-mode--install!)
  "The doors, installed. It draws nothing. The doors:
   The frame primitives the draw uses: select-window! moves the focus,
   and window-set-buffer! and switch-to-buffer-here! show a buffer in a
   window; outside a draw each edits the model first (see the section
   above).
   Hooks: buffer-kill-repair runs panes--kill-repair!,
   buffer-renamed-hook runs panes--rename!, and group-joined-hook with
   post-command-hook give a buffer that joins a group a window
   (panes--place-joined!). No window hook writes the model."
  (advice-add! 'select-window! 'around 'panes
    (lambda (next win &rest more)
      (when (panes--door?) (panes--focus-follows! win))
      (apply next (cons win more))))
  (advice-add! 'window-set-buffer! 'around 'panes
    (lambda (next win buf &rest more)
      (when (panes--door?) (panes--show-follows! win buf))
      (apply next (cons win (cons buf more)))))
  (advice-add! 'switch-to-buffer-here! 'around 'panes
    (lambda (next buf &rest more)
      (when (panes--door?) (panes--show-follows! (active-window) buf))
      (apply next (cons buf more))))
  (add-hook! 'group-joined-hook 'panes--joined!)
  (add-hook! 'post-command-hook 'panes--place-joined!)
  (add-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (add-hook! 'buffer-renamed-hook 'panes--rename!)
  ;; an install over an older one drops the hooks that read the frame back
  (remove-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (remove-hook! 'window-state-change-hook 'panes--note-focus!))

(define (panes--current-pane l)
  "The pane of the selected window, an empty pane's blank window
   included; #f when the selection is in neither."
  (let ((k (panes-key-of-handle l (active-window))))
    (or (and k (panes-pane-of l k)) (panes--empty-pane-of (active-window)))))

(define (panes-add-empty-pane l pid)
  "An empty pane right of PID's column (the end when #f): (LAYOUT ID).
   The capacity grows to hold it."
  (let* ((col (and pid (find (lambda (c) (member pid (map (lambda (p) (plist-get p 'id)) c))) (panes-columns l))))
         (i (and col (panes--index-of (plist-get (car (reverse col)) 'id) (panes-pane-ids l))))
         (added (panes-add-pane l (if i (+ i 1) (panes-pane-count l))))
         (l (car added)))
    (list (if (> (panes-column-count l) (panes-capacity l)) (panes-set-capacity l (panes-column-count l)) l)
          (cadr added))))

(define (panes--move-current-pane! step)
  "s-S-<left> and s-S-<right>: the column of the selected window moves
   one column, STEP -1 left and 1 right, every pane and window in it
   going along. #t when it moved; at the edge, a message and #f."
  (let* ((l (panes--ensure-layout!))
         (pid (panes--current-pane l))
         (moved (and pid (panes-move-column l pid step))))
    (if (and moved (not (equal? moved l)))
        (begin (panes-apply! moved) #t)
        (begin (message "No pane that way") #f))))

(define (panes--shift-window! dir)
  "S-<left> and S-<right>: the focused window moves to the front of the
   neighbouring pane, DIR -1 left and 1 right, and that pane takes the
   focus. At the edge it takes a new pane while there is room. A pane
   it leaves empty stays, and shows the empty pane. #t when it moved;
   else a message and #f."
  (let* ((l (panes--ensure-layout!))
         (key (panes-key-of-handle l (active-window)))
         (from (and key (panes-pane-of l key)))
         (ids (panes-pane-ids l))
         (i (and from (+ dir (panes--index-of from ids))))
         (to (cond ((not i) #f)
                   ((and (>= i 0) (< i (length ids))) (list l (list-ref ids i)))
                   ((panes-under-capacity? l) (panes-add-pane l (if (< i 0) 0 (length ids))))
                   (else #f))))
    (if (not to)
        (begin (message "No pane that way") #f)
        (let ((moved (panes-set-focus (panes-move-window (car to) key (cadr to)) (cadr to))))
          (panes-apply! moved)
          #t))))

;;; --- motion between panes ------------------------------------------------------
;;; The panes are one row: left and previous are the pane before, right and
;;; next the pane after, and nothing is above or below. Each motion changes
;;; the model and the draw shows it.

(define (panes--pane-toward l dir)
  "The pane DIR of the focused one, or #f at the edge. Left and right
   step to the next column, to the pane level with this one or its
   last; up and down step in the column; previous and next step in
   pane order."
  (let* ((pid (panes--current-pane l))
         (ids (panes-pane-ids l))
         (cols (map (lambda (c) (map (lambda (p) (plist-get p 'id)) c)) (panes-columns l)))
         (ci (and pid (panes--index-of #t (map (lambda (c) (and (member pid c) #t)) cols))))
         (ri (and ci (panes--index-of pid (list-ref cols ci))))
         (at (lambda (lst j) (and j (>= j 0) (< j (length lst)) (list-ref lst j)))))
    (and pid
         (cond ((member dir '(previous next))
                (at ids (+ (panes--index-of pid ids) (if (equal? dir 'next) 1 -1))))
               ((member dir '(left right))
                (let ((c (at cols (+ ci (if (equal? dir 'right) 1 -1)))))
                  (and c (list-ref c (min ri (- (length c) 1))))))
               ((member dir '(up down))
                (at (list-ref cols ci) (+ ri (if (equal? dir 'down) 1 -1))))
               (else #f)))))

(define (focus-move! dir)
  "The focus goes to the pane DIR; at the edge a message."
  (let* ((l (panes--ensure-layout!)) (to (panes--pane-toward l dir)))
    (if to
        (begin (panes-apply! (panes-set-focus l to)) (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

(define (focus-move-safe! dir) (focus-move! dir))

(define (window-swap! dir)
  "This window and the front window of the pane DIR trade places, each
   with its stack; the focus goes along. #t when they moved."
  (let* ((l (panes--ensure-layout!))
         (to (panes--pane-toward l dir))
         (a (panes-key-of-handle l (active-window)))
         (ks (if to (panes-pane-keys l to) '())))
    (if (and a (pair? ks))
        (begin (panes-apply! (panes-focus-window (panes-swap-windows l a (car ks)) a)) #t)
        (begin (message (string-append "No window " (symbol->string dir))) #f))))

(define (buffer-move! dir)
  "This buffer goes to the front window of the pane DIR, which takes the
   focus; in an empty pane it gets a window of its own."
  (let* ((l (panes--ensure-layout!))
         (buf (window-buffer (active-window)))
         (to (panes--pane-toward l dir))
         (ks (if to (panes-pane-keys l to) '())))
    (cond ((not (and buf (panes-find l buf))) (message "Cannot move this buffer"))
          ((pair? ks) (panes-apply! (panes-focus-window (panes-move-buffer l buf (car ks)) (car ks))))
          (to (let ((made (panes-add-window (panes-drop-buffer l buf) to buf (panes--buffer-mode buf))))
                (panes-apply! (panes-focus-window (car made) (cadr made)))))
          (else (message "No neighboring pane")))))

(define (window-eat! &optional dir)
  "The pane DIR (right, else left) goes, and its windows wait behind this
   pane's, so no buffer closes."
  (let* ((l (panes--ensure-layout!))
         (me (panes--current-pane l))
         (nb (if dir (panes--pane-toward l dir) (or (panes--pane-toward l 'right) (panes--pane-toward l 'left)))))
    (if (not (and me nb))
        (message "No neighboring pane")
        (panes-apply!
          (panes-set-focus
            (panes-remove-pane
              (fold (lambda (l k) (panes-move-window l k me (length (panes-pane-keys l me))))
                    l (panes-pane-keys l nb))
              nb)
            me)))))

(define-command "pane-move-left" "Move this pane left, with all its windows"
  (lambda () (panes--move-current-pane! -1)))

(define-command "pane-move-right" "Move this pane right, with all its windows"
  (lambda () (panes--move-current-pane! 1)))

(define (panes--cycle-pane-window! step)
  "The next window of the focused pane comes to its front; the one that
   was there goes to the back, so stepping on walks the whole pane.
   STEP 1 is forward, -1 is back. The pane keeps the focus. A message
   and #f when the pane has fewer than two windows."
  (let* ((l (panes--ensure-layout!))
         (k (panes-key-of-handle l (active-window)))
         (pid (and k (panes-pane-of l k)))
         (ks (if pid (panes-pane-keys l pid) '())))
    (if (< (length ks) 2)
        (begin (message "No other window in this pane") #f)
        (begin
          (panes-apply!
            (if (> step 0)
                (panes-set-focus (panes-move-window l (car ks) pid (- (length ks) 1)) pid)
                (panes-focus-window l (car (reverse ks)))))
          #t))))

(define-command "pane-next-window" "Bring the next window of this pane to the front"
  (lambda () (panes--cycle-pane-window! 1)))

(define-command "pane-previous-window" "Bring the previous window of this pane to the front"
  (lambda () (panes--cycle-pane-window! -1)))

(define-command "pane-add" "Add an empty pane to the right of this one; you stay where you are"
  (lambda ()
    (let* ((l (panes--ensure-layout!))
           (me (active-window)))
      ;; the focus stays on this pane: the draw keeps you here
      (panes-apply! (car (panes-add-empty-pane l (panes--current-pane l)))))))

(define (panes-split-off! bufs &optional from)
  "BUFS go to a second window of their mode, beside FROM; the new
   window is selected. Without FROM: the window of the first of BUFS
   that a window holds, else the window of the mode of the first.
   Answers the new handle; a message and #f when there is no window to
   split, or FROM would be left empty."
  (let* ((l (panes--ensure-layout!))
         (from (or from
                   (find (lambda (k) k) (map (lambda (b) (panes-find l b)) bufs))
                   (panes-mode-window l (panes--buffer-mode (car bufs)))))
         (split (and from (panes-split-off l bufs from))))
    (cond ((not from) (message "No window of this mode to split") #f)
          ((not split) (message "The window would be left empty") #f)
          (else
            (panes-handle (panes-apply! (panes-focus-window (car split) (cadr split))) (cadr split))))))

(define-command "buffer-pop"
  "Move this buffer to a second window of its mode, beside this one; ibuffer's split action moves the marked buffers"
  (lambda ()
    (let ((buf (window-buffer (active-window))))
      (cond ((not buf) #f)
            (else (panes-split-off! (list buf)
                                    (panes-key-of-handle (panes--ensure-layout!) (active-window))))))))

(define-command "panes-adopt"
  "Read this frame as it stands into the window model, and lay it out from the model"
  (lambda () (panes-apply! (panes-fit-capacity (panes-adopt)))))

(public! 'panes-layout "(panes-layout) -> the window model of this frame's group, or #f")
(catalog-meta! 'function "panes-layout" 'effects '(read))
(public! 'panes-apply! "(panes-apply! LAYOUT) -> lay the frame out as LAYOUT and keep it as this group's model")
(public! 'panes-waiting-windows "(panes-waiting-windows) -> (KEY BUFFER) for each window of this frame's layout that waits off the screen")
(catalog-meta! 'function "panes-waiting-windows" 'effects '(read))
(public! 'panes-adopt "(panes-adopt) -> this frame as a layout: one pane per window on screen")
(catalog-meta! 'function "panes-adopt" 'effects '(read))

;; --- the default -------------------------------------------------------------
;; A group record from before the model holds a window tree, per frame:
;; (per-frame (FRAME TREE TARGET) ...). It becomes a model once: one pane
;; per buffer the tree showed, in the layout the record named.
(define (panes--migrate-group-trees!)
  (for-each
    (lambda (r)
      (let* ((id (group-record-id r))
             (saved (group-record-layout r))
             (entry (and (pair? saved) (equal? (car saved) 'per-frame) (pair? (cdr saved)) (cadr saved)))
             (tree (if entry (cadr entry) saved))
             (target (and entry (> (length entry) 2) (caddr entry))))
        (when (and (pair? saved) (not (group-layout id)))
          (let ((bufs (filter buffer-known? (or (ignore-errors (lambda () (window-tree-buffers tree))) '()))))
            (group-record-update! id 'layout
              (if (pair? bufs)
                  (let ((l (panes--default-layout (panes--uniq bufs))))
                    (if (and (symbol? target) (panes-layout-spec target)) (panes-set-layout l target) l))
                  #f))))))
    *group-records*))

(panes--migrate-group-trees!)

;; the model is the editor's window management; a reload installs the
;; doors again, so a changed door reaches it
(panes-mode--install!)
