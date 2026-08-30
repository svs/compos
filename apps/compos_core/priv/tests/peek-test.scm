;;; peek-test.scm --- editor.scm's peek: look at a buffer without keeping it.
;;;
;;; A peek shows beside the selected window. The next peek replaces it
;;; and kills what the first peek made. A buffer that existed before is
;;; only shown. RET twice keeps. q closes the peek and its window. A
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

(deftest 'a-peek-shows-beside-and-the-selected-window-stays
  "the file is on screen, marked, and the reader did not move"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let* ((a (t--peek-file "a.txt" "alpha\n"))
               (me (active-window)))
          (peek-file! a)
          (check-equal! (current-buffer) "*scratch*" "the reader stays put")
          (check-equal! (active-window) me "in the same window")
          (check-true! (peek-buffer? a) "the file is a peek")
          (check-true! (and (window-showing a) #t) "shown in a window")
          (check-false! (equal? (window-showing a) me) "which is another one")
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

(deftest 'ret-twice-keeps-and-goes-there
  "peek-or-keep!: the first call peeks, the second keeps and selects"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n"))
              (me (active-window)))
          (check-equal! (peek-or-keep! a (lambda () (visit a))) 'peek "first: a peek")
          (check-true! (peek-buffer? a) "marked")
          (check-equal! (current-buffer) "*scratch*" "reader stayed")
          (check-equal! (peek-or-keep! a (lambda () (visit a))) 'keep "second: kept")
          (check-false! (peek-buffer? a) "the mark is gone")
          (check-equal! (current-buffer) a "and the reader went there")
          (check-false! (string-contains? (buffer-modeline-name a) "peek")
                        "the modeline is plain again")
          ;; a kept buffer keeps its window: the next peek splits beside
          (select-window! me)
          (let ((b (t--peek-file "b.txt" "beta\n")))
            (peek-file! b)
            (check-true! (and (window-showing a) #t) "a still has its window")
            (check-true! (and (window-showing b) #t) "b has one too")
            (check-equal! (length (window-list)) 3 "three windows")))))))

(deftest 'an-edit-keeps-a-peeked-file
  "typing in it makes it yours"
  (lambda ()
    (t--peek-with
      (lambda ()
        (let ((a (t--peek-file "a.txt" "alpha\n")))
          (peek-file! a)
          (buffer-insert! a 0 "x")
          ;; the post-command hook calls this after every key
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
            (check-true! (peek-buffer? a) "the file is a peek beside")
            (run-command "dired-visit")
            (check-equal! (current-buffer) a "the second RET went there")
            (check-false! (peek-buffer? a) "and kept it")
            (buffer-kill! d)))))))

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
