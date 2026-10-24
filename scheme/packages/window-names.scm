;;; window-names.scm --- windows are things with names.
;;;
;;; A window is a stack of one mode's buffers; it sits on screen in a pane
;;; or waits behind one. It has a name: the one you gave it with
;;; window-rename, else its mode with -mode taken off, numbered when another
;;; window of the frame has the same one.
;;;
;;;   C-x j   switch-window: pick a window of this frame by name and go to it
;;;   M-x window-rename   name this window; an empty name goes back to the default

(domain! 'windows)
(effects! '(write display))

(define *window-names* '())   ;; ((ID NAME) ...)

;; a window still on screen or waiting behind a pane
(define (window-live? win)
  (and win (window-buffer-any win) #t))

(define (window-given-name win)
  (let ((hit (assoc win *window-names*)))
    (and hit (cadr hit))))

(define (window-name! win name)
  (set! *window-names*
        (cons (list win name)
              (filter (lambda (e) (and (not (equal? (car e) win)) (window-live? (car e))))
                      *window-names*)))
  name)

(define (window-name-clear! win)
  (set! *window-names* (filter (lambda (e) (not (equal? (car e) win))) *window-names*)))

;; the mode a window holds, without -mode; else what it shows
(define (window-name-default win)
  (let ((mode (and (boundp 'mode-consolidate-window-mode) (mode-consolidate-window-mode win)))
        (shown (window-buffer-any win)))
    (cond ((and mode (string-suffix? "-mode" mode)) (substring mode 0 (- (string-length mode) 5)))
          (mode mode)
          (shown (buffer-modeline-name shown))
          (else "window"))))

;; every window of this frame: the pane rows when the group has panes,
;; else the panes on screen and the ring behind them
(define (frame-windows)
  (if (boundp 'jump-to-mode-windows)
      (jump-to-mode-windows)
      (append (layout-pane-windows) (layout-hidden-windows))))

;; (WIN NAME) for every window of this frame: given names as they are,
;; default ones numbered when they repeat
(define *window-names-cache* #f)   ;; (KEY NAMES)

(define (window-names)
  ;; every row of a list asks for one name, so the names are worked out once
  ;; for each arrangement: the frame, its windows, what they show, the given names
  (let* ((wins (frame-windows))
         (key (list (selected-frame) *window-names* (map (lambda (w) (list w (window-buffer-any w))) wins))))
    (if (and *window-names-cache* (equal? (car *window-names-cache*) key))
        (cadr *window-names-cache*)
        (let ((names (window-names--work wins)))
          (set! *window-names-cache* (list key names))
          names))))

(define (window-names--work wins)
  (let loop ((wins wins) (seen '()) (acc '()))
    (if (null? wins)
        (reverse acc)
        (let* ((w (car wins))
               (given (window-given-name w))
               (base (or given (window-name-default w)))
               (n (length (filter (lambda (s) (equal? s base)) seen)))
               (name (if (or given (= n 0)) base (string-append base " " (number->string (+ n 1))))))
          (loop (cdr wins) (cons base seen) (cons (list w name) acc))))))

(define (window-name win)
  (let ((hit (assoc win (window-names))))
    (if hit (cadr hit) (window-name-default win))))

(define (window-named name)
  (let ((hit (find (lambda (e) (equal? (cadr e) name)) (window-names))))
    (and hit (car hit))))

;; where a window is: on screen, behind a pane, or waiting on the ring
(define (window-where win)
  (let* ((l (panes-layout))
         (k (and l (panes-key-of-handle l win))))
    (cond ((member win (layout-pane-windows)) "on screen")
          (k (string-append "behind " (panes-pane-of l k)))
          (else "waiting"))))

;; go to WIN: to the front of its pane, or along the ring
(define (window-go! win)
  (and (window-live? win) (panes-raise-window! win)))

(define-command "switch-window"
  "Pick a window of this frame by name and go to it"
  (lambda ()
    (let* ((me (active-window))
           (rows (filter (lambda (e) (not (equal? (car e) me))) (window-names))))
      (if (null? rows)
          (message "No other window in this frame")
          (minibuffer-read "Window: "
            (map (lambda (e)
                   (let ((b (window-buffer-any (car e))))
                     (list (cadr e)
                           (string-append (if b (buffer-modeline-name b) "") ", " (window-where (car e))))))
                 rows)
            (lambda (pick)
              (let* ((name (if (pair? pick) (car pick) pick))
                     (w (window-named name)))
                (or (and w (window-go! w))
                    (message (string-append "no window named " name))))))))))

;; ask for WIN's name; AFTER runs once it is set
(define (window-rename-prompt! win &optional after)
  (minibuffer-read* "Window name: " (list)
    (list (list 'initial (window-name win))
          (list 'style #f)
          (list 'confirm
                (lambda (v)
                  (let ((name (if (pair? v) (car v) v)))
                    (if (or (not (string? name)) (equal? name ""))
                        (begin (window-name-clear! win)
                               (message (string-append "Window is " (window-name win))))
                        (begin (window-name! win name)
                               (message (string-append "Window named " name))))
                    (window-state-changed!)
                    (when after (after))))))))

(define-command "window-rename"
  "Give this window a name; an empty name goes back to the default"
  (lambda () (window-rename-prompt! (active-window))))

(global-set-key "C-x j" "switch-window")

(public! 'window-name "(window-name WIN) — the window's name: given, else its mode, numbered when it repeats")
(public! 'window-name! "(window-name! WIN NAME) — give WIN a name")
(public! 'window-names "(window-names) — (WIN NAME) for every window of this frame")
(public! 'window-named "(window-named NAME) — the window of this frame called NAME, or #f")
(public! 'window-go! "(window-go! WIN) — go to WIN: to the front of its pane, or along the ring")
(catalog-meta! 'function "window-name" 'effects '(read))
(catalog-meta! 'function "window-names" 'effects '(read))
(catalog-meta! 'function "window-named" 'effects '(read))
