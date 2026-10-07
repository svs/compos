;; The Emacs Dired verbs past the basics: regexp marks, toggling,
;; renames that swap names, wdired, and the ! command line.

(domain! 'files)
(effects! '(write))

(define t--dx-dir (string-append (compos-home) "/zz-dired-emacs"))

(define (t--dx-make! names)
  (shell-command->string (string-append "rm -rf " (sh-quote t--dx-dir)))
  (shell-command->string (string-append "mkdir -p " (sh-quote t--dx-dir)))
  (for-each (lambda (n) (write-file! (string-append t--dx-dir "/" n) n)) names)
  (dired-open t--dx-dir))

(define (t--dx-remove!)
  (buffer-kill! t--dx-dir)
  (shell-command->string (string-append "rm -rf " (sh-quote t--dx-dir))))

(define (t--dx-file n) (file-exists? (string-append t--dx-dir "/" n)))

(deftest 'dired-regexp-marks-only-the-matching-files
  "% m marks the names a regexp matches, and t turns the marks over"
  (lambda ()
    (let ((buf (t--dx-make! '("a.txt" "b.txt" "c.md"))))
      (dired-mark-matching! buf "[.]txt$" *list-mark-char* "Marked")
      (check-equal! (list-marked buf *list-mark-char*) '("b.txt" "a.txt")
                    "the two txt files are marked")
      (with-current-buffer buf (lambda () (run-command "dired-toggle-marks")))
      (check-equal! (list-marked buf *list-mark-char*) '("c.md")
                    "toggle leaves only the other file marked")
      (t--dx-remove!))))

(deftest 'dired-backups-get-the-trash-flag
  "~ flags backup and auto-save files with the trash flag"
  (lambda ()
    (let ((buf (t--dx-make! '("a.txt" "a.txt~" "#a.txt#"))))
      (with-current-buffer buf (lambda () (run-command "dired-flag-backup-files")))
      (check-equal! (length (list-marked buf "D")) 2 "both backups are flagged")
      (check-false! (member "a.txt" (list-marked buf "D")) "the file itself is not")
      (t--dx-remove!))))

(deftest 'dired-rename-all-swaps-two-names
  "a swap renames through temporary names, so no file is lost"
  (lambda ()
    (let ((buf (t--dx-make! '("one" "two"))))
      (check-equal! (dired-rename-all! buf '(("one" "two") ("two" "one"))) 2
                    "two files renamed")
      (check-equal! (read-file (string-append t--dx-dir "/two")) "one" "one is now two")
      (check-equal! (read-file (string-append t--dx-dir "/one")) "two" "two is now one")
      (check-false! (dired-rename-all! buf '(("one" "x") ("two" "x")))
                    "two files never take one name")
      (check-true! (and (t--dx-file "one") (t--dx-file "two")) "a refused rename moves nothing")
      (t--dx-remove!))))

(deftest 'wdired-renames-the-changed-lines
  "C-x C-q edits the names as text, and C-c C-c renames the changed ones"
  (lambda ()
    (let* ((buf (t--dx-make! '("a.txt" "b.txt")))
           (ed (string-append "*wdired:" t--dx-dir "*")))
      (with-current-buffer buf (lambda () (run-command "dired-toggle-read-only")))
      (check-true! (buffer-known? ed) "the edit buffer opens")
      (buffer-set-text! ed (string-replace (buffer-text ed) "a.txt" "z.txt") #f)
      (with-current-buffer ed (lambda () (run-command "wdired-finish-edit")))
      (check-true! (t--dx-file "z.txt") "the changed line renamed its file")
      (check-false! (t--dx-file "a.txt") "the old name is gone")
      (check-true! (t--dx-file "b.txt") "the same line left its file alone")
      (check-false! (buffer-known? ed) "the edit buffer closes")
      (t--dx-remove!))))

(deftest 'dired-shell-line-places-the-files
  "* is every file, ? is each file, and with neither the files go last"
  (lambda ()
    (check-equal! (dired-shell-line "wc -l" '("a" "b c")) "wc -l 'a' 'b c'" "files go last")
    (check-equal! (dired-shell-line "tar cf x.tar *" '("a" "b")) "tar cf x.tar 'a' 'b'" "* is all")
    (check-equal! (dired-shell-line "gzip ?" '("a" "b")) "gzip 'a'; gzip 'b'" "? is each")))

(deftest 'dired-star-prefix-marks-by-kind
  "* / marks directories, * . an extension, * s every file"
  (lambda ()
    (let ((buf (t--dx-make! '("a.txt" "b.md"))))
      (make-directory! (string-append t--dx-dir "/sub"))
      (dired-refresh-buffer! buf)
      (with-current-buffer buf (lambda () (run-command "dired-mark-directories")))
      (check-equal! (length (list-marked buf *list-mark-char*)) 1 "only the directory")
      (list-clear-marks! buf)
      (dired-mark-matching! buf "[.]md$" *list-mark-char* "Marked")
      (check-equal! (list-marked buf *list-mark-char*) '("b.md") "only the md file")
      (with-current-buffer buf (lambda () (run-command "dired-mark-subdir-files")))
      (check-equal! (length (list-marked buf *list-mark-char*)) 3 "every file, not ..")
      (t--dx-remove!))))

(deftest 'dired-next-marked-file-goes-around
  "* C-n goes to the next mark and wraps past the end"
  (lambda ()
    (let ((buf (t--dx-make! '("a" "b" "c"))))
      (list-mark! buf "a" *list-mark-char*)
      (list-goto-index! buf 3)
      (with-current-buffer buf (lambda () (run-command "dired-next-marked-file")))
      (check-equal! (list-current buf) "a" "wrapped to the marked file")
      (t--dx-remove!))))
