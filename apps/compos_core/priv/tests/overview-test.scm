;;; overview-test.scm --- tile-all is a locked overview of every buffer.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "replaces the frame layout and locks the frame's keys")

(define (t--ov-drop-group! name)
  (let ((stale (group-resolve-id name)))
    (when stale (group-record-delete! stale))))

(deftest 'overview-locks-the-frame-and-quit-restores
  "the overview shows every work buffer and no key edits until quit"
  (lambda ()
    (let* ((first (test-buffer! "*zz-ov-first*" "hello"))
           (second (test-buffer! "*zz-ov-second*" "")))
      (delete-other-windows!)
      (switch-to-buffer! first)
      (set-frame-local! 'current-group #f)

      (run-command "tile-all")
      (check-true! (overview-active?) "the overview is on")
      (check-true! (pair? (frame-local 'transient-keymap))
                   "the overview owns the frame's key routing")
      (check-true! (>= (length (window-list)) 2) "the work buffers tile")
      (check-true! (window-showing first) "the first buffer is visible")
      (check-true! (window-showing second) "the second buffer is visible")

      ;; the frame is locked: a printable key selects nothing and edits nothing
      (dispatch-keys '("x"))
      (check-equal! (buffer-text first) "hello" "a printable key does not edit")
      (check-true! (overview-active?) "an unbound key does not leave the overview")

      (run-command "overview-quit")
      (check-false! (overview-active?) "quit leaves the overview")
      (check-equal! (length (window-list)) 1 "quit restores the one-window layout")
      (check-equal! (window-buffer (active-window)) first "quit restores the buffer")

      (for-each buffer-kill! (list first second)))))

(deftest 'overview-pop-out-founds-a-child-and-dissolve-merges-back
  "SPC pops the selection into a child group; dissolve returns it to the parent"
  (lambda ()
    (let* ((stay (test-buffer! "*zz-ov-stay*" ""))
           (move (test-buffer! "*zz-ov-move*" "")))
      (t--ov-drop-group! "zz-ov-origin")
      (t--ov-drop-group! "*zz-ov-move*")
      (let ((origin (group-record-create! "zz-ov-origin")))
        (buffer-add-group! stay origin)
        (buffer-add-group! move origin)
        (delete-other-windows!)
        (switch-to-buffer! move)
        (set-frame-local! 'current-group origin)

        (run-command "tile-all")
        (check-equal! (current-buffer) move "the selection starts on the MRU buffer")

        (run-command "overview-pop-out")
        (let ((child (group-resolve-id "*zz-ov-move*")))
          (check-true! child "the pop-out founded a group named for the buffer")
          (check-equal! (group-parent child) origin "the child records its parent")
          (check-true! (buffer-in-group? move child) "the buffer joined the child")
          (check-false! (buffer-in-group? move origin) "the buffer left the parent")
          (check-equal! (frame-group) child "the frame stands in the child")
          (check-false! (overview-active?) "the pop-out ends the overview")

          (run-command "group-dissolve")
          (check-true! (buffer-in-group? move origin) "dissolve merged the member back")
          (check-false! (group-resolve-id "*zz-ov-move*") "the child record is gone")
          (check-equal! (frame-group) origin "the frame followed into the parent"))

        (switch-to-buffer! "*scratch*")
        (delete-other-windows!)
        (set-frame-local! 'current-group #f)
        (for-each buffer-kill! (list stay move))
        (t--ov-drop-group! "zz-ov-origin")))))

(deftest 'overview-marks-collect-a-multi-buffer-pop-out
  "marked tiles pop out together into one new group"
  (lambda ()
    (let* ((one (test-buffer! "*zz-ov-mark-one*" ""))
           (two (test-buffer! "*zz-ov-mark-two*" "")))
      (t--ov-drop-group! "*zz-ov-mark-one*")
      (delete-other-windows!)
      (switch-to-buffer! two)
      (switch-to-buffer! one)
      (set-frame-local! 'current-group #f)

      (run-command "tile-all")
      (run-command "overview-mark")
      (select-window! (window-showing two))
      (run-command "overview-mark")
      (run-command "overview-pop-out")

      (let ((child (group-resolve-id "*zz-ov-mark-one*")))
        (check-true! child "the pop-out founded one group")
        (check-true! (buffer-in-group? one child) "the first mark joined")
        (check-true! (buffer-in-group? two child) "the second mark joined")
        (check-false! (group-parent child) "no origin group means no parent"))

      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (set-frame-local! 'current-group #f)
      (for-each buffer-kill! (list one two))
      (t--ov-drop-group! "*zz-ov-mark-one*"))))

(deftest 'dissolve-without-a-parent-keeps-the-old-sweep
  "a group nobody popped out dissolves without inventing a membership"
  (lambda ()
    (t--ov-drop-group! "zz-ov-plain")
    (let ((buf (test-buffer! "*zz-ov-plain*" ""))
          (id (group-record-create! "zz-ov-plain")))
      (buffer-add-group! buf id)
      (group-dissolve! id)
      (check-equal! (buffer-group-ids buf) '() "the buffer is in no group")
      (check-false! (group-resolve-id "zz-ov-plain") "the record is gone")
      (buffer-kill! buf))))
