;;; file-view-test.scm --- readable structured and media files.

(domain! 'testing)
(effects! '(write))

(define t--file-view-json "zz-file-view.json")
(define t--file-view-image "zz-file-view.png")

(deftest 'json-mode-formats-compact-json-without-changing-json-literals
  "mode setup indents compact JSON and preserves null, false, escapes, and key order"
  (lambda ()
    (test-buffer! t--file-view-json "{\"z\":null,\"a\":false,\"s\":\"a\\\\nb\"}")
    (with-current-buffer t--file-view-json (lambda () (set-mode! "json-mode")))
    (check-equal!
      (buffer-text t--file-view-json)
      "{\n  \"z\": null,\n  \"a\": false,\n  \"s\": \"a\\\\nb\"\n}\n"
      "the lexical formatter preserves JSON data")
    (check-equal! (buffer-local t--file-view-json 'ts-lang) "json" "the parser is active")
    (buffer-kill! t--file-view-json)))

(deftest 'json-mode-leaves-invalid-json-unchanged
  "invalid input stays editable and visible"
  (lambda ()
    (test-buffer! t--file-view-json "{bad json}")
    (with-current-buffer t--file-view-json (lambda () (set-mode! "json-mode")))
    (check-equal! (buffer-text t--file-view-json) "{bad json}" "the source is unchanged")
    (buffer-kill! t--file-view-json)))

(deftest 'browser-file-mode-draws-common-images-with-the-browser-viewer
  "image suffixes select the inert browser file render mode"
  (lambda ()
    (test-buffer! t--file-view-image "binary")
    (with-current-buffer t--file-view-image (lambda () (set-mode! "browser-file-mode")))
    (check-equal! (buffer-local t--file-view-image 'render-mode) "file" "the browser view is active")
    (check-true! (buffer-read-only? t--file-view-image) "the file bytes are read-only")
    (check-true! (browser-file-path? "photo.AVIF") "extension matching ignores case")
    (buffer-kill! t--file-view-image)))

(deftest 'file-view-modes-and-commands-are-discoverable-with-declared-effects
  "apropos finds the public surface and its metadata is complete"
  (lambda ()
    (check-contains! (value->string (apropos "browser file viewer" 'lexical #t))
                     "browser-file-mode" "apropos finds the viewer")
    (check-contains! (value->string (apropos "json-pretty-print-buffer" 'lexical #t))
                     "json-pretty-print-buffer" "apropos finds the formatter")
    (check-equal! (plist-get (catalog-entry 'mode "browser-file-mode") 'metadata-source)
                  "declared" "the viewer mode declares its effects")
    (check-equal! (plist-get (catalog-entry 'command "json-pretty-print-buffer") 'metadata-source)
                  "declared" "the format command declares its effects")))
