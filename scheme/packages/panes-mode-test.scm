;;; panes-mode-test.scm --- the window model on a frame: a visit, a display,
;;; a quit and a kill go through the model, and the frame follows it.

(domain! 'testing)
(effects! '(write display))

(define (pmt-buffer! name mode)
  ;; every test starts with the model off and turns it on itself
  (when panes-mode (panes-mode-disable!))
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

(deftest 'panes-mode-group-switch-arranges-the-same-windows
  "with the model on, leaving a group and coming back puts the very same windows on screen: nothing is rebuilt, no id changes"
  (lambda ()
    (with-fresh-group "zz-panes-sw-a"
      (lambda (ga)
        (with-fresh-group "zz-panes-sw-b"
          (lambda (gb)
            (let ((a1 (pmt-buffer! "zz-sw-a1" "zz-a-mode"))
                  (a2 (pmt-buffer! "zz-sw-a2" "zz-c-mode"))
                  (b1 (pmt-buffer! "zz-sw-b1" "zz-b-mode")))
              (for-each (lambda (x) (buffer-add-group! x ga)) (list a1 a2))
              (buffer-add-group! b1 gb)
              (switch-to-group! ga)
              (delete-other-windows!)
              (switch-to-buffer-here! a1)
              (unwind-protect
                (lambda ()
                  (panes-mode-enable!)
                  (switch-to-buffer! a2)
                  (check-equal! (length (window-list)) 2 "two panes in A")
                  (let ((before (window-list)))
                    (switch-to-group! gb)
                    (check-false! (equal? (map cadr (window-list)) (map cadr before)) "B shows its own windows")
                    (switch-to-group! ga)
                    (check-equal! (window-list) before "A comes back with the same windows: same ids, same buffers, same order")))
                (lambda () (pmt-done! (list a1 a2 b1)))))))))))

(deftest 'panes-mode-arrangement-pop-arranges-back
  "a frame look ends by arranging the model's windows back: the same window id, and the model follows the frame"
  (lambda ()
    (with-fresh-group "zz-panes-arr"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-ar-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-ar-c" "zz-c-mode")))
          (for-each (lambda (x) (buffer-add-group! x id)) (list a c))
          (switch-to-group! id)
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (unwind-protect
            (lambda ()
              (panes-mode-enable!)
              (let ((before (window-list))
                    (token (arrangement-push! 'zz-panes)))
                (switch-to-buffer! c)
                (check-equal! (length (window-list)) 2 "a second pane opened")
                (check-true! (arrangement-pop! token #t) "the pop answers #t")
                (check-equal! (window-list) before "the frame is back with the same window")
                (check-equal! (length (panes-panes (panes-layout))) 1 "and the model is the one pane again")))
            (lambda () (pmt-done! (list a c)))))))))

(deftest 'panes-mode-a-layout-without-handles-takes-the-windows-that-show-its-buffers
  "a layout whose handles are gone, as after a restart, is drawn on the windows that already show its buffers; no window is made"
  (lambda ()
    (let ((a (pmt-buffer! "zz-at-a" "zz-a-mode"))
          (b (pmt-buffer! "zz-at-b" "zz-b-mode")))
      (unwind-protect
        (lambda ()
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (split-window! 'h 0.5)
          (other-window!)
          (switch-to-buffer-here! b)
          (let* ((before (window-list))
                 (drawn (panes-look! (panes-strip-handles (panes-adopt)))))
            (check-equal! (window-list) before "the same windows, untouched")
            (check-equal! (map (lambda (k) (panes-handle drawn k)) (panes-top-windows drawn))
                          (map car before)
                          "each window took its handle back")))
        (lambda () (pmt-done! (list a b)))))))

(deftest 'panes-mode-winner-walks-the-layout-history
  "with the model on, winner-previous puts the previous pane arrangement back and winner-next goes forward again"
  (lambda ()
    (with-fresh-group "zz-panes-wn"
      (lambda (id)
        (let ((a (pmt-buffer! "zz-wn-a" "zz-a-mode"))
              (c (pmt-buffer! "zz-wn-c" "zz-c-mode")))
          (for-each (lambda (x) (buffer-add-group! x id)) (list a c))
          (switch-to-group! id)
          (delete-other-windows!)
          (switch-to-buffer-here! a)
          (unwind-protect
            (lambda ()
              (panes-mode-enable!)
              (switch-to-buffer! c)
              (check-equal! (length (window-list)) 2 "two panes")
              (winner-previous!)
              (check-equal! (length (window-list)) 1 "winner-previous put the one pane back")
              (winner-next!)
              (check-equal! (length (window-list)) 2 "winner-next went forward again"))
            (lambda () (pmt-done! (list a c)))))))))

(deftest 'panes-mode-a-group-model-never-holds-another-groups-buffer
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
                  (panes-mode-enable!)
                  (switch-to-buffer! a2)
                  (panes-layout-set! (panes-show (panes-layout) (car (panes-top-windows (panes-layout))) b1))
                  (check-false! (member b1 (panes-buffers (panes-layout-of ga))) "A's model kept B's buffer out")
                  (check-true! (and (member a2 (panes-buffers (panes-layout-of ga))) #t) "and its own buffers in")
                  (switch-to-group! gb)
                  (switch-to-group! ga)
                  (check-false! (window-showing b1) "back in A, B's buffer is not on screen"))
                (lambda () (pmt-done! (list a1 a2 b1)))))))))))
