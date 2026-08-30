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

(deftest 'overview-tiles-work-buffers-only
  "the overview lists live work buffers, never chats, listings, or context"
  (lambda ()
    (let ((work (test-buffer! "*zz-ov-list-work*" ""))
          (listing (test-buffer! "*zz-ov-list-transient*" ""))
          (context (test-buffer! "*zz-ov-list-context*" "")))
      (buffer-set-local! listing 'transient #t)
      (buffer-context-only! context)
      (let ((buffers (overview-buffers)))
        (check-true! (member work buffers) "a work buffer tiles")
        (check-false! (member listing buffers) "a transient listing does not")
        (check-false! (member context buffers) "a context-only buffer does not"))
      (for-each buffer-kill! (list work listing context)))))

(deftest 'dashboard-one-line-keeps-the-expanded-dashboard-facts
  "the persistent modeline summary names the mode and input lane"
  (lambda ()
    (let ((buf "zz-dashboard-line"))
      (test-buffer! buf "hello\n")
      (with-current-buffer buf (lambda () (post-command!)))
      ;; the compact line carries the facts the expanded segments carry:
      ;; mode, group, model, lane. Neither rendering names the read-only
      ;; state today.
      (check-contains! (buffer-local buf 'dashboard-line) "mode "
                       "the compact line names the mode")
      (check-contains! (buffer-local buf 'dashboard-line) "groups "
                       "the compact line names the groups")
      (check-contains! (buffer-local buf 'dashboard-line) "llm "
                       "the compact line names the model")
      (check-contains! (buffer-local buf 'dashboard-line) "lane api"
                       "the compact line names the lane")
      (buffer-kill! buf))))

;; A group is sealed: the third column never comes from outside it.
(deftest 'three-columns-in-a-group-fill-from-members-then-a-blank-pane
  "in a group the third column is a member, else the group's scratch, never a foreign buffer"
  (lambda ()
    (let ((a (test-buffer! "zz-seal-a" "a"))
          (b (test-buffer! "zz-seal-b" "b"))
          (c (test-buffer! "zz-seal-c" "c"))
          (foreign (test-buffer! "zz-seal-foreign" "f"))
          (group (group-record-create! "zz-sealed-group")))
      (for-each (lambda (buf) (buffer-add-group! buf group)) (list a b c))
      ;; the foreign buffer is the most recent one: the old pool led with it
      (switch-to-buffer! foreign)
      (switch-to-buffer! a)
      (set-frame-local! 'current-group group)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) c "it is the group's other member")
        (check-false! (member foreign three) "the foreign buffer stays out"))
      ;; members run out: the third column is the group's scratch, a blank pane
      (buffer-remove-group! c group)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! (length three) 3 "a blank third column is added")
        (check-true! (string-prefix? "*scratch:" (nth 2 three))
                     "it is the group's scratch")
        (check-false! (member foreign three) "the foreign buffer still stays out"))
      ;; one member: the scratch makes two columns, and no more
      (buffer-remove-group! b group)
      (let ((two (layout--three-columns (list a))))
        (check-equal! (length two) 2 "one member and the blank pane")
        (check-false! (member foreign two) "and nothing foreign"))
      (set-frame-local! 'current-group #f)
      (for-each (lambda (buf) (when (buffer-known? buf) (buffer-kill! buf)))
                (append (group-buffers-as group 'scratch) (list a b c foreign)))
      (group-record-delete! group))))

(deftest 'three-columns-outside-a-group-fill-from-the-buffer-mru
  "with no group the third column is the most recent other buffer"
  (lambda ()
    (let ((a (test-buffer! "zz-open-a" "a"))
          (b (test-buffer! "zz-open-b" "b"))
          (recent (test-buffer! "zz-open-recent" "r")))
      (set-frame-local! 'current-group #f)
      (switch-to-buffer! recent)
      (switch-to-buffer! a)
      (let ((three (layout--three-columns (list a b))))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) recent "it is the most recent other buffer"))
      (for-each buffer-kill! (list a b recent)))))
