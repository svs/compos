;;; list-mode-test.scm --- the contract every list shares, proved once.
;;;
;;; A fixture list stands in for ibuffer, the chat list, notmuch, occur and
;;; the rest. A real list tests only its own rows and verbs; what it gets
;;; from list-mode is proved here: a move hands the row to the preview and
;;; the focus stays, the next look takes the last look's window, q takes
;;; the look before the list, a visit lands where you were looking, the
;;; row at point is read with the list's own point, a listing card floats
;;; over the list's own window, and a layout profile is chosen by width.
;;; Paging lives in list-page-test and the keys bar in list-keys-test.

(domain! 'testing)
(effects! '(write))

(define t--lm-buf "*zz-list-contract*")
(define t--lm-rows '("*zz-lc-a*" "*zz-lc-b*" "*zz-lc-c*"))
(define t--lm-previewed '())

(define t--lm-narrow
  (list 'name 'narrow
        'max-cols 50
        'columns (lambda (buf) (list (list "name" #f)))
        'cells (lambda (buf row) (list row))
        'footer (lambda (buf) '(("q" "quit")))))

(define t--lm-wide
  (list 'name 'wide 'default #t
        'columns (lambda (buf) (list (list "name" 20) (list "size" #f)))
        'cells (lambda (buf row)
                 (list row (number->string (if (buffer-known? row) (buffer-size row) 0))))))

(define-list-mode! "zz-list-contract-mode"
  (list
    'buffer t--lm-buf
    'rows (lambda (buf) t--lm-rows)
    'key (lambda (buf row) row)
    'columns (lambda (buf) (list (list "name" 20) (list "size" #f)))
    'cells (lambda (buf row)
             (list row (number->string (if (buffer-known? row) (buffer-size row) 0))))
    'title (lambda (buf) "Contract")
    'footer (lambda (buf) '(("RET" "visit") ("q" "quit")))
    'layouts (list t--lm-narrow t--lm-wide)
    'no-marks #t
    ;; the look goes beside the list through the shared preview slot
    'preview (lambda (buf row)
               (set! t--lm-previewed (cons row t--lm-previewed))
               (preview-show row 'other))))

;; every test starts from one window on *scratch* and ends there
(define (t--lm-with thunk)
  (set! t--lm-previewed '())
  (when (preview-slot) (preview-end #f))
  (when (float-open?) (float-close!))
  (switch-to-buffer! "*scratch*")
  (run-command "delete-other-windows")
  (for-each (lambda (b) (test-buffer! b (string-append b "\n"))) t--lm-rows)
  (let ((out (thunk)))
    (when (preview-slot) (preview-end #f))
    (when (float-open?) (float-close!))
    (for-each (lambda (b)
                (when (and (buffer-known? b)
                           (or (string-prefix? "*zz-lc-" b)
                               (equal? b t--lm-buf)
                               (string-contains? b "zz-lc-group")
                               (equal? (buffer-local b 'listing-preview-owner) t--lm-buf)))
                  (buffer-kill! b)))
              (buffer-list))
    (switch-to-buffer! "*scratch*")
    (run-command "delete-other-windows")
    out))

(define (t--lm-open!)
  (list-mode-show! "zz-list-contract-mode")
  (list-goto-first-entry t--lm-buf))
