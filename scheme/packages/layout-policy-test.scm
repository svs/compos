;;; layout-policy-test.scm --- measured group layout and replacement journeys.
(domain! 'testing)
(effects! '(write))
(tests-need-a-disposable-editor! "creates groups and measures each layout transition")

(define *lp-trace* '())
(define (lp-snapshot! step)
  (let ((state (list 'step step 'target (layout-target)
                     'focus (window-buffer (active-window))
                     'rects (map cdr (window-rects)))))
    (set! *lp-trace* (append *lp-trace* (list state)))
    state))
(define (lp-buffers) (map cadr (window-list)))
(define (lp-buffer! name)
  (let ((buf (string-append "zz-lp-" name)))
    (test-buffer! buf "012345678901234567890123456789\n")
    (when (frame-group) (buffer-add-group! buf (frame-group)))
    buf))
(define (lp-group! name)
  (group-create-and-enter! (string-append "zz-lp-" name) '() #f))
(define (lp-clean!)
  ;; a journey starts from nothing of the last one: group-create-and-enter!
  ;; refuses a name that exists, and a member the last journey left in
  ;; the group would fill a pane of this one
  (when (minibuffer-state) (minibuffer-cancel!))
  (when (float-open?) (float-close!))
  (delete-other-windows!)
  (window-hidden-clear!)
  (switch-to-buffer-here! "*scratch*")
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (for-each (lambda (b)
              (when (or (string-prefix? "zz-lp-" b)
                        (string-prefix? "*chat:zz-lp-" b)
                        (string-prefix? "*scratch:zz-lp-" b)
                        ;; group-switch tests reuse group ids, so a chat
                        ;; one of them left can pass for this group's
                        (string-prefix? "*chat:zz-sw-" b)
                        (string-prefix? "*chat:zzsw-" b))
                (buffer-kill! b)))
            (buffer-list))
  (for-each (lambda (name) (when (group-record-by-name name) (group-record-delete! name)))
            '("zz-lp-group" "zz-lp-other" "zz-lp-away")))
(define (lp-start!)
  (set! *lp-trace* '())
  (layout-target-free!)
  (set-frame-local! 'pinned-group #f)
  (lp-clean!)
  ;; the first buffer founds the group, so the default layout shows it and
  ;; makes no chat: a chat made and killed here kept working after the
  ;; journey started. These journeys start with exactly one eligible
  ;; buffer; a chat test asks for the chat itself.
  (test-buffer! "zz-lp-a" "012345678901234567890123456789\n")
  (group-create-and-enter! "zz-lp-group" '("zz-lp-a") #f)
  (lp-snapshot! 'new-group)
  (switch-to-buffer-here! "zz-lp-a")
  (delete-other-windows!)
  (lp-snapshot! 'one-buffer))
;; The editor runs window-configuration-changed! from a detached task
;; after a window change (Editor, config_hook). Its reflow then races the
;; journey's own steps, so the same file went red on different names from
;; run to run. A journey takes the reflow out of the hook and calls
;; layout-target-on-change! itself where it means it; the hook gets the
;; reflow back when the journey ends.
(define (lp-journey thunk)
  (lambda ()
    (remove-hook! 'window-configuration-change-hook 'layout-target-on-change!)
    (thunk)
    (add-hook! 'window-configuration-change-hook 'layout-target-on-change!)))

(define (lp-rect! buf x y width height)
  (let ((r (assoc buf (map cdr (window-rects)))))
    (check-true! (and r #t) (string-append buf " is visible"))
    (when r
      (for-each (lambda (pair)
                  (check-true! (< (abs (- (car pair) (cadr pair))) 0.001)
                    (string-append buf " geometry " (number->string (car pair)))))
                (list (list (nth 1 r) x) (list (nth 2 r) y)
                      (list (nth 3 r) width) (list (nth 4 r) height))))))

(deftest 'layout-target-starts-with-one-buffer-and-fills-to-its-capacity
  "a rows target records one full pane, then two halves, and stops there"
  (lp-journey (lambda ()
    (lp-start!)
    (run-command "window-layout-rows")
    (lp-snapshot! 'one-row-target)
    (check-equal! (layout-target) 'rows "a one-buffer choice is a target")
    (lp-rect! "zz-lp-a" 0 0 1 1)
    (lp-buffer! "b")
    (switch-to-buffer! "zz-lp-b")
    (lp-snapshot! 'two-buffers)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b") "new work fills the vacancy")
    (lp-rect! "zz-lp-a" 0 0 1 0.5)
    (lp-rect! "zz-lp-b" 0 0.5 1 0.5)
    (lp-buffer! "c")
    (switch-to-buffer! "zz-lp-c")
    (lp-snapshot! 'a-third-buffer)
    (check-equal! (length (lp-buffers)) 2 "rows holds two panes and grows no further")
    (check-equal! (current-buffer) "zz-lp-c" "the new work is on screen"))))

(deftest 'relayout-preserves-pane-order-and-focus
  "changing focus before relayout does not move that buffer to the first slot"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (select-window! (window-showing "zz-lp-b"))
    (lp-snapshot! 'columns-b-focused)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-c") "stable spatial order")
    (run-command "window-layout-halves")
    (lp-snapshot! 'halves-b-focused)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b") "a smaller layout keeps the first slots")
    (check-equal! (current-buffer) "zz-lp-b" "focus survives")
    (lp-rect! "zz-lp-a" 0 0 0.5 1)
    (lp-rect! "zz-lp-b" 0.5 0 0.5 1))))

(deftest 'fixed-target-fills-vacancies-then-replaces-the-selected-slot
  "two-pane opens into capacity, then replaces in place without importing foreign buffers"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b")
    (run-command "window-layout-two-pane")
    (lp-snapshot! 'two-pane)
    (lp-rect! "zz-lp-a" 0 0 (/ 2 3) 1)
    (lp-rect! "zz-lp-b" (/ 2 3) 0 (/ 1 3) 1)
    (select-window! (window-showing "zz-lp-b"))
    (lp-buffer! "c")
    (switch-to-buffer! "zz-lp-c")
    (lp-snapshot! 'replace-right)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c") "only selected slot changes")
    (lp-rect! "zz-lp-c" (/ 2 3) 0 (/ 1 3) 1)
    (switch-to-buffer! "zz-lp-a")
    (lp-snapshot! 'select-already-visible)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c") "opening visible work does not duplicate it")
    (check-equal! (current-buffer) "zz-lp-a" "existing pane receives focus"))))

(deftest 'group-refill-uses-hidden-members-before-chat-and-keeps-geometry
  "a pane with no usable history falls to hidden group work before a chat or scratch"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (select-window! (window-showing "zz-lp-b"))
    (set-window-prev-buffers! (active-window) '())
    (lp-snapshot! 'before-kill)
    (buffer-kill! "zz-lp-b")
    (lp-snapshot! 'after-kill)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c") "hidden member precedes chat fallback")
    (check-equal! (current-buffer) "zz-lp-c" "focus stays in the repaired pane")
    (lp-rect! "zz-lp-c" (/ 2 3) 0 (/ 1 3) 1))))

(deftest 'group-switch-restores-its-own-target
  "a new group has no inherited target and returning restores the previous target"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b")
    (run-command "window-layout-two-pane")
    (lp-snapshot! 'first-group)
    (lp-group! "other")
    (lp-snapshot! 'second-group)
    (check-equal! (layout-target) window-layout-default
                  "a new group takes the default target, not the old group's")
    (switch-to-group! "zz-lp-group")
    (lp-snapshot! 'first-group-restored)
    (check-equal! (layout-target) 'two-pane "the old group's target returns")
    (lp-rect! "zz-lp-a" 0 0 (/ 2 3) 1)
    (lp-rect! "zz-lp-b" (/ 2 3) 0 (/ 1 3) 1))))

(deftest 'relayout-preserves-points-of-duplicate-buffer-windows
  "two views of one buffer keep separate reading positions through relayout"
  (lp-journey (lambda ()
    (lp-start!)
    (tile-windows! 'rows '("zz-lp-a" "zz-lp-a"))
    (let ((ids (map car (window-list))))
      (window-set-point! (car ids) 3)
      (window-set-point! (cadr ids) 19))
    (lp-snapshot! 'two-views)
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-a"))
    (lp-snapshot! 'two-views-relayout)
    (check-equal! (map (lambda (row) (window-point (car row))) (window-list))
                  '(3 19) "each view retains its own point"))))

(deftest 'fixed-target-underfills-and-grows-without-placeholder-panes
  "a two-pane target with only one work buffer stays full-frame until another opens"
  (lp-journey (lambda ()
    (lp-start!)
    (run-command "window-layout-two-pane")
    (lp-snapshot! 'underfilled-target)
    (check-equal! (layout-target) 'two-pane "target is remembered")
    (check-equal! (lp-buffers) '("zz-lp-a") "no automatic chat or scratch pane")
    (lp-rect! "zz-lp-a" 0 0 1 1)
    (lp-buffer! "b")
    (switch-to-buffer! "zz-lp-b")
    (lp-snapshot! 'target-filled)
    (lp-rect! "zz-lp-a" 0 0 (/ 2 3) 1)
    (lp-rect! "zz-lp-b" (/ 2 3) 0 (/ 1 3) 1))))

(deftest 'smaller-target-keeps-focus-and-the-first-surviving-slots
  "three-column capacity retains the focused fourth buffer without shuffling the first two"
  (lp-journey (lambda ()
    (lp-start!)
    (for-each lp-buffer! '("b" "c" "d"))
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-d"))
    (select-window! (window-showing "zz-lp-d"))
    (lp-snapshot! 'three-panes)
    (run-command "window-layout-columns")
    (lp-snapshot! 'three-column-capacity)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-d") "capacity retains focus")
    (check-equal! (current-buffer) "zz-lp-d" "selected work stays selected")
    (lp-rect! "zz-lp-a" 0 0 (/ 1 3) 1)
    (lp-rect! "zz-lp-b" (/ 1 3) 0 (/ 1 3) 1)
    (lp-rect! "zz-lp-d" (/ 2 3) 0 (/ 1 3) 1))))

(deftest 'target-candidates-exclude-foreign-transient-and-background-only-buffers
  "layout filling and kill history use eligible members of the current group"
  (lp-journey (lambda ()
    (lp-start!)
    (let ((group (frame-group)))
      (lp-buffer! "foreign")
      (buffer-remove-group! "zz-lp-foreign" group)
      (lp-buffer! "background") (buffer-context-only! "zz-lp-background")
      (lp-buffer! "transient") (buffer-set-local! "zz-lp-transient" 'special #t)
      (lp-buffer! "b") (lp-buffer! "c")
      (run-command "window-layout-two-pane")
      (lp-snapshot! 'filtered-layout)
      (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b") "only normal group work fills")
      (let ((win (window-showing "zz-lp-b")))
        (set-window-prev-buffers! win '("zz-lp-foreign" "zz-lp-background" "zz-lp-transient"))
        (buffer-kill! "zz-lp-b"))
      (lp-snapshot! 'filtered-history)
      (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c") "history uses the same eligibility")
      (check-equal! (frame-group) group "the group stays sealed")))))

(deftest 'background-buffer-context-does-not-grow-a-target-layout
  "logical switches stay headless even when their current buffer is also visible"
  (lp-journey (lambda ()
    (lp-start!)
    (run-command "window-layout-rows")
    (lp-buffer! "b")
    (with-current-buffer "zz-lp-a"
      (lambda ()
        (switch-to-buffer! "zz-lp-b")
        (check-equal! (current-buffer) "zz-lp-b" "logical context changes")))
    (lp-snapshot! 'background-open)
    (check-equal! (lp-buffers) '("zz-lp-a") "window does not change")
    (lp-rect! "zz-lp-a" 0 0 1 1))))

(deftest 'passive-results-replace-the-oldest-other-pane-and-quit-restores-it
  "result display preserves focus and quitting reverses its replacement"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c") (lp-buffer! "result")
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (layout-target-set! 'columns)
    ;; c is older than b; a is selected and cannot be used.
    (select-window! (window-showing "zz-lp-c"))
    (select-window! (window-showing "zz-lp-b"))
    (select-window! (window-showing "zz-lp-a"))
    (let* ((c-win (window-showing "zz-lp-c"))
           (win (display-buffer "zz-lp-result")))
      (lp-snapshot! 'passive-result)
      (check-equal! (current-buffer) "zz-lp-a" "display takes no focus")
      (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-result") "oldest other pane is reused")
      (check-false! (equal? win c-win) "the result is a new window")
      (check-equal! (assoc c-win (window-hidden-list)) (list c-win "zz-lp-c")
                    "the pane's window is hidden with its buffer")
      (select-window! win)
      (run-command "quit-window")
      (lp-snapshot! 'result-quit)
      (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-c") "quitting restores the borrowed pane")
      (check-equal! (window-showing "zz-lp-c") c-win "with the window that had it")
      (check-false! (assoc win (window-hidden-list)) "the result's window is gone")
      (lp-rect! "zz-lp-c" (/ 2 3) 0 (/ 1 3) 1)))))

(deftest 'selected-result-quit-restores-the-buffer-under-it
  "a user-opened result remembers the selected pane it replaced"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c") (lp-buffer! "result")
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (layout-target-set! 'columns)
    (select-window! (window-showing "zz-lp-a"))
    (switch-to-buffer! "zz-lp-result")
    (let ((win (active-window)))
      (check-equal! (current-buffer) "zz-lp-result" "the result is selected")
      (check-equal! (car (window-restore win)) 'other "the editor records the pane replacement")
      (check-equal! (cadr (window-restore win)) "zz-lp-a" "the editor remembers the underlying buffer")
      (run-command "quit-window")
      (check-equal! (current-buffer) "zz-lp-a" "q restores the buffer under the result")
      (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-c") "no unrelated buffer is duplicated")))))

(deftest 'target-reflows-after-pane-close-without-reopening-hidden-work
  "closing a pane reduces occupancy but keeps the target for the next open"
  (lp-journey (lambda ()
    (lp-start!)
    (run-command "window-layout-columns")
    (lp-buffer! "b") (switch-to-buffer! "zz-lp-b")
    (lp-buffer! "c") (switch-to-buffer! "zz-lp-c")
    (select-window! (window-showing "zz-lp-b"))
    (delete-window!)
    (layout-target-on-change!)
    (lp-snapshot! 'middle-pane-closed)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c") "the hidden buffer stays hidden")
    (check-equal! (layout-target) 'columns "closing does not drop the target")
    ;; two buffers in a three-column layout share the frame evenly
    (lp-rect! "zz-lp-a" 0 0 0.5 1)
    (lp-rect! "zz-lp-c" 0.5 0 0.5 1)
    (switch-to-buffer! "zz-lp-b")
    (lp-snapshot! 'hidden-work-reopened)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-c" "zz-lp-b") "reopened work fills the vacancy"))))

(deftest 'a-full-layout-does-not-grow-a-pane-for-new-work
  "a layout holds a fixed number of panes; new work takes a pane instead of adding one"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (select-window! (window-showing "zz-lp-b"))
    (lp-buffer! "c") (switch-to-buffer! "zz-lp-c")
    (lp-snapshot! 'two-pane-stays-two)
    (check-equal! (length (window-list)) 2 "two-pane holds two panes")
    (lp-rect! "zz-lp-a" 0 0 window-layout-main-ratio 1)
    (lp-rect! "zz-lp-c" window-layout-main-ratio 0 (- 1 window-layout-main-ratio) 1)
    (check-equal! (current-buffer) "zz-lp-c" "new work receives focus"))))

(deftest 'a-layout-scrolls-along-the-window-ring
  "the layouts go on for ever: forward shows the next window, backward comes back"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (let ((c-win (window-new-hidden! "zz-lp-c"))
          (a-win (window-showing "zz-lp-a")))
      (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b") "the run starts at the panes")
      (run-command "layout-forward")
      (lp-snapshot! 'scrolled-forward)
      (check-equal! (layout-target-visible-buffers) '("zz-lp-b" "zz-lp-c") "forward moves the run one window along")
      (check-equal! (window-showing "zz-lp-c") c-win "the hidden window itself comes in, not a new one")
      (check-equal! (assoc a-win (window-hidden-list)) (list a-win "zz-lp-a") "the window that left is hidden")
      (run-command "layout-backward")
      (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b") "backward returns where forward came from")
      (check-equal! (window-showing "zz-lp-a") a-win "with the same window")
      (run-command "layout-backward")
      (check-equal! (layout-target-visible-buffers) '("zz-lp-c" "zz-lp-a") "the ring is cyclic: backward past the front arrives at the back")))))

(deftest 'a-buffer-with-no-window-is-not-in-the-ring
  "the ring holds windows: a buffer that no window shows is not a stop"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (window-hidden-clear!)
    (run-command "layout-forward")
    (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b") "no hidden window: the run stays"))))

(deftest 'a-walk-meets-the-hidden-windows-most-recent-first
  "forward from the panes brings the hidden window used last"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c") (lp-buffer! "d")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (window-new-hidden! "zz-lp-c")
    (window-new-hidden! "zz-lp-d")
    (run-command "layout-forward")
    (check-equal! (layout-target-visible-buffers) '("zz-lp-b" "zz-lp-d") "d was hidden last, so d comes first"))))

(deftest 'a-kill-takes-a-hidden-window-out-of-the-ring
  "a hidden window whose buffer dies, with nothing in its past, goes; the walk passes it"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c") (lp-buffer! "d") (lp-buffer! "e")
    (tile-visible-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (layout-target-set! 'columns)
    (window-new-hidden! "zz-lp-d")
    (window-new-hidden! "zz-lp-e")
    (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-c")
                  "three columns to start")
    (buffer-kill! "zz-lp-d")
    (check-false! (member "zz-lp-d" (map cadr (window-hidden-list))) "the window on d is gone")
    (run-command "layout-forward")
    (lp-snapshot! 'scrolled-past-where-a-dead-window-was)
    (check-equal! (length (window-list)) 3 "still three panes, not two")
    (check-equal! (layout-target-visible-buffers) '("zz-lp-b" "zz-lp-c" "zz-lp-e")
                  "the run reaches the next LIVE window"))))

(deftest 'a-scroll-with-no-hidden-window-left-declines-instead-of-shrinking
  "a kill can leave the ring no longer than the layout; a scroll then says so rather than tiling short"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c") (lp-buffer! "d")
    (tile-visible-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (layout-target-set! 'columns)
    (window-new-hidden! "zz-lp-d")
    (buffer-kill! "zz-lp-d")
    (run-command "layout-forward")
    (check-equal! (length (window-list)) 3 "the three columns stand unchanged")
    (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b" "zz-lp-c")
                  "the run never moved"))))

(deftest 'a-smaller-layout-hides-windows-and-a-larger-one-shows-them-again
  "columns to single hides two windows; single to columns shows the same windows"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-visible-windows! 'columns '("zz-lp-a" "zz-lp-b" "zz-lp-c"))
    (let ((b-win (window-showing "zz-lp-b")) (c-win (window-showing "zz-lp-c")))
      (select-window! (window-showing "zz-lp-a"))
      (tile-visible-windows! 'single)
      (check-equal! (length (window-list)) 1 "single shows one pane")
      (check-equal! (length (window-hidden-list)) 2 "the other two windows are hidden")
      (tile-visible-windows! 'columns)
      (check-equal! (window-showing "zz-lp-b") b-win "b's window comes back")
      (check-equal! (window-showing "zz-lp-c") c-win "c's window comes back")
      (check-equal! (window-hidden-list) '() "no window stays hidden")))))

(deftest 'a-group-keeps-its-hidden-windows-across-a-switch
  "hidden windows belong to the group: another group does not see them, and a switch back restores them"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b") (lp-buffer! "c")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (window-new-hidden! "zz-lp-c")
    (lp-group! "other")
    (check-equal! (window-hidden-list) '() "the new group has no hidden windows")
    (switch-to-group! "zz-lp-group")
    (check-equal! (map cadr (window-hidden-list)) '("zz-lp-c")
                  "the switch back restores the group's hidden window"))))

(deftest 'a-foreign-display-takes-a-pane-and-the-frame-leaves-the-group
  "the ruling of 2026-09-19: nothing floats; a foreign display takes the window chain, and a pane that shows it takes the frame out of the group"
  (lp-journey (lambda ()
    (lp-start!)
    (lp-buffer! "b")
    (run-command "window-layout-two-pane")
    (let ((group (frame-group)))
      (lp-buffer! "foreign")
      (buffer-remove-group! "zz-lp-foreign" group)
      (let ((win (display-buffer "zz-lp-foreign")))
        (lp-snapshot! 'foreign-shown)
        (check-false! (float-open?) "nothing floats")
        (check-equal! (current-buffer) "zz-lp-a" "a display takes no focus")
        (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-foreign")
                      "the other pane shows it")
        (check-equal! (layout-target) 'two-pane "the target stays")
        (check-equal! (car (window-restore win)) 'other "the display records the pane it took")
        (check-equal! (cadr (window-restore win)) "zz-lp-b" "and the buffer under it")
        (check-false! (frame-group) "a pane that shows a foreign buffer takes the frame out of the group"))))))

(deftest 'a-restored-target-keeps-its-first-slot
  "new window IDs after group restoration do not invert the panes"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (let ((home (frame-group)))
      (lp-group! "away")
      (switch-to-group! home)
      (lp-snapshot! 'restored-two-pane)
      (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b") "logical slots survive restoration")
      (lp-rect! "zz-lp-a" 0 0 window-layout-main-ratio 1)))))

(deftest 'duplicate-view-focus-survives-relayout
  "the selected second view remains selected at its own point"
  (lp-journey (lambda ()
    (lp-start!)
    (tile-windows! 'rows '("zz-lp-a" "zz-lp-a"))
    (let ((rows (window-list)))
      (window-set-point! (car (car rows)) 3)
      (window-set-point! (car (cadr rows)) 19)
      (select-window! (car (cadr rows))))
    (run-command "window-layout-columns")
    (lp-snapshot! 'second-view-selected)
    (check-equal! (window-point (active-window)) 19 "focus follows the second occurrence")
    (check-equal! (active-window) (car (cadr (window-list))) "second view stays selected"))))

(deftest 'active-target-persists-without-a-group-switch
  "desktop state includes a newly selected target and rebuilds its runtime slots"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (tile-visible-windows! 'two-pane '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (let ((saved (layout-targets-state)))
      (layout-target-set! #f)
      (layout-targets-restore! saved)
      (check-equal! (layout-target) 'two-pane "active choice survives the snapshot")
      (lp-buffer! "c") (switch-to-buffer! "zz-lp-c")
      (lp-snapshot! 'persisted-target-grown)
      (check-equal! (length (window-list)) 2 "the restored target keeps its capacity")))))

(deftest 'an-explicit-layout-replaces-the-previous-target
  "a layout command becomes the frame's target and lays the strip again"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (run-command "window-layout-rows")
    (check-equal! (layout-target) 'rows "the command is the target")
    (run-command "window-layout-columns")
    (lp-snapshot! 'columns-target)
    (check-equal! (layout-target) 'columns "the later choice wins")
    (check-equal! (length (window-list)) 2 "columns shows what the frame has"))))

(deftest 'stale-slot-cache-cannot-reverse-the-displayed-order
  "a restored or manually reordered tree outranks older cached window IDs"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'two-pane)
    (set-frame-local! 'layout-slots (reverse (window-list)))
    (check-equal! (layout-target-visible-buffers) '("zz-lp-a" "zz-lp-b") "the actual tree is authoritative")
    (run-command "window-layout-two-pane")
    (lp-snapshot! 'stale-order-reconciled)
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b") "relayout does not reverse panes")
    (lp-rect! "zz-lp-a" 0 0 (/ 2 3) 1)
    (lp-rect! "zz-lp-b" (/ 2 3) 0 (/ 1 3) 1))))

(deftest 'a-group-chat-joins-the-frame-instead-of-collapsing-it
  "opening a group's chat keeps the panes already on the frame and adds one"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (tile-windows! 'columns '("zz-lp-a" "zz-lp-b"))
    (check-equal! (lp-buffers) '("zz-lp-a" "zz-lp-b") "two panes before the chat")
    (let ((chat (group-chat (frame-group))))
      (group-chat-buffer-show! chat)
      (lp-snapshot! 'chat-opened)
      ;; the regression: this collapsed the frame to one window and split
      ;; it, so the second pane -- a mail preview, a companion doc -- was
      ;; gone and the group had two buffers to tile instead of three
      (check-equal! (length (lp-buffers)) 3 "the chat is a third pane")
      (check-true! (and (member "zz-lp-a" (lp-buffers)) #t) "the first pane stayed")
      (check-true! (and (member "zz-lp-b" (lp-buffers)) #t) "and so did the second")
      (check-equal! (current-buffer) chat "the chat takes the focus")
      (buffer-kill! chat)))))

(deftest 'a-group-chat-arranges-by-the-frames-chosen-layout
  "a C-x l pick survives a pane opening: the width decides only for a frame that never chose"
  (lp-journey (lambda ()
    (lp-start!) (lp-buffer! "b")
    (tile-visible-windows! 'columns '("zz-lp-a" "zz-lp-b"))
    (layout-target-set! 'columns)
    (let ((chat (group-chat (frame-group))))
      (group-chat-buffer-show! chat)
      (lp-snapshot! 'chat-opened)
      (check-equal! (layout-target) 'columns "the frame keeps the layout it was given")
      (check-equal! (length (lp-buffers)) 3 "and the chat is a third pane")
      ;; three equal columns, because the frame chose columns
      (lp-rect! "zz-lp-a" 0 0 (/ 1 3) 1)
      (lp-rect! "zz-lp-b" (/ 1 3) 0 (/ 1 3) 1)
      (lp-rect! chat (/ 2 3) 0 (/ 1 3) 1)
      (buffer-kill! chat)
      (layout-target-set! #f)))))
