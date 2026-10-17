;;; visual-line.scm --- visual-line-mode: motion over rendered rows.
;;;
;;; The client reports where the rendered rows begin (the wrap map); this
;;; minor mode decides what a key means on those rows. Loaded from init.scm.

(domain! 'unknown)
(effects! '(unknown))

;;; --- visual lines --------------------------------------------------------------
;;; Visual lines are a buffer capability, independent of the major mode.
;;; This minor mode owns the durable flag. The client measures where the
;;; rendered rows begin and reports the byte offsets per window, tagged
;;; with the buffer version it measured: the wrap map. The client cannot
;;; know what a key means on those rows; that is decided here.

(domain! 'interaction)
(effects! '(write))

(define (visual-line-mode--apply! buf)
  (buffer-set-local! buf 'visual-line-mode #t))

(define (visual-line-mode--teardown! buf)
  (buffer-set-local! buf 'visual-line-mode #f)
  (buffer-set-local! buf 'visual-goal #f))

(register-minor-mode!
  "visual-line-mode"
  visual-line-mode--apply!
  visual-line-mode--teardown!)

(define-command "visual-line-mode" "Toggle visual-row motion in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "visual-line-mode")
        (message "Visual line mode enabled")
        (message "Visual line mode disabled"))))

(mode-doc! "visual-line-mode"
  "Wrap long logical lines and make vertical motion follow rendered rows.")

;; The rows the client measured for the active window, when the mode is
;; on and the map is as new as the buffer. A map from an older version
;; names rows that moved, so the caller moves by source line instead, and
;; the measure after the next paint repairs it. A key never waits.
(define (visual-rows buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (let ((m (window-wrap-map (active-window))))
         (and m
              (equal? (car m) (buffer-version buf))
              (cadr m)))))

;; the end of the source line holding POS: the byte before its newline
(define (visual--line-end pos)
  (let* ((n (line-number-at-pos pos))
         (next (line-start-position (+ n 1))))
    (if (> next pos) (- next 1) (buffer-size (current-buffer)))))

;; The row holding POS: (START NEXT), NEXT being where the row below
;; begins, or #f for the last measured row. #f when POS is above every
;; measured row, or below the last one's source line.
(define (visual-row-bounds rows pos)
  (let loop ((rs rows) (start #f))
    (cond ((null? rs)
           (and start (<= pos (visual--line-end start)) (list start #f)))
          ((> (car rs) pos)
           (and start (list start (car rs))))
          (else (loop (cdr rs) (car rs))))))

;; the byte before POS, as a one-byte string; "" at the buffer start
(define (visual--byte-before pos)
  (if (> pos 0) (buffer-substring (- pos 1) pos) ""))

;; Where the row that begins at START ends. The row below begins at NEXT,
;; and the byte before NEXT is what the browser wrapped at. A space or a
;; newline there is not something the reader sees on this row, so the row
;; ends before it; a paragraph break is two newlines, and both stay off.
;; A row with nothing measured below it runs to the end of its source line.
(define (visual-row-end-from start next)
  (if (not next)
      (visual--line-end start)
      (let* ((b (visual--byte-before next))
             (q (if (and (> next start) (or (equal? b " ") (equal? b "\n")))
                    (- next 1)
                    next)))
        ;; a row never runs past its own newline: a table row measures from
        ;; its cell text, so NEXT can sit past "|\n| [" on the line below
        (min (visual--line-end start)
             (let loop ((q q))
               (if (and (> q start) (equal? (visual--byte-before q) "\n"))
                   (loop (- q 1))
                   q))))))

(define (visual--row-before rows start)
  (let loop ((rs rows) (prev #f))
    (cond ((null? rs) #f)
          ((= (car rs) start) prev)
          (else (loop (cdr rs) (car rs))))))

(define (visual-row-start pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (car b))))))
(public! 'visual-row-start
  "(visual-row-start POS) — the byte offset the visual row holding POS begins at; #f when the wrap map cannot say")

(define (visual-row-end pos)
  (let ((rows (visual-rows (current-buffer))))
    (and rows
         (let ((b (visual-row-bounds rows pos)))
           (and b (visual-row-end-from (car b) (cadr b)))))))
(public! 'visual-row-end
  "(visual-row-end POS) — the byte offset the visual row holding POS ends at; #f when the wrap map cannot say")

;; The column a run of vertical moves holds, in characters from the row
;; start. It lives while point stands where the last move left it: any
;; other move, horizontal or a click, starts the column afresh.
(define (visual--goal buf start pos)
  (let ((g (buffer-local buf 'visual-goal)))
    (if (and g (equal? (car g) pos))
        (cadr g)
        (string-length (buffer-substring start pos)))))

(define (visual--land! buf start end goal)
  (let* ((text (buffer-substring start end))
         (n (min goal (string-length text)))
         (pos (+ start (string-byte-length (substring text 0 n)))))
    (goto-char! pos)
    (buffer-set-local! buf 'visual-goal (list pos goal))
    pos))

;; extending keeps the anchor, or starts a region at point; a plain move
;; clears the mark, as a click does
(define (visual--mark! extend)
  (if extend
      (unless (mark) (set-mark! (point)))
      (set-mark! #f)))

;; An editable surface asks the browser's own layout to move: it knows
;; where every row wraps, so no map is measured or kept for it. A
;; rendered page and a read-only buffer keep the wrap map.
(define (visual--client? buf)
  (and (equal? (buffer-local buf 'visual-line-mode) #t)
       (not (buffer-read-only? buf))
       ;; a client that has reported its caret is there to answer; a
       ;; headless buffer keeps the server's own motion
       (equal? (buffer-local buf 'client-caret) #t)
       ;; a window that measured a map, fresh or stale, draws a page that
       ;; measures; an editable surface never sends one
       (not (window-wrap-map (active-window)))
       ;; only the plain text view is an editable surface; a rendered page,
       ;; a block view, a transcript, and a terminal draw something else
       (not (member (buffer-local buf 'render-mode)
                    '("markdown" "html" "app" "blocks" "terminal")))))

(define (visual--client-move! alter dir granularity &optional count)
  (client-select! alter (if (< dir 0) "backward" "forward") granularity (or count 1))
  #t)

;; one measured row, from wherever point is now
(define (visual--row-step! buf rows dir extend)
  (let* ((pos (point))
         (here (visual-row-bounds rows pos)))
    (and here
         (let* ((start (car here))
                (goal (visual--goal buf start pos))
                (target (if (> dir 0) (cadr here) (visual--row-before rows start))))
           (and target
                (let ((there (visual-row-bounds rows target)))
                  (visual--mark! extend)
                  (visual--land! buf (car there)
                                 (visual-row-end-from (car there) (cadr there))
                                 goal)
                  #t))))))

;; COUNT rows up or down, holding the goal column; one row by default.
;; #f when the map cannot answer: the mode is off, the map is stale, or
;; no measured row lies that way. The caller then moves by source line.
;;
;; COUNT is one call, never a loop of calls. The browser answers a whole
;; page in one request; asking it COUNT times does not work, because a
;; frame keeps ONE pending request and each ask overwrites the last, so a
;; page moved one row.
(define (visual-row-move! dir extend &optional count)
  (let* ((buf (current-buffer))
         (n (max 1 (or count 1)))
         (rows (visual-rows buf)))
    ;; a fresh map answers first (a rendered page measures one; so does a
    ;; test); an editable surface measures none and asks the browser
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "line" n)
        (and rows
             (let loop ((i 0) (moved #f))
               (if (>= i n)
                   moved
                   (if (visual--row-step! buf rows dir extend)
                       (loop (+ i 1) #t)
                       moved)))))))

;; the edge of the row point is on; #f when the map cannot answer
(define (visual-row-edge! dir extend)
  (let* ((buf (current-buffer))
         (rows (visual-rows buf)))
    (if (and (not rows) (visual--client? buf))
        (visual--client-move! (if extend "extend" "move") dir "lineboundary")
    (and rows
         (let ((here (visual-row-bounds rows (point))))
           (and here
                (begin
                  (visual--mark! extend)
                  (goto-char! (if (< dir 0)
                                  (car here)
                                  (visual-row-end-from (car here) (cadr here))))
                  #t)))))))

;; The motions the commands run. Each moves by visual row when the wrap
;; map can answer, and by source line otherwise, so a plain buffer moves
;; as it always did. EXTEND grows the region instead of clearing it.
(define (visual-next-line! &optional extend)
  (or (visual-row-move! 1 extend) (next-line!)))

;; The browser reached the edge of the rendered slice, not of the buffer.
;; Cross that source-line boundary in the buffer; redisplay supplies the
;; next slice, where native wrapped-line motion can continue.
(define (visual-edge-move! dir extend count)
  (visual--mark! extend)
  (repeat-count count (if (< dir 0) previous-line! next-line!))
  (recenter!))

(public! 'visual-edge-move!
  "(visual-edge-move! DIR EXTEND COUNT) — cross a rendered text slice boundary by source lines")
(define (visual-previous-line! &optional extend)
  (or (visual-row-move! -1 extend) (previous-line!)))
(define (visual-beginning-of-line! &optional extend)
  (or (visual-row-edge! -1 extend) (beginning-of-line!)))
(define (visual-end-of-line! &optional extend)
  (or (visual-row-edge! 1 extend) (end-of-line!)))
(public! 'visual-next-line!
  "(visual-next-line! [EXTEND]) — move point one visual row down when the wrap map can say, else one source line")
(public! 'visual-previous-line!
  "(visual-previous-line! [EXTEND]) — move point one visual row up when the wrap map can say, else one source line")
(public! 'visual-beginning-of-line!
  "(visual-beginning-of-line! [EXTEND]) — move point to the start of its visual row when the wrap map can say, else of its line")
(public! 'visual-end-of-line!
  "(visual-end-of-line! [EXTEND]) — move point to the end of its visual row when the wrap map can say, else of its line")

(domain! 'unknown)
(effects! '(unknown))

(domain! 'unknown)
(effects! '(unknown))
