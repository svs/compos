;;; display-buffer-test.scm --- where a buffer goes: the action chain.
;;;
;;; display-buffer tries the rule for the name, the base action, then the
;;; fallback: reuse-window, mode-window, pop-up-window, use-some-window,
;;; same-window.
;;; The thresholds decide a split; the tests set them, so the frame's
;;; size does not.

(domain! 'testing)
(effects! '(write display))

(define t--db-dir (string-append (compos-home) "/display-test"))

(define (t--db-file name text)
  (let ((p (string-append t--db-dir "/" name)))
    (write-file! p text)
    p))

;; one window on *scratch*, the stock rules, the thresholds of the test;
;; everything put back after
(define (t--db-with thresholds thunk)
  (make-directory! t--db-dir)
  (unwind-protect
    (lambda ()
      (with-stubs (list (list '*display-buffer-alist* *display-buffer-alist*)
                        (list '*display-buffer-base-action* '())
                        (list '*display-buffer-fallback-action* *display-buffer-fallback-action*)
                        (list 'split-height-threshold (car thresholds))
                        (list 'split-width-threshold (cadr thresholds)))
        (lambda ()
          (layout-target-set! #f)
          (when (float-open?) (float-close!))
          (set-frame-local! 'pinned-group #f)
          (set-frame-local! 'current-group #f)
          (switch-to-buffer-here! "*scratch*")
          (run-command "delete-other-windows")
          (unwind-protect thunk
            (lambda ()
              (for-each (lambda (b)
                          (when (or (string-prefix? "*zz-db" b) (string-prefix? t--db-dir b))
                            (buffer-kill! b)))
                        (buffer-list)))))))
    (lambda ()
      (set! *peek-recent* '())
      (switch-to-buffer! "*scratch*")
      (run-command "delete-other-windows"))))

(define t--db-wide '(1000 1))     ; beside always, below never
(define t--db-tall '(1 1000))     ; below always
(define t--db-never '(1000 1000)) ; no split by size

(define (t--db-rect win) (assoc win (window-rects)))

(deftest 'a-buffer-with-no-rule-takes-the-fallback-chain
  "the chain is reuse, mode, pop-up, use-some, same; a rule's action goes first"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (check-equal! (display-buffer-actions-for "*zz-db-none*")
                      '(reuse-window mode-window pop-up-window use-some-window same-window)
                      "the fallback")
        (add-display-rule! "*zz-db-ruled*" 'same-window)
        (check-equal! (car (display-buffer-actions-for "*zz-db-ruled*")) 'same-window
                      "a name rule first")
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*" '(category preview)))
                      'reuse-window "the preview category first")
        (set! *display-buffer-base-action* '(same-window))
        (check-equal! (car (display-buffer-actions-for "*zz-db-none*")) 'same-window
                      "with no rule the base action comes first")
        (check-equal! (cadr (display-buffer-actions-for "*zz-db-none*")) 'reuse-window
                      "and the fallback after it")
        (check-equal! (car (display-buffer-actions-for "*zz-db-ruled*")) 'same-window
                      "a rule still comes before the base action")))))

;; One window per mode: the second buffer of a mode takes the window the
;; first one holds, instead of splitting a pane of its own for it.
(deftest 'a-second-buffer-of-a-mode-takes-the-window-the-first-one-holds
  "mode-window keeps a group to one window per mode"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (with-current-buffer "*zz-db-a*" (lambda () (set-mode! "text-mode")))
        (with-current-buffer "*zz-db-b*" (lambda () (set-mode! "text-mode")))
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (window-mode first) "text-mode" "the mode came with it")
          (check-equal! (display-buffer "*zz-db-b*") first
                        "the same mode took the same window")
          (check-equal! (window-buffer first) "*zz-db-b*" "and replaced it there")
          (buffer-create "*zz-db-c*")
          (with-current-buffer "*zz-db-c*" (lambda () (set-mode! "fundamental-mode")))
          (check-false! (equal? (display-buffer "*zz-db-c*") first)
                        "another mode does not take that window"))))))

;; A target layout is no licence for two panes of one mode: with a column
;; still free, the second buffer of a mode takes the first one's pane.
(deftest 'a-target-layout-does-not-give-one-mode-two-panes
  "one window per mode outranks the target's spare capacity"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (with-current-buffer "*zz-db-a*" (lambda () (set-mode! "text-mode")))
        (with-current-buffer "*zz-db-b*" (lambda () (set-mode! "text-mode")))
        (layout-target-set! 'columns)
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (display-buffer "*zz-db-b*") first
                        "the second buffer of the mode took the first one's pane")
          (check-equal! (length (window-list)) 2 "the free column stayed free"))
        (layout-target-set! #f)))))

(deftest 'pop-up-window-splits-beside-and-selects-nothing
  "one wide window: the buffer takes a new window beside it; point stays"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (active-window) me "the selected window did not change")
            (check-equal! (current-buffer) "*scratch*" "nor the current buffer")
            (check-equal! (window-buffer win) "*zz-db-a*" "the new window shows it")
            (check-true! (not (equal? win me)) "and it is not the selected one")
            (check-equal! (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me)) "beside: the same top")
            (check-true! (> (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me))) "to the right")
            (check-equal! (car (window-restore win)) 'window "noted as a window the display made")))))))

(deftest 'pop-up-window-splits-below-when-the-window-is-tall
  "the height threshold wins over the width one, as in Emacs"
  (lambda ()
    (t--db-with t--db-tall
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-equal! (nth 2 (t--db-rect win)) (nth 2 (t--db-rect me)) "below: the same left")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "under it")))))))

(deftest 'the-sole-window-splits-below-whatever-its-size
  "no threshold is met, but a frame with one window still gets a second"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "two windows")
            (check-true! (> (nth 3 (t--db-rect win)) (nth 3 (t--db-rect me))) "the new one below")))))))

