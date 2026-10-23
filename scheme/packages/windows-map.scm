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

(define (windows-map--keys l pid) (or (plist-get (panes-pane l pid) 'windows) '()))

;; the selection: (PANE . WINDOW-KEY), the key #f on an empty pane. A pane
;; or window an edit removed falls back to the nearest one left.
(define (windows-map--sel l)
  (let* ((sel (windows-map--get 'windows-map-sel))
         (ids (panes-pane-ids l))
         (key (and sel (cdr sel)))
         (pid (cond ((and key (panes-window l key)) (panes-pane-of l key))
                    ((and sel (member (car sel) ids)) (car sel))
                    ((pair? ids) (car ids))
                    (else #f)))
         (keys (if pid (windows-map--keys l pid) '())))
    (cons pid (cond ((and key (member key keys)) key) ((pair? keys) (car keys)) (else #f)))))

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
         (title (string-append " " pid " · " (number->string (round (* 100 share))) "% "))
         (top (string-append (if on "┏" "┌") hz (windows-map--fit title (- w 3)) ""))
         (top (string-append (substring top 0 (- (string-length top) 0)) (if on "┓" "┐")))
         (keys (windows-map--keys l pid))
         (body (if (null? keys)
                   (list (windows-map--fit "(empty)" (- w 4)))
                   (apply append (map (lambda (k) (windows-map--cell l k (cdr sel) (- w 4))) keys))))
         (rows (let loop ((i 0) (acc '()))
                 (if (= i (- h 2))
                     (reverse acc)
                     (loop (+ i 1) (cons (string-append vt " " (if (< i (length body)) (list-ref body i) (string-repeat " " (- w 4))) " " vt) acc))))))
    (append (list (string-append (if on "┏" "┌") (string-repeat hz (- w 2)) (if on "┓" "┐"))
                  (string-append vt " " (windows-map--fit title (- w 4)) " " vt))
            rows
            (list (string-append (if on "┗" "└") (string-repeat hz (- w 2)) (if on "┛" "┘"))))))
