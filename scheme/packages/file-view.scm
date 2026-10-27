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
  (when json-auto-pretty-print
    (json-pretty-print! (current-buffer))))

(define-mode "json-mode" json-mode-setup)
(mode-keys! "json-mode" '(("C-c C-f" "json-pretty-print-buffer")))
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
;;;
;;; The buffer holds none of the file. The browser reads it from disk through
;;; the signed route, so a visit never reads the bytes: a 900 MB screen
;;; recording opens as fast as a thumbnail, writes an empty checkpoint, and
;;; costs no later boot anything. That is why no size cap applies to these
;;; files, and why nothing in such a buffer may be written over one.

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
  "A read-only browser viewer for common images, audio, and video. The buffer holds none of the file: the browser reads it from disk, so the size of the file costs the editor nothing. Nothing here can be written over the file.")

;; The buffer never read the file, so nothing in it stands for the file.
;; The rule is not confirmable: no answer makes an empty buffer the right
;; contents for a video.
(effects! '(pure))
(defwrite-rule! 'unread-file
  "this buffer never read the file, so saving it would replace the file with nothing"
  #f
  (lambda (path source)
    (and source (buffer-unread-file? source))))
(effects! '(write display))

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

;;; A visited file can open read-only. It is the reader's choice: #f opens
;;; every file writable, #t opens every file read-only, and a list of mode
;;; names opens a file read-only when its major mode is one of them or
;;; descends from one. C-x C-q makes the buffer writable. The rule reads
;;; the mode that auto-mode set, so find-file-hook runs it. It blocks only
;;; the user's own edits: an agent edits a read-only buffer as before.

(domain! 'files)
(effects! '(write))

(defgroup 'files "Opening files.")

(defcustom 'find-file-read-only #f
  "#t opens every visited file read-only; a list of mode names opens a file read-only when its mode is in the list."
  'group 'files)

(define (find-file-read-only? buf)
  (let ((rule (and (boundp 'find-file-read-only) (symbol-value 'find-file-read-only)))
        (mode (buffer-local buf 'mode-name)))
    ;; A chat is a conversation you type into, not a page you read. A
    ;; restored .chat file opens writable whatever the rule says.
    (cond ((and (string? mode) (derived-mode? mode "chat-mode")) #f)
          ((equal? rule #t) #t)
          ((pair? rule)
           (and (string? mode)
                (let loop ((ms rule))
                  (and (pair? ms)
                       (or (derived-mode? mode (let ((m (car ms))) (if (symbol? m) (symbol->string m) m)))
                           (loop (cdr ms)))))))
          (else #f))))

(define (find-file-read-only--hook!)
  (let ((buf (current-buffer)))
    (when (and (buffer-path buf) (find-file-read-only? buf))
      (buffer-set-read-only! buf #t))))

(add-hook! 'find-file-hook 'find-file-read-only--hook!)
