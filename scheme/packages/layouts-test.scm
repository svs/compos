;;; layouts-test.scm — the layouts.

(domain! 'testing)
(effects! '(read))

(deftest 'the-layout-that-fits-a-pane-count
  "a caller with panes in hand and no chosen layout gets the one that holds them"
  (lambda ()
    (check-equal! (layout-for-count 1) 'single "one pane")
    (check-equal! (layout-for-count 2) 'two-pane "two panes")
    (check-equal! (layout-for-count 3) 'columns "three panes")
    (check-equal! (layout-for-count 9) 'columns "more panes than any layout holds still fit three")))

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


(deftest 'dashboard-sync-writes-its-four-locals-together
  "one sync lands the line, the blocks, the modeline name and the context"
  (lambda ()
    (let ((buf "zz-dashboard-sync"))
      (test-buffer! buf "hello\n")
      (switch-to-buffer! buf)
      (dashboard--sync! buf)
      (check-true! (string? (buffer-local buf 'dashboard-line)) "the compact line landed")
      (check-true! (pair? (buffer-local buf 'dashboard-line-blocks)) "the blocks landed")
      (check-equal! (modeline-cache-get buf 'name) buf "the modeline name landed")
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
