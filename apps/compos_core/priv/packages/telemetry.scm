;;; telemetry.scm --- the editor's telemetry, every layer in one list.
;;;
;;; Elixir retains a bounded stream of raw events from three layers: the
;;; Scheme scheduler (lane jobs and tasks), LiveView (the event, the refresh,
;;; the render), and the browser (the round trip of one push, the DOM patch,
;;; the paint, long tasks). One keystroke leaves one row in each layer, and
;;; the rows share a trace id. This package owns the policy: row shape,
;;; slow threshold, filtering, and commands.

(package! 'telemetry)
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

(define (telemetry-events &optional limit)
  (telemetry-snapshot (max 1 (min 1000 (or limit telemetry-event-limit)))))

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

(define (telemetry--replace-buffer! buf text)
  (buffer-create buf)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text)
  (buffer-set-read-only! buf #t))

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
  (buffer-set-local! buf 'transient #t)
  (buffer-set-read-only! buf #t)
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks
    (telemetry--detail-blocks (buffer-local buf 'telemetry-detail-row)))
  (local-set-key* buf "q" "quit-window"))

(mode-icon! "telemetry-detail-mode" "")

(define-mode "telemetry-detail-mode"
  (lambda () (telemetry--detail-setup! (current-buffer))))

(mode-doc! "telemetry-detail-mode"
  "Complete fields for one telemetry event. `q` closes the window.")

(define-command "telemetry-visit" "Show complete details for the event on this row"
  (lambda ()
    (let ((row (list-current (current-buffer))))
      (when row
        (telemetry--replace-buffer! *telemetry-detail-buffer*
          (telemetry--detail-text row))
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
      (number->string count) " events · "
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

(define (telemetry--cause? row)
  (or (not (equal? (telemetry--trace row) ""))
      (and (equal? (telemetry--layer row) "scheme")
           (not (string-contains? (or (plist-get row 'label) "") "telemetry")))))

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
    (list-refresh! *telemetry-buffer*)))

;; the collector's notice (Compos.Core.Telemetry): refresh the list when
;; it shows and a row the user caused arrived since the last draw
(define (telemetry-arrived!)
  (let ((buf *telemetry-buffer*))
    (when (and (buffer-exists? buf) (window-showing buf))
      (let ((newest (telemetry--newest-cause (telemetry-events 50)))
            (seen (or (buffer-local buf 'telemetry-seen) 0)))
        (when (> newest seen)
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
           "and n draw more at the end. RET shows every field; g "
           "refreshes, c clears, and q quits.")
    'buffer *telemetry-buffer*
    'rows (lambda (buf) (telemetry-events))
    'columns (lambda (buf)
               (list (list "time" 8)
                     (list "layer" 7)
                     (list "owner" 14)
                     (list "job" #f)
                     (list "" *telemetry-bar-width*)
                     (list "ms" 6 'right)
                     (list "wait" 5 'right)
                     (list "trace" 9)))
    'cells telemetry--cells
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
                ("/" "filter") ("g" "refresh") ("c" "clear") ("q" "quit")))
    'keys '(("RET" "telemetry-visit")
            ("t" "telemetry-trace")
            ("k" "telemetry-keys")
            ("s" "telemetry-slow")
            ("g" "telemetry-refresh")
            ("c" "telemetry-clear")
            ("q" "quit-window"))))

(define-command "telemetry" "Show the duration of every layer's work: scheme, live, browser"
  (lambda () (list-mode-show! "telemetry-mode")))

;;; --- the popup ---------------------------------------------------------------
;;; The list is a popup with the default geometry, as ibuffer is: a side
;;; window, and the bottom edge on a compact frame. One chord opens it
;;; with current rows and closes it again.

(add-display-rule! "*Telemetry*" 'popup)

(define (telemetry-popup-open?)
  (and (popup-open?) (equal? (popup-buffer) *telemetry-buffer*)))

(define-command "telemetry-toggle" "Show the telemetry popup, or close it"
  (lambda ()
    (if (telemetry-popup-open?)
        (popup-close!)
        (list-mode-show! "telemetry-mode"))))

(catalog-meta! 'command "telemetry-toggle" 'domain 'diagnostics 'effects '(read display))

(global-set-key "C-t" "telemetry-toggle")

(public! 'telemetry-events
  "(telemetry-events [LIMIT]) — return recent events of every layer, newest first")
(public! 'telemetry-refresh!
  "(telemetry-refresh!) — refresh the telemetry buffer when it exists")
(public! 'telemetry-arrived!
  "(telemetry-arrived!) — the collector's notice: redraw the shown list for work the user caused")
(public! 'telemetry-popup-open?
  "(telemetry-popup-open?) — #t while the telemetry popup shows")
