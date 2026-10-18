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

(deftest 'the-row-at-point-is-read-with-the-lists-own-point
  "list-current slices the list with the list's point, not the current buffer's; an undrawn list answers #f instead of raising"
  (lambda ()
    (t--lm-with
      (lambda ()
        (t--lm-open!)
        (list-goto-index! t--lm-buf 1)
        (check-equal! (list-current t--lm-buf) "*zz-lc-b*" "point rests on the second row")
        (test-buffer! "*zz-lc-big*" "")
        (buffer-append! "*zz-lc-big*" (string-repeat "x" 100000))
        (switch-to-buffer! "*zz-lc-big*")
        (end-of-buffer!)
        (check-equal! (list-current t--lm-buf) "*zz-lc-b*"
                      "asked from a buffer whose point is far past the list's end, the list answers its own row")
        (check-equal! (list-key-at-pos t--lm-buf (buffer-point t--lm-buf)) "*zz-lc-b*"
                      "and a position in the list names the row that holds it")
        (buffer-create "*zz-lc-unpointed*")
        (check-equal! (ignore-errors (lambda () (list 'ok (line-index-at "*zz-lc-unpointed*" 0))))
                      (list 'ok 0) "an empty buffer sits on the first entry line")
        (check-equal! (ignore-errors (lambda () (list 'ok (line-index-at "*zz-lc-unpointed*" 3))))
                      (list 'ok #f) "and under a header it is above the entries")
        (check-equal! (ignore-errors (lambda () (list 'ok (list-current "*zz-lc-unpointed*"))))
                      (list 'ok #f) "so it has no row, rather than raising")))))

(deftest 'a-listing-card-floats-over-the-lists-own-window
  "listing-preview! floats a read-only copy of the row over the list: its own window, the neighbour untouched, the frame's group unmoved; q takes the card before the list, and dismissing gives the neighbour back"
  (lambda ()
    (t--lm-with
      (lambda ()
        (when (group-record-by-name "zz-lc-group")
          (group-record-delete! (group-record-by-name "zz-lc-group")))
        (let ((g (group-record-create! "zz-lc-group")))
          (buffer-add-group! "*zz-lc-c*" g)
          (test-buffer! "*zz-lc-side*" "work beside the list")
          (t--lm-open!)
          (run-command "delete-other-windows")
          (let ((home (active-window))
                (group (frame-group)))
            (split-window! 'h 0.5)
            (other-window!)
            (switch-to-buffer-here! "*zz-lc-side*")
            (select-window! home)
            (let ((side (other-window-id home)))
              (check-equal! (window-buffer home) t--lm-buf "the list stands in its window")
              (listing-preview! t--lm-buf "*zz-lc-c*")
              (check-true! (float-open?) "a card is floated")
              (check-equal! (buffer-local (float-buffer) 'listing-preview-source) "*zz-lc-c*"
                            "and it reads the row")
              (check-true! (buffer-read-only? (float-buffer)) "the card is a look, read-only")
              (check-false! (member (float-window) (list home side))
                            "the card is its own window, neither the list's nor the neighbour's")
              (check-equal! (window-buffer side) "*zz-lc-side*"
                            "the window beside the list keeps what it was showing")
              (check-equal! (active-window) home "the selection stayed on the list")
              (check-equal! (frame-group) group
                            "a card is a copy: the frame did not follow the row into its group")
              (run-command "quit-window")
              (check-false! (float-open?) "q takes the card first")
              (check-equal! (current-buffer) t--lm-buf "and leaves the list standing")
              (listing-preview! t--lm-buf "*zz-lc-b*")
              (check-true! (float-open?) "the next row floats a card again")
              (listing-preview-dismiss! t--lm-buf)
              (check-false! (float-open?) "dismissing takes the card down")
              (check-equal! (window-buffer side) "*zz-lc-side*"
                            "and gives the neighbour back untouched")))
          (group-record-delete! g))))))

(deftest 'a-layout-profile-is-chosen-by-width-and-answers-before-the-mode
  "the first profile whose bounds hold the width wins, a default profile catches the rest, a profile named narrow takes the narrow bound, and list-opt reads the profile's key before the mode's"
  (lambda ()
    (t--lm-with
      (lambda ()
        (t--lm-open!)
        (let ((layouts (plist-get (list-mode-opts "zz-list-contract-mode") 'layouts)))
          (check-equal! (plist-get (list-select-layout t--lm-buf layouts 40) 'name) 'narrow
                        "a narrow window takes the narrow profile")
          (check-equal! (plist-get (list-select-layout t--lm-buf layouts 50) 'name) 'narrow
                        "the bound is inclusive")
          (check-equal! (plist-get (list-select-layout t--lm-buf layouts 120) 'name) 'wide
                        "a wide window falls to the default")
          (check-equal! (list-select-layout t--lm-buf (list t--lm-narrow) 120) '()
                        "no profile fits: the mode's own options answer")
          (let ((named (list 'name 'narrow 'columns (lambda (buf) '()))))
            (check-true! (list-layout-match? t--lm-buf named (- narrow-cols 1))
                         "a profile named narrow with no bound stops at the narrow width")
            (check-false! (list-layout-match? t--lm-buf named narrow-cols)
                          "and not one column past it"))
          (buffer-set-local! t--lm-buf 'list-layout-cache (list (list-view-width t--lm-buf) t--lm-narrow))
          (check-equal! (length ((list-opt t--lm-buf 'columns) t--lm-buf)) 1
                        "the active profile's columns answer")
          (check-equal! ((list-opt t--lm-buf 'footer) t--lm-buf) '(("q" "quit")) "and its footer")
          (check-equal! ((list-opt t--lm-buf 'title) t--lm-buf) "Contract"
                        "a key the profile lacks falls to the mode")
          (buffer-set-local! t--lm-buf 'list-layout-cache (list (list-view-width t--lm-buf) t--lm-wide))
          (check-equal! (length ((list-opt t--lm-buf 'columns) t--lm-buf)) 2
                        "the wide profile's columns answer in a wide window"))))))

(deftest 'a-cell-with-no-spans-paints-no-face
  "list-lay-out reads a cell of pills with no pills, (\"\" ()), as a cell with no face, not a face named ()"
  (lambda ()
    (let ((laid (list-lay-out (list (list "" '()) (list "x" "bold"))
                              (list (list "a" 4) (list "b" #f)))))
      (check-equal! (cadr laid) (list (list 6 1 "bold"))
                    "only the named face paints a span"))))
