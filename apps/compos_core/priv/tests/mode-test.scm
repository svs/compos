;;; mode-test.scm --- major modes, derived modes, minor-mode hooks, auto-mode.

(domain! 'testing)
(effects! '(write))

(define *mode-test-log* '())
(define (mode-test-log! x) (set! *mode-test-log* (cons x *mode-test-log*)))
(define (mode-test-reset!) (set! *mode-test-log* '()))

(define (mode-test-parent-hook!) (mode-test-log! 'parent-hook))
(define (mode-test-child-hook!) (mode-test-log! 'child-hook))
(define (mode-test-minor-hook!) (mode-test-log! 'minor-hook))
(define (mode-test-change-hook!) (mode-test-log! 'change))

(define-mode "zz-mode-test-parent"
  (lambda ()
    (mode-test-log! 'parent-setup)
    (local-set-key "<f9> p" "keymap-test-dummy-one")))

(define-derived-mode "zz-mode-test-child" "zz-mode-test-parent"
  (lambda () (mode-test-log! 'child-setup)))

(deftest 'a-derived-mode-runs-the-parent-setup-first-and-both-hooks-in-order
  "parent setup, child setup, parent hook, child hook"
  (lambda ()
    (add-hook! 'zz-mode-test-parent-hook 'mode-test-parent-hook!)
    (add-hook! 'zz-mode-test-child-hook 'mode-test-child-hook!)
    (test-buffer! "zz-mode-test-buf" "x")
    (mode-test-reset!)
    (with-current-buffer "zz-mode-test-buf" (lambda () (set-mode! "zz-mode-test-child")))
    (check-equal! (reverse *mode-test-log*) '(parent-setup child-setup parent-hook child-hook)
                  "the order Emacs's define-derived-mode gives")
    (check-true! (buffer-mode-is? "zz-mode-test-buf" "zz-mode-test-parent")
                 "the child is one of the parent's buffers")
    (check-equal! (keymap-parent (mode-keymap "zz-mode-test-child")) (mode-keymap "zz-mode-test-parent")
                  "the child's map falls back to the parent's")
    (remove-hook! 'zz-mode-test-parent-hook 'mode-test-parent-hook!)
    (remove-hook! 'zz-mode-test-child-hook 'mode-test-child-hook!)
    (buffer-kill! "zz-mode-test-buf")))

(deftest 'the-mode-command-enters-the-mode-and-running-it-again-keeps-it
  "a major mode's command is a setter, as in Emacs"
  (lambda ()
    (test-buffer! "zz-mode-test-buf" "x")
    (with-current-buffer "zz-mode-test-buf"
      (lambda ()
        (run-command "zz-mode-test-parent")
        (check-equal! (buffer-local (current-buffer) 'mode-name) "zz-mode-test-parent" "entered")
        (run-command "zz-mode-test-parent")
        (check-equal! (buffer-local (current-buffer) 'mode-name) "zz-mode-test-parent" "still in it")))
    (buffer-kill! "zz-mode-test-buf")))

(deftest 'a-change-of-major-mode-runs-change-major-mode-hook-and-starts-the-keys-afresh
  "the old mode's own keys go, the new mode's setup puts its keys in"
  (lambda ()
    (add-hook! 'change-major-mode-hook 'mode-test-change-hook!)
    ;; key-binding reads the window's buffer, so the buffer takes the window
    (let ((buf (test-buffer! "zz-mode-test-buf" "x")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (set-mode! "zz-mode-test-parent")
      (local-set-key "<f9> q" "keymap-test-dummy-two")
      (check-equal! (key-binding "<f9> p") "keymap-test-dummy-one" "the setup bound its key")
      (mode-test-reset!)
      (set-mode! "text-mode")
      (check-equal! *mode-test-log* '(change) "change-major-mode-hook ran once")
      (check-false! (key-binding "<f9> q") "the buffer's own binding from before is gone")
      (check-false! (key-binding "<f9> p") "and the old mode's setup binding too")
      (set-mode! "zz-mode-test-parent")
      (check-equal! (key-binding "<f9> p") "keymap-test-dummy-one" "the setup put its key back")
      (remove-hook! 'change-major-mode-hook 'mode-test-change-hook!)
      (buffer-kill! buf))))

(deftest 'a-minor-mode-runs-its-hook-when-it-turns-on
  "NAME-hook, in the buffer"
  (lambda ()
    (register-minor-mode! "zz-mode-test-minor" (lambda (b) #t) (lambda (b) #t))
    (add-hook! 'zz-mode-test-minor-hook 'mode-test-minor-hook!)
    (test-buffer! "zz-mode-test-buf" "x")
    (mode-test-reset!)
    (enable-minor-mode! "zz-mode-test-buf" "zz-mode-test-minor")
    (check-equal! *mode-test-log* '(minor-hook) "the hook ran")
    (remove-hook! 'zz-mode-test-minor-hook 'mode-test-minor-hook!)
    (buffer-kill! "zz-mode-test-buf")))

(define (mode-test-eligible? buf) (string-prefix? "zz-mode-test-global" buf))

(deftest 'a-globalized-minor-mode-turns-the-local-mode-on-everywhere-it-applies
  "on now, on for a buffer that appears, off everywhere"
  (lambda ()
    (register-minor-mode! "zz-mode-test-local" (lambda (b) #t) (lambda (b) #t))
    (define-globalized-minor-mode! "zz-mode-test-global" "zz-mode-test-local" mode-test-eligible?)
    (test-buffer! "zz-mode-test-global-a" "x")
    (test-buffer! "zz-mode-test-other" "x")
    (run-command "zz-mode-test-global")
    (check-true! (globalized-minor-mode-on? "zz-mode-test-global") "the flag is on")
    (check-true! (minor-mode-on? "zz-mode-test-global-a" "zz-mode-test-local") "an eligible buffer got it")
    (check-false! (minor-mode-on? "zz-mode-test-other" "zz-mode-test-local") "an ineligible one did not")
    (test-buffer! "zz-mode-test-global-b" "y")
    (buffer-created! "zz-mode-test-global-b")
    (check-true! (minor-mode-on? "zz-mode-test-global-b" "zz-mode-test-local") "a new buffer gets it")
    (run-command "zz-mode-test-global")
    (check-false! (minor-mode-on? "zz-mode-test-global-a" "zz-mode-test-local") "off takes it away")
    (buffer-kill! "zz-mode-test-global-a")
    (buffer-kill! "zz-mode-test-global-b")
    (buffer-kill! "zz-mode-test-other")))

(deftest 'auto-mode-alist-takes-a-regexp-and-the-interpreter-line-wins
  "a regexp entry matches the name; a shebang names the mode before the name does"
  (lambda ()
    (let ((saved *auto-mode-alist*))
      (set! *auto-mode-alist* (cons '("^zz-Makefile$" "text-mode") *auto-mode-alist*))
      (check-equal! (auto-mode-for "zz-Makefile") "text-mode" "a regexp entry matches")
      (check-equal! (auto-mode-for "a.scm") "scheme-mode" "a suffix entry still matches")
      (set! *auto-mode-alist* saved))
    (test-buffer! "zz-mode-test-script" "#!/usr/bin/env elixir\nIO.puts 1\n")
    (check-equal! (auto-mode-for-buffer "zz-mode-test-script" "zz-mode-test-script") "elixir-mode"
                  "the interpreter line names the mode")
    (let ((saved *magic-mode-alist*))
      (set! *magic-mode-alist* '(("^#!/usr/bin/env elixir" "text-mode")))
      (check-equal! (auto-mode-for-buffer "zz-mode-test-script") "text-mode" "magic beats the interpreter")
      (set! *magic-mode-alist* saved))
    (buffer-kill! "zz-mode-test-script")))

(deftest 'kill-all-local-variables-keeps-the-permanent-ones
  "a plain local goes, a permanent one stays"
  (lambda ()
    (test-buffer! "zz-mode-test-buf" "x")
    (permanent-local! 'zz-mode-test-keep)
    (buffer-set-local! "zz-mode-test-buf" 'zz-mode-test-keep 1)
    (buffer-set-local! "zz-mode-test-buf" 'zz-mode-test-drop 2)
    (kill-all-local-variables! "zz-mode-test-buf")
    (check-equal! (buffer-local "zz-mode-test-buf" 'zz-mode-test-keep) 1 "kept")
    (check-false! (buffer-local "zz-mode-test-buf" 'zz-mode-test-drop) "dropped")
    (buffer-kill! "zz-mode-test-buf")))
