;;; recording.scm --- record the editor: a window log and a video.
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
;;;
;;; Beside the log, while the browser is connected and recording-frames
;;; is on, a task captures the editor tab frame by frame into
;;; PATH-frames/, and the end makes PATH.mp4 of them with ffmpeg.
;;; recording-video names the video once it is made.

(domain! 'windows)
(effects! '(write))

(define *recording-path* #f)
(define *recording-lines* '())   ; log lines, newest first
(define *recording-last* #f)     ; the last logged snapshot
(define *recording-t0* #f)       ; monotonic-ms when the recording began
(define *recording-frames* '())  ; (OFFSET-MS FILE), newest first
(define *recording-task* #f)     ; the task taking frames, or #f
(define *recording-video* #f)    ; the video of the last recording

(defgroup 'recording "Recordings of the editor: a window log and the frames of the tab.")

(defcustom 'recording-frames #t
  "Capture the editor tab as frames while a recording runs, and make a video of them at the end. Off, a recording is the window log alone."
  'group 'recording)

(defcustom 'recording-frame-scale 0.5
  "The size of each frame against the tab: 1 is every pixel, 0.5 is half the width and half the height."
  'group 'recording)

(defcustom 'recording-frame-quality 60
  "The JPEG quality of each frame, 1 to 100."
  'group 'recording)

(defcustom 'recording-video-fps 30
  "The frame rate of the video made at the end. Each captured frame is held until the next was taken, so the video keeps the recording's real timing."
  'group 'recording)

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

;;; Frames. While the recording runs, a task takes one frame of the editor
;;; tab after another through the browser: a JPEG, scaled by
;;; recording-frame-scale, stamped with the milliseconds since the start.
;;; There is no timer between frames; the next one starts when the browser
;;; has answered the last, so the pace is what the capture costs. The end
;;; of the recording writes an ffconcat list, one frame per row with the
;;; time until the next, and ffmpeg makes the video beside the log.

(effects! '(write external))

(define (recording--frames-dir path)
  (string-append (if (string-suffix? ".jsonl" path)
                     (substring path 0 (- (string-length path) 6))
                     path)
                 "-frames"))

(define (recording--video-path path)
  (string-append (if (string-suffix? ".jsonl" path)
                     (substring path 0 (- (string-length path) 6))
                     path)
                 ".mp4"))

(define (recording--pad n)
  (let loop ((s (number->string n)))
    (if (< (string-length s) 6) (loop (string-append "0" s)) s)))

;; The clip of the tab in CSS pixels, scaled: the browser wants every
;; field when it clips. #f when the tab does not answer, and then the
;; shot takes the whole tab at full size.
(define (recording--clip)
  (let ((v (app-await
             (lambda (k)
               (browser-call "eval"
                 (list 'tab (chrome--tab-id (dom--editor-tab))
                       'code "innerWidth + 'x' + innerHeight")
                 (lambda (r) (k (and (pair? r) (plist-get r 'value)))))))))
    (and (string? v)
         (let ((parts (string-split v "x")))
           (and (= (length parts) 2)
                (list 'x 0 'y 0
                      'width (string->number (car parts))
                      'height (string->number (cadr parts))
                      'scale recording-frame-scale))))))

;; One frame, as the browser answers it: a reply plist whose result holds
;; the JPEG as base64. The call goes to the browser directly, so K runs
;; even when the browser says no; a refusal ends the frames, it does not
;; hang them.
(define (recording--shot clip k)
  (browser-call "cdp"
    (list 'tab (chrome--tab-id (dom--editor-tab))
          'method "Page.captureScreenshot"
          'params (append (list 'format "jpeg" 'quality recording-frame-quality)
                          (if clip (list 'clip clip) '())))
    k))

(define (recording--frame-data reply)
  (and (pair? reply)
       (let ((result (plist-get reply 'result)))
         (and (pair? result)
              (let ((data (plist-get result 'data)))
                (and (string? data) data))))))

;; Runs in a task. Stops when the recording ends or the browser stops
;; answering with frames.
(define (recording--capture-loop! path dir)
  (let ((clip (recording--clip)))
    (let loop ((n 0))
      (when (equal? *recording-path* path)
        (let ((data (recording--frame-data
                      (app-await (lambda (k) (recording--shot clip k))))))
          (cond ((not (equal? *recording-path* path)) #f)
                (data
                 (let ((file (string-append dir "/" (recording--pad n) ".jpg")))
                   (write-file! file (base64-decode data))
                   (set! *recording-frames*
                     (cons (list (- (monotonic-ms) *recording-t0*) file)
                           *recording-frames*))
                   (loop (+ n 1))))
                (else
                 (message "recording: the browser gave no frame; the frames stop here"))))))))

(define (recording--frames-start! path)
  (set! *recording-task*
    (and recording-frames
         (browser-connected?)
         (let ((dir (recording--frames-dir path)))
           (task-spawn (lambda () (recording--capture-loop! path dir)))))))

(define (recording--seconds ms)
  (number->string (/ ms 1000.0)))

;; The ffconcat list: each frame lasts until the next was taken; the last
;; one lasts as long as the one before it, and stands twice, as the
;; demuxer wants the final duration.
(define (recording--concat-text frames)
  (let loop ((rows frames) (last-ms 100) (acc '()))
    (if (null? rows)
        (string-append "ffconcat version 1.0\n"
                       (string-join (reverse acc) "")
                       (if (pair? frames)
                           (string-append "file '" (cadr (car (reverse frames))) "'\n")
                           ""))
        (let* ((row (car rows))
               (next (if (null? (cdr rows)) #f (car (cdr rows))))
               (ms (if next (- (car next) (car row)) last-ms)))
          (loop (cdr rows)
                (if next ms last-ms)
                (cons (string-append "file '" (cadr row) "'\nduration "
                                     (recording--seconds ms) "\n")
                      acc))))))

(define *recording-encoding* #f)  ; the video ffmpeg is making, or #f

(define (recording--encode! path frames)
  (let ((list-file (string-append (recording--frames-dir path) "/frames.ffconcat"))
        (video (recording--video-path path)))
    (write-file! list-file (recording--concat-text frames))
    (set! *recording-encoding* video)
    (task-run!
      (lambda ()
        (shell-command->string
          (string-append "ffmpeg -v error -y -f concat -safe 0 -i '" list-file
                         "' -vf 'fps=" (number->string recording-video-fps)
                         ",scale=trunc(iw/2)*2:trunc(ih/2)*2' -c:v libx264 -crf 18"
                         " -pix_fmt yuv420p '" video "' 2>&1 && echo RECORDING-OK")
          (recording--frames-dir path)))
      (lambda (ok? out)
        (set! *recording-encoding* #f)
        (if (and ok? (string? out) (string-suffix? "RECORDING-OK\n" out))
            (begin (set! *recording-video* video)
                   (message (string-append "Recording video: " video)))
            (message (string-append "recording: ffmpeg failed: "
                                    (if (string? out) out "no output"))))))))

(effects! '(read))
(public! 'recording-video
  "(recording-video) — the video of the last recording, or #f while none is made yet")
(define (recording-video) *recording-video*)

(public! 'recording-frame-count
  "(recording-frame-count) — how many frames the running recording holds")
(define (recording-frame-count) (length *recording-frames*))

(effects! '(write))

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
        (set! *recording-t0* (monotonic-ms))
        (set! *recording-frames* '())
        (set! *recording-video* #f)
        (recording-note!)
        (recording--frames-start! *recording-path*)
        *recording-path*)))

(public! 'recording-end!
  "(recording-end!) — append the end mark and close the recording; return the log path or #f")
(define (recording-end!)
  (and *recording-path*
       (let ((path *recording-path*)
             (frames (reverse *recording-frames*)))
         (recording--log! (list #f '()))
         (set! *recording-path* #f)
         (set! *recording-lines* '())
         (set! *recording-last* #f)
         (set! *recording-frames* '())
         (set! *recording-task* #f)
         (when (pair? frames) (recording--encode! path frames))
         path)))

;;;###autoload
(define-command "recording-start"
  "Start the recording: log the visible windows on each change and capture the editor as frames"
  (lambda ()
    (let ((path (recording-start!)))
      (if path
          (message (string-append "Recording to " path
                                  (if *recording-task* " with frames" "")))
          (message (string-append "Recording already runs: "
                                  *recording-path*))))))

(define-command "recording-end"
  "Stop the recording and name its log file; the video follows"
  (lambda ()
    (let ((path (recording-end!)))
      (if path
          (message (string-append "Recording saved to " path
                                  (if *recording-encoding* "; the video is being made" "")))
          (message "No recording runs")))))
