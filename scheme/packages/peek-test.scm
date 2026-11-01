;;; peek-test.scm --- the spec of a peek in the window model (docs/PEEK.md).
;;;
;;; Each test is one rule the user sees, checked on the layout value: a
;;; layout goes in, a layout comes out, with no frame and no draw.

(domain! 'testing)
(effects! '(pure))

(define (pk-row &rest bufs) (panes-default-layout bufs (lambda (b) "text-mode")))

(define (pk-shown l) (map caddr (panes-visible l)))

(define (pk-state placed owner target)
  (list 'owner owner 'buffer target 'key (cadr placed) 'made (caddr placed) 'held (cadddr placed)))

(deftest 'a-peek-goes-in-the-pane-after-the-list
  "the list's own pane keeps the list in front; the next pane shows the row, and dismiss gives that pane back"
  (lambda ()
    (let* ((l (pk-row "*list*" "b.txt"))
           (placed (peek-place l "*list*" "row.txt" "p1"))
           (pl (car placed)))
      (check-equal! (pk-shown pl) '("*list*" "row.txt") "the row is beside the list")
      (check-false! (caddr placed) "no pane was made")
      (check-equal! (panes-focus pl) "p1" "the focus stays in the list")
      (check-equal! (pk-shown (peek--without pl (pk-state placed "*list*" "row.txt")))
                    '("*list*" "b.txt") "dismiss shows the pane as it was"))))

(deftest 'a-peek-makes-a-pane-when-there-is-room-and-dismiss-removes-it
  "one pane under capacity: the peek adds a pane after the list, and that pane goes with the peek"
  (lambda ()
    (let* ((l (panes-set-capacity (pk-row "*list*") 3))
           (placed (peek-place l "*list*" "row.txt" "p1"))
           (pl (car placed)))
      (check-equal! (panes-pane-count pl) 2 "a pane was added")
      (check-true! (caddr placed) "the peek made it")
      (check-equal! (panes-pane-count (peek--without pl (pk-state placed "*list*" "row.txt"))) 1
                    "dismiss removes the pane it made"))))

(deftest 'with-no-room-a-peek-covers-the-list
  "one pane at capacity 1: the peek goes over the list, and dismiss brings the list back to the front"
  (lambda ()
    (let* ((l (panes-set-capacity (pk-row "*list*") 1))
           (placed (peek-place l "*list*" "row.txt" "p1"))
           (pl (car placed)))
      (check-equal! (pk-shown pl) '("row.txt") "the peek covers the list")
      (check-equal! (pk-shown (peek--without pl (pk-state placed "*list*" "row.txt")))
                    '("*list*") "the list is back"))))

(deftest 'a-buffer-a-hidden-window-held-goes-back-there
  "the row's buffer waited in a hidden window: the peek takes it, and dismiss puts it back in that window"
  (lambda ()
    (let* ((l (pk-row "*list*" "b.txt"))
           (hidden (panes-add-window l "p2" "row.txt" "text-mode" #t))
           (l (car hidden))
           (placed (peek-place l "*list*" "row.txt" "p1"))
           (back (peek--without (car placed) (pk-state placed "*list*" "row.txt"))))
      (check-equal! (panes-window-buffers back (cadr hidden)) '("row.txt") "the hidden window holds it again")
      (check-equal! (pk-shown back) '("*list*" "b.txt") "the screen is as it was"))))
