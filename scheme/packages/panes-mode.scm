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
   history only through panes-layout-set!. It draws nothing. Answers
   the sealed layout."
  (let ((layout (panes--sealed layout g)))
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
   Pure. The rules: one frame window to one model window, each model
   window in one pane, and no pane names a window the model does not
   have."
  ;; pure: what MODEL breaks of its own rules, as text; () is none. One live
  ;; window to one model window, each model window in one pane, and no pane
  ;; naming a window the model does not have
  (let* ((handles (filter (lambda (h) h) (map (lambda (w) (plist-get w 'win)) (panes-windows model))))
         (keys (map (lambda (w) (plist-get w 'key)) (panes-windows model)))
         (placed (apply append (map (lambda (p) (or (plist-get p 'windows) '())) (panes-panes model))))
         (count (lambda (x xs) (length (filter (lambda (y) (equal? x y)) xs)))))
    (append
      (map (lambda (h) (format "window ~a is held by ~a model windows" h (count h handles)))
           (panes--uniq (filter (lambda (h) (> (count h handles) 1)) handles)))
      (map (lambda (k) (format "model window ~a is in ~a panes" k (count k placed)))
           (filter (lambda (k) (not (= (count k placed) 1))) keys))
      (map (lambda (k) (format "a pane names ~a, which the model does not have" k))
           (panes--uniq (filter (lambda (k) (not (member k keys))) placed))))))

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
                         (made (panes-new-window layout last buf (panes--buffer-mode buf) #t))
                         (l (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))))
                    (hidden (cdr hs) (panes-set-handle l (cadr made) win))))))
        (let* ((win (car (car rows))) (buf (cadr (car rows))) (width (caddr (car rows)))
               (added (panes-add-pane layout))
               (l (panes-set-share (car added) (cadr added) width))
               (made (panes-new-window l (cadr added) buf (panes--buffer-mode buf)))
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

(define (panes--empty-render!)
  "Writes the text of the blank buffer: a title, then one line for each
   command of pane-empty-mode, with its keys and its doc. The keys take
   the face pane-empty-key, all the text pane-empty-text."
  (let loop ((rows (panes--empty-keys)) (text "\n   Empty pane\n\n") (spans '()))
    (if (null? rows)
        (begin
          (buffer-set-text! panes-empty-buffer text #t)
          (overlay-set! panes-empty-buffer 'pane-empty
                        (cons (list 0 (string-length text) "pane-empty-text") spans)))
        (let* ((keys (string-join (cadr (car rows)) " "))
               (start (+ (string-length text) 3))
               (doc (or (command-doc (car (car rows))) (car (car rows)))))
          (loop (cdr rows)
                (string-append text "   " (string-pad-right keys (max 8 (+ 2 (string-length keys)))) doc "\n")
                (cons (list start (+ start (string-length keys)) "pane-empty-key") spans))))))

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
                  (let ((moved (panes-apply! (panes-move-window (panes-layout) (cadr row) pid))))
                    (let ((h (and moved (panes-handle moved (cadr row)))))
                      (when (and h (window-exists? h)) (select-window! h)))))))
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
          (let* ((ks (or (plist-get p 'windows) '()))
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
                  (when (and (equal? (car (car r)) g) (or (not p) (pair? (or (plist-get p 'windows) '()))))
                    (panes--forget-empty! (cadr (car r)))
                    (when (assoc (cadr r) (window-hidden-list)) (window-hidden-delete! (cadr r))))))
              (panes--empty-rows))))

(define (panes--pane-handles layout)
  "A frame window for every pane, left to right: its front window, else
   its blank one, made when it has none. A front window with no handle
   gives #f."
  (map (lambda (p)
         (let ((ks (or (plist-get p 'windows) '())))
           (if (pair? ks) (panes-handle layout (car ks)) (panes--empty-handle! (plist-get p 'id)))))
       (panes-panes layout)))

(define (panes--materialize layout keys)
  "Every window in KEYS that shows a buffer has a live handle: one
   without gets a new hidden frame window. Unlike panes--materialize!,
   it does not set the window history and does not look for shared
   handles."
  (fold (lambda (l k)
          (let ((h (panes-handle l k)) (buf (panes-window-buffer l k)))
            (cond ((panes--live-handle? h) l)
                  ((not buf) l)
                  (else (let ((nw (window-new-hidden! buf)))
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
  "A window whose handle is gone takes the frame window that shows its
   buffer, on screen or hidden, each frame window once: a layout read
   back from the desktop, or one whose windows another door rebuilt,
   meets the frame again without a new window being made. A window
   that finds none gets #f."
  (let ((rows (append (window-list) (window-hidden-list))))
    (let loop ((keys (panes-window-keys layout)) (layout layout) (taken '()))
      (if (null? keys)
          layout
          (let* ((k (car keys)) (h (panes-handle layout k)))
            (if (panes--live-handle? h)
                (loop (cdr keys) layout (cons h taken))
                (let* ((buf (panes-window-buffer layout k))
                       (row (find (lambda (r) (and (equal? (cadr r) buf) (not (member (car r) taken)))) rows)))
                  (if row
                      (loop (cdr keys) (panes-set-handle layout k (car row)) (cons (car row) taken))
                      (loop (cdr keys) (panes-set-handle layout k #f) taken)))))))))

(define (panes--note-focus!)
  "Coming back to a group, focus goes where it was when you left: the
   model records it the moment it changes, as the focus of the layout,
   (window KEY) or (pane PID) for a blank window. It runs only on
   window-state-change-hook, and select-window! does not run that hook.
   It does nothing while panes-mode is off, while the model draws, or
   while a layout arranges. It writes with panes--layout-store!, so the
   layout history does not record it."
  (unless (or (not panes-mode) panes--applying (layout-arranging?))
    (let ((l (panes-layout)))
      (when l
        (let* ((w (active-window))
               (k (panes-key-of-handle l w))
               (p (and (not k) (panes--empty-pane-of w)))
               (f (cond (k (list 'window k)) (p (list 'pane p)) (else #f))))
          (when (and f (not (equal? f (plist-get l 'focus))))
            (panes--layout-store! (panes--group-key) (plist-put l 'focus f))))))))

(define (panes--focus-handle layout handles)
  "The frame window that takes the focus after a draw: the one the
   layout's focus names, when it is among HANDLES, else the first of
   HANDLES."
  (let* ((f (plist-get layout 'focus))
         (h (and (pair? f)
                 (if (eq? (car f) 'window) (panes-handle layout (cadr f)) (panes--empty-handle (cadr f))))))
    (if (and h (member h handles)) h (car handles))))

(define (panes--draw! layout)
  "The frame drawn as LAYOUT: every top window on screen with its
   pane's share, showing the front of its stack, the rest waiting
   behind; an empty pane shows its blank window. First the windows take
   their handles back (panes--attach-handles), the panes take their
   blank windows, and every top window and every pane gets a frame
   window. It arranges the frame only when every pane has a frame
   window; else the screen stays as it was. When the selected window is
   not one of the pane windows, the focus goes to panes--focus-handle.
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
              ;; asked before the arrange: the arrange selects a window of its own
              (let ((stays (member (active-window) handles)))
                (window-arrange-line! 'h (panes--top-shares layout) handles)
                (for-each
                  (lambda (k)
                    (let ((h (panes-handle layout k)) (bufs (panes-window-buffers layout k)))
                      (when (and h (pair? bufs) (window-exists? h))
                        (unless (equal? (window-buffer h) (car bufs))
                          (window-set-buffer! h (car bufs)))
                        (set-window-prev-buffers! h (cdr bufs)))))
                  tops)
                (unless stays (select-window! (panes--focus-handle layout handles)))))
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

(define (panes--ctx layout kind inhibit mode)
  "The CTX a policy reads: MODE, KIND (visit or display), INHIBIT as
   inhibit-same, the key of the selected window (#f when it is not a
   window of LAYOUT), the empty pane the selected window stands for,
   and the window keys, the most recently seen first."
  (list 'mode mode 'kind kind 'inhibit-same inhibit
        'selected (panes-key-of-handle layout (active-window))
        'selected-pane (panes--empty-pane-of (active-window))
        'recent (panes--recent layout)))

(define (panes--ensure-layout!)
  "The layout of this frame's group. When it has none: the group's seed
   (panes--seed!), else the frame as it stands (panes-adopt!)."
  (or (panes-layout) (panes--seed! (frame-group)) (panes-adopt!)))

(define (panes-place! buf kind inhibit)
  "BUF opens where the policy says. KIND is visit or display; INHIBIT
   is inhibit-same. The policy decides on the current layout, the
   decision is applied, panes-apply! draws and stores it, and the
   window log notes the decision. It does not select the window.
   Answers the window's handle, or #f."
  (let* ((layout (panes--ensure-layout!))
         (mode (panes--buffer-mode buf))
         (ctx (panes--ctx layout kind inhibit mode))
         (decision (panes-decide layout buf ctx))
         (opened (panes-apply-decision layout buf mode decision))
         (layout (panes-apply! (car opened))))
    (window-log-note! "panes" kind buf mode "->" decision)
    (panes-handle layout (cadr opened))))

(define (panes-visit! buf)
  "A visit: BUF shows and its window is selected, when the window
   exists and is not selected already. Answers the handle, or #f."
  (let ((h (panes-place! buf 'visit #f)))
    (when (and h (window-exists? h) (not (equal? h (active-window))))
      (select-window! h))
    h))

(define (panes-display! buf inhibit)
  "A display: BUF shows, the selection stays. INHIBIT #t keeps BUF out
   of the selected window."
  (panes-place! buf 'display inhibit))

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
    (panes-apply! after)
    (when (window-exists? me) (select-window! me))
    (message (string-append "Consolidated into " (number->string (length (panes-window-keys after))) " windows"))
    me))

(define (panes--materialize! layout)
  "A frame window, hidden, for every window of the model that has none:
   a consolidate makes windows the frame never drew. A handle two keys
   share counts once. The window takes its stack, so it walks as the
   model says. A window whose buffer is not known stays without one."
  (let loop ((ks (panes-window-keys layout)) (l layout) (used '()))
    (if (null? ks)
        l
        (let* ((k (car ks)) (h (panes-handle l k)) (buf (panes-window-buffer l k)))
          (if (and (panes--live-handle? h) (not (member h used)))
              (loop (cdr ks) l (cons h used))
              (let ((nh (and buf (buffer-known? buf) (window-new-hidden! buf))))
                (if nh
                    (begin
                      (set-window-prev-buffers! nh (cdr (panes-window-buffers l k)))
                      (loop (cdr ks) (panes-set-handle l k nh) (cons nh used)))
                    (loop (cdr ks) l used))))))))

(define (panes-quit! win)
  "q in WIN: its shown buffer leaves that window and the next one shows;
   an exhausted window closes. Then the front window of the pane where
   the buffer stood is selected. The buffer is not killed. #t when the
   model knew the window; #f, and nothing changes, when it did not."
  (let* ((layout (panes-layout))
         (k (and layout (panes-key-of-handle layout win))))
    (and k
         (let ((popped (panes-pop layout k)) (pid (panes-pane-of layout k)))
           (window-log-note! "panes quit" k "->" (or (cadr popped) "window closes"))
           (let* ((after (panes-apply! (car popped)))
                  (p (and pid (panes-pane after pid)))
                  (ks (and p (plist-get p 'windows)))
                  (h (and (pair? ks) (panes-handle after (car ks)))))
             ;; quitting leaves you where the buffer stood
             (when (and h (window-exists? h)) (select-window! h)))
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
  "A renamed buffer OLD keeps its places as NEW, in every layout of
   every frame. It draws nothing, and panes--latest keeps the old name."
  (for-each
    (lambda (frame)
      (let ((store (frame-local-in frame 'panes-layouts)))
        (when (pair? store)
          (set-frame-local-in! frame 'panes-layouts
            (map (lambda (e) (list (car e) (panes-rename (cadr e) old new))) store)))))
    (frame-list)))

(define (panes--reconcile!)
  "A change made by another door joins the model. It runs on
   window-configuration-change-hook, and does nothing while panes-mode
   is off, while the model draws, while a layout arranges, or while the
   overview shows. The cases, in order:
   1. A top window that is gone takes its pane with it (C-x 0 deletes
      the pane); in the last pane only the window closes.
   2. A top window that shows a buffer its stack does not have in front
      takes that buffer to the front, when fill-candidate? accepts it.
   3. An empty pane whose blank window is gone goes.
   4. A window on screen the model does not have on top, with a buffer
      fill-candidate? accepts: the blank window of an empty pane fills
      that pane; else it is the front window of a pane whose front
      window a swap took off the screen; else it gets a new pane at
      the end.
   5. Past the capacity, the layout folds and panes-apply! draws it;
      else a changed layout is stored with panes-layout-set!, and the
      frame is not drawn."
  ;; the overview's tiles are not panes: the model waits until it gathers
  (unless (or (not panes-mode) panes--applying (layout-arranging?)
              (frame-local 'windows-overview-rows))
    (let ((layout (panes-layout)))
      (when layout
        (let* ((tops (panes-top-windows layout))
               (l (fold (lambda (l k)
                          (let* ((h (panes-handle l k))
                                 (shown (and h (window-exists? h) (window-buffer h))))
                            ;; C-x 0 deletes the pane; the last pane keeps its place
                            (cond ((and h (not (panes--live-handle? h)))
                                   (let ((gone (panes-remove-pane l (panes-pane-of l k))))
                                     (if (equal? gone l) (panes-close-window l k) gone)))
                                  ((and shown (not (equal? shown (panes-window-buffer l k))) (fill-candidate? shown))
                                   (panes-show l k shown))
                                  (else l))))
                        layout tops))
               ;; an empty pane whose blank window was deleted goes too
               (l (fold (lambda (l pid)
                          (let ((row (assoc (panes--empty-key pid) (panes--empty-rows))))
                            (if (and row (null? (or (plist-get (panes-pane l pid) 'windows) '()))
                                     (not (panes--live-handle? (cadr row))))
                                (begin (panes--forget-empty! pid) (panes-remove-pane l pid))
                                l)))
                        l (panes-pane-ids l)))
               (known (filter (lambda (h) h) (map (lambda (k) (panes-handle l k)) (panes-top-windows l))))
               (rows (panes--frame-row))
               ;; panes whose front window a swap took off the screen
               (vacated (filter (lambda (p) p)
                                (map (lambda (k)
                                       (let ((h (panes-handle l k)))
                                         (and h (not (assoc h rows)) (panes-pane-of l k))))
                                     (panes-top-windows l))))
               (l (let loop ((rows rows) (l l) (vacated vacated))
                    (if (null? rows)
                        l
                        (let ((win (car (car rows))) (buf (cadr (car rows))))
                          (cond ((or (member win known) (not (fill-candidate? buf)))
                                 (loop (cdr rows) l vacated))
                                ;; a buffer shown in an empty pane's blank window fills that pane
                                ((let ((pid (panes--empty-pane-of win))) (and pid (panes-pane l pid)))
                                 (let* ((pid (panes--empty-pane-of win))
                                        (made (panes-new-window l pid buf (panes--buffer-mode buf))))
                                   (panes--forget-empty! pid)
                                   (loop (cdr rows)
                                         (panes-set-handle (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))
                                                           (cadr made) win)
                                         vacated)))
                                ;; a window that took a pane's place on screen is that pane's front window
                                ((pair? vacated)
                                 (let ((k (panes-key-of-handle l win)))
                                   (loop (cdr rows)
                                         (if k
                                             (panes-show (panes-move-window l k (car vacated)) k buf)
                                             (let ((made (panes-new-window l (car vacated) buf (panes--buffer-mode buf))))
                                               (panes-set-handle (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))
                                                                 (cadr made) win)))
                                         (cdr vacated))))
                                (else
                                 (loop (cdr rows)
                                       (let* ((added (panes-add-pane l))
                                              (made (panes-new-window (car added) (cadr added) buf (panes--buffer-mode buf))))
                                         (panes-set-handle (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))
                                                           (cadr made) win))
                                       vacated))))))))
          ;; a window that came on screen past the capacity waits behind the last pane
          (if (> (panes-pane-count l) (panes-capacity l))
              (panes-apply! (panes-fit-capacity l))
              (unless (equal? l layout) (panes-layout-set! l))))))))

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
                 (made (panes-new-window (car added) (cadr added) b (panes--buffer-mode b))))
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
                             (map (lambda (k) (panes-handle l k)) (or (plist-get p 'windows) '())))))
             (panes-panes l)))))

(define (panes--tree-matches? tree layout)
  "A saved frame TREE still fits the model when it shows the model's
   front buffers, in order, and every one of them is known. A model
   with nothing on screen never fits."
  (let ((shown (window-tree-buffers tree))
        (fronts (map (lambda (k) (panes-window-buffer layout k)) (panes-top-windows layout))))
    (and (pair? fronts) (equal? shown fronts) (null? (filter (lambda (b) (not (buffer-known? b))) shown)))))


(define (panes-mode--install!)
  "The doors, installed: panes-mode becomes #t, and every door yields to
   the old path while panes-mode is #f. It draws nothing. The doors:
   switch-to-buffer--show!: a visit, after buffer-join-here!.
   display-buffer: a display, unless display-buffer-agent-refuses?.
   window-swap!: a swap that moved the window swaps it in the model.
   window-unwind-or-close!: panes-quit!, else the old path.
   group-frame-leave!: the group's frame is saved as it is left.
   group-layout-enter!: the saved frame when it fits the model, else
   the layout, else a seed, else a default layout from the saved
   buffers or the group's default panes.
   group-preview-draw!: the switcher's look draws the group's model.
   winner-previous! and winner-next!: layout-undo and layout-redo.
   windows-overview-enter! and windows-overview-exit!: the overview
   spreads the model's windows, and the chosen one comes to the front
   of its pane.
   Hooks: buffer-kill-repair runs panes--kill-repair!,
   buffer-renamed-hook runs panes--rename!,
   window-configuration-change-hook runs panes--reconcile!, and
   window-state-change-hook runs panes--note-focus!."
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
          (panes-display! name (plist-get (or alist '()) 'inhibit-same-window))
          (next name alist))))
  ;; a window moved to the neighbouring pane trades places with that pane's window
  ;; in the model too, so the next placement keeps what the screen shows
  (advice-add! 'window-swap! 'around 'panes
    (lambda (next dir)
      (let* ((win (active-window))
             (nb (and panes-mode (window-in-direction dir)))
             (at (panes--index-of win (map car (window-list))))
             (r (next dir))
             ;; only a swap that happened: the window stands somewhere else now
             (l (and nb (not (equal? at (panes--index-of win (map car (window-list))))) (panes-layout)))
             (a (and l (panes-key-of-handle l win)))
             (b (and l (panes-key-of-handle l (car nb)))))
        (when (and a b)
          (window-log-note! "panes swap" a b)
          (panes-layout-set! (panes-swap-windows l a b)))
        r)))
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
            (cond
              ;; the frame as the group was left: put back, nothing recalculated
              ((and (panes-layout) saved (panes--tree-matches? saved (panes-layout)))
               (with-layout-held (lambda () (window-tree-set! saved))))
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
                              (front (panes-handle l (car (or (plist-get (panes-pane l pid) 'windows) (list k))))))
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
  (add-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (add-hook! 'window-state-change-hook 'panes--note-focus!))

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
              group-preview-draw! winner-previous! winner-next! windows-overview-enter! windows-overview-exit!))
  (remove-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (remove-hook! 'buffer-renamed-hook 'panes--rename!)
  (remove-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (remove-hook! 'window-state-change-hook 'panes--note-focus!)
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
  "The pane of the selected window trades places with its neighbour,
   every window and stack in it going along. STEP -1 is left, 1 is
   right. #t when it moved; at the edge, a message and #f."
  ;; the pane of the selected window trades places with its neighbour, every
  ;; window and stack in it going along
  (let* ((l (panes--ensure-layout!))
         (pid (panes--current-pane l))
         (ids (map (lambda (p) (plist-get p 'id)) (panes-panes l)))
         (i (let loop ((xs ids) (n 0))
              (cond ((null? xs) #f) ((equal? (car xs) pid) n) (else (loop (cdr xs) (+ n 1))))))
         (to (and i (+ i step))))
    (if (and to (>= to 0) (< to (length ids)))
        (begin (panes-apply! (panes-move-pane l pid to)) #t)
        (begin (message "No pane that way") #f))))

(define (panes--shift-window! dir)
  "The selected window goes on top of the next pane's windows, which
   wait behind it. At the edge it takes a new pane while there is room.
   DIR -1 is left, 1 is right. A pane it leaves empty goes, unless it
   is the last. The window stays selected. #t when it moved; else a
   message and #f."
  ;; the selected window goes on top of the next pane's windows, which wait
  ;; behind it; at the edge it takes a new pane while there is room
  (let* ((l (panes--ensure-layout!))
         (key (panes-key-of-handle l (active-window)))
         (from (and key (panes-pane-of l key)))
         (ids (panes-pane-ids l))
         (i (and from (+ dir (panes--index-of from ids))))
         (next (cond ((not i) #f)
                     ((and (>= i 0) (< i (length ids))) (panes-move-window l key (list-ref ids i)))
                     ((not (panes-under-capacity? l)) #f)
                     (else (let ((added (panes-add-pane l (if (< i 0) 0 (length ids)))))
                             (panes-move-window (car added) key (cadr added)))))))
    (if (not next)
        (begin (message "No pane that way") #f)
        (let* ((applied (panes-apply! next))
               (h (panes-handle applied key)))
          (when (and h (window-exists? h)) (select-window! h))
          #t))))

(define-command "pane-move-left" "Move this pane left, with all its windows"
  (lambda () (panes--move-current-pane! -1)))

(define-command "pane-move-right" "Move this pane right, with all its windows"
  (lambda () (panes--move-current-pane! 1)))

(define (panes--cycle-pane-window! step)
  "The next window of the selected pane comes to its front; the one
   that was there goes to the back, so stepping on walks the whole
   pane. STEP 1 is forward, -1 is back. The new front window is
   selected. A message and #f when the pane has fewer than two windows."
  ;; the next window of the selected pane comes to its front; the one that
  ;; was there goes to the back, so stepping on walks the whole pane
  (let* ((l (panes--ensure-layout!))
         (k (panes-key-of-handle l (active-window)))
         (pid (and k (panes-pane-of l k)))
         (ws (if pid (or (plist-get (panes-pane l pid) 'windows) '()) '())))
    (if (< (length ws) 2)
        (begin (message "No other window in this pane") #f)
        (let* ((order (if (> step 0)
                          (append (cdr ws) (list (car ws)))
                          (cons (car (reverse ws)) (reverse (cdr (reverse ws))))))
               (applied (panes-apply! (panes--update-pane l pid (lambda (p) (panes--put p 'windows order)))))
               (h (panes-handle applied (car order))))
          (when (and h (window-exists? h)) (select-window! h))
          #t))))

(define-command "pane-next-window" "Bring the next window of this pane to the front"
  (lambda () (panes--cycle-pane-window! 1)))

(define-command "pane-previous-window" "Bring the previous window of this pane to the front"
  (lambda () (panes--cycle-pane-window! -1)))

(define-command "pane-add" "Add an empty pane to the right of this one; you stay where you are"
  (lambda ()
    (let* ((l (panes--ensure-layout!))
           (me (active-window)))
      (panes-apply! (car (panes-add-empty-pane l (panes--current-pane l))))
      (when (window-exists? me) (select-window! me)))))

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
            (let* ((applied (panes-apply! (car split)))
                   (h (panes-handle applied (cadr split))))
              (when (and h (window-exists? h)) (select-window! h))
              h)))))

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

(when (and panes-mode-default (not panes-mode)) (panes-mode--install!))
