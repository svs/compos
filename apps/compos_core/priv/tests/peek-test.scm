;;; peek-test.scm --- editor.scm's peek: look at a buffer without keeping it.
;;;
;;; A peek shows in the popup, read-only. The next peek replaces it and
;;; kills what the first peek made. A buffer that existed before is only
;;; shown. RET again, or M-RET, opens it as your own. q dismisses it. A
;;; replaced peek leaves a row in recent, and the switcher lists it.

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
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

(deftest 'a-peek-shows-in-the-popup-and-the-selected-window-stays
  "the file is in the popup, marked, read-only, and the reader did not move"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let* ((a (t--peek-file "a.txt" "alpha\n"))
               (me (active-window)))
          (peek-file! a)
          (check-equal! (current-buffer) "*scratch*" "the reader stays put")
          (check-equal! (active-window) me "in the same window")
          (check-true! (peek-buffer? a) "the file is a peek")
          (check-true! (popup-open?) "the popup is open")
          (check-equal! (popup-buffer) a "and shows the file")
          (check-true! (buffer-read-only? a) "read-only")
          (check-contains! (buffer-modeline-name a) "peek" "and its modeline says so"))))))

(deftest 'the-next-peek-replaces-the-last-and-kills-what-peek-made
  "one peek at a time; a buffer that existed before is only shown"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let* ((a (t--peek-file "a.txt" "alpha\n"))
               (b (t--peek-file "b.txt" "beta\n"))
               (c (t--peek-file "c.txt" "gamma\n")))
          ;; c is a real buffer before any peek
          (visit c)
          (switch-to-buffer! "*scratch*")
          (run-command "delete-other-windows")
          (peek-file! a)
          (let ((slot (window-showing a)))
            (peek-file! b)
            (check-equal! (window-showing b) slot "b took a's window")
            (check-false! (buffer-exists? a) "a is gone")
            (check-equal! (length (window-list)) 2 "and no third window opened")
            (peek-file! c)
            (check-equal! (window-showing c) slot "c shows in the slot")
            (check-false! (peek-buffer? c) "but c is not a peek: it existed")
            (check-false! (buffer-exists? b) "b is gone")
            (peek-file! a)
            (check-true! (buffer-exists? c) "c survives being replaced")
            (check-true! (peek-buffer? a) "a is a peek again")))))))

(deftest 'peeks-of-existing-buffers-share-the-slot-window
  "ibuffer walking ten buffers opens one window, not ten"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (b (t--peek-file "b.txt" "beta\n")))
          (visit a) (visit b)
          (switch-to-buffer! "*scratch*")
          (run-command "delete-other-windows")
          (peek! a (lambda () a))
          (let ((slot (window-showing a)))
            (peek! b (lambda () b))
            (check-equal! (window-showing b) slot "b took the same slot")
            (check-equal! (length (window-list)) 2 "two windows, not three")
            (check-true! (buffer-exists? a) "a existed before: not killed")
            (check-false! (peek-buffer? a) "and was never a peek")))))))

(deftest 'ret-again-opens-the-peek-here
  "peek-or-open!: the first call peeks, the second opens it as your own in the selected window"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (me (active-window)))
          (check-equal! (peek-or-open! a (lambda () (visit a))) 'peek "first: a peek")
          (check-true! (peek-buffer? a) "marked")
          (check-equal! (current-buffer) "*scratch*" "reader stayed")
          (check-equal! (peek-or-open! a (lambda () (visit a))) 'open "second: opened")
          (check-false! (peek-buffer? a) "the mark is gone")
          (check-equal! (current-buffer) a "and the reader is in it")
          (check-false! (equal? (active-window) me) "in another window: never on top of the listing")
          (check-equal! (window-buffer me) "*scratch*" "the listing's window keeps the listing")
          (check-false! (popup-open?) "the popup gave it up")
          (check-false! (buffer-read-only? a) "writable")
          (check-false! (string-contains? (buffer-modeline-name a) "peek")
                        "the modeline is plain again")
          ;; the next peek gets a fresh popup; the opened buffer stays put
          (let ((b (t--peek-file "b.txt" "beta\n")))
            (peek-file! b)
            (check-true! (popup-open?) "a fresh popup")
            (check-equal! (popup-buffer) b "with the new peek")
            (check-equal! (current-buffer) a "and the opened buffer stays where it is")))))))

