;;; window-log-test.scm --- a change of the windows leaves a record: before,
;;; the action, after; a note from a door rides along.

(domain! 'testing)
(effects! '(write display))

(deftest 'a-window-change-is-recorded-with-its-action-and-notes
  "the record holds the windows before and after, the action, the note, and reads back as a report"
  (lambda ()
    (test-buffer! "zz-wl-a" "text\n")
    (unwind-protect
      (lambda ()
        (delete-other-windows!)
        (switch-to-buffer-here! "zz-wl-a")
        (set-frame-local! 'window-log-after #f)
        (window-log--pre!)
        (set-frame-local! 'window-log-after (window-log-snapshot))
        (let ((n (length (window-log))))
          (window-log--pre!)
          (check-equal! (length (window-log)) n "no change, no record")
          (window-log-note! "test says" 42)
          (split-window! 'h 0.5)
          (window-log--post! "zz-split")
          (check-equal! (length (window-log)) (+ n 1) "one change, one record")
          (let ((e (car (window-log))))
            (check-equal! (plist-get e 'action) "zz-split" "the action is the command")
            (check-equal! (plist-get e 'notes) '("test says 42") "the note rides along")
            (check-equal! (length (plist-get (plist-get e 'before) 'windows)) 1 "one window before")
            (check-equal! (length (plist-get (plist-get e 'after) 'windows)) 2 "two after")
            (let ((report (window-log-report e)))
              (check-true! (and (string-contains? report "zz-split") #t) "the report names the action")
              (check-true! (and (string-contains? report "came on screen") #t) "and the window that came")))))
      (lambda ()
        (delete-other-windows!)
        (switch-to-buffer-here! "*scratch*")
        (buffer-kill! "zz-wl-a")))))
