;;; package-update-test.scm --- the release heartbeat, hold and rollback marks, and fail forward.

(domain! 'testing)
(effects! '(write))

(define (t--pu-dir) (string-append (compos-temp-dir) "/package-update-test"))

(define (t--pu-rm! path)
  (when (file-directory? path)
    (for-each (lambda (f)
                (t--pu-rm! (string-append path "/" (if (string-suffix? "/" f)
                                                        (substring f 0 (- (string-length f) 1))
                                                        f))))
              (list-dir path)))
  (when (or (file-exists? path) (file-directory? path)) (delete-file! path)))

(deftest 'package-api-names-reads-the-public-surface
  "public!, define-command and defcustom names count; a plain define does not"
  (lambda ()
    (check-equal! (package-api-names "(public! 'zz-a \"x\") (define-command \"zz-b\" \"d\" f) (begin (defcustom 'zz-c 1 \"d\")) (define (zz-d) 1)")
                  '("zz-a" "zz-b" "zz-c") "the three declared names, sorted")
    (check-equal! (package-api-removed '("a" "b" "c") '("a" "c" "d")) '("b") "b went; d is new, not removed")))

(deftest 'package-update-replacement-reads-the-change-notes
  "an arrow or a renamed ... to names the new name; a bare mention gives the line"
  (lambda ()
    (check-equal! (car (package-update-replacement "zz-old" '("other" "- renamed `zz-old` to `zz-new`"))) "zz-new" "renamed to")
    (check-equal! (car (package-update-replacement "zz-old" '("zz-old -> zz-new"))) "zz-new" "an arrow")
    (check-equal! (car (package-update-replacement "zz-old" '("zz-old → zz-new (shorter)"))) "zz-new" "a unicode arrow")
    (check-equal! (package-update-replacement "zz-old" '("dropped zz-old, use the page")) '(#f "dropped zz-old, use the page") "no new name")
    (check-equal! (package-update-replacement "zz-old" '("zz-older -> x")) #f "a longer symbol is not the name")))

(deftest 'package-update-uses-in-matches-whole-symbols
  "a use is the whole symbol, in code or in a string"
  (lambda ()
    (check-equal! (map car (package-update-uses-in "(zz-f 1)\n(zz-fx 2)\n(run-command \"zz-f\")" "zz-f")) '(1 3) "lines 1 and 3")))

(deftest 'package-lock-keeps-marks-and-the-release
  "hold, previous and the release survive a write of packages.lock"
  (lambda ()
    (let ((lock (string-append (t--pu-dir) "/packages.lock")))
      (t--pu-rm! (t--pu-dir))
      (with-stub 'package-lock-file lock
        (lambda ()
          (package-lock-write! '(("zzl" "https://github.com/compos-dev/compos-zzl.git" "1111111111111111111111111111111111111111")) '(release "9.9.9"))
          (package-lock-set! "zzl" "2222222222222222222222222222222222222222" 'previous "1111111111111111111111111111111111111111")
          (check-equal! (caddr (assoc "zzl" (package-lock))) "2222222222222222222222222222222222222222" "the new pin")
          (check-equal! (package-previous "zzl") "1111111111111111111111111111111111111111" "the commit it left")
          (check-equal! (package-held? "zzl") #f "not held")
          (with-stub 'message (lambda (t . _) #t)
            (lambda () (check-equal! (package-hold! "zzl") #t "h holds it")))
          (check-equal! (package-held? "zzl") #t "the lock says held")
          (check-equal! (package-lock-release) '(release "9.9.9") "the release stays")
          (check-equal! (package-update! "zzl") '("zzl" skipped "no clone") "no clone, nothing to move")))
      (t--pu-rm! (t--pu-dir)))))

(deftest 'package-fail-forward-files-the-plan-for-the-users-code
  "a dropped name the user's code uses becomes a todo with each use, its file and the new name"
  (lambda ()
    (let* ((root (t--pu-dir)) (mine (string-append root "/mine")) (filed '()))
      (t--pu-rm! root)
      (write-file! (string-append mine "/zzmine.scm") "(define (x) (zzp-old 1))\n(zzp-kept 2)\n")
      (write-file! (string-append mine "/zzdep/recipe.scm") "(zzdep :requires ((zzp 1)))\n")
      (write-file! (string-append mine "/zzdep/zzdep.scm") "(zzp-kept 3)\n")
      (with-stub 'personal-package-dirs (lambda () (list mine))
        (lambda ()
          (with-stub 'package-develop-directories '()
            (lambda ()
              (with-stub 'package-installed (lambda () '())
                (lambda ()
                  (with-stub 'package-fix-start-chat #f
                    (lambda ()
                      (with-stub 'compos-home (lambda () root)
                        (lambda ()
                          (with-stub 'todo-create (lambda (title props) (set! filed (list title props)) "t-zz")
                            (lambda ()
                              (with-stub 'message (lambda (t . _) #t)
                                (lambda ()
                                  (check-equal! (package-fail-forward! "zzp" "aaaaaaa1" "bbbbbbb2" '("zzp-old") 1 2
                                                                       '("renamed zzp-old to zzp-new"))
                                                "t-zz" "the todo id")
                                  (let ((notes (plist-get (cadr filed) 'notes)))
                                    (check-true! (string-contains? notes "zzmine.scm:1  zzp-old → zzp-new") "the use, its file and line, and the new name")
                                    (check-true! (string-contains? notes "recipe.scm:1  (zzp 1) → (zzp 2)") "the require of the old :major")
                                    (check-true! (string-contains? notes "todo-review") "the fix waits for review"))
                                  (check-equal! (package-fail-forward! "zzp" "a" "b" '("zzp-gone") 1 1 '()) #f
                                                "nothing to fix when nothing uses it")))))))))))))))
      (t--pu-rm! root))))
