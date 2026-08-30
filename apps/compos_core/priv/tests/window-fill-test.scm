;;; window-fill-test.scm --- one pool answers which buffers may fill a window here.

(domain! 'testing)
(effects! '(write display))

(deftest 'the-pool-is-the-groups-members-and-nothing-from-elsewhere
  "in a group the pool is the members; a foreign buffer never fills a window"
  (lambda ()
    (let ((id (group-record-create! "zz-fill-group"))
          (a "*zz-fill-a*") (b "*zz-fill-b*") (c "*zz-fill-elsewhere*"))
      (buffer-create a) (buffer-create b) (buffer-create c)
      (buffer-add-group! a id) (buffer-add-group! b id)
      (delete-other-windows!)
      (switch-to-buffer! a)
      (check-equal! (frame-group) id "the frame stands in the group")
      (let ((pool (window-fill-buffers)))
        (check-true! (and (member a pool) (member b pool) #t) "the members are the pool")
        (check-false! (member c pool) "a buffer from elsewhere is not"))
      (let ((panes (layout--three-columns (list a))))
        (check-true! (and (member b panes) #t) "the columns fill from the pool")
        (check-false! (member c panes) "and pull nothing in from elsewhere"))
      (switch-to-buffer! "*scratch*")
      (buffer-kill! a) (buffer-kill! b) (buffer-kill! c)
      (group-record-delete! id))))

(deftest 'a-peek-and-a-popup-are-not-fill-candidates
  "a look and a floating buffer never fill a window"
  (lambda ()
    (buffer-create "*zz-fill-popup*")
    (buffer-set-local! "*zz-fill-popup*" 'window-class "popup popup-right")
    (check-false! (fill-candidate? "*zz-fill-popup*") "the popup's buffer")
    (check-false! (fill-candidate? " *zz-hidden*") "a hidden name")
    (check-true! (fill-candidate? "*scratch*") "an ordinary buffer")
    (buffer-set-local! "*zz-fill-popup*" 'window-class #f)
    (buffer-kill! "*zz-fill-popup*")))
