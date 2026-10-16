;;; detail-test.scm --- a list opens its rows into one window, and keeps it.
;;;
;;; The frame has three windows on purpose: the list, and two others. The
;;; display chain alone would put the second row in whichever window is
;;; least recently used, so a table with three rows open would have walked
;;; across the frame. The detail window is remembered instead.

(domain! 'testing)
(effects! '(write display))

(define (t--dt-with thunk)
  (let ((rules *display-buffer-alist*)
        (base *display-buffer-base-action*)
        (h split-height-threshold)
        (w split-width-threshold))
    (set! split-height-threshold 1000)
    (set! split-width-threshold 1)
    (set! *display-buffer-base-action* '())
    (layout-target-set! #f)
    (when (float-open?) (float-close!))
    (set-frame-local! 'pinned-group #f)
    (set-frame-local! 'current-group #f)
    (set! *detail-windows* '())
    (switch-to-buffer-here! "*scratch*")
    (run-command "delete-other-windows")
    (let ((out (thunk)))
      (for-each (lambda (b) (when (string-prefix? "*zz-detail" b) (buffer-kill! b)))
                (buffer-list))
      (set! *display-buffer-alist* rules)
      (set! *display-buffer-base-action* base)
      (set! split-height-threshold h)
      (set! split-width-threshold w)
      (set! *detail-windows* '())
      (layout-target-set! #f)
      (switch-to-buffer! "*scratch*")
      (run-command "delete-other-windows")
      out)))

;; the list in the selected window, two other windows to be taken
(define (t--dt-frame!)
  (for-each buffer-create
    '("*zz-detail-list*" "*zz-detail-x*" "*zz-detail-y*" "*zz-detail-a*" "*zz-detail-b*"))
  (switch-to-buffer-here! "*zz-detail-list*")
  (split-window! 'h 0.34)
  (split-window! 'h 0.5)
  (let* ((me (active-window))
         (others (filter (lambda (w) (not (equal? w me))) (map car (window-list)))))
    (window-set-buffer! (car others) "*zz-detail-x*")
    (window-set-buffer! (cadr others) "*zz-detail-y*")
    (switch-to-buffer-here! "*zz-detail-list*")
    (cons me others)))

(deftest 'the-detail-category-reuses-before-it-splits
  "the stock rule: reuse a window, then take one, and only then make one"
  (lambda ()
    (t--dt-with
      (lambda ()
        (check-equal! (list-head (display-buffer-actions-for "*zz-detail-a*" '(category detail)) 3)
                      '(reuse-window use-some-window pop-up-window)
                      "the detail chain, before the fallback")))))


(deftest 'the-list-owns-what-it-opened
  "a detail is the list's child, so the details of one list are siblings"
  (lambda ()
    (t--dt-with
      (lambda ()
        (t--dt-frame!)
        (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")
        (display-buffer-detail! "*zz-detail-b*" "*zz-detail-list*")
        (check-equal! (detail-owner "*zz-detail-a*") "*zz-detail-list*" "the list is the parent")
        (check-true! (member "*zz-detail-b*" (buffer-children "*zz-detail-list*"))
                     "and both are its children")
        (check-true! (minor-mode-on? "*zz-detail-a*" "detail-mode") "detail-mode is on")))))

(deftest 'the-key-walks-the-details-of-this-list
  "C-` in the detail window flips through the rows already opened"
  (lambda ()
    (t--dt-with
      (lambda ()
        (t--dt-frame!)
        (let ((win (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")))
          (display-buffer-detail! "*zz-detail-b*" "*zz-detail-list*")
          (select-window! win)
          (check-equal! (current-buffer) "*zz-detail-b*" "standing in the second row")
          (check-equal! (keymap-lookup "detail-mode-map" "C-`") "detail-next"
                        "the key is the mode's own")
          (run-command "detail-next")
          (check-equal! (current-buffer) "*zz-detail-a*" "the other row of this list")
          (run-command "detail-next")
          (check-equal! (current-buffer) "*zz-detail-b*" "and back")
          (check-equal! (length (window-list)) 3 "the walk makes no window"))))))

(deftest 'the-detail-destination-moves-with-its-window
  "a user window move carries the remembered destination, so the next row, asked from the list, opens there"
  (lambda ()
    (t--dt-with
      (lambda ()
        (let* ((wins (t--dt-frame!))
               (list-win (car wins))
               (win (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")))
          (select-window! win)
          (window-swap! (if (window-in-direction 'left) 'left 'right))
          (check-equal! (active-window) win "the move follows the window")
          ;; the memory answers the list, not the detail you stand in
          (check-false! (detail-window "*zz-detail-list*")
                        "standing in the destination, it is not one to use")
          (select-window! list-win)
          (check-equal! (detail-window "*zz-detail-list*") win
                        "the destination is still the same logical window")
          (let ((again (display-buffer-detail! "*zz-detail-b*" "*zz-detail-list*")))
            (check-equal! again win "the next row uses the moved window")
            (check-equal! (window-buffer win) "*zz-detail-b*" "the new detail is visible there")))))))

(deftest 'the-memory-lapses-when-the-window-goes
  "nothing to put back: the next row picks a window through the chain again"
  (lambda ()
    (t--dt-with
      (lambda ()
        (let ((wins (t--dt-frame!)))
          (let ((first (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")))
            (delete-window-id! first)
            (check-false! (detail-window "*zz-detail-list*") "the memory is gone")
            (let ((second (display-buffer-detail! "*zz-detail-b*" "*zz-detail-list*")))
              (check-true! (and second (not (equal? second (active-window))))
                           "a live window that is not the list's")
              (check-equal! (window-buffer second) "*zz-detail-b*" "showing the row"))))))))

(deftest 'keeping-a-detail-keeps-its-name-and-leaves-the-list
  "M-RET on the detail: a buffer under its own name keeps it, stops being the list's child, and stays in the walk"
  (lambda ()
    (t--dt-with
      (lambda ()
        (let* ((wins (t--dt-frame!))
               (list-win (car wins))
               (win (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")))
          (select-window! win)
          (let ((kept (detail-keep!)))
            (check-equal! kept "*zz-detail-a*" "a name of its own already: no number is taken")
            (check-true! (buffer-known? "*zz-detail-a*") "the buffer stays under that name")
            (check-true! (buffer-local kept 'detail-kept) "and is marked kept")
            (check-equal! (detail-owner kept) "*zz-detail-list*" "it still knows its list")
            (check-false! (buffer-parent kept) "and the list's q leaves it alone")
            (select-window! list-win)
            (let ((again (display-buffer-detail! "*zz-detail-b*" "*zz-detail-list*")))
              (check-equal! again win "the next row takes the same window")
              (check-equal! (window-buffer win) "*zz-detail-b*" "showing the new row")
              (select-window! win)
              (check-true! (member kept (detail-ring)) "and the kept one is still in the walk"))))))))

;; The editor runs window-configuration-changed! from a detached task after
;; a window change, and the target reflow in it races this test's split:
;; the test went red and green from run to run. The test holds the reflow
;; out while it stands, the way layout-policy-test.scm does.
(deftest 'a-target-layout-still-gives-the-detail-a-window
  "one window, a target that never splits, a buffer no layout will hold: it lands anyway"
  (lambda ()
    (remove-hook! 'window-configuration-change-hook 'layout-target-on-change!)
    (t--dt-with
      (lambda ()
        (buffer-create "*zz-detail-list*")
        (buffer-create "*zz-detail-a*")
        (buffer-set-local! "*zz-detail-a*" 'special #t)
        (switch-to-buffer-here! "*zz-detail-list*")
        (run-command "delete-other-windows")
        (layout-target-set! 'two-pane)
        (check-false! (fill-candidate? "*zz-detail-a*") "no layout will hold it")
        (let ((me (active-window))
              (win (display-buffer-detail! "*zz-detail-a*" "*zz-detail-list*")))
          (check-true! (and win (not (equal? win me))) "a window of its own")
          (check-equal! (window-buffer win) "*zz-detail-a*" "showing the detail")
          (check-equal! (active-window) me "point stays in the list"))))
    (add-hook! 'window-configuration-change-hook 'layout-target-on-change!)))
