;;; switch-test.scm --- Cmd-up and Cmd-down walk a window's stack.
;;;
;;; A walk shows each buffer at once, with no prompt. The order holds
;;; while the walk lasts, so each step goes one sheet deeper, and the
;;; window's history is the one a single switch would leave.

(domain! 'testing)
(effects! '(read write))

(define (t--walk-setup!)
  (for-each (lambda (b) (buffer-create b))
            '("*zz-walk-a*" "*zz-walk-b*" "*zz-walk-c*" "*zz-walk-d*"))
  (run-command "window-walk-end")
  (switch-to-buffer-here! "*zz-walk-d*")
  (set-window-prev-buffers! (active-window) '("*zz-walk-c*" "*zz-walk-b*" "*zz-walk-a*")))

(deftest 'a-window-walk-goes-deeper-each-step
  "two steps down reach the third sheet, not the first again"
  (lambda ()
    (t--walk-setup!)
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-c*" "one step down")
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-b*" "a second step goes deeper")
    (check-equal! (window-prev-buffers (active-window))
                  '("*zz-walk-d*" "*zz-walk-c*" "*zz-walk-a*")
                  "the history is one switch from d to b")
    (window-walk! -1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-c*" "a step up comes back")))

(deftest 'a-new-walk-starts-on-top
  "after the walk ends, the next step reaches the buffer the walk left"
  (lambda ()
    (t--walk-setup!)
    (window-walk! 1 #t)
    (window-walk! 1 #t)
    (run-command "window-walk-end")
    (window-walk! 1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-d*" "back to where the walk began")))

(deftest 'a-walk-up-from-the-top-wraps
  "up from the top of the stack reaches its bottom"
  (lambda ()
    (t--walk-setup!)
    (window-walk! -1 #t)
    (check-equal! (window-buffer (active-window)) "*zz-walk-a*" "the oldest sheet")))

;;; C-x b tabs: All, Group, Window. A row is (NAME PATH MODIFIED MODE
;;; GROUP-ID GROUP-IDS GROUP); a recent file has #f in each field.

(define t--tab-rows
  '(("a.scm" "/a.scm" #f "scheme-mode" #f ("g1") #f)
    ("*chat:x:1*" #f #f "chat-mode" "g1" #f #f)
    ("b.md" "/b.md" #f "markdown-mode" #f ("g2") #f)
    ("/old.txt" #f #f #f #f #f #f)))

(deftest 'the-tab-row-marks-the-tab
  "the tabs name every view and mark the one you are on"
  (lambda ()
    (check-equal! (switch-tab-row 'group) '(("All" #f) ("Group" #t) ("Window" #f)) "group")
    (check-equal! (switch-tab-row 'all) '(("All" #t) ("Group" #f) ("Window" #f)) "all")))

(deftest 'the-side-arrows-wrap-the-tabs
  "right from the last tab reaches the first, and left from the first the last"
  (lambda ()
    (check-equal! (switch-tab-step 'group 1) 'window "right")
    (check-equal! (switch-tab-step 'window 1) 'all "right wraps")
    (check-equal! (switch-tab-step 'all -1) 'window "left wraps")))

(deftest 'a-tab-keeps-its-own-rows
  "Group keeps the group's buffers and chats, All keeps every row"
  (lambda ()
    (check-equal! (map car (switch-tab-rows 'group t--tab-rows "g1" #f)) '("a.scm" "*chat:x:1*") "group")
    (check-equal! (length (switch-tab-rows 'all t--tab-rows "g1" #f)) 4 "all")
    (check-equal! (switch-tab-rows 'window t--tab-rows "g1" #f) '() "no window, no history")
    (check-equal! (switch-tab-rows 'group t--tab-rows #f #f) '() "no group")))
