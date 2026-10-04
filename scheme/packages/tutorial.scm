;;; tutorial.scm --- the learn-by-doing tutorial: C-h t.
;;;
;;; The tutorial is a buffer the reader edits while reading it. The master
;;; is bundled (priv/tutorials/COMPOS) and never changes; the reader edits a
;;; copy, and the copy keeps its place in ~/.compos/tutorial. training.scm,
;;; an opt-in app, adds a companion chat that teaches the same text.

(domain! 'learning)
(effects! '(read write))

(define *training-tutorial-buffer* "TUTORIAL")

(define (training-document-path)
  "Return the bundled, immutable tutorial master."
  (string-append (compos-priv-dir) "/tutorials/COMPOS"))

(define (training-state-dir)
  (string-append (compos-home) "/tutorial"))

(define (training-state-path)
  (string-append (training-state-dir) "/COMPOS.tut"))

(define (training-encode-state point text)
  (string-append (number->string point) "\n" text))

(define (training-decode-state raw)
  (and (string? raw)
       (let ((nl (string-index raw "\n")))
         (and nl
              (let* ((head (substring-bytes raw 0 nl))
                     (point (string->number head)))
                (and (re-match "^[0-9]+$" head)
                     (number? point)
                     (>= point 0)
                     (list point
                           (substring-bytes raw (+ nl 1) (string-byte-length raw)))))))))

(define (training-read-state)
  (let ((raw (read-file (training-state-path))))
    (and raw (training-decode-state raw))))

(define (training-save-state! buf)
  (make-directory! (training-state-dir))
  (write-file! (training-state-path)
               (training-encode-state (buffer-point buf) (buffer-text buf)))
  #t)

(define (training--load-tutorial! text point)
  (let ((buf *training-tutorial-buffer*))
    (buffer-create buf)
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-insert! buf 0 text)
    (with-current-buffer buf (lambda () (set-mode! "morg-mode")))
    ;; Rendered, and still editable: morg draws it in place.
    (unless (minor-mode-on? buf "preview-mode")
      (enable-minor-mode! buf "preview-mode"))
    (preview-heal! buf)
    (let ((point (max 0 (min point (buffer-size buf)))))
      (buffer-goto! buf point)
      (buffer-set-local! buf 'training-starting-point point))
    (buffer-set-local! buf 'training-tutorial #t)
    (buffer-mark-saved! buf)
    buf))

(define (training-fresh-tutorial!)
  (let ((text (read-file (training-document-path))))
    (if text
        (training--load-tutorial! text 0)
        (error "The bundled Compos tutorial is missing"))))

(define (training-resume-tutorial! state)
  (training--load-tutorial! (cadr state) (car state)))

(define (training--show! buf)
  (switch-to-buffer! buf)
  buf)

(define (training--prepare-document!)
  (if (buffer-known? *training-tutorial-buffer*)
      (buffer-create *training-tutorial-buffer*)
      (let ((state (training-read-state)))
        (if state
            (training-resume-tutorial! state)
            (training-fresh-tutorial!)))))

(define (training--open-tutorial!)
  (training--show! (training--prepare-document!)))

(define-command "help-with-tutorial"
  "Select the Compos learn-by-doing tutorial, resuming saved progress"
  (lambda () (training--open-tutorial!)))

(define-key "help-map" "t" "help-with-tutorial")

;; The welcome page links compos:training/tutorial. The companion app
;; answers the other training links when the user init loads it.
(define (tutorial--follow-link arg)
  (and (equal? arg "tutorial")
       (begin (run-command "help-with-tutorial") #t)))

(add-hook! (list 'preview-link "training") tutorial--follow-link)

(category! 'learning)
(public! 'training-document-path
  "(training-document-path) — the bundled immutable tutorial master")
(public! 'training-state-path
  "(training-state-path) — the reader's saved tutorial content and point")
