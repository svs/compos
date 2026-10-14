;;; switch-test.scm --- Cmd-up and Cmd-down walk a window's stack.
;;;
;;; A walk shows each buffer at once, with no prompt. The order holds
;;; while the walk lasts, so each step goes one sheet deeper, and the
;;; window's history is the one a single switch would leave.

(domain! 'testing)
(effects! '(read write))

(define (t--walk-setup!)
  (for-each (lambda (b) (buffer-create b))
            '("*zz-walk-a*" "*zz-walk-b*" "*zz-walk-c*" "*zz-walk-d*"))
  (run-command "window-walk-end")
  (switch-to-buffer-here! "*zz-walk-d*")
  (set-window-prev-buffers! (active-window) '("*zz-walk-c*" "*zz-walk-b*" "*zz-walk-a*")))

(deftest 'a-window-walk-goes-deeper-each-step
  "two steps down reach the third sheet, not the first again"
  (lambda ()
    (t--walk-setup!)
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-c*" "one step down")
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-b*" "a second step goes deeper")
    (check-equal! (window-prev-buffers (active-window))
                  '("*zz-walk-d*" "*zz-walk-c*" "*zz-walk-a*")
                  "the history is one switch from d to b")
    (window-walk! -1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-c*" "a step up comes back")))

(deftest 'a-new-walk-starts-on-top
  "after the walk ends, the next step reaches the buffer the walk left"
  (lambda ()
    (t--walk-setup!)
    (window-walk! 1 #t)
    (window-walk! 1 #t)
    (run-command "window-walk-end")
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-d*" "back to where the walk began")))

(deftest 'a-walk-up-from-the-top-wraps
  "up from the top of the stack reaches its bottom"
  (lambda ()
    (t--walk-setup!)
    (window-walk! -1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-a*" "the oldest sheet")))
