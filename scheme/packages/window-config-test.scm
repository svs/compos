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

(define (t--wc-done!)
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
    (t--wc-done!)))

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
    (t--wc-done!)))


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
    (t--wc-done!)))

;;; the preview verb: one look per frame, no MRU, no focus, no winner



(deftest 'a-definition-peek-is-the-frames-look
  "the definition shows beside the reader, and the reader keeps focus"
  (lambda ()
    (t--wr-setup!)
    (let ((me (active-window)))
      (let ((w (peek--show! "zz-name" '(buffer "zz-wr-b" 0))))
        (check-equal! (window-buffer w) "zz-wr-b" "the definition shows beside")
        (check-equal! (active-window) me "the reader stays")))
    (t--wc-done!)))

;;; the frame return stack

