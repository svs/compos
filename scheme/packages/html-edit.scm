;;; html-edit.scm --- edit an HTML file on its own rendered page
;;
;; M-x html-edit runs the file as an app (preview.scm) in the other window:
;; the page draws with its own CSS, and html-edit/html-edit.js makes it a
;; copy editor. Hover marks only content: text, pictures, embeds. A click
;; puts the caret in the text or selects the picture, Delete removes it,
;; and a paste puts an image, an X post or a YouTube video after it.
;;
;; The page does the editing on its own DOM. This side tells it where
;; every element sits in the source, data-hs="START,END" in bytes, and
;; takes each finished change back as one byte range: an element's text
;; when it loses focus, a delete, an insert. Each change is saved at once.

(domain! 'writing)
(effects! '(write))

(define (html-edit--directory)
  (let ((js (locate-library "html-edit/html-edit.js")))
    (and js (substring js 0 (- (string-length js) (string-length "/html-edit.js"))))))

(define (html-edit-app-name source)
  (string-append "*html-edit:" (cadr (path-split source)) "*"))

;; where each element of the body takes its data-hs attribute: (AT TEXT),
;; in source order. CAPS are the "e" (element) and "s" (its start tag)
;; captures; an element comes just before its own start tag.
(define (html-edit--marks text caps)
  (let loop ((cs caps) (body #f) (acc '()))
    (cond
      ((null? cs) (reverse acc))
      ((and (equal? (car (car cs)) "e") (pair? (cdr cs)) (equal? (car (cadr cs)) "s"))
       (let* ((s (cadr (car cs))) (e (caddr (car cs))) (tag-end (caddr (cadr cs)))
              (at (if (equal? (substring-bytes text (- tag-end 2) tag-end) "/>")
                      (- tag-end 2) (- tag-end 1))))
         (cond
           ((and (not body)
                 (re-match "^<body[ \t\r\n>]" (string-downcase (substring-bytes text s (+ s 6)))))
            (loop (cddr cs) e acc))
           ((and body (< s body))
            (loop (cddr cs) body
                  (cons (list at (string-append " data-hs=\"" (number->string s) ","
                                                (number->string e) "\""))
                        acc)))
           (else (loop (cddr cs) body acc)))))
      (else (loop (cdr cs) body acc)))))

(define (html-edit--splice text marks)
  (let loop ((ms marks) (pos 0) (acc '()))
    (if (null? ms)
        (apply string-append (reverse (cons (substring-bytes text pos (string-byte-length text)) acc)))
        (loop (cdr ms) (car (car ms))
              (cons (cadr (car ms)) (cons (substring-bytes text pos (car (car ms))) acc))))))

;; the script carries the hash of the source it was drawn from, so a page
;; served stale (a reload the editor did not start) knows to ask again
(define (html-edit--assets hash)
  (string-append "<link rel=\"stylesheet\" href=\"html-edit.css\"><script src=\"html-edit.js\" data-hash=\""
                 hash "\"></script>"))

;; the page: the source with every body element marked, and the editor's
;; script and style before </body>
(define (html-edit--page source)
  (let* ((text (buffer-text source))
         (caps (with-current-buffer source
                 (lambda () (ts-query "(element [(start_tag) (self_closing_tag)] @s) @e"))))
         (page (html-edit--splice text (html-edit--marks text caps)))
         (assets (html-edit--assets (content-hash text)))
         (ends (re-find* "</[Bb][Oo][Dd][Yy]>" page)))
    (if (null? ends)
        (string-append page assets)
        (let ((at (car (car (reverse ends)))))
          (string-append (substring-bytes page 0 at) assets
                         (substring-bytes page at (string-byte-length page)))))))

(define (html-edit--render! app source)
  (buffer-set-read-only! app #f)
  (buffer-replace-range! app 0 (buffer-size app) (html-edit--page source))
  (buffer-set-read-only! app #t))

;; An edit from the page is already on the page: it redraws nothing, not
;; even the page buffer, whose every change repaints the window and flashes
;; the frame. Any other edit to the source (the source window, an undo, an
;; agent) never reloads the page, which would lose the text being typed: it
;; posts word of the change, and the page fetches the new markup when no
;; text is open. The page's own edit leaves the hash of the text it expects.
(define *html-edit-watches* '())

(define (html-edit--changed! source)
  (let ((app (html-edit-app-name source)))
    (if (not (buffer-exists? app))
        (html-edit--unwatch! source)
        (let ((hash (content-hash (buffer-text source))))
          (unless (equal? (buffer-local app 'html-edit-expect) hash)
            (app-post! app (list 'changed hash)))))))

(define (html-edit--unwatch! source)
  (let ((old (assoc source *html-edit-watches*)))
    (when old
      (remove-on-change! (cadr old))
      (set! *html-edit-watches*
            (let loop ((ws *html-edit-watches*) (acc '()))
              (cond ((null? ws) (reverse acc))
                    ((equal? (car (car ws)) source) (loop (cdr ws) acc))
                    (else (loop (cdr ws) (cons (car ws) acc)))))))))

(define (html-edit--watch! source)
  (html-edit--unwatch! source)
  (set! *html-edit-watches*
        (alist-put *html-edit-watches* source
                   (on-change! source
                               (lambda (pos inserted deleted tag)
                                 (unless (equal? tag "locals") (html-edit--changed! source)))
                               'eager))))

(define (html-edit--save! source)
  (with-current-buffer source (lambda () (buffer-save!))))

(define (html-edit--reply status data) (list status (json-encode data)))

;; where CTX, which the page last saw at byte AT, stands now: at AT when it
;; still does, else at its nearest copy, else #f. Another edit may have
;; moved it since the page drew.
(define (html-edit--locate now ctx at)
  (cond
    ((and (<= (+ at (string-byte-length ctx)) (string-byte-length now))
          (equal? (substring-bytes now at (+ at (string-byte-length ctx))) ctx))
     at)
    ((equal? ctx "") #f)
    (else
     (let loop ((hits (re-find* (regexp-quote ctx) now)) (best #f))
       (cond ((null? hits) best)
             ((or (not best) (< (abs (- (car (car hits)) at)) (abs (- best at))))
              (loop (cdr hits) (car (car hits))))
             (else (loop (cdr hits) best)))))))

;; replace bytes S..E of the source with TEXT. CTX is the source the page
;; saw around the change, from byte CTX_S; it finds the change again when
;; the file moved under the page.
(define (html-edit--replace! app source msg)
  (let* ((s0 (plist-get msg 's)) (e0 (plist-get msg 'e))
         (text (plist-get msg 'text))
         (ctx (or (plist-get msg 'ctx) (plist-get msg 'old) ""))
         (cs (or (plist-get msg 'ctx_s) s0))
         (now (buffer-text source))
         (base (and (integer? cs) (string? ctx) (html-edit--locate now ctx cs)))
         (s (and base (integer? s0) (+ base (- s0 cs))))
         (e (and base (integer? e0) (+ base (- e0 cs)))))
    (if (and s e (string? text) (<= 0 s) (<= s e) (<= e (string-byte-length now)))
        (begin
          (buffer-set-local! app 'html-edit-expect
            (content-hash (string-append (substring-bytes now 0 s) text
                                         (substring-bytes now e (string-byte-length now)))))
          (buffer-replace-range! source s (- e s) text)
          (html-edit--save! source)
          (html-edit--reply 200 (list 'ok #t 'moved (not (= base cs)))))
        (html-edit--reply 409 (list 'error "That text is no longer in the file")))))

;; a pasted image goes to images/ beside the file; the page gets its link
(define (html-edit--image! source msg)
  (let* ((path (buffer-path source))
         (dir (string-append (car (path-split path)) "images/"))
         (ext (clipboard-image-extension (or (plist-get msg 'mime) "image/png")))
         (full (let loop ((n 1))
                 (let ((p (string-append dir "pasted-" (number->string n) ext)))
                   (if (file-exists? p) (loop (+ n 1)) p)))))
    (write-file! full (base64-decode (plist-get msg 'data)))
    (html-edit--reply 200 (list 'src (clipboard-image-link path full)))))

(define (html-edit--app-request app method body)
  (let ((source (and (buffer-exists? app) (buffer-local app 'html-edit-source))))
    (and source
         (cond
           ((not (buffer-exists? source))
            (html-edit--reply 410 (list 'error "The HTML buffer is gone")))
           ((equal? method "GET")
            (let ((text (buffer-text source)))
              (html-edit--reply 200 (list 'source text 'hash (content-hash text)
                                          'page (html-edit--page source)))))
           ((equal? method "POST")
            (let* ((msg (json-parse body)) (op (and (pair? msg) (plist-get msg 'op))))
              (cond
                ((equal? op "replace") (html-edit--replace! app source msg))
                ((equal? op "image") (html-edit--image! source msg))
                ((equal? op "undo")
                 (with-current-buffer source (lambda () (undo!)))
                 (html-edit--save! source)
                 (html-edit--reply 200 '(ok #t)))
                (else (html-edit--reply 400 (list 'error "No such edit"))))))
           (else (html-edit--reply 405 (list 'error "The page answers GET and POST")))))))

(add-hook! '(app-request html-edit) 'html-edit--app-request)

(define (html-edit! source)
  (let ((app (html-edit-app-name source)))
    (unless (buffer-exists? app)
      (buffer-create app)
      (when (boundp 'buffer-join-here!) (buffer-join-here! app)))
    (buffer-set-local! app 'html-edit-source source)
    (buffer-set-local! app 'app-keep-on-save #t)
    (buffer-set-local! app 'app-directory
                       (list (car (path-split (buffer-path source))) (html-edit--directory)))
    (unless (equal? (buffer-local app 'mode-name) "html-edit-mode")
      (with-current-buffer app (lambda () (set-mode! "html-edit-mode"))))
    (html-edit--render! app source)
    (buffer-set-local! app 'preview-renderer "html")
    (buffer-set-local! app 'render-mode "app")
    (html-edit--watch! source)
    (app-reload! app)
    app))

;; a restored page lost its watch on the source
(define-mode "html-edit-mode"
  (lambda ()
    (let ((source (buffer-local (current-buffer) 'html-edit-source)))
      (when (and source (buffer-exists? source)) (html-edit--watch! source)))))

(mode-doc! "html-edit-mode"
  "An HTML file drawn as itself for copy editing. Hover marks the text, pictures and embeds, never the layout. A click puts the caret in the text, and the text goes back to the file when it loses focus; Escape leaves it. A click on a picture or an embed selects it and Delete removes it. A paste puts an image, an X post or a YouTube video after the text or the picture. C-g gives the keyboard back.")

;;;###autoload
(define-command "html-edit" "Edit this HTML file on its rendered page in the other window"
  (lambda ()
    (let ((source (current-buffer)))
      (if (not (and (buffer-path source) (re-match "\\.html?$" (buffer-path source))))
          (message "html-edit works on an HTML file")
          (let ((app (html-edit! source)))
            (unless (window-showing app) (display-buffer-other-window! app))
            (message "Click to edit, Delete removes, paste images and URLs. C-g gives the keyboard back."))))))

(public! 'html-edit! "(html-edit! SOURCE) — run HTML buffer SOURCE as its own editable page, without showing it; answers the page buffer")
(public! 'html-edit-app-name "(html-edit-app-name SOURCE) — the name of SOURCE's editable page buffer")
(catalog-meta! 'function "html-edit!" 'domain 'writing 'effects '(write))
(catalog-meta! 'function "html-edit-app-name" 'domain 'writing 'effects '(pure))

(provide 'html-edit)
