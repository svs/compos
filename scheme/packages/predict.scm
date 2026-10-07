;;; predict.scm --- predict-mode: the browser paints typed text at once.
;;;
;;; In a buffer with predict-mode on, the browser holds a rope of the
;;; text (rope.wasm). A typed character, Enter, or Backspace changes the
;;; rope and the rows before the daemon answers. The daemon still runs
;;; the command and owns the text: when its result differs, the browser
;;; takes the daemon's rows. This package decides where prediction is on.

(domain! 'interaction)
(effects! '(write))

(define (predict-mode--apply! buf)
  (buffer-set-local! buf 'predict-mode #t))

(define (predict-mode--teardown! buf)
  (buffer-set-local! buf 'predict-mode #f))

(register-minor-mode!
  "predict-mode"
  predict-mode--apply!
  predict-mode--teardown!)

(define-command "predict-mode" "Toggle local echo of typed text in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "predict-mode")
        (message "Predict mode enabled")
        (message "Predict mode disabled"))))

(mode-doc! "predict-mode"
  "Paint typed text in the browser before the daemon answers. The daemon's text wins.")

;;; --- keys a mode takes over ----------------------------------------------------
;;; The browser predicts a plain insert for a typed char, a newline for
;;; RET, and a char deletion for DEL. A mode that binds one of those keys
;;; to its own command names the key here. The browser then sends that
;;; key with no prediction, so it never paints an edit the mode does not
;;; make. The registry rides the frame chrome as "predict-skip": a list
;;; of (MODE KEY ...), and the daemon sends the keys of the modes a
;;; buffer wears.

(define *predict-skip* '())

(define (predict--publish!)
  (frame-chrome-set! "predict-skip" *predict-skip*))

(define (predict-skip! mode keys)
  (set! *predict-skip*
    (cons (cons mode keys)
          (remove (lambda (e) (equal? (car e) mode)) *predict-skip*)))
  (predict--publish!))

(define (predict-skip-keys buf)
  (let ((modes (cons (or (buffer-local buf 'mode-name) "")
                     (or (buffer-local buf 'minor-modes) '()))))
    (apply append
      (map cdr (filter (lambda (e) (member (car e) modes)) *predict-skip*)))))

(predict--publish!)

(public! 'predict-skip!
  "(predict-skip! MODE KEYS) — the browser sends KEYS without a prediction in a buffer that wears MODE")
(public! 'predict-skip-keys
  "(predict-skip-keys BUF) — the keys the browser sends without a prediction in BUF")

;; A file buffer takes plain typed text. A chat, a list, or a process
;; buffer draws its own rows, so the browser cannot predict them.
(define (predict--eligible? buf)
  (and (not (string-prefix? " " buf))
       (buffer-path buf)
       (not (process-running? buf))
       #t))

(define-globalized-minor-mode! "global-predict-mode" "predict-mode" predict--eligible?
  "Toggle local echo of typed text in every file buffer")

(globalized-minor-mode-on! "global-predict-mode")
