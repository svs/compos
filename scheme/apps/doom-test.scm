;;; doom-test.scm --- the DOOM app page and its script file.

(deftest 'doom-writes-its-page-and-script-beside-the-engine
  "the page names doom.js and holds no inline script; the sync copies the package's script"
  (lambda ()
    (let ((dir (string-append (compos-config-dir) "/zz-doom-test")))
      (with-stub 'doom-home dir
        (lambda ()
          (make-directory! dir)
          (doom--sync-page!)
          (let ((page (read-file (string-append dir "/doom.html")))
                (script (read-file (string-append dir "/doom.js"))))
            (check-contains! page "<script src=\"doom.js\"></script>" "the page names its script")
            (check-false! (string-contains? page "<script>") "the page holds no inline script")
            (check-false! (string-contains? page "oncontextmenu") "and no inline handler")
            (check-equal! script (read-file (locate-library "doom/doom.js")) "the script is the package's")
            (check-contains! script "window.Module" "the script starts the engine")))))))
