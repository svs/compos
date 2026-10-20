;;; telemetry.scm --- the editor's telemetry, every layer in one list.
;;;
;;; Elixir retains a bounded stream of raw events from three layers: the
;;; Scheme scheduler (lane jobs and tasks), LiveView (the event, the refresh,
;;; the render), and the browser (the round trip of one push, the DOM patch,
;;; the paint, long tasks). One keystroke leaves one row in each layer, and
;;; the rows share a trace id. This package owns the policy: row shape,
;;; slow threshold, filtering, and commands.

(domain! 'diagnostics)
(effects! '(read))

(define *telemetry-buffer* "*Telemetry*")
(define *telemetry-detail-buffer* "*Telemetry Event*")

(defcustom 'telemetry-event-limit 400
  "The maximum number of telemetry events shown in the list."
  'group 'telemetry 'type 'number)

(defcustom 'telemetry-slow-ms 250
  "An event with this duration is slow."
  'group 'telemetry 'type 'number)

(defcustom 'telemetry-draw-ms 2000
  "The shortest gap between two redraws of a shown *Telemetry*. Every redraw is one patch to the browser."
  'group 'telemetry 'type 'number)

(define (telemetry-events &optional limit)
  (telemetry-snapshot (max 1 (min 1000 (or limit telemetry-event-limit)))))

;; The editor's own reaction to a change: a live refresh and a render
;; with no trace. Every buffer change makes one pair, so they are most
;; of the stream, and they say nothing a traced row does not. The list
;; hides them unless you ask for all.
(define (telemetry--noise? row)
  (and (equal? (telemetry--layer row) "live")
       (equal? (telemetry--trace row) "")
       (let ((l (or (plist-get row 'label) "")))
         (or (string-prefix? "refresh" l) (string-prefix? "render" l)))))

(define (telemetry--rows buf)
  (let ((rows (telemetry-events)))
    (if (buffer-local buf 'telemetry-all)
        rows
        (filter (lambda (r) (not (telemetry--noise? r))) rows))))

(define (telemetry--time row)
  (format-time (quotient (plist-get row 'time-ms) 1000) "%H:%M:%S"))

(define (telemetry--duration row)
  (number->string (plist-get row 'duration-ms)))

(define (telemetry--queue row)
  (number->string (plist-get row 'queue-ms)))

(define (telemetry--backlog row)
  (number->string (plist-get row 'backlog)))

(define (telemetry--slow? row)
  (>= (plist-get row 'duration-ms) telemetry-slow-ms))

(define (telemetry--owner row)
  (if (equal? (plist-get row 'kind) "task")
      (string-append "task " (plist-get row 'owner))
      (plist-get row 'owner)))

(define (telemetry--layer row) (or (plist-get row 'layer) "scheme"))

(define (telemetry--trace row) (or (plist-get row 'tid) ""))

(define (telemetry--detail row) (or (plist-get row 'detail) ""))

;; the job cell: the label, then the detail the layer added
(define (telemetry--job row)
  (let ((d (telemetry--detail row)))
    (if (equal? d "")
        (plist-get row 'label)
        (string-append (plist-get row 'label) "  " d))))

;;; --- the look ---------------------------------------------------------------
;;; A layer wears one colour in every row. A duration is a bar beside its
;;; number, on one scale: a full bar is the slow threshold. The meta line
;;; carries a sparkline of the newest keystrokes, the oldest on the left.

(defface! 'telemetry-scheme 'fg "#26356b" 'weight "600")
(defface! 'telemetry-live 'fg "#2e6b45" 'weight "600")
(defface! 'telemetry-browser 'fg "#7a5a1a" 'weight "600")
(defface! 'telemetry-bar 'fg "#8a857a")

(define (telemetry--layer-face layer)
  (cond ((equal? layer "live") "telemetry-live")
        ((equal? layer "browser") "telemetry-browser")
        (else "telemetry-scheme")))

(define *telemetry-blocks* '("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█"))
(define *telemetry-bar-width* 6)
(define *telemetry-spark-keys* 24)

;; the duration as a number: the collector rounds every layer to a whole
;; millisecond, and a row without one counts as zero
(define (telemetry--ms row)
  (or (plist-get row 'duration-ms) 0))

;; one block per value; the tallest block is the largest value
(define (telemetry--sparkline values)
  (let ((top (fold (lambda (acc v) (max acc v)) 0 values)))
    (apply string-append
      (map (lambda (v)
             (nth (if (= top 0) 0 (min 7 (quotient (* 7 v) top)))
                  *telemetry-blocks*))
           values))))

;; the bar of one duration: WIDTH * ms / slow, rounded up, at most WIDTH
(define (telemetry--bar ms)
  (let* ((slow (max 1 telemetry-slow-ms))
         (n (min *telemetry-bar-width*
                 (quotient (+ (* *telemetry-bar-width* ms) (- slow 1)) slow))))
    (string-repeat "▇" n)))

;; the value under which P percent of SORTED falls; SORTED ascends
(define (telemetry--percentile sorted p)
  (if (null? sorted)
      0
      (nth (min (- (length sorted) 1) (quotient (* p (length sorted)) 100))
           sorted)))

;; the browser's row for one keystroke: the round trip of the push
(define (telemetry--key-row? row)
  (and (equal? (telemetry--layer row) "browser")
       (string-prefix? "key " (or (plist-get row 'label) ""))))

;; the newest N keystroke rows, oldest first: ROWS arrive newest first
(define (telemetry--newest-keys rows n)
  (let loop ((rs rows) (k n) (acc '()))
    (cond ((or (null? rs) (= k 0)) acc)
          ((telemetry--key-row? (car rs))
           (loop (cdr rs) (- k 1) (cons (car rs) acc)))
          (else (loop (cdr rs) k acc)))))

(define (telemetry--cells buf row)
  (let ((layer (telemetry--layer row))
        (slow? (telemetry--slow? row)))
    (list
      (list (telemetry--time row) "dim")
      (list layer (telemetry--layer-face layer))
      (telemetry--owner row)
      (telemetry--job row)
      (list (telemetry--bar (telemetry--ms row)) (if slow? "warn" "telemetry-bar"))
      (if slow?
          (list (telemetry--duration row) "warn")
          (telemetry--duration row))
      (telemetry--queue row)
      (list (telemetry--trace row) "dim"))))

;; Two views. A side window is narrow: it shows the time, the layer, the
;; job, the bar, and the number. The owner, the wait, and the trace stay
;; in the wide view and in RET's details; t still narrows to the trace.
(define telemetry-narrow-cols 100)

(define (telemetry--wide-columns buf)
  (list (list "time" 8)
        (list "layer" 7)
        (list "owner" 14)
        (list "job" #f)
        (list "" *telemetry-bar-width*)
        (list "ms" 6 'right)
        (list "wait" 5 'right)
        (list "trace" 9)))

(define (telemetry--narrow-columns buf)
  (list (list "time" 8)
        (list "layer" 7)
        (list "job" #f)
        (list "" *telemetry-bar-width*)
        (list "ms" 6 'right)))

(define (telemetry--narrow-cells buf row)
  (let ((cells (telemetry--cells buf row)))
    (list (nth 0 cells) (nth 1 cells) (nth 3 cells) (nth 4 cells) (nth 5 cells))))

(define (telemetry--detail-text row)
  (string-append
    "Telemetry Event\n\n"
    "Time: " (telemetry--time row) "\n"
    "Layer: " (telemetry--layer row) "\n"
    "Kind: " (plist-get row 'kind) "\n"
    "Owner: " (telemetry--owner row) "\n"
    "Job: " (plist-get row 'label) "\n"
    "Detail: " (telemetry--detail row) "\n"
    "Duration: " (telemetry--duration row) " ms\n"
    "Wait: " (telemetry--queue row) " ms\n"
    "Backlog: " (telemetry--backlog row) "\n"
    "Trace: " (telemetry--trace row) "\n"
    "Status: " (plist-get row 'status) "\n"))

(define (telemetry--detail-blocks row)
  (list
    (component 'ui/section (list 'title "Telemetry Event"))
    (component 'ui/card
      (list 'title (plist-get row 'label) 'open? #t
            'body
            (list
              (component 'ui/kv
                (list 'pairs
                  (list
                    (list "Time" (telemetry--time row))
                    (list "Layer" (telemetry--layer row))
                    (list "Kind" (plist-get row 'kind))
                    (list "Owner" (telemetry--owner row))
                    (list "Job" (plist-get row 'label))
                    (list "Detail" (telemetry--detail row))
                    (list "Duration" (string-append (telemetry--duration row) " ms"))
                    (list "Wait" (string-append (telemetry--queue row) " ms"))
                    (list "Backlog" (telemetry--backlog row))
                    (list "Trace" (telemetry--trace row))
                    (list "Status" (plist-get row 'status))))))))))

(define (telemetry--detail-setup! buf)
  (desktop-skip! buf 'render-blocks)
  (desktop-skip! buf 'telemetry-detail-row)
  (buffer-set-read-only! buf #t)
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks
    (telemetry--detail-blocks (buffer-local buf 'telemetry-detail-row)))
  )

(mode-icon! "telemetry-detail-mode" "")

(define-mode "telemetry-detail-mode"
  (lambda () (telemetry--detail-setup! (current-buffer))))

(mode-keys! "telemetry-detail-mode"
  '(
    ("q" "quit-window")))

(mode-doc! "telemetry-detail-mode"
  "Complete fields for one telemetry event. `q` closes the window.")

(define-command "telemetry-visit" "Show complete details for the event on this row"
  (lambda ()
    (let ((row (list-current (current-buffer))))
      (when row
        (buffer-set-text! *telemetry-detail-buffer*
          (telemetry--detail-text row) #t)
        (buffer-set-local! *telemetry-detail-buffer* 'telemetry-detail-row row)
        (display-buffer-other-window! *telemetry-detail-buffer*)
        (with-current-buffer *telemetry-detail-buffer*
          (lambda () (set-mode! "telemetry-detail-mode")))))))

(define (telemetry--meta buf)
  (let* ((rows (list-entries buf))
         (count (length rows))
         (slow (length (filter telemetry--slow? rows)))
         (sorted (sort (map telemetry--ms rows)))
         (keys (telemetry--newest-keys rows *telemetry-spark-keys*))
         (last (if (null? keys) #f (car (reverse keys)))))
    (string-append
      (number->string count) (if (buffer-local buf 'telemetry-all) " events · " " events, quiet · ")
      (number->string slow) " slow · "
      "p50 " (number->string (telemetry--percentile sorted 50)) "ms · "
      "p95 " (number->string (telemetry--percentile sorted 95)) "ms"
      (if last
          (string-append
            "   keys " (telemetry--sparkline (map telemetry--ms keys))
            "  " (plist-get last 'label) " " (telemetry--duration last) "ms")
          ""))))

;;; --- narrowing ---------------------------------------------------------------
;;; The mode's own filters ride the list's stack beside `/`: one trace is a
;;; keystroke end to end, `keys` is every traced row, `slow` is the rows
;;; over the threshold. The same key again widens.

(define (telemetry--filter buf row f)
  (let ((kind (car f)))
    (cond ((equal? kind "trace") (equal? (telemetry--trace row) (cadr f)))
          ((equal? kind "keys") (not (equal? (telemetry--trace row) "")))
          ((equal? kind "slow") (telemetry--slow? row))
          (else #t))))

(define (telemetry--toggle-filter! buf kind value)
  (let ((fs (list-filters buf)))
    (if (and (pair? fs) (equal? (car (car fs)) kind))
        (list-filter-pop! buf)
        (list-filter-push! buf (list kind value)))))

(define-command "telemetry-trace" "Narrow to the keystroke under point, end to end"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (list-current buf))
           (tid (if row (telemetry--trace row) "")))
      (if (equal? tid "")
          (message "This row has no trace")
          (telemetry--toggle-filter! buf "trace" tid)))))

(define-command "telemetry-keys" "Keep the traced rows: keystrokes and intents"
  (lambda () (telemetry--toggle-filter! (current-buffer) "keys" "traced")))

(define-command "telemetry-all" "Show the editor's own refresh and render rows too; again hides them"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'telemetry-all (not (buffer-local buf 'telemetry-all)))
      (list-refresh! buf))))

(define-command "telemetry-slow" "Keep the rows over the slow threshold"
  (lambda ()
    (telemetry--toggle-filter! (current-buffer) "slow"
      (string-append ">=" (number->string telemetry-slow-ms) "ms"))))

;;; --- following the work ------------------------------------------------------
;;; The collector says when rows arrive, once a second at most. The list
;;; follows only the work the user causes: a keystroke or an intent (a
;;; traced row) and a Scheme job. Its own refresh leaves live rows, browser
;;; rows, and a lane job named after this package; those never refresh it,
;;; so a quiet editor draws nothing.

;; the rows a redraw makes by itself: the buffer write lands as an
;; "apply" on the owning lane and the coalescing timer as a "debounce",
;; and every row the telemetry code itself asks for names it. None of
;; them is a reason to draw again — counting them fed the list its own
;; output, and it redrew for as long as it was open.
(define (telemetry--plumbing? row)
  (let ((label (or (plist-get row 'label) ""))
        (owner (or (telemetry--owner row) "")))
    (or (equal? label "apply")
        (equal? label "debounce")
        (string-contains? label "telemetry")
        (string-contains? owner *telemetry-buffer*))))

(define (telemetry--cause? row)
  (or (not (equal? (telemetry--trace row) ""))
      (and (equal? (telemetry--layer row) "scheme")
           (not (telemetry--plumbing? row)))))

;; the time of the newest row the user caused; ROWS arrive newest first
(define (telemetry--newest-cause rows)
  (let loop ((rs rows))
    (cond ((null? rs) 0)
          ((telemetry--cause? (car rs)) (or (plist-get (car rs) 'time-ms) 0))
          (else (loop (cdr rs))))))

(define (telemetry--mark-seen! buf)
  (buffer-set-local! buf 'telemetry-seen
    (telemetry--newest-cause (telemetry-events 50))))

(define (telemetry-refresh!)
  (when (buffer-exists? *telemetry-buffer*)
    (telemetry--mark-seen! *telemetry-buffer*)
    ;; the newest row is the first row, so a reader who has not moved off
    ;; it stays on it. Tracking the row under point instead walked the
    ;; point down one row per arriving event until the window sat at the
    ;; end of the list and scrolled there on every draw.
    (let ((head? (equal? 0 (list-index *telemetry-buffer*))))
      (list-refresh! *telemetry-buffer*)
      (when head? (list-goto-index! *telemetry-buffer* 0)))))

;; the collector's notice (Compos.Core.Telemetry), once a second. The
;; list draws when it shows and rows the user caused have arrived since
;; the last draw — and no sooner than telemetry-draw-ms after it, so a
;; busy editor costs one patch per interval instead of one per second.
(define (telemetry-arrived!)
  (let ((buf *telemetry-buffer*))
    (when (and (buffer-exists? buf) (window-showing buf))
      (let ((newest (telemetry--newest-cause (telemetry-events 50)))
            (seen (or (buffer-local buf 'telemetry-seen) 0)))
        (when (> newest (+ seen telemetry-draw-ms))
          (telemetry-refresh!))))))

(define-command "telemetry-refresh" "Refresh the telemetry list"
  (lambda () (telemetry-refresh!)))

(effects! '(write))

(define-command "telemetry-clear" "Clear retained telemetry events"
  (lambda ()
    (telemetry-clear!)
    (telemetry-refresh!)
    (message "Telemetry cleared")))

(effects! '(read))

(mode-icon! "telemetry-mode" "")

(define-list-mode! "telemetry-mode"
  (list
    'doc (string-append
           "Recent events of every layer: scheme (lane jobs, tasks), live "
           "(the LiveView event, the refresh, the render), and browser (the "
           "round trip of one push, the DOM patch, the paint, long tasks). "
           "Milliseconds throughout. The bar is the duration against the "
           "slow threshold. Wait is the queue time of a job, the server "
           "round trip of a push, or the input delay of a paint. The rows "
           "of one keystroke share a trace id: t narrows to the trace "
           "under point, k keeps every traced row, s keeps the slow rows, "
           "and the same key again widens. The list draws 60 rows; PgDn "
           "and n draw more at the end. The editor's own untraced refresh "
           "and render rows are hidden; a shows them. RET shows every "
           "field; g refreshes, c clears, and q quits.")
    'buffer *telemetry-buffer*
    'rows telemetry--rows
    'columns telemetry--wide-columns
    'cells telemetry--cells
    'layouts (list (list 'name 'narrow
                         'max-cols (- telemetry-narrow-cols 1)
                         'columns telemetry--narrow-columns
                         'cells telemetry--narrow-cells)
                   (list 'name 'wide 'default #t))
    'title (lambda (buf) "Telemetry")
    'meta telemetry--meta
    'total (lambda (buf) (length (telemetry-events)))
    'no-marks #t
    'local-filter #t
    'filter telemetry--filter
    ;; the newest rows first; the reader who wants older ones pages down
    'page-size 60
    'footer (lambda (buf)
              '(("RET" "details") ("t" "trace") ("k" "keys") ("s" "slow")
                ("a" "all") ("/" "filter") ("g" "refresh") ("c" "clear") ("q" "quit")))
    'keys '(("RET" "telemetry-visit")
            ("t" "telemetry-trace")
            ("k" "telemetry-keys")
            ("s" "telemetry-slow")
            ("a" "telemetry-all")
            ("g" "telemetry-refresh")
            ("c" "telemetry-clear")
            ("q" "quit-window"))))

(define-command "telemetry" "Show the duration of every layer's work: scheme, live, browser"
  (lambda () (list-mode-show! "telemetry-mode")))

;; --- chat-perf ---------------------------------------------------------------
;; One chat's last turn, step by step. Elixir stamps a row for every stage
;; and every step: the context build, the record, the stream handshake, the
;; model request of each round, and each tool call. The stamps land in the
;; same collector as M-x telemetry.
;;
;; The collector keeps the end time and the duration of each row, so a row
;; knows when it started. That is enough to place every step on one time
;; line: the bar column is a flame graph, drawn in text like the bar in
;; M-x telemetry.

(define *chat-perf-buffer* "*chat-perf*")
(define *chat-perf-flame-width* 44)

(define (chat-perf--slug buf)
  (or (buffer-local buf 'agent-slug) ""))

(define (chat-perf--ms row)
  (let ((n (plist-get row 'duration-ms)))
    (if (number? n) n 0)))

(define (chat-perf--end row)
  (let ((n (plist-get row 'time-ms)))
    (if (number? n) n 0)))

(define (chat-perf--start row)
  (- (chat-perf--end row) (chat-perf--ms row)))

(define (chat-perf--step row) (or (plist-get row 'label) ""))

;; Every turn opens with one "context" stamp, so the last one starts the
;; last turn. Without this cut the list spans every turn the ring still
;; holds, and the flame graph measures a window nobody waited through.
(define (chat-perf--last-turn rows)
  (let loop ((rs rows) (seen '()))
    (cond ((null? rs) (reverse seen))
          ((equal? (chat-perf--step (car rs)) "context")
           (loop (cdr rs) (list (car rs))))
          (else (loop (cdr rs) (cons (car rs) seen))))))

(define (chat-perf--window rows)
  (if (null? rows)
      (list 0 1)
      (let loop ((rs rows) (lo (chat-perf--start (car rows))) (hi (chat-perf--end (car rows))))
        (if (null? rs)
            (list lo (max hi (+ lo 1)))
            (loop (cdr rs)
                  (min lo (chat-perf--start (car rs)))
                  (max hi (chat-perf--end (car rs))))))))

;; the column of one instant, inside the drawn width
;; The HTTP stack does not know which chat it carries, so its rows name no
;; slug. They belong to the turn they ran inside, and the flame graph places
;; every row by time, so the window decides: an http row between the first
;; start and the last end of the turn is part of that turn.
(define (chat-perf--http-rows lo hi events)
  (filter (lambda (row)
            (and (equal? (plist-get row 'layer) "http")
                 (>= (chat-perf--start row) lo)
                 (<= (chat-perf--start row) hi)))
          events))

;; ascending by start; term order compares the head of each pair first
(define (chat-perf--by-start rows)
  (map cadr (sort (map (lambda (r) (list (chat-perf--start r) r)) rows))))

;; The collector answers newest first. A turn reads in the order it ran.
(define (chat-perf--rows slug)
  (if (equal? slug "")
      '()
      (let* ((events (telemetry-events 1000))
             (mine (chat-perf--last-turn
                     (reverse
                       (filter (lambda (row)
                                 (and (equal? (plist-get row 'layer) "chat")
                                      (equal? (plist-get row 'owner) slug)))
                               events)))))
        (if (null? mine)
            '()
            (let* ((win (chat-perf--window mine))
                   (http (chat-perf--http-rows (car win) (cadr win) events)))
              (chat-perf--by-start (append mine http)))))))

;; The collector is a ring that rolls over in about two minutes, so a
;; redraw after the turn finds nothing. Keep the last steps we saw.
(define (chat-perf--keep! buf)
  (let ((rows (chat-perf--rows (or (buffer-local buf 'chat-perf-slug) ""))))
    (if (null? rows)
        (or (buffer-local buf 'chat-perf-kept) '())
        (begin (buffer-set-local! buf 'chat-perf-kept rows) rows))))

;; A tool runs inside the round that called it, so it reads one level in.
;; "first thought" and "first token" measure from the send, so they span
;; every step above them and stay at the margin.
(define (chat-perf--depth row)
  (if (or (string-prefix? "tool " (chat-perf--step row))
          (string-prefix? "http " (chat-perf--step row)))
      1
      0))

(define (chat-perf--label row)
  (string-append (string-repeat "  " (chat-perf--depth row))
                 (chat-perf--step row)))

;;; --- the flame graph ----------------------------------------------------------
;;; Every step is one bar, placed by when it started and how long it ran.
;;; The window is the first start to the last end, so the bars line up
;;; under each other and a gap in the row is a gap in the turn.

(define (chat-perf--col at lo span)
  (max 0 (min (- *chat-perf-flame-width* 1)
              (quotient (* *chat-perf-flame-width* (- at lo)) span))))

(define (chat-perf--flame row lo span)
  (let* ((a (chat-perf--col (chat-perf--start row) lo span))
         (b (chat-perf--col (chat-perf--end row) lo span))
         ;; a step too short to fill a column still gets one, or it
         ;; disappears from a graph that is meant to show every step
         (wide (max 1 (- b a))))
    (string-append (string-repeat " " a)
                   (string-repeat "█" wide))))

;; A narrow window cannot hold the flame and the detail both. The flame is
;; the reason to open this list, so the detail goes first.
(define (chat-perf--narrow-columns buf)
  (list (list "step" 22)
        (list "ms" 7 'right)
        (list "flame" *chat-perf-flame-width*)))

(define (chat-perf--narrow-cells buf row)
  (let ((cs (chat-perf--cells buf row)))
    (list (car cs) (cadr cs) (caddr cs))))

(define (chat-perf--cells buf row)
  (let* ((rows (chat-perf--keep! buf))
         (win (chat-perf--window rows))
         (lo (car win))
         (span (max 1 (- (cadr win) lo))))
    (list (chat-perf--label row)
          (number->string (chat-perf--ms row))
          (chat-perf--flame row lo span)
          (or (plist-get row 'detail) ""))))

;; the chat this list was opened from, by name; the slug is the fallback
;; for a list restored from a desktop that lost the buffer
(define (chat-perf--name buf)
  (let ((chat (buffer-local buf 'chat-perf-chat)))
    (if (and chat (buffer-exists? chat))
        chat
        (or (buffer-local buf 'chat-perf-slug) "no chat"))))

(define (chat-perf--meta buf)
  (let* ((slug (or (buffer-local buf 'chat-perf-slug) ""))
         (drawn (list-entries buf))
         (rows (if (null? drawn) (chat-perf--keep! buf) drawn))
         (win (chat-perf--window rows))
         (wall (- (cadr win) (car win)))
         (busy (let loop ((rs rows) (n 0))
                 (if (null? rs) n (loop (cdr rs) (+ n (chat-perf--ms (car rs))))))))
    (string-append slug " · "
                   (number->string (length rows)) " steps · "
                   (number->string wall) " ms wall · "
                   (number->string busy) " ms summed")))

(domain! 'diagnostics)
(effects! '(read))
(define-list-mode! "chat-perf-mode"
  (list
    'doc (string-append
           "One chat's last turn, step by step. Each row is a step the "
           "editor stamped: context is Scheme building the prompt, record "
           "writes the user turn, and round N model is that round's model "
           "request. http open is the stream setup only: it starts a lazy "
           "stream and does not touch the network. http queue, http "
           "connect and http send are the HTTP stack under that round, and "
           "a tool row is one tool call. first thought and "
           "first token measure from the send, so they cover every step "
           "above them. The bar column is a flame graph: each step sits "
           "where it ran between the first start and the last end, so a "
           "gap in the column is a gap in the turn. g redraws; q quits.")
    'buffer *chat-perf-buffer*
    'rows (lambda (buf) (chat-perf--keep! buf))
    'id (lambda (row) (string-append (chat-perf--step row) "@"
                                     (number->string (chat-perf--end row))))
    'columns (lambda (buf)
               (list (list "step" 22)
                     (list "ms" 7 'right)
                     (list "flame" *chat-perf-flame-width*)
                     (list "detail" #f)))
    'cells chat-perf--cells
    'layouts (list (list 'name 'narrow
                         'max-cols 99
                         'columns chat-perf--narrow-columns
                         'cells chat-perf--narrow-cells)
                   (list 'name 'wide 'default #t))
    'title (lambda (buf)
             (string-append "Chat perf: " (chat-perf--name buf)))
    'no-marks #t
    'meta chat-perf--meta
    'footer (lambda (buf) '(("g" "refresh") ("q" "quit")))
    'keys '(("g" "list-revert")
            ("q" "quit-window"))))

(domain! 'diagnostics)
(effects! '(read display))
(define-command "chat-perf" "Show every step of this chat's last turn, with a flame graph"
  (lambda ()
    (let* ((chat (current-buffer))
           (slug (chat-perf--slug chat)))
      (if (equal? slug "")
          (if (buffer-local chat 'agent-saved-mark)
              ;; a chat whose runtime died (a restart, a module swap) keeps
              ;; its conversation but stamps nothing until it runs again
              (message "this chat has no live runtime — send once, then M-x chat-perf")
              (message "not a chat"))
          (begin
            (buffer-create *chat-perf-buffer*)
            ;; the kept steps belong to the chat they came from. Opening
            ;; this list on another chat must not show the last one's turn.
            (unless (equal? (buffer-local *chat-perf-buffer* 'chat-perf-slug) slug)
              (buffer-set-local! *chat-perf-buffer* 'chat-perf-kept '()))
            (buffer-set-local! *chat-perf-buffer* 'chat-perf-slug slug)
            ;; the reader knows the chat by its name, not by its slug
            (buffer-set-local! *chat-perf-buffer* 'chat-perf-chat chat)
            (list-mode-show! "chat-perf-mode")
            (list-redraw! *chat-perf-buffer*))))))

;;; --- the toggle ---------------------------------------------------------------
;;; One chord opens the list with current rows and closes it again. The
;;; list takes the display chain like any listing, and the close undoes
;;; that display: the window it made goes, or the buffer it covered
;;; comes back.

(define (telemetry-shown?)
  (and (window-showing *telemetry-buffer*) #t))

(define-command "telemetry-toggle" "Show the telemetry list, or take it away"
  (lambda ()
    (let ((w (window-showing *telemetry-buffer*)))
      (cond ((not w) (list-mode-show! "telemetry-mode"))
            ((window-quit-restore! w) #t)
            ((pair? (cdr (window-list))) (delete-window-id! w))
            (else (message "The telemetry list is the last window"))))))

(catalog-meta! 'command "telemetry-toggle" 'domain 'diagnostics 'effects '(read display))

(global-set-key "C-t" "telemetry-toggle")

(public! 'telemetry-events
  "(telemetry-events [LIMIT]) — return recent events of every layer, newest first")
(public! 'telemetry-refresh!
  "(telemetry-refresh!) — refresh the telemetry buffer when it exists")
(public! 'telemetry-arrived!
  "(telemetry-arrived!) — the collector's notice: redraw the shown list for work the user caused")
(public! 'telemetry-shown?
  "(telemetry-shown?) — #t while a window shows the telemetry list")

;;; --- one keystroke, phase by phase --------------------------------------------
;;; The dispatch mechanism records a row per phase: the key, the resolved
;;; command, the pre-command policy, and the state after the command. The
;;; rows show which phase moved point. This fn adds the derived
;;; input-start, so a point outside a chat's input region is visible in
;;; the row itself.

(effects! '(write))

(define (trace-key keys)
  (map (lambda (row)
         (let ((mark (plist-get row 'mark))
               (mb (plist-get row 'marker-bytes)))
           (if (and (number? mark) (number? mb))
               (append row (list 'input-start (+ mark mb)))
               row)))
       (trace-key! (if (string? keys) (list keys) keys))))

(public! 'trace-key
  "(trace-key KEYS) — dispatch KEYS; return a state row per phase: point, size, mark, input-start")
