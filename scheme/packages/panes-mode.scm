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
(define (panes-layout)
  (let ((e (assoc (panes--group-key) (panes--store))))
    (and e (cadr e))))

(define (panes-layout-set! layout)
  (set-frame-local! 'panes-layouts (alist-put (panes--store) (panes--group-key) layout))
  layout)

(define (panes-layout-forget!)
  (set-frame-local! 'panes-layouts (alist-delete (panes--store) (panes--group-key))))

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

(define (panes-adopt!) (panes-layout-set! (panes-adopt)))

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

(define (panes-apply! layout)
  (let* ((tops (panes-top-windows layout))
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
              (unless (member (active-window) handles) (select-window! (car handles))))))
        (panes-layout-set! layout))
      (lambda () (set! panes--applying #f)))
    (window-state-changed!)
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
(define (panes-quit! win)
  (let* ((layout (panes-layout))
         (k (and layout (panes-key-of-handle layout win))))
    (and k
         (let ((popped (panes-pop layout k)))
           (window-log-note! "panes quit" k "->" (or (cadr popped) "window closes"))
           (panes-apply! (car popped))
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
           (panes-apply! (panes-drop-buffer layout name))
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
  (unless (or (not panes-mode) panes--applying (layout-arranging?))
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
               (l (fold (lambda (l row)
                          (let ((win (car row)) (buf (cadr row)))
                            (if (or (member win known) (not (fill-candidate? buf)))
                                l
                                (let* ((added (panes-add-pane l))
                                       (made (panes-new-window (car added) (cadr added) buf (panes--buffer-mode buf))))
                                  (panes-set-handle (panes-set-buffers (car made) (cadr made) (panes--window-stack win buf))
                                                    (cadr made) win)))))
                        l (panes--frame-row))))
          (unless (equal? l layout) (panes-layout-set! l)))))))

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

(define (panes-mode-enable!)
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
  (advice-add! 'window-unwind-or-close! 'around 'panes
    (lambda (next win) (if (and panes-mode (panes-quit! win)) #t (next win))))
  (advice-add! 'switch-to-group! 'around 'panes
    (lambda (next g) (let ((r (next g))) (when panes-mode (panes--enter-group!)) r)))
  (add-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (add-hook! 'buffer-renamed-hook 'panes--rename!)
  (add-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (panes--enter-group!)
  (message "panes-mode on: one window per mode, in a row of panes"))

(define (panes-mode-disable!)
  (set! panes-mode #f)
  (for-each (lambda (t) (advice-remove! t 'panes))
            '(switch-to-buffer--show! display-buffer window-unwind-or-close! switch-to-group!))
  (remove-hook! '(buffer-kill-repair panes) 'panes--kill-repair!)
  (remove-hook! 'buffer-renamed-hook 'panes--rename!)
  (remove-hook! 'window-configuration-change-hook 'panes--reconcile!)
  (message "panes-mode off"))

(define-command "panes-mode"
  "Toggle the window model: a row of panes, each a stack of windows, each a stack of buffers; a buffer opens where the window policy says"
  (lambda () (if panes-mode (panes-mode-disable!) (panes-mode-enable!))))

(define-command "panes-adopt"
  "Read this frame as it stands into the window model, and lay it out from the model"
  (lambda () (panes-apply! (panes-adopt))))

(public! 'panes-layout "(panes-layout) -> the window model of this frame's group, or #f")
(catalog-meta! 'function "panes-layout" 'effects '(read))
(public! 'panes-apply! "(panes-apply! LAYOUT) -> lay the frame out as LAYOUT and keep it as this group's model")
(public! 'panes-adopt "(panes-adopt) -> this frame as a layout: one pane per window on screen, the hidden windows behind the last")
(catalog-meta! 'function "panes-adopt" 'effects '(read))
