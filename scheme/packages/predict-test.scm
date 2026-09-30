;;; predict-test.scm --- where the browser may predict typed text.

(domain! 'testing)
(effects! '(write))

(define t--pr-dir (string-append (compos-home) "/zz-predict"))
(define t--pr-file (string-append t--pr-dir "/notes.txt"))

(define (t--pr-teardown!)
  (when (buffer-exists? t--pr-file) (buffer-kill! t--pr-file))
  (when (file-exists? t--pr-file) (delete-file! t--pr-file))
  (when (file-directory? t--pr-dir) (delete-file! t--pr-dir)))

(deftest 'predict-mode-is-on-in-a-visited-file
  "global-predict-mode turns predict-mode on in a file buffer"
  (lambda ()
    (make-directory! t--pr-dir)
    (write-file! t--pr-file "alpha\n")
    (visit t--pr-file)
    (check-true! (minor-mode-on? t--pr-file "predict-mode") "the file buffer predicts")
    (t--pr-teardown!)))

(deftest 'predict-mode-is-off-in-a-buffer-without-a-file
  "a buffer that visits no file draws its own rows"
  (lambda ()
    (let ((buf (test-buffer! "zz-predict-scratch" "text")))
      (check-false! (minor-mode-on? buf "predict-mode") "no prediction without a file")
      (buffer-kill! buf))))

(deftest 'predict-mode-toggles-in-one-buffer
  "the predict-mode command turns the mode off and on in the current buffer"
  (lambda ()
    (let ((buf (test-buffer! "zz-predict-toggle" "text")))
      (switch-to-buffer! buf)
      (run-command "predict-mode")
      (check-true! (minor-mode-on? buf "predict-mode") "the command turns it on")
      (check-equal! (buffer-local buf 'predict-mode) #t "the local says so")
      (run-command "predict-mode")
      (check-false! (minor-mode-on? buf "predict-mode") "the command turns it off")
      (buffer-kill! buf))))
