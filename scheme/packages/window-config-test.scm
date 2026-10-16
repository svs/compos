;;; window-config-test.scm --- the frame's group follows its windows, not
;;; the shaped surfaces that float over them.

(domain! 'testing)
(effects! '(read write display))

(deftest 'a-floating-surface-does-not-change-the-frame-group
  "a prompt floating over the group's panes is a visit, not a place"
  (lambda ()
    (with-fresh-group "zz-popup-group"
      (lambda (id)
        (let ((a "*zz-popup-member*")
              (w "*zz-popup-visitor*"))
          (buffer-create a)
          (buffer-create w)
          (buffer-add-group! a id)
          (delete-other-windows!)
          (switch-to-buffer! a)
          (check-equal! (frame-group) id "the frame stands in the member's group")
          (float-show! w 'bottom 0.4 #t)
          (check-equal! (frame-group) id "the floating surface changes nothing")
          (check-equal! (group-current-recalculate!) id "and a recalculation agrees")
          (float-close!)
          (check-equal! (frame-group) id "closing it changes nothing")
          (switch-to-buffer! "*scratch*")
          (buffer-kill! a)
          (buffer-kill! w))))))

;;; the window leaf's restore record (Emacs quit-restore as leaf data)

(define (t--wr-setup!)
  (for-each (lambda (b) (test-buffer! b "text\n")) (list "zz-wr-a" "zz-wr-b" "zz-wr-c"))
  (delete-other-windows!)
  (switch-to-buffer-here! "zz-wr-a")
  (set-window-restore! (active-window) #f))

(define (t--wr-done!)
  (delete-other-windows!)
  (switch-to-buffer-here! "*scratch*")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list "zz-wr-a" "zz-wr-b" "zz-wr-c")))

(deftest 'a-look-records-what-it-covers-on-the-leaf
  "a preview writes (preview BUF POINT) on the leaf, the next look keeps it, and the end of the look clears it"
  (lambda ()
    (t--wr-setup!)
    (let ((w (active-window))
          (mru (buffer-list-mru))
          (history (window-prev-buffers (active-window))))
      (window-preview-buffer! "zz-wr-b" w)
      (check-equal! (take (window-restore w) 2) '(preview "zz-wr-a") "the look covers a")
      (window-preview-buffer! "zz-wr-c" w)
      (check-equal! (take (window-restore w) 2) '(preview "zz-wr-a") "the next look keeps what the first covered")
      (check-equal! (buffer-list-mru) mru "a look does not bump the MRU")
      (check-equal! (window-prev-buffers w) history "a look writes no history")
      (check-true! (window-preview-end! w) "the end of the look answers #t")
      (check-equal! (window-buffer w) "zz-wr-a" "and puts a back")
      (check-false! (window-restore w) "the record goes with the look"))
    (t--wr-done!)))

(deftest 'a-visit-commits-a-look-and-a-kill-ends-it
  "a visit keeps the looked-at buffer with the covered one first in history; a kill of the look shows the covered buffer"
  (lambda ()
    (t--wr-setup!)
    (let ((w (active-window)))
      (window-preview-buffer! "zz-wr-b" w)
      (switch-to-buffer-here! "zz-wr-b")
      (check-false! (window-restore w) "a visit ends the look")
      (check-equal! (car (window-prev-buffers w)) "zz-wr-a" "the covered buffer leads the history")
      (window-preview-buffer! "zz-wr-c" w)
      (buffer-kill! "zz-wr-c")
      (check-equal! (window-buffer w) "zz-wr-b" "a kill of the look shows what it covered")
      (check-false! (window-restore w) "and the record goes"))
    (t--wr-done!)))

(deftest 'a-display-record-applies-only-while-the-window-shows-its-buffer
  "set-window-restore! names the buffer shown; a switch away drops it; window-tree carries it"
  (lambda ()
    (t--wr-setup!)
    (let ((w (active-window)))
      (set-window-restore! w '(other "zz-wr-b" 0))
      (check-equal! (window-restore w) '(other "zz-wr-b" 0) "the record reads back")
      (let ((tree (window-tree)))
        (set-window-restore! w #f)
        (window-tree-set! tree)
        (check-equal! (window-restore (active-window)) '(other "zz-wr-b" 0) "window-tree carries the record"))
      (switch-to-buffer-here! "zz-wr-c")
      (check-false! (window-restore (active-window)) "a window on another buffer has no record")
      (set-window-owner! (active-window) 99999)
      (check-false! (window-owner (active-window)) "an owner names a live window or nothing"))
    (t--wr-done!)))

(deftest 'quit-window-reads-the-leaf
  "window-quit-restore! deletes a window the display made and puts back a buffer it covered"
  (lambda ()
    (t--wr-setup!)
    (let ((me (active-window)))
      (split-window! 'h 0.5)
      (let ((w (other-window-id me)))
        (select-window! me)
        (window-set-buffer! w "zz-wr-b")
        (set-window-restore! w '(other "zz-wr-a" 0))
        (window-set-buffer! w "zz-wr-c")
        (check-false! (window-quit-restore! w) "a record made for b does not apply to c")
        (window-set-buffer! w "zz-wr-b")
        (set-window-restore! w '(window #f #f))
        (check-true! (window-quit-restore! w) "quit undoes the display")
        (check-equal! (length (window-list)) 1 "and deletes the window it made")))
    (t--wr-done!)))

;;; the preview verb: one look per frame, no MRU, no focus, no winner

(deftest 'a-look-here-moves-nothing-and-its-end-puts-back
  "preview-show here shows in the window, preview-end #f puts back what it covered"
  (lambda ()
    (t--wr-setup!)
    (let ((w (active-window)) (mru (buffer-list-mru)))
      (set-frame-local! 'winner-ring '())
      (preview-show "zz-wr-b" 'here)
      (preview-show "zz-wr-c" 'here)
      (check-equal! (window-buffer w) "zz-wr-c" "the look shows")
      (check-equal! (buffer-list-mru) mru "the MRU did not change")
      (check-equal! (frame-local 'winner-ring) '() "winner did not change")
      (check-equal! (active-window) w "the focus stays")
      (preview-end #f)
      (check-equal! (window-buffer w) "zz-wr-a" "the end puts back what the first look covered")
      (check-false! (preview-slot) "the slot is empty")
      (preview-show "zz-wr-b" 'here)
      (preview-end #t)
      (check-equal! (window-buffer w) "zz-wr-b" "keep commits the look")
      (check-equal! (car (window-prev-buffers w)) "zz-wr-a" "as a visit"))
    (t--wr-done!)))

(deftest 'a-look-in-another-window-is-owned-and-goes-with-its-end
  "preview-show other shows in a window the invoking one owns; preview-end #f removes it"
  (lambda ()
    (t--wr-setup!)
    (let ((me (active-window)) (mru (buffer-list-mru)))
      (set-frame-local! 'winner-ring '())
      (let ((w (preview-show "zz-wr-b" 'other)))
        (check-true! (and w (not (equal? w me))) "another window shows the look")
        (check-equal! (window-owner w) me "the invoking window owns it")
        (check-equal! (active-window) me "the focus stays")
        (check-equal! (preview-show "zz-wr-c" 'other) w "the next look takes the same window")
        (check-equal! (buffer-list-mru) mru "the MRU did not change")
        (check-equal! (frame-local 'winner-ring) '() "winner did not change")
        (preview-end #f)
        (check-false! (window-exists? w) "the end deletes the window the look made")
        (check-equal! (window-buffer me) "zz-wr-a" "and the reader's window is as it was")))
    (t--wr-done!)))

(deftest 'a-definition-peek-is-the-frames-look
  "the definition peek shows through the slot; a discard gives the window back"
  (lambda ()
    (t--wr-setup!)
    (let ((me (active-window)))
      (let ((w (peek--show! "zz-name" '(buffer "zz-wr-b" 0))))
        (check-equal! (window-buffer w) "zz-wr-b" "the definition shows beside")
        (check-equal! (car (peek--data)) "zz-name" "the slot names the definition")
        (peek-discard!)
        (check-false! (preview-slot) "the discard ends the look")
        (check-equal! (length (window-list)) 1 "and the window the peek made goes")
        (check-equal! (active-window) me "the reader stays")))
    (t--wr-done!)))

;;; the frame return stack

(deftest 'a-pop-puts-back-the-tree-target-and-focus
  "arrangement-pop! restores what arrangement-push! saw; drop keeps the screen; a pop ends later entries"
  (lambda ()
    (t--wr-setup!)
    (layout-target-set! #f)
    (set-frame-local! 'winner-ring '())
    (let* ((me (active-window))
           (token (arrangement-push! 'zz-test)))
      (split-window! 'h 0.5)
      (switch-to-buffer-here! "zz-wr-b")
      (layout-target-set! 'columns)
      (let ((later (arrangement-push! 'zz-later)))
        (check-true! (arrangement-pop! token) "the pop answers #t")
        (check-equal! (map cadr (window-list)) '("zz-wr-a") "the tree comes back")
        (check-equal! (window-buffer (active-window)) "zz-wr-a" "and the focus")
        (check-false! (layout-target) "and the layout target")
        (check-false! (arrangement-for 'zz-later) "a pop ends the entries pushed after it")
        (check-false! (arrangement-pop! later) "so they restore nothing"))
      (let ((token (arrangement-push! 'zz-test)))
        (split-window! 'h 0.5)
        (check-true! (arrangement-drop! token) "a drop answers #t")
        (check-equal! (length (window-list)) 2 "and keeps what is on screen")
        (check-false! (arrangement-for 'zz-test) "the entry is gone")))
    (layout-target-set! #f)
    (t--wr-done!)))
