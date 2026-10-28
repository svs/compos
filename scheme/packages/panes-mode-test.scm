;;; panes-mode-test.scm --- the spec of the window model on the screen.
;;;
;;; panes-test.scm says what the model does, on the value alone. These few
;;; say only that the screen shows the model: its panes as windows, its
;;; focus as the selection, and that nothing but a door writes it.

(domain! 'testing)
(effects! '(write display))

(define (pmt-buffer! name mode)
  (test-buffer! name "text\n")
  (buffer-set-local! name 'mode-name mode)
  name)

(define (pmt-done! bufs)
  (panes-layout-forget!)
  (delete-other-windows!)
  (switch-to-buffer-here! "*scratch*")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) bufs))

;; a group of A and C, laid out as a new group is: one pane each
(define (pmt-two-panes! id a c)
  (for-each (lambda (x) (buffer-add-group! x id)) (list a c))
  (switch-to-group! id)
  (delete-other-windows!)
  (switch-to-buffer-here! a)
  (panes--enter-group!)
  (panes-apply! (panes--default-layout (list a c))))

(deftest 'the-screen-shows-one-window-per-pane-left-to-right
  "each pane of the model is one window on the screen, in the model's order; the width each window gets is the model's (panes-test.scm)"
  (lambda ()
    (with-fresh-group "zz-panes-draw"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-pw-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-pw-c" "zz-c-mode")))
          (unwind-protect
            (lambda ()
              (let* ((l (pmt-two-panes! id a c))
                                          (ws (window-list)))
                (check-equal! (map cadr ws) (list a c) "one window per pane, left to right")))
            (lambda () (pmt-done! (list a c)))))))))

(deftest 'the-selected-window-is-the-models-focus
  "select-window! moves the model's focus to the pane of that window"
  (lambda ()
    (with-fresh-group "zz-panes-focus"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-pf-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-pf-c" "zz-c-mode")))
          (unwind-protect
            (lambda ()
              (let* ((l (pmt-two-panes! id a c))
                     (wc (panes-handle l (car (panes-pane-keys l (cadr (panes-pane-ids l)))))))
                (check-equal! (length (window-list)) 2 "two panes on screen")
                (select-window! wc)
                (check-equal! (panes-focus (panes-layout)) (cadr (panes-pane-ids l)) "the model's focus is the second pane")
                (check-equal! (active-window) wc "and the frame selected its window")))
            (lambda () (pmt-done! (list a c)))))))))

(deftest 'only-a-door-writes-the-model
  "a window change runs no hook that writes the model"
  (lambda ()
    (with-fresh-group "zz-panes-hooks"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-ph-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-ph-c" "zz-c-mode")))
          (unwind-protect
            (lambda ()
              (pmt-two-panes! id a c)
              (let ((before (panes-layout)))
                (window-configuration-changed!)
                (check-equal! (panes-layout) before "the hooks left the model as it was"))
              (check-false! (member 'panes--reconcile! (hook-functions 'window-configuration-change-hook)) "no reconcile hook")
              (check-false! (member 'panes--note-focus! (hook-functions 'window-state-change-hook)) "no focus hook"))
            (lambda () (pmt-done! (list a c)))))))))

(deftest 'coming-back-to-a-group-never-shows-another-groups-buffer
  "a window of A that comes to show B's buffer leaves A's model without it, so coming back to A never shows B's buffer"
  (lambda ()
    (with-fresh-group "zz-panes-seal-a"
      (lambda (ga)
        (with-fresh-group "zz-panes-seal-b"
          (lambda (gb)
            (let ((a1 (pmt-buffer! "zz-se-a1" "zz-a-mode"))
                  (a2 (pmt-buffer! "zz-se-a2" "zz-c-mode"))
                  (b1 (pmt-buffer! "zz-se-b1" "zz-b-mode")))
              (for-each (lambda (x) (buffer-add-group! x ga)) (list a1 a2))
              (buffer-add-group! b1 gb)
              (switch-to-group! ga)
              (delete-other-windows!)
              (switch-to-buffer-here! a1)
              (unwind-protect
                (lambda ()
                  (panes--enter-group!)
                  (switch-to-buffer! a2)
                  (panes-layout-set! (panes-show (panes-layout) (car (panes-top-windows (panes-layout))) b1))
                  (check-false! (member b1 (panes-buffers (panes-layout-of ga))) "A's model kept B's buffer out")
                  (check-true! (and (member a2 (panes-buffers (panes-layout-of ga))) #t) "and its own buffers in")
                  (switch-to-group! gb)
                  (switch-to-group! ga)
                  (check-false! (window-showing b1) "back in A, B's buffer is not on screen"))
                (lambda () (pmt-done! (list a1 a2 b1)))))))))))
