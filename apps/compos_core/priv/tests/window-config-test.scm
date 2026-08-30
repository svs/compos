;;; window-config-test.scm --- the frame's group follows its windows, not its popups.

(domain! 'testing)
(effects! '(read write display))

(deftest 'a-popup-does-not-change-the-frame-group
  "a listing floating over the group's panes is a visit, not a place"
  (lambda ()
    (let ((id (group-record-create! "zz-popup-group"))
          (a "*zz-popup-member*")
          (w "*zz-popup-visitor*"))
      (buffer-create a)
      (buffer-create w)
      (buffer-add-group! a id)
      (delete-other-windows!)
      (switch-to-buffer! a)
      (check-equal! (frame-group) id "the frame stands in the member's group")
      (display-buffer-popup! w)
      (check-equal! (frame-group) id "the popup changes nothing")
      (check-equal! (group-current-recalculate!) id "and a recalculation agrees")
      (popup-close!)
      (check-equal! (frame-group) id "closing it changes nothing")
      (switch-to-buffer! "*scratch*")
      (buffer-kill! a)
      (buffer-kill! w)
      (group-record-delete! id))))

(deftest 'ibuffer-puts-the-frames-group-first
  "in a group, the members lead the table; without one the order stands"
  (lambda ()
    (let ((id (group-record-create! "zz-ibuffer-group"))
          (a "*zz-ib-member*")
          (b "*zz-ib-other*"))
      (buffer-create a)
      (buffer-create b)
      (buffer-add-group! a id)
      (check-equal! (ibuffer-promote-group (list b a) id) (list a b) "the member leads")
      (check-equal! (ibuffer-promote-group (list b a) #f) (list b a) "no group, no change")
      (buffer-kill! a)
      (buffer-kill! b)
      (group-record-delete! id))))
