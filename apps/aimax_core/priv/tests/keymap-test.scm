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
                  "the sibling binding remains")))

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
