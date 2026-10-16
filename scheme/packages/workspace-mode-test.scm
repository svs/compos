;;; workspace-mode-test.scm --- what every workspace mode owes its buffer.
;;;
;;; code-mode, code-agent-mode and writing-mode declare their locals to
;;; define-workspace-mode!. These tests prove the contract once, on a
;;; fixture mode, so each real mode tests only what it sets.

(domain! 'testing)
(effects! '(write))

(define *t--ws-log* '())
(define (t--ws-note! entry)
  (set! *t--ws-log* (append *t--ws-log* (list entry))))

(define (t--ws-setup! buf entering?)
  (t--ws-note! (list 'setup entering?))
  (buffer-set-local! buf 'zz-ws-a "mode-a")
  (buffer-set-local! buf 'zz-ws-b "mode-b")
  (buffer-set-local! buf 'zz-ws-list '(mode))
  (buffer-set-local! buf 'zz-ws-note "changed")
  (enable-minor-mode! buf "zz-ws-helper")
  (enable-minor-mode! buf "zz-ws-other")
  ;; a choice the mode makes once: a re-run must not make it again
  (when entering? (buffer-set-local! buf 'zz-ws-pick "pinned")))

;; the fixture modes, registered fresh for each test
(define (t--ws-modes!)
  (set! *t--ws-log* '())
  (register-minor-mode! "zz-ws-helper" (lambda (b) #t) (lambda (b) #t))
  (register-minor-mode! "zz-ws-other" (lambda (b) #t) (lambda (b) #t))
  (define-workspace-mode! "zz-ws-mode"
    'locals '(zz-ws-a zz-ws-b (zz-ws-list ()))
    'modes '("zz-ws-helper" "zz-ws-other")
    'remember (list 'zz-ws-note (list 'zz-ws-computed (lambda (buf) 'computed)))
    'accepts? (lambda (buf) (not (buffer-local buf 'zz-ws-refuse)))
    'setup t--ws-setup!
    'teardown (lambda (buf saved)
                (t--ws-note! (list 'teardown (buffer-local buf 'zz-ws-a) (saved 'zz-ws-note))))
    'after (lambda (buf saved)
             (t--ws-note! (list 'after (buffer-local buf 'zz-ws-a) (saved 'zz-ws-computed))))))

(define (t--ws-buffer! name)
  (when (buffer-known? name) (buffer-kill! name))
  (test-buffer! name "text\n"))

(deftest 'a-workspace-mode-remembers-what-it-finds-and-gives-it-back
  "each declared local comes back exactly; a mode it found on stays on"
  (lambda ()
    (t--ws-modes!)
    (let ((buf (t--ws-buffer! "zz-ws-restore")))
      (buffer-set-local! buf 'zz-ws-a "mine")
      (buffer-set-local! buf 'zz-ws-note "kept")
      (enable-minor-mode! buf "zz-ws-helper")
      (enable-minor-mode! buf "zz-ws-mode")
      (check-equal! (buffer-local buf 'zz-ws-a) "mode-a" "the setup set its local")
      (check-equal! (workspace-mode-saved "zz-ws-mode" buf 'zz-ws-a) "mine"
                    "and the mode remembers what it found")
      (check-false! (workspace-mode-saved "zz-ws-mode" buf 'zz-ws-b)
                    "an absent local reads as #f")
      (check-equal! (workspace-mode-saved "zz-ws-mode" buf 'zz-ws-list) '()
                    "or as its declared default")
      (check-equal! (workspace-mode-saved "zz-ws-mode" buf 'zz-ws-computed) 'computed
                    "a reader answers a remembered value")
      (check-true! (minor-mode-on? buf "zz-ws-other") "the setup turned a mode on")

      (disable-minor-mode! buf "zz-ws-mode")
      (check-equal! (buffer-local buf 'zz-ws-a) "mine" "the local is back")
      (check-false! (buffer-local buf 'zz-ws-b) "the absent one is absent")
      (check-equal! (buffer-local buf 'zz-ws-list) '() "the defaulted one holds its default")
      (check-equal! (buffer-local buf 'zz-ws-note) "changed"
                    "a remembered local is not written back")
      (check-equal! (buffer-local buf 'minor-modes) '("zz-ws-helper")
                    "the mode it found on stays on; the one it turned on is off")
      (check-false! (buffer-local buf 'zz-ws-mode-saved) "and nothing is left to restore")
      (check-equal! *t--ws-log*
                    '((setup #t) (teardown "mode-a" "kept") (after "mine" computed))
                    "teardown sees the mode's values, after sees the buffer's own")
      (buffer-kill! buf))))
