;;; runtime-owed-test.scm --- a buffer whose mode setup never ran gets it
;;; on its first key lookup.

(domain! 'testing)
(effects! '(write))

(define-mode "zz-owed-mode"
  (lambda ()
    (buffer-set-local! (current-buffer) 'zz-owed-setup-ran #t)))

(deftest 'a-buffer-whose-setup-never-ran-is-restored-at-its-first-key
  "runtime-owed? names a moded buffer this run never set up; the key lookup restores it"
  (lambda ()
    (let ((buf (test-buffer! "zz-owed-buf" "text")))
      (with-current-buffer buf (lambda () (set-mode! "zz-owed-mode")))
      (check-false! (runtime-owed? buf) "a buffer set-mode! ran for is not owed")
      ;; what a checkpoint wake leaves: the mode's name, no setup this run
      (set! *runtime-restored* (filter (lambda (b) (not (equal? b buf))) *runtime-restored*))
      (buffer-set-local! buf 'zz-owed-setup-ran #f)
      (check-true! (runtime-owed? buf) "the woken buffer is owed its setup")
      (switch-to-buffer! buf)
      (set! *runtime-restored* (filter (lambda (b) (not (equal? b buf))) *runtime-restored*))
      (buffer-set-local! buf 'zz-owed-setup-ran #f)
      (check-equal! (car (key-context)) buf "the frame shows the owed buffer")
      (key-binding-dispatch "C-f")
      (check-false! (runtime-owed? buf) "the lookup ran the restore")
      (check-equal! (buffer-local-value 'zz-owed-setup-ran buf) #t "and the mode setup ran")
      (buffer-kill! buf))))
