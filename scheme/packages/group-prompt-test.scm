;;; group-prompt-test.scm --- what the group prompts offer.

(domain! 'testing)
(effects! '(read))

(deftest 'a-listing-seeds-no-new-group
  "the switch prompt's new row seeds a work buffer, never a transient listing"
  (lambda ()
    (buffer-create "*zz-transient-listing*")
    (buffer-set-local! "*zz-transient-listing*" 'special #t)
    (buffer-create "*zz-work*")
    (check-false! (group-seed-buffer? "*zz-transient-listing*") "a transient buffer seeds nothing")
    (check-true! (group-seed-buffer? "*zz-work*") "a work buffer seeds")
    (with-current-buffer "*zz-transient-listing*"
      (lambda ()
        (check-equal! (car (group-switch-new-action)) "Start an empty group"
                      "from a listing the new group starts empty")))
    (buffer-kill! "*zz-transient-listing*")
    (buffer-kill! "*zz-work*")))

(deftest 'the-visible-verbs-take-the-windows-as-they-stand
  "group-from-visible founds a group from the visible work buffers under a new name, and moves them to a group picked by name"
  (lambda ()
    (delete-other-windows!)
    (buffer-create "*zz-vis-a*") (buffer-create "*zz-vis-b*")
    (switch-to-buffer! "*zz-vis-a*")
    (split-window! 'h 0.5) (other-window!) (switch-to-buffer! "*zz-vis-b*")
    (let ((id (group-found-from-windows! "zz-from-windows")))
      (check-true! (and id #t) "a group was founded")
      (check-true! (buffer-in-group? "*zz-vis-a*" id) "with the first window's buffer")
      (check-true! (buffer-in-group? "*zz-vis-b*" id) "and the second's")
      (check-equal! (frame-group) id "and the frame stands in it")
      (let ((other (group-record-create! "zz-elsewhere")))
        (group-add-buffers-to! (group-visible-work-buffers) other)
        (check-true! (buffer-in-group? "*zz-vis-b*" other) "the visible buffers can be moved by name")
        (group-record-delete! other))
      (delete-other-windows!)
      (switch-to-buffer! "*scratch*")
      (buffer-kill! "*zz-vis-a*") (buffer-kill! "*zz-vis-b*")
      (group-record-delete! id))))

(deftest 'moving-the-visible-buffers-keeps-them-on-screen
  "group-from-visible on a picked group changes the group alone: the same windows stay up"
  (lambda ()
    (delete-other-windows!)
    (buffer-create "*zz-mv-a*") (buffer-create "*zz-mv-b*")
    (switch-to-buffer! "*zz-mv-a*")
    (split-window! 'h 0.5) (other-window!) (switch-to-buffer! "*zz-mv-b*")
    (let ((from (group-found-from-windows! "zz-mv-from"))
          (to (group-record-create! "zz-mv-to")))
      (group-move-buffers-to! (group-visible-work-buffers) to #t)
      (check-equal! (frame-group) to "the frame stands in the destination")
      (check-true! (buffer-in-group? "*zz-mv-a*" to) "the first buffer moved")
      (check-true! (buffer-in-group? "*zz-mv-b*" to) "and the second")
      (let ((shown (map cadr (window-list))))
        (check-true! (and (member "*zz-mv-a*" shown) #t) "the first buffer is still on screen")
        (check-true! (and (member "*zz-mv-b*" shown) #t) "and so is the second"))
      (delete-other-windows!)
      (switch-to-buffer! "*scratch*")
      (buffer-kill! "*zz-mv-a*") (buffer-kill! "*zz-mv-b*")
      (group-record-delete! to)
      (group-record-delete! from))))
