;;; panes-mode-test.scm --- the window model on a frame: a visit, a display,
;;; a quit and a kill go through the model, and the frame follows it.

(domain! 'testing)
(effects! '(write display))

(define (pmt-buffer! name mode)
  (test-buffer! name "text\n")
  (buffer-set-local! name 'mode-name mode)
  name)

(define (pmt-done! bufs)
  (when panes-mode (panes-mode-disable!))
  (panes-layout-forget!)
  (delete-other-windows!)
  (switch-to-buffer-here! "*scratch*")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) bufs))

(deftest 'panes-mode-routes-a-visit-to-the-window-of-its-mode
  "with the model on, a new mode takes a pane, a second buffer of a mode lands on that mode's window, q steps back in that window alone, and a kill closes an emptied window and its pane"
  (lambda ()
    (with-fresh-group "zz-panes-visit"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-pm-a" "zz-a-mode"))
              (b (pmt-buffer! "zz-pm-b" "zz-a-mode"))
              (c (pmt-buffer! "zz-pm-c" "zz-c-mode")))
          (for-each (lambda (x) (buffer-add-group! x id)) (list a b c))
          (switch-to-group! id)
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (unwind-protect
            (lambda ()
              (panes-mode-enable!)
              (check-equal! (length (window-list)) 1 "the model adopted the one pane")
              (switch-to-buffer! c)
              (check-equal! (length (window-list)) 2 "a new mode took a second pane")
              (check-equal! (window-buffer (active-window)) c "and the visit selected it")
              (let ((wc (active-window)))
                (switch-to-buffer! b)
                (check-equal! (length (window-list)) 2 "a second buffer of a mode made no pane")
                (check-equal! (window-buffer (active-window)) b "it is selected")
                (check-false! (equal? (active-window) wc) "in the window of its mode, not where the visit began")
                (check-equal! (window-prev-buffers (active-window)) (list a) "on top of that window's stack")
                (window-unwind-or-close! (active-window))
                (check-equal! (window-buffer (active-window)) a "q steps back in this window")
                (check-equal! (window-buffer wc) c "and leaves the other window alone")
                (buffer-kill! c)
                (check-equal! (length (window-list)) 1 "the emptied window and its pane are gone")
                (check-equal! (window-buffer (active-window)) a "the survivor stays")))
            (lambda () (pmt-done! (list a b c)))))))))

(deftest 'panes-mode-displays-beside-and-keeps-the-selection
  "a display opens another pane while there is room and selects nothing; a second display of that mode lands on the same window"
  (lambda ()
    (with-fresh-group "zz-panes-display"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-pd-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-pd-c" "zz-c-mode"))
              (d (pmt-buffer! "zz-pd-d" "zz-c-mode")))
          (for-each (lambda (x) (buffer-add-group! x id)) (list a c d))
          (switch-to-group! id)
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (unwind-protect
            (lambda ()
              (panes-mode-enable!)
              (let ((me (active-window)))
                (display-buffer c)
                (check-equal! (length (window-list)) 2 "the result took a pane of its own")
                (check-equal! (active-window) me "the selection stayed")
                (let ((wc (window-showing c)))
                  (display-buffer d)
                  (check-equal! (length (window-list)) 2 "a second result of that mode made no pane")
                  (check-equal! (window-buffer wc) d "it shows in the mode's window")
                  (check-equal! (window-prev-buffers wc) (list c) "over the first result"))))
            (lambda () (pmt-done! (list a c d)))))))))

(deftest 'panes-adopt-reads-the-frame-left-to-right
  "two windows side by side read as two panes with equal shares, each window's history as its stack"
  (lambda ()
    (let ((a (pmt-buffer! "zz-pr-a" "zz-a-mode"))
          (b (pmt-buffer! "zz-pr-b" "zz-b-mode")))
      (unwind-protect
        (lambda ()
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (split-window! 'h 0.5)
          (other-window!)
          (switch-to-buffer-here! b)
          (let ((l (panes-adopt)))
            (check-equal! (panes-pane-count l) 2 "two panes")
            (check-equal! (map caddr (panes-visible l)) (list a b) "left to right")
            (check-equal! (panes-shares l) '(0.5 0.5) "equal shares")
            (check-equal! (panes-handle l (cadr (car (panes-visible l)))) (car (car (window-list))) "the handle is the window")))
        (lambda () (pmt-done! (list a b)))))))
