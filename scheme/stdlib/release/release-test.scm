;;; release-test.scm --- the overlay of Scheme a hot patch or a Scheme bundle ships.

(domain! 'testing)
(effects! '(write))

(define (t--rel-dir) (string-append (compos-temp-dir) "/release-test"))

(define (t--rel-rm! path)
  (when (file-directory? path)
    (for-each (lambda (f)
                (t--rel-rm! (string-append path "/" (if (string-suffix? "/" f)
                                                         (substring f 0 (- (string-length f) 1))
                                                         f))))
              (list-dir path)))
  (when (or (file-exists? path) (file-directory? path)) (delete-file! path)))

(deftest 'release-overlay-target-mirrors-load-path
  "a stdlib file goes in by its own name, a package by its path under packages; tests and editor.scm stay out"
  (lambda ()
    (check-equal! (release-overlay-target "scheme/stdlib/release/release.scm") "release.scm" "a stdlib file")
    (check-equal! (release-overlay-target "scheme/packages/package.scm") "package.scm" "a package")
    (check-equal! (release-overlay-target "apps/compos_core/priv/editor/blocks/run-block.scm") "editor/blocks/run-block.scm" "a priv file by its require path")
    (check-equal! (release-overlay-target "apps/compos_core/priv/standard.lock") "standard.lock" "the release lock")
    (check-equal! (release-overlay-target "apps/compos_core/priv/editor.scm") #f "Elixir loads editor.scm by path")
    (check-equal! (release-overlay-target "scheme/packages/package-test.scm") #f "tests stay out")
    (check-equal! (release-overlay-target "docs/README.md") #f "not Scheme")))

(deftest 'release-overlay-apply-copies-loads-and-boot-clears-a-stale-one
  "apply copies the files into the overlay and loads them; boot clears an overlay made for another commit"
  (lambda ()
    (let* ((root (t--rel-dir)) (src (string-append root "/src")) (state (string-append root "/state")))
      (t--rel-rm! root)
      (write-file! (string-append src "/scheme/packages/zzrel.scm") "(define zzrel-mark 41)\n")
      (make-directory! state)
      (with-stub 'release-stable-self? (lambda () #t)
        (lambda ()
          (with-stub 'compos-state-dir (lambda () state)
            (lambda ()
              (let ((rs (release-overlay-apply! src '("scheme/packages/zzrel.scm" "docs/x.md") "abcdef1234" "9.9.9")))
                (check-equal! rs '(("scheme/packages/zzrel.scm" ok)) "the Scheme file loaded; the doc stayed out")
                (check-equal! zzrel-mark 41 "its code runs in this compos")
                (check-true! (file-exists? (string-append state "/overlay/zzrel.scm")) "it is in the overlay")
                (check-equal! (plist-get (release-overlay-manifest (string-append state "/overlay")) 'files) '("zzrel.scm") "the manifest names it"))
              (with-stub 'build-info (lambda () '(version "9.9.8" commit "abcdef1"))
                (lambda ()
                  (check-equal! (release-running-version) "9.9.9" "the overlay's version counts while it patches the commit that runs")))
              (with-stub 'build-info (lambda () '(version "9.9.9" commit "1234567"))
                (lambda ()
                  (with-stub 'release--overlay-booted #f
                    (lambda ()
                      (check-equal! (release-overlay-boot!) '() "another commit loads nothing")
                      (check-false! (file-exists? (string-append state "/overlay/zzrel.scm")) "and clears the overlay")))))))))
      (t--rel-rm! root))))
