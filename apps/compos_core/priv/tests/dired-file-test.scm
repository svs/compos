;;; dired-file-test.scm --- Dired answers a file name with its parent listing.
;;;
;;; A Dired buffer takes the directory path as its buffer name. A file path
;;; therefore takes the file's own buffer name. The file then cannot open at
;;; all: the poisoned buffer holds a listing error, carries no file
;;; association, and Dired repaints it after every mode change.

(domain! 'files)
(effects! '(write))

(define t--dfile-dir (string-append (compos-home) "/zz-dired-file"))
(define t--dfile-doc (string-append t--dfile-dir "/note.txt"))

(define (t--dfile-make!)
  (shell-command->string (string-append "rm -rf " (sh-quote t--dfile-dir)))
  (shell-command->string (string-append "mkdir -p " (sh-quote t--dfile-dir)))
  (write-file! t--dfile-doc "one\n"))

(define (t--dfile-remove!)
  (buffer-kill! t--dfile-doc)
  (buffer-kill! t--dfile-dir)
  (shell-command->string (string-append "rm -rf " (sh-quote t--dfile-dir))))

(deftest 'dired-on-a-file-opens-the-parent-directory
  "the listing shows the file's directory, and point sits on the file"
  (lambda ()
    (t--dfile-make!)
    (let ((buf (dired-open t--dfile-doc)))
      (check-equal! buf t--dfile-dir "the buffer is the parent directory")
      (check-equal! (list-current buf) "note.txt" "point sits on the file"))
    (check-true! (not (buffer-known? t--dfile-doc))
                 "the file's own buffer name stays free")
    (t--dfile-remove!)))

(deftest 'a-file-still-opens-after-dired-named-it
  "the file buffer holds the file, not a listing"
  (lambda ()
    (t--dfile-make!)
    (dired-open t--dfile-doc)
    (let ((buf (visit t--dfile-doc)))
      (check-equal! (buffer-path buf) t--dfile-doc "the buffer owns the file")
      (check-equal! (buffer-text buf) "one\n" "the buffer holds the file text"))
    (t--dfile-remove!)))

(deftest 'dired-stops-repainting-a-buffer-that-changed-mode
  "dired-dir alone does not make a buffer Dired"
  (lambda ()
    (t--dfile-make!)
    (let ((buf (dired-open t--dfile-dir)))
      (check-true! (dired-buffer? buf) "the listing is a Dired buffer")
      (buffer-set-local! buf 'mode-name "text-mode")
      (check-true! (not (dired-buffer? buf)) "another mode owns it now")
      ;; a rescan clears dired-scanned. The sentinel survives a refresh that
      ;; correctly does nothing.
      (buffer-set-local! buf 'dired-scanned 'sentinel)
      (dired-refresh-buffer! buf)
      (check-equal! (buffer-local buf 'dired-scanned) 'sentinel
                    "the refresh leaves the buffer alone"))
    (t--dfile-remove!)))

(deftest 'dired-keeps-a-listing-per-group
  "a directory opened from two groups gets a Dired in each, and each stays in its group"
  (lambda ()
    (t--dfile-make!)
    (with-fresh-group "zz-dired-a"
      (lambda (a)
        (with-fresh-group "zz-dired-b"
          (lambda (b)
            (buffer-create "zz-dired-from-a")
            (buffer-create "zz-dired-from-b")
            (buffer-move-to-group! "zz-dired-from-a" a)
            (buffer-move-to-group! "zz-dired-from-b" b)
            (let ((in-a (with-current-buffer "zz-dired-from-a" (lambda () (dired-open t--dfile-dir))))
                  (in-b (with-current-buffer "zz-dired-from-b" (lambda () (dired-open t--dfile-dir))))
                  (again (with-current-buffer "zz-dired-from-a" (lambda () (dired-open t--dfile-dir)))))
              (check-true! (not (equal? in-a in-b)) "each group gets its own listing")
              (check-equal! again in-a "opening it again reuses the group's listing")
              (check-equal! (buffer-group in-a) a "the first listing stays in its group")
              (check-equal! (buffer-group in-b) b "the second listing stays in its group")
              (check-equal! (dired-dir in-b) t--dfile-dir "both list the same directory")
              (buffer-kill! in-b))
            (buffer-kill! "zz-dired-from-a")
            (buffer-kill! "zz-dired-from-b")))))
    (t--dfile-remove!)))
