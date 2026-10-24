;;; windows-map.scm --- the frame's panes and windows as a canvas: one box a
;;; pane, as wide as its share, its windows inside top to bottom with their
;;; mode. The keys edit a copy of the window model; RET draws it once and
;;; goes to the selected window, q leaves the frame as it was.

(domain! 'windows)
(effects! '(write display))

(define *windows-map-buffer* "*windows*")

(define (windows-map--fit s w)
  (let ((n (string-length s)))
    (cond ((<= w 0) "")
          ((> n w) (string-append (substring s 0 (- w 1)) "…"))
          (else (string-append s (string-repeat " " (- w n)))))))

(define (windows-map--index x xs)
  (let loop ((xs xs) (i 0))
    (cond ((null? xs) #f) ((equal? (car xs) x) i) (else (loop (cdr xs) (+ i 1))))))

(define (windows-map--mode m)
  (if (and (string? m) (string-suffix? "-mode" m)) (substring m 0 (- (string-length m) 5)) (or m "")))

(define (windows-map--get k) (buffer-local *windows-map-buffer* k))
(define (windows-map--set! k v) (buffer-set-local! *windows-map-buffer* k v))

(define (windows-map--keys l pid) (panes-pane-keys l pid))

;; the selection: (PANE WINDOW-KEY), the key #f on an empty pane. A pane
;; or window an edit removed falls back to the nearest one left.
(define (windows-map--sel l)
  (let* ((sel (windows-map--get 'windows-map-sel))
         (ids (panes-pane-ids l))
         (key (and sel (cadr sel)))
         (pid (cond ((and key (panes-window l key)) (panes-pane-of l key))
                    ((and sel (member (car sel) ids)) (car sel))
                    ((pair? ids) (car ids))
                    (else #f)))
         (keys (if pid (windows-map--keys l pid) '())))
    (list pid (cond ((and key (member key keys)) key) ((pair? keys) (car keys)) (else #f)))))

;; one window: its name, then its mode and how many buffers it holds
(define (windows-map--cell l k sel w)
  (let* ((b (panes-window-buffer l k))
         (n (length (panes-window-buffers l k)))
         (mark (cond ((equal? k sel) "▶ ") ((member k (panes-top-windows l)) "■ ") (else "□ ")))
         (name (if (and b (buffer-known? b)) (buffer-modeline-name b) (or b "(empty)"))))
    (list (windows-map--fit (string-append mark name) w)
          (windows-map--fit (string-append "  " (windows-map--mode (panes-window-mode l k))
                                           (if (> n 1) (string-append " · " (number->string n) " buffers") ""))
                            w))))

;; one pane: a box W wide and H high, heavy when it holds the selection
(define (windows-map--box l pid sel w h)
  (let* ((on (equal? pid (car sel)))
         (hz (if on "━" "─")) (vt (if on "┃" "│"))
         (i (windows-map--index pid (panes-pane-ids l)))
         (share (list-ref (panes-shares l) i))
         (title (string-append pid " · " (number->string (round (* 100 share))) "% "))
         (keys (windows-map--keys l pid))
         (body (if (null? keys)
                   (list (windows-map--fit "(empty)" (- w 4)))
                   (apply append (map (lambda (k) (windows-map--cell l k (cadr sel) (- w 4))) keys))))
         (rows (let loop ((i 0) (acc '()))
                 (if (= i (- h 2))
                     (reverse acc)
                     (loop (+ i 1) (cons (string-append vt " " (if (< i (length body)) (list-ref body i) (string-repeat " " (- w 4))) " " vt) acc))))))
    (append (list (string-append (if on "┏" "┌") (string-repeat hz (- w 2)) (if on "┓" "┐"))
                  (string-append vt " " (windows-map--fit title (- w 4)) " " vt))
            rows
            (list (string-append (if on "┗" "└") (string-repeat hz (- w 2)) (if on "┛" "┘"))))))

(define (windows-map-render!)
  (let* ((l (windows-map--get 'windows-map-model))
         (sel (windows-map--sel l))
         (width (windows-map--get 'windows-map-width))
         (ids (panes-pane-ids l))
         (shares (panes-shares l))
         (total (apply + shares))
         (ws (map (lambda (s) (max 18 (- (floor (* width (/ s total))) 1))) shares))
         (h (+ 2 (apply max (map (lambda (p) (max 1 (* 2 (length (windows-map--keys l p))))) ids))))
         (boxes (let loop ((ps ids) (ws ws) (acc '()))
                  (if (null? ps) (reverse acc) (loop (cdr ps) (cdr ws) (cons (windows-map--box l (car ps) sel (car ws) h) acc)))))
         (lines (let loop ((i 0) (acc '()))
                  (if (> i h)
                      (reverse acc)
                      (loop (+ i 1) (cons (string-join (map (lambda (b) (list-ref b i)) boxes) " ") acc))))))
    (windows-map--set! 'windows-map-sel sel)
    (buffer-set-text! *windows-map-buffer*
      (string-append
        (if (windows-map--get 'windows-map-edited) "edited · RET draws it, q drops it" "RET goes there · q back")
        "\n\n" (string-join lines "\n") "\n\n"
        "arrows select   S-arrows move the window   M-<left>/<right> move the pane\n"
        "+ - = width   a add pane   x close window or empty pane   RET go   q back\n")
      #t)))

;; FN (layout sel) -> layout edits the copy; the frame changes on RET only
(define (windows-map--edit! fn)
  (let* ((l (windows-map--get 'windows-map-model))
         (next (fn l (windows-map--sel l))))
    (when (and next (not (equal? next l)))
      (windows-map--set! 'windows-map-model next)
      (windows-map--set! 'windows-map-edited #t))
    (windows-map-render!)))

(define (windows-map--select! dx dy)
  (let* ((l (windows-map--get 'windows-map-model))
         (sel (windows-map--sel l))
         (ids (panes-pane-ids l))
         (i (or (windows-map--index (car sel) ids) 0))
         (wi (or (windows-map--index (cadr sel) (windows-map--keys l (car sel))) 0))
         (pid (list-ref ids (max 0 (min (- (length ids) 1) (+ i dx)))))
         (keys (windows-map--keys l pid))
         (wj (max 0 (min (- (length keys) 1) (+ wi dy)))))
    (windows-map--set! 'windows-map-sel (list pid (and (pair? keys) (list-ref keys wj))))
    (windows-map-render!)))

;; the window over to the pane DIR away, at its top; past the edge a new pane
(define (windows-map--shift! dir)
  (windows-map--edit!
    (lambda (l sel)
      (let* ((key (cadr sel)) (ids (panes-pane-ids l))
             (i (+ dir (or (windows-map--index (car sel) ids) 0))))
        (cond ((not key) l)
              ((and (>= i 0) (< i (length ids))) (panes--prune-pane (panes-move-window l key (list-ref ids i) 0) (car sel)))
              ((not (panes-under-capacity? l)) (message "no pane that way") l)
              (else (let ((added (panes-add-pane l (if (< i 0) 0 (length ids)))))
                      (panes--prune-pane (panes-move-window (car added) key (cadr added) 0) (car sel)))))))))

(define (windows-map--reorder! dir)
  (windows-map--edit!
    (lambda (l sel)
      (let* ((key (cadr sel)) (keys (windows-map--keys l (car sel)))
             (j (and key (+ dir (windows-map--index key keys)))))
        (if (and j (>= j 0) (< j (length keys))) (panes-move-window l key (car sel) j) l)))))

(define (windows-map--move-pane! dir)
  (windows-map--edit!
    (lambda (l sel) (panes-move-pane l (car sel) (+ dir (windows-map--index (car sel) (panes-pane-ids l)))))))

(define (windows-map--resize! factor)
  (windows-map--edit!
    (lambda (l sel)
      (let* ((s (plist-get (panes-pane l (car sel)) 'share)) (s (if (and (number? s) (> s 0)) s 1)))
        (panes-set-share l (car sel) (* s factor))))))

(define (windows-map--close!)
  (windows-map--edit!
    (lambda (l sel)
      (cond ((cadr sel) (panes-remove-window l (cadr sel)))
            ((> (panes-pane-count l) 1) (panes-remove-pane l (car sel)))
            (else l)))))

(define (windows-map--add-pane!)
  (windows-map--edit! (lambda (l sel) (car (panes-add-empty-pane l (car sel))))))

(define (windows-map-open!)
  (let* ((shown (map car (window-list)))
         (model (windows-overview-model-as-shown (panes-board-layout) shown))
         (me (panes-key-of-handle model (active-window)))
         (width (max 60 (- (apply + (map window-cols shown)) 2))))
    (when (transient-frame-enter! 'windows-map)
      ;; held: the model does not follow the frame while the canvas covers it
      (set-frame-local! 'layout-held #t)
      (buffer-create *windows-map-buffer*)
      (with-current-buffer *windows-map-buffer* (lambda () (set-mode! "windows-map-mode")))
      (windows-map--set! 'windows-map-model model)
      (windows-map--set! 'windows-map-edited #f)
      (windows-map--set! 'windows-map-sel (list (and me (panes-pane-of model me)) me))
      (windows-map--set! 'windows-map-width width)
      (windows-map-render!)
      (switch-to-buffer-here! *windows-map-buffer*)
      (delete-other-windows!))))

;; the frame back as it was, then, with GO, the edited model drawn and the
;; selected window at the front of its pane
(define (windows-map-quit! &optional go)
  (let* ((l (and (buffer-known? *windows-map-buffer*) (windows-map--get 'windows-map-model)))
         (sel (and l (windows-map--sel l)))
         (edited (and l (windows-map--get 'windows-map-edited))))
    (transient-frame-exit! 'windows-map)
    (set-frame-local! 'layout-held #f)
    (when (buffer-known? *windows-map-buffer*) (buffer-kill! *windows-map-buffer*))
    (when (and go l)
      (let* ((key (cadr sel))
             (next (if key (panes-raise l key) l)))
        (when (or edited key)
          (let* ((applied (panes-apply! next))
                 (h (and key (panes-handle applied key))))
            (when (and h (window-exists? h)) (select-window! h))))))))

(define-command "windows-map" "The frame's panes and windows as a canvas to rearrange; again, or q, gives the frame back"
  (lambda () (if (transient-frame-standing? 'windows-map) (windows-map-quit!) (windows-map-open!))))
(define-command "windows-map-quit" "Give the frame back as it was, dropping the edits" (lambda () (windows-map-quit!)))
(define-command "windows-map-go" "Draw the edited layout and go to the selected window" (lambda () (windows-map-quit! #t)))
(define-command "windows-map-left" "Select the pane on the left" (lambda () (windows-map--select! -1 0)))
(define-command "windows-map-right" "Select the pane on the right" (lambda () (windows-map--select! 1 0)))
(define-command "windows-map-up" "Select the window above" (lambda () (windows-map--select! 0 -1)))
(define-command "windows-map-down" "Select the window below" (lambda () (windows-map--select! 0 1)))
(define-command "windows-map-shift-left" "Move the window to the pane on the left" (lambda () (windows-map--shift! -1)))
(define-command "windows-map-shift-right" "Move the window to the pane on the right" (lambda () (windows-map--shift! 1)))
(define-command "windows-map-shift-up" "Move the window up in its pane" (lambda () (windows-map--reorder! -1)))
(define-command "windows-map-shift-down" "Move the window down in its pane" (lambda () (windows-map--reorder! 1)))
(define-command "windows-map-pane-left" "Move the pane left" (lambda () (windows-map--move-pane! -1)))
(define-command "windows-map-pane-right" "Move the pane right" (lambda () (windows-map--move-pane! 1)))
(define-command "windows-map-wider" "Give the pane more of the width" (lambda () (windows-map--resize! 1.25)))
(define-command "windows-map-narrower" "Give the pane less of the width" (lambda () (windows-map--resize! 0.8)))
(define-command "windows-map-equalize" "Every pane an equal share" (lambda () (windows-map--edit! (lambda (l sel) (panes-equalize l)))))
(define-command "windows-map-close" "Close the window, its buffers stay open; on an empty pane, remove the pane" (lambda () (windows-map--close!)))
(define-command "windows-map-add-pane" "Add an empty pane after this one" (lambda () (windows-map--add-pane!)))

(define-mode "windows-map-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))

(mode-keys! "windows-map-mode"
  '(("<left>" "windows-map-left") ("<right>" "windows-map-right")
    ("<up>" "windows-map-up") ("<down>" "windows-map-down")
    ("S-<left>" "windows-map-shift-left") ("S-<right>" "windows-map-shift-right")
    ("S-<up>" "windows-map-shift-up") ("S-<down>" "windows-map-shift-down")
    ("M-<left>" "windows-map-pane-left") ("M-<right>" "windows-map-pane-right")
    ("+" "windows-map-wider") ("-" "windows-map-narrower") ("=" "windows-map-equalize")
    ("a" "windows-map-add-pane") ("x" "windows-map-close")
    ("RET" "windows-map-go") ("q" "windows-map-quit") ("s-S-<up>" "windows-map-quit")))

(global-set-key "s-S-<down>" "windows-map")
