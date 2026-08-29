;;; peek-test.scm --- look at a definition, then go or discard.
;;;
;;; definition-peek shows the definition of the name at point in the
;;; other window and keeps focus. The post-command hook decides what
;;; happens next: while the reader stays where the peek was made it
;;; stays, when the reader moves it is discarded, and the peek run again
;;; on the same name goes there. The tests call the hook by hand, because
;;; run-command from Scheme does not pass through the dispatcher that
;;; runs it.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "the tests split and delete windows and reset zz- buffers")

(define t--peek-doc "zz-peek-doc.md")
(define t--peek-defs "zz-peek-defs.scm")

;; the doc names the definition; point lands inside the name
(define (t--peek-setup!)
  (peek-discard!)
  (run-command "delete-other-windows")
  (test-buffer! t--peek-defs ";; a source\n(define (zz-peek-target) 1)\n")
  (with-current-buffer t--peek-defs (lambda () (set-mode! "scheme-mode")))
  (test-buffer! t--peek-doc "see `zz-peek-target` here\n")
  (with-current-buffer t--peek-doc (lambda () (set-mode! "morg-mode")))
  (switch-to-buffer! t--peek-doc)
  (buffer-goto! t--peek-doc 8))

(define (t--peek-teardown!)
  (peek-discard!)
  (run-command "delete-other-windows")
  (when (buffer-exists? t--peek-doc) (buffer-kill! t--peek-doc))
  (when (buffer-exists? t--peek-defs) (buffer-kill! t--peek-defs)))

(deftest 'definition-locate-finds-a-definition-in-an-open-scheme-buffer
  "the catalog chain answers with the source kind, the target, and the byte position"
  (lambda ()
    (t--peek-setup!)
    (let ((hit (definition-locate "zz-peek-target")))
      (check-true! hit "the name has a definition")
      (check-equal! 'buffer (car hit) "an open scheme buffer is a buffer source")
      (check-equal! t--peek-defs (cadr hit) "the target is that buffer")
      (check-equal! 12 (caddr hit) "the position is the defining form"))
    (t--peek-teardown!)))

(deftest 'a-located-file-is-the-source-file
  "a bundled definition resolves to the checkout's priv, not the build symlink"
  (lambda ()
    (let ((hit (definition-locate "definition-peek" 'command)))
      (check-true! hit "a bundled command has a definition")
      (check-equal! 'file (car hit) "it is a file source")
      (check-false! (string-contains? (cadr hit) "_build") "the path names the source tree")
      (check-true! (string-suffix? "priv/packages/peek.scm" (cadr hit)) "and the right file"))))

(deftest 'definition-peek-shows-the-definition-and-keeps-focus
  "the other window shows the source at the definition; the active window does not change"
  (lambda ()
    (t--peek-setup!)
    (let ((origin (active-window))
          (before (length (window-list))))
      (run-command "definition-peek")
      (check-equal! origin (active-window) "focus stays in the doc")
      (check-equal! (+ before 1) (length (window-list)) "one window was added")
      (check-true! (window-showing t--peek-defs) "the source is on screen")
      (check-equal! 12 (buffer-point t--peek-defs) "at the definition")
      (check-equal! t--peek-doc (current-buffer) "the doc is still current"))
    (t--peek-teardown!)))

(deftest 'moving-on-discards-the-peek
  "the hook keeps the peek while the reader stays put, and closes it when point moves"
  (lambda ()
    (t--peek-setup!)
    (let ((origin (active-window))
          (before (length (window-list))))
      (run-command "definition-peek")
      (peek--post-command!)
      (peek--post-command!)
      (check-true! (window-showing t--peek-defs) "the hook may run twice; the peek stays")
      (buffer-goto! t--peek-doc 3)
      (peek--post-command!)
      (check-false! (window-showing t--peek-defs) "moving point closes the window")
      (check-equal! before (length (window-list)) "the split is gone")
      (check-equal! origin (active-window) "focus is where it was")
      (check-true! (buffer-exists? t--peek-defs) "a buffer that was open before stays open"))
    (t--peek-teardown!)))

(deftest 'definition-peek-again-goes-there
  "the second run on the same name selects the peek window and keeps it"
  (lambda ()
    (t--peek-setup!)
    (let ((origin (active-window)))
      (run-command "definition-peek")
      (peek--post-command!)
      (run-command "definition-peek")
      (peek--post-command!)
      (check-false! (equal? origin (active-window)) "focus moved to the source")
      (check-equal! t--peek-defs (current-buffer) "the source is current")
      (check-equal! 12 (point) "at the definition")
      (peek--post-command!)
      (check-true! (window-showing t--peek-defs) "the window is kept after going there"))
    (t--peek-teardown!)))

(deftest 'a-peek-on-another-name-replaces-the-first
  "one peek window at a time; the new name takes it over"
  (lambda ()
    (t--peek-setup!)
    (buffer-insert! t--peek-defs 0 "(define (zz-peek-other) 2)\n")
    (buffer-goto! t--peek-doc 8)
    (run-command "definition-peek")
    (peek--post-command!)
    (let ((count (length (window-list))))
      (buffer-delete-range! t--peek-doc 0 (buffer-size t--peek-doc))
      (buffer-insert! t--peek-doc 0 "see `zz-peek-other` here\n")
      (buffer-goto! t--peek-doc 8)
      (run-command "definition-peek")
      (peek--post-command!)
      (check-equal! count (length (window-list)) "no second window")
      (check-equal! 0 (buffer-point t--peek-defs) "the window moved to the other definition"))
    (t--peek-teardown!)))

(deftest 'no-name-at-point-changes-nothing
  "an empty spot leaves the windows alone"
  (lambda ()
    (t--peek-setup!)
    (buffer-goto! t--peek-doc 3)
    (let ((before (length (window-list))))
      (run-command "definition-peek")
      (check-equal! before (length (window-list)) "no window was added")
      (check-false! *peek* "no peek is recorded"))
    (t--peek-teardown!)))
