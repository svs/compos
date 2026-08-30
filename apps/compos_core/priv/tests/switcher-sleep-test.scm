;;; switcher-sleep-test.scm --- a dormant buffer is still a row.
;;;
;;; The modal switcher previews a dormant candidate by waking it. When the
;;; switcher closes, every woken buffer nobody picked goes back to sleep —
;;; and a dormant row stays a row: RET wakes it, C-k kills it.
;;;
;;; The switcher is opened by its own command. These tests were pressing
;;; C-x b, which named the modal switcher until groups.scm took that key
;;; for the group-aware prompt on 2026-08-23; the tests failed together
;;; and none of them said why. keymap-test.scm now asserts the binding, so
;;; the next hand-over fails one test instead of eleven.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "opens the modal switcher and sleeps buffers, which a live editor is using")

(define t--ss-n 0)

(define (t--ss-unique label)
  (set! t--ss-n (+ t--ss-n 1))
  (string-append "*zz-" label "-" (number->string t--ss-n) "*"))

;; a buffer with history presence, then made dormant — the shape most of
;; the switcher pool has
(define (t--ss-dormant! label)
  (let ((name (t--ss-unique label))
        (here (current-buffer)))
    (test-buffer! name "asleep")
    (switch-to-buffer! name)
    (switch-to-buffer! here)
    (buffer-sleep! name)
    name))

(define (t--ss-open!)
  ;; the suite shares one editor: a switcher another test left open, or a
  ;; live prompt, changes what this one sees
  (when (minibuffer-state) (minibuffer-cancel!))
  (when (buffer-known? "*switch*") (buffer-kill! "*switch*"))
  (delete-other-windows!)
  (run-command "switch-to-buffer"))

(define (t--ss-type! text)
  (dispatch-keys (map (lambda (i) (substring text i (+ i 1)))
                      (let loop ((i 0) (out '()))
                        (if (>= i (string-length text)) (reverse out)
                            (loop (+ i 1) (cons i out))))))
  (wait-until (lambda () (equal? (list-query "*switch*") text)) 3000 20))

(define (t--ss-done!)
  (when (buffer-known? "*switch*") (buffer-kill! "*switch*"))
  (delete-other-windows!))

(deftest 'narrowing-to-a-dormant-candidate-wakes-it-and-leaving-sleeps-it
  "the preview wakes a sleeper; quitting puts it back"
  (lambda ()
    (let ((dorm (t--ss-dormant! "doze")))
      (t--ss-open!)
      (check-equal! (current-buffer) "*switch*" "the switcher opened")
      (t--ss-type! (substring dorm 1 (- (string-length dorm) 1)))
      (check-true! (wait-until (lambda () (buffer-exists? dorm)) 3000 20)
                   "the preview woke the sleeper")

      (run-command "switch-quit")
      (check-true! (wait-until (lambda () (not (buffer-exists? dorm))) 3000 20)
                   "and leaving put it back to sleep")
      (check-true! (buffer-known? dorm) "while the store still knows it"))
    (t--ss-done!)))

(deftest 'visiting-keeps-the-pick-awake-and-sleeps-the-other-woken-candidate
  "only the one you chose stays"
  (lambda ()
    (let ((pick (t--ss-dormant! "pick"))
          (other (t--ss-dormant! "other")))
      (t--ss-open!)
      (t--ss-type! (substring other 1 (- (string-length other) 1)))
      (check-true! (wait-until (lambda () (buffer-exists? other)) 3000 20) "the other woke")

      (list-set-query! "*switch*" "")
      (t--ss-type! (substring pick 1 (- (string-length pick) 1)))
      (check-true! (wait-until (lambda () (buffer-exists? pick)) 3000 20) "the pick woke")

      (run-command "switch-visit")
      (check-true! (buffer-exists? pick) "the pick is awake")
      (check-equal! (current-buffer) pick "and we are in it")
      (check-true! (wait-until (lambda () (not (buffer-exists? other))) 3000 20)
                   "the other went back to sleep")
      (check-true! (buffer-known? other) "and is still known")
      (buffer-kill! pick))
    (t--ss-done!)))

(deftest 'kill-removes-the-dormant-buffer-the-row-names
  "a row you never woke is still a buffer you can kill"
  (lambda ()
    (let ((dorm (t--ss-dormant! "kill")))
      (t--ss-open!)
      (t--ss-type! (substring dorm 1 (- (string-length dorm) 1)))
      (let ((mark (string-length (messages-text))))
        (run-command "switch-kill")
        (check-false! (buffer-known? dorm) "the store no longer knows it")
        (let ((said (messages-text)))
          (check-contains! (substring said mark (string-length said)) "killed 1 buffer"
                           "and it says what it did")))
      (run-command "switch-quit"))
    (t--ss-done!)))

(deftest 'a-verb-acts-on-the-nearest-row-when-point-sits-in-the-chrome
  "point below every row is still pointing at the last one"
  (lambda ()
    (let ((dorm (t--ss-dormant! "chrome")))
      (t--ss-open!)
      (t--ss-type! (substring dorm 1 (- (string-length dorm) 1)))

      ;; point below every row: on the key bar
      (buffer-goto! "*switch*" (- (buffer-size "*switch*") 3))
      (check-equal! (car (list-current "*switch*")) dorm "the nearest row is the answer")

      (run-command "switch-visit")
      (check-true! (buffer-exists? dorm) "the verb visited it")
      (check-equal! (current-buffer) dorm "and we are in it")
      (buffer-kill! dorm))
    (t--ss-done!)))

(deftest 'a-row-for-a-buffer-killed-elsewhere-leaves-on-the-next-command
  "the list is derived, so any command re-derives it"
  (lambda ()
    (let ((victim (t--ss-unique "gone"))
          (here (current-buffer)))
      (test-buffer! victim "")
      (switch-to-buffer! victim)
      (switch-to-buffer! here)

      (t--ss-open!)
      (check-true! (member victim (map car (list-entries "*switch*"))) "the row is listed")

      (buffer-kill! victim)
      (check-false! (buffer-exists? victim) "the buffer is gone")

      ;; any command re-renders the list, and the stamp moves on the key
      ;; path — so this dispatches rather than calling the command
      (dispatch-keys (list "C-n"))
      (check-true! (wait-until
                     (lambda () (not (member victim (map car (list-entries "*switch*")))))
                     3000 20)
                   "and the row went with it")
      (run-command "switch-quit"))
    (t--ss-done!)))
