;;; keymap-test.scm --- the key mechanism, on bindings this test makes itself.
;;;
;;; A test must never assert a production binding. A binding is a
;;; preference. It moves, and a test that names one goes red on the day
;;; somebody moves it — reporting a broken editor when the editor is
;;; fine. Eleven switcher tests failed together the night C-x b changed
;;; hands, and every one of them was checking the key, not the command.
;;;
;;; What is worth a test is the MECHANISM under the map: a bound key runs
;;; its command, a buffer-local binding shadows the global one, unbinding
;;; gives the global one back, and a prefix reads as a prefix. So this
;;; file binds its own dummy keys to its own dummy commands. Nothing here
;;; can go red when a real binding moves.
;;;
;;; The dummy keys hang off <f9>, which nothing binds.

(domain! 'testing)
(effects! '(write))

;; The commands are defined at the top level, on purpose. A command
;; defined inside a test body is a closure made mid-eval, and the key
;; runs it from the :ui lane in another process, which cannot resolve a
;; frame that eval has not flushed yet. See
;; docs/BUG-escaped-closure-handlers.md. Loading this file is its own
;; eval, so by the time any test runs these are flushed and shared.
(define *keymap-test-fired* '())

(define (keymap-test-fire! tag)
  (set! *keymap-test-fired* (cons tag *keymap-test-fired*)))

(define (keymap-test-reset!) (set! *keymap-test-fired* '()))

(define (keymap-test-fired? tag) (member tag *keymap-test-fired*))

(define-command "keymap-test-dummy-one" "Test command: record that it ran"
  (lambda () (keymap-test-fire! 'one)))

(define-command "keymap-test-dummy-two" "Test command: record that it ran"
  (lambda () (keymap-test-fire! 'two)))

;; <f9> is the prefix, so <f9> a and <f9> b are two full sequences under it
(define *keymap-test-key* (list "<f9>" "a"))
(define *keymap-test-free* (list "<f9>" "b"))

(define (keymap-test-press! keys)
  (keymap-test-reset!)
  (dispatch-keys keys))

;;; --- the mechanism ------------------------------------------------------------

(deftest 'a-bound-key-runs-the-command-it-names
  "bind a dummy key to a dummy command, press it, and the command ran"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (check-equal! (key-binding *keymap-test-key*) "keymap-test-dummy-one"
                  "the map answers the command the binding named")
    (keymap-test-press! *keymap-test-key*)
    (check-true! (wait-until (lambda () (keymap-test-fired? 'one)) 3000 20)
                 "and pressing the key ran it")))

(deftest 'a-local-binding-shadows-the-global-one-and-unbinding-gives-it-back
  "the same key, two meanings, chosen by the buffer it is pressed in"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (let ((buf (test-buffer! "zz-keymap-local" "shadowed")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (local-set-key* buf "<f9> a" "keymap-test-dummy-two")
      (check-equal! (key-binding *keymap-test-key*) "keymap-test-dummy-two"
                    "in this buffer the local binding wins")
      (keymap-test-press! *keymap-test-key*)
      (check-true! (wait-until (lambda () (keymap-test-fired? 'two)) 3000 20)
                   "and the key ran the local command")
      (check-false! (keymap-test-fired? 'one) "not the global one")

      (local-unset-key* buf "<f9> a")
      (check-equal! (key-binding *keymap-test-key*) "keymap-test-dummy-one"
                    "unbinding gives the global command back")
      (keymap-test-press! *keymap-test-key*)
      (check-true! (wait-until (lambda () (keymap-test-fired? 'one)) 3000 20)
                   "and the key runs it again")
      (buffer-kill! buf))))

(deftest 'a-prefix-reads-as-a-prefix
  "a key that holds a map answers prefix, and an unbound one answers #f"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (check-equal! (key-binding "<f9>") 'prefix
                  "the first key of a two-key sequence is a prefix")
    (check-false! (key-binding *keymap-test-free*)
                  "a sequence under it that nothing bound answers #f")))

(deftest 'key-binding-takes-a-string-or-a-list
  "the introspection every keymap leans on, in both shapes"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (check-equal! (key-binding "<f9> a") (key-binding *keymap-test-key*)
                  "a written sequence and a list agree")
    ;; a bad argument used to raise inside the Editor call, and an Editor
    ;; that dies loses every buffer's local keymap. An empty sequence is a
    ;; prefix of every key, so prefix is the answer — what matters is that
    ;; it answers at all.
    (check-equal! (key-binding "") 'prefix
                  "an empty sequence answers prefix, it does not raise")))

(deftest 'a-global-binding-can-be-removed
  "unbinding one global key leaves sibling keys under the same prefix"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (global-set-key "<f9> b" "keymap-test-dummy-two")
    (global-unset-key "<f9> a")
    (check-false! (key-binding "<f9> a") "the selected binding is gone")
    (check-equal! (key-binding "<f9> b") "keymap-test-dummy-two"
                  "the sibling binding remains")
    ;; leave no global binding behind for the next test
    (global-unset-key "<f9> b")))

;;; --- the map's own integrity --------------------------------------------------
;;;
;;; This one names no binding, so no rebinding can break it. It fails only
;;; for a key that runs a command no package defines, which is a dead key
;;; whatever anybody prefers.

(deftest 'every-global-binding-names-a-live-command
  "a key bound to a command that does not exist is a dead key"
  (lambda ()
    (let ((names (command-names)))
      (for-each
        (lambda (row)
          (let ((keys (car row)) (cmd (nth 1 row)))
            (check-true! (member cmd names)
                         (string-append keys " runs \"" cmd "\", which no package defines"))))
        (global-keys)))))

;;; --- the trace under the map ---------------------------------------------------
;;; trace-key presses a key the same way the GUI does and returns a state
;;; row per phase. The dummy binding keeps this free of any production key.

(deftest 'trace-key-reports-the-phases-of-one-key
  "the trace names the command it ran and ends on the after-command row"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (keymap-test-reset!)
    (let ((rows (trace-key *keymap-test-key*)))
      (check-true! (wait-until (lambda () (keymap-test-fired? 'one)) 3000 20)
                    "the traced key ran its command")
      (check-false! (null? (filter (lambda (r)
                                     (and (equal? (plist-get r 'phase) "command")
                                          (equal? (plist-get r 'name) "keymap-test-dummy-one")))
                                   rows))
                    "one row names the resolved command")
      (check-equal! (plist-get (car (reverse rows)) 'phase) "after-command"
                    "the last row reports the state after the command"))))

(deftest 'key-for-command-reads-the-buffers-own-keymap
  "the reverse lookup sees a local binding, and only in its buffer"
  (lambda ()
    (let ((buf (test-buffer! "zz-keymap-reverse" "text")))
      (local-set-key* buf "<f9> b" "keymap-test-dummy-two")
      (check-equal! (key-for-command "keymap-test-dummy-two" buf) "<f9> b"
                    "the buffer's map answers")
      (check-equal! (key-for-command "keymap-test-dummy-two" "zz-keymap-elsewhere") ""
                    "another buffer does not")
      (local-unset-key* buf "<f9> b")
      (check-equal! (key-for-command "keymap-test-dummy-two" buf) ""
                    "unbinding takes the answer with it")
      (buffer-kill! buf))))

;;; --- keymaps are named, with parents ------------------------------------------
;;; A mode's map answers for every buffer that wears the mode. A minor
;;; mode's map answers ahead of the buffer's own. All on dummy keys.

(define *keymap-test-mode-map* "zz-keymap-test-mode-map")
(define *keymap-test-minor-map* "zz-keymap-test-minor-map")
(define *keymap-test-key-c* (list "<f9>" "c"))

(deftest 'a-mode-map-answers-for-the-buffer-and-the-buffers-own-map-wins
  "use-local-map! chains the buffer's map to the mode's; local-set-key* shadows it"
  (lambda ()
    (define-keymap! *keymap-test-mode-map*)
    (define-key *keymap-test-mode-map* "<f9> c" "keymap-test-dummy-one")
    (let ((buf (test-buffer! "zz-keymap-mode" "x")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (use-local-map! buf *keymap-test-mode-map*)
      (check-equal! (buffer-local-map buf) *keymap-test-mode-map* "the parent is the mode's map")
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-one"
                    "the mode's binding answers in the buffer")
      (check-equal! (key-binding-source *keymap-test-key-c*)
                    (list "keymap-test-dummy-one" *keymap-test-mode-map*)
                    "and the source names the mode's map")
      (local-set-key* buf "<f9> c" "keymap-test-dummy-two")
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-two"
                    "the buffer's own binding wins over the mode's")
      (local-unset-key* buf "<f9> c")
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-one"
                    "and unbinding gives the mode's back")
      (buffer-kill! buf))
    (keymap-unset! *keymap-test-mode-map* "<f9> c")))

(deftest 'a-parent-chain-answers-what-the-child-does-not-bind
  "keymap-lookup walks child, parent, grandparent"
  (lambda ()
    (define-keymap! "zz-keymap-test-grand")
    (define-keymap! "zz-keymap-test-parent" "zz-keymap-test-grand")
    (define-keymap! "zz-keymap-test-child" "zz-keymap-test-parent")
    (define-key "zz-keymap-test-grand" "<f9> d" "keymap-test-dummy-one")
    (define-key "zz-keymap-test-child" "<f9> e" "keymap-test-dummy-two")
    (check-equal! (keymap-lookup "zz-keymap-test-child" "<f9> d") "keymap-test-dummy-one"
                  "the grandparent answers through the chain")
    (check-equal! (keymap-lookup "zz-keymap-test-child" "<f9>") 'prefix "and a prefix reads as a prefix")
    (check-equal! (keymap-parent "zz-keymap-test-child") "zz-keymap-test-parent" "keymap-parent reads back")
    (check-equal! (keymap-bindings "zz-keymap-test-child") '(("<f9> e" "keymap-test-dummy-two"))
                  "keymap-bindings lists the map's own only")
    (keymap-unset! "zz-keymap-test-grand" "<f9> d")
    (keymap-unset! "zz-keymap-test-child" "<f9> e")))

(deftest 'a-minor-mode-map-answers-ahead-of-the-buffers-own-and-leaves-with-the-mode
  "register-minor-mode! with a keymap: on puts the map in force, off takes it away"
  (lambda ()
    (define-keymap! *keymap-test-minor-map*)
    (define-key *keymap-test-minor-map* "<f9> c" "keymap-test-dummy-two")
    (register-minor-mode! "zz-keymap-test-minor" (lambda (b) #t) (lambda (b) #t) *keymap-test-minor-map*)
    (let ((buf (test-buffer! "zz-keymap-minor" "x")))
      (delete-other-windows!)
      (switch-to-buffer! buf)
      (local-set-key* buf "<f9> c" "keymap-test-dummy-one")
      (enable-minor-mode! buf "zz-keymap-test-minor")
      (check-equal! (buffer-minor-maps buf) (list *keymap-test-minor-map*) "the map is in force")
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-two"
                    "the minor mode's binding beats the buffer's own")
      (keymap-test-press! *keymap-test-key-c*)
      (check-true! (wait-until (lambda () (keymap-test-fired? 'two)) 3000 20)
                   "and pressing the key ran it")
      (disable-minor-mode! buf "zz-keymap-test-minor")
      (check-equal! (buffer-minor-maps buf) '() "off takes the map away")
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-one"
                    "and the buffer's own binding answers again")
      (buffer-kill! buf))))

(deftest 'a-global-minor-map-answers-everywhere-under-the-buffers-minor-maps
  "global-minor-maps! puts a map in force in every buffer, and unsetting it restores the rest"
  (lambda ()
    (define-keymap! "zz-keymap-test-global-minor")
    (define-key "zz-keymap-test-global-minor" "<f9> c" "keymap-test-dummy-two")
    (global-set-key "<f9> c" "keymap-test-dummy-one")
    (let ((before (global-minor-maps)))
      (global-minor-maps! (cons "zz-keymap-test-global-minor" before))
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-two"
                    "the global minor map beats the global map")
      (global-minor-maps! before)
      (check-equal! (key-binding *keymap-test-key-c*) "keymap-test-dummy-one"
                    "taking it away gives the global binding back"))
    (global-unset-key "<f9> c")))

(deftest 'where-is-internal-lists-every-key-of-a-command
  "two keys, one command, both reported, the tersest first"
  (lambda ()
    (global-set-key "<f9> a" "keymap-test-dummy-one")
    (global-set-key "<f9> x y" "keymap-test-dummy-one")
    (check-equal! (where-is-internal "keymap-test-dummy-one") '("<f9> a" "<f9> x y")
                  "both keys, shortest first")
    (global-unset-key "<f9> x y")))
