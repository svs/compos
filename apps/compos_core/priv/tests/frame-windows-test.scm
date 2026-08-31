;;; frame-windows-test.scm --- the tool buffer context and its exit.
;;;
;;; A tool eval runs under with-current-buffer, so switch-to-buffer!
;;; retargets the logical context and changes no window. Window reads
;;; must still report the real frame. with-frame-windows is the
;;; deliberate exit: inside it, current-buffer and the switch
;;; primitives act on the frame's real windows.

(domain! 'testing)
(effects! '(write))

;; the buffer the frame's active window really shows
(define (t--fw-window-buffer)
  (let ((active (active-window)))
    (let loop ((rows (window-list)))
      (cond ((null? rows) #f)
            ((equal? (car (car rows)) active) (cadr (car rows)))
            (else (loop (cdr rows)))))))

(deftest 'window-reads-ignore-the-buffer-context
  "window observation reports the real frame from inside a buffer context"
  (lambda ()
    (let ((shown (test-buffer! "*zz-fw-shown-1*" ""))
          (context (test-buffer! "*zz-fw-context-1*" ""))
          (origin (current-buffer)))
      (switch-to-buffer! shown)
      (with-current-buffer context
        (lambda ()
          (check-equal! (current-buffer) context
                        "the context buffer is current inside the binding")
          (check-equal! (t--fw-window-buffer) shown
                        "the window read still reports the shown buffer")))
      (switch-to-buffer! origin)
      (for-each buffer-kill! (list shown context)))))

(deftest 'switch-under-context-changes-no-window
  "switch-to-buffer! inside a buffer context retargets the context only"
  (lambda ()
    (let ((shown (test-buffer! "*zz-fw-shown-2*" ""))
          (context (test-buffer! "*zz-fw-context-2*" ""))
          (target (test-buffer! "*zz-fw-target-2*" ""))
          (origin (current-buffer)))
      (switch-to-buffer! shown)
      (with-current-buffer context
        (lambda ()
          (switch-to-buffer! target)
          (check-equal! (current-buffer) target
                        "the context follows the switch")
          (check-equal! (t--fw-window-buffer) shown
                        "the real window keeps its buffer")))
      (switch-to-buffer! origin)
      (for-each buffer-kill! (list shown context target)))))

(deftest 'with-frame-windows-reaches-the-real-windows
  "the escape reads and switches the frame's windows from a context"
  (lambda ()
    (let ((shown (test-buffer! "*zz-fw-shown-3*" ""))
          (context (test-buffer! "*zz-fw-context-3*" ""))
          (target (test-buffer! "*zz-fw-target-3*" ""))
          (origin (current-buffer)))
      (switch-to-buffer! shown)
      (with-current-buffer context
        (lambda ()
          (check-equal! (with-frame-windows (lambda () (current-buffer)))
                        shown
                        "inside the escape, current-buffer is the shown buffer")
          (with-frame-windows (lambda () (switch-to-buffer! target)))
          (check-equal! (t--fw-window-buffer) target
                        "a switch inside the escape changes the real window")
          (check-equal! (current-buffer) context
                        "the context comes back after the escape")))
      (switch-to-buffer! origin)
      (for-each buffer-kill! (list shown context target)))))
