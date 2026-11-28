;;; canvas-overview-test.scm --- spatial canvas overview snapshot, preview, and bridge tests.

(require 'canvas-overview)

(domain! 'testing)
(effects! '(read))

(deftest 'canvas-overview-snapshot-encodes-cleanly
  "canvas-overview-snapshot produces a valid JSON snapshot with theme and groups"
  (lambda ()
    (let* ((snap (canvas-overview-snapshot))
           (json (json-encode snap))
           (back (json-parse json)))
      (check-true! (number? (plist-get back 'rev)) "rev is numeric")
      (check-true! (list? (plist-get back 'groups)) "groups is a list")
      (check-true! (string? (plist-get (plist-get back 'theme) 'bg)) "theme includes bg"))))

(deftest 'canvas-overview-preview-reads-lines-and-metadata
  "canvas-overview--buffer-preview reads lines around point and reports metadata"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-preview*" "line one\nline two\nline three\n")))
      (let ((p (canvas-overview--buffer-preview buf 10)))
        (check-equal! (plist-get p 'name) buf "name matches")
        (check-true! (string-contains? (plist-get p 'text) "line two") "preview includes text")
        (check-equal! (plist-get p 'pointLine) 2 "pointLine matches byte offset"))
      (buffer-kill! buf))))

(deftest 'canvas-overview-app-request-serves-snapshot-and-watches
  "app-request answers GET snapshot and POST watch/preview and cleans up watches"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-watch*" "hello world\n")))
      (let* ((get-res (canvas-overview--app-request *canvas-overview-buffer* "GET" ""))
             (watch-body (json-encode (list 'op "watch" 'buffers (list buf))))
             (watch-res (canvas-overview--app-request *canvas-overview-buffer* "POST" watch-body))
             (parsed (json-parse (cadr watch-res))))
        (check-equal! (car get-res) 200 "GET returns 200")
        (check-equal! (car watch-res) 200 "POST watch returns 200")
        (check-true! (plist-get parsed 'ok) "watch reports ok")
        (check-true! (pair? (plist-get parsed 'buffers)) "watch returns buffer preview")
        (check-true! (and (assoc buf *canvas-overview-watches*) #t) "watch registered on buffer"))
      (canvas-overview--unwatch-all!)
      (check-equal! *canvas-overview-watches* '() "unwatch releases every watch")
      (buffer-kill! buf))))

(deftest 'canvas-overview-mode-configures-app-render-mode
  "canvas-overview-mode sets app render-mode and links external JS and CSS"
  (lambda ()
    (let ((buf (test-buffer! "*zz-canvas-mode*" "")))
      (with-current-buffer buf (lambda () (set-mode! "canvas-overview-mode")))
      (check-equal! (buffer-local-value 'render-mode buf) "app" "render-mode is app")
      (check-true! (string-contains? (buffer-text buf) "canvas-overview.js") "links external JS")
      (check-true! (string-contains? (buffer-text buf) "canvas-overview.css") "links external CSS")
      (check-true! (pair? (buffer-local-value 'app-directory buf)) "sets app-directory")
      (buffer-kill! buf))))
