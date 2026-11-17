;;; register-test.scm --- registers and the mark ring.

(domain! 'testing)
(effects! '(write))

(define (register-test-buffer! name text)
  (let ((buf (test-buffer! name text)))
    (delete-other-windows!)
    (switch-to-buffer! buf)
    (goto-char! 0)
    buf))

(deftest 'a-point-register-jumps-back-to-the-buffer-and-position
  "point-to-register! then jump-to-register!"
  (lambda ()
    (let ((a (register-test-buffer! "zz-reg-a" "hello world")))
      (goto-char! 6)
      (point-to-register! "a")
      (check-equal! (car (register-get "a")) 'point "a point register")
      (register-test-buffer! "zz-reg-b" "elsewhere")
      (jump-to-register! "a")
      (check-equal! (current-buffer) a "back in the buffer")
      (check-equal! (point) 6 "at the position")
      (buffer-kill! a)
      (buffer-kill! "zz-reg-b"))))

(deftest 'a-text-register-inserts-and-appends
  "copy-to-register!, append-to-register!, insert-register!"
  (lambda ()
    (let ((a (register-test-buffer! "zz-reg-a" "")))
      (copy-to-register! "t" "one")
      (append-to-register! "t" " two")
      (insert-register! "t")
      (check-equal! (buffer-text a) "one two" "the text landed")
      (check-contains! (register-describe "t") "one two" "described")
      (buffer-kill! a))))

(deftest 'a-window-register-restores-the-arrangement
  "window-configuration-to-register! then jump-to-register!"
  (lambda ()
    (let ((a (register-test-buffer! "zz-reg-a" "x")))
      (window-configuration-to-register! "w")
      (split-window! 'h 0.5)
      (check-true! (> (length (window-list)) 1) "split")
      (jump-to-register! "w")
      (check-equal! (length (window-list)) 1 "one window again")
      (buffer-kill! a))))

(deftest 'the-mark-ring-remembers-and-pop-walks-back
  "push-mark! twice, pop-to-mark! back through both, no region left"
  (lambda ()
    (let ((a (register-test-buffer! "zz-reg-a" "0123456789")))
      (goto-char! 2) (push-mark! #f #t)
      (goto-char! 5) (push-mark! #f #t)
      (goto-char! 8)
      (check-equal! (mark) 5 "the mark is the last one set")
      (check-equal! (mark-ring a) '(2) "the ring holds the one before")
      (command-call "set-mark-command" '(4))
      (check-equal! (point) 5 "C-u C-SPC went to the mark")
      (check-false! (mark) "and left no region")
      (command-call "set-mark-command" '(4))
      (check-equal! (point) 2 "the next pop reaches the one before")
      (buffer-kill! a))))

(deftest 'the-global-mark-ring-crosses-buffers
  "pop-global-mark returns to the buffer a mark was set in"
  (lambda ()
    (let ((a (register-test-buffer! "zz-reg-a" "aaaa")))
      (goto-char! 3) (push-mark! #f #t)
      (let ((b (register-test-buffer! "zz-reg-b" "bbbb")))
        (run-command "pop-global-mark")
        (check-equal! (current-buffer) a "back in the first buffer")
        (buffer-kill! b))
      (buffer-kill! a))))
