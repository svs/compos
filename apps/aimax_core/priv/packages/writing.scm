;;; writing.scm — writing-mode: distraction-free prose, olivetti-style.
;;;
;;; A minor mode (composes with org-mode etc.): centered measure, serif
;;; prose face, line numbers off, hl-line off, quiet modeline showing a
;;; live word count + reading time. Everything it changes is saved on
;;; enable and restored on disable; all of it survives a daemon reload
;;; via 'minor-modes + restore-minor-modes!.
;;;
;;; M-x writing-mode toggles. Knobs live in the 'writing customize group.

(defgroup 'writing "Distraction-free writing.")

;; re-apply to every live writing buffer so customize changes repaint
(define (writing--refresh! _v)
  (for-each
    (lambda (buf)
      (if (minor-mode-on? buf "writing-mode")
          (writing--apply! buf)))
    (buffer-list)))

(defcustom 'writing-measure "62ch"
  "Column width of the centered text measure (any CSS length)."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-font-family "Spectral, Georgia, serif"
  "Font family for writing-mode buffer text."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-font-size "17px"
  "Font size for writing-mode buffer text (any CSS size)."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-line-height "1.9"
  "Line height for writing-mode buffer text."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-wpm 220
  "Reading speed (words per minute) behind the modeline's read-time."
  'group 'writing 'type 'number 'set writing--refresh!)

;;; --- word count ---------------------------------------------------------------

;; change-hook registry keyed by buffer NAME in global state (org pattern):
;; rules outlive buffer kill + recreate, so re-enabling must not stack
(define *writing-hooks* '())

(define (writing--ensure-hook! buf)
  (unless (assoc buf *writing-hooks*)
    (set! *writing-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (writing--update-count! buf))))
            *writing-hooks*))))

(define (writing--remove-hook! buf)
  (let ((hit (assoc buf *writing-hooks*)))
    (if hit
        (begin
          (remove-on-change! (cadr hit))
          (set! *writing-hooks*
            (remove (lambda (h) (equal? (car h) buf)) *writing-hooks*))))))

(define (writing--update-count! buf)
  (if (minor-mode-on? buf "writing-mode")
      (let ((words (count-words buf)))
        (buffer-set-local! buf 'modeline-info
          (if (= words 0)
              "0 words"
              (string-append
                (number->string words) " words · "
                (number->string
                  (max 1 (quotient (+ words (- writing-wpm 1)) writing-wpm)))
                " min"))))))

;;; --- enable / disable -----------------------------------------------------------

(define (writing--saved buf key)
  (let ((hit (assoc key (or (buffer-local buf 'writing-saved) '()))))
    (if hit (cadr hit) #f)))

(define (writing--apply! buf)
  ;; remember what we clobber, once — the saved alist persists, and the
  ;; restore path re-runs this fn, which must not re-save writing's own look
  (unless (buffer-local buf 'writing-saved)
    (buffer-set-local! buf 'writing-saved
      (list (list 'face-remap (or (buffer-local buf 'face-remap) '()))
            (list 'style (or (buffer-local buf 'style) #f))
            (list 'line-numbers (or (buffer-local buf 'line-numbers) #f)))))
  (face-remap-in! buf 'default
    (list 'family writing-font-family
          'size writing-font-size
          'line-height writing-line-height))
  ;; pseudo-face: emits --writing-measure on .buf; the stylesheet's
  ;; .window.writing rules read it
  (face-remap-in! buf 'writing (list 'measure writing-measure))
  (buffer-set-local! buf 'line-numbers "off")
  (buffer-set-local! buf 'window-class "writing")
  (writing--ensure-hook! buf)
  (writing--update-count! buf))

(define (writing--teardown! buf)
  (writing--remove-hook! buf)
  (buffer-set-local! buf 'face-remap (or (writing--saved buf 'face-remap) '()))
  (buffer-set-local! buf 'style (writing--saved buf 'style))
  (buffer-set-local! buf 'line-numbers (writing--saved buf 'line-numbers))
  (buffer-set-local! buf 'window-class #f)
  (buffer-set-local! buf 'modeline-info #f)
  (buffer-set-local! buf 'writing-saved #f))

(register-minor-mode! "writing-mode" writing--apply! writing--teardown!)

(define-command "writing-mode" "Toggle writing mode in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "writing-mode")
        (message "Writing mode enabled")
        (message "Writing mode disabled"))))

(define-command "count-words" "Display the number of words in the buffer"
  (lambda ()
    (message (string-append "Buffer has "
                            (number->string (count-words (current-buffer)))
                            " words"))))
