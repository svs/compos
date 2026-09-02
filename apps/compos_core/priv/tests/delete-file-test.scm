;;; delete-file-test.scm --- delete-file: this buffer's file by default, trash first.

(domain! 'testing)
(effects! '(destroy))

(define t--df-dir (string-append (compos-home) "/delete-file-test"))

(define (t--df-file name)
  (make-directory! t--df-dir)
  (let ((p (string-append t--df-dir "/" name)))
    (write-file! p "bytes\n")
    p))

(deftest 'delete-file-offers-this-buffers-file
  "the prompt's default is the current buffer's path; a buffer with none offers its directory"
  (lambda ()
    (let ((p (t--df-file "offered.txt")))
      ;; a real file buffer: a named test buffer has no path
      (visit-quietly p)
      (check-equal! (delete-file-default p) p "a file buffer offers its own file")
      (buffer-kill! p)
      (check-true! (string? (delete-file-default "*scratch*"))
                   "a buffer without a file offers a directory")
      (delete-file-path! p #t))))

(deftest 'delete-file-trashes-by-default-and-deletes-with-permanent
  "the file leaves its place either way; nothing there answers #f"
  (lambda ()
    (let ((a (t--df-file "to-trash.txt"))
          (b (t--df-file "to-delete.txt")))
      (check-equal! (delete-file-path! a #f) a "trash answers the path")
      (check-false! (file-exists? a) "the file left its place")
      (check-equal! (delete-file-path! b #t) b "delete answers the path")
      (check-false! (file-exists? b) "the file is gone")
      (check-false! (delete-file-path! a #f) "nothing there: #f, no error"))))
