;;; peek.scm --- the row of a list in a real window of the panes model.
;;;
;;; docs/PEEK.md is the contract. A peek is a model window with a 'peek
;;; mark at the front of a pane. Dismiss removes that window, so the
;;; window under it comes back with nothing to restore; keep clears the
;;; mark. One peek for each frame: the next row changes the buffer of the
;;; same window.

(require 'panes-mode)

(domain! 'windows)
(effects! '(write display))

(defcustom 'listing-preview-style 'peek
  "How a list previews the row at point: peek shows the real buffer in a window beside the list, or over it when there is no room; float shows a read-only card over the list."
  'group 'windows)

;; --- state ---------------------------------------------------------------
;; the frame's peek: (owner LIST buffer BUF key KEY made PANE-ID|#f
;; asleep BOOL held ((KEY PANE BUFS MODE) ...) group G). held is every
;; other window that had BUF before the peek took it.

(effects! '(read))

(define (peek-state) (frame-local 'peek))
(define (peek-owner) (let ((s (peek-state))) (and s (plist-get s 'owner))))
(define (peek-buffer) (let ((s (peek-state))) (and s (plist-get s 'buffer))))

(define (peek--asleep? buf)
  "#t when BUF is known but has no process: a dormant buffer."
  (and (buffer-known? buf) (not (buffer-exists? buf))))

(define (peek--foreign? buf)
  "#t when another group holds BUF: groups are sealed, so it cannot enter
   this group's model."
  (let ((g (buffer-group buf)) (here (frame-group)))
    (and g here (not (buffer-in-group? buf here)))))

(effects! '(pure))

(define (peek--holders l buf except)
  "The windows of L that hold BUF, other than EXCEPT, as (KEY PANE BUFS MODE)."
  (map (lambda (k) (list k (panes-pane-of l k) (panes-window-buffers l k) (panes-window-mode l k)))
       (filter (lambda (k) (not (equal? k except))) (panes-windows-holding l buf))))

(define (peek--restore-held l buf held)
  "L with BUF back in the windows HELD names. A window that closed when
   it lost BUF comes back at the back of its pane."
  (fold (lambda (l h)
          (let ((k (car h)) (pid (cadr h)) (bufs (filter buffer-known? (caddr h))) (mode (cadddr h)))
            (cond ((panes-window l k)
                   (let ((now (panes-window-buffers l k)))
                     (panes-set-buffers l k (append bufs (filter (lambda (b) (not (member b bufs))) now)))))
                  ((and (panes-pane l pid) (pair? bufs))
                   (let ((a (panes-add-window l pid buf mode #t)))
                     (panes-set-buffers (car a) (cadr a) bufs)))
                  (else l))))
        l held))

(define (peek--pane l owner here)
  "Where a peek of OWNER's row goes: (LAYOUT PANE MADE?). The pane after
   OWNER's, else a new pane after it while there is room, else the pane
   before, else OWNER's own pane. An OWNER in no pane, as a prompt's
   list, peeks over HERE. #f with no pane at all."
  (let* ((ok (panes-find l owner))
         (from (if ok (panes-pane-of l ok) here))
         (ids (panes-pane-ids l))
         (i (and from (panes--index-of from ids))))
    (cond ((not i) #f)
          ((not ok) (list l from #f))
          ((< (+ i 1) (length ids)) (list l (list-ref ids (+ i 1)) #f))
          ((panes-under-capacity? l)
           (let ((a (panes-add-pane l (+ i 1)))) (list (car a) (cadr a) #t)))
          ((> i 0) (list l (list-ref ids (- i 1)) #f))
          (else (list l from #f)))))

(define (peek--without l s)
  "L without the peek S: its window goes, its buffer goes back to the
   windows that held it, and a pane the peek made goes when empty."
  (let* ((made (plist-get s 'made))
         (l (panes-remove-window l (plist-get s 'key)))
         (l (peek--restore-held l (plist-get s 'buffer) (plist-get s 'held))))
    (if (and made (panes-pane l made) (null? (panes-pane-keys l made)))
        (panes-remove-pane l made)
        l)))

;; --- the buffer ----------------------------------------------------------

(effects! '(write display))

(define (peek--arm! buf)
  "BUF is a peek: peek-mode's keys are on, and an edit keeps it."
  (when (buffer-exists? buf)
    (enable-minor-mode! buf "peek-mode")
    (buffer-watch-change! buf 'peek (lambda args (peek-keep!)))))

(define (peek--disarm! buf)
  (when (buffer-exists? buf)
    (buffer-unwatch-change! buf 'peek)
    (when (minor-mode-on? buf "peek-mode") (disable-minor-mode! buf "peek-mode"))))

(define (peek--left! buf asleep)
  "BUF is no longer the peek and not kept: it goes back to sleep when it
   was asleep before. buffer-sleep! refuses a buffer on screen, busy or
   pinned, and then BUF stays awake."
  (peek--disarm! buf)
  (when (and asleep (buffer-exists? buf) (not (window-showing buf)))
    (buffer-sleep! buf)))

;; --- show, swap, dismiss, keep -------------------------------------------

(define (peek--show! owner target)
  (let* ((l (panes--ensure-layout!))
         (here (panes--selected-pane l))
         (to (and l (peek--pane l owner here))))
    (and to
         (let* ((l (car to)) (pid (cadr to))
                (held (peek--holders l target #f))
                (asleep (peek--asleep? target))
                (added (panes-add-window (panes-drop-buffer l target) pid target (panes--buffer-mode target)))
                (key (cadr added))
                (l (panes--update-window (car added) key
                     (lambda (w) (panes--put (panes--put w 'peek #t) 'preferred #f))))
                (l (if (and here (panes-pane l here)) (panes-set-focus l here) l))
                (drawn (panes-apply! l)))
           (set-frame-local! 'peek
             (list 'owner owner 'buffer target 'key key 'made (and (caddr to) pid)
                   'asleep asleep 'held held 'group (panes--group-key)))
           (peek--arm! target)
           (window-log-note! "peek" target "->" key)
           (or (panes-handle drawn key) #t)))))

(define (peek--swap! target)
  (let* ((s (peek-state)) (old (plist-get s 'buffer)) (key (plist-get s 'key))
         (l (panes-layout))
         (held (peek--holders l target key))
         (asleep (peek--asleep? target))
         (l (panes-set-buffers (panes-drop-buffer l target) key (list target)))
         (l (panes-set-mode l key (panes--buffer-mode target)))
         (l (peek--restore-held l old (plist-get s 'held)))
         (drawn (panes-apply! l)))
    (set-frame-local! 'peek (plist-put (plist-put (plist-put s 'buffer target) 'asleep asleep) 'held held))
    (peek--left! old (plist-get s 'asleep))
    (peek--arm! target)
    (or (panes-handle drawn key) #t)))

(define (peek--live? s)
  "#t while the window of peek S is in this frame's model and still
   shows the peeked buffer."
  (let ((l (panes-layout)))
    (and s l (equal? (plist-get s 'group) (panes--group-key))
         (panes-window l (plist-get s 'key))
         (equal? (panes-window-buffer l (plist-get s 'key)) (plist-get s 'buffer)))))

(define (listing-peek! owner target)
  "Peek TARGET, the row at point of the list OWNER. A row already on
   screen ends the peek and shows nothing new. #f when it cannot peek:
   TARGET is in another group, or the frame has no pane."
  (let ((s (peek-state)))
    (cond ((not (and (buffer-known? owner) (buffer-known? target) (not (equal? owner target)))) #f)
          ((and s (equal? target (plist-get s 'buffer)) (peek--live? s)) #t)
          ((peek--foreign? target) (peek-dismiss!) #f)
          ((window-showing target) (peek-dismiss!) #t)
          ((and s (equal? owner (plist-get s 'owner)) (peek--live? s)) (peek--swap! target))
          (else (peek-dismiss!) (peek--show! owner target)))))

(define (peek-dismiss! &optional to-owner)
  "The peek goes: its window, a pane it made, the wake it gave. With
   TO-OWNER the focus goes to the list, on the row it was on."
  (let ((s (peek-state)))
    (when s
      (set-frame-local! 'peek #f)
      (let ((l (panes-layout-of (plist-get s 'group))))
        (when (and l (panes-window l (plist-get s 'key)))
          (let* ((l (peek--without l s))
                 (owner (plist-get s 'owner))
                 (ok (and (buffer-known? owner) (panes-find l owner)))
                 (l (if ok (panes-set-window-point l ok owner (with-current-buffer owner (lambda () (point)))) l))
                 (l (if (and to-owner ok) (panes-set-focus l (panes-pane-of l ok)) l)))
            (if (equal? (plist-get s 'group) (panes--group-key))
                (panes-apply! l)
                (panes--layout-store! (plist-get s 'group) l)))))
      (peek--left! (plist-get s 'buffer) (plist-get s 'asleep)))))

(define (peek-keep! &optional go)
  "The peek stays as a normal window. With GO the focus goes there."
  (let ((s (peek-state)))
    (when s
      (set-frame-local! 'peek #f)
      (peek--disarm! (plist-get s 'buffer))
      (let* ((key (plist-get s 'key)) (l (panes-layout)))
        (when (and l (panes-window l key))
          (let ((l (panes--update-window l key (lambda (w) (panes--put w 'peek #f)))))
            (if go (panes-apply! (panes-focus-window l key)) (panes-layout-set! l))))))))

(define (peek-track!)
  "After each command: the peek goes when its list is gone or the focus
   is in a window that is neither the list nor the peek. A peek window
   that shows another buffer now is kept; one that is gone is over."
  (let ((s (peek-state)))
    (when s
      (let ((l (panes-layout)) (key (plist-get s 'key))
            (buf (window-buffer (active-window))) (owner (plist-get s 'owner)))
        (cond ((not (equal? (plist-get s 'group) (panes--group-key))) (peek-dismiss!))
              ((not (and l (panes-window l key)))
               (set-frame-local! 'peek #f)
               (peek--left! (plist-get s 'buffer) (plist-get s 'asleep)))
              ((not (equal? (panes-window-buffer l key) (plist-get s 'buffer))) (peek-keep!))
              ((not (buffer-known? owner)) (peek-dismiss!))
              ((member buf (list owner (plist-get s 'buffer))) #f)
              ((and (boundp 'mb-list-target) (equal? (mb-list-target) owner)) #f)
              (else (peek-dismiss!)))))))

(add-hook! 'post-command-hook 'peek-track!)

;; --- peek-mode -----------------------------------------------------------

(define (peek-step! dir)
  "Move the list's point DIR rows and peek the row it lands on."
  (let ((owner (peek-owner)))
    (when owner
      (with-current-buffer owner (lambda () (run-command (if (> dir 0) "list-next" "list-prev"))))
      (let ((row (list-current owner)))
        (when (and (string? row) (buffer-known? row))
          (listing-peek! owner row))))))

(register-minor-mode! "peek-mode" (lambda (buf) #t) (lambda (buf) #t))

(define-command "peek-quit" "Dismiss the peek and go back to its list"
  (lambda ()
    (let ((owner (peek-owner)))
      (when owner (buffer-set-local! owner 'listing-preview-dismissed-row (peek-buffer)))
      (peek-dismiss! #t))))
(define-command "peek-next" "Peek the next row of the list" (lambda () (peek-step! 1)))
(define-command "peek-previous" "Peek the previous row of the list" (lambda () (peek-step! -1)))
(define-command "peek-keep" "Keep the peek as a normal window" (lambda () (peek-keep! #t)))

(minor-mode-keys! "peek-mode"
  '(("q" "peek-quit") ("C-g" "peek-quit") ("n" "peek-next") ("p" "peek-previous") ("RET" "peek-keep")))

(public! 'listing-peek! "(listing-peek! OWNER TARGET) -> peek TARGET, the row of list OWNER, in a window of the panes model; #f when it cannot")
(public! 'peek-dismiss! "(peek-dismiss! [TO-OWNER]) -> end this frame's peek; TO-OWNER puts the focus back on the list")
(public! 'peek-keep! "(peek-keep! [GO]) -> this frame's peek stays as a normal window; GO focuses it")
(public! 'peek-owner "(peek-owner) -> the list of this frame's peek, or #f")
(catalog-meta! 'function "peek-owner" 'effects '(read))
(public! 'peek-buffer "(peek-buffer) -> the buffer this frame's peek shows, or #f")
(catalog-meta! 'function "peek-buffer" 'effects '(read))

(provide 'peek)