(deftest 'reuse-window-finds-the-window-that-shows-it
  "a second display of the same buffer makes no window"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (let ((first (display-buffer "*zz-db-a*")))
          (check-equal! (display-buffer "*zz-db-a*") first "the same window")
          (check-equal! (length (window-list)) 2 "still two"))))))

(deftest 'use-some-window-takes-another-window-when-no-split-fits
  "two windows, no room to split: the other window shows it, and quit puts back what it showed"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (let ((other (display-buffer "*zz-db-a*")))
            (check-equal! (length (window-list)) 2 "the sole window split once")
            (let ((win (display-buffer "*zz-db-b*")))
              (check-equal! win other "the other window is used")
              (check-equal! (length (window-list)) 2 "no third window")
              (check-equal! (window-buffer other) "*zz-db-b*" "and shows the second buffer")
              (check-equal! (active-window) me "point stays")
              (check-equal! (car (window-restore win)) 'other "noted as a window the display took")
              (check-equal! (cadr (window-restore win)) "*zz-db-a*" "with what it showed")
              (window-quit-restore! win)
              (check-equal! (window-buffer other) "*zz-db-a*" "quit puts the first buffer back"))))))))

(deftest 'a-target-layout-fills-capacity-before-replacing
  "an explicit two-pane target grows once, then uses the other pane"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((home (current-buffer)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (layout-target-set! 'two-pane)
          (display-buffer "*zz-db-a*")
          (check-equal! (length (window-list)) 2 "underfilled target grows")
          (check-equal! (current-buffer) home "passive display preserves focus")
          (let* ((other (window-showing "*zz-db-a*"))
                 (win (display-buffer "*zz-db-b*")))
            (check-equal! (window-buffer win) "*zz-db-b*" "full target shows the result")
            (check-false! (window-showing "*zz-db-a*") "the result takes the other pane")
            (check-true! (and (assoc other (window-hidden-list)) #t)
                         "the other pane's window is hidden, not changed")
            (check-equal! (length (window-list)) 2 "capacity is respected")
            (check-equal! (current-buffer) home "replacement preserves focus"))
          (layout-target-set! #f)
          (check-equal! (caddr (display-buffer-actions-for "*zz-db-b*")) 'pop-up-window
                        "free restores sensible splitting"))))))

(deftest 'a-same-window-rule-shows-it-here
  "a same-window rule shows the buffer in the selected window"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (set! *display-buffer-alist* (list (list "*zz-db" 'same-window '())))
        (buffer-create "*zz-db-a*")
        (let ((me (active-window)))
          (check-equal! (display-buffer "*zz-db-a*") me "a same-window rule shows it here")
          (check-equal! (current-buffer) "*zz-db-a*" "and it is current")
          (check-equal! (length (window-list)) 1 "no split"))))))

(deftest 'pop-to-buffer-shows-and-selects
  "display-buffer selects nothing; pop-to-buffer selects the window it used"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (let ((win (pop-to-buffer "*zz-db-a*")))
            (check-equal! (active-window) win "the new window is selected")
            (check-true! (not (equal? win me)) "and it is another window")
            (check-equal! (current-buffer) "*zz-db-a*" "the buffer is current")))))))

