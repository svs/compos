;;; layouts-test.scm — the five layouts and the overview.

(domain! 'testing)
(effects! '(read))

(deftest 'the-six-layouts-and-their-capacities
  "there are six layouts; each one holds a fixed number of panes"
  (lambda ()
    (check-equal! *window-layout-algorithms* '(single two-pane halves columns rows two-chat)
                  "six layouts and no others")
    (check-equal! (layout-capacity 'single) 1 "one window")
    (check-equal! (layout-capacity 'two-pane) 2 "2/3 + 1/3")
    (check-equal! (layout-capacity 'halves) 2 "two equal panes")
    (check-equal! (layout-capacity 'columns) 3 "three columns")
    (check-equal! (layout-capacity 'rows) 2 "two stacked panes")
    (check-equal! (layout-capacity 'two-chat) 3 "two panes and a chat")
    (check-false! (layout-capacity 'grid) "a name that is not a layout has no capacity")))

(deftest 'two-chat-gives-the-chat-a-narrow-last-pane
  "two-chat splits the frame into two equal shares and a smaller chat share"
  (lambda ()
    (let ((shares (layout-first-ratio 'two-chat 3)))
      (check-equal! (length shares) 3 "a share for each pane")
      (check-equal! (car shares) (cadr shares) "the two work panes are equal")
      (check-true! (< (caddr shares) (car shares)) "the chat is narrower"))))

(deftest 'the-layout-that-fits-a-pane-count
  "a caller with panes in hand and no chosen layout gets the one that holds them"
  (lambda ()
    (check-equal! (layout-for-count 1) 'single "one pane")
    (check-equal! (layout-for-count 2) 'two-pane "two panes")
    (check-equal! (layout-for-count 3) 'columns "three panes")
    (check-equal! (layout-for-count 9) 'columns "more panes than any layout holds still fit three")))

(deftest 'overview-uses-only-the-current-group
  "the overview includes each group member and excludes other buffers"
  (lambda ()
    (let ((stale (group-resolve-id "zz-ov-list")))
      (when stale (group-record-delete! stale)))
    (let ((work (test-buffer! "*zz-ov-list-work*" ""))
          (foreign (test-buffer! "*zz-ov-list-foreign*" ""))
          (group (group-record-create! "zz-ov-list"))
          (origin (current-buffer)))
      (buffer-add-group! work group)
      (switch-to-buffer! work)
      (set-frame-local! 'current-group group)
      (let* ((chat (group-chat group))
             (buffers (overview-buffers)))
        (check-true! (member work buffers) "the work buffer tiles")
        (check-true! (member chat buffers) "the group chat tiles")
        (check-false! (member foreign buffers) "the foreign buffer stays out")
        (switch-to-buffer! origin)
        (set-frame-local! 'current-group #f)
        (group-record-delete! group)
        (for-each buffer-kill! (list work chat foreign))))))

(deftest 'dashboard-one-line-keeps-the-expanded-dashboard-facts
  "the persistent modeline summary names the mode and input lane"
  (lambda ()
    (let ((buf "zz-dashboard-line"))
      (test-buffer! buf "hello\n")
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
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
(deftest 'three-columns-in-a-group-fill-from-members-without-manufacturing-panes
  "in a group only ordinary members fill spare capacity"
  (lambda ()
    (let ((a (test-buffer! "zz-seal-a" "a"))
          (b (test-buffer! "zz-seal-b" "b"))
          (c (test-buffer! "zz-seal-c" "c"))
          (foreign (test-buffer! "zz-seal-foreign" "f"))
          (group (group-record-create! "zz-sealed-group")))
      (for-each (lambda (buf) (buffer-add-group! buf group)) (list a b c))
      ;; the foreign buffer is the most recent one: the old pool led with it
      (when (float-open?) (float-close!))
      (delete-other-windows!)
      (switch-to-buffer-here! foreign)
      (switch-to-buffer-here! a)
      (set-frame-local! 'current-group group)
      (let ((three (layout--fill-to (list a b) 3)))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) c "it is the group's other member")
        (check-false! (member foreign three) "the foreign buffer stays out"))
      ;; Members run out: leave the target underfilled.
      (buffer-remove-group! c group)
      (let ((three (layout--fill-to (list a b) 3)))
        (check-equal! three (list a b) "unused capacity stays empty")
        (check-false! (member foreign three) "the foreign buffer still stays out"))
      ;; One member occupies the frame by itself.
      (buffer-remove-group! b group)
      (let ((two (layout--fill-to (list a) 3)))
        (check-equal! two (list a) "one member stays one pane")
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
      (let ((three (layout--fill-to (list a b) 3)))
        (check-equal! (length three) 3 "a third column is found")
        (check-equal! (nth 2 three) recent "it is the most recent other buffer"))
      (for-each buffer-kill! (list a b recent)))))

(deftest 'dashboard-sync-writes-its-four-locals-together
  "one sync lands the line, the blocks, the modeline name and the context"
  (lambda ()
    (let ((buf "zz-dashboard-sync"))
      (test-buffer! buf "hello\n")
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      (check-true! (string? (buffer-local buf 'dashboard-line)) "the compact line landed")
      (check-true! (pair? (buffer-local buf 'dashboard-line-blocks)) "the blocks landed")
      (check-equal! (buffer-local buf 'modeline-name) buf "the modeline name landed")
      (check-true! (member 'dashboard-line (buffer-local buf 'desktop-skip-locals))
                   "the line is runtime state the desktop skips")
      (buffer-kill! buf))))

;;; --- transient frames -------------------------------------------------------

(deftest 'a-transient-frame-gives-back-exactly-what-it-found
  "the arrangement a transient frame mode found is the arrangement it leaves"
  (lambda ()
    (test-buffer! "*zz-tf-a*" "a")
    (test-buffer! "*zz-tf-b*" "b")
    (test-buffer! "*zz-tf-over*" "over")
    (switch-to-buffer-here! "*zz-tf-a*")
    (delete-other-windows!)
    (split-window! 'h 0.5)
    (display-buffer-in-window! (other-window-id (active-window)) "*zz-tf-b*")
    (let ((before (map (lambda (w) (nth 1 w)) (window-list))))
      (check-true! (transient-frame-enter! 'zz-tf) "entering records the arrangement")
      (check-true! (transient-frame-standing? 'zz-tf) "and the mode stands")
      ;; the mode takes the frame whole: one window over its own buffer
      (switch-to-buffer-here! "*zz-tf-over*")
      (delete-other-windows!)
      (check-equal! (length (window-list)) 1 "the mode covered the frame")
      (check-true! (transient-frame-exit! 'zz-tf) "leaving gives the frame back")
      (check-equal! (map (lambda (w) (nth 1 w)) (window-list)) before
                    "the same buffers in the same panes")
      (check-false! (transient-frame-standing? 'zz-tf) "and nothing is left standing")
      (check-false! (transient-frame-exit! 'zz-tf) "leaving twice restores nothing"))
    (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
              '("*zz-tf-a*" "*zz-tf-b*" "*zz-tf-over*"))
    (delete-other-windows!)))

(deftest 'a-transient-frame-that-stopped-standing-re-arms
  "a record whose buffer left the screen is stale: arriving records what is there now"
  (lambda ()
    (test-buffer! "*zz-tf-a*" "a")
    (test-buffer! "*zz-tf-over*" "over")
    (switch-to-buffer-here! "*zz-tf-a*")
    (delete-other-windows!)
    (transient-frame-enter! 'zz-tf)
    (switch-to-buffer-here! "*zz-tf-over*")
    ;; the mode's buffer is gone from the screen, so its record is stale
    (test-buffer! "*zz-tf-b*" "b")
    (switch-to-buffer-here! "*zz-tf-b*")
    (check-true! (transient-frame-rearm! 'zz-tf "*zz-tf-over*")
                 "re-arming records the arrangement in front of you")
    (switch-to-buffer-here! "*zz-tf-over*")
    (transient-frame-exit! 'zz-tf)
    (check-equal! (window-buffer (active-window)) "*zz-tf-b*"
                  "not the arrangement from the first entry")
    (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
              '("*zz-tf-a*" "*zz-tf-b*" "*zz-tf-over*"))
    (delete-other-windows!)))
