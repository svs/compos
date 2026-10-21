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
  ;; window of the panes in the order of the hidden list, the most recently
  ;; hidden first. The tiles lay in this order and the exit hides them again
  ;; in tile order, so any other order here rewrites the ring on every visit
  (let* ((rows (group-panes-windows))
         (tracked (if (pair? rows)
                      (apply append (map (lambda (row) (filter group-panes-live? (cdr row))) rows))
                      (filter group-panes-live? (jump-to-mode-windows))))
         ;; a window of this group that no pane recorded still gets a tile: the
         ;; overview is of windows, so two windows on one buffer are two tiles
         (all (let loop ((ws (map car (append (window-list) (window-hidden-list)))) (acc (reverse tracked)))
                (cond ((null? ws) (reverse acc))
                      ((member (car ws) acc) (loop (cdr ws) acc))
                      (else
                        (let ((buf (window-buffer-any (car ws))))
                          (if (and buf (equal? (buffer-group buf) (frame-group)))
                              (loop (cdr ws) (cons (car ws) acc))
                              (loop (cdr ws) acc)))))))
         (shown (filter (lambda (w) (member w all)) (map car (window-list))))
         (rest (filter (lambda (w) (not (member w shown))) all))
         (hidden (map car (window-hidden-list))))
    (list shown
          (append (filter (lambda (w) (member w rest)) hidden)
                  (filter (lambda (w) (not (member w hidden))) rest)))))

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

;; Every other key works as it does outside the view, except a key that
;; acts on a buffer: the tiles are a glance. The view's map falls back to a
;; copy of the global map without those commands; the buffers' own maps
;; are never asked.
(define windows-overview--blocked
  '("self-insert-command" "newline" "preview-newline" "indent-for-tab" "yank" "yank-pop"
    "kill-line" "kill-word" "backward-kill-word" "kill-region" "copy-region-as-kill"
    "delete-char" "delete-backward-char" "undo" "set-mark-command" "exchange-point-and-mark"
    "pop-global-mark" "forward-char" "backward-char" "next-line" "previous-line"
    "forward-word" "backward-word" "beginning-of-line" "end-of-line" "beginning-of-buffer"
    "end-of-buffer" "back-to-indentation" "goto-line" "scroll-up-command" "scroll-down-command"
    "scroll-other-window" "scroll-other-window-down" "recenter-top-bottom" "forward-sexp"
    "backward-sexp" "down-list" "backward-up-list" "completion-at-point" "isearch-forward"
    "isearch-backward" "query-replace" "narrow-to-region" "narrow-context-also" "widen"
    "eval-last-sexp" "chat-send-region" "llm-pipe-region" "llm-send-buffer" "read-only-mode"
    "goto-thing-at-point" "lsp-pop-marker" "embark-act" "imenu"))

