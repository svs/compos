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

(define (panes--store) (or (frame-local 'panes-layouts) '()))
(define (panes--group-key) (or (frame-group) 'none))

;; the layout of this frame's group, or #f
(define (panes-layout) (panes-layout-of (panes--group-key)))

;; the layout of group G on this frame, or #f
(define (panes-layout-of g)
  (let ((e (assoc (or g 'none) (panes--store))))
    (and e (cadr e))))

;; the raw write: a change records in the layout history only through
;; panes-layout-set!
(define (panes--layout-store! g layout)
  (set-frame-local! 'panes-layouts (alist-put (panes--store) (or g 'none) layout))
  layout)

(define (panes-layout-set! layout) (panes--layout-store! (panes--group-key) layout))

(define (panes-layout-forget!)
  (set-frame-local! 'panes-layouts (alist-delete (panes--store) (panes--group-key))))

;; --- across restarts -------------------------------------------------------
;; every frame's layouts go into the desktop as they are. A window id
;; survives a restart (the desktop names it), and a handle that did not
;; come back is taken again by buffer when the frame next draws the layout.
(define (panes-layouts-state)
  (map (lambda (frame) (list frame (or (frame-local-in frame 'panes-layouts) '())))
       (frame-list)))

(define (panes-layouts-restore! saved)
  (for-each (lambda (entry)
              (when (and (pair? entry) (pair? (cdr entry)) (member (car entry) (frame-list)))
                (set-frame-local-in! (car entry) 'panes-layouts (cadr entry))))
            (or saved '())))

(persist-global! 'panes-layouts panes-layouts-state panes-layouts-restore!)

;;; --- the frame as a layout ---------------------------------------------------------

(define (panes--buffer-mode b)
  (and (string? b) (buffer-known? b) (or (buffer-local b 'mode-name) "fundamental-mode")))

(define (panes--live-handle? h)
  (and h (or (window-exists? h) (assoc h (window-hidden-list))) #t))

;; the work windows on screen, left to right: (WIN BUF WIDTH) rows
(define (panes--frame-row)
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

;; a window's stack as the model keeps it: what it shows, then its history
(define (panes--window-stack win buf)
  (panes--uniq (cons buf (filter (lambda (b) (and (buffer-known? b) (fill-candidate? b)))
                                 (window-prev-buffers win)))))

;; the frame as it stands: one pane per window on screen, left to right,
;; each holding that window; the hidden windows wait behind the last pane
(define (panes-adopt)
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

(define (panes-adopt!) (panes-layout-set! (panes-fit-capacity (panes-adopt))))

;;; --- apply: the frame becomes the model -----------------------------------------------

;; every window in KEYS has a live handle
(define (panes--materialize layout keys)
  (fold (lambda (l k)
          (let ((h (panes-handle l k)) (buf (panes-window-buffer l k)))
            (cond ((panes--live-handle? h) l)
                  ((not buf) l)
                  (else (let ((nw (window-new-hidden! buf)))
                          (if nw (panes-set-handle l k nw) l))))))
        layout keys))

;; the shares of the panes that have a window, normalized
(define (panes--top-shares layout)
  (let* ((rows (filter (lambda (p) (pair? (plist-get p 'windows))) (panes-panes layout)))
         (raw (map (lambda (p) (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1))) rows))
         (total (apply + raw)))
    (map (lambda (s) (/ s total)) raw)))

;; a window whose handle is gone takes the frame window that shows its
;; buffer, on screen or hidden, each window once: a layout read back from
;; the desktop, or one whose windows another door rebuilt, meets the frame
;; again without a new window being made
(define (panes--attach-handles layout)
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

;; the frame drawn as LAYOUT: every top window on screen with its pane's
;; share, showing the front of its stack, the rest waiting behind. Answers
;; the layout with the handles the draw took or made. Nothing is recorded.
(define (panes--draw! layout)
  (let* ((layout (panes--attach-handles layout))
         (tops (panes-top-windows layout))
         (layout (panes--materialize layout tops))
         (handles (filter (lambda (h) h) (map (lambda (k) (panes-handle layout k)) tops))))
    (set! panes--applying #t)
    (unwind-protect
      (lambda ()
        (with-layout-suppressed
          (lambda ()
            (when (and (pair? handles) (= (length handles) (length tops)))
              (window-arrange-line! 'h (panes--top-shares layout) handles)
              (for-each
                (lambda (k)
                  (let ((h (panes-handle layout k)) (bufs (panes-window-buffers layout k)))
                    (when (and h (pair? bufs) (window-exists? h))
                      (unless (equal? (window-buffer h) (car bufs))
                        (window-set-buffer! h (car bufs)))
                      (set-window-prev-buffers! h (cdr bufs)))))
                tops)
              (unless (member (active-window) handles) (select-window! (car handles)))))))
      (lambda () (set! panes--applying #f)))
    layout))

;; the frame follows LAYOUT and it becomes this group's model
(define (panes-apply! layout)
  (let ((layout (panes--draw! layout)))
    (panes-layout-set! layout)
    (window-state-changed!)
    layout))

;; a look: the frame shows LAYOUT and nothing is recorded as a change. The
;; model of group G keeps the handles the look made, so the switch into G
;; finds its windows on screen already.
(define (panes-look! layout &optional g)
  (let ((layout (panes--draw! layout)))
    (when g (panes--layout-store! g layout))
    layout))

;;; --- the doors ------------------------------------------------------------------------

;; window keys, the most recently seen first, by the buffer each shows
(define (panes--recent layout)
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
  (list 'mode mode 'kind kind 'inhibit-same inhibit
        'selected (panes-key-of-handle layout (active-window))
        'recent (panes--recent layout)))

;; the layout of this frame's group, adopted from the frame when it has none
(define (panes--ensure-layout!)
  (or (panes-layout) (panes-adopt!)))

;; BUF opens where the policy says; the window's handle, or #f
(define (panes-place! buf kind inhibit)
  (let* ((layout (panes--ensure-layout!))
         (mode (panes--buffer-mode buf))
         (ctx (panes--ctx layout kind inhibit mode))
         (decision (panes-decide layout buf ctx))
         (opened (panes-apply-decision layout buf mode decision))
         (layout (panes-apply! (car opened))))
    (window-log-note! "panes" kind buf mode "->" decision)
    (panes-handle layout (cadr opened))))

;; a visit: BUF shows and its window is selected
(define (panes-visit! buf)
  (let ((h (panes-place! buf 'visit #f)))
    (when (and h (window-exists? h) (not (equal? h (active-window))))
      (select-window! h))
    h))

;; a display: BUF shows, the selection stays
(define (panes-display! buf inhibit)
  (panes-place! buf 'display inhibit))

;; q in WIN: its shown buffer leaves that window and the next one shows;
;; an exhausted window closes. #t when the model knew the window.
;; the frame's hidden windows the model does not hold, most recently used first, as
;; the 'spares an emptied pane takes before it goes (panes-close-window); EXCEPT is
;; a buffer that is leaving
(define (panes--spare-windows layout &optional except)
  (filter (lambda (s) s)
          (map (lambda (row)
                 (let ((win (car row)) (buf (cadr row)))
                   (and (not (panes-key-of-handle layout win))
                        (string? buf) (not (equal? buf except))
                        (buffer-known? buf) (fill-candidate? buf)
                        (list win buf (panes--window-stack win buf) (panes--buffer-mode buf)))))
               (window-hidden-list))))

(define (panes--with-spares layout &optional except)
  (plist-put layout 'spares (panes--spare-windows layout except)))

;; the model keeps no spares: the frame's hidden windows change under it
(define (panes--without-spares layout) (plist-put layout 'spares '()))

(define (panes-quit! win)
  (let* ((layout (panes-layout))
         (k (and layout (panes-key-of-handle layout win))))
    (and k
         (let ((popped (panes-pop (panes--with-spares layout) k)))
           (window-log-note! "panes quit" k "->" (or (cadr popped) "window closes"))
           (panes-apply! (panes--without-spares (car popped)))
           #t))))

;; a buffer dies: it leaves every stack before the core looks for a
;; stand-in. The keyed hook (buffer-kill-repair KEY) answers a thunk for
;; after the kill, or #f when it has nothing to say; the first answer wins,
;; so while the mode is on the group repair stands down.
(define (panes--kill-repair! name)
  (let ((layout (panes-layout)))
    (and layout (member name (panes-buffers layout))
         (begin
           (window-log-note! "panes kill" name)
           (panes-apply! (panes--without-spares (panes-drop-buffer (panes--with-spares layout name) name)))
           (lambda () (window-state-changed!))))))

(define (panes--rename! old new)
  (for-each
    (lambda (frame)
      (let ((store (frame-local-in frame 'panes-layouts)))
        (when (pair? store)
          (set-frame-local-in! frame 'panes-layouts
            (map (lambda (e) (list (car e) (panes-rename (cadr e) old new))) store)))))
    (frame-list)))

;; a change made by another door joins the model: a pane that shows a
;; buffer the model does not know of takes it onto its window's stack; a
;; window on screen the model never saw gets a pane; a window that is gone
;; leaves the model
(define (panes--reconcile!)
  ;; the overview's tiles are not panes: the model waits until it gathers
  (unless (or (not panes-mode) panes--applying (layout-arranging?)
              (frame-local 'windows-overview-rows))
    (let ((layout (panes-layout)))
      (when layout
        (let* ((tops (panes-top-windows layout))
               (l (fold (lambda (l k)
                          (let* ((h (panes-handle l k))
                                 (shown (and h (window-exists? h) (window-buffer h))))
                            (cond ((and h (not (panes--live-handle? h))) (panes-close-window l k))
                                  ((and shown (not (equal? shown (panes-window-buffer l k))) (fill-candidate? shown))
                                   (panes-show l k shown))
                                  (else l))))
                        layout tops))
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

;; the frame enters a group: its layout comes back, or the frame is read
;; in. The layout target stands down: the model owns the shape now.
(define (panes--enter-group!)
  (layout-target-free!)
  (window-log-note! "panes enter group" (or (frame-group) "none"))
  (let ((layout (panes-layout)))
    (if layout
        (panes-apply! (panes-validate layout buffer-known?))
        (panes-adopt!))))

;;; --- the mode ---------------------------------------------------------------------------

(define (panes--door?)
  (and panes-mode (not (buffer-context?)) (not (layout-arranging?)) (not panes--applying)))

;; one pane per buffer, left to right, equal shares: a group's first layout
(define (panes--default-layout bufs)
  (fold (lambda (l b)
          (let* ((added (panes-add-pane l))
                 (made (panes-new-window (car added) (cadr added) b (panes--buffer-mode b))))
            (car made)))
        (panes-empty)
        bufs))

;; the model as group-panes rows, ((PANE WIN ...) ...), the window on screen
;; first: the overview spreads and gathers the frame by these rows
(define (panes--rows)
  (let ((l (panes-layout)))
    (if (not l)
        '()
        (map (lambda (p)
               (cons (plist-get p 'id)
                     (filter (lambda (h) h)
                             (map (lambda (k) (panes-handle l k)) (or (plist-get p 'windows) '())))))
             (panes-panes l)))))

;; the doors, installed: every one yields to the old path while panes-mode is #f
(define (panes-mode--install!)
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
  (advice-add! 'group-layout-enter! 'around 'panes
    (lambda (next id saved)
      (if (not panes-mode)
          (next id saved)
          (begin
            (layout-target-free!)
            (window-log-note! "panes enter group" id)
            (if (panes-layout)
                (panes-apply! (panes-validate (panes-layout) buffer-known?))
                ;; no model yet: the group's saved arrangement names the
                ;; buffers, else the group's default does; the model is built
                ;; from them and the frame's other windows only step aside
                (let* ((kept (if saved
                                 (begin (group-revive-layout-files! saved)
                                        (filter (lambda (b) (and (buffer-known? b) (fill-candidate? b) (buffer-in-group? b id)))
                                                (window-tree-buffers saved)))
                                 '()))
                       (bufs (if (pair? kept) kept (group-default-panes id))))
                  (panes-apply! (panes--default-layout bufs))))
            ;; the group's chosen layout comes back with it: the frame is
            ;; free only while the panes are drawn
            (layout-target-set! (group-layout-target id))
            (layout-target-default!)))))
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
      (when panes-mode
        (panes--ensure-layout!)
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
            (when (and k (not stay))
              (panes-apply! (if (and home (panes-pane l home)) (panes-move-window l k home 0) (panes-raise l k)))
              (when (window-exists? me) (select-window! me)))
            r))))
  (add-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (add-hook! 'buffer-renamed-hook 'panes--rename!)
  (add-hook! 'window-configuration-change-hook 'panes--reconcile!))

(define (panes-mode-enable!)
  (panes-mode--install!)
  (panes--enter-group!)
  (message "panes-mode on: one window per mode, in a row of panes"))

(define (panes-mode-disable!)
  (set! panes-mode #f)
  (for-each (lambda (t) (advice-remove! t 'panes))
            '(switch-to-buffer--show! display-buffer window-unwind-or-close! group-layout-enter!
              group-preview-draw! winner-previous! winner-next! windows-overview-enter! windows-overview-exit!))
  (remove-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (remove-hook! 'buffer-renamed-hook 'panes--rename!)
  (remove-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (message "panes-mode off"))

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
