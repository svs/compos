;;; recording.scm --- log the visible windows while a recording runs.
;;;
;;; recording-start opens a log file and writes what is visible now.
;;; While the recording runs, every window-configuration change appends
;;; one entry: the active buffer and each window's buffer and rectangle.
;;; The log grows only on change: an arrangement equal to the last entry
;;; writes nothing. Buffer contents are recorded separately (Provenance);
;;; this log holds only the windows, their alignment, and the time.
;;;
;;; The file is JSON lines. A window entry is
;;;   [TIME, ACTIVE-BUFFER, [[BUFFER, X, Y, W, H], ...]]
;;; with fractional rectangles. recording-end appends the end mark
;;;   [TIME, false, []]
;;; and closes the recording.

(domain! 'windows)
(effects! '(write))

(define *recording-path* #f)
(define *recording-lines* '())   ; log lines, newest first
(define *recording-last* #f)     ; the last logged snapshot

;; What is visible: the active buffer, then one row per window with its
;; buffer and rectangle. Window ids stay out of the log — two
;; arrangements that look the same are the same.
(define (recording--snapshot)
  (let ((active (active-window))
        (rects (window-rects)))
    (list
      (let loop ((rows rects))
        (cond ((null? rows) #f)
              ((equal? (car (car rows)) active) (cadr (car rows)))
              (else (loop (cdr rows)))))
      (map cdr rects))))

(define (recording--write!)
  (write-file! *recording-path*
    (string-append (string-join (reverse *recording-lines*) "\n") "\n")))

(define (recording--log! snapshot)
  (set! *recording-last* snapshot)
  (set! *recording-lines*
    (cons (json-encode (cons (current-time) snapshot)) *recording-lines*))
  (recording--write!))

(effects! '(read))
(public! 'recording-active?
  "(recording-active?) — return #t while a window recording runs")
(define (recording-active?)
  (if *recording-path* #t #f))

(public! 'recording-path
  "(recording-path) — the log file of the running recording, or #f")
(define (recording-path) *recording-path*)

(effects! '(write))
(public! 'recording-note!
  "(recording-note!) — log the visible windows if they changed; the window-configuration hook calls this")
(define (recording-note!)
  (when *recording-path*
    (let ((snapshot (recording--snapshot)))
      (unless (equal? snapshot *recording-last*)
        (recording--log! snapshot)))))

(define (recording--configuration-hook!)
    (recording-note!))

(add-hook! 'window-configuration-change-hook 'recording--configuration-hook!)

(public! 'recording-start!
  "(recording-start! [PATH]) — start the window recording and log the current arrangement")
(define (recording-start! &optional path)
  (if *recording-path*
      #f
      (begin
        (set! *recording-path*
          (or path
              (string-append (compos-home) "/recordings/"
                             (number->string (current-time)) ".jsonl")))
        (set! *recording-lines* '())
        (set! *recording-last* #f)
        (recording-note!)
        *recording-path*)))

(public! 'recording-end!
  "(recording-end!) — append the end mark and close the recording; return the log path or #f")
(define (recording-end!)
  (and *recording-path*
       (let ((path *recording-path*))
         (recording--log! (list #f '()))
         (set! *recording-path* #f)
         (set! *recording-lines* '())
         (set! *recording-last* #f)
         path)))

(define-command "recording-start"
  "Start the window recording: log the visible windows on each change"
  (lambda ()
    (let ((path (recording-start!)))
      (if path
          (message (string-append "Recording windows to " path))
          (message (string-append "Recording already runs: "
                                  *recording-path*))))))

(define-command "recording-end"
  "Stop the window recording and name its log file"
  (lambda ()
    (let ((path (recording-end!)))
      (if path
          (message (string-append "Recording saved to " path))
          (message "No recording runs")))))
