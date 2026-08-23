;;; telemetry.scm --- Scheme execution telemetry.
;;;
;;; Elixir retains a bounded stream of raw scheduler events. This package owns
;;; the policy: row shape, slow-job threshold, filtering, and commands.

(package! 'telemetry)
(domain! 'diagnostics)
(effects! '(read))

(define *telemetry-buffer* "*Scheme Telemetry*")
(define *telemetry-detail-buffer* "*Scheme Telemetry Event*")

(defcustom 'telemetry-event-limit 200
  "The maximum number of Scheme telemetry events shown in the list."
  'group 'telemetry 'type 'number)

(defcustom 'telemetry-slow-ms 250
  "A Scheme job with this duration is slow."
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

(define (telemetry--cells buf row)
  (list
    (list (telemetry--time row) "dim")
    (telemetry--owner row)
    (plist-get row 'label)
    (if (telemetry--slow? row)
        (list (telemetry--duration row) "warn")
        (telemetry--duration row))
    (telemetry--queue row)
    (telemetry--backlog row)))

(define (telemetry--replace-buffer! buf text)
  (buffer-create buf)
  (buffer-set-read-only! buf #f)
  (buffer-delete-range! buf 0 (buffer-size buf))
  (buffer-append! buf text)
  (buffer-set-read-only! buf #t))

(define (telemetry--detail-text row)
  (string-append
    "Scheme Telemetry Event\n\n"
    "Time: " (telemetry--time row) "\n"
    "Kind: " (plist-get row 'kind) "\n"
    "Owner: " (telemetry--owner row) "\n"
    "Job: " (plist-get row 'label) "\n"
    "Duration: " (telemetry--duration row) " ms\n"
    "Queue delay: " (telemetry--queue row) " ms\n"
    "Backlog: " (telemetry--backlog row) "\n"
    "Status: " (plist-get row 'status) "\n"))

(define (telemetry--detail-blocks row)
  (list
    (component 'ui/section (list 'title "Scheme Telemetry Event"))
    (component 'ui/card
      (list 'title (plist-get row 'label) 'open? #t
            'body
            (list
              (component 'ui/kv
                (list 'pairs
                  (list
                    (list "Time" (telemetry--time row))
                    (list "Kind" (plist-get row 'kind))
                    (list "Owner" (telemetry--owner row))
                    (list "Job" (plist-get row 'label))
                    (list "Duration" (string-append (telemetry--duration row) " ms"))
                    (list "Queue delay" (string-append (telemetry--queue row) " ms"))
                    (list "Backlog" (telemetry--backlog row))
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
  "Complete fields for one Scheme telemetry event. `q` closes the window.")

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

(define-command "telemetry-refresh" "Refresh the Scheme telemetry list"
  (lambda () (telemetry-refresh!)))

(effects! '(write))

(define-command "telemetry-clear" "Clear retained Scheme telemetry events"
  (lambda ()
    (telemetry-clear!)
    (telemetry-refresh!)
    (message "Scheme telemetry cleared")))

(effects! '(read))

(mode-icon! "telemetry-mode" "")

(define-list-mode! "telemetry-mode"
  (list
    'doc (string-append
           "Recent Scheme lane jobs and shared tasks. Duration and queue time "
           "use milliseconds. Backlog is the lane mailbox length when the job starts. "
           "RET shows every field; / filters, g refreshes, c clears, and q quits.")
    'buffer *telemetry-buffer*
    'rows (lambda (buf) (telemetry-events))
    'columns (lambda (buf)
               (list (list "time" 8)
                     (list "owner" 18)
                     (list "job" #f)
                     (list "ms" 6 'right)
                     (list "wait" 6 'right)
                     (list "q" 4 'right)))
    'cells telemetry--cells
    'title (lambda (buf) "Scheme Telemetry")
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

(define-command "telemetry" "Show Scheme execution duration, queue time, and backlog"
  (lambda () (list-mode-show! "telemetry-mode")))

(public! 'telemetry-events
  "(telemetry-events [LIMIT]) — return recent Scheme lane and task events, newest first")
(public! 'telemetry-refresh!
  "(telemetry-refresh!) — refresh the Scheme telemetry buffer when it exists")
