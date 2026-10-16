;;; test-test.scm --- the fixtures in test.scm put back what they changed.
;;;
;;; A fixture that leaks is worse than none: the next test reads what it
;;; left, and the failure shows up in a file that did nothing wrong. Each
;;; test here changes state through a fixture, raises half way once, and
;;; reads the state back.

(domain! 'testing)
(effects! '(write))

(define *zz-fixture-probe* 'original)
(define *zz-fixture-other* 'other)

(deftest 'with-stub-replaces-a-global-for-the-thunk-and-puts-it-back
  "the thunk sees the stub and its value comes through; after it the old value is back"
  (lambda ()
    (set! *zz-fixture-probe* 'original)
    (check-equal! (with-stub '*zz-fixture-probe* 'stubbed (lambda () *zz-fixture-probe*))
                  'stubbed "the thunk sees the stub")
    (check-equal! *zz-fixture-probe* 'original "the old value is back")
    (ignore-errors
      (lambda () (with-stub '*zz-fixture-probe* 'stubbed (lambda () (error "zz boom")))))
    (check-equal! *zz-fixture-probe* 'original "and back after an error")))

(deftest 'with-stub-unbinds-a-name-that-had-no-binding
  "a stub of a name nobody defined leaves no global behind"
  (lambda ()
    (when (boundp 'zz-fixture-unbound) (unbind-global! 'zz-fixture-unbound))
    (check-equal! (with-stub 'zz-fixture-unbound 7 (lambda () (symbol-value 'zz-fixture-unbound)))
                  7 "the thunk sees the value")
    (check-false! (boundp 'zz-fixture-unbound) "the name is unbound again")))

(deftest 'with-stubs-sets-every-pair-and-puts-each-back
  "several globals at once, each restored, also after an error"
  (lambda ()
    (set! *zz-fixture-probe* 'original)
    (set! *zz-fixture-other* 'other)
    (check-equal! (with-stubs (list (list '*zz-fixture-probe* 1) (list '*zz-fixture-other* 2))
                    (lambda () (list *zz-fixture-probe* *zz-fixture-other*)))
                  '(1 2) "both stubs are in place inside")
    (check-equal! (list *zz-fixture-probe* *zz-fixture-other*) '(original other)
                  "both come back after")
    (ignore-errors
      (lambda ()
        (with-stubs (list (list '*zz-fixture-probe* 1) (list '*zz-fixture-other* 2))
          (lambda () (error "zz boom")))))
    (check-equal! (list *zz-fixture-probe* *zz-fixture-other*) '(original other)
                  "and after an error")
    (check-equal! (with-stubs '() (lambda () 'ran)) 'ran "no pairs is a plain call")))

(deftest 'with-custom-runs-the-setter-on-the-way-in-and-out
  "a setting with a setter sees the new value, then the old one, also after an error"
  (lambda ()
    (with-stub '*custom-vars* *custom-vars*
      (lambda ()
        (let ((sets '()))
          (defcustom 'zz-fixture-setting "a" "A fixture setting."
            'type 'string 'set (lambda (v) (set! sets (cons v sets))))
          (set-symbol-value! 'zz-fixture-setting "a")
          (check-equal! (with-custom 'zz-fixture-setting "b"
                          (lambda () (symbol-value 'zz-fixture-setting)))
                        "b" "the thunk sees the new value")
          (check-equal! (symbol-value 'zz-fixture-setting) "a" "the old value is back")
          (check-equal! sets '("a" "b") "the setter ran with the new value, then the old")
          (ignore-errors
            (lambda () (with-custom 'zz-fixture-setting "c" (lambda () (error "zz boom")))))
          (check-equal! (symbol-value 'zz-fixture-setting) "a" "and back after an error")
          (check-equal! (with-customs (list (list 'zz-fixture-setting "d"))
                          (lambda () (symbol-value 'zz-fixture-setting)))
                        "d" "with-customs takes pairs")
          (check-equal! (symbol-value 'zz-fixture-setting) "a" "and puts them back")
          (unbind-global! 'zz-fixture-setting)
          (test-forget-catalog! "setting" 'zz-fixture-setting))))))

(deftest 'with-fresh-group-makes-the-record-and-deletes-it
  "the record exists for FN alone; a stale copy goes first; a dissolve inside is fine"
  (lambda ()
    (let ((name "zz-fixture-group"))
      (with-fresh-group name
        (lambda (id)
          (check-equal! (group-resolve-id name) id "the record exists inside")))
      (check-false! (group-resolve-id name) "and is gone after")
      (let ((stale (group-record-create! name)))
        (with-fresh-group name
          (lambda (id)
            (check-false! (equal? id stale) "a stale record is replaced by a new one")
            (check-equal! (group-resolve-id name) id "and the name resolves to the new one")))
        (check-false! (group-resolve-id name) "the new one is gone after"))
      (ignore-errors
        (lambda () (with-fresh-group name (lambda (id) (error "zz boom")))))
      (check-false! (group-resolve-id name) "gone after an error")
      (with-fresh-group name (lambda (id) (group-record-delete! id)))
      (check-false! (group-resolve-id name) "a record FN deleted itself raises nothing"))))

(deftest 'with-frame-selects-a-new-frame-and-comes-back
  "FN runs in a frame of its own; the old frame is selected after and the new one is gone"
  (lambda ()
    (let ((home (selected-frame))
          (count (length (frame-list))))
      (let ((made (with-frame
                    (lambda (frame)
                      (check-equal! (selected-frame) frame "the new frame is selected inside")
                      (check-false! (equal? frame home) "and it is not the old one")
                      frame))))
        (check-equal! (selected-frame) home "the old frame is selected after")
        (check-false! (member made (frame-list)) "the new frame is gone"))
      (ignore-errors (lambda () (with-frame (lambda (frame) (error "zz boom")))))
      (check-equal! (selected-frame) home "the old frame is selected after an error")
      (check-equal! (length (frame-list)) count "and no frame leaks"))))
