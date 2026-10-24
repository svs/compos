;;; panes-mode.scm --- the window model (panes.scm) on the frame.
;;;
;;; One layout per (frame, group). The applier lays the frame out as the
;;; model says: one window on screen per pane, in a row, with the pane's
;;; share of the width; every other window waits behind its pane with its
;;; stack, its point and its history. Every door asks the one policy:
;;; a visit, a display, a quit, a kill, a rename, a group switch.
;;;
;;;   M-x panes-mode     turn the model on for every frame; again turns it off
;;;   M-x panes-adopt    read the frame as it stands into the model
;;;
;;; Off, nothing here touches a window: window.scm and groups.scm place as
;;; they did.

(require 'panes)
(require 'groups)
(require 'window-log)

(domain! 'windows)
(effects! '(write display))

(define panes-mode #f)
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
  "The layout of group G on this frame, or #f. A #f G is the key none."
  (let ((e (assoc (or g 'none) (panes--store))))
    (and e (cadr e))))

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
   frame, and, when G is a group id, the newest layout of G in
   panes--latest, without handles. A change records in the layout
   history only through panes-layout-set!. Every stack entry is stored
   as a buffer id. It draws nothing. Answers the sealed layout."
  (let ((layout (panes--with-ids (panes--sealed layout g))))
    (set-frame-local! 'panes-layouts (alist-put (panes--store) (or g 'none) layout))
    (when (string? g) (set! panes--latest (alist-put panes--latest g (panes-strip-handles layout))))
    layout))

;; the newest layout of every group, whichever frame made it: a frame that
;; enters a group it has never shown takes this, not whatever the screen holds
(define panes--latest (if (boundp 'panes--latest) panes--latest '()))

(define (panes--seed g)
  "The layout group G takes on a frame that has none: the newest one of
   G in panes--latest, else the one of G on the first frame that has
   one, without handles; #f when there is none."
  (let ((e (and g (assoc g panes--latest))))
    (if e
        (cadr e)
        (let loop ((fs (frame-list)))
          (if (null? fs)
              #f
              (let ((e (and g (assoc g (or (frame-local-in (car fs) 'panes-layouts) '())))))
                (if e (panes-strip-handles (cadr e)) (loop (cdr fs)))))))))

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
   Pure. The rules: one frame window to one model window, and one model
   window to each key."
  (let* ((handles (filter (lambda (h) h) (map (lambda (w) (plist-get w 'win)) (panes-windows model))))
         (keys (panes-window-keys model))
         (count (lambda (x xs) (length (filter (lambda (y) (equal? x y)) xs)))))
    (append
      (map (lambda (h) (format "window ~a is held by ~a model windows" h (count h handles)))
           (panes--uniq (filter (lambda (h) (> (count h handles) 1)) handles)))
      (map (lambda (k) (format "model window ~a is in ~a places" k (count k keys)))
           (panes--uniq (filter (lambda (k) (> (count k keys) 1)) keys))))))

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
   panes--latest keep theirs."
  (set-frame-local! 'panes-layouts (alist-delete (panes--store) (panes--group-key))))

;; --- across restarts -------------------------------------------------------
(define (panes-layouts-state)
  "Every frame's layouts as the desktop saves them: ((FRAME STORE) ...).
   A window id survives a restart (the desktop names it), and a handle
   that did not come back is taken again by buffer when the frame next
   draws the layout."
  (map (lambda (frame) (list frame (or (frame-local-in frame 'panes-layouts) '())))
       (frame-list)))

(define (panes-layouts-restore! saved)
  "SAVED comes back: each frame that still exists takes its store. An
   entry of another frame, or a malformed one, is ignored."
  (for-each (lambda (entry)
              (when (and (pair? entry) (pair? (cdr entry)) (member (car entry) (frame-list)))
                (set-frame-local-in! (car entry) 'panes-layouts (cadr entry))))
            (or saved '())))

(persist-global! 'panes-layouts panes-layouts-state panes-layouts-restore!)
;; a restart brings new frame ids, so the per-group layouts carry across apart
(persist-global! 'panes-latest (lambda () panes--latest) (lambda (saved) (set! panes--latest (or saved '()))))

;;; --- the frame as a layout ---------------------------------------------------------

(define (panes--buffer-mode b)
  "The mode of buffer B, fundamental-mode when it names none; #f when B
   is not the name of a known buffer."
  (and (string? b) (buffer-known? b) (or (buffer-local b 'mode-name) "fundamental-mode")))

(define (panes--live-handle? h)
  "#t when H is a frame window that still exists, on screen or hidden,
   else #f."
  (and h (or (window-exists? h) (assoc h (window-hidden-list))) #t))

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

(define (panes-adopt)
  "The frame as it stands: one pane per window on screen, left to right,
   each holding that window, with the window's width as its share. The
   hidden windows wait behind the last pane. A hidden window whose
   buffer fill-candidate? rejects stays out, and with no window on
   screen there is no pane, so no hidden window comes in. It reads the
   frame and stores nothing: panes-adopt! stores."
  (let loop ((rows (panes--frame-row)) (layout (panes-empty)))
    (if (null? rows)
        ;; the windows behind the panes keep their place in the model
        (let hidden ((hs (window-hidden-list)) (layout layout))
          (cond ((null? hs) layout)
                ((not (fill-candidate? (cadr (car hs)))) (hidden (cdr hs) layout))
                ((null? (panes-panes layout)) (hidden (cdr hs) layout))
                (else
                  (let* ((win (car (car hs))) (buf (cadr (car hs)))
                         (last (car (reverse (panes-pane-ids layout))))
                         (made (panes-add-window layout last buf (panes--buffer-mode buf) #t))
                         (l (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))))
                    (hidden (cdr hs) (panes-set-handle l (cadr made) win))))))
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
;; on the blank buffer. That window is kept here, per group and pane, and
;; never in the model: ((GROUP PANE) . WIN) rows
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

(define (panes--empty-rows)
  "The blank windows of this frame: ((GROUP PANE) WIN) rows."
  (or (frame-local 'panes-empty-windows) '()))
(define (panes--empty-key pid)
  "The key of the blank window of pane PID in this frame's group:
   (GROUP PID)."
  (list (panes--group-key) pid))

(define (panes--empty-handle pid)
  "The blank window of pane PID, or #f when it has none or the window
   is gone."
  (let ((row (assoc (panes--empty-key pid) (panes--empty-rows))))
    (and row (panes--live-handle? (cadr row)) (cadr row))))

(define (panes--forget-empty! pid)
  "Pane PID loses the row of its blank window. The window itself stays."
  (set-frame-local! 'panes-empty-windows
    (filter (lambda (r) (not (equal? (car r) (panes--empty-key pid)))) (panes--empty-rows))))

(define (panes--empty-handle! pid)
  "The blank window of pane PID, made when it has none: a hidden window
   on the blank buffer, kept for the pane. #f when no window could be
   made."
  (or (panes--empty-handle pid)
      (begin
        (panes--empty-buffer!)
        (let ((h (window-new-hidden! panes-empty-buffer)))
          (when h
            (panes--forget-empty! pid)
            (set-frame-local! 'panes-empty-windows (cons (list (panes--empty-key pid) h) (panes--empty-rows))))
          h))))

(define (panes--empty-pane-of win)
  "The pane of this group that frame window WIN stands for while the
   pane is empty, or #f."
  (let* ((g (panes--group-key))
         (row (find (lambda (r) (and (equal? (cadr r) win) (equal? (car (car r)) g))) (panes--empty-rows))))
    (and row (cadr (car row)))))

(define (panes--claim-empty-windows layout)
  "A pane that took a window takes its blank one too, so the frame
   window stays: the front window gets the blank window as its handle,
   and the blank row is forgotten. Only when the front window has no
   live handle."
  (fold (lambda (l p)
          (let* ((ks (panes-keys p))
                 (pid (plist-get p 'id))
                 (h (and (pair? ks) (panes--empty-handle pid))))
            (if (and h (not (panes--live-handle? (panes-handle l (car ks)))))
                (begin (panes--forget-empty! pid) (panes-set-handle l (car ks) h))
                l)))
        layout (panes-panes layout)))

(define (panes--drop-stale-empty-windows! layout)
  "The blank windows of panes that hold a window now, or are gone, go:
   their rows are forgotten, and a hidden one is deleted. Only the rows
   of this frame's group."
  (let ((g (panes--group-key)))
    (for-each (lambda (r)
                (let ((p (and (equal? (car (car r)) g) (panes-pane layout (cadr (car r))))))
                  (when (and (equal? (car (car r)) g) (or (not p) (pair? (panes-keys p))))
                    (panes--forget-empty! (cadr (car r)))
                    (when (assoc (cadr r) (window-hidden-list)) (window-hidden-delete! (cadr r))))))
              (panes--empty-rows))))

(define (panes--pane-handles layout)
  "A frame window for every pane, left to right: its front window, else
   its blank one, made when it has none. A front window with no handle
   gives #f."
  (map (lambda (p)
         (let ((ks (panes-keys p)))
           (if (pair? ks) (panes-handle layout (car ks)) (panes--empty-handle! (plist-get p 'id)))))
       (panes-panes layout)))

(define (panes--materialize layout keys)
  "Every window in KEYS that shows a buffer has a live handle: one
   without gets a hidden frame window, with the id its handle names
   when no window holds it. Unlike panes--materialize!,
   it does not set the window history and does not look for shared
   handles."
  (fold (lambda (l k)
          (let ((h (panes-handle l k)) (buf (panes-window-buffer l k)))
            (cond ((panes--live-handle? h) l)
                  ((not (and buf (buffer-known? buf))) l)
                  ;; a window that had an id comes back with it
                  (else (let ((nw (window-new-hidden! buf h)))
                          (if nw (panes-set-handle l k nw) l))))))
        layout keys))

(define (panes--top-shares layout)
  "The shares of the panes, empty ones too, normalized to sum 1. A
   share that is not a positive number counts as 1."
  ;; a pane's share is its own once it was resized; panes that kept the
  ;; default follow the layout target: under two-chat the last pane is the
  ;; chat, at window-layout-chat-ratio, and the rest share what is left
  (let* ((rows (panes-panes layout))
         (raw (map (lambda (p) (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1))) rows))
         (n (length raw))
         (plain (and (> n 1) (null? (filter (lambda (s) (not (= s 1))) raw))))
         (raw (if (and plain (equal? (layout-target) 'two-chat) (number? window-layout-chat-ratio))
                  (let ((r window-layout-chat-ratio))
                    (append (map (lambda (_) (/ (- 1 r) (- n 1))) (cdr raw)) (list r)))
                  raw))
         (total (apply + raw)))
    (map (lambda (s) (/ s total)) raw)))

(define (panes--attach-handles layout)
  "A window id is a stable reference: a window whose handle is gone
   keeps it, and panes--materialize gives it back the same id. Only a
   window with no handle takes the frame window that shows its buffer,
   on screen or hidden, each frame window once; one that finds none
   stays without."
  (let ((rows (append (window-list) (window-hidden-list))))
    (let loop ((keys (panes-window-keys layout)) (layout layout) (taken '()))
      (if (null? keys)
          layout
          (let* ((k (car keys)) (h (panes-handle layout k)))
            (cond
              ((panes--live-handle? h) (loop (cdr keys) layout (cons h taken)))
              (h (loop (cdr keys) layout taken))
              (else
                (let* ((buf (panes-window-buffer layout k))
                       (row (find (lambda (r) (and (equal? (cadr r) buf) (not (member (car r) taken)))) rows)))
                  (if row
                      (loop (cdr keys) (panes-set-handle layout k (car row)) (cons (car row) taken))
                      (loop (cdr keys) (panes-set-handle layout k #f) taken))))))))))

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
         (h (and p (if (pair? ks) (panes-handle layout (car ks)) (panes--empty-handle p)))))
    (if (and h (member h handles)) h (car handles))))

(define (panes--draw! layout)
  "The frame drawn as LAYOUT: every top window on screen with its
   pane's share, showing the front of its stack, the rest waiting
   behind; an empty pane shows its blank window. First the windows take
   their handles back (panes--attach-handles), the panes take their
   blank windows, and every top window and every pane gets a frame
   window. It arranges the frame only when every pane has a frame
   window; else the screen stays as it was. The focused pane's window
   is selected (panes--focus-handle), whatever was selected before.
   Then the stale blank windows go. Answers the layout with the handles
   the draw took or made. Nothing is recorded: panes-apply! stores the
   model anyway, also when the draw did not arrange."
  (let* ((layout (panes--claim-empty-windows (panes--attach-handles layout)))
         (tops (panes-top-windows layout))
         (layout (panes--materialize layout tops))
         (handles (panes--pane-handles layout)))
    (set! panes--applying #t)
    (unwind-protect
      (lambda ()
        (with-layout-suppressed
          (lambda ()
            (when (and (pair? handles) (null? (filter (lambda (h) (not h)) handles)))
              (begin
                (window-arrange-line! 'h (panes--top-shares layout) handles)
                (for-each
                  (lambda (k)
                    (let ((h (panes-handle layout k)) (bufs (panes-window-buffers layout k)))
                      ;; an id no buffer has is no name: showing it would make a buffer of it
                      (when (and h (pair? bufs) (window-exists? h) (buffer-known? (car bufs)))
                        (unless (equal? (window-buffer h) (car bufs))
                          (window-set-buffer! h (car bufs)))
                        (set-window-prev-buffers! h (cdr bufs)))))
                  tops)
                ;; the screen is a projection of the model: whatever the arrange
                ;; selected, the draw ends on the focused pane's window
                (let ((target (panes--focus-handle layout handles)))
                  (unless (or (not target) (not (window-exists? target)) (equal? (active-window) target))
                    (select-window! target)))))
            (panes--drop-stale-empty-windows! layout))))
      (lambda () (set! panes--applying #f)))
    layout))

(define (panes--group-buffers &optional held)
  "The open buffers of this frame's group, each to be in a window. The
   read model answers the group's names; only the ones not in HELD are
   checked further: no leading space, fill-candidate?, and not
   context-only."
  (let* ((group (or (frame-group) (and (boundp 'group-cycle-group) (group-cycle-group))))
         (names (if group (map car (cadr (buffer-rows (list 'groups (list group) 'fields '(name))))) '())))
    (filter (lambda (b) (or (and held (member b held))
                            (and (not (string-prefix? " " b))
                                 (fill-candidate? b)
                                 (not (buffer-context-only? b)))))
            names)))

(define (panes-apply! layout)
  "The frame follows LAYOUT and it becomes this group's model. In
   order: each buffer goes to one window, every window of the model
   gets a frame window (panes--materialize!), the frame is drawn
   (panes--draw!), the layout is stored (panes-layout-set!), and
   window-state-changed! runs. It stores the layout also when the draw
   did not arrange the frame. Answers the drawn layout."
  ;; a buffer is in one window, whatever made this layout, and every window of
  ;; the layout is a window of the frame: one the screen does not show waits hidden.
  ;; Only the layout's own windows are drawn: a member of the group with no
  ;; window stays without one until the user opens it
  (let ((layout (panes--draw! (panes--materialize! (panes-unique-buffers layout)))))
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

(define (panes-visit! buf)
  "A visit: BUF shows and its window takes the focus. Answers the
   handle, or #f."
  (panes-place! buf 'visit))

(define (panes-display! buf)
  "A display: BUF shows, the selection stays."
  (panes-place! buf 'display))

(define (panes-consolidate!)
  "Consolidate on the model: every mode one window. The frame-level
   consolidate makes hidden windows the model does not know, and the
   next redraw throws them away. The buffers of the frame's group that
   no window holds join too, except context-only ones. The selected
   window stays selected when it still exists. Answers that window."
  (let* ((me (active-window))
         ;; the group's buffers no window holds any more join behind their mode's window
         (g (frame-group))
         (after (panes-consolidate (panes--ensure-layout!) panes--buffer-mode #f
                                   (filter (lambda (b) (and (equal? (buffer-group b) g) (not (buffer-local b 'context-only)))) (buffer-list)))))
    (window-log-note! "panes consolidate")
    (panes-apply! (let ((k (panes-key-of-handle after me))) (if k (panes-focus-window after k) after)))
    (message (string-append "Consolidated into " (number->string (length (panes-window-keys after))) " windows"))
    me))

(define (panes--materialize! layout)
  "A frame window, hidden, for every window of the model that has none:
   a consolidate makes windows the frame never drew. A handle two keys
   share counts once. The window takes its stack, so it walks as the
   model says. A window that had an id gets it again when no window
   holds it. A window whose buffer is not known stays without one."
  (let loop ((ks (panes-window-keys layout)) (l layout) (used '()))
    (if (null? ks)
        l
        (let* ((k (car ks)) (h (panes-handle l k)) (buf (panes-window-buffer l k)))
          (if (and (panes--live-handle? h) (not (member h used)))
              (loop (cdr ks) l (cons h used))
              (let ((nh (and buf (buffer-known? buf) (window-new-hidden! buf (and (not (member h used)) h)))))
                (if nh
                    (begin
                      (set-window-prev-buffers! nh (cdr (panes-window-buffers l k)))
                      (loop (cdr ks) (panes-set-handle l k nh) (cons nh used)))
                    (loop (cdr ks) l used))))))))

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
   wins, so while the mode is on the group repair stands down. #f when
   the layout does not hold NAME. From the overview an emptied pane
   goes; elsewhere it stays, empty."
  (let ((layout (panes-layout)))
    (and layout (member name (panes-buffers layout))
         (begin
           (window-log-note! "panes kill" name)
           ;; a kill from the overview keeps no count of panes: an emptied pane goes;
           ;; elsewhere it stays, empty
           (panes-apply! (if (and (boundp 'windows-overview-active?) (windows-overview-active?))
                             (plist-put (panes-drop-buffer (plist-put layout 'bare #t) name) 'bare #f)
                             (panes-drop-buffer layout name)))
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
   Then layout-target-refresh! runs."
  (window-log-note! "panes enter group" (or (frame-group) "none"))
  (let ((layout (panes-layout)))
    (if layout
        (panes-apply! (panes-validate layout buffer-known?))
        (or (panes--seed! (frame-group)) (panes-adopt!))))
  (layout-target-refresh!))

;;; --- the mode ---------------------------------------------------------------------------

(define (panes--door?)
  "#t when a door goes through the model: panes-mode is on,
   buffer-context? is #f, no layout arranges, and the model does not
   draw."
  (and panes-mode (not (buffer-context?)) (not (layout-arranging?)) (not panes--applying)))

(define (panes--default-layout bufs)
  "One pane per buffer of BUFS, left to right, equal shares: a group's
   first layout. It does not fold to the capacity."
  (fold (lambda (l b)
          (let* ((added (panes-add-pane l))
                 (made (panes-add-window (car added) (cadr added) b (panes--buffer-mode b))))
            (car made)))
        (panes-empty)
        bufs))

(define (panes--rows)
  "The model as group-panes rows, ((PANE WIN ...) ...), the window on
   screen first: the overview spreads and gathers the frame by these
   rows. A window with no handle is left out; () when the group has no
   layout."
  (let ((l (panes-layout)))
    (if (not l)
        '()
        (map (lambda (p)
               (cons (plist-get p 'id)
                     (filter (lambda (h) h)
                             (map (lambda (k) (panes-handle l k)) (panes-keys p)))))
             (panes-panes l)))))

(define (panes--tree-matches? tree layout)
  "A saved frame TREE still fits the model when it shows the model's
   front buffers, in order, and every one of them is known. A model
   with nothing on screen never fits."
  (let ((shown (window-tree-buffers tree))
        (fronts (map (lambda (k) (panes-window-buffer layout k)) (panes-top-windows layout))))
    (and (pair? fronts) (equal? shown fronts) (null? (filter (lambda (b) (not (buffer-known? b))) shown)))))



;;; --- the frame primitives are doors ----------------------------------------------
;;; While panes-mode is on, a primitive that changes the frame changes the
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
           (let ((made (panes-add-window l pid buf (panes--buffer-mode buf))))
             (panes--forget-empty! pid)
             (panes-layout-set! (panes-set-handle (car made) (cadr made) win)))))))

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
    (and (not (equal? after l))
         (let ((gone-handles (filter (lambda (h) (and h (not (member h (map (lambda (k) (panes-handle after k)) (panes-window-keys after))))))
                                     (map (lambda (k) (panes-handle l k)) (panes-window-keys l)))))
           (when (and pid (not k)) (panes--forget-empty! pid))
           (panes-apply! after)
           ;; Emacs deletes the window: its frame window goes, its buffers stay open
           (for-each (lambda (h) (when (assoc h (window-hidden-list)) (window-hidden-delete! h))) gone-handles)
           #t))))

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

(define (panes--split-window!)
  "C-x 3 and C-x 2: an empty pane opens right of the focused pane, and
   the next fill buffer shows in it when the fill rule names one. The
   selection stays. Answers the new pane's frame window, or #f."
  (let* ((l (panes--ensure-layout!))
         (me (active-window))
         (k (panes-key-of-handle l me))
         (pid (or (and k (panes-pane-of l k)) (panes--empty-pane-of me) (panes-focus l)))
         (added (panes-add-empty-pane l pid))
         (action (window-fill-decide (list 'shown (panes-buffers l)) (window-fill-buffers)))
         (buf (and (equal? (car action) 'show) (cadr action)))
         (after (if buf
                    (car (panes-add-window (car added) (cadr added) buf (panes--buffer-mode buf)))
                    (car added)))
         (drawn (panes-apply! (panes-set-focus after pid)))
         (ks (panes-pane-keys drawn (cadr added))))
    (if (pair? ks) (panes-handle drawn (car ks)) (panes--empty-handle (cadr added)))))

(define (panes--tile-windows! algorithm buffers)
  "C-x l and every caller of tile-windows!: a layout is a capacity and
   an order. The capacity becomes that of ALGORITHM, and BUFFERS, up to
   it, front the panes from the left: a buffer of a window already used
   leaves it for a new window. Panes past the buffers fold into the
   last one, and the first pane takes the focus. Answers the front
   buffers, or #f for an unknown layout or no buffer."
  (let* ((cap (layout-capacity algorithm))
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
               (l (panes-set-capacity (panes-fit-capacity (panes-set-capacity l (length bufs))) cap))
               (drawn (panes-apply! (panes-set-focus (panes-equalize l) (car (panes-pane-ids l))))))
          (map (lambda (k) (panes-window-buffer drawn k)) (panes-top-windows drawn)))))))

(define (panes-mode--install!)
  "The doors, installed: panes-mode becomes #t, and every door yields to
   the old path while panes-mode is #f. It draws nothing. The doors:
   switch-to-buffer--show!: a visit, after buffer-join-here!.
   display-buffer: a display, unless display-buffer-agent-refuses?.
   window-swap!: a swap that moved the window swaps it in the model.
   window-unwind-or-close!: panes-quit!, else the old path.
   group-frame-leave!: the group's frame is saved as it is left.
   group-layout-enter!: the layout, else a seed, else a default layout
   from the saved buffers or the group's default panes. It hides the
   windows of the group it leaves and destroys none.
   group-preview-draw!: the switcher's look draws the group's model.
   winner-previous! and winner-next!: layout-undo and layout-redo.
   windows-overview-enter! and windows-overview-exit!: the overview
   spreads the model's windows, and the chosen one comes to the front
   of its pane.
   The frame primitives: select-window! moves the focus,
   window-set-buffer! shows a buffer in its window, delete-window!,
   delete-other-windows!, split-window! and tile-windows! change the
   panes. Each edits the model first (see the section above).
   Hooks: buffer-kill-repair runs panes--kill-repair!, and
   buffer-renamed-hook runs panes--rename!. No window hook writes the
   model."
  (set! panes-mode #t)
  (advice-add! 'switch-to-buffer--show! 'around 'panes
    (lambda (next buf)
      (if (panes--door?)
          (begin
            ;; a buffer opens in the group it was launched from (groups.scm)
            (when (boundp 'buffer-join-here!) (buffer-join-here! buf))
            (panes-visit! buf)
            buf)
          (next buf))))
  (advice-add! 'display-buffer 'around 'panes
    (lambda (next name &optional alist)
      (if (and (panes--door?) (not (display-buffer-agent-refuses? name (or alist '()))))
          (panes-display! name)
          (next name alist))))
  ;; a window moved to the neighbouring pane trades places with that pane's
  ;; window: the model swaps them, and the draw moves them
  (advice-add! 'window-swap! 'around 'panes
    (lambda (next dir)
      (let* ((l (and (panes--door?) (panes-layout)))
             (nb (and l (window-in-direction dir)))
             (a (and nb (panes-key-of-handle l (active-window))))
             (b (and a (panes-key-of-handle l (car nb)))))
        (if (and a b)
            (begin
              (window-log-note! "panes swap" a b)
              (panes-apply! (panes-focus-window (panes-swap-windows l a b) a))
              #t)
            (next dir)))))
  (advice-add! 'select-window! 'around 'panes
    (lambda (next win &rest more)
      (when (panes--door?) (panes--focus-follows! win))
      (apply next (cons win more))))
  (advice-add! 'window-set-buffer! 'around 'panes
    (lambda (next win buf &rest more)
      (when (panes--door?) (panes--show-follows! win buf))
      (apply next (cons win (cons buf more)))))
  (advice-add! 'delete-window! 'around 'panes
    (lambda (next &rest args) (if (panes--door?) (panes--delete-window!) (apply next args))))
  (advice-add! 'delete-other-windows! 'around 'panes
    (lambda (next &rest args) (if (panes--door?) (panes--delete-other-windows!) (apply next args))))
  (advice-add! 'split-window-with-other-buffer! 'around 'panes
    (lambda (next direction) (if (panes--door?) (panes--split-window!) (next direction))))
  ;; the overview lays its tiles with splits: they are not panes
  (advice-add! 'split-window! 'around 'panes
    (lambda (next dir &rest ratio)
      (if (and (panes--door?) (not (frame-local 'windows-overview-rows)))
          (panes--split-window!)
          (apply next (cons dir ratio)))))
  (advice-add! 'tile-windows! 'around 'panes
    (lambda (next algorithm buffers)
      (if (panes--door?) (panes--tile-windows! algorithm buffers) (next algorithm buffers))))
  (advice-add! 'window-unwind-or-close! 'around 'panes
    (lambda (next win) (if (and panes-mode (panes-quit! win)) #t (next win))))
  ;; a group switch arranges the group's windows; it rebuilds nothing. A
  ;; group with no model yet takes the old path once and is read from the frame
  ;; the frame as the group is left, sizes and selected window with it, is
  ;; the one record a return puts back
  (advice-add! 'group-frame-leave! 'before 'panes
    (lambda (from) (when (and panes-mode from (group-resolve-id from)) (group-layout-save! from))))
  (advice-add! 'group-layout-enter! 'around 'panes
    (lambda (next id saved)
      (if (not panes-mode)
          (next id saved)
          (begin
            ;; the group's layout stays the target; panes--draw! holds the
            ;; reflow back while it draws
            (window-log-note! "panes enter group" id)
            ;; the model draws the group: its windows come to the front and the
            ;; other groups' windows wait hidden. window-tree-set! of the saved
            ;; frame replaced every hidden window, so it destroyed the windows
            ;; of the groups not on screen
            (cond
              ((panes-layout)
               (panes-apply! (panes-validate (panes-layout) buffer-known?)))
              ;; another frame laid this group out: its arrangement comes along
              ((panes--seed! id))
              (else
                ;; no model yet: the group's saved arrangement names the
                ;; buffers, else the group's default does; the model is built
                ;; from them and the frame's other windows only step aside
                (let* ((kept (if saved
                                 (begin (group-revive-layout-files! saved)
                                        (filter (lambda (b) (and (buffer-known? b) (fill-candidate? b) (buffer-in-group? b id)))
                                                (window-tree-buffers saved)))
                                 '()))
                       (bufs (if (pair? kept) kept (group-default-panes id))))
                  (panes-apply! (panes--default-layout bufs)))))
            (layout-target-refresh!)))))
  ;; the switcher's look at a group draws that group's model, and wakes what
  ;; it shows the way the old look did; the switcher sleeps them again
  (advice-add! 'group-preview-draw! 'around 'panes
    (lambda (next index g)
      (let ((layout (and panes-mode (panes-layout-of g))))
        (cond ((not layout) (next index g))
              ((group-preview-shown? g) '())
              (else
                (let ((standing *group-current-inhibit*)
                      (asleep (filter (lambda (b) (and (buffer-known? b) (not (buffer-exists? b))))
                                      (map caddr (panes-visible layout)))))
                  (set! *group-current-inhibit* #t)
                  (set! *group-look-active* #t)
                  (panes-look! layout g)
                  (set! *group-current-inhibit* standing)
                  (set! *group-preview-last* (list g (map cadr (window-list))))
                  (let ((woken (filter buffer-exists? asleep)))
                    (for-each restore-buffer-runtime! woken)
                    woken)))))))
  ;; winner walks the layout history
  (advice-add! 'winner-previous! 'around 'panes
    (lambda (next) (if panes-mode (run-command "layout-undo") (next))))
  (advice-add! 'winner-next! 'around 'panes
    (lambda (next) (if panes-mode (run-command "layout-redo") (next))))
  ;; the overview spreads the model's windows, and the window chosen comes
  ;; to the front of the pane the user came from
  (advice-add! 'windows-overview-enter! 'around 'panes
    (lambda (next)
      ;; the frame as it was, to put back when the view closes on it
      (set-frame-local! 'panes-overview-tree (and panes-mode (window-tree)))
      (when panes-mode
        (panes--ensure-layout!)
        ;; every window of the model gets a tile, so each wants a frame window
        (panes-layout-set! (panes--materialize! (panes-layout)))
        (group-panes-set-rows! (panes--rows)))
      (next)))
  (advice-add! 'windows-overview-exit! 'around 'panes
    (lambda (next &rest args)
      (if (not panes-mode)
          (apply next args)
          (let* ((me (active-window))
                 (home (frame-local 'windows-overview-home))
                 ;; back on the window it opened from, the view gives the frame back as it was
                 (stay (and (frame-local 'windows-overview-arrangement) (frame-local 'windows-overview-from)))
                 (r (apply next args))
                 (l (panes-layout))
                 (k (and l (panes-key-of-handle l me))))
            (let ((tree (frame-local 'panes-overview-tree)))
              (set-frame-local! 'panes-overview-tree #f)
              (cond ((and k (not stay) tree (panes--tree-matches? tree l))
                     ;; the frame as it was, then the one change the choice asks for
                     (with-layout-held (lambda () (window-tree-set! tree)))
                     (unless (assoc me (window-list))
                       (let* ((pid (or (and home (panes-pane l home) home) (panes-pane-of l k)))
                              (front (panes-handle l (car (let ((ks (panes-pane-keys l pid))) (if (pair? ks) ks (list k)))))))
                         (when (and front (assoc front (window-list)) (assoc me (window-hidden-list)))
                           (window-swap-hidden! front me)
                           (panes-layout-set! (panes-move-window l k pid 0))
                           (window-state-changed!))))
                     (when (window-exists? me) (select-window! me)))
                    ((and k (not stay))
                     (panes-apply! (if (and home (panes-pane l home)) (panes-move-window l k home 0) (panes-raise l k)))
                     (when (window-exists? me) (select-window! me)))
                    ;; back where it opened: the frame as it was, nothing recalculated
                    ((and tree l (panes--tree-matches? tree l))
                     (with-layout-held (lambda () (window-tree-set! tree)))
                     (when (window-exists? me) (select-window! me)))))
            r))))
  (add-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (add-hook! 'buffer-renamed-hook 'panes--rename!)
  ;; an install over an older one drops the hooks that read the frame back
  (remove-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (remove-hook! 'window-state-change-hook 'panes--note-focus!))

(define (panes-mode-enable!)
  "Turns panes-mode on: the doors are installed, then the frame enters
   its group (panes--enter-group!), so the model lays the frame out now.
   The echo area says so."
  (panes-mode--install!)
  (panes--enter-group!)
  (message "panes-mode on: one window per mode, in a row of panes"))

(define (panes-mode-disable!)
  "Turns panes-mode off: panes-mode becomes #f and the advice and the
   hooks go. The advice on window-swap! and group-frame-leave! stays,
   but it does nothing while panes-mode is #f. The frame and the stored
   layouts stay as they are."
  (set! panes-mode #f)
  (for-each (lambda (t) (advice-remove! t 'panes))
            '(switch-to-buffer--show! display-buffer window-unwind-or-close! group-layout-enter!
              group-preview-draw! winner-previous! winner-next! windows-overview-enter! windows-overview-exit!
              select-window! window-set-buffer! delete-window! delete-other-windows!
              split-window-with-other-buffer! split-window! tile-windows!))
  (remove-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (remove-hook! 'buffer-renamed-hook 'panes--rename!)
  (message "panes-mode off"))

(define (panes--current-pane l)
  "The pane of the selected window, an empty pane's blank window
   included; #f when the selection is in neither."
  (let ((k (panes-key-of-handle l (active-window))))
    (or (and k (panes-pane-of l k)) (panes--empty-pane-of (active-window)))))

(define (panes-add-empty-pane l pid)
  "An empty pane right after PID (the end when #f): (LAYOUT ID). The
   capacity grows to hold it."
  (let* ((i (and pid (panes--index-of pid (panes-pane-ids l))))
         (added (panes-add-pane l (if i (+ i 1) (panes-pane-count l))))
         (l (car added)))
    (list (if (> (panes-pane-count l) (panes-capacity l)) (panes-set-capacity l (panes-pane-count l)) l)
          (cadr added))))

(define (panes--move-current-pane! step)
  "s-S-<left> and s-S-<right>: the pane of the selected window moves one
   place, STEP -1 left and 1 right, every window in it going along. #t
   when it moved; at the edge, a message and #f."
  (let* ((l (panes--ensure-layout!))
         (pid (panes--current-pane l))
         (i (and pid (panes--index-of pid (panes-pane-ids l))))
         (to (and i (+ i step))))
    (if (and to (>= to 0) (< to (panes-pane-count l)))
        (begin (panes-apply! (panes-move-pane l pid to)) #t)
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
      (cond ((not panes-mode) (message "buffer-pop needs panes-mode") #f)
            ((not buf) #f)
            (else (panes-split-off! (list buf)
                                    (panes-key-of-handle (panes--ensure-layout!) (active-window))))))))

(define-command "panes-mode"
  "Toggle the window model: a row of panes, each a stack of windows, each a stack of buffers; a buffer opens where the window policy says"
  (lambda () (if panes-mode (panes-mode-disable!) (panes-mode-enable!))))

(define-command "panes-adopt"
  "Read this frame as it stands into the window model, and lay it out from the model"
  (lambda () (panes-apply! (panes-fit-capacity (panes-adopt)))))

(public! 'panes-layout "(panes-layout) -> the window model of this frame's group, or #f")
(catalog-meta! 'function "panes-layout" 'effects '(read))
(public! 'panes-apply! "(panes-apply! LAYOUT) -> lay the frame out as LAYOUT and keep it as this group's model")
(public! 'panes-adopt "(panes-adopt) -> this frame as a layout: one pane per window on screen, the hidden windows behind the last")
(catalog-meta! 'function "panes-adopt" 'effects '(read))

;; --- the default -------------------------------------------------------------
;; the model is the editor's window management. Off puts the old doors
;; back: the layout target, the window ring, the saved window trees.
(defcustom 'panes-mode-default #t
  "Start the window model with the editor: one window per mode, in a row of panes"
  'group 'windows 'type 'boolean)

;; on already, a reload installs the doors again, so a changed door reaches it
(when (or panes-mode panes-mode-default) (panes-mode--install!))
