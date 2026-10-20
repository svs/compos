;;; overview.scm --- The all-windows view of a frame's panes.
;;;; s-S-<down> puts every window of the frame on screen at once, the ones
;;;; behind the panes included, each with its own stack. Every window and
;;;; buffer command works as usual there. s-S-<up>, or s-S-<down> again,
;;;; lays the panes out again with the window you are in at the front of
;;;; its pane. The panes themselves belong to groups.scm.

(require 'groups)

(domain! 'windows)
(effects! '(write display))

(defcustom 'windows-overview-expose #f
  "Show the all-windows view as Exposé does: every window live and scaled into a grid over a dimmed desk, at the size it has in its pane. Off, the windows tile the frame."
  'group 'windows 'type 'boolean)

(define (windows-overview-active?)
  (equal? (frame-local 'windows-overview) #t))

(define (windows-overview--rows ids cols)
  ;; IDS cut into rows of COLS each
  (if (<= (length ids) cols)
      (list ids)
      (cons (list-head ids cols) (windows-overview--rows (list-tail ids cols) cols))))

(define (windows-overview--order)
  ;; (SHOWN REST): the windows on screen, left to right, and every other
  ;; window of the panes, the most recently seen first
  (let* ((rows (group-panes-windows))
         (tracked (if (pair? rows)
                      (apply append (map (lambda (row) (filter group-panes-live? (cdr row))) rows))
                      (filter group-panes-live? (jump-to-mode-windows))))
         ;; a window of this group that no pane recorded still gets a tile, one per buffer
         (all (let loop ((ws (map car (append (window-list) (window-hidden-list)))) (acc (reverse tracked)))
                (cond ((null? ws) (reverse acc))
                      ((member (car ws) acc) (loop (cdr ws) acc))
                      (else
                        (let ((buf (window-buffer-any (car ws))))
                          (if (and buf
                                   (equal? (buffer-group buf) (frame-group))
                                   (not (find (lambda (w) (equal? (window-buffer-any w) buf)) acc)))
                              (loop (cdr ws) (cons (car ws) acc))
                              (loop (cdr ws) acc)))))))
         (shown (filter (lambda (w) (member w all)) (map car (window-list))))
         (rest (filter (lambda (w) (not (member w shown))) all))
         (seen (lambda (w) (let ((b (window-buffer-any w))) (or (and b (buffer-last-seen b)) 0)))))
    (list shown (map cadr (sort (map (lambda (w) (list (- 0 (seen w)) w)) rest))))))

(define (windows-overview--bindings)
  (list (list "<left>" "windows-overview-left")
        (list "<right>" "windows-overview-right")
        (list "<up>" "windows-overview-up")
        (list "<down>" "windows-overview-down")
        (list "k" "windows-overview-kill")
        (list "c" "windows-overview-consolidate")
        (list "RET" "windows-overview-exit")
        (list "q" "windows-overview-exit")
        (list "ESC" "windows-overview-exit")
        (list "C-g" "windows-overview-exit")
        (list "s-S-<up>" "windows-overview-exit")
        (list "s-S-<down>" "windows-overview-exit")))

;; The view's keys are a map of its own. transient-map is one map for every
;; frame: a menu, or the layouts overview, opened anywhere rewrote the keys
;; this frame was locked to, and no key led out of the view again.
(define-keymap! "windows-overview-map")
(for-each (lambda (row) (define-key "windows-overview-map" (car row) (cadr row)))
          (windows-overview--bindings))

(define (windows-overview-on?)
  ;; the view, or what is left of one: its flag, or this frame's keys still
  ;; locked to its map
  (or (windows-overview-active?)
      (let ((over (cadr (key-context))))
        (and (pair? over) (equal? (car over) "windows-overview-map")))))

(define (windows-overview--split-off! win ratio)
  ;; split WIN side by side, WIN keeping RATIO; the new window
  (let ((before (map car (window-list))))
    (select-window! win)
    (split-window! 'h ratio)
    (let loop ((ws (window-list)))
      (cond ((null? ws) #f)
            ((member (car (car ws)) before) (loop (cdr ws)))
            (else (car (car ws)))))))

(define (windows-overview--row! ids)
  ;; lay IDS side by side in the space of the first, each an equal share
  (let loop ((win (car ids)) (rest (cdr ids)))
    (when (pair? rest)
      (let ((new (windows-overview--split-off! win (* 1.0 (/ 1 (+ 1 (length rest)))))))
        (when new
          (window-swap-hidden! new (car rest))
          (window-hidden-delete! new)
          (loop (car rest) (cdr rest)))))))

(define (windows-overview--lay! rows)
  (with-layout-suppressed
    (lambda ()
      (if windows-overview-expose
          ;; every tile on screen in one line, one call: the client places
          ;; them in the grid of ROWS at the size each has in its pane, so
          ;; the tree under them does not matter and no window rewraps
          (let ((ids (apply append rows)))
            (window-arrange-line! 'h (map (lambda (w) (/ 1 (length ids))) ids) ids))
          ;; ROWS of window ids, one line each, stacked in equal shares
          (begin
            (window-arrange-line! 'v (map (lambda (r) (/ 1 (length rows))) rows) (map car rows))
            (for-each windows-overview--row! rows))))))

(define (windows-overview--cols n)
  ;; tiles to a row: about 1.6 across for each one down, as a wide screen holds them
  (max 1 (min n (ceiling (sqrt (* n 1.6))))))

(define (windows-overview--nearest c len len2)
  ;; rows are centred: the index in a row of LEN2 nearest tile C of a row of LEN
  (max 0 (min (- len2 1) (floor (+ (- c (/ (- len 1) 2)) (/ (- len2 1) 2) 0.5)))))

(define (windows-overview--move! dir)
  ;; the arrows walk the grid the eye sees, the rows the view laid, not the
  ;; window tree under it
  (let* ((rows (or (frame-local 'windows-overview-rows) '()))
         (me (active-window))
         (r (let loop ((rs rows) (i 0))
              (cond ((null? rs) #f) ((member me (car rs)) i) (else (loop (cdr rs) (+ i 1))))))
         (row (and r (list-ref rows r)))
         (c (and row (- (length row) (length (member me row)))))
         (target
           (and r
                (cond ((equal? dir 'left) (and (> c 0) (list-ref row (- c 1))))
                      ((equal? dir 'right) (and (< (+ c 1) (length row)) (list-ref row (+ c 1))))
                      (else
                        (let ((r2 (if (equal? dir 'up) (- r 1) (+ r 1))))
                          (and (>= r2 0) (< r2 (length rows))
                               (let ((next (list-ref rows r2)))
                                 (list-ref next (windows-overview--nearest c (length row) (length next)))))))))))
    (if target
        (select-window! target)
        (message (string-append "No tile " (symbol->string dir))))))

(define (windows-overview--step! dir)
  ;; Exposé tiles sit in the grid of rows; tiled panes are where the tree says
  (if windows-overview-expose (windows-overview--move! dir) (focus-move! dir)))

(define (windows-overview--spread)
  ;; the client's token: the windows behind each pane, and for Exposé the rows
  (if windows-overview-expose
      (list 'spread (windows-overview--homes) 'rows (frame-local 'windows-overview-rows))
      (list 'spread (windows-overview--homes))))

(define (windows-overview-kill!)
  ;; kill the selected tile's buffer, drop its window, and close the gap
  (let* ((win (active-window))
         (buf (window-buffer win))
         (rows (or (frame-local 'windows-overview-rows) '()))
         (flat (apply append rows))
         (after (member win flat))
         (next (cond ((and after (pair? (cdr after))) (cadr after))
                     ((> (length flat) 1) (car (reverse (filter (lambda (w) (not (equal? w win))) flat))))
                     (else #f))))
    (cond ((not buf) #f)
          ((and (buffer-modified? buf) (not (equal? (frame-local 'windows-overview-armed) win)))
           (set-frame-local! 'windows-overview-armed win)
           (message (string-append buf " has unsaved changes; k again kills it")) #f)
          (else
            (set-frame-local! 'windows-overview-armed #f)
            (let ((row (group-panes-row-of win)))
              ;; a pane that loses its front shows its next window instead
              (when row
                (let ((rest (filter (lambda (w) (and (not (equal? w win)) (group-panes-live? w)))
                                    (cdr (assoc (car row) (group-panes-windows))))))
                  (when (pair? rest) (group-panes-record! (car row) (car rest) #t)))))
            (buffer-kill! buf)
            (when next
              ;; the rest regrid, as many to a row as before
              (let* ((left (windows-overview--rows (filter (lambda (w) (not (equal? w win))) flat)
                                                   (max 1 (length (car rows))))))
                (set-frame-local! 'windows-overview-rows left)
                (windows-overview--lay! left)
                (when windows-overview-expose (client-slide! (json-encode (windows-overview--spread))))
                (when (assoc win (window-hidden-list)) (window-hidden-delete! win))
                (when (assoc next (window-list)) (select-window! next))
                (editing-state-off! (window-buffer next))))
            (window-state-changed!)
            (message (string-append "Killed " buf))
            buf))))

(define (windows-overview-enter!)
  (let ((spec (group-panes-of (frame-group))))
    (cond ((not spec)
           (message "This frame has no panes to spread") #f)
          (else
            (when (null? (group-panes-windows)) (group-panes-apply!))
            (let* ((me (active-window))
                   (home (group-panes-row-of me))
                   (order (windows-overview--order))
                   (ids (append (car order) (cadr order)))
                   (done #f))
              (cond ((null? ids) (message "No windows in this frame") #f)
                    (else
                      ;; a spread that fails half way goes back to the panes
                      (unwind-protect
                        (lambda ()
                          (layout-target-free!)
                          (let ((rows (windows-overview--rows ids (if windows-overview-expose
                                                                       (windows-overview--cols (length ids))
                                                                       (max 1 (length (car order)))))))
                            (set-frame-local! 'windows-overview-rows rows)
                            ;; the pane the user came from takes the window they choose
                            (set-frame-local! 'windows-overview-home (and home (car home)))
                            (windows-overview--lay! rows))
                          (client-slide! (json-encode (windows-overview--spread)))
                          (set-frame-local! 'windows-overview #t)
                          ;; a tile is a glance: every window is in focus, none editing
                          (for-each (lambda (w) (let ((b (window-buffer-any w))) (when b (editing-state-off! b)))) ids)
                          (overriding-map! "windows-overview-map" #t)
                          (transient-show! #t)
                          (set! done #t))
                        (lambda () (unless done (windows-overview-exit!))))
                      (when (assoc me (window-list)) (select-window! me))
                      (window-state-changed!)
                      (message (string-append (number->string (length ids)) " windows; s-S-<up> goes back to the panes"))
                      ids)))))))

(define (windows-overview--homes)
  ;; ((WIN FRONT) ...): each window behind a pane, with the window at that pane's front
  (apply append
         (map (lambda (row)
                (if (and (pair? (cdr row)) (pair? (cddr row)))
                    (map (lambda (w) (list w (cadr row))) (cddr row))
                    '()))
              (group-panes-windows))))

(define (windows-overview-exit!)
  ;; the keys and the client leave the view first: a pane restore that
  ;; raises must not leave the frame locked in it
  (set-frame-local! 'windows-overview #f)
  (set-frame-local! 'windows-overview-armed #f)
  (set-frame-local! 'windows-overview-rows #f)
  (transient-show! #f)
  (overriding-map! #f)
  (client-slide! (json-encode (list 'gather (windows-overview--homes))))
  (let* ((me (active-window))
         (row (group-panes-row-of me))
         (pane (or (frame-local 'windows-overview-home) (and row (car row)))))
    (set-frame-local! 'windows-overview-home #f)
    (when pane
      ;; the chosen window leaves its own pane for the one the user came from
      (group-panes-set-rows!
        (map (lambda (r) (if (equal? (car r) pane) r (cons (car r) (filter (lambda (w) (not (equal? w me))) (cdr r)))))
             (group-panes-windows)))
      (group-panes-record! pane me #t))
    (let ((ids (group-panes-arrange!)))
      (when (and ids (member me ids)) (select-window! me))
      ids)))

(define-command "windows-overview"
  "Show every window of this frame at once; again, or windows-overview-exit, goes back to the panes"
  (lambda ()
    (if (windows-overview-on?) (windows-overview-exit!) (windows-overview-enter!))))

(define-command "windows-overview-exit"
  "Back from the all-windows view to the panes, the window you are in at the front of its pane"
  (lambda ()
    (if (windows-overview-on?)
        (windows-overview-exit!)
        (begin
          ;; the client may still show the view a failed exit left it in
          (client-slide! (json-encode (list 'gather '())))
          (message "Not in the all-windows view")))))

(define-command "windows-overview-kill" "Kill the buffer of the selected tile in the all-windows view"
  (lambda ()
    (if (windows-overview-active?)
        (windows-overview-kill!)
        (message "Not in the all-windows view"))))
(define (windows-overview--merge-modes!)
  ;; one window for each major mode of the frame, the hidden ones included:
  ;; the first tile of a mode keeps all its buffers in its stack, and the
  ;; other windows of that mode close. consolidate! only lays a group's
  ;; panes again, and left every window behind them standing.
  (let loop ((ids (let ((order (windows-overview--order))) (append (car order) (cadr order))))
             (done '())
             (count 0))
    (if (null? ids)
        count
        (let* ((win (car ids))
               (buf (window-buffer-any win))
               (mode (and buf (mode-consolidate-mode-of buf))))
          (if (and mode (not (member mode done)))
              (loop (cdr ids) (cons mode done) (+ count (mode-consolidate-into! win mode)))
              (loop (cdr ids) done count))))))

(define-command "windows-overview-consolidate"
  "Give every major mode of the group one window, then spread the windows again"
  (lambda ()
    (if (windows-overview-active?)
        (let* ((me (window-buffer (active-window)))
               (rows (or (frame-local 'windows-overview-rows) '()))
               (front (if (pair? rows) (map window-buffer-any (car rows)) '()))
               (done #f))
          (set-frame-local! 'windows-overview #f)
          ;; a merge that fails half way leaves the panes, not a locked view
          (unwind-protect
            (lambda ()
              (windows-overview--merge-modes!)
              ;; what was on top of each pane stays on top: a buffer the merge
              ;; folded into a window's history comes back to its front
              (for-each
                (lambda (buf)
                  (let* ((ws (apply append (map cdr (group-panes-windows))))
                         (win (or (find (lambda (w) (equal? (window-buffer-any w) buf)) ws)
                                  (find (lambda (w) (member buf (window-prev-buffers w))) ws)))
                         (row (and win (group-panes-row-of win))))
                    (when (and win row)
                      (unless (equal? (window-buffer-any win) buf) (window-set-buffer! win buf))
                      (group-panes-record! (car row) win #t))))
                (filter (lambda (b) b) front))
              (group-panes-arrange!)
              (windows-overview-enter!)
              (set! done #t))
            (lambda () (unless done (windows-overview-exit!))))
          (let ((w (window-showing me))) (when w (select-window! w))))
        (message "Not in the all-windows view"))))
(define-command "windows-overview-left" "Select the tile to the left in the all-windows view"
  (lambda () (windows-overview--step! 'left)))
(define-command "windows-overview-right" "Select the tile to the right in the all-windows view"
  (lambda () (windows-overview--step! 'right)))
(define-command "windows-overview-up" "Select the tile above in the all-windows view"
  (lambda () (windows-overview--step! 'up)))
(define-command "windows-overview-down" "Select the tile below in the all-windows view"
  (lambda () (windows-overview--step! 'down)))

(global-set-key "s-S-<down>" "windows-overview")
(global-set-key "s-S-<up>" "windows-overview-exit")
(public! 'windows-overview-active? "(windows-overview-active?) — #t while this frame shows every window at once")
(catalog-meta! 'function "windows-overview-active?" 'effects '(read))
