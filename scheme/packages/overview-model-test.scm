;;; overview-model-test.scm --- the overview as data: walking the tiles,
;;; killing them and leaving keep the window model whole. Pure: no window
;;; moves, so the tests run in the live editor.

(domain! 'testing)
(effects! '(pure))

;; three panes, windows behind two of them, and two windows no pane holds
(define t--ov-model
  '(panes ((windows ("w1" "w2" "w3") id "p1" share 1)
           (windows ("w4" "w5") id "p2" share 1.0)
           (windows ("w6") id "p3" share 1.0))
    windows ((key "w1" win 10 mode "list-mode" buffers ("*list*") preferred #t)
             (key "w2" win 11 mode "jobs-mode" buffers ("*jobs*" "*list*") preferred #t)
             (key "w3" win 12 mode "todo-mode" buffers ("*todo*") preferred #t)
             (key "w4" win 20 mode "detail-mode" buffers ("*detail a*" "*detail b*") preferred #t)
             (key "w5" win 21 mode "meeting-mode" buffers ("*meeting*") preferred #t)
             (key "w6" win 30 mode "chat-mode" buffers ("chat") preferred #t))
    next-window 7 next-pane 4 capacity 3))

(define t--ov-buffers
  '((10 "*list*") (11 "*jobs*") (12 "*todo*") (20 "*detail a*") (21 "*meeting*")
    (30 "chat") (40 "*stray one*") (41 "*stray two*")))

(define (t--ov-buffer-of w) (let ((e (assoc w t--ov-buffers))) (and e (cadr e))))

;; the tiles as the view lays them: the panes' fronts first, then the rest
(define t--ov-ids '(10 20 30 11 12 21 40 41))
(define t--ov-rows (windows-overview--rows t--ov-ids (windows-overview--cols (length t--ov-ids))))

(define (t--ov-run from keys) (windows-overview-session t--ov-model t--ov-rows from keys t--ov-buffer-of))

(define (t--ov-fronts m)
  (map (lambda (p) (panes-handle m (car (plist-get p 'windows)))) (panes-panes m)))

(deftest 'overview-grid-is-even
  "the tiles lay in rows that differ by one at most"
  (lambda ()
    (check-equal! (map length t--ov-rows) '(4 4) "eight tiles")
    (check-equal! (map (lambda (n) (map length (windows-overview--rows (iota n) (windows-overview--cols n)))) '(1 5 7 19))
                  '((1) (3 2) (4 3) (5 5 5 4)) "one, five, seven, nineteen")))

(deftest 'overview-steps-stay-on-the-grid
  "every arrow from every tile lands on a tile or stays; right then left comes back"
  (lambda ()
    (let ((flat (apply append t--ov-rows)))
      (for-each
        (lambda (w)
          (for-each (lambda (d) (let ((to (windows-overview-step t--ov-rows w d)))
                                  (check-true! (or (not to) (member to flat)) (format "~a ~a" w d))))
                    '(left right up down))
          (let ((r (windows-overview-step t--ov-rows w 'right)))
            (when r (check-equal! (windows-overview-step t--ov-rows r 'left) w (format "~a right left" w)))))
        flat)
      (check-equal! (windows-overview-step t--ov-rows 11 'right) 12 "right runs on to the next row")
      (check-equal! (windows-overview-step t--ov-rows 10 'up) #f "the top edge"))))

(deftest 'overview-leaving-unchosen-keeps-the-model
  "leaving on the window the view opened from, or on one on screen, draws the saved model"
  (lambda ()
    (for-each (lambda (keys)
                (let ((r (t--ov-run 10 keys)))
                  (check-equal! (cadr r) t--ov-model (format "~a" keys))
                  (check-equal! (caddr r) '() (format "~a faults" keys))))
              '((ret) (quit) (right ret) (right right ret) (down up ret)))))

(deftest 'overview-chosen-window-takes-the-home-pane
  "a window behind a pane, or one no pane holds, takes the place of the window the view opened from"
  (lambda ()
    (let ((behind (t--ov-run 10 '(down ret)))
          (stray (t--ov-run 30 '(down ret))))
      (check-equal! (car behind) 12 "down from the first tile")
      (check-equal! (t--ov-fronts (cadr behind)) '(12 20 30) "the todo window fronts p1")
      (check-equal! (caddr behind) '() "no faults")
      (check-equal! (car stray) 40 "down from chat")
      (check-equal! (t--ov-fronts (cadr stray)) '(10 20 40) "the stray fronts p3")
      (check-equal! (caddr stray) '() "no faults"))))

(deftest 'overview-kill-leaves-a-whole-model
  "a killed tile's buffer leaves every window; a window with nothing left closes"
  (lambda ()
    (let* ((r (t--ov-run 10 '(right right kill ret)))
           (bufs (apply append (map (lambda (w) (plist-get w 'buffers)) (panes-windows (cadr r))))))
      (check-equal! (list-ref r 4) '((30 "chat")) "chat was killed")
      (check-false! (member "chat" bufs) "no window lists chat")
      (check-equal! (caddr r) '() "no faults"))))

(deftest 'overview-faults-catch-the-bugs-we-had
  "two columns swapped, one window in two places, a pane's width: each is a fault"
  (lambda ()
    (let* ((m t--ov-model)
           (wide (panes--put m 'panes (map (lambda (p) (panes--put p 'share 2)) (panes-panes m)))))
      (check-true! (pair? (windows-overview-model-faults m (windows-overview--swap-keys m "w1" "w4") 10 #f)) "swapped columns")
      (check-true! (pair? (windows-overview-model-faults m (panes-set-handle m "w4" 10) 10 #f)) "one window twice")
      (check-true! (pair? (windows-overview-model-faults m wide 10 #f)) "widths"))))

(deftest 'overview-random-walks-keep-the-rules
  "three hundred walks of arrows and kills, left on ret or quit, break no rule"
  (lambda ()
    (let* ((seed 7)
           (rand (lambda (n) (set! seed (modulo (+ (* seed 1103515245) 12345) 2147483648)) (modulo (quotient seed 65536) n))))
      (let loop ((i 0))
        (when (< i 300)
          (let* ((len (+ 1 (rand 12)))
                 (keys (let gen ((j 0) (ks '()))
                         (if (= j len) (reverse (cons (if (= 0 (rand 2)) 'ret 'quit) ks))
                             (gen (+ j 1) (cons (list-ref '(left right up down kill) (rand 5)) ks)))))
                 (from (list-ref '(10 20 30) (rand 3)))
                 (r (t--ov-run from keys)))
            (check-equal! (caddr r) '() (format "from ~a ~a" from keys))
            (check-true! (member (car r) (apply append (list-ref r 3))) (format "chosen on the grid ~a" keys))
            (check-false! (assoc (car r) (list-ref r 4)) (format "chosen not killed ~a" keys)))
          (loop (+ i 1)))))))

(deftest 'overview-returns-what-was-on-screen
  "a model drifted from the screen is saved as the screen shows it, and leaving draws that"
  (lambda ()
    (let* ((shown '(30 11 20))
           (saved (windows-overview-model-as-shown t--ov-model shown))
           (r (windows-overview-session saved t--ov-rows 30 '(right left ret) t--ov-buffer-of)))
      (check-equal! (t--ov-fronts saved) shown "the panes in screen order, the shown windows in front")
      (check-equal! (map (lambda (p) (plist-get p 'share)) (panes-panes saved)) '(1.0 1 1.0) "each pane keeps its share")
      (check-equal! (t--ov-fronts (cadr r)) shown "leaving draws the screen as it was")
      (check-equal! (caddr r) '() "no faults"))))
