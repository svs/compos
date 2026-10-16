;;; peek-test.scm --- a look at a file opens it beside the reader; the reader keeps focus.

(domain! 'testing)
(effects! '(write))

(define t--peek-dir (string-append (compos-home) "/look-test"))

(define (t--peek-file name text)
  (let ((p (string-append t--peek-dir "/" name)))
    (write-file! p text)
    p))

;; every test starts from one window on *scratch* and ends there
(define (t--peek-with thunk)
  (make-directory! t--peek-dir)
  (switch-to-buffer! "*scratch*")
  (run-command "delete-other-windows")
  (let ((out (thunk)))
    (for-each (lambda (b)
                (when (string-prefix? t--peek-dir b) (buffer-kill! b)))
              (buffer-list))
    (set! *peek-recent* '())
    ;; a look the last test scheduled must not land in the next one
    (debounce-cancel! "dired-peek")
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

(deftest 'a-peek-shows-in-another-window-and-the-selected-window-stays
  "the file is beside the reader, and the reader keeps its window and focus"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let* ((a (t--peek-file "a.txt" "alpha"))
               (me (active-window)))
          (peek-file! a)
          (check-equal! (current-buffer) "*scratch*" "the reader stays put")
          (check-equal! (active-window) me "the focus stays")
          (check-true! (and (window-showing a) #t) "a window shows the file")
          (check-false! (equal? (window-showing a) me) "and it is not the reader's window"))))))

(deftest 'a-look-does-not-open-a-file-over-the-cap
  "a look at a big file shows nothing and opens nothing; RET still opens it"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((big (t--peek-file "big.txt" (string-repeat "x" 4096))))
          (with-stub 'peek-max-file-size 2048
            (lambda ()
              (check-true! (peek-too-big? big) "over the cap")
              (check-false! (peek-file! big) "a look answers #f")
              (check-false! (buffer-known? big) "and nothing opened it")
              (visit big)
              (check-true! (buffer-known? big) "a visit the reader asked for still opens it")
              (buffer-kill! big)))
          (with-stub 'peek-max-file-size 0
            (lambda ()
              (check-false! (peek-too-big? (t--peek-file "big2.txt" (string-repeat "x" 4096)))
                            "0 removes the cap"))))))))








(deftest 'the-other-window-scroll-reads-the-float-first
  "M-<down> from the listing scrolls the float (the card), not the next split"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha"))
              (me (active-window)))
          (split-window! 'h 0.5)
          (select-window! me)
          (peek-file! a)
          (check-equal! (scroll-other-window-target) (window-showing a)
                        "the file's window is the target")
          (buffer-create "*zz-plain-float*")
          (float-show! "*zz-plain-float*" 'right 0.3)
          (select-window! me)
          (check-equal! (scroll-other-window-target) (float-window)
                        "a float beside your work is the target")
          (float-close!)
          (buffer-kill! "*zz-plain-float*"))))))

(deftest 'a-rested-look-fires-only-where-it-was-scheduled
  "the reader moved on: the look does nothing"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha"))
              (me (active-window)))
          (split-window! 'h 0.5)
          (other-window!)
          (dired--peek-now! (list a #f me "*scratch*"))
          (check-false! (window-showing a) "no look: the reader is in another window")
          (select-window! me)
          (dired--peek-now! (list a #f me "*scratch*"))
          (check-true! (and (window-showing a) #t) "back where it was scheduled, the look fires"))))))



(deftest 'dired-up-returns-to-the-row-you-came-down-from
  "the parent remembers: the row you left it on is the directory you went into"
  (lambda ()
    (t--peek-with
      (lambda ()
        (t--peek-file "a.txt" "alpha\n")
        (let* ((parent (dired-parent (dired-normalize-dir t--peek-dir)))
               (child (string-append (cadr (path-split (dired-normalize-dir t--peek-dir))) "/")))
          (dired-open parent)
          (let ((p (current-buffer)))
            (let loop ((i 0))
              (when (and (< i 40) (not (equal? (dired-entry) child)))
                (list-move-in! p 1)
                (loop (+ i 1))))
            (check-equal! (dired-entry) child "the reader points at the child")
            (run-command "dired-visit")
            (check-equal! (dired-dir (current-buffer)) (dired-normalize-dir t--peek-dir) "and goes in")
            (run-command "dired-up")
            (check-equal! (current-buffer) p "up is the parent listing")
            (check-equal! (dired-entry) child "on the row the reader left it on")
            (buffer-kill! p)))))))

(deftest 'dired-opened-again-keeps-its-row
  "the point is the reader's: a listing opened again stays on the row it was on"
  (lambda ()
    (t--peek-with
      (lambda ()
        (t--peek-file "a.txt" "alpha\n")
        (t--peek-file "b.txt" "beta\n")
        (dired-open t--peek-dir)
        (let ((d (current-buffer)))
          (let loop ((i 0))
            (when (and (< i 20) (not (equal? (dired-entry) "b.txt")))
              (list-move-in! d 1)
              (loop (+ i 1))))
          (check-equal! (dired-entry) "b.txt" "the reader points at b")
          (switch-to-buffer! "*scratch*")
          (dired-open t--peek-dir)
          (check-equal! (dired-entry) "b.txt" "opened again, still at b")
          (run-command "dired-up")
          (dired-open t--peek-dir)
          (check-equal! (dired-entry) "b.txt" "back from the parent, still at b")
          (buffer-kill! d))))))
