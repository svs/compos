;;; panes-history-test.scm --- undo and redo over the pane arrangement, on the pure model.

(require 'panes-history)

(domain! 'testing)
(effects! '(pure))

(define (pht-layout)
  ;; two panes: a holds x over y, b holds z
  (let* ((r (panes-add-pane (panes-empty))) (l (car r)) (pa (cadr r))
         (r (panes-new-window l pa "x" "m-mode")) (l (car r)) (wa (cadr r))
         (l (panes-set-buffers l wa '("x" "y")))
         (r (panes-add-pane l)) (l (car r)) (pb (cadr r))
         (r (panes-new-window l pb "z" "n-mode")) (l (car r)))
    (list l wa pb)))

(deftest 'layout-history-records-shapes-not-buffers
  "a new arrangement is a state; a buffer change in a window is not"
  (lambda ()
    (let* ((made (pht-layout)) (l (car made)) (wa (cadr made))
           (h (panes-history-record (panes-history-empty) l))
           (h2 (panes-history-record h (panes-show l wa "y")))
           (h3 (panes-history-record h2 (car (panes-add-pane l)))))
      (check-equal! (length (panes-history-past h)) 1 "the first layout is the current state")
      (check-equal! (length (panes-history-past h2)) 1 "showing another buffer records no state")
      (check-equal! (panes-window-buffer (panes-history-current h2) wa) "y" "but the current state follows the buffers")
      (check-equal! (length (panes-history-past h3)) 2 "a third pane is a new state"))))

(deftest 'layout-undo-and-redo-walk-the-states
  "undo steps back, redo steps forward, a new state ends the redo"
  (lambda ()
    (let* ((made (pht-layout)) (l (car made))
           (l3 (car (panes-add-pane l)))
           (h (panes-history-record (panes-history-record (panes-history-empty) l) l3))
           (u (panes-history-undo h)))
      (check-true! (pair? u) "there is a state to go back to")
      (check-equal! (panes-shape (cadr u)) (panes-shape l) "undo answers the two-pane arrangement")
      (check-false! (panes-history-undo (car u)) "and nothing older")
      (let ((r (panes-history-redo (car u))))
        (check-equal! (panes-shape (cadr r)) (panes-shape l3) "redo answers the three-pane arrangement")
        (check-false! (panes-history-redo (car r)) "and nothing newer"))
      (let ((after-new (panes-history-record (car u) (car (panes-add-pane (car (panes-add-pane l)))))))
        (check-equal! (panes-history-future after-new) '() "a new state ends the redo")))))

(deftest 'layout-undo-keeps-the-buffers-the-windows-show-now
  "the arrangement comes back; a window both states hold keeps its present stack; a gone buffer leaves"
  (lambda ()
    (let* ((made (pht-layout)) (l (car made)) (wa (cadr made)) (pb (caddr made))
           (recorded l)
           (now (panes-show (panes-close-window l (car (plist-get (panes-pane l pb) 'windows))) wa "y"))
           (merged (panes-history-merge now recorded (lambda (b) (not (equal? b "z"))))))
      (check-equal! (length (panes-panes merged)) 1 "the pane whose only buffer is gone does not come back")
      (check-equal! (panes-window-buffer merged wa) "y" "the surviving window shows what it shows now")
      (check-equal! (panes-window-buffers merged wa) '("y" "x") "with its present stack"))))
