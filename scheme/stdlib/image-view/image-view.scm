;;; image-view.scm --- fit-to-buffer image viewer mode.
;;;
;;; Replaces browser-file-mode for image extensions while keeping those
;;; extensions in *browser-file-extensions* so find-file never reads raw
;;; image bytes into memory.

(domain! 'files)
(effects! '(pure))

(defgroup 'image-view "Image viewing.")

(defcustom '*image-view-extensions*
  '(".png" ".apng" ".jpg" ".jpeg" ".jfif" ".gif" ".webp" ".avif" ".bmp" ".ico" ".svg")
  "File suffixes that image-view-mode opens fitted to the buffer."
  'group 'image-view 'type 'list)

(define (image-view-path? path)
  (and (string? path)
       (let ((down (string-downcase path)))
         (let loop ((exts *image-view-extensions*))
           (cond ((null? exts) #f)
                 ((string-suffix? (car exts) down) #t)
                 (else (loop (cdr exts))))))))

(defwrite-rule! 'image-view-mode
  "image-view-mode holds viewer markup, not the image file"
  #f
  (lambda (path source)
    (and source (equal? (buffer-local-value 'mode-name source) "image-view-mode"))))

(define (image-view--html path fit?)
  (string-append
    "<!doctype html><html><head><meta charset=\"utf-8\"><style>"
    "html,body{margin:0!important;padding:0!important;max-width:none!important;width:100%!important;height:100%!important;background:transparent!important;"
    (if fit?
        "overflow:hidden!important;display:flex!important;align-items:center!important;justify-content:center!important;}"
        "overflow:auto!important;display:block!important;}")
    (if fit?
        "img{display:block;max-width:100%;max-height:100%;width:auto;height:auto;object-fit:contain;margin:auto;}"
        "img{display:block;max-width:none;max-height:none;width:auto;height:auto;margin:0;}")
    "</style></head><body><img src=\"" (html-escape path) "\" alt=\"\"></body></html>"))

(effects! '(write display))

(define (image-view--fit? buf)
  (not (equal? (buffer-local-value 'image-view-size buf) 'actual)))

(define (image-view--render! buf)
  (let* ((path (buffer-path buf))
         (fit? (image-view--fit? buf)))
    (when path
      (buffer-set-local! buf 'preview-renderer "html")
      (buffer-set-local! buf 'preview-authored #t)
      (buffer-set-local! buf 'render-mode "html")
      (buffer-set-local! buf 'modeline-info (if fit? "fit" "1:1"))
      (buffer-set-read-only! buf #f)
      (buffer-delete-range! buf 0 (buffer-size buf))
      (buffer-append! buf (image-view--html path fit?))
      (buffer-mark-saved! buf)
      (buffer-set-read-only! buf #t))))

(define (image-view-mode-setup)
  (let ((buf (current-buffer)))
    (unless (equal? (buffer-local-value 'image-view-size buf) 'actual)
      (buffer-set-local! buf 'image-view-size 'fit))
    (image-view--render! buf)))

(define-mode "image-view-mode" image-view-mode-setup)

(define-command "image-view-fit" "Fit the image to the buffer"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'image-view-size 'fit)
      (image-view--render! buf)
      (message "Image: fit to buffer")))
  'modes '(image-view-mode))

(define-command "image-view-toggle-actual-size" "Toggle between fit-to-buffer and actual 1:1 size"
  (lambda ()
    (let* ((buf (current-buffer))
           (next (if (image-view--fit? buf) 'actual 'fit)))
      (buffer-set-local! buf 'image-view-size next)
      (image-view--render! buf)
      (message (if (equal? next 'fit) "Image: fit to buffer" "Image: actual size (1:1)"))))
  'modes '(image-view-mode))

(define-command "image-view-reload" "Reload the image view"
  (lambda ()
    (image-view--render! (current-buffer))
    (message "Image reloaded"))
  'modes '(image-view-mode))

(mode-keys! "image-view-mode"
  '(("f" "image-view-fit")
    ("0" "image-view-fit")
    ("1" "image-view-toggle-actual-size")
    ("g" "image-view-reload")))

(mode-doc! "image-view-mode"
  "Read-only image viewer fitted to the buffer. Press `1` for actual size (1:1), `f` or `0` to fit, `g` to reload.")

(define (image-view-register-auto-modes!)
  (for-each
    (lambda (ext)
      (set! *auto-mode-alist*
        (cons (list ext "image-view-mode")
              (filter
                (lambda (entry)
                  (not (equal? (string-downcase (car entry)) ext)))
                *auto-mode-alist*))))
    *image-view-extensions*)
  (for-each
    (lambda (buf)
      (let ((path (buffer-path buf)))
        (when (image-view-path? path)
          (with-current-buffer buf
            (lambda () (set-mode! "image-view-mode"))))))
    (buffer-list)))

(image-view-register-auto-modes!)

(effects! '(pure))
(public! 'image-view-path?
  "(image-view-path? PATH) — return #t when PATH opens in image-view-mode")
(catalog-meta! 'function "image-view-path?" 'domain 'files 'effects '(pure))

(provide 'image-view)
