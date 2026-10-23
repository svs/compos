;;; windows-map.scm --- every pane and window of this frame as text, laid
;;; out as the frame has them: one column a pane, its windows top to bottom
;;; with their mode and size, the selected window previewed below. No live
;;; tiles, so it opens at once. s-S-<down> takes the frame for it; RET goes
;;; to the window, q gives the frame back as it was.

(domain! 'windows)
(effects! '(write display))

(define *windows-map-buffer* "*windows*")
(define windows-map--preview-lines 14)

(define (windows-map--fit s w)
  (let ((n (string-length s)))
    (cond ((<= w 0) "")
          ((> n w) (string-append (substring s 0 (- w 1)) "…"))
          (else (string-append s (string-repeat " " (- w n)))))))

(define (windows-map--index x xs)
  (let loop ((xs xs) (i 0))
    (cond ((null? xs) #f) ((equal? (car xs) x) i) (else (loop (cdr xs) (+ i 1))))))

(define (windows-map--size n)
  (cond ((< n 1024) (string-append (number->string n) " B"))
        ((< n 1048576) (string-append (number->string (round (/ n 1024))) " KB"))
        (else (string-append (number->string (round (/ n 1048576))) " MB"))))

(define (windows-map--mode m)
  (if (and (string? m) (string-suffix? "-mode" m)) (substring m 0 (- (string-length m) 5)) (or m "")))

;; (PANE WIN ...) rows of live windows, from the panes, else one column of
;; the shown windows
(define (windows-map--panes)
  (let ((rows (filter (lambda (r) (pair? (cdr r)))
                      (map (lambda (r) (cons (car r) (filter group-panes-live? (cdr r)))) (group-panes-windows)))))
    (if (pair? rows)
        rows
        (let loop ((ws (map car (window-list))) (i 1) (acc '()))
          (if (null? ws)
              (reverse acc)
              (loop (cdr ws) (+ i 1) (cons (list (string-append "p" (number->string i)) (car ws)) acc)))))))

;; the two lines a window gets in its column: its name, then mode and size
(define (windows-map--cell win shown sel w)
  (let* ((b (window-buffer-any win))
         (live (and b (buffer-known? b)))
         (mark (cond ((equal? win sel) "▶ ") ((member win shown) "■ ") (else "□ ")))
         (name (if live (buffer-modeline-name b) (or b "?")))
         (dirty (if (and live (buffer-modified? b)) " *" "")))
    (list (windows-map--fit (string-append mark name dirty) w)
          (windows-map--fit (string-append "  " (windows-map--mode (window-mode win))
                                           (if live (string-append " · " (windows-map--size (buffer-size b))) ""))
                            w))))

;; a few lines around the window's point, never the whole buffer
(define (windows-map--preview win w)
  (let ((b (window-buffer-any win)))
    (if (not (and b (buffer-known? b)))
        ""
        (let* ((size (buffer-size b))
               (pt (or (window-point win) (buffer-point b) 1))
               (text (with-current-buffer b
                       (lambda () (buffer-substring (max 1 (- pt 1200)) (min (+ size 1) (+ pt 1200))))))
               (lines (string-split text "\n"))
               (k windows-map--preview-lines)
               (lines (if (> (length lines) k)
                          (list-head (list-tail lines (max 0 (- (quotient (length lines) 2) (quotient k 2)))) k)
                          lines)))
          (apply string-append
                 (map (lambda (l) (string-append (string-trim-right (string-append "  " (windows-map--fit l (- w 2)))) "\n")) lines))))))

(define (windows-map-render! buf)
  (let* ((panes (buffer-local buf 'windows-map-panes))
         (shown (buffer-local buf 'windows-map-shown))
         (sel (buffer-local buf 'windows-map-sel))
         (width (buffer-local buf 'windows-map-width))
         (n (length panes))
         (w (max 12 (quotient (- width (* 3 (- n 1))) n)))
         (cols (map (lambda (row)
                      (let ((k (length (cdr row))))
                        (cons (windows-map--fit (string-append (car row) " · " (number->string k) (if (= k 1) " window" " windows")) w)
                              (apply append (map (lambda (win) (windows-map--cell win shown sel w)) (cdr row))))))
                    panes))
         (height (apply max (map length cols)))
         (blank (string-repeat " " w))
         (lines (let loop ((i 0) (acc '()))
                  (if (= i height)
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (string-trim-right (string-join (map (lambda (c) (if (< i (length c)) (list-ref c i) blank)) cols) " │ ")) acc)))))
         (count (apply + (map (lambda (r) (length (cdr r))) panes)))
         (b (window-buffer-any sel)))
    (buffer-set-text! buf
      (string-append
        (number->string n) (if (= n 1) " pane · " " panes · ") (number->string count) " windows    arrows move · RET go · q back\n\n"
        (string-join lines "\n") "\n\n"
        (string-repeat "─" width) "\n"
        (if b (string-append (if (buffer-known? b) (buffer-modeline-name b) b) "  " (or (window-mode sel) "") "\n\n") "")
        (windows-map--preview sel width))
      #t)))

(define (windows-map--move! dx dy)
  (let* ((buf *windows-map-buffer*)
         (panes (buffer-local buf 'windows-map-panes))
         (sel (buffer-local buf 'windows-map-sel))
         (pi (or (windows-map--index #t (map (lambda (r) (and (member sel (cdr r)) #t)) panes)) 0))
         (row (cdr (list-ref panes pi)))
         (wi (or (windows-map--index sel row) 0))
         (pj (max 0 (min (- (length panes) 1) (+ pi dx))))
         (row2 (cdr (list-ref panes pj)))
         (wj (max 0 (min (- (length row2) 1) (if (= dx 0) (+ wi dy) wi)))))
    (buffer-set-local! buf 'windows-map-sel (list-ref row2 wj))
    (windows-map-render! buf)))

(define (windows-map-quit!)
  (transient-frame-exit! 'windows-map)
  (when (buffer-known? *windows-map-buffer*) (buffer-kill! *windows-map-buffer*)))

(define (windows-map-open!)
  (let* ((buf *windows-map-buffer*)
         (me (active-window))
         (shown (map car (window-list)))
         (width (max 40 (- (apply + (map window-cols shown)) 2))))
    (when (transient-frame-enter! 'windows-map)
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "windows-map-mode")))
      (buffer-set-local! buf 'windows-map-panes (windows-map--panes))
      (buffer-set-local! buf 'windows-map-shown shown)
      (buffer-set-local! buf 'windows-map-sel me)
      (buffer-set-local! buf 'windows-map-width width)
      (windows-map-render! buf)
      (delete-other-windows!)
      (switch-to-buffer! buf))))

;; back to the frame, then to the chosen window: a hidden one comes to the
;; front of its own pane
(define (windows-map-go!)
  (let ((sel (buffer-local *windows-map-buffer* 'windows-map-sel)))
    (windows-map-quit!)
    (when sel
      (unless (assoc sel (window-list))
        (let* ((row (group-panes-row-of sel))
               (front (and row (find (lambda (w) (assoc w (window-list))) (cdr row)))))
          (when (and front (window-swap-hidden! front sel))
            (group-panes-record! (car row) sel #t)
            (window-state-changed!))))
      (when (assoc sel (window-list)) (select-window! sel)))))

(define-command "windows-map" "Every pane and window of this frame as a map; again, or q, gives the frame back"
  (lambda () (if (transient-frame-standing? 'windows-map) (windows-map-quit!) (windows-map-open!))))
(define-command "windows-map-quit" "Give the frame back as it was" (lambda () (windows-map-quit!)))
(define-command "windows-map-go" "Go to the selected window" (lambda () (windows-map-go!)))
(define-command "windows-map-left" "Select the pane on the left" (lambda () (windows-map--move! -1 0)))
(define-command "windows-map-right" "Select the pane on the right" (lambda () (windows-map--move! 1 0)))
(define-command "windows-map-up" "Select the window above" (lambda () (windows-map--move! 0 -1)))
(define-command "windows-map-down" "Select the window below" (lambda () (windows-map--move! 0 1)))

(define-mode "windows-map-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))

(mode-keys! "windows-map-mode"
  '(("<left>" "windows-map-left") ("<right>" "windows-map-right")
    ("<up>" "windows-map-up") ("<down>" "windows-map-down")
    ("h" "windows-map-left") ("l" "windows-map-right")
    ("k" "windows-map-up") ("j" "windows-map-down")
    ("RET" "windows-map-go") ("q" "windows-map-quit")
    ("s-S-<up>" "windows-map-quit")))

(global-set-key "s-S-<down>" "windows-map")
