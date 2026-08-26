;;; hot-reload-test.scm --- a reload reaches the buffers already open.
;;;
;;; Session.reload_files/1 brackets every reload with reload-begin! and
;;; reload-finish!. What happens between them is policy, so it is tested
;;; here: which modes the reload named, and which buffers it rebuilds.
;;; The ExUnit side covers the watcher and the form diff.

(domain! 'testing)
(effects! '(write))

(define t--hr-a "zz-hot-reload-a")
(define t--hr-b "zz-hot-reload-b")

;; A mode whose setup fn stamps the buffer. The stamp is the evidence:
;; a new stamp in an open buffer means the setup fn ran again.
(define (t--hr-major! mode stamp)
  (define-mode mode
    (lambda () (buffer-set-local! (current-buffer) 'zz-hr-stamp stamp))))

(define (t--hr-minor! mode stamp)
  (register-minor-mode! mode
    (lambda (b) (buffer-set-local! b 'zz-hr-minor-stamp stamp))))

(deftest 'a-reloaded-major-mode-rebuilds-the-buffers-already-in-it
  "the setup fn runs again where the mode is worn, and nowhere else"
  (lambda ()
    (t--hr-major! "zz-hr-mode" 1)
    (t--hr-major! "zz-hr-other" 1)
    (test-buffer! t--hr-a "alpha\n")
    (test-buffer! t--hr-b "beta\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-mode")))
    (with-current-buffer t--hr-b (lambda () (set-mode! "zz-hr-other")))
    (check-equal! (buffer-local t--hr-a 'zz-hr-stamp) 1 "the mode set the buffer up once")

    ;; one reload, redefining one of the two modes
    (reload-begin!)
    (t--hr-major! "zz-hr-mode" 2)
    (check-equal! (reload-finish!) 1 "one buffer wore the mode the reload named")

    (check-equal! (buffer-local t--hr-a 'zz-hr-stamp) 2 "it took the new setup")
    (check-equal! (buffer-local t--hr-b 'zz-hr-stamp) 1 "the other mode was left alone")
    (buffer-kill! t--hr-a)
    (buffer-kill! t--hr-b)))

(deftest 'a-reloaded-minor-mode-rebuilds-the-buffers-that-wear-it
  "a minor mode is worn in a buffer-local list, and counts the same way"
  (lambda ()
    (t--hr-minor! "zz-hr-minor" 1)
    (test-buffer! t--hr-a "alpha\n")
    (enable-minor-mode! t--hr-a "zz-hr-minor")
    (check-equal! (buffer-local t--hr-a 'zz-hr-minor-stamp) 1 "the minor setup ran")

    (reload-begin!)
    (t--hr-minor! "zz-hr-minor" 2)
    (check-equal! (reload-finish!) 1 "the buffer wearing it was rebuilt")
    (check-equal! (buffer-local t--hr-a 'zz-hr-minor-stamp) 2 "with the new setup")

    (disable-minor-mode! t--hr-a "zz-hr-minor")
    (buffer-kill! t--hr-a)))

(deftest 'a-reload-that-redefines-no-mode-rebuilds-nothing
  "a save in one package must not rebuild the whole editor"
  (lambda ()
    (t--hr-major! "zz-hr-mode" 7)
    (test-buffer! t--hr-a "alpha\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-mode")))

    (reload-begin!)
    (check-equal! (reload-finish!) 0 "no mode named, no buffer touched")
    (buffer-kill! t--hr-a)))

(deftest 'outside-a-reload-nothing-is-recorded
  "define-mode costs nothing at boot, when every mode is new"
  (lambda ()
    (t--hr-major! "zz-hr-quiet" 1)
    (reload-begin!)
    (check-equal! (reload-finish!) 0 "the definition before the bracket was not carried in")))

(deftest 'a-mode-registry-does-not-grow-when-a-file-reloads
  "assoc reads the newest either way; an auto-reloader must not stack rows"
  (lambda ()
    (t--hr-major! "zz-hr-grow" 1)
    (let ((before (length *mode-setups*)))
      (t--hr-major! "zz-hr-grow" 2)
      (t--hr-major! "zz-hr-grow" 3)
      (check-equal! (length *mode-setups*) before "the entry replaced in place"))))

(deftest 'buffer-wears-mode-sees-both-halves-of-a-buffers-mode
  "the major mode and every minor mode name the buffer"
  (lambda ()
    (t--hr-major! "zz-hr-mode" 1)
    (t--hr-minor! "zz-hr-minor" 1)
    (test-buffer! t--hr-a "alpha\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-mode")))
    (enable-minor-mode! t--hr-a "zz-hr-minor")

    (check-true! (buffer-wears-mode? t--hr-a '("zz-hr-mode")) "the major mode")
    (check-true! (buffer-wears-mode? t--hr-a '("zz-hr-minor")) "the minor mode")
    (check-false! (buffer-wears-mode? t--hr-a '("zz-hr-absent")) "and nothing else")

    (disable-minor-mode! t--hr-a "zz-hr-minor")
    (buffer-kill! t--hr-a)))
