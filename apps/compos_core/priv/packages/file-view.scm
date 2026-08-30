;;; file-view.scm --- readable defaults for structured and browser-native files.

(domain! 'files)
(effects! '(write display))

;;; JSON stays editable. The formatter works on JSON tokens, so it preserves
;;; null, booleans, number spelling, string escapes, and object key order.

(defgroup 'json "JSON editing.")

(defcustom 'json-auto-pretty-print #t
  "Indent valid JSON when json-mode starts. The buffer becomes modified when its layout changes."
  'group 'json 'type 'boolean)

(define (json-pretty-print! buf)
  (let* ((text (buffer-text buf))
         (pretty (json-format text)))
    (cond
      ((not pretty) #f)
      ((equal? pretty text) #t)
      (else
        (let ((p (if (equal? buf (current-buffer)) (point) 0)))
          (buffer-replace-range! buf 0 (buffer-size buf) pretty)
          (when (equal? buf (current-buffer))
            (goto-char! (min p (buffer-size buf))))
          #t)))))

(define-command "json-pretty-print-buffer" "Indent the current JSON buffer without changing its values or key order"
  (lambda ()
    (if (json-pretty-print! (current-buffer))
        (message "JSON formatted")
        (message "Invalid JSON; the buffer is unchanged"))))

(define (json-mode-setup)
  ((ts-mode "json"))
  (local-set-key "C-c C-f" "json-pretty-print-buffer")
  (when json-auto-pretty-print
    (json-pretty-print! (current-buffer))))

(define-mode "json-mode" json-mode-setup)
(mode-doc! "json-mode"
  "Editable JSON with syntax colors and structural motion. The mode indents valid compact JSON. Use `C-c C-f` to format again.")

(effects! '(pure))
(public! 'json-format
  "(json-format STR) — indent valid JSON without changing values or object key order; return #f on invalid input")
(catalog-meta! 'function "json-format" 'domain 'files 'effects '(pure))

(effects! '(write display))
(public! 'json-pretty-print!
  "(json-pretty-print! BUF) — indent valid JSON in BUF; return #f and leave invalid JSON unchanged")
(catalog-meta! 'function "json-pretty-print!" 'domain 'files 'effects '(write display))

;;; Browsers already have good viewers for common image, audio, and video
;;; files. The UI serves only the signed path of the current file. Scheme owns
;;; this extension policy and can replace any entry with a more capable mode.

(defgroup 'file-view "Browser-native file viewing.")

(defcustom '*browser-file-extensions*
  '(".png" ".apng" ".jpg" ".jpeg" ".jfif" ".gif" ".webp" ".avif" ".bmp" ".ico" ".svg"
    ".mp3" ".wav" ".ogg" ".oga" ".opus" ".weba" ".m4a" ".aac" ".flac"
    ".mp4" ".webm" ".ogv" ".mov" ".m4v")
  "File suffixes that browser-file-mode opens with the browser's native viewer."
  'group 'file-view 'type 'list)

(define (browser-file-path? path)
  (and (string? path)
       (let loop ((extensions *browser-file-extensions*))
         (cond ((null? extensions) #f)
               ((string-suffix? (car extensions) (string-downcase path)) #t)
               (else (loop (cdr extensions)))))))

(effects! '(write display))
(define (browser-file-mode-setup)
  (let ((buf (current-buffer)))
    (buffer-set-local! buf 'render-mode "file")
    (buffer-set-local! buf 'modeline-info "browser viewer")
    (buffer-set-read-only! buf #t)))

(define-mode "browser-file-mode" browser-file-mode-setup)
(mode-doc! "browser-file-mode"
  "A read-only browser viewer for common images, audio, and video. Use `C-x C-q` to expose the file bytes as text.")

(define (browser-file-register-auto-modes!)
  (for-each
    (lambda (extension)
      (set! *auto-mode-alist*
        (cons (list extension "browser-file-mode")
              (filter
                (lambda (entry)
                  (not (equal? (string-downcase (car entry)) extension)))
                *auto-mode-alist*))))
    *browser-file-extensions*)
  (for-each
    (lambda (buf)
      (let ((path (buffer-path buf)))
        (when (browser-file-path? path)
          (with-current-buffer buf
            (lambda () (set-mode! "browser-file-mode"))))))
    (buffer-list)))

(browser-file-register-auto-modes!)

(effects! '(pure))
(public! 'browser-file-path?
  "(browser-file-path? PATH) — return #t when PATH uses the browser file viewer")
(catalog-meta! 'function "browser-file-path?" 'domain 'files 'effects '(pure))
