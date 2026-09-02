;;; autolayout-test.scm --- one main pane, the rest beside it.
;;;
;;; The policy is tested by its functions: autolayout-apply! arranges,
;;; autolayout--on-change! is what the window hook runs. The rects say
;;; where a pane landed: (window-rects) rows are (ID BUF X Y W H) as
;;; fractions of the frame.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "re-arranges the frame's windows and sets the layout customs")

(define t--al-a "zz-al-a")
(define t--al-b "zz-al-b")
(define t--al-c "zz-al-c")
(define t--al-d "zz-al-d")

(define (t--al-setup!)
  (set! *autolayout-mode* #f)
  (customize-set! 'window-layout-main-side 'left)
  (customize-set! 'window-layout-main-ratio 0.62)
  (customize-set! 'window-layout-stack 'column)
  (for-each (lambda (b) (test-buffer! b "")) (list t--al-a t--al-b t--al-c t--al-d))
  (delete-other-windows!)
  (switch-to-buffer! t--al-a)
  (split-window! 'h 0.5)
  (other-window!)
  (switch-to-buffer! t--al-b))

(define (t--al-done!)
  (set! *autolayout-mode* #f)
  (delete-other-windows!)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list t--al-a t--al-b t--al-c t--al-d)))

(define (t--al-rect buf)
  (let loop ((rs (window-rects)))
    (cond ((null? rs) #f)
          ((equal? (nth 1 (car rs)) buf) (car rs))
          (else (loop (cdr rs))))))

(define (t--al-near? x y) (< (abs (- x y)) 0.02))

(deftest 'autolayout-makes-the-selected-buffer-the-main-pane-on-the-left
  "the selected window's buffer takes the main share on the left; the rest go right"
  (lambda ()
    (t--al-setup!)
    ;; b is selected: it becomes main
    (autolayout-apply! (window-buffer (active-window)))
    (let ((main (t--al-rect t--al-b)) (other (t--al-rect t--al-a)))
      (check-true! (and main #t) "the main pane shows the selected buffer")
      (check-true! (t--al-near? (nth 2 main) 0) "on the left")
      (check-true! (t--al-near? (nth 4 main) 0.62) "with the main share")
      (check-true! (and other (t--al-near? (nth 2 other) 0.62)) "the other pane sits beside it")
      (check-equal! (current-buffer) t--al-b "and keeps the selection"))
    (t--al-done!)))

(deftest 'autolayout-main-right-puts-the-main-pane-on-the-right
  "the side custom moves the main pane"
  (lambda ()
    (t--al-setup!)
    (customize-set! 'window-layout-main-side 'right)
    (customize-set! 'window-layout-main-ratio 0.7)
    (autolayout-apply! t--al-b)
    (let ((main (t--al-rect t--al-b)))
      (check-true! (and main (t--al-near? (nth 2 main) 0.3)) "the main pane starts after the stack")
      (check-true! (and main (t--al-near? (nth 4 main) 0.7)) "with the share the custom names"))
    (t--al-done!)))

(deftest 'autolayout-stacks-the-rest-as-a-column-or-as-tiles
  "three other buffers: a column shares the height in thirds; tiles make a grid"
  (lambda ()
    (t--al-setup!)
    (split-window! 'v 0.5)
    (other-window!)
    (switch-to-buffer! t--al-c)
    (split-window! 'v 0.5)
    (other-window!)
    (switch-to-buffer! t--al-d)
    (autolayout-apply! t--al-a)
    (check-equal! (length (window-list)) 4 "four panes")
    (let ((b (t--al-rect t--al-b)) (c (t--al-rect t--al-c)) (d (t--al-rect t--al-d)))
      (check-true! (and b c d (t--al-near? (nth 4 b) 0.38) (t--al-near? (nth 4 c) 0.38))
                   "a column: every other pane spans the stack's width")
      (check-true! (and b c d (t--al-near? (nth 5 b) (/ 1 3))) "in thirds"))
    (customize-set! 'window-layout-stack 'grid)
    (autolayout-apply! t--al-a)
    (check-equal! (length (window-list)) 4 "still four panes")
    (let ((rects (filter (lambda (r) (not (equal? (nth 1 r) t--al-a))) (window-rects))))
      (check-true! (pair? (filter (lambda (r) (< (nth 4 r) 0.3)) rects))
                   "tiles: one of the other panes is narrower than the stack"))
    (t--al-done!)))

(deftest 'autolayout-mode-re-arranges-when-a-window-comes
  "with the mode on, a new window joins the stack and the main pane stays main"
  (lambda ()
    (t--al-setup!)
    (autolayout-apply! t--al-a)
    (check-equal! (frame-local 'autolayout-main) t--al-a "a is main")
    ;; a new window with a new buffer, as C-x 2 then a switch would make.
    ;; The mode is off while the windows are made, so the hook that the
    ;; splits run does not re-arrange half way; then the hook runs once.
    (select-window! (window-showing t--al-a))
    (let ((before (map car (window-list))))
      (split-window! 'v 0.5)
      (select-window! (layout--new-window before))
      (switch-to-buffer! t--al-c))
    (set! *autolayout-mode* #t)
    (autolayout--on-change!)
    (let ((main (t--al-rect t--al-a)) (c (t--al-rect t--al-c)))
      (check-true! (and main (t--al-near? (nth 2 main) 0) (t--al-near? (nth 4 main) 0.62))
                   "a is still the main pane")
      (check-true! (and c (t--al-near? (nth 2 c) 0.62)) "c joined the stack"))
    ;; nothing changed: the hook does nothing
    (let ((before (window-rects)))
      (autolayout--on-change!)
      (check-equal! (window-rects) before "a second run leaves the frame alone"))
    (t--al-done!)))
