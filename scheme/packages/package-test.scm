;;; package-test.scm --- recipes, activation and develop of the package manager.

(domain! 'testing)
(effects! '(write))

(define (t--pkg-dir) (string-append (compos-temp-dir) "/package-test-repos"))

(define (t--pkg-rm! path)
  (when (file-directory? path)
    (for-each (lambda (f)
                (t--pkg-rm! (string-append path "/" (if (string-suffix? "/" f)
                                                          (substring f 0 (- (string-length f) 1))
                                                          f))))
              (list-dir path)))
  (when (or (file-exists? path) (file-directory? path)) (delete-file! path)))

(deftest 'package-recipe-url-takes-url-before-github-repo
  "a :url is the url; a :repo is a github repo"
  (lambda ()
    (check-equal! (package-recipe-url '(:repo "u/r")) "https://github.com/u/r.git" ":repo is github")
    (check-equal! (package-recipe-url '(:url "/x/r" :repo "u/r")) "/x/r" ":url wins")
    (check-equal! (package-recipe-url '()) #f "no source, no url")))

(deftest 'package-activate-loads-the-clone-and-refuses-a-newer-api
  "the registered recipe beats recipe.scm; activation puts the clone on load-path and loads it"
  (lambda ()
    (let* ((root (t--pkg-dir)) (dir (string-append root "/zzpt")))
      (write-file! (string-append dir "/recipe.scm") "(zzpt :api 1 :requires (zzother))\n")
      (write-file! (string-append dir "/zzpt.scm") "(define zzpt-mark 7)\n")
      (with-stub 'package-repos-directory root
        (lambda ()
          (with-stub 'load-path load-path
            (lambda ()
              (with-stub 'package--recipes '(("zzpt" :url "/x/zzpt"))
                (lambda ()
                  (check-equal! (package-recipe 'zzpt) '(:url "/x/zzpt" :api 1 :requires (zzother))
                                "init.scm's recipe first, the repo's recipe.scm after")
                  (check-equal! (package--activate! "zzpt") "zzpt" "activation answers the name")
                  (check-true! (member dir load-path) "the clone is on load-path")
                  (check-equal! zzpt-mark 7 "NAME.scm loaded")))
              (with-stub 'package--recipes '(("zzpt" :api 999))
                (lambda ()
                  (check-equal! (report-errors "package-test" (lambda () (package--activate! "zzpt"))) #f
                                "a package that needs a newer core is refused")))))))
      (t--pkg-rm! root))))

(deftest 'package-develop-moves-load-path-to-the-checkout
  "develop swaps the clone for the checkout on load-path; #f goes back"
  (lambda ()
    (let* ((root (t--pkg-dir)) (clone (string-append root "/zzpd"))
           (mine (string-append root "/mine/zzpd")))
      (write-file! (string-append clone "/zzpd.scm") "(define zzpd-mark 1)\n")
      (write-file! (string-append mine "/zzpd.scm") "(define zzpd-mark 2)\n")
      (with-stub 'package-repos-directory root
        (lambda ()
          (with-stub 'package-develop-directories '()
            (lambda ()
              (with-stub 'customize-save! (lambda (name value) (set-symbol-value! name value))
                (lambda ()
                  (with-stub 'load-path load-path
                    (lambda ()
                      (package--activate! "zzpd")
                      (check-equal! zzpd-mark 1 "the clone loads first")
                      (check-equal! (package-develop! 'zzpd mine) mine "develop answers the checkout")
                      (check-true! (and (member mine load-path) (not (member clone load-path)))
                                   "the checkout replaced the clone on load-path")
                      (check-equal! zzpd-mark 2 "a loaded package reloads from the checkout")
                      (check-equal! (package-develop! 'zzpd #f) clone "#f goes back to the clone")
                      (check-equal! package-develop-directories '() "and forgets the checkout")))))))))
      (t--pkg-rm! root))))
