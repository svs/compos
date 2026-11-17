;;; cua-test.scm --- Shift-selection, by the commands under the keys.
;;;
;;; The keys are preferences and no test names one. What is worth a test:
;;; the mode is on from the start, and each cua-select-* command starts a
;;; region at point when there is none and extends it.

(domain! 'testing)
(effects! '(write))

(define t--cua-buf "zz-cua-select")

(define (t--cua! text point)
  (test-buffer! t--cua-buf text)
  (buffer-goto! t--cua-buf point)
  t--cua-buf)

(define (t--cua-run! cmd)
  (with-current-buffer t--cua-buf (lambda () (run-command cmd))))

(deftest 'shift-selection-is-on-from-the-start
  "no setup step stands between a fresh editor and a Shift selection"
  (lambda ()
    (check-true! (cua-mode-on?) "cua-mode is on at boot")))

(deftest 'a-select-command-starts-a-region-and-extends-it
  "point moves, the mark stays where the selection began"
  (lambda ()
    (t--cua! "alpha\nbravo\ncharlie\n" 2)
    (t--cua-run! "cua-select-buffer-end")
    (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 2 "the mark holds the start")
    (check-equal! (buffer-point t--cua-buf) 20 "and point reached the end")
    (t--cua-run! "cua-select-buffer-start")
    (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 2 "the same region, extended")
    (check-equal! (buffer-point t--cua-buf) 0 "now to the buffer's start")
    (buffer-kill! t--cua-buf)))

(deftest 'a-page-select-extends-by-a-screenful
  "the same page the plain motion steps by, with the region held"
  (lambda ()
    (let ((lines ""))
      (let loop ((i 0) (acc ""))
        (if (= i 80)
            (set! lines acc)
            (loop (+ i 1) (string-append acc "line\n"))))
      (t--cua! lines 0)
      (t--cua-run! "cua-select-page-down")
      (check-equal! (with-current-buffer t--cua-buf (lambda () (mark))) 0 "the mark holds the start")
      (check-true! (> (buffer-point t--cua-buf) 0) "and point moved a screenful")
      (buffer-kill! t--cua-buf))))

;;; The gate: the selections answer in a buffer you are editing, and a
;;; buffer you have just landed on keeps the plain meaning of the chords.

;; key-binding answers for the frame's buffer, so the ladder is read as
;; data: the maps in force in this buffer, and the key that selects there.
(define (t--cua-in-force? map)
  (if (member map (buffer-keymaps t--cua-buf)) #t #f))

(define (t--cua-select-key)
  (key-for-command "cua-select-backward" t--cua-buf))

(define (t--cua-after! cmd)
  (with-current-buffer t--cua-buf (lambda () (editing--after-command! cmd))))

(deftest 'a-landing-buffer-keeps-the-plain-shift-chords
  "until a key says you are editing here, the Shift chords walk buffers and move between groups"
  (lambda ()
    (t--cua! "alpha bravo charlie\n" 0)
    (editing-state-off! t--cua-buf)
    (check-false! (t--cua-in-force? "cua-mode-map") "the selections are not in force on a landing")
    (check-equal! (t--cua-select-key) "" "so no key selects there")
    (editing-state-on! t--cua-buf)
    (check-true! (t--cua-in-force? "cua-mode-map") "a buffer you are editing has them")
    (check-false! (equal? (t--cua-select-key) "") "and a chord extends the region there")
    (buffer-kill! t--cua-buf)))

(deftest 'any-key-but-a-cua-chord-arms-the-buffer
  "a letter or an arrow puts the selections in force; the Shift chords never do"
  (lambda ()
    (t--cua! "alpha bravo charlie\n" 0)
    (editing-state-off! t--cua-buf)
    (t--cua-after! "previous-buffer")
    (check-false! (editing-state? t--cua-buf) "the buffer walk leaves the buffer as it found it")
    (t--cua-after! "group-tab-left")
    (check-false! (editing-state? t--cua-buf) "and so does the group move")
    (t--cua-after! "cua-select-forward")
    (check-false! (editing-state? t--cua-buf) "a selection is no evidence either")
    (t--cua-after! "forward-char")
    (check-true! (editing-state? t--cua-buf) "a plain arrow arms it")
    (editing-state-off! t--cua-buf)
    (t--cua-after! "self-insert-command")
    (check-true! (editing-state? t--cua-buf) "and so does a letter")
    (buffer-kill! t--cua-buf)))