(deftest 'quit-window-deletes-the-window-the-display-made
  "q in a popped-up listing closes its window and kills it; the layout is what it was"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (pop-to-buffer "*zz-db-a*")
          (run-command "quit-window")
          (check-equal! (length (window-list)) 1 "one window again")
          (check-equal! (active-window) me "the one the reader had")
          (check-false! (buffer-exists? "*zz-db-a*") "the listing is killed"))))))

(deftest 'display-buffer-other-window-never-covers-the-selected-window
  "with two windows and no room, the other window is used, never this one"
  (lambda ()
    (t--db-with t--db-never
      (lambda ()
        (let ((me (active-window)))
          (buffer-create "*zz-db-a*")
          (buffer-create "*zz-db-b*")
          (display-buffer "*zz-db-a*")
          (let ((win (display-buffer-other-window! "*zz-db-b*")))
            (check-true! (not (equal? win me)) "another window")
            (check-equal! (window-buffer me) "*scratch*" "this one still shows scratch")
            (check-equal! (active-window) me "and is still selected")))))))

(deftest 'a-rule-can-match-by-a-procedure
  "a rule's pattern can be a procedure of the name and the alist"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-proc*")
        (buffer-create "*zz-db-other*")
        (add-display-rule! (lambda (name alist) (equal? name "*zz-db-proc*")) 'same-window)
        (let ((me (active-window)))
          (check-equal! (display-buffer "*zz-db-proc*") me "the procedure matched: this window")
          (check-false! (equal? (display-buffer "*zz-db-other*") me)
                        "another name takes the chain"))))))

(deftest 'mode-preference-survives-a-temporary-cover
  "display reuses the work window beneath a special buffer"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (for-each (lambda (b)
                    (buffer-create b)
                    (buffer-set-local! b 'mode-name "text-mode"))
                  '("*zz-db-a*" "*zz-db-b*"))
        (let ((win (display-buffer "*zz-db-a*")))
          (buffer-create "*zz-db-cover*")
          (buffer-set-local! "*zz-db-cover*" 'mode-name "help-mode")
          (buffer-set-local! "*zz-db-cover*" 'special #t)
          (display-buffer-in-window! win "*zz-db-cover*")
          (check-equal! (window-preferred-mode win) "text-mode" "the cover keeps the preference")
          (check-true! (window-prefers-buffer? win "*zz-db-b*") "the next work buffer matches")
          (window-tree-set! (window-tree))
          (set! win (window-showing "*zz-db-cover*"))
          (check-equal! (window-preferred-mode win) "text-mode" "restoring the tree keeps the preference")
          (check-equal! (display-buffer "*zz-db-b*") win "the stack receives the next work buffer"))))))

(deftest 'free-layout-switch-reuses-the-same-mode-window
  "ordinary switching reuses a matching window without a target layout"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (for-each (lambda (b)
                    (buffer-create b)
                    (buffer-set-local! b 'mode-name "text-mode"))
                  '("*zz-db-a*" "*zz-db-b*"))
        (let ((source (active-window)) (win (display-buffer "*zz-db-a*")))
          (switch-to-buffer! "*zz-db-b*")
          (check-equal! (active-window) win "the matching window is selected")
          (check-equal! (window-buffer source) "*scratch*" "the source stays unchanged")
          (check-equal! (window-buffer win) "*zz-db-b*" "the buffer opens in the matching stack"))))))

(deftest 'a-listing-keeps-its-own-mode-preference
  "a special listing is a mode destination, not automatically a temporary cover"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-list*")
        (buffer-set-local! "*zz-db-list*" 'mode-name "Dired")
        (buffer-set-local! "*zz-db-list*" 'special #t)
        (display-buffer-in-window! (active-window) "*zz-db-list*")
        (check-equal! (window-preferred-mode (active-window)) "Dired"
                      "directory buffers cycle with directories")))))

(deftest 'quit-window-exhausted-history-does-not-borrow-a-buffer
  "an exhausted work window closes even when other buffers are available"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (let ((source (active-window)) (win (display-buffer "*zz-db-a*")))
          (set-window-restore! win #f)
          (set-window-prev-buffers! win '())
          (select-window! win)
          (run-command "quit-window")
          (check-equal! (length (window-list)) 1 "the layout degrades")
          (check-equal! (active-window) source "the surviving window is selected")
          (check-equal! (current-buffer) "*scratch*" "no unrelated buffer is borrowed")
          (check-true! (buffer-known? "*zz-db-b*") "hidden buffers remain alive"))))))

(deftest 'quit-window-last-exhausted-window-stays
  "the final window cannot close or borrow a buffer"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (switch-to-buffer-here! "*zz-db-a*")
        (set-window-prev-buffers! (active-window) '())
        (set-window-restore! (active-window) #f)
        (run-command "quit-window")
        (check-equal! (current-buffer) "*zz-db-a*" "the final window stays on its buffer")
        (check-true! (buffer-known? "*zz-db-a*") "the final buffer is not killed")))))

