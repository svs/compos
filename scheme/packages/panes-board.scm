;;; panes-board.scm --- the window model as a list: panes, their windows,
;;; their buffers. C-x w lists them; the verbs edit the model and the frame
;;; follows.

(require 'panes-mode)

(domain! 'windows)
(effects! '(write display))

(define *panes-board-buffer* "*panes*")

;; the model the board shows: the group's, else the frame read in
(define (panes-board-layout) (or (panes-layout) (panes-adopt)))

;; row ids: p:PANE, w:KEY, b:KEY:BUFFER
(define (panes-board-ids buf)
  (let ((l (panes-board-layout)))
    (apply append
      (map (lambda (p)
             (cons (string-append "p:" (plist-get p 'id))
                   (apply append
                     (map (lambda (k)
                            (cons (string-append "w:" k)
                                  (map (lambda (b) (string-append "b:" k ":" b)) (panes-window-buffers l k))))
                          (or (plist-get p 'windows) '())))))
           (panes-panes l)))))

(define (panes-board-kind id) (substring id 0 1))

(define (panes-board-key id)
  ;; the window key of a w: or b: row
  (let ((rest (substring id 2 (string-length id))))
    (if (equal? (panes-board-kind id) "b")
        (let loop ((i 0)) (if (or (>= i (string-length rest)) (equal? (substring rest i (+ i 1)) ":")) (substring rest 0 i) (loop (+ i 1))))
        rest)))

(define (panes-board-buffer-of id)
  (let* ((rest (substring id 2 (string-length id)))
         (key (panes-board-key id)))
    (substring rest (+ 1 (string-length key)) (string-length rest))))

(define (panes-board-pane-of id)
  (let ((l (panes-board-layout)))
    (if (equal? (panes-board-kind id) "p")
        (substring id 2 (string-length id))
        (panes-pane-of l (panes-board-key id)))))

(define (panes-board--pct share) (string-append (number->string (round (* 100 share))) "%"))

(define (panes-board--short mode)
  (let ((m (or mode "")))
    (if (string-suffix? "-mode" m) (substring m 0 (- (string-length m) 5)) m)))

(define (panes-board-cells buf id)
  (let* ((l (panes-board-layout))
         (kind (panes-board-kind id)))
    (cond ((equal? kind "p")
           (let* ((pid (substring id 2 (string-length id)))
                  (p (panes-pane l pid))
                  (i (panes--index-of pid (panes-pane-ids l)))
                  (share (list-ref (panes-shares l) i)))
             (list (list "■" "ok")
                   (list (string-append "pane " (number->string (+ i 1))) #f)
                   (list (panes-board--pct share) "faint")
                   (list (string-append (number->string (length (or (plist-get p 'windows) '()))) " windows") "dim"))))
          ((equal? kind "w")
           (let* ((k (panes-board-key id))
                  (h (panes-handle l k))
                  (on (member k (panes-top-windows l)))
                  (here (and h (equal? h (active-window)))))
             (list (list (cond (here "  ●") (on "  ■") (else "  □")) (if on "ok" "faint"))
                   (list (string-append "  " (or (and h (boundp 'window-name) (window-name h)) k)) #f)
                   (list (panes-board--short (panes-window-mode l k)) "dim")
                   (list (string-append (number->string (length (panes-window-buffers l k))) " buffers") "faint"))))
          (else
            (let* ((k (panes-board-key id))
                    (b (panes-board-buffer-of id))
                    (top (equal? b (panes-window-buffer l k))))
              (list (list (if top "    ·" "     ") "faint")
                    (list (string-append "    " (if (buffer-known? b) (buffer-modeline-name b) b)) (if top #f "faint"))
                    (list (panes-board--short (panes--buffer-mode b)) "dim")
                    (list (if (and (buffer-known? b) (buffer-modified? b)) "modified" "") "faint")))))))

(define (panes-board-narrow-cells buf id)
  (let ((cells (panes-board-cells buf id)))
    (list (nth 0 cells) (nth 1 cells) (nth 2 cells))))

(define (panes-board-refresh!) (list-refresh! *panes-board-buffer*))

;; edit the model with FN (layout id) -> layout, lay the frame out, redraw
(define (panes-board-edit! fn)
  (let ((id (list-current *panes-board-buffer*)))
    (if (not id)
        (message "no row here")
        (let* ((l (panes-board-layout))
               (next (fn l id)))
          (when (and next (not (equal? next l)))
            (let ((me (active-window)))
              (panes-apply! next)
              (when (window-exists? me) (select-window! me))))
          (panes-board-refresh!)))))

;;; --- the verbs -------------------------------------------------------------------

(define-command "panes-board-visit" "Show this window, or this buffer in its window, and go there"
  (lambda ()
    (let ((id (list-current *panes-board-buffer*)))
      (cond ((not id) (message "no row here"))
            (else
              (let* ((l (panes-board-layout))
                     (kind (panes-board-kind id))
                     (key (cond ((equal? kind "p")
                                 (let ((ks (plist-get (panes-pane l (substring id 2 (string-length id))) 'windows)))
                                   (and (pair? ks) (car ks))))
                                (else (panes-board-key id))))
                     (next (cond ((not key) l)
                                 ((equal? kind "b") (panes-show l key (panes-board-buffer-of id)))
                                 (else (panes-raise l key)))))
                (when key
                  (let* ((applied (panes-apply! next))
                         (h (panes-handle applied key)))
                    (when (and h (window-exists? h)) (select-window! h))))))))))

;; move the window on this row one pane over; at the edge a new pane while there is room
(define (panes-board-shift! dir)
  (panes-board-edit!
    (lambda (l id)
      (if (equal? (panes-board-kind id) "p")
          (let* ((pid (substring id 2 (string-length id)))
                 (i (panes--index-of pid (panes-pane-ids l))))
            (panes-move-pane l pid (+ i dir)))
          (let* ((key (panes-board-key id))
                 (from (panes-pane-of l key))
                 (ids (panes-pane-ids l))
                 (i (+ dir (panes--index-of from ids))))
            (cond ((and (>= i 0) (< i (length ids))) (panes-move-window l key (list-ref ids i)))
                  ((not (panes-under-capacity? l)) (message "no pane that way") l)
                  (else
                    (let ((added (panes-add-pane l (if (< i 0) 0 (length ids)))))
                      (panes-move-window (car added) key (cadr added))))))))))

(define-command "panes-board-left" "Move this window to the pane on its left; a pane row moves the pane"
  (lambda () (panes-board-shift! -1)))
(define-command "panes-board-right" "Move this window to the pane on its right; a pane row moves the pane"
  (lambda () (panes-board-shift! 1)))

(define-command "panes-board-close"
  "Close this window (its buffers stay open), take this buffer out of its window, or remove this pane"
  (lambda ()
    (panes-board-edit!
      (lambda (l id)
        (let ((kind (panes-board-kind id)))
          (cond ((equal? kind "p") (panes-remove-pane l (substring id 2 (string-length id))))
                ((equal? kind "w") (panes-close-window l (panes-board-key id)))
                (else
                  (let* ((key (panes-board-key id)) (b (panes-board-buffer-of id))
                         (left (panes--without b (panes-window-buffers l key))))
                    (if (null? left) (panes-close-window l key) (panes-set-buffers l key left))))))))))

(define-command "panes-board-kill" "Kill the buffer on this row"
  (lambda ()
    (let ((id (list-current *panes-board-buffer*)))
      (if (and id (equal? (panes-board-kind id) "b"))
          (kill-buffer-confirm! (panes-board-buffer-of id) (lambda (done) (panes-board-refresh!)))
          (message "K on a buffer row kills it")))))

(define-command "panes-board-consolidate" "Give every mode one window"
  (lambda ()
    (panes-board-edit! (lambda (l id) (panes-consolidate l panes--buffer-mode)))))

(define (panes-board-resize! factor)
  (panes-board-edit!
    (lambda (l id)
      (let* ((pid (panes-board-pane-of id))
             (p (and pid (panes-pane l pid)))
             (share (and p (let ((s (plist-get p 'share))) (if (and (number? s) (> s 0)) s 1)))))
        (if p (panes-set-share l pid (* share factor)) l)))))

(define-command "panes-board-wider" "Give this pane more of the width" (lambda () (panes-board-resize! 1.25)))
(define-command "panes-board-narrower" "Give this pane less of the width" (lambda () (panes-board-resize! 0.8)))
(define-command "panes-board-equalize" "Every pane an equal share"
  (lambda () (panes-board-edit! (lambda (l id) (panes-equalize l)))))
(define-command "panes-board-refresh" "Redraw the board" (lambda () (panes-board-refresh!)))

(define-list-mode! "panes-list-mode"
  (list
    'doc (string-append
           "The windows of this frame as the model holds them: a pane, its windows (■ on screen, ● the one you are in, □ behind), "
           "and each window's buffers (· the one it shows). `RET` goes there, `<left>`/`<right>` move a window or a pane, `k` closes a window "
           "or takes a buffer out of one, `K` kills a buffer, `c` gives every mode one window, `+`/`-` resize a pane, `=` equalizes.")
    'buffer *panes-board-buffer*
    'rows panes-board-ids
    'layouts (list (list 'name 'wide 'min-cols 70
                         'columns (lambda (buf) (list (list "" 5) (list "what" 34) (list "mode" 16) (list "" #f)))
                         'cells panes-board-cells)
                   (list 'name 'narrow 'default #t
                         'columns (lambda (buf) (list (list "" 5) (list "what" #f) (list "mode" 14)))
                         'cells panes-board-narrow-cells))
    'cells panes-board-cells
    'title (lambda (buf) "Panes")
    'meta (lambda (buf) (let ((l (panes-board-layout)))
                          (string-append (number->string (panes-pane-count l)) " panes, "
                                         (number->string (length (panes-window-keys l))) " windows")))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "go") ("<left>/<right>" "move") ("k" "close") ("K" "kill") ("c" "consolidate")
                ("+/-" "resize") ("=" "equalize") ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "panes-board-visit") ("<left>" "panes-board-left") ("<right>" "panes-board-right")
            ("k" "panes-board-close") ("K" "panes-board-kill") ("c" "panes-board-consolidate")
            ("+" "panes-board-wider") ("-" "panes-board-narrower") ("=" "panes-board-equalize")
            ("g" "panes-board-refresh") ("q" "quit-window"))))

(define-command "list-panes" "List the panes of this frame, their windows and their buffers"
  (lambda ()
    (let ((buf *panes-board-buffer*))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "panes-list-mode")))
      (pop-to-buffer buf)
      (list-refresh! buf))))

;; the board follows the frame while it is on screen
(define (panes-board-follow!)
  (when (and (buffer-known? *panes-board-buffer*) (window-showing *panes-board-buffer*))
    (panes-board-refresh!)))
(add-hook! 'window-state-change-hook 'panes-board-follow!)