(define-command "windows-overview-blocked" "Nothing: in the all-windows view a key does not reach the windows"
  (lambda () #f))

(define (windows-overview--copy! from prefix)
  (for-each
    (lambda (b)
      (let ((keys (if prefix (string-append prefix " " (car b)) (car b)))
            (cmd (cadr b)))
        (cond ((not (string? cmd)) #f)
              ((string-prefix? "keymap:" cmd)
               (windows-overview--copy! (substring cmd 7 (string-length cmd)) keys))
              (else (define-key "windows-overview-global" keys
                                (if (member cmd windows-overview--blocked) "windows-overview-blocked" cmd))))))
    (keymap-bindings from)))

(define (windows-overview--keys-of from)
  ;; the bindings of FROM with its prefix maps inside: a copy is rebuilt only
  ;; when these change, as a rebuild costs a fifth of a second
  (map (lambda (b)
         (if (and (string? (cadr b)) (string-prefix? "keymap:" (cadr b)))
             (cons (car b) (windows-overview--keys-of (substring (cadr b) 7 (string-length (cadr b)))))
             b))
       (keymap-bindings from)))

(define windows-overview--copied #f)

(define (windows-overview--sync-keys!)
  ;; the global map as it is now: a key it lost since the last copy does nothing
  (let ((now (windows-overview--keys-of "global")))
    (unless (equal? now windows-overview--copied)
      (for-each (lambda (b) (define-key "windows-overview-global" (car b) "windows-overview-blocked"))
                (keymap-bindings "windows-overview-global"))
      (windows-overview--copy! "global" #f)
      (set! windows-overview--copied now))))

(define-keymap! "windows-overview-global")
(keymap-parent! "windows-overview-map" "windows-overview-global")
(windows-overview--sync-keys!)

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
  ;; the tiles are a look at the group, as the switcher's is: the frame's
  ;; group is not worked out again after every split
  (let ((look *group-look-active*))
    (set! *group-look-active* #t)
    (unwind-protect
      (lambda () (windows-overview--lay-tiles! rows))
      (lambda () (set! *group-look-active* look)))))

(define (windows-overview--lay-tiles! rows)
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
  ;; tiles to a row: about 1.6 across for each one down, as a wide screen
  ;; holds them, evened out so the last row is not a lone wide tile
  (if (< n 2)
      1
      (let* ((cols (max 1 (min n (ceiling (sqrt (* n 1.6))))))
             (rows (ceiling (/ n cols))))
        (ceiling (/ n rows)))))

(define (windows-overview--nearest c len len2)
  ;; rows are centred: the index in a row of LEN2 nearest tile C of a row of LEN
  (max 0 (min (- len2 1) (floor (+ (- c (/ (- len 1) 2)) (/ (- len2 1) 2) 0.5)))))

(define (windows-overview-step rows me dir)
  ;; pure: the tile DIR of ME in the grid ROWS, or #f at its edge. Left and
  ;; right run on across the rows: before the first tile of a row is the
  ;; last of the row above, after the last is the first of the row below.
  ;; Up and down keep the column, centred on a shorter row
  (let* ((r (let loop ((rs rows) (i 0))
              (cond ((null? rs) #f) ((member me (car rs)) i) (else (loop (cdr rs) (+ i 1))))))
         (row (and r (list-ref rows r)))
         (c (and row (- (length row) (length (member me row))))))
    (and r
         (cond ((equal? dir 'left)
                (if (> c 0) (list-ref row (- c 1)) (and (> r 0) (car (reverse (list-ref rows (- r 1)))))))
               ((equal? dir 'right)
                (if (< (+ c 1) (length row)) (list-ref row (+ c 1)) (and (< (+ r 1) (length rows)) (car (list-ref rows (+ r 1))))))
               (else
                 (let ((r2 (if (equal? dir 'up) (- r 1) (+ r 1))))
                   (and (>= r2 0) (< r2 (length rows))
                        (let ((next (list-ref rows r2)))
                          (list-ref next (windows-overview--nearest c (length row) (length next)))))))))))

(define (windows-overview-after-kill rows win)
  ;; pure: (ROWS NEXT) once WIN's tile is gone: the rest laid again in rows
  ;; as wide as the grid was, and the tile after it, else the last one
  (let* ((flat (apply append rows))
         (after (member win flat))
         (left (filter (lambda (w) (not (equal? w win))) flat))
         (next (cond ((and after (pair? (cdr after))) (cadr after)) ((pair? left) (car (reverse left))) (else #f))))
    (list (if (null? left) '() (windows-overview--rows left (max 1 (length (car rows))))) next)))

(define (windows-overview-model-kill model win buf)
  ;; pure: the model once BUF is killed from WIN's tile: no window lists BUF,
  ;; and a window left with no buffer closes
  (let loop ((ws (panes-windows model)) (l model))
    (if (null? ws)
        l
        (let* ((w (car ws)) (k (plist-get w 'key))
               (bufs (filter (lambda (b) (not (equal? b buf))) (or (plist-get w 'buffers) '()))))
          (loop (cdr ws)
                (cond ((equal? bufs (or (plist-get w 'buffers) '())) l)
                      ((null? bufs) (panes-close-window l k))
                      (else (panes-set-buffers l k bufs))))))))

(define (windows-overview-session model rows from keys buffer-of)
  ;; pure: the view walked by KEYS from FROM, as its commands walk it: left,
  ;; right, up, down, kill, and ret or quit to leave. BUFFER-OF names a
  ;; window's buffer. Answers (CHOSEN AFTER FAULTS ROWS KILLED); a step past
  ;; the edge stays put
  (let loop ((keys keys) (at from) (rows rows) (l model) (killed '()))
    (if (or (null? keys) (member (car keys) '(ret quit)))
        (let* ((buf (buffer-of at))
               (after (windows-overview-return-model l from at (if buf (list buf) '()) (and buf "fundamental-mode"))))
          (list at after (windows-overview-model-faults model after from at killed) rows killed))
        (let ((key (car keys)))
          (cond ((member key '(left right up down))
                 (loop (cdr keys) (or (windows-overview-step rows at key) at) rows l killed))
                ((equal? key 'kill)
                 (let* ((buf (buffer-of at)) (gone (windows-overview-after-kill rows at)))
                   (if (not (cadr gone))
                       (loop (cdr keys) at rows l killed)
                       (loop (cdr keys) (cadr gone) (car gone)
                             (windows-overview-model-kill l at buf) (cons (list at buf) killed)))))
                (else (loop (cdr keys) at rows l killed)))))))

(define (windows-overview--move! dir)
  ;; the arrows walk the grid the eye sees, the rows the view laid, not the
  ;; window tree under it
  (let ((target (windows-overview-step (or (frame-local 'windows-overview-rows) '()) (active-window) dir)))
    (if target
        (select-window! target)
        (message (string-append "No tile " (symbol->string dir))))))

(define (windows-overview--step! dir)
  ;; the tiles sit in the grid of rows in both views: the arrows walk it
  (windows-overview--move! dir))

(define (windows-overview--spread)
  ;; the client's token: the windows behind each pane, and for Exposé the rows
  (if windows-overview-expose
      (list 'spread (windows-overview--homes) 'rows (frame-local 'windows-overview-rows))
      (list 'spread (windows-overview--homes))))

(define (windows-overview-kill!)
  ;; kill the selected tile's window and every buffer in it, and close the gap
  (let* ((win (active-window))
         (buf (window-buffer win))
         (l (and (boundp 'panes-mode) panes-mode (panes-layout)))
         (k (and l (panes-key-of-handle l win)))
         ;; the window's whole stack: the model's when it holds the window, else the frame's
         (bufs (filter (lambda (b) (and (string? b) (buffer-known? b)))
                       (if k (panes-window-buffers l k) (cons buf (window-prev-buffers win)))))
         (dirty (filter buffer-modified? bufs))
         (rows (or (frame-local 'windows-overview-rows) '()))
         (flat (apply append rows))
         (after (member win flat))
         (next (cond ((and after (pair? (cdr after))) (cadr after))
                     ((> (length flat) 1) (car (reverse (filter (lambda (w) (not (equal? w win))) flat))))
                     (else #f))))
    (cond ((not buf) #f)
          ((and (pair? dirty) (not (equal? (frame-local 'windows-overview-armed) win)))
           (set-frame-local! 'windows-overview-armed win)
           (message (string-append (string-join dirty ", ") " has unsaved changes; k again kills the window")) #f)
          (else
            (set-frame-local! 'windows-overview-armed #f)
            (let ((row (group-panes-row-of win)))
              ;; a pane that loses its front shows its next window instead
              (when row
                (let ((rest (filter (lambda (w) (and (not (equal? w win)) (group-panes-live? w)))
                                    (cdr (assoc (car row) (group-panes-windows))))))
                  (when (pair? rest) (group-panes-record! (car row) (car rest) #t)))))
            (for-each buffer-kill! bufs)
            ;; the model the exit draws loses the buffers too
            (let ((m (frame-local 'windows-overview-model)))
              ;; the overview keeps no count of panes or windows: nothing refills
              (when m (set-frame-local! 'windows-overview-model
                        (plist-put (fold (lambda (m b) (windows-overview-model-kill m win b)) (plist-put m 'bare #t) bufs)
                                   'bare #f))))
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
            (message (if (= (length bufs) 1)
                         (string-append "Killed " buf)
                         (string-append "Killed the window of " buf " and its " (number->string (length bufs)) " buffers")))
            buf))))

(define (windows-overview-enter!)
  (let ((spec (group-panes-of (frame-group))))
    (cond ((not spec)
           (message "This frame has no panes to spread") #f)
          (else
            ;; rows that name no live window (a restore gave the frame new ids)
            ;; are rebuilt first, or the exit would have nothing to lay out
            (unless (find group-panes-live? (apply append (map cdr (group-panes-windows))))
              (group-panes-apply!))
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
                          ;; the frame the spread borrows: the exit gives it back when the panes cannot
                          (set-frame-local! (quote windows-overview-arrangement) (arrangement-push! (quote overview)))
                          (set-frame-local! 'layout-held #t)
                          (let ((rows (windows-overview--rows ids (windows-overview--cols (length ids)))))
                            (set-frame-local! 'windows-overview-rows rows)
                            ;; the pane the user came from takes the window they choose
                            (set-frame-local! 'windows-overview-home (and home (car home)))
                            (set-frame-local! 'windows-overview-from me)
                            ;; the window model as it was: the exit draws it back, as data
                            (set-frame-local! 'windows-overview-model
                              (and (boundp 'panes-layout) (panes-layout)
                                   (windows-overview-model-as-shown (panes-layout) (map car (window-list)))))
                            (windows-overview--lay! rows))
                          (client-slide! (json-encode (windows-overview--spread)))
                          (set-frame-local! 'windows-overview #t)
                          ;; a tile is a glance: every window is in focus, none editing
                          (for-each (lambda (w) (let ((b (window-buffer-any w))) (when b (editing-state-off! b)))) ids)
                          (windows-overview--sync-keys!)
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

(define (windows-overview-model-as-shown model shown)
  ;; pure: MODEL as the screen has it: the panes in the order SHOWN puts
  ;; their windows, and the window on screen at the front of its pane. The
  ;; view saves this, so leaving gives back what was on screen even when the
  ;; model had drifted from it
  (let* ((l (fold (lambda (l h) (let ((k (panes-key-of-handle l h))) (if k (panes-raise l k) l))) model shown))
         (order (panes--uniq (filter (lambda (p) p)
                                     (map (lambda (h) (let ((k (panes-key-of-handle l h))) (and k (panes-pane-of l k)))) shown))))
         (panes (panes-panes l))
         (first (filter (lambda (p) p) (map (lambda (id) (find (lambda (p) (equal? (plist-get p 'id) id)) panes)) order)))
         (rest (filter (lambda (p) (not (member (plist-get p 'id) order))) panes)))
    (panes--put l 'panes (append first rest))))

(define (windows-overview--swap-keys model a b)
  ;; pure: windows A and B trade places in the panes
  (let ((sw (lambda (k) (cond ((equal? k a) b) ((equal? k b) a) (else k)))))
    (panes--put model 'panes
                (map (lambda (p) (panes--put p 'windows (map sw (or (plist-get p 'windows) '()))))
                     (panes-panes model)))))

(define (windows-overview-return-model model from chosen bufs mode)
  ;; pure: the window model after the overview, from the window it opened
  ;; from and the one chosen. Nothing chosen, or a window on screen, gives
  ;; MODEL back as it was; a window behind takes FROM's place, and FROM
  ;; takes its place behind
  (let ((tops (filter (lambda (h) h) (map (lambda (k) (panes-handle model k)) (panes-top-windows model))))
        (kf (panes-key-of-handle model from))
        (kc (panes-key-of-handle model chosen)))
    (cond ((or (not chosen) (equal? chosen from) (member chosen tops) (not kf)) model)
          (kc (windows-overview--swap-keys model kf kc))
          (else
            (let* ((made (panes-new-window model (panes-pane-of model kf) (and (pair? bufs) (car bufs)) mode))
                   (l (panes-set-buffers (car made) (cadr made) bufs)))
              (panes-set-handle l (cadr made) chosen))))))

(define (windows-overview-model-faults before after from chosen &optional killed)
  ;; pure: what AFTER breaks of the rules a return keeps, as text; () is none.
  ;; BEFORE is the model the view saved, KILLED the (WIN BUF) the view killed.
  ;; One live window to one model window, each model window in one pane, no
  ;; killed buffer left, the panes and their shares as they were, and no pane
  ;; but FROM's changes
  (let* ((killed (or killed '()))
         (base (let loop ((ks (reverse killed)) (l before))
                 (if (null? ks) l (loop (cdr ks) (windows-overview-model-kill l (car (car ks)) (cadr (car ks)))))))
         (handles (filter (lambda (h) h) (map (lambda (w) (plist-get w 'win)) (panes-windows after))))
         (keys (map (lambda (w) (plist-get w 'key)) (panes-windows after)))
         (placed (apply append (map (lambda (p) (or (plist-get p 'windows) '())) (panes-panes after))))
         (shown (apply append (map (lambda (w) (or (plist-get w 'buffers) '())) (panes-windows after))))
         (count (lambda (x xs) (length (filter (lambda (y) (equal? x y)) xs))))
         (shape (lambda (m) (map (lambda (p) (list (plist-get p 'id) (plist-get p 'share))) (panes-panes m))))
         (front (lambda (m) (map (lambda (p) (let ((ks (or (plist-get p 'windows) '())))
                                               (list (plist-get p 'id) (and (pair? ks) (panes-handle m (car ks))))))
                                 (panes-panes m))))
         (kf (panes-key-of-handle base from))
         (home (and kf (panes-pane-of base kf)))
         (tops (map cadr (front base)))
         (moved (and chosen (not (equal? chosen from)) (not (member chosen tops)) kf)))
    (append
      (map (lambda (h) (format "window ~a is held by two model windows" h))
           (panes--uniq (filter (lambda (h) (> (count h handles) 1)) handles)))
      (map (lambda (k) (format "model window ~a is in ~a panes" k (count k placed)))
           (filter (lambda (k) (not (= (count k placed) 1))) keys))
      (map (lambda (k) (format "a pane names ~a, which no model window is" k))
           (filter (lambda (k) (not (member k keys))) placed))
      (map (lambda (b) (format "the killed ~a is still in a window" b))
           (filter (lambda (b) (member b shown)) (map cadr killed)))
      (if (equal? (shape base) (shape after)) '() (list "the panes or their shares changed"))
      (if moved
          (append
            (filter (lambda (x) x)
                    (map (lambda (b) (let ((a (assoc (car b) (front after))))
                                       (and (not (equal? (car b) home)) (not (equal? b a))
                                            (format "pane ~a shows ~a, was ~a" (car b) (and a (cadr a)) (cadr b)))))
                         (front base)))
            (let ((h (assoc home (front after))))
              (if (and h (equal? (cadr h) chosen)) '()
                  (list (format "pane ~a shows ~a, not the chosen ~a" home (and h (cadr h)) chosen)))))
          (if (equal? base after) '() (list "nothing was chosen, yet the model changed"))))))

(define (windows-overview--apply-return! quiet model from me)
  ;; the model the view saved, with the chosen window in FROM's place, is
  ;; drawn once; a model that breaks the rules is not drawn, the saved one is
  (let* ((borrowed (frame-local 'windows-overview-arrangement))
         (buf (window-buffer-any me))
         (after (windows-overview-return-model model from me
                                               (if buf (panes--window-stack me buf) '())
                                               (and buf (panes--buffer-mode buf))))
         (faults (windows-overview-model-faults model after from me))
         (drawn (if (null? faults) after model)))
    (for-each (lambda (k) (set-frame-local! k #f))
              '(windows-overview windows-overview-armed windows-overview-rows windows-overview-home
                windows-overview-arrangement windows-overview-from windows-overview-model))
    (transient-show! #f)
    (overriding-map! #f)
    (unless quiet (client-slide! (json-encode (list 'gather (windows-overview--homes)))))
    (when borrowed (arrangement-drop! borrowed))
    (panes-apply! drawn)
    (set-frame-local! 'layout-held #f)
    (let ((shown (map car (window-list))))
      (select-window! (cond ((member me shown) me) ((member from shown) from) (else (car shown))))
      (unless (null? faults)
        (message (string-append "Overview: kept the panes as they were; " (string-join faults "; "))))
      shown)))

(define (windows-overview-exit! &optional quiet)
  ;; leaving gives the frame back as it was, nothing moves; a tile chosen
  ;; elsewhere then takes the place of the window the view opened from, or
  ;; is gone to when it is on screen already
  (let ((from (frame-local 'windows-overview-from))
        (model (frame-local 'windows-overview-model))
        (me (active-window)))
    ;; a model that was broken before the view opened is not drawn: the
    ;; arrangement the view borrowed comes back instead
    (if (and from model (boundp 'panes-mode) panes-mode (null? (panes-model-faults model)))
        (windows-overview--apply-return! quiet model from me)
    (if (and from (frame-local 'windows-overview-arrangement))
        (let ((ids (windows-overview--return! quiet)))
          (cond ((equal? me from) ids)
                ((assoc me (window-list)) (select-window! me) ids)
                ((and (assoc from (window-list)) (assoc me (window-hidden-list)))
                 (window-swap-hidden! from me)
                 (select-window! me)
                 (window-state-changed!)
                 (map car (window-list)))
                (else ids)))
        (windows-overview--gather! quiet)))))

(define (windows-overview--return! quiet)
  (let ((borrowed (frame-local 'windows-overview-arrangement)))
    (for-each (lambda (k) (set-frame-local! k #f))
              '(windows-overview windows-overview-armed windows-overview-rows windows-overview-home
                windows-overview-arrangement windows-overview-from))
    (transient-show! #f)
    (overriding-map! #f)
    (unless quiet (client-slide! (json-encode (list 'gather (windows-overview--homes)))))
    (arrangement-pop! borrowed)
    (set-frame-local! 'layout-held #f)
    (window-state-changed!)
    (map car (window-list))))

(define (windows-overview--gather! quiet)
  (set-frame-local! 'windows-overview-from #f)
  ;; the keys and the client leave the view first: a pane restore that
  ;; raises must not leave the frame locked in it. QUIET leaves the client
  ;; in the view, for a command that runs on the panes and spreads again.
  (set-frame-local! 'windows-overview #f)
  (set-frame-local! 'windows-overview-armed #f)
  (set-frame-local! 'windows-overview-rows #f)
  (transient-show! #f)
  (overriding-map! #f)
  (unless quiet (client-slide! (json-encode (list 'gather (windows-overview--homes)))))
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
    (let ((ids (group-panes-arrange! #t))
          (borrowed (frame-local 'windows-overview-arrangement)))
      (set-frame-local! 'windows-overview-arrangement #f)
      ;; no pane row named a live window: the frame goes back to what the
      ;; spread borrowed rather than staying spread
      (if ids (arrangement-drop! borrowed) (arrangement-pop! borrowed))
      ;; the spread borrowed the frame; the chosen layout comes back
      (set-frame-local! 'layout-held #f)
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
          ;; and the frame may still hold what the spread borrowed: the
          ;; chosen layout comes back, the borrowed arrangement goes
          (let ((borrowed (frame-local 'windows-overview-arrangement)))
            (set-frame-local! 'windows-overview-arrangement #f)
            (when borrowed (arrangement-drop! borrowed))
            (set-frame-local! 'layout-held #f))
          (message "Not in the all-windows view")))))

;; a group switch takes the spread down first, so the group records its
;; panes and its chosen layout, not the spread's free frame
(advice-add! 'switch-to-group! 'before 'windows-overview
  (lambda (g) (when (windows-overview-on?) (windows-overview-exit! #t))))

(define-command "windows-overview-kill" "Kill the selected tile's window and every buffer in it, in the all-windows view"
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

;; Another command runs on the panes, not on the spread tiles: the view
;; gathers them quietly before it and spreads them again after it. A
;; command that asks first, M-x or a buffer prompt, shows the panes until
;; it has its answer.
(define windows-overview--passive
  '("universal-argument" "digit-argument" "negative-argument" "telemetry-toggle"))

(define (windows-overview--foreign? cmd)
  (and (string? cmd)
       (not (equal? cmd ""))
       (not (string-prefix? "windows-overview" cmd))
       (not (member cmd windows-overview--passive))))

(define (windows-overview--pre-command!)
  (when (and (windows-overview-active?) (windows-overview--foreign? (this-command)))
    (windows-overview-exit! #t)
    (set-frame-local! 'windows-overview-resume #t)))

(define (windows-overview--post-command!)
  (when (frame-local 'windows-overview-resume)
    (if (minibuffer-active?)
        (unless (frame-local 'windows-overview-asking)
          (set-frame-local! 'windows-overview-asking #t)
          (client-slide! (json-encode (list 'gather '()))))
        (begin
          (set-frame-local! 'windows-overview-resume #f)
          (set-frame-local! 'windows-overview-asking #f)
          (windows-overview-enter!)))))

(add-hook! 'pre-command-hook 'windows-overview--pre-command!)
(add-hook! 'post-command-hook 'windows-overview--post-command!)

(global-set-key "s-S-<down>" "windows-overview")
(global-set-key "s-S-<up>" "windows-overview-exit")
(public! 'windows-overview-active? "(windows-overview-active?) — #t while this frame shows every window at once")
(catalog-meta! 'function "windows-overview-active?" 'effects '(read))