(deftest 'a-buffer-shows-in-one-window-at-a-time
  "a display of a visible buffer takes it out of the window that had it"
  (lambda ()
    (t--db-with t--db-wide
      (lambda ()
        (buffer-create "*zz-db-a*")
        (buffer-create "*zz-db-b*")
        (buffer-create "*zz-db-c*")
        (let* ((home (active-window))
               (other (display-buffer "*zz-db-a*")))
          (display-buffer-in-window! home "*zz-db-b*")
          (check-equal! (window-showing "*zz-db-a*") other "a sits in the other window")
          (display-buffer-in-window! home "*zz-db-a*")
          (check-equal! (length (filter (lambda (w) (equal? (cadr w) "*zz-db-a*"))
                                        (window-list)))
                        1 "one window, never two")
          (check-equal! (window-showing "*zz-db-a*") home "the display moved it here")
          (check-false! (equal? (window-buffer other) "*zz-db-a*")
                        "the window that had it reveals something else"))))))


(deftest 'an-agent-opens-a-file-only-in-the-other-window
  "an agent's display-buffer refuses a file buffer in the same window, and shows it in the other window"
  (lambda ()
    (let ((path (string-append t--db-dir "/zz-agent-open.txt"))
          (plain "*zz-agent-plain*"))
      (make-directory! t--db-dir)
      (write-file! path "text\n")
      (when (buffer-known? path) (buffer-kill! path))
      (visit-quietly path)
      (test-buffer! plain "")
      (check-false! (with-edit-author "agent:zz-db-agent"
                      (lambda () (display-buffer path)))
                    "the agent gets #f for a file in the same window")
      (check-false! (member path (map window-buffer (window-list)))
                    "no window shows the file")
      (check-true! (and (with-edit-author "agent:zz-db-agent"
                          (lambda () (display-buffer-other-window! path)))
                        #t)
                   "the agent opens a file in the other window")
      (check-true! (and (with-edit-author "agent:zz-db-agent"
                          (lambda () (display-buffer-other-window! plain)))
                        #t)
                   "a buffer that is not a file still shows")
      (check-true! (and (display-buffer-other-window! path) #t)
                   "the user still opens the file")
      (buffer-kill! plain)
      (buffer-kill! path)
      (delete-file! path))))

(deftest 'an-agent-buffer-stays-out-of-the-windows-until-asked
  "a buffer an agent makes is context-only; the agent shows it only in the other window, and that promotes it"
  (lambda ()
    (let ((buf "*zz-agent-work*")
          (before (map window-buffer (window-list))))
      (when (buffer-known? buf) (buffer-kill! buf))
      (with-edit-author "agent:zz-db-agent"
        (lambda () (buffer-create buf)))
      (check-true! (buffer-context-only? buf) "the agent's new buffer is context-only")
      (check-false! (fill-candidate? buf) "no window fills with it")
      (check-false! (with-edit-author "agent:zz-db-agent"
                      (lambda () (display-buffer buf)))
                    "display-buffer refuses it in the same window")
      (check-false! (with-edit-author "agent:zz-db-agent"
                      (lambda () (switch-to-buffer! buf)))
                    "switch-to-buffer! refuses it")
      (check-equal! (map window-buffer (window-list)) before "no window changed")
      (check-true! (and (with-edit-author "agent:zz-db-agent"
                          (lambda () (display-buffer-other-window! buf)))
                        #t)
                   "the other window shows it on request")
      (check-false! (buffer-context-only? buf) "a shown buffer is the user's")
      (buffer-kill! buf))))

(deftest 'an-agent-visit-on-the-frame-shows-nothing
  "an agent visit outside a buffer context loads the file and leaves every window and mode alone"
  (lambda ()
    (let ((path (string-append t--db-dir "/zz-agent-visit.txt"))
          (here (window-buffer (active-window))))
      (make-directory! t--db-dir)
      (write-file! path "text\n")
      (when (buffer-known? path) (buffer-kill! path))
      (let ((mode (buffer-local here 'mode-name))
            (before (map window-buffer (window-list)))
            (got (with-edit-author "agent:zz-db-agent"
                   (lambda () (visit path)))))
        (check-equal! got path "visit answers the file buffer")
        (check-true! (buffer-context-only? path) "the file stays context-only")
        (check-equal! (map window-buffer (window-list)) before "no window changed")
        (check-equal! (buffer-local here 'mode-name) mode "the selected buffer keeps its mode"))
      (buffer-kill! path)
      (delete-file! path))))
