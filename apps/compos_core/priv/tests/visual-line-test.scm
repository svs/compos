;;; visual-line-test.scm — visual-row motion is Scheme over the wrap map.
;;; A test hands the window a map the way the client would, then runs the
;;; motion commands and reads point. Byte offsets are what the map holds,
;;; so the texts are ASCII and a byte is a character.

(define (t--vl-buf! name text)
  (let ((buf (test-buffer! name text)))
    (delete-other-windows!)
    (switch-to-buffer! buf)
    (enable-minor-mode! buf "visual-line-mode")
    (buffer-set-local! buf 'visual-goal #f)
    (set-mark! #f)
    buf))

(define (t--vl-map! buf rows)
  (window-set-wrap-map! (active-window) (buffer-version buf) rows))

(define (t--vl-done! buf)
  (when (minor-mode-on? buf "visual-line-mode")
    (disable-minor-mode! buf "visual-line-mode"))
  (buffer-kill! buf))

;; "aaaa bbbb cccc dddd\nshort\n" wrapped after every word:
;; bytes 0-3 aaaa, 4 space, 5-8 bbbb, 9 space, 10-13 cccc, 14 space,
;; 15-18 dddd, 19 newline, 20-24 short, 25 newline
(define t--vl-words "aaaa bbbb cccc dddd\nshort\n")
(define t--vl-word-rows '(0 5 10 15 20))

(deftest 'visual-row-edges-land-on-the-row-point-is-on
  "home and end stop at the measured row, never the one below"
  (lambda ()
    (let ((buf (t--vl-buf! "zz-vl-edges" t--vl-words)))
      (t--vl-map! buf t--vl-word-rows)
      (goto-char! 7)
      (check-equal! (visual-row-start 7) 5 "the row start is a lookup")
      (check-equal! (visual-row-end 7) 9 "and so is the row end")
      (run-command "end-of-line")
      (check-equal! (point) 9 "end of the second row, before the wrap space")
      (run-command "beginning-of-line")
      (check-equal! (point) 5 "start of the second row")
      (goto-char! 17)
      (run-command "end-of-line")
      (check-equal! (point) 19 "the last row of a line ends before its newline")
      (goto-char! 22)
      (run-command "end-of-line")
      (check-equal! (point) 25 "a row with nothing measured below it runs to the line end")
      (t--vl-done! buf))))

(deftest 'visual-row-moves-hold-the-goal-column-across-a-run
  "down through a short row keeps the column of the row the run began on"
  (lambda ()
    ;; bytes 0-7 aaaaaaaa, 8 space, 9-10 bb, 11 space, 12-19 cccccccc
    (let ((buf (t--vl-buf! "zz-vl-goal" "aaaaaaaa bb cccccccc\n")))
      (t--vl-map! buf '(0 9 12))
      (goto-char! 6)
      (run-command "next-line")
      (check-equal! (point) 11 "the short row clamps to its end")
      (run-command "next-line")
      (check-equal! (point) 18 "the column of the first row returns on the third")
      (run-command "previous-line")
      (check-equal! (point) 11 "and up clamps again")
      (run-command "previous-line")
      (check-equal! (point) 6 "back where the run began")
      (t--vl-done! buf))))

(deftest 'a-horizontal-move-ends-the-run
  "after a move along the row, the column is taken from where point stands"
  (lambda ()
    ;; bytes 0-7 aaaaaaaa, 8 space, 9-16 bbbbbbbb, 17 space, 18-25 cccccccc
    (let ((buf (t--vl-buf! "zz-vl-reset" "aaaaaaaa bbbbbbbb cccccccc\n")))
      (t--vl-map! buf '(0 9 18))
      (goto-char! 6)
      (run-command "next-line")
      (check-equal! (point) 15 "column six on the second row")
      (backward-char!)
      (run-command "next-line")
      (check-equal! (point) 23 "column five, taken from the new point")
      (t--vl-done! buf))))

(deftest 'a-stale-wrap-map-moves-by-source-line
  "an edit puts the buffer ahead of the map; the key still moves, by source line"
  (lambda ()
    (let ((buf (t--vl-buf! "zz-vl-stale" t--vl-words)))
      (t--vl-map! buf t--vl-word-rows)
      (buffer-insert! buf 0 "x")
      (goto-char! 2)
      (run-command "end-of-line")
      (check-equal! (point) 20 "the source line end")
      (goto-char! 2)
      (run-command "next-line")
      (check-equal! (point) 23 "one source line down")
      (t--vl-done! buf))))

(deftest 'visual-line-mode-off-moves-by-source-line
  "a map the client measured means nothing while the mode is off"
  (lambda ()
    (let ((buf (t--vl-buf! "zz-vl-off" t--vl-words)))
      (t--vl-map! buf t--vl-word-rows)
      (disable-minor-mode! buf "visual-line-mode")
      (goto-char! 2)
      (run-command "end-of-line")
      (check-equal! (point) 19 "the source line end")
      (run-command "beginning-of-line")
      (check-equal! (point) 0 "the source line start")
      (t--vl-done! buf))))

(deftest 'extending-keeps-the-anchor-and-a-plain-move-clears-the-mark
  "the shifted forms grow the region along the same rows"
  (lambda ()
    (let ((buf (t--vl-buf! "zz-vl-mark" t--vl-words)))
      (t--vl-map! buf t--vl-word-rows)
      (goto-char! 2)
      (run-command "writing-select-down")
      (check-equal! (point) 7 "one row down")
      (check-equal! (mark) 2 "the anchor is where the region began")
      (run-command "writing-select-line-end")
      (check-equal! (point) 9 "to the row end")
      (check-equal! (mark) 2 "the anchor stays")
      (run-command "next-line")
      (check-equal! (point) 14 "one row down, holding the column")
      (check-false! (mark) "a plain move clears the mark")
      (t--vl-done! buf))))

(deftest 'a-row-before-a-paragraph-break-ends-at-its-text
  "both newlines of a break stay off the row above it"
  (lambda ()
    ;; bytes 0-7 para one, 8 and 9 newlines, 10-17 para two
    (let ((buf (t--vl-buf! "zz-vl-para" "para one\n\npara two\n")))
      (t--vl-map! buf '(0 10))
      (goto-char! 2)
      (run-command "end-of-line")
      (check-equal! (point) 8 "before both newlines")
      (goto-char! 2)
      (run-command "next-line")
      (check-equal! (point) 12 "into the next paragraph, holding the column")
      (t--vl-done! buf))))

(deftest 'a-move-past-the-measured-rows-falls-back-to-the-source-line
  "the map covers the screen; beyond it the key moves by source line"
  (lambda ()
    ;; a line above the words: bytes 0-1 zz, 2 newline, then the words
    ;; from byte 3, so the rows sit at 3 8 13 18 23 and only the first
    ;; three are measured
    (let ((buf (t--vl-buf! "zz-vl-beyond" (string-append "zz\n" t--vl-words))))
      (t--vl-map! buf '(3 8 13))
      (goto-char! 20)
      (run-command "next-line")
      (check-equal! (point) 28
                    "one source line down from the last measured row: column 17 clamps to the short line's end")
      (goto-char! 5)
      (run-command "previous-line")
      (check-equal! (point) 2 "up from the first measured row is a source move to the line above")
      (t--vl-done! buf))))