(deftest 'a-peek-is-read-only-and-keep-makes-it-writable
  "a look changes nothing; kept, the file is yours to edit"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (peek-file! a)
          (check-true! (buffer-read-only? a) "the peek is read-only")
          (peek-keep! a)
          (check-false! (peek-buffer? a) "kept")
          (check-false! (buffer-read-only? a) "and writable again")
          (buffer-insert! a 0 "x")
          (check-true! (buffer-modified? a) "so an edit lands"))))))

(deftest 'an-agents-edit-keeps-a-peeked-file
  "a change from outside the keyboard makes the buffer yours"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (peek-file! a)
          ;; the editor's own insert is not a keystroke: read-only stops keys
          (buffer-insert! a 0 "x")
          (peek-keep-if-edited! a)
          (check-false! (peek-buffer? a) "the edit kept it")
          (check-true! (buffer-modified? a) "and the edit is still there"))))))

(deftest 'q-closes-the-peek-and-its-window-and-remembers-it
  "the layout is what it was; recent knows the file"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (peek-file! a)
          (select-window! (window-showing a))
          (run-command "quit-window")
          (check-false! (buffer-exists? a) "the peek is gone")
          (check-equal! (length (window-list)) 1 "and so is its window")
          (check-equal! (current-buffer) "*scratch*" "back where the reader was")
          (let ((e (peek-recent-find a)))
            (check-true! (and e #t) "recent has the file")
            (check-equal! (nth 1 e) 'file "as a file")
            (peek-revive! e)
            (check-true! (peek-buffer? a) "and it comes back as a peek")))))))

(deftest 'a-kept-buffer-leaves-recent
  "keeping is the opposite of letting go"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (b (t--peek-file "b.txt" "beta\n")))
          (peek-file! a)
          (peek-file! b)
          (check-true! (and (peek-recent-find a) #t) "a went to recent")
          (peek-file! a)
          (peek-keep! a)
          (check-false! (peek-recent-find a) "kept: out of recent"))))))

