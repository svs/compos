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

(define (telemetry--cells buf row)
  (list
    (list (telemetry--time row) "dim")
    (telemetry--layer row)
    (telemetry--owner row)
    (telemetry--job row)
    (if (telemetry--slow? row)
        (list (telemetry--duration row) "warn")
        (telemetry--duration row))
    (telemetry--queue row)
    (telemetry--backlog row)
    (list (telemetry--trace row) "dim")))

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

(define (telemetry--sum rows key)
  (fold (lambda (n row) (+ n (plist-get row key))) 0 rows))

(define (telemetry--meta buf)
  (let* ((rows (list-entries buf))
         (count (length rows))
         (slow (length (filter telemetry--slow? rows)))
         (avg (if (= count 0) 0 (quotient (telemetry--sum rows 'duration-ms) count))))
    (string-append
      (number->string count) " events · "
      (number->string slow) " slow · "
      (number->string avg) "ms average")))

(define (telemetry-refresh!)
  (when (buffer-exists? *telemetry-buffer*)
    (list-refresh! *telemetry-buffer*)))

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
           "Milliseconds throughout. Wait is the queue time of a job, the "
           "server round trip of a push, or the input delay of a paint. "
           "Backlog is the lane mailbox length when the job starts. The rows "
           "of one keystroke share a trace id: / with the id shows the "
           "keystroke end to end. RET shows every field; g refreshes, c "
           "clears, and q quits.")
    'buffer *telemetry-buffer*
    'rows (lambda (buf) (telemetry-events))
    'columns (lambda (buf)
               (list (list "time" 8)
                     (list "layer" 7)
                     (list "owner" 16)
                     (list "job" #f)
                     (list "ms" 6 'right)
                     (list "wait" 6 'right)
                     (list "q" 4 'right)
                     (list "trace" 9)))
    'cells telemetry--cells
    'title (lambda (buf) "Telemetry")
    'meta telemetry--meta
    'total (lambda (buf) (length (telemetry-events)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "details") ("/" "filter") ("g" "refresh")
                ("c" "clear") ("q" "quit")))
    'keys '(("RET" "telemetry-visit")
            ("g" "telemetry-refresh")
            ("c" "telemetry-clear")
            ("q" "quit-window"))))

(define-command "telemetry" "Show the duration of every layer's work: scheme, live, browser"
  (lambda () (list-mode-show! "telemetry-mode")))

(public! 'telemetry-events
  "(telemetry-events [LIMIT]) — return recent events of every layer, newest first")
(public! 'telemetry-refresh!
  "(telemetry-refresh!) — refresh the telemetry buffer when it exists")
