;;; layouts-test.scm — responsive window policy is inspectable Scheme data.

(domain! 'testing)
(effects! '(read))

(deftest 'adaptive-layout-stacks-on-compact-frames
  "a narrow editor preserves horizontal reading room"
  (lambda ()
    (check-equal! (window-layout-for-width 80 3) 'main-bottom
                  "compact frames stack the secondary panes")))

(deftest 'adaptive-layout-keeps-a-third-rail-on-regular-frames
  "the common desktop arrangement is a main pane and side rail"
  (lambda ()
    (check-equal! (window-layout-for-width 140 3) 'main-right
                  "regular frames use the one-third rail")))

(deftest 'adaptive-layout-uses-monitor-width-for-wide-arrangements
  "wide frames promote three panes to columns and four to a grid"
  (lambda ()
    (check-equal! (window-layout-for-width 240 2) 'main-right
                  "two panes retain the main/rail hierarchy")
    (check-equal! (window-layout-for-width 240 3) 'columns
                  "three panes become exact thirds")
    (check-equal! (window-layout-for-width 240 4) 'grid
                  "four panes become a balanced grid")))

(deftest 'dashboard-one-line-keeps-the-expanded-dashboard-facts
  "the persistent modeline summary names the mode and input lane"
  (lambda ()
    (let ((buf "zz-dashboard-line"))
      (test-buffer! buf "hello\n")
      (with-current-buffer buf (lambda () (post-command!)))
      (check-contains! (buffer-local buf 'dashboard-line) "editable"
                       "the compact line names the edit state")
      (check-contains! (buffer-local buf 'dashboard-line) "api"
                       "the compact line names the lane")
      (buffer-kill! buf))))
