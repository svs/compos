;;; desktop-clear-test.scm --- each modified file gets one question.
;;;
;;; The prompt and the clear are stubbed: these test the answers' logic,
;;; y n A N and a quit, on real file buffers, without killing the desktop.

(domain! 'testing)
(effects! '(write))

(define (zz-dc-file! label text)
  (let ((path (compos-temp-file (string-append "zz-dc-" label "-"
                                               (number->string (monotonic-ms)) ".txt"))))
    (write-file! path text)
    (let ((buf (visit path)))
      (buffer-append! buf "edit ")
      (list buf path))))

;; run THUNK with the prompt answering ANSWERS in order and the clear
;; recorded instead of done; answers (FINISHED? KEPT MEMBERS)
(define (zz-dc-run answers thunk)
  (let ((old-read read-char-choice)
        (old-finish desktop-clear--finish)
        (left answers)
        (finished #f))
    (set! read-char-choice
      (lambda (prompt choices k)
        (when (pair? left)
          (let ((ch (car left))) (set! left (cdr left)) (k ch)))))
    (set! desktop-clear--finish
      (lambda (kept members) (set! finished (list #t kept members))))
    (thunk)
    (set! read-char-choice old-read)
    (set! desktop-clear--finish old-finish)
    (or finished (list #f '() '()))))

(define (zz-dc-cleanup! . files)
  (for-each (lambda (f) (buffer-kill! (car f)) (delete-file (cadr f))) files))

(deftest 'desktop-clear-y-saves-and-n-keeps
  "y saves the file it asks about, n keeps the buffer and its edit"
  (lambda ()
    (let* ((a (zz-dc-file! "a" "a\n")) (b (zz-dc-file! "b" "b\n"))
           (r (zz-dc-run '("y" "n")
                (lambda () (desktop-clear--ask-save (list (car a) (car b)) '() (list (car a) (car b)))))))
      (check-true! (car r) "the clear ran")
      (check-true! (string-prefix? "a" (read-file (cadr a))) "a file holds its text")
      (check-true! (string-contains? (read-file (cadr a)) "edit ") "y saved a")
      (check-equal! (read-file (cadr b)) "b\n" "n did not save b")
      (check-equal! (cadr r) (list (car b)) "n keeps b")
      (zz-dc-cleanup! a b))))

(deftest 'desktop-clear-A-saves-every-remaining-file
  "A saves this file and every one after it, and keeps none"
  (lambda ()
    (let* ((a (zz-dc-file! "a" "a\n")) (b (zz-dc-file! "b" "b\n"))
           (r (zz-dc-run '("A")
                (lambda () (let ((d (list (car a) (car b)))) (desktop-clear--ask-save d '() d))))))
      (check-true! (car r) "the clear ran")
      (check-true! (string-contains? (read-file (cadr a)) "edit ") "a saved")
      (check-true! (string-contains? (read-file (cadr b)) "edit ") "b saved")
      (check-equal! (cadr r) '() "nothing kept")
      (zz-dc-cleanup! a b))))

(deftest 'desktop-clear-N-saves-none
  "N discards every remaining edit and keeps none"
  (lambda ()
    (let* ((a (zz-dc-file! "a" "a\n"))
           (r (zz-dc-run '("N")
                (lambda () (let ((d (list (car a)))) (desktop-clear--ask-save d '() d))))))
      (check-true! (car r) "the clear ran")
      (check-equal! (read-file (cadr a)) "a\n" "a not saved")
      (check-equal! (cadr r) '() "nothing kept")
      (zz-dc-cleanup! a))))

(deftest 'desktop-clear-quit-clears-nothing
  "a prompt that is quit never answers, so nothing is saved or cleared"
  (lambda ()
    (let* ((a (zz-dc-file! "a" "a\n"))
           (r (zz-dc-run '()
                (lambda () (let ((d (list (car a)))) (desktop-clear--ask-save d '() d))))))
      (check-false! (car r) "no clear")
      (check-true! (buffer-known? (car a)) "the buffer stays")
      (check-equal! (read-file (cadr a)) "a\n" "the file is untouched")
      (zz-dc-cleanup! a))))
