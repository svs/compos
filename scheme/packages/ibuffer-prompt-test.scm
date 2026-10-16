;;; ibuffer-prompt-test.scm --- the two forms of C-x b.
;;;
;;; ibuffer-prompt is the plain minibuffer list: the pool as candidates,
;;; no table. ibuffer-prompt-pretty is the ibuffer table in the minibuffer
;;; form: a dock at the bottom of the frame with its filter line in front.
;;;
;;; Every test opens a form by command, reads the dock and the prompt, and
;;; drives the prompt through the minibuffer commands. No test names a key.

(domain! 'testing)
(effects! '(write))

(define *ibp-bufs* '("*zz-ibp-a*" "*zz-ibp-b*" "*zz-ibp-c*"))

(define (ibp-drop-group! name)
  (when (group-record-by-name name) (group-record-delete! name)))

(define (ibp-reset!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (when (float-open?) (float-close!))
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (append *ibp-bufs* (list " *buffers*" "*zz-ibp-chat*")))
  ;; a group founded here brings a chat and a scratch along: take them away
  (for-each (lambda (b)
              (when (or (string-prefix? "*chat:zz-ibp" b) (string-prefix? "*scratch:zz-ibp" b))
                (buffer-kill! b)))
            (buffer-list))
  (ibp-drop-group! "zz-ibp-one")
  (ibp-drop-group! "zz-ibp-two")
  (delete-other-windows!))

;; a and b in group one, c in group two; the last switch was to b, and
;; the prompt opens from a
(define (ibp-setup!)
  (ibp-reset!)
  (let ((one (group-record-create! "zz-ibp-one"))
        (two (group-record-create! "zz-ibp-two")))
    (for-each (lambda (b) (test-buffer! b "")) *ibp-bufs*)
    (buffer-add-group! "*zz-ibp-a*" one)
    (buffer-add-group! "*zz-ibp-b*" one)
    (buffer-add-group! "*zz-ibp-c*" two)
    ;; shown through the mechanism a layout uses, which places without joining
    (switch-to-buffer-here! "*zz-ibp-c*")
    (switch-to-buffer-here! "*zz-ibp-b*")
    (switch-to-buffer-here! "*zz-ibp-a*")
    (set-frame-local! 'current-group one)
    (list one two)))

;; the table narrows after a delay; the flush applies the query now
(define (ibp-type! text)
  (minibuffer-change! text)
  (when *mb-list-flush* (*mb-list-flush*)))

(define (ibp-names view)
  (filter string? (list-entries view)))

;; the fixture's own rows: a group founded here brings its chat along
(define (ibp-mine view)
  (filter (lambda (b) (member b *ibp-bufs*)) (ibp-names view)))

(define (ibp-labels view)
  (map (lambda (e) (if (ibuffer-heading? e) (ibuffer-heading-label e) e))
       (list-entries view)))

;; the plain prompt's candidates, by label
(define (ibp-candidates)
  (map (lambda (c) (plist-get c 'label)) (plist-get (minibuffer-state) 'candidates)))

(define (ibp-my-candidates)
  (filter (lambda (b) (member b *ibp-bufs*)) (ibp-candidates)))

(deftest 'the-buffer-prompt-is-the-plain-minibuffer-list
  "ibuffer-prompt opens a candidate prompt over the pool: no table, no dock, no headings"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt")
    (check-false! (float-open?) "no popup")
    (check-false! (buffer-known? " *buffers*") "no table")
    (check-equal! (plist-get (minibuffer-state) 'prompt) "Switch to: " "the prompt line is open")
    (check-equal! (ibp-my-candidates) '("*zz-ibp-b*" "*zz-ibp-c*" "*zz-ibp-a*")
                  "the window's history first, the buffer you are on last")
    (check-false! (member "zz-ibp-one" (ibp-candidates)) "a group name is not a candidate")
    (ibp-reset!)))

(deftest 'the-pretty-prompt-is-the-table-under-a-filter-line
  "ibuffer-prompt-pretty docks the ibuffer view at the bottom, its rows by group under the group's name, and the prompt in front"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (let ((w (window-showing " *buffers*")))
      (check-true! (and w #t) "the table has a window")
      (check-equal! (window-docked " *buffers*") w "the window is a dock, not a popup")
      (check-false! (float-open?) "nothing floats"))
    (check-equal! (buffer-local " *buffers*" 'mode-name) "ibuffer-pretty-mode" "in ibuffer-pretty-mode")
    (check-equal! (plist-get (minibuffer-state) 'prompt) "Switch to: " "the prompt line is open")
    (list-set-filters! " *buffers*" (list (list "match" "zz-ibp-")))
    (let ((labels (ibp-labels " *buffers*")))
      (check-equal! (car labels) "zz-ibp-one" "this group leads, under its own name")
      (check-true! (and (member "zz-ibp-two" labels) #t) "the other group under its name")
      (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*")
                    "the rows in the window's history order, the buffer you are on last in its group"))
    (ibp-reset!)))

(deftest 'typing-narrows-the-table-and-arrows-move-its-highlight
  "the prompt's change narrows the rows after the filter delay; next-candidate moves the table's highlight"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (ibp-type! "zz-ibp-")
    (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*") "three rows match")
    (check-equal! (window-buffer (buffer-local " *buffers*" 'ibuffer-prompt-home-window)) "*zz-ibp-b*"
                  "the prompt previews the highlighted buffer in the invoking window")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "the highlight starts on the first row")
    (run-command "minibuffer-next-candidate")
    (check-equal! (list-current " *buffers*") "*zz-ibp-a*" "and moves down a row")
    (run-command "minibuffer-previous-candidate")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "and back up")
    (ibp-type! "zz-ibp-c")
    (check-equal! (ibp-names " *buffers*") '("*zz-ibp-c*") "a longer query narrows further")
    (check-equal! (list-current " *buffers*") "*zz-ibp-c*" "over the heading, onto the row that matches")
    (ibp-reset!)))

(deftest 'typing-narrows-the-plain-prompt-and-previews-the-selection
  "the plain prompt narrows its candidates on change and shows the selected one in the invoking window"
  (lambda ()
    (ibp-setup!)
    (let ((home (active-window)))
      (run-command "ibuffer-prompt")
      (minibuffer-change! "zz-ibp-")
      (check-equal! (ibp-candidates) '("*zz-ibp-b*" "*zz-ibp-c*" "*zz-ibp-a*") "three candidates match")
      (check-equal! (plist-get (minibuffer-state) 'sel) 0 "the selection starts on the first")
      (check-equal! (window-buffer home) "*zz-ibp-b*" "and the invoking window previews it")
      (run-command "minibuffer-next-candidate")
      (check-equal! (window-buffer home) "*zz-ibp-c*" "the next candidate is previewed in turn")
      (minibuffer-cancel!)
      (check-equal! (window-buffer home) "*zz-ibp-a*" "cancel gives the window its buffer back"))
    (ibp-reset!)))

(deftest 'confirm-takes-the-row-and-brings-it-here
  "RET switches to the highlighted candidate; a buffer of another group joins this one and the frame stays (the ruling of 2026-09-22)"
  (lambda ()
    (let ((groups (ibp-setup!)))
      (run-command "ibuffer-prompt")
      (minibuffer-change! "zz-ibp-c")
      (run-command "minibuffer-confirm")
      (check-false! (minibuffer-state) "the prompt is closed")
      (check-false! (float-open?) "nothing floats")
      (check-equal! (current-buffer) "*zz-ibp-c*" "the row is the current buffer")
      (check-equal! (frame-group) (car groups) "the frame stands where it stood")
      (check-true! (buffer-in-group? "*zz-ibp-c*" (car groups)) "and the buffer joined this group"))
    (ibp-reset!)))

(deftest 'confirm-in-the-table-takes-the-row-and-closes-the-dock
  "RET in the pretty form switches to the highlighted row, and the table and its dock go"
  (lambda ()
    (let ((groups (ibp-setup!)))
      (run-command "ibuffer-prompt-pretty")
      (ibp-type! "zz-ibp-c")
      (run-command "minibuffer-confirm")
      (check-false! (minibuffer-state) "the prompt is closed")
      (check-false! (window-showing " *buffers*") "the table is closed")
      (check-false! (buffer-known? " *buffers*") "and its buffer is gone")
      (check-equal! (current-buffer) "*zz-ibp-c*" "the row is the current buffer")
      (check-equal! (frame-group) (cadr groups) "the frame entered the buffer's group")
      (check-equal! (list-query " *buffers*") "" "the next open starts wide"))
    (ibp-reset!)))

(deftest 'cancel-closes-the-table-and-keeps-the-buffer
  "C-g closes the dock and the buffer you came from stays current"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (ibp-type! "zz-ibp-c")
    (minibuffer-cancel!)
    (check-false! (minibuffer-state) "the prompt is closed")
    ;; the table went with the prompt: a table left standing in a window is
    ;; no longer a dock to anything, so nothing would ever close it
    (check-false! (window-showing " *buffers*") "the table is not left standing")
    (check-false! (buffer-known? " *buffers*") "and its buffer is gone")
    (check-equal! (length (window-list)) 1 "the dock's pane went with it")
    (check-equal! (current-buffer) "*zz-ibp-a*" "the buffer you came from")
    (ibp-reset!)))

(deftest 'cancel-still-closes-the-table-when-the-dock-is-the-only-window
  "C-x 1 under the prompt leaves the table as the only window; C-g still closes it and the work buffer returns"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (delete-other-windows!)
    (check-equal! (map cadr (window-list)) '(" *buffers*") "the table is the only window")
    (check-true! (and (minibuffer-state) #t) "the prompt is still open")
    (minibuffer-cancel!)
    (check-false! (minibuffer-state) "the prompt is closed")
    (check-false! (window-showing " *buffers*") "the table is closed, not left standing")
    (check-false! (buffer-known? " *buffers*") "and its buffer is gone, the way q's own close leaves it")
    (check-equal! (current-buffer) "*zz-ibp-a*" "the window shows the buffer you came from")
    (ibp-reset!)))

(deftest 'the-prompt-dock-wears-no-chrome
  "a switcher you close in one keystroke shows no line numbers and no modeline"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (check-equal! (buffer-local " *buffers*" 'line-numbers) "off" "no line numbers")
    (check-true! (string-contains? (buffer-local " *buffers*" 'window-classes) "bare")
                 "the window wears the bare class")
    (check-true! (and (member '("TAB" "fold") (plist-get (minibuffer-state) 'legend)) #t)
                 "the prompt says the keys it answers")
    (ibp-reset!)))

(deftest 'the-prompt-folds-the-section-at-hand
  "TAB's command folds the section the highlight is in, and folds it back"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (ibp-type! "zz-ibp-")
    (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*")
                  "both sections show their rows")
    (run-command "minibuffer-complete")
    (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-c*")
                  "the first section stands for its rows")
    (run-command "minibuffer-complete")
    (check-equal! (ibp-mine " *buffers*") '("*zz-ibp-b*" "*zz-ibp-a*" "*zz-ibp-c*")
                  "and unfolds again")
    (ibp-reset!)))

(deftest 'the-prompt-cycles-what-a-section-is
  "the regroup command moves the table from group to mode and on to directory"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (check-equal! (ibuffer-grouping " *buffers*") 'group "the table starts by group")
    (run-command "minibuffer-regroup")
    (check-equal! (ibuffer-grouping " *buffers*") 'mode "then by mode")
    (run-command "minibuffer-regroup")
    (check-equal! (ibuffer-grouping " *buffers*") 'directory "then by directory")
    (ibp-reset!)))

(deftest 'the-prompt-jumps-section-to-section
  "the section commands land on the first row of the next section, never on a heading"
  (lambda ()
    (ibp-setup!)
    (run-command "ibuffer-prompt-pretty")
    (ibp-type! "zz-ibp-")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "the highlight starts in this group")
    (run-command "minibuffer-next-section")
    (check-equal! (list-current " *buffers*") "*zz-ibp-c*" "the next section's first row")
    (run-command "minibuffer-previous-section")
    (check-equal! (list-current " *buffers*") "*zz-ibp-b*" "and back to the first section's first row")
    (ibp-reset!)))
