;;; peek-wire-test.scm --- the peek says which window it was asked from.

(domain! 'testing)
(effects! '(write))

(deftest 'a-peek-points-back-at-the-window-it-was-asked-from
  "the wire's two ends: the local names the source window; keep and replace clear it"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let* ((a (t--peek-file "a.txt" "alpha\n"))
               (c (t--peek-file "c.txt" "gamma\n"))
               (me (active-window)))
          (visit c)
          (switch-to-buffer! "*scratch*")
          (run-command "delete-other-windows")
          (peek-file! a)
          (check-equal! (buffer-local a 'peek-from) me "the peek names the window it came from")
          (peek-file! c)
          (check-equal! (buffer-local c 'peek-from) me "an existing buffer, peeked, names it too")
          (peek-file! a)
          (check-equal! (buffer-local c 'peek-from) #f "replaced, it no longer points")
          (peek-keep! a)
          (check-equal! (buffer-local a 'peek-from) #f "kept, it no longer points"))))))
