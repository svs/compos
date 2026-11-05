;;; image-gen.scm --- Make an image from a text prompt.
;;;
;;; The image job is a role in llm-model-presets, as summarize is: set it with
;;; (llm-models! '(... (image . "openai:gpt-image-2"))). A model id is
;;; PROVIDER:MODEL; openai and gemini are known. With no image role set, the
;;; job takes image-gen-default-model. Each image lands as a PNG in
;;; image-gen-directory.

(domain! 'writing)
(effects! '(write))

(defgroup 'image-gen "Images made from a text prompt.")

(defcustom 'image-gen-role 'image
  "The llm-models! job that makes images."
  'group 'image-gen 'type 'symbol)

(defcustom 'image-gen-default-model "openai:gpt-image-2"
  "The image model when the image job has none: PROVIDER:MODEL, openai or gemini."
  'group 'image-gen 'type 'string)

(defcustom 'image-gen-directory "~/.compos/images"
  "Where a made image lands when no path is given."
  'group 'image-gen 'type 'string)

(defcustom 'image-gen-size "1024x1024"
  "The size of an OpenAI image: 1024x1024, 1536x1024, 1024x1536 or auto."
  'group 'image-gen 'type 'string)

(defcustom 'image-gen-quality "auto"
  "The quality of an OpenAI image: low, medium, high or auto. Higher costs more."
  'group 'image-gen 'type 'string)

(defcustom 'image-gen-timeout-ms 180000
  "How long one image may take, in milliseconds."
  'group 'image-gen 'type 'number)

(define (image-gen-model)
  (let* ((row (assq image-gen-role llm-model-presets))
         (id (and row (cdr row))))
    (if (and (string? id) (> (string-length id) 0)) id image-gen-default-model)))

(define (image-gen--split model)
  (let ((i (string-index model ":")))
    (if i
        (list (substring-bytes model 0 i) (substring-bytes model (+ i 1) (string-length model)))
        (list "openai" model))))

(define (image-gen--path prompt)
  (let* ((words (filter (lambda (w) (> (string-length w) 0))
                        (string-split (re-replace-all "[^a-z0-9 ]" (string-downcase prompt) "") " ")))
         (slug (string-join (if (> (length words) 5) (take words 5) words) "-")))
    (string-append (expand-path image-gen-directory) "/"
                   (format-time (current-time) "%Y%m%d-%H%M%S") "-" slug ".png")))

(define (image-gen--opts headers)
  (list 'headers headers 'timeout image-gen-timeout-ms 'max-bytes 64000000))

;; Each provider answers the base64 of the PNG, or (error TEXT).
(define (image-gen--openai model prompt k)
  (http-post "https://api.openai.com/v1/images/generations"
    (list 'model model 'prompt prompt 'n 1 'size image-gen-size 'quality image-gen-quality)
    (image-gen--opts (list (list "Authorization" (string-append "Bearer " (or (llm-key "openai") "")))))
    (lambda (r)
      (let* ((j (http-json r))
             (data (and j (plist-get j 'data)))
             (b64 (and (pair? data) (plist-get (car data) 'b64_json))))
        (k (or b64 (list 'error (image-gen--why r j))))))))

(define (image-gen--gemini model prompt k)
  (http-post (string-append "https://generativelanguage.googleapis.com/v1beta/models/" model
                            ":generateContent?key=" (or (llm-key "gemini") ""))
    (list 'contents (list (list 'parts (list (list 'text prompt))))
          'generationConfig (list 'responseModalities (list "IMAGE")))
    (image-gen--opts '())
    (lambda (r)
      (let* ((j (http-json r))
             (cands (and j (plist-get j 'candidates)))
             (parts (and (pair? cands) (plist-get (plist-get (car cands) 'content) 'parts)))
             (hit (and parts (filter (lambda (p) (plist-get p 'inlineData)) parts)))
             (b64 (and (pair? hit) (plist-get (plist-get (car hit) 'inlineData) 'data))))
        (k (or b64 (list 'error (image-gen--why r j))))))))

(define (image-gen--why r j)
  (let ((err (and j (plist-get j 'error))))
    (cond ((and (pair? err) (plist-get err 'message)) (plist-get err 'message))
          ((plist-get r 'error) (plist-get r 'error))
          (else (format "HTTP ~a, no image in the answer" (plist-get r 'status))))))

;;;###autoload
(define (image-generate prompt &optional path k)
  (let* ((path (or path (image-gen--path prompt)))
         (pm (image-gen--split (image-gen-model)))
         (provider (car pm))
         (done (lambda (v)
                 (cond ((string? v)
                        (write-file! path (base64-decode v))
                        (when k (k path)))
                       (else
                        (message (format "image-generate: ~a" (cadr v)))
                        (when k (k #f)))))))
    (cond ((equal? provider "openai") (image-gen--openai (cadr pm) prompt done))
          ((equal? provider "gemini") (image-gen--gemini (cadr pm) prompt done))
          (else (error (format "image-generate: no image provider ~a" provider))))
    path))

;;;###autoload
(define-command "image-generate" "Make an image from a prompt and show it"
  (lambda ()
    (let ((group (buffer-group (current-buffer))))
      (read-string "Image of: "
        (lambda (prompt)
          (unless (equal? (string-trim prompt) "")
            (message (format "Making the image with ~a…" (image-gen-model)))
            (image-generate prompt #f
              (lambda (path)
                (when path
                  (with-frame-windows
                    (lambda () (window-set-buffer! (get-other-window) (visit path group))))
                  (message (abbreviate-file-name path)))))))))))

(effects! '(read))
(public! 'image-gen-model "(image-gen-model) — the PROVIDER:MODEL the image job uses")
(effects! '(write external spend))
(public! 'image-generate
  "(image-generate PROMPT [PATH] [K]) — make a PNG of PROMPT with the image job's model; answers PATH at once, K gets PATH or #f once written")

(provide 'image-gen)
