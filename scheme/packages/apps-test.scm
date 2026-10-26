;;; apps-test.scm --- an app instance is a set, not a screen region.
;;;
;;; Two instances of the same app are open at once, and one of the first
;;; instance's buffers is not on screen. That is the case every
;;; position-based or name-prefix-based answer gets wrong, so it is the
;;; case these tests set up.

(domain! 'testing)
(effects! '(write display))

(define (t--apps-clean!)
  (for-each (lambda (b) (when (string-prefix? "*zz-app" b) (buffer-kill! b)))
            (buffer-list))
  (let ((stale (group-resolve-id "zz-app-destination")))
    (when stale (group-record-delete! stale))))

;; one window on *scratch*, our buffers gone, the group gone: before and after
(define (t--apps-with thunk)
  (t--apps-clean!)
  (switch-to-buffer-here! "*scratch*")
  (run-command "delete-other-windows")
  (let ((out (thunk)))
    (t--apps-clean!)
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

;; instance one: a home on screen and a detail that is not.
;; instance two: a home of the same app, on screen beside it.
(define (t--apps-two-instances!)
  (test-buffer! "*zz-app-one-home*" "one")
  (test-buffer! "*zz-app-one-detail*" "one detail")
  (test-buffer! "*zz-app-two-home*" "two")
  (app-claim! "*zz-app-one-home*" "zz-app:one" 'home)
  (app-claim! "*zz-app-one-detail*" "zz-app:one" 'detail)
  (app-claim! "*zz-app-two-home*" "zz-app:two" 'home)
  (switch-to-buffer-here! "*zz-app-one-home*")
  (split-window! 'h)
  (other-window!)
  (switch-to-buffer-here! "*zz-app-two-home*"))

(deftest 'app-windows-answers-one-instance
  "the sibling instance's window beside it is not this app's window"
  (lambda ()
    (t--apps-with
      (lambda ()
        (t--apps-two-instances!)
        (let ((wins (app-windows "zz-app:one")))
          (check-equal! (length wins) 1 "instance one has one window")
          (check-equal! (cadr (car wins)) "*zz-app-one-home*"
                        "and it is instance one's home"))))))

(deftest 'app-buffers-counts-the-hidden-one
  "the detail nobody is looking at still belongs to the instance"
  (lambda ()
    (t--apps-with
      (lambda ()
        (t--apps-two-instances!)
        (let ((bufs (app-buffers "zz-app:one")))
          (check-equal! (length bufs) 2 "the home and the hidden detail")
          (check-equal! (and (member "*zz-app-one-detail*" bufs) #t) #t
                        "the hidden detail is in the set"))))))

(deftest 'app-id-of-nothing-matches-nothing
  "an unclaimed buffer has no instance, and #f is not an instance"
  (lambda ()
    (t--apps-with
      (lambda ()
        (test-buffer! "*zz-app-plain*" "plain")
        (check-equal! (app-id "*zz-app-plain*") #f "an unclaimed buffer")
        (check-equal! (app-buffers #f) #f "#f enumerates nothing")
        (check-equal! (app-windows #f) #f "and matches no window")))))

(deftest 'app-move-buffers-takes-the-whole-instance
  "every buffer of the instance moves; the sibling instance stays put"
  (lambda ()
    (t--apps-with
      (lambda ()
        (t--apps-two-instances!)
        (let ((before (buffer-group "*zz-app-two-home*"))
              (moved (app-move-buffers! "zz-app:one" "zz-app-destination")))
          (check-equal! (length moved) 2 "both of instance one's buffers moved")
          (let ((gid (group-resolve-id "zz-app-destination")))
            (check-equal! (buffer-group "*zz-app-one-home*") gid
                          "the home is in the destination")
            (check-equal! (buffer-group "*zz-app-one-detail*") gid
                          "so is the hidden detail")
            (check-equal! (buffer-group "*zz-app-two-home*") before
                          "the sibling instance did not move")))))))

(deftest 'app-move-buffers-leaves-the-frame-alone
  "membership moved, not the user's view of it"
  (lambda ()
    (t--apps-with
      (lambda ()
        (t--apps-two-instances!)
        (let ((before (window-list))
              (here (active-window)))
          (app-move-buffers! "zz-app:one" "zz-app-destination")
          (check-equal! (window-list) before "the same windows show the same buffers")
          (check-equal! (active-window) here "and focus never left"))))))

(deftest 'app-layout-gives-its-roles-panes-before-what-was-on-screen
  "a full layout keeps the app's index and page; the screen fills what is left, the selected buffer first"
  (lambda ()
    (t--apps-with
      (lambda ()
        (let ((group (frame-local 'current-group)) (target (panes-current-layout)))
          (set-frame-local! 'current-group #f)
          (test-buffer! "*zz-app-work-a*" "a")
          (test-buffer! "*zz-app-work-b*" "b")
          (test-buffer! "*zz-app-three-home*" "home")
          (test-buffer! "*zz-app-three-detail*" "detail")
          (app-claim! "*zz-app-three-home*" "zz-app:three" 'home)
          (app-claim! "*zz-app-three-detail*" "zz-app:three" 'detail)
          (panes-tile! 'columns '("*zz-app-work-a*" "*zz-app-work-b*"))
          (panes-choose-layout! 'columns)
          (select-window! (window-showing "*zz-app-work-b*"))
          (app-layout! "zz-app:three")
          (check-equal! (map cadr (window-list))
                        '("*zz-app-work-b*" "*zz-app-three-home*" "*zz-app-three-detail*")
                        "three columns: the selected work buffer, the index, the page")
          (panes-choose-layout! target)
          (set-frame-local! 'current-group group))))))

(deftest 'app-open-leaves-the-window-you-are-in
  "from the middle pane, the listing and the detail take the other two panes; the selected window keeps its buffer"
  (lambda ()
    (t--apps-with
      (lambda ()
        (let ((group (frame-local 'current-group)) (target (panes-current-layout)))
          (set-frame-local! 'current-group #f)
          (test-buffer! "*zz-app-work-a*" "a")
          (test-buffer! "*zz-app-work-b*" "b")
          (test-buffer! "*zz-app-work-c*" "c")
          (test-buffer! "*zz-app-open-home*" "home")
          (test-buffer! "*zz-app-open-detail*" "detail")
          (panes-tile! 'columns '("*zz-app-work-a*" "*zz-app-work-b*" "*zz-app-work-c*"))
          (panes-choose-layout! 'columns)
          (let ((b (window-showing "*zz-app-work-b*")))
            (select-window! b)
            (app-open! "*zz-app-open-home*" "*zz-app-open-detail*")
            (check-equal! (window-buffer b) "*zz-app-work-b*" "the window you were in keeps its buffer")
            (check-equal! (map cadr (window-list))
                          '("*zz-app-open-home*" "*zz-app-work-b*" "*zz-app-open-detail*")
                          "the listing takes the left free pane and the detail the right one")
            (check-equal! (window-buffer (active-window)) "*zz-app-open-home*" "the listing has the focus")
            (check-equal! (panes-current-layout) 'columns "the layout is the one you chose"))
          (panes-choose-layout! target)
          (set-frame-local! 'current-group group))))))
