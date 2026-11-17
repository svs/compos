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

(define-mode "zz-raise-mode"
  (lambda () (error "zz-raise-mode: the setup raises")))

(define *zz-woken* '())
(define (zz--note-woken! buf) (set! *zz-woken* (cons buf *zz-woken*)))

(deftest 'a-mode-setup-that-raises-does-not-end-the-wake
  "the owners on buffer-woken-hook still run, and the waking flag comes back"
  (lambda ()
    (let ((buf (test-buffer! "zz-raise-buf" "text")))
      (buffer-set-local! buf 'mode-name "zz-raise-mode")
      (set! *zz-woken* '())
      (add-hook! 'buffer-woken-hook 'zz--note-woken!)
      (restore-buffer-runtime! buf)
      (remove-hook! 'buffer-woken-hook 'zz--note-woken!)
      (check-true! (if (member buf *zz-woken*) #t #f) "the wake hook ran for the buffer")
      (check-false! *buffer-waking* "the waking flag is off again")
      (buffer-set-local! buf 'mode-name #f)
      (buffer-kill! buf))))
