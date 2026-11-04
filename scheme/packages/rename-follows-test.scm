;;; rename-follows-test.scm --- a rename reaches every owner of name-keyed state.
;;;
;;; A buffer name IS the buffer handle here, so anything that points AT a
;;; buffer must hear a rename. Membership escapes this: it rides the buffer
;;; as 'group-id, and a stable group id never moves. A layout is the other
;;; direction — the group holds it and names the buffers in it — so the
;;; group must subscribe to rename-buffer!.
;;;
;;; These read deltas and restore what they touch: the suite also runs in a
;;; live editor, where the groups and the window ring are the person's own.

(domain! 'testing)
(effects! '(write))

(define (t--rf-kill! &rest names)
  (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names))

(define (t--rf-drop! &rest ids)
  (for-each (lambda (id) (when (group-record-by-id id) (group-record-delete! id))) ids))

;; A layout is a panes value: one pane showing NAME, in the buffer's mode.
(define (t--rf-layout-naming name)
  (panes-default-layout (list name) panes--buffer-mode))

;;; --- a group's saved layout ---------------------------------------------------

(deftest 'a-rename-follows-into-a-groups-saved-layout
  "the chat rename that stranded the browse group's second pane"
  (lambda ()
    (let ((id (group-record-create! "zzrf-layout"))
          (buf (test-buffer! "*zz-rf-chat*" "")))
      (group-record-update! id 'layout (t--rf-layout-naming "*zz-rf-chat*"))
      (check-true! (member "*zz-rf-chat*" (panes-buffers (group-layout id)))
                   "the layout names the buffer")

      (rename-buffer! buf "*zz-rf-chat-named*")

      (let ((saved (panes-buffers (group-layout id))))
        (check-true! (member "*zz-rf-chat-named*" saved)
                     "the saved layout names the buffer's new name")
        (check-false! (member "*zz-rf-chat*" saved)
                      "and nothing is left under the old one"))
      (t--rf-drop! id)
      (t--rf-kill! "*zz-rf-chat*" "*zz-rf-chat-named*"))))

(deftest 'a-rename-leaves-group-membership-alone
  "membership rides the buffer as a stable id, so it never needed a hook"
  (lambda ()
    (let ((id (group-record-create! "zzrf-members"))
          (buf (test-buffer! "*zz-rf-work*" "")))
      (buffer-add-group! buf id)
      (rename-buffer! buf "*zz-rf-work-named*")
      (check-true! (buffer-in-group? "*zz-rf-work-named*" id)
                   "the renamed buffer is still a member")
      (t--rf-drop! id)
      (t--rf-kill! "*zz-rf-work*" "*zz-rf-work-named*"))))

;;; --- the winner ring ----------------------------------------------------------

