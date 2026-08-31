;;; project-search-test.scm --- Search rows stay small.

(domain! 'testing)
(effects! '(write execute))

(deftest 'a-search-row-clips-a-generated-line
  "one generated multi-megabyte line must not ride a match list whole"
  (lambda ()
    (let* ((long (string-repeat "x" 5000))
           (m (rg--parse (string-append "./gen/app.js:7:" long))))
      (check-equal! (nth 1 m) "gen/app.js" "the path parses")
      (check-equal! (nth 2 m) 7 "the line number parses")
      (check-equal! (string-length (nth 3 m))
                    (+ project-ripgrep-max-text 2)
                    "the text stops at the cap plus an ellipsis")
      (check-contains! (nth 3 m) "xxxx" "the clipped text keeps its head"))
    (let ((short (rg--parse "./a.scm:3:(define x 1)")))
      (check-equal! (nth 3 short) "(define x 1)"
                    "a short row stays whole"))))

;; /tmp, not compos-home: the home can itself be a checkout, and this
;; test needs one directory that no repository contains
(define t--search-root "/tmp/zz-compos-project-search")

(deftest 'a-project-search-reads-only-what-git-names
  "matches come from git's file list; an ignored file does not match"
  (lambda ()
    (shell-command->string (string-append "rm -rf " t--search-root))
    (make-directory! t--search-root)
    (write-file! (string-append t--search-root "/kept.txt") "zz-needle here\n")
    (write-file! (string-append t--search-root "/dropped.log") "zz-needle here\n")
    (write-file! (string-append t--search-root "/.gitignore") "*.log\n")
    (shell-command->string "git init -q ." t--search-root)
    (let ((ms (project-search-matches t--search-root "zz-needle")))
      (check-equal! (map (lambda (m) (nth 1 m)) ms) '("kept.txt")
                    "only the file git names matches; the ignored file does not"))
    (shell-command->string (string-append "rm -rf " t--search-root))))
;; the no-project error cannot be caught in Scheme (no catch form), so
;; project_search_test.exs asserts it through the eval boundary
