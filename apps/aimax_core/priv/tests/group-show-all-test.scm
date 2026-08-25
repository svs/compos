;;; group-show-all-test.scm --- Show one group's buffers as one layout.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "replaces the frame layout and its Winner history")

(deftest 'group-show-all-tiles-every-member-and-winner-undo-restores-the-layout
  "the adaptive group layout is one Winner transaction"
  (lambda ()
    (let* ((first (test-buffer! "*zz-group-show-first*" ""))
           (second (test-buffer! "*zz-group-show-second*" ""))
           (third (test-buffer! "*zz-group-show-third*" ""))
           (group (group-record-create! "zz-group-show-all")))
      (for-each (lambda (buffer) (buffer-add-group! buffer group))
                (list first second third))
      (delete-other-windows!)
      (switch-to-buffer! first)
      (set-frame-local! 'current-group group)
      (set-frame-local! 'winner-ring #f)
      (set-frame-local! 'winner-pos #f)
      (set! *winner-inhibit* #f)

      ;; Test dispatch through a disposable binding. Production keys can move.
      (global-set-key "<f9> s" "group-show-all")
      (dispatch-keys '("<f9>" "s"))

      (check-true!
        (wait-until (lambda () (= (length (window-list)) 3)) 3000 20)
        "every member gets one window")
      (check-true! (window-showing first) "the first member is visible")
      (check-true! (window-showing second) "the second member is visible")
      (check-true! (window-showing third) "the third member is visible")

      (run-command "winner-undo")
      (check-equal! (length (window-list)) 1 "Winner restored the one-window layout")
      (check-equal! (window-buffer (active-window)) first "Winner restored its buffer")

      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (for-each buffer-kill! (list first second third))
      (group-record-delete! group))))

(deftest 'group-show-all-wakes-a-dormant-member
  "sleep does not remove a buffer from its group"
  (lambda ()
    (let* ((member (test-buffer! "*zz-group-show-sleeper*" "asleep"))
           (group (group-record-create! "zz-group-show-sleeper")))
      (buffer-add-group! member group)
      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (buffer-sleep! member)
      (check-false! (buffer-exists? member) "the member is dormant")
      (check-true! (buffer-known? member) "the group can still find its checkpoint")
      (set-frame-local! 'current-group group)

      (run-command "group-show-all")
      (check-true! (buffer-exists? member) "show all woke the member")
      (check-true! (window-showing member) "show all gave it a window")

      (switch-to-buffer! "*scratch*")
      (delete-other-windows!)
      (buffer-kill! member)
      (group-record-delete! group))))

(deftest 'group-show-all-gives-an-empty-group-its-primary-chat
  "an empty durable group still has one reconstructable surface"
  (lambda ()
    (let* ((before (test-buffer! "*zz-group-show-before-empty*" ""))
           (group (group-record-create! "zz-group-show-empty")))
      (delete-other-windows!)
      (switch-to-buffer! before)
      (set-frame-local! 'current-group group)
      (set-frame-local! 'winner-ring #f)
      (set-frame-local! 'winner-pos #f)
      (set! *winner-inhibit* #f)

      (run-command "group-show-all")
      (let ((chat (group-chat-name group)))
        (check-true! (buffer-in-group? chat group) "the primary chat belongs to the group")
        (check-true! (window-showing chat) "show all displayed the primary chat"))

      (run-command "winner-undo")
      (check-equal! (window-buffer (active-window)) before "Winner restored the prior buffer")

      (let ((chat (group-chat-name group)))
        (switch-to-buffer! "*scratch*")
        (delete-other-windows!)
        (when (buffer-known? chat) (buffer-kill! chat)))
      (buffer-kill! before)
      (group-record-delete! group))))
