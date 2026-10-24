;;; window-history-test.scm --- a window remembers its own past across a
;;; tile, and a kill refills the window from that past.
;;;
;;; The tiler uses the windows that show the buffers it lays out, so each
;;; pane keeps its own history. A pane the tile leaves out becomes a hidden
;;; window. A kill then shows the buffer the pane showed before, and never
;;; a buffer another window of the frame shows.

(domain! 'testing)
(effects! '(write display))

(tests-need-a-disposable-editor!
  "re-arranges the frame's windows and kills buffers")

(define t--wh-a "zz-wh-a")
(define t--wh-b "zz-wh-b")
(define t--wh-c "zz-wh-c")
(define t--wh-d "zz-wh-d")
(define t--wh-e "zz-wh-e")
(define t--wh-all (list t--wh-a t--wh-b t--wh-c t--wh-d t--wh-e))

;; two windows: the left one on b after a, the right one on d after c
(define (t--wh-setup!)
  (panes-choose-layout! #f)
  (for-each (lambda (b) (test-buffer! b "")) t--wh-all)
  (delete-other-windows!)
  (switch-to-buffer! t--wh-a)
  (switch-to-buffer! t--wh-b)
  (split-window! 'h 0.5)
  (other-window!)
  (switch-to-buffer! t--wh-c)
  (switch-to-buffer! t--wh-d))

(define (t--wh-done!)
  (panes-choose-layout! #f)
  (delete-other-windows!)
  (window-hidden-clear!)
  (switch-to-buffer! "*scratch*")
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) t--wh-all))

(deftest 'a-tile-keeps-each-panes-own-history
  "after a tile the pane on b still remembers a, and the pane on d remembers c"
  (lambda ()
    (t--wh-setup!)
    (panes-tile! 'columns (list t--wh-b t--wh-d))
    (check-equal! (length (window-list)) 2 "two panes")
    (check-equal! (car (window-prev-buffers (window-showing t--wh-b))) t--wh-a
                  "the pane on b remembers a")
    (check-equal! (car (window-prev-buffers (window-showing t--wh-d))) t--wh-c
                  "the pane on d remembers c, not the survivor's past")
    (t--wh-done!)))

(deftest 'a-kill-after-a-tile-refills-the-pane-from-its-own-past
  "kill d in its pane: the pane shows c, the layout stays"
  (lambda ()
    (t--wh-setup!)
    (panes-tile! 'two-pane (list t--wh-b t--wh-d))
    (let ((win (window-showing t--wh-d)))
      (buffer-kill! t--wh-d)
      (check-equal! (length (window-list)) 2 "the window stays")
      (check-true! (window-exists? win) "the same window")
      (check-equal! (window-buffer win) t--wh-c "and shows the buffer it showed before d"))
    (t--wh-done!)))

(deftest 'a-pane-a-tile-leaves-out-becomes-a-hidden-window
  "tile b with e: the pane on d does not die; it is hidden, with d and its past"
  (lambda ()
    (t--wh-setup!)
    (let ((d-win (window-showing t--wh-d)))
      (panes-tile! 'columns (list t--wh-b t--wh-e))
      (check-false! (window-showing t--wh-d) "no pane shows d")
      (check-equal! (assoc d-win (window-hidden-list)) (list d-win t--wh-d)
                    "the window on d is hidden, with its id and buffer")
      (check-false! (member t--wh-c (window-prev-buffers (window-showing t--wh-e)))
                    "e's new window has its own past, not d's")
      ;; the same layout with d again shows the hidden window, not a new one
      (panes-tile! 'columns (list t--wh-b t--wh-d))
      (check-equal! (window-showing t--wh-d) d-win "d's own window comes back")
      (check-equal! (car (window-prev-buffers d-win)) t--wh-c "and it still remembers c"))
    (t--wh-done!)))
