;;; group-prompt-test.scm --- what the group prompts offer.

(domain! 'testing)
(effects! '(read))

(deftest 'a-listing-seeds-no-new-group
  "the switch prompt's new row seeds a work buffer, never a transient listing"
  (lambda ()
    (buffer-create "*zz-transient-listing*")
    (buffer-set-local! "*zz-transient-listing*" 'transient #t)
    (buffer-create "*zz-work*")
    (check-false! (group-seed-buffer? "*zz-transient-listing*") "a transient buffer seeds nothing")
    (check-true! (group-seed-buffer? "*zz-work*") "a work buffer seeds")
    (with-current-buffer "*zz-transient-listing*"
      (lambda ()
        (check-equal! (car (group-switch-new-action)) "Start an empty group"
                      "from a listing the new group starts empty")))
    (buffer-kill! "*zz-transient-listing*")
    (buffer-kill! "*zz-work*")))
