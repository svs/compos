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

;; A reload also rebuilds every visible buffer, and the test frame has
;; windows of its own. Take that half out to count the mode half alone.
(define (t--hr-modes-only thunk)
  (let ((was *reload-refresh-visible*))
    (set! *reload-refresh-visible* #f)
    (let ((r (thunk)))
      (set! *reload-refresh-visible* was)
      r)))

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
    (check-equal! (t--hr-modes-only reload-finish!) 1
      "one buffer wore the mode the reload named")

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
    (check-equal! (t--hr-modes-only reload-finish!) 1
      "the buffer wearing it was rebuilt")
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
    (check-equal! (t--hr-modes-only reload-finish!) 0
      "no mode named, no buffer touched")
    (buffer-kill! t--hr-a)))

(deftest 'outside-a-reload-nothing-is-recorded
  "define-mode costs nothing at boot, when every mode is new"
  (lambda ()
    (t--hr-major! "zz-hr-quiet" 1)
    (reload-begin!)
    (check-equal! (t--hr-modes-only reload-finish!) 0
      "the definition before the bracket was not carried in")))

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

(deftest 'a-reload-rebuilds-the-buffers-you-can-see
  "a setup fn calls helpers the same save can change without touching define-mode"
  (lambda ()
    (t--hr-major! "zz-hr-visible" 1)
    (test-buffer! t--hr-a "alpha\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-visible")))
    (switch-to-buffer! t--hr-a)
    (check-equal! (buffer-local t--hr-a 'zz-hr-stamp) 1 "the mode set the buffer up once")

    ;; the reload redefines no mode at all: only a helper changed
    (t--hr-major! "zz-hr-visible" 2)
    (reload-begin!)
    (reload-finish!)

    (check-equal! (buffer-local t--hr-a 'zz-hr-stamp) 2
      "the visible buffer was not rebuilt")
    (buffer-kill! t--hr-a)))

(deftest 'the-visible-refresh-can-be-turned-off
  "a session whose mode setup is expensive opts out"
  (lambda ()
    (t--hr-major! "zz-hr-visible" 3)
    (test-buffer! t--hr-a "alpha\n")
    (with-current-buffer t--hr-a (lambda () (set-mode! "zz-hr-visible")))
    (switch-to-buffer! t--hr-a)

    (t--hr-major! "zz-hr-visible" 4)
    (reload-begin!)
    (t--hr-modes-only reload-finish!)

    (check-equal! (buffer-local t--hr-a 'zz-hr-stamp) 3
      "the refresh ran with the switch off")
    (buffer-kill! t--hr-a)))

;; M-x reload-scheme is the manual door for a purged primitive. The rebind
;; must leave the stdlib alone: editor.scm aliases define-command and then
;; wraps the same name in Scheme, and a rebind that writes the primitive map
;; straight in puts the raw primitive back over the wrapper.
(deftest 'reload-scheme-rebinds-the-primitives-and-keeps-the-stdlib
  "the alias still calls, and the Scheme wrapper is still the wrapper"
  (lambda ()
    (run-command "reload-scheme")

    ;; the wrapper answers with the name; the raw primitive answers void
    (check-equal! (define-command "zz-reload-scheme-a" "probe" (lambda () 1))
      "zz-reload-scheme-a" "the rebind put the raw primitive over the wrapper")
    (check-equal! (procedure? define-command--raw) #t
      "the alias of a Session primitive lost its fun")
    (define-command--raw "zz-reload-scheme-b" (lambda () 1))
    (check-equal! (command-doc "zz-reload-scheme-b") ""
      "the alias did not register the command")))
