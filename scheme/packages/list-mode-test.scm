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

(deftest 'a-move-previews-the-row-beside-the-list-and-takes-no-focus
  "list-move-in! hands the row it lands on to the mode's preview; the row shows in another window, the list keeps its window and the selection, the recency ring does not move, no popup opens, and the next look takes the last look's window"
  (lambda ()
    (t--lm-with
      (lambda ()
        (t--lm-open!)
        (let ((me (active-window))
              (before (buffer-list-mru)))
          (check-equal! (window-buffer me) t--lm-buf "the list has the selected window")
          (list-move-in! t--lm-buf 1)
          (check-equal! (car t--lm-previewed) "*zz-lc-b*" "the move previews the row it lands on")
          (let ((slot (window-showing "*zz-lc-b*")))
            (check-true! (and slot #t) "the row's buffer is on screen")
            (check-false! (equal? slot me) "in another window, never the list's")
            (check-equal! (active-window) me "the selection stayed on the list")
            (check-equal! (window-buffer me) t--lm-buf "and the list kept its window")
            (check-false! (float-open?) "no popup was opened")
            (check-equal! (buffer-list-mru) before "a look is not a use: the ring did not move")
            (let ((windows (length (window-list))))
              (list-move-in! t--lm-buf 1)
              (check-equal! (car t--lm-previewed) "*zz-lc-c*" "the next move previews the next row")
              (check-equal! (window-showing "*zz-lc-c*") slot "in the window the last look had")
              (check-false! (window-showing "*zz-lc-b*") "the last look is gone")
              (check-equal! (length (window-list)) windows "and no window was added")
              (check-equal! (active-window) me "the selection still rests on the list"))))))))

(deftest 'q-takes-the-look-before-it-takes-the-list
  "quit-window in the list dismisses the previewed row and leaves the list in hand; quit-window again leaves the list"
  (lambda ()
    (t--lm-with
      (lambda ()
        (t--lm-open!)
        (list-move-in! t--lm-buf 1)
        (check-true! (and (window-showing "*zz-lc-b*") #t) "a look is on screen")
        (run-command "quit-window")
        (check-false! (window-showing "*zz-lc-b*") "q took the look")
        (check-true! (buffer-known? "*zz-lc-b*") "and the buffer, which was yours, stays")
        (check-equal! (current-buffer) t--lm-buf "and left the list in hand")
        (run-command "quit-window")
        (check-false! (equal? (current-buffer) t--lm-buf) "q again leaves the list")))))

(deftest 'a-visit-after-a-look-lands-in-the-looks-window
  "the display chain reuses the window that shows the row: a visit lands there, the selection follows it, and the list keeps its own window"
  (lambda ()
    (t--lm-with
      (lambda ()
        (t--lm-open!)
        (let ((me (active-window)))
          (list-move-in! t--lm-buf 1)
          (let ((slot (window-showing "*zz-lc-b*")))
            (pop-to-buffer "*zz-lc-b*")
            (check-equal! (current-buffer) "*zz-lc-b*" "the row is the buffer in hand")
            (check-equal! (active-window) slot "in the window that showed the look")
            (check-equal! (window-buffer me) t--lm-buf "and the list's window keeps the list")))))))
