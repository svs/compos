;;; popup-move-test.scm --- the popup opens on the right and moves by M-<arrows>.

(domain! 'testing)
(effects! '(write display))

(define t--pop "*zz-popup-move*")

(deftest 'the-popup-opens-on-the-right-and-moves-to-the-edge-you-name
  "right is the default; a move re-floats it, and the side is remembered"
  (lambda ()
    (delete-other-windows!)
    (when (popup-open?) (popup-close!))
    (buffer-create t--pop)
    (check-equal! (popup-default-side) 'right "the default is the right edge")
    (popup-show t--pop)
    (check-equal! (buffer-local t--pop 'window-class) "popup popup-right" "it floats on the right")
    (with-current-buffer t--pop
      (lambda ()
        (check-equal! (key-binding "M-<down>") "popup-move-down" "the popup's keys are in")
        (run-command "popup-move-down")
        (check-equal! (buffer-local t--pop 'window-class) "popup popup-bottom" "M-<down> puts it on the bottom")
        (check-equal! (buffer-local t--pop 'popup-side) 'bottom "and the side is remembered")
        (run-command "popup-move-left")
        (check-equal! (buffer-local t--pop 'window-class) "popup popup-left" "M-<left> puts it on the left")))
    (popup-close!)
    (popup-show t--pop)
    (check-equal! (buffer-local t--pop 'window-class) "popup popup-left" "it opens where it was moved to")
    (popup-close!)
    (check-true! (not (equal? (with-current-buffer t--pop (lambda () (key-binding "M-<down>")))
                              "popup-move-down"))
                 "closed, the popup's keys are out")
    (buffer-kill! t--pop)))

(deftest 'a-move-outside-the-popup-does-nothing
  "the command belongs to the popup window"
  (lambda ()
    (delete-other-windows!)
    (when (popup-open?) (popup-close!))
    (buffer-create t--pop)
    (switch-to-buffer! t--pop)
    (run-command "popup-move-down")
    (check-equal! (buffer-local t--pop 'window-class) #f "an ordinary window does not float")
    (switch-to-buffer! "*scratch*")
    (buffer-kill! t--pop)))

(deftest 'dismissing-a-popup-brings-back-the-one-under-it
  "messages, then telemetry over it: q on telemetry shows messages; q again closes the popup"
  (lambda ()
    (delete-other-windows!)
    (when (popup-open?) (popup-close!))
    (buffer-create "*zz-pop-under*")
    (buffer-create "*zz-pop-over*")
    (popup-show "*zz-pop-under*")
    (popup-show "*zz-pop-over*")
    (check-equal! (popup-buffer) "*zz-pop-over*" "the second covers the first")
    (check-equal! (popup-stack) (list "*zz-pop-under*") "and the first waits underneath")
    (popup-dismiss!)
    (check-true! (popup-open?) "the popup is still open")
    (check-equal! (popup-buffer) "*zz-pop-under*" "showing the first again")
    (check-equal! (popup-stack) '() "with nothing underneath")
    (popup-dismiss!)
    (check-true! (not (popup-open?)) "dismissing the last one closes the popup")
    (popup-show "*zz-pop-under*")
    (popup-show "*zz-pop-over*")
    (popup-close!)
    (check-equal! (popup-stack) '() "closing the popup empties the stack")
    (buffer-kill! "*zz-pop-under*")
    (buffer-kill! "*zz-pop-over*")))
