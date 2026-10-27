;;; ibuffer-test.scm --- the ibuffer table's policy: sections, order, folds, ages.
;;;
;;; Every test opens the table by command and narrows it to its own
;;; buffers, then reads the entries and the text. No test names a key.

(domain! 'testing)
(effects! '(write))

(define *ibuffer-test-mode* "zz-ib-mode")

(define (ibuffer-test-buffer! name text mode)
  (test-buffer! name text)
  (buffer-set-local! name 'mode-name mode)
  name)

(define (ibuffer-test-reset!)
  (when (buffer-known? "*ibuffer*")
    ;; the view dies on the next line: no redraw for a cleared filter
    (buffer-set-locals! "*ibuffer*"
      (list 'list-sort #f 'ibuffer-grouping #f 'ibuffer-collapsed '() 'list-filters '()))
    (buffer-kill! "*ibuffer*"))
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*"))
  (delete-other-windows!))

;; three buffers of one mode, sizes 1, 3, 2, shown in the order a c b
(define (ibuffer-test-open! grouping sort)
  (ibuffer-test-reset!)
  (ibuffer-test-buffer! "*zz-ib-a*" "1" *ibuffer-test-mode*)
  (ibuffer-test-buffer! "*zz-ib-b*" "333" *ibuffer-test-mode*)
  (ibuffer-test-buffer! "*zz-ib-c*" "22" *ibuffer-test-mode*)
  (switch-to-buffer! "*zz-ib-a*")
  (switch-to-buffer! "*zz-ib-c*")
  (switch-to-buffer! "*zz-ib-b*")
  (run-command "ibuffer")
  ;; the filter and the options land together, then one draw
  (buffer-set-locals! "*ibuffer*"
    (list 'ibuffer-grouping grouping 'list-sort sort 'ibuffer-collapsed '()
          'list-filters (list (list "match" "zz-ib-"))))
  (ibuffer-refresh!))

(define (ibuffer-test-names)
  (filter string? (list-entries "*ibuffer*")))

(define (ibuffer-test-headings)
  (map ibuffer-heading-label
       (filter ibuffer-heading? (list-entries "*ibuffer*"))))

(deftest 'ibuffer-notes-when-a-buffer-was-last-shown
  "the hook stamps the shown buffer, and the row reads the age back"
  (lambda ()
    (check-true! (member 'ibuffer--seen-hook!
                         (hook-functions 'window-configuration-change-hook))
                 "the hook is on window-configuration-change-hook")
    ;; the stamp is the buffer's own local, so it needs a buffer: the hook
    ;; only ever passes the buffer the active window shows
    (buffer-create "*zz-ib-seen*")
    (ibuffer-note-seen! "*zz-ib-seen*")
    (check-equal! (ibuffer-last-label "*zz-ib-seen*") "now" "just noted")
    (check-equal! (ibuffer-last-label "*zz-ib-never-shown*") "" "never noted")
    (buffer-kill! "*zz-ib-seen*")))

(deftest 'ibuffer-sections-by-mode
  "grouped by mode, one heading per mode, by name, in its own register, with the member count"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (buffer-set-local! "*zz-ib-b*" 'mode-name "aa-other-mode")
    (ibuffer-refresh!)
    (check-equal! (ibuffer-test-headings) '("aa-other-mode" "zz-ib-mode") "one heading per mode, by name")
    (let ((heading (car (filter ibuffer-heading? (list-entries "*ibuffer*")))))
      (check-equal! (ibuffer-heading-count heading) 1 "the first section holds b")
      (check-equal! (ibuffer-heading-members heading) '("*zz-ib-b*") "its member"))
    (let ((second (nth 1 (filter ibuffer-heading? (list-entries "*ibuffer*")))))
      (check-equal! (ibuffer-heading-count second) 2 "the zz-ib heading counts two")
      (check-equal! (ibuffer-heading-details "*ibuffer*" second) "2 buffers"
                    "and a heading counts in the view's own noun, never a bare digit")
      (check-equal! (ibuffer-heading-details "*ibuffer*"
                      (list "zz" "" "separator" "zz" 3 2 0 #f '()))
                    "3 buffers · 2 modified"
                    "a heading says how many of its rows hold unsaved edits")
      (check-equal! (ibuffer-section-label second) "ZZ-IB-MODE"
                    "the name is set in a register no row uses")
      (check-equal! (ibuffer-section-kind "*ibuffer*" second) "mode"
                    "and it says what kind of section it is")
      (check-equal! (ibuffer-section-label (list "*mail*" "" "separator" "group:g" 1 0 0 #f '()))
                    "MAIL"
                    "a group named after a buffer drops the stars")
      (check-equal! (ibuffer-section-kind "*ibuffer*"
                      (list "*mail*" "" "separator" "group:g" 1 0 0 #f '()))
                    "buffer"
                    "and says the word the stars stood for"))
    (check-equal! (ibuffer-field-fill "") "—" "an empty field keeps its column")
    (check-equal! (ibuffer-field-fill "2.4k") "2.4k" "a field with something to say says it")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-sections-by-directory-put-no-file-last
  "grouped by directory, a buffer with no file sits under no file"
  (lambda ()
    (ibuffer-test-open! 'directory 'name)
    (check-equal! (ibuffer-test-headings) '("no file") "no file buffers make one section")
    (check-equal! (ibuffer-test-names) '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*") "by name inside it")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-sorts-a-section-by-name-recency-or-size
  "the three orders, on the same three rows"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (check-equal! (ibuffer-test-names) '("*zz-ib-a*" "*zz-ib-b*" "*zz-ib-c*") "name order")
    (ibuffer-set-sort! 'recent)
    (check-equal! (ibuffer-test-names) '("*zz-ib-b*" "*zz-ib-c*" "*zz-ib-a*") "recent order is MRU")
    (ibuffer-set-sort! 'size)
    (check-equal! (ibuffer-test-names) '("*zz-ib-b*" "*zz-ib-c*" "*zz-ib-a*") "largest first")
    (check-contains! (car (ibuffer-meta "*ibuffer*")) "by mode · size" "the meta names the order")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-toggle-sorting-mode-cycles
  "the cycle runs name, recent, size, mode, name"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'recent "name then recent")
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'size "recent then size")
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'mode "size then mode")
    (run-command "ibuffer-toggle-sorting-mode")
    (check-equal! (ibuffer-sort) 'name "mode then name")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping) 'directory "mode then directory")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping) 'none "directory then none: a flat table is one of the choices")
    (run-command "ibuffer-toggle-grouping")
    (check-equal! (ibuffer-grouping) 'group "none then group, and round again")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-folds-a-section-into-its-heading
  "a folded heading is a row that carries the counts; the narrowing keeps it while a member matches"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (ibuffer-goto-first-row! "*ibuffer*")
    (check-true! (string? (ibuffer-current)) "point starts on a member row")
    (list-goto-first-entry "*ibuffer*")
    (check-true! (ibuffer-heading? (ibuffer-current))
                 "the first row of the table is the heading, and it is a row")
    (ibuffer-goto-first-row! "*ibuffer*")
    (run-command "ibuffer-toggle-filter-group")
    (let ((es (list-entries "*ibuffer*")))
      (check-equal! (length es) 1 "only the heading remains")
      (check-true! (ibuffer-heading-folded? (car es)) "and it is folded")
      (check-equal! (ibuffer-heading-count (car es)) 3 "it counts its members")
      (check-equal! (ibuffer-heading-bytes (car es)) 6 "and their bytes"))
    (check-contains! (buffer-text "*ibuffer*") "▸" "the chevron points right")
    (check-contains! (car (ibuffer-meta "*ibuffer*")) "3 buffers" "the meta still counts the folded rows")
    (check-true! (ibuffer-heading? (ibuffer-current)) "the highlight can rest on the heading")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-b")))
    (check-equal! (length (list-entries "*ibuffer*")) 1 "a member matches, so the heading stays")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-nothing-here")))
    (check-equal! (length (list-entries "*ibuffer*")) 0 "no member matches, so it goes")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-")))
    (run-command "ibuffer-visit")
    (check-equal! (length (ibuffer-test-names)) 3 "RET on the heading opens it again")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-a-name-written-as-markdown-draws-as-text
  "a name a summary wrote in Markdown draws as words, with the emphasis as a face"
  (lambda ()
    (check-equal! (ibuffer-md-plain "fix `list-refresh!` and **fold** state")
                  '("fix list-refresh! and fold state"
                    ((4 13 "morg-code") (22 4 "morg-bold")))
                  "the markers go, and each run keeps its face")
    (check-equal! (ibuffer-md-plain "see [the docs](http://x) here")
                  '("see the docs here" ((4 8 "link")))
                  "a link draws its text, never its target")
    (check-equal! (ibuffer-md-plain "*scratch*") '("*scratch*" ())
                  "one star each side is a buffer's name, not emphasis")
    (check-equal! (ibuffer-md-plain "zz_ib_notes") '("zz_ib_notes" ())
                  "an underscore inside a word is part of the word")
    (ibuffer-test-open! 'mode 'name)
    (check-true! (ibuffer-md-row? "*zz-ib-a*") "a row with no file is read as prose")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-a-name-is-read-by-the-inline-grammar
  "a double-tick code span keeps its ticks inside; a star after a space closes nothing"
  (lambda ()
    (check-equal! (ibuffer-md-plain "fix ``a `b` c`` now")
                  '("fix a `b` c now" ((4 7 "morg-code")))
                  "the span's own delimiter length")
    (check-equal! (ibuffer-md-plain "**not bold ** here")
                  '("**not bold ** here" ())
                  "no strong run where the grammar reads none")))

(deftest 'ibuffer-headings-and-marks-wear-bands
  "a heading wears its register, a marked row wears a band across the row"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let* ((es (list-entries "*ibuffer*"))
           (heading (car es))
           (ov (ibuffer-row-overlays "*ibuffer*" heading 100)))
      (check-equal! (length ov) 1 "no band: the heading is not a coloured row")
      (check-equal! (nth 2 (car ov)) "faint" "the kind, the rule and the tally are faint")
      (check-equal! (car (car ov))
                    (+ 100 2 1 2 (string-byte-length (ibuffer-chevron heading)) 2
                       (string-byte-length (ibuffer-section-label heading)))
                    "the faint span starts where the name ends"))
    (list-mark! "*ibuffer*" "*zz-ib-a*" "*")
    (let ((ov (ibuffer-row-overlays "*ibuffer*" "*zz-ib-a*" 200)))
      (check-equal! (nth 2 (car ov)) "ibuffer-marked" "a marked row wears the tint"))
    (list-mark! "*ibuffer*" "*zz-ib-a*" #f)
    (check-equal! (ibuffer-row-overlays "*ibuffer*" "*zz-ib-a*" 200) '() "an unmarked buffer with no file wears nothing")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-toggle-mark-marks-then-unmarks
  "list-toggle-mark on an unmarked row marks it and moves down; on a marked row it unmarks"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (ibuffer-goto-first-row! "*ibuffer*")
    (check-equal! (ibuffer-current) "*zz-ib-a*" "start on the first row")
    (run-command "list-toggle-mark")
    (check-equal! (list-mark-of "*ibuffer*" "*zz-ib-a*") "*" "the row is marked")
    (check-equal! (ibuffer-current) "*zz-ib-b*" "and point moved down")
    (ibuffer-goto-first-row! "*ibuffer*")
    (run-command "list-toggle-mark")
    (check-equal! (list-mark-of "*ibuffer*" "*zz-ib-a*") " " "the same key clears the mark")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-group-kill-kills-the-section-group
  "K on a row under group sectioning kills that row's group: the members and the record"
  (lambda ()
    (ibuffer-test-reset!)
    (when (group-record-by-name "zz-ib-group")
      (group-record-delete! (group-record-by-name "zz-ib-group")))
    (test-buffer! "*zz-ib-a*" "")
    (test-buffer! "*zz-ib-b*" "")
    (let ((g (group-record-create! "zz-ib-group")))
      (buffer-add-group! "*zz-ib-a*" g)
      (buffer-add-group! "*zz-ib-b*" g)
      (switch-to-buffer! "*zz-ib-a*")
      (run-command "ibuffer")
      (buffer-set-locals! "*ibuffer*"
        (list 'ibuffer-grouping 'group 'list-sort 'name 'ibuffer-collapsed '()))
      (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-")))
      (ibuffer-refresh!)
      (ibuffer-goto-first-row! "*ibuffer*")
      (check-true! (string? (ibuffer-current)) "point is on a member row")
      (check-equal! (ibuffer-group-at) g "the row's section names the group")
      ;; k on the group row is the same act: the row stands for the group
      (list-goto-first-entry "*ibuffer*")
      (check-true! (ibuffer-heading? (ibuffer-current)) "the group row takes the highlight")
      (check-equal! (length (ibuffer-targets "*ibuffer*")) 2
                    "and a verb on it reads both members")
      (run-command "ibuffer-group-kill")
      (check-false! (buffer-known? "*zz-ib-a*") "the first member is gone")
      (check-false! (buffer-known? "*zz-ib-b*") "the second member is gone")
      (check-false! (group-record-by-id g) "and the group record with them"))
    (ibuffer-test-reset!)))

(deftest 'ibuffer-narrows-by-mode-and-name
  "the typed narrowing reads the mode as well as the name"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (list-set-filters! "*ibuffer*" (list (list "match" *ibuffer-test-mode*)))
    (check-equal! (length (ibuffer-test-names)) 3 "every row wears the mode")
    (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-c")))
    (check-equal! (ibuffer-test-names) '("*zz-ib-c*") "and the name still narrows")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-rows-wear-a-dot-for-state-alone
  "a buffer with no file wears no dot; every field is a column of its own"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let ((cells (ibuffer-compact-cells "*ibuffer*" "*zz-ib-b*")))
      (check-equal! (car cells) "" "a buffer with no file has no state to show")
      (check-equal! (car (nth 2 cells)) "*zz-ib-b*" "the name")
      (check-equal! (car (nth 3 cells)) "3" "the size is a cell of its own"))
    (check-false! (ibuffer-buffer-modified? "*zz-ib-b*")
                  "a buffer with no file counts as modified nowhere")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-heading-carries-its-count-beside-the-name
  "a heading's name cell holds the name, a rule and its tally; its field cells say nothing"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let* ((heading (car (filter ibuffer-heading? (list-entries "*ibuffer*"))))
           (cells (ibuffer-wide-cells "*ibuffer*" heading))
           (name (car (nth 2 cells))))
      (check-true! (string-prefix? "ZZ-IB" name) "the name leads, in upper case")
      (check-true! (string-contains? name "─") "a rule runs from the name to the tally")
      (check-true! (string-suffix? "3 buffers" name) "and the tally ends the cell")
      (check-equal! (nth 3 cells) "" "the first field cell is empty")
      (check-equal! (nth 4 cells) "" "and so is the second")
      (let ((lines (filter (lambda (l) (string-contains? l "▾  ZZ-IB"))
                           (string-split (buffer-text "*ibuffer*") "\n"))))
        (check-true! (pair? lines) "the drawn line reads the chevron and the name")
        (check-true! (string-suffix? "3 buffers" (car lines))
                     "and ends with the tally")))
    (ibuffer-test-reset!)))

(deftest 'ibuffer-name-column-stops-at-its-cap
  "one long name widens the name column into empty room, never into a field's"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let ((long (string-append "*zz-ib-" (string-repeat "x" 70) "*")))
      (ibuffer-test-buffer! long "1" *ibuffer-test-mode*)
      (ibuffer-refresh!)
      (let* ((cols (list-columns "*ibuffer*"))
             (total (fold (lambda (n c) (+ n (list-col-width c))) 0 cols)))
        (check-true! (<= total (list-view-width "*ibuffer*"))
                     "every column still fits the window")
        (check-true! (< (list-col-width (nth 2 cols)) (string-length long))
                     "and the name column stops short of the longest name"))
      (buffer-kill! long))
    (ibuffer-test-reset!)))

(deftest 'ibuffer-drops-the-field-the-sections-already-say
  "sectioned by mode, no row repeats its mode; sectioned by group, none repeats its group"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (check-equal! (map ibuffer-field-tag (ibuffer-fields "*ibuffer*" *ibuffer-wide-fields*))
                  '(size group last) "the mode column goes")
    (ibuffer-set-grouping! 'group)
    (check-equal! (map ibuffer-field-tag (ibuffer-fields "*ibuffer*" *ibuffer-wide-fields*))
                  '(size mode last) "the group column goes")
    (ibuffer-set-grouping! 'directory)
    (check-equal! (map ibuffer-field-tag (ibuffer-fields "*ibuffer*" *ibuffer-wide-fields*))
                  '(size mode group last) "by directory every field earns its place")
    (ibuffer-test-reset!)))

(deftest 'ibuffer-shows-no-key-bar-and-no-column-names
  "the head is one line: the title, the counts, and where the keys are"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (check-true! (pair? (ibuffer-compact-footer "*ibuffer*")) "the footer names the main keys for the bar")
    (check-equal! (list-label-lines "*ibuffer*" (list-columns "*ibuffer*")) '()
                  "and no column is named, so no label row")
    (check-false! (string-contains? (car (ibuffer-meta "*ibuffer*")) "? keys")
                  "the head says nothing about keys: the bar at the foot has them")
    (ibuffer-test-reset!)))

;;; --- RET goes to the buffer where it lives ------------------------------------

;; two groups, one buffer each, the frame standing in the first
(define (ibuffer-test-two-groups!)
  (ibuffer-test-reset!)
  (for-each (lambda (name)
              (let ((old (group-record-by-name name)))
                (when old (group-record-delete! old))))
            '("zzgrp-one" "zzgrp-two"))
  (test-buffer! "*zz-ib-a*" "")
  (test-buffer! "*zz-ib-b*" "")
  (let ((one (group-record-create! "zzgrp-one"))
        (two (group-record-create! "zzgrp-two")))
    (buffer-add-group! "*zz-ib-a*" one)
    (buffer-add-group! "*zz-ib-b*" two)
    (switch-to-group! one)
    (switch-to-buffer! "*zz-ib-a*")
    (list one two)))

;; open the table on one row alone and rest the highlight on it
(define (ibuffer-test-point-on! name)
  (run-command "ibuffer")
  (buffer-set-locals! "*ibuffer*"
    (list 'ibuffer-grouping 'group 'list-sort 'name 'list-tab 'all 'ibuffer-collapsed '()))
  (list-set-filters! "*ibuffer*" (list (list "match" name)))
  (ibuffer-refresh!)
  (ibuffer-goto-first-row! "*ibuffer*")
  (ibuffer-current "*ibuffer*"))

(define (ibuffer-test-groups-reset! ids)
  (ibuffer-test-reset!)
  ;; a group with no saved layout builds one, and that makes its chat: the
  ;; buffers a verb made must not outlive the test that made them
  (for-each (lambda (b)
              (when (and (buffer-known? b) (string-contains? b "zzgrp-"))
                (buffer-kill! b)))
            (buffer-list))
  (for-each (lambda (id) (when (group-record-by-id id) (group-record-delete! id))) ids))

(deftest 'ibuffer-visit-enters-the-group-of-the-row
  "RET on a row of another group enters that group and focuses the buffer"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (check-equal! (frame-group) one "the frame stands in the first group")
      (check-equal! (ibuffer-test-point-on! "zz-ib-b") "*zz-ib-b*" "point is on the other group's row")
      (run-command "ibuffer-visit")
      (check-equal! (frame-group) two "the frame entered the row's group")
      (check-equal! (current-buffer) "*zz-ib-b*" "and the buffer is the one in hand")
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-visit-stays-put-for-a-buffer-of-this-group
  "a row of the group at hand opens without a switch"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids)))
      (check-equal! (ibuffer-test-point-on! "zz-ib-a") "*zz-ib-a*" "point is on this group's row")
      (run-command "ibuffer-visit")
      (check-equal! (frame-group) one "the frame kept its group")
      (check-equal! (current-buffer) "*zz-ib-a*" "and the buffer is the one in hand")
      (ibuffer-test-groups-reset! ids))))

;;; --- C-. on a row --------------------------------------------------------------

(define (ibuffer-test-act! name)
  (let ((a (assoc name (actions-for 'buffer))))
    (check-true! (and a #t) (string-append "the menu offers " name))
    ((cadr a) (ibuffer-current "*ibuffer*"))))

(deftest 'ibuffer-row-is-a-typed-target
  "the row at point answers as a buffer target, it follows the highlight, and a heading answers nothing"
  (lambda ()
    (let ((ids (ibuffer-test-two-groups!)))
      (ibuffer-test-point-on! "zz-ib-")
      (check-equal! (target-at "*ibuffer*") '(buffer "*zz-ib-a*" "*zz-ib-a*")
                    "the row at point names itself")
      (let* ((rows (list-entries "*ibuffer*"))
             (i (list-index-of "*ibuffer*" rows "*zz-ib-b*"))
             (heading (list-index-of "*ibuffer*" rows
                                     (list-key "*ibuffer*"
                                               (car (filter ibuffer-heading? rows))))))
        (list-goto-index! "*ibuffer*" i)
        (check-equal! (target-at "*ibuffer*") '(buffer "*zz-ib-b*" "*zz-ib-b*")
                      "the target follows the highlight")
        (list-goto-index! "*ibuffer*" heading)
        (check-false! (ibuffer-target-at "*ibuffer*") "a heading is no target"))
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-act-move-here-takes-the-row-into-this-group
  "move here leaves the row's old group and joins the group at hand"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (ibuffer-test-point-on! "zz-ib-b")
      (ibuffer-test-act! "move here")
      (check-equal! (buffer-group "*zz-ib-b*") one "the buffer moved to the group at hand")
      (check-equal! (group-buffers two) '() "and left the group it was in")
      (ibuffer-test-groups-reset! ids))))

(deftest 'ibuffer-act-reads-the-marks
  "a verb acts on every marked row, not on the row at point alone"
  (lambda ()
    (let* ((ids (ibuffer-test-two-groups!))
           (one (car ids))
           (two (cadr ids)))
      (ibuffer-test-point-on! "zz-ib-")
      (check-equal! (group-here) one "the group at hand is the one the frame came from")
      (check-equal! (ibuffer-current "*ibuffer*") "*zz-ib-a*" "point rests on the first row")
      (list-mark! "*ibuffer*" "*zz-ib-a*" "*")
      (list-mark! "*ibuffer*" "*zz-ib-b*" "*")
      (ibuffer-test-act! "move here")
      (check-true! (buffer-in-group? "*zz-ib-b*" one)
                   "the marked row that point does not rest on moved too")
      (check-false! (buffer-in-group? "*zz-ib-b*" two) "and left the group it was in")
      (ibuffer-test-groups-reset! ids))))




(deftest 'ibuffer-header-totals-come-off-the-source
  "the header's numbers are worked out when the source is built, not per keystroke"
  (lambda ()
    (ibuffer-test-open! 'mode 'name)
    (let ((all (ibuffer-total "*ibuffer*")))
      (check-equal! (nth 1 (ibuffer-source-facts "*ibuffer*")) all
                    "the source build left the count behind")
      (check-equal! (length (ibuffer-source-facts "*ibuffer*")) 2
                    "and nothing else: the header counts rows, it does not weigh them")
      (check-false! (buffer-local "*ibuffer*" 'ibuffer-source-facts)
                    "and none of it sits in the locals every draw reads")
      (list-set-filters! "*ibuffer*" (list (list "match" "zz-ib-c")))
      (check-equal! (ibuffer-total "*ibuffer*") all
                    "a narrowing leaves the total alone")
      (check-equal! (list-count "*ibuffer*") 1
                    "and the chip's other number is what the narrowing shows"))
    (ibuffer-test-reset!)))