(deftest 'the-switcher-hides-peeks-and-lists-recent
  "a peek is a look, not a buffer of yours"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (b (t--peek-file "b.txt" "beta\n")))
          (peek-file! a)
          (peek-file! b)
          (buffer-create "*switch*")
          (buffer-set-local! "*switch*" 'switch-here "*scratch*")
          (let ((rows (map car (switch-buffer-rows "*switch*"))))
            (check-false! (member b rows) "the live peek is not a row")
            (check-true! (and (member a rows) #t) "the replaced one is a recent row"))
          (let ((row (car (filter switch-recent-row? (switch-buffer-rows "*switch*")))))
            (check-contains! (nth 1 row) "recent" "and says so"))
          (buffer-kill! "*switch*")
          ;; C-x b is group-switch-buffer: the same two rules there
          (when (boundp 'group-buffer-switch-candidates)
            (let ((names (map car (group-buffer-switch-candidates #f "*scratch*"))))
              (check-false! (member b names) "the live peek is not a candidate")
              (check-true! (and (member a names) #t) "the replaced one is")
              (check-true! (and (member "recent" names) #t) "under a recent heading"))))))))

(deftest 'dired-ret-peeks-a-file-and-ret-again-keeps-it
  "the listing is yours; the file is a look until you say so"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (dired-open t--peek-dir)
          (let ((d (current-buffer)))
            (check-equal! (buffer-local d 'mode-name) "Dired" "dired is open")
            (check-false! (peek-buffer? d) "and is not a peek")
            ;; put point on a.txt
            (let loop ((i 0))
              (when (and (< i 20) (not (equal? (dired-entry) "a.txt")))
                (list-move-in! d 1)
                (loop (+ i 1))))
            (check-equal! (dired-entry) "a.txt" "point is on the file")
            (run-command "dired-visit")
            (check-equal! (current-buffer) d "still in dired")
            (check-true! (peek-buffer? a) "the file is a peek in the popup")
            (check-equal! (popup-buffer) a "in the popup")
            (let ((me (active-window)))
              (run-command "dired-visit")
              (check-equal! (current-buffer) a "the second RET opened it")
              (check-false! (peek-buffer? a) "and it is no peek")
              (check-false! (popup-open?) "the popup gave it up")
              (check-equal! (window-buffer me) d "beside dired, not on top of it"))
            (buffer-kill! d)))))))

(deftest 'dired-q-dismisses-the-peek-and-then-leaves
  "q with a peek showing takes the peek; q with none takes dired"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (dired-open t--peek-dir)
          (let ((d (current-buffer)))
            (let loop ((i 0))
              (when (and (< i 20) (not (equal? (dired-entry) "a.txt")))
                (list-move-in! d 1)
                (loop (+ i 1))))
            (run-command "dired-visit")
            (check-true! (peek-buffer? a) "a peek shows")
            (run-command "dired-quit")
            (check-false! (buffer-exists? a) "q took the peek")
            (check-false! (popup-open?) "and the popup")
            (check-equal! (current-buffer) d "dired stays")
            (run-command "dired-quit")
            (check-false! (equal? (current-buffer) d) "q again leaves dired")))))))

(deftest 'browse-m-ret-peeks-the-link-and-again-keeps-it
  "the page beside the page"
  (lambda ()
    (when (boundp 'web--tab-for!)
      (t--peek-with
        (lambda ()
          (let ((saved *web-fetch*))
            (set! *web-fetch*
              (lambda (url want k)
                (k (list want
                         (if (string-contains? url "second")
                             "# Second\n\nback [home](https://peek.test/)\n"
                             "# First\n\nsee [second](https://peek.test/second.html)\n")
                         #f))))
            (let* ((a (browse "https://peek.test/index.html"))
                   (l (web--link-after a 0)))
              (goto-char! (car l))
              (run-command "browse-follow-other-window")
              (let ((b (web--buffer-for "https://peek.test/second.html")))
                (check-true! (peek-buffer? b) "the linked page is a peek")
                (check-equal! (current-buffer) a "the reader stays")
                (run-command "browse-follow-other-window")
                (check-false! (peek-buffer? b) "the same link again keeps it")
                (check-equal! (current-buffer) b "and goes there")
                (buffer-kill! b))
              (buffer-kill! a))
            (set! *web-fetch* saved)))))))

(deftest 'a-shown-peek-follows-the-dired-highlight
  "no popup until RET; then the file under the rested highlight replaces the peek"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (b (t--peek-file "b.txt" "beta\n")))
          (dired-open t--peek-dir)
          (let ((d (current-buffer)))
            (let loop ((i 0))
              (when (and (< i 20) (not (equal? (dired-entry) "a.txt")))
                (list-move-in! d 1)
                (loop (+ i 1))))
            ;; the highlight rests on a.txt with no peek showing: nothing
            (dired--preview d (dired-entry))
            (check-false! (peek-buffer? a) "moving the highlight opens no popup")
            (run-command "dired-visit")
            (check-true! (peek-buffer? a) "RET peeks it")
            (list-move-in! d 1)
            (check-equal! (dired-entry) "b.txt" "the highlight moved on")
            ;; the debounced look runs on this lane after the rest; the test
            ;; holds the lane, so it runs the look the highlight schedules
            (dired--peek-now! (list b (buffer-group d) (active-window) d))
            (check-true! (peek-buffer? b) "the rested file replaced the peek")
            (check-false! (buffer-exists? a) "and the old peek is gone")
            (check-equal! (current-buffer) d "the reader stayed in dired")
            (run-command "dired-visit")
            (check-equal! (current-buffer) b "RET on it opens it")
            (check-false! (peek-buffer? b) "as your own")
            (buffer-kill! d)))))))

(deftest 'the-other-window-scroll-reads-the-peek-first
  "M-<down> from the listing scrolls the peek, not the next split"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (me (active-window)))
          (split-window! 'h 0.5)
          (select-window! me)
          (peek-file! a)
          (check-equal! (scroll-other-window-target) (window-showing a)
                        "the peek's window is the target")
          (popup-close!)
          (check-false! (equal? (scroll-other-window-target) me)
                        "with no peek, the next window is"))))))

(deftest 'the-peek-floats-on-the-side-away-from-the-listing
  "asked from the right window it floats left; from the left, right"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (left (active-window)))
          (split-window! 'h 0.5)
          (other-window!)
          (let ((right (active-window)))
            (peek-file! a)
            (check-equal! (buffer-local a 'window-class) "popup popup-left"
                          "from the right window the popup floats left")
            (popup-close!)
            (select-window! left)
            (peek-file! a)
            (check-equal! (buffer-local a 'window-class) "popup popup-right"
                          "from the left window it floats right")))))))

(deftest 'a-left-peek-leaves-the-listing-where-it-was
  "the popup floats; the window it covers keeps its id and its place"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (split-window! 'h 0.5)
          (other-window!)
          (let* ((me (active-window))
                 (before (assoc me (window-rects))))
            (peek-file! a)
            (check-equal! (buffer-local a 'window-class) "popup popup-left" "it floats left")
            (check-equal! (active-window) me "the reader's window is the same window")
            (check-equal! (window-buffer me) "*scratch*" "and still shows the listing")
            (check-equal! (nth 2 (assoc me (window-rects))) (nth 2 before)
                          "and starts where it started")
            ;; a second peek keeps the side, wherever it is asked from
            (let ((b (t--peek-file "b.txt" "beta\n")))
              (peek-file! b)
              (check-equal! (buffer-local b 'window-class) "popup popup-left"
                            "the side is chosen once"))))))))

(deftest 'a-rested-look-fires-only-where-it-was-scheduled
  "the reader moved on: the look does nothing"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (me (active-window)))
          (split-window! 'h 0.5)
          (other-window!)
          (dired--peek-now! (list a #f me "*scratch*"))
          (check-false! (peek-buffer? a) "no peek: the reader is in another window")
          (select-window! me)
          (dired--peek-now! (list a #f me "*scratch*"))
          (check-true! (peek-buffer? a) "back where it was scheduled, the look fires"))))))

(deftest 'an-opened-peek-over-a-waiting-popup-stops-floating
  "messages under the peek: open the peek, and it is a plain window while the popup shows messages"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (buffer-create "*zz-under*")
          (popup-show "*zz-under*")
          (select-window! (car (car (window-list))))
          (switch-to-buffer! "*scratch*")
          (peek-file! a)
          (check-equal! (popup-stack) (list "*zz-under*") "the popup buffer waits under the peek")
          (peek-open! a (lambda () a))
          (check-equal! (buffer-local a 'window-class) #f "opened, the buffer does not float")
          (check-equal! (popup-buffer) "*zz-under*" "the popup shows what waited")
          (check-equal! (length (filter (lambda (w) (popup--class? (cadr w))) (window-list))) 1
                        "one floating window, not more")
          (check-equal! (current-buffer) a "the reader is in the opened buffer")
          (popup-close!)
          (buffer-kill! "*zz-under*"))))))

(deftest 'a-peek-takes-no-focus
  "showing and replacing a peek moves the selection nowhere; other-window passes the peek by"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (b (t--peek-file "b.txt" "beta\n"))
              (me (active-window)))
          (peek-file! a)
          (check-equal! (active-window) me "the selection stayed for the first peek")
          (peek-file! b)
          (check-equal! (active-window) me "and for the replacement")
          (run-command "other-window")
          (check-equal! (active-window) me "other-window with only a peek beside stays")
          (split-window! 'h 0.5)
          (select-window! me)
          (run-command "other-window")
          (check-false! (equal? (active-window) me) "with a real window it moves")
          (check-true! (window-focusable? (active-window)) "to the real window, not the peek"))))))
