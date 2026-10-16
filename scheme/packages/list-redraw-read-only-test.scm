;;; list-redraw-read-only-test.scm --- a list redraw leaves the read-only flag alone.
;;;
;;; The redraw writes with buffer-replace-range!, a programmatic write
;;; that bypasses read-only on its own. A redraw that flipped the flag
;;; off and on reached the browser as two patches when a hook redrew
;;; the list outside a command. Between the two patches the buffer was
;;; editable, the client took the caret, and the second patch left that
;;; caret at the end of the buffer: point moved to the last row.

(domain! 'testing)
(effects! '(write))

(define t--lrro-buf "*zz-redraw-read-only-list*")

(define-list-mode! "zz-redraw-read-only-mode"
  (list
    'buffer t--lrro-buf
    'rows (lambda (buf) '("alpha" "beta" "gamma"))
    'columns (lambda (buf) (list (list "name" #f)))
    'cells (lambda (buf row) (list row))
    'title (lambda (buf) "Read-only redraw")
    'no-marks #t))

(define (t--lrro-with thunk)
  (switch-to-buffer! "*scratch*")
  (run-command "delete-other-windows")
  (let ((out (thunk)))
    (when (buffer-known? t--lrro-buf) (buffer-kill! t--lrro-buf))
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

(deftest 'a-list-redraw-never-flips-read-only
  "the list is read-only before the redraw, stays read-only during it, and is read-only after"
  (lambda ()
    (t--lrro-with
      (lambda ()
        (list-mode-show! "zz-redraw-read-only-mode")
        (check-true! (buffer-read-only? t--lrro-buf) "a list buffer is read-only")
        (list-goto-index! t--lrro-buf 1)
        (let ((orig buffer-set-read-only!)
              (flips 0))
          (with-stub 'buffer-set-read-only!
            (lambda (buf value) (set! flips (+ flips 1)) (orig buf value))
            (lambda () (list-refresh! t--lrro-buf)))
          (check-equal! flips 0 "the redraw does not touch the read-only flag")
          (check-true! (buffer-read-only? t--lrro-buf) "the list is read-only after the redraw")
          (check-contains! (buffer-text t--lrro-buf) "gamma" "the redraw wrote the rows")
          (check-equal! (list-current t--lrro-buf) "beta" "point stays on its row"))))))
