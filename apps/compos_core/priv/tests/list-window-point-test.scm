;;; list-window-point-test.scm --- a list redraw keeps every window on its row.
;;;
;;; A window keeps its own point (Emacs window-point). A list refresh
;;; rewrites the buffer's text, which clamps every stored window point to
;;; 0. The redraw puts each window back on the row it was on, the way
;;; dired-restore-positions does, so a reader who comes back to a Dired
;;; window finds point where they left it.

(domain! 'testing)
(effects! '(write))

(define t--lwp-buf "*zz-window-point-list*")

(define-list-mode! "zz-window-point-mode"
  (list
    'buffer t--lwp-buf
    'rows (lambda (buf) '("alpha" "beta" "gamma" "delta"))
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf row) (list row))
    'title (lambda (buf) "Window point")
    'no-marks #t))

;; every test starts from one window on *scratch* and ends there
(define (t--lwp-with thunk)
  (switch-to-buffer! "*scratch*")
  (run-command "delete-other-windows")
  (let ((out (thunk)))
    (when (buffer-known? t--lwp-buf) (buffer-kill! t--lwp-buf))
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

(deftest 'a-refresh-keeps-a-non-selected-window-on-its-row
  "the list is refreshed while another window is selected; back in the list, point is on the same row"
  (lambda ()
    (t--lwp-with
      (lambda ()
        (list-mode-show! "zz-window-point-mode")
        (let ((list-win (active-window)))
          (list-goto-index! t--lwp-buf 2)
          (check-equal! (list-current t--lwp-buf) "gamma" "the reader is on gamma")
          (let ((row-pos (buffer-point t--lwp-buf)))
            (check-equal! (window-point list-win) row-pos
                          "the selected window's point is the buffer's")
            ;; the reader goes to another window; the list window keeps its own point
            (run-command "split-window-right")
            (run-command "other-window")
            (switch-to-buffer! "*scratch*")
            (check-equal! (window-point list-win) row-pos
                          "the list window's point stays where the reader left it")
            ;; the directory changed: the list is refreshed while the reader is away
            (list-refresh! t--lwp-buf)
            (check-equal! (list-key-at-pos t--lwp-buf (window-point list-win)) "gamma"
                          "after the rewrite the list window is still on gamma")
            ;; and coming back finds point there
            (select-window! list-win)
            (check-equal! (list-current t--lwp-buf) "gamma"
                          "back in the list window, point is on gamma")))))))

(deftest 'window-set-point-places-a-window-that-is-not-selected
  "the primitive moves the stored point, and selecting the window shows it"
  (lambda ()
    (t--lwp-with
      (lambda ()
        (list-mode-show! "zz-window-point-mode")
        (let ((list-win (active-window))
              (offs (list-offsets t--lwp-buf)))
          (run-command "split-window-right")
          (run-command "other-window")
          (switch-to-buffer! "*scratch*")
          (check-true! (window-set-point! list-win (nth 3 offs)) "the window exists")
          (check-equal! (window-point list-win) (nth 3 offs) "the stored point moved")
          (check-false! (window-set-point! 999999 0) "no window: #f")
          (select-window! list-win)
          (check-equal! (list-current t--lwp-buf) "delta" "selecting the window shows the row"))))))
