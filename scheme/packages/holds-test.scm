;;; holds-test.scm --- holds keep their contracts: they open, they end, they gate a reload.

(require 'holds)

(define (t--holds-clear!) (for-each (lambda (h) (release! (plist-get h 'id))) (holds)))

(deftest 'holds-open-and-release
  "hold! answers an id that holds lists with its kind and why; release! ends it once"
  (lambda ()
    (t--holds-clear!)
    (let ((id (hold! 'reload "a run" "user")))
      (check-equal! (map (lambda (h) (list (plist-get h 'id) (plist-get h 'kind) (plist-get h 'why))) (holds))
                    (list (list id 'reload "a run")) "the hold is open")
      (check-equal! (holds 'test) '() "KIND keeps one kind")
      (check-true! (release! id) "release! ends it")
      (check-false! (release! id) "a second release! finds nothing")
      (check-equal! (holds) '() "no hold is open"))))

(deftest 'holds-test-is-one-at-a-time
  "a test hold refuses a second owner and names the holder; the same owner may take another"
  (lambda ()
    (t--holds-clear!)
    (buffer-create "zz-holds-owner")
    (let ((a (hold! 'test "suite a" "user")))
      (check-false! (ignore-errors (lambda () (hold! 'test "suite b" "zz-holds-owner"))) "a second owner is refused")
      (check-equal! (map (lambda (h) (plist-get h 'why)) (holds 'test)) '("suite a") "and holds nothing")
      (let ((b (hold! 'test "suite c" "user")))
        (check-equal! (length (holds 'test)) 2 "the same owner takes another")
        (release! b))
      (release! a))
    (buffer-kill! "zz-holds-owner")))

(deftest 'holds-die-with-their-owner
  "a hold whose owner chat is gone is not open"
  (lambda ()
    (t--holds-clear!)
    (buffer-create "zz-holds-owner")
    (hold! 'reload "a run" "zz-holds-owner")
    (check-equal! (length (holds)) 1 "open while its owner lives")
    (buffer-kill! "zz-holds-owner")
    (check-equal! (holds) '() "gone with its owner")))

(deftest 'holds-gate-an-agent-save-not-the-user
  "an agent's save of reloadable source is refused while a reload hold is open; the user's save goes"
  (lambda ()
    (t--holds-clear!)
    (let ((src (string-append (compos-config-dir) "/packages/zz-holds-probe.scm"))
          (txt (string-append (compos-config-dir) "/packages/zz-holds-probe.txt")))
      (check-true! (holds-reloadable? src) "a package under the config home reloads")
      (check-false! (holds-reloadable? txt) "a text file does not")
      (check-false! (holds-reloadable? (string-append (compos-config-dir) "/packages/zz-test.scm")) "nor a test file")
      (check-false! (holds-reload-refusal src) "no hold, no refusal")
      (let ((id (hold! 'reload "a run" "user")))
        (check-contains! (or (with-edit-author "agent:zz" (lambda () (write-refusal src "zz" #f))) "")
                         "reload-waits-for-holds" "an agent's save is refused")
        (check-false! (with-edit-author "agent:zz" (lambda () (write-refusal txt "zz" #f))) "a file that does not reload saves")
        (check-false! (with-edit-author "user" (lambda () (write-refusal src "zz" #f))) "the user's save goes")
        (release! id)
        (check-false! (with-edit-author "agent:zz" (lambda () (write-refusal src "zz" #f))) "after the release the agent saves")))))
