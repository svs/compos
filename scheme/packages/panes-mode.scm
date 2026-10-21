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
  (when (string? g) (set! panes--latest (alist-put panes--latest g (panes-strip-handles layout))))
  layout)

;; the newest layout of every group, whichever frame made it: a frame that
;; enters a group it has never shown takes this, not whatever the screen holds
(define panes--latest (if (boundp 'panes--latest) panes--latest '()))

(define (panes--seed g)
  (let ((e (and g (assoc g panes--latest))))
    (if e
        (cadr e)
        (let loop ((fs (frame-list)))
          (if (null? fs)
              #f
              (let ((e (and g (assoc g (or (frame-local-in (car fs) 'panes-layouts) '())))))
                (if e (panes-strip-handles (cadr e)) (loop (cdr fs)))))))))

(define (panes--seed! g)
  (let ((seed (panes--seed g)))
    (and seed (panes-apply! (panes-validate seed buffer-known?)))))

(define (panes-layout-set! layout)
  (let ((layout (panes-unique-buffers layout)))
    (panes--layout-store! (panes--group-key) layout)
    (panes--check-model! layout)))

(define (panes-model-faults model)
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
  ;; a model that breaks its rules is noted in the window log with the
  ;; command that broke it, once, so the break can be found
  (let ((faults (if layout (panes-model-faults layout) '())))
    (unless (or (null? faults) (equal? faults panes--last-faults))
      (window-log-note! "panes model broken" (string-join faults "; "))
      (message (string-append "panes: the window model broke: " (car faults))))
    (set! panes--last-faults faults)))

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
;; a restart brings new frame ids, so the per-group layouts carry across apart
(persist-global! 'panes-latest (lambda () panes--latest) (lambda (saved) (set! panes--latest (or saved '()))))

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

;; an empty pane holds no window of the model; the frame shows it as a window
;; on the blank buffer. That window is kept here, per group and pane, and
;; never in the model: ((GROUP PANE) . WIN) rows
(define panes-empty-buffer " *pane*")

(define (panes--empty-rows) (or (frame-local 'panes-empty-windows) '()))
(define (panes--empty-key pid) (list (panes--group-key) pid))

(define (panes--empty-handle pid)
  (let ((row (assoc (panes--empty-key pid) (panes--empty-rows))))
    (and row (panes--live-handle? (cdr row)) (cdr row))))

(define (panes--forget-empty! pid)
  (set-frame-local! 'panes-empty-windows
    (filter (lambda (r) (not (equal? (car r) (panes--empty-key pid)))) (panes--empty-rows))))

(define (panes--empty-handle! pid)
  (or (panes--empty-handle pid)
      (begin
        (unless (buffer-exists? panes-empty-buffer) (buffer-create panes-empty-buffer))
        (let ((h (window-new-hidden! panes-empty-buffer)))
          (when h
            (panes--forget-empty! pid)
            (set-frame-local! 'panes-empty-windows (cons (cons (panes--empty-key pid) h) (panes--empty-rows))))
          h))))

;; the pane of this group that frame window WIN stands for while it is empty, or #f
(define (panes--empty-pane-of win)
  (let* ((g (panes--group-key))
         (row (find (lambda (r) (and (equal? (cdr r) win) (equal? (car (car r)) g))) (panes--empty-rows))))
    (and row (cadr (car row)))))

;; a pane that took a window takes its blank one too, so the frame window stays
(define (panes--claim-empty-windows layout)
  (fold (lambda (l p)
          (let* ((ks (or (plist-get p 'windows) '()))
                 (pid (plist-get p 'id))
                 (h (and (pair? ks) (panes--empty-handle pid))))
            (if (and h (not (panes--live-handle? (panes-handle l (car ks)))))
                (begin (panes--forget-empty! pid) (panes-set-handle l (car ks) h))
                l)))
        layout (panes-panes layout)))

;; the blank windows of panes that hold a window now, or are gone, go
(define (panes--drop-stale-empty-windows! layout)
  (let ((g (panes--group-key)))
    (for-each (lambda (r)
                (let ((p (and (equal? (car (car r)) g) (panes-pane layout (cadr (car r))))))
                  (when (and (equal? (car (car r)) g) (or (not p) (pair? (or (plist-get p 'windows) '()))))
                    (panes--forget-empty! (cadr (car r)))
                    (when (assoc (cdr r) (window-hidden-list)) (window-hidden-delete! (cdr r))))))
              (panes--empty-rows))))

;; a frame window for every pane, left to right: its front window, else its blank one
(define (panes--pane-handles layout)
  (map (lambda (p)
         (let ((ks (or (plist-get p 'windows) '())))
           (if (pair? ks) (panes-handle layout (car ks)) (panes--empty-handle! (plist-get p 'id)))))
       (panes-panes layout)))

;; every window in KEYS has a live handle
(define (panes--materialize layout keys)
  (fold (lambda (l k)
          (let ((h (panes-handle l k)) (buf (panes-window-buffer l k)))
            (cond ((panes--live-handle? h) l)
                  ((not buf) l)
                  (else (let ((nw (window-new-hidden! buf)))
                          (if nw (panes-set-handle l k nw) l))))))
        layout keys))

;; the shares of the panes, empty ones too, normalized
(define (panes--top-shares layout)
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
;; share, showing the front of its stack, the rest waiting behind; an empty
;; pane shows its blank window. Answers
;; the layout with the handles the draw took or made. Nothing is recorded.
(define (panes--draw! layout)
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
              (window-arrange-line! 'h (panes--top-shares layout) handles)
              (for-each
                (lambda (k)
                  (let ((h (panes-handle layout k)) (bufs (panes-window-buffers layout k)))
                    (when (and h (pair? bufs) (window-exists? h))
                      (unless (equal? (window-buffer h) (car bufs))
                        (window-set-buffer! h (car bufs)))
                      (set-window-prev-buffers! h (cdr bufs)))))
                tops)
              (unless (member (active-window) handles) (select-window! (car handles))))
            (panes--drop-stale-empty-windows! layout))))
      (lambda () (set! panes--applying #f)))
    layout))

;; the frame follows LAYOUT and it becomes this group's model
;; the open buffers of this frame's group: each is in a window. The read model
;; answers the group's names; only the ones no window holds are checked further
(define (panes--group-buffers &optional held)
  (let* ((group (or (frame-group) (and (boundp 'group-cycle-group) (group-cycle-group))))
         (names (if group (map car (cadr (buffer-rows (list 'groups (list group) 'fields '(name))))) '())))
    (filter (lambda (b) (or (and held (member b held))
                            (and (not (string-prefix? " " b))
                                 (fill-candidate? b)
                                 (not (buffer-context-only? b)))))
            names)))

(define (panes-apply! layout)
  ;; a buffer is in one window, whatever made this layout, and every window of
  ;; the layout is a window of the frame: one the screen does not show waits hidden.
  ;; Only the layout's own windows are drawn: a member of the group with no
  ;; window stays without one until the user opens it
  (let ((layout (panes--draw! (panes--materialize! (panes-unique-buffers layout)))))
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
        'selected-pane (panes--empty-pane-of (active-window))
        'recent (panes--recent layout)))

;; the layout of this frame's group, adopted from the frame when it has none
(define (panes--ensure-layout!)
  (or (panes-layout) (panes--seed! (frame-group)) (panes-adopt!)))

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
;; consolidate on the model: every mode one window. The frame-level consolidate
;; makes hidden windows the model does not know, and the next redraw throws them away
(define (panes-consolidate!)
  (let* ((me (active-window))
         ;; every buffer is in a window already (panes-apply!); consolidate only regroups
         (after (panes-consolidate (panes--ensure-layout!) panes--buffer-mode)))
    (window-log-note! "panes consolidate")
    (panes-apply! after)
    (when (window-exists? me) (select-window! me))
    (message (string-append "Consolidated into " (number->string (length (panes-window-keys after))) " windows"))
    me))

;; a frame window, hidden, for every window of the model that has none: a
;; consolidate makes windows the frame never drew. A handle two keys share
;; counts once. The window takes its stack, so it walks as the model says
(define (panes--materialize! layout)
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
           ;; a kill from the overview keeps no count of panes: an emptied pane goes;
           ;; elsewhere it stays, empty
           (panes-apply! (if (and (boundp 'windows-overview-active?) (windows-overview-active?))
                             (plist-put (panes-drop-buffer (plist-put layout 'bare #t) name) 'bare #f)
                             (panes-drop-buffer layout name)))
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
;; takes its pane with it (C-x 0 deletes the pane)
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
                                     (not (panes--live-handle? (cdr row))))
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

;; the frame enters a group: its layout comes back, or the frame is read
;; in. The layout target stands down: the model owns the shape now.
(define (panes--enter-group!)
  (window-log-note! "panes enter group" (or (frame-group) "none"))
  (let ((layout (panes-layout)))
    (if layout
        (panes-apply! (panes-validate layout buffer-known?))
        (or (panes--seed! (frame-group)) (panes-adopt!))))
  (layout-target-refresh!))

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
            ;; the group's layout stays the target; panes--draw! holds the
            ;; reflow back while it draws
            (window-log-note! "panes enter group" id)
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

;; the pane of the selected window, an empty pane's blank window included
(define (panes--current-pane l)
  (let ((k (panes-key-of-handle l (active-window))))
    (or (and k (panes-pane-of l k)) (panes--empty-pane-of (active-window)))))

;; an empty pane right after PID (the end when #f); the capacity grows to hold
;; it. (LAYOUT ID)
(define (panes-add-empty-pane l pid)
  (let* ((i (and pid (panes--index-of pid (panes-pane-ids l))))
         (added (panes-add-pane l (if i (+ i 1) (panes-pane-count l))))
         (l (car added)))
    (list (if (> (panes-pane-count l) (panes-capacity l)) (panes-set-capacity l (panes-pane-count l)) l)
          (cadr added))))

(define (panes--move-current-pane! step)
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

;; BUFS go to a second window of their mode, beside FROM (the window that
;; holds the first of them when absent); the new window is selected
(define (panes-split-off! bufs &optional from)
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
