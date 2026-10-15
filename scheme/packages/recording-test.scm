;;; recording-test.scm --- the window recording logs changes only.
;;;
;;; recording-start! logs the current arrangement. A window change adds
;;; one entry. A configuration event without a visible change adds
;;; nothing. recording-end! appends the end mark and closes the log.
;;; The tests call the functions and the hook entry point directly; the
;;; editor's asynchronous notification path only re-runs the same
;;; deduplication. Frames stay off: they need the browser, and the video
;;; list they feed ffmpeg is checked as text.

(domain! 'testing)
(effects! '(write))

(define (t--rec-lines path)
  (let ((text (read-file path)))
    (if text
        (filter (lambda (line) (not (equal? line "")))
                (string-split text "\n"))
        '())))

(define (t--without-frames thunk)
  (let ((was recording-frames))
    (set! recording-frames #f)
    (thunk)
    (set! recording-frames was)))

(deftest 'recording-logs-only-on-change
  "the log gains an entry per visible change and ignores repeats"
  (lambda ()
   (t--without-frames (lambda ()
    (let ((path (string-append (compos-home) "/recordings/zz-rec-test.jsonl"))
          (shown (test-buffer! "*zz-rec-shown*" ""))
          (origin (current-buffer)))
      (check-false! (recording-active?) "no recording runs before the test")
      (recording-start! path)
      (check-true! (recording-active?) "the recording is active after start")
      (check-equal! (recording-path) path "the recording names its log file")
      (check-equal! (length (t--rec-lines path)) 1
                    "start logs the current arrangement")
      (recording-note!)
      (check-equal! (length (t--rec-lines path)) 1
                    "an unchanged configuration logs nothing")
      (with-frame-windows (lambda () (switch-to-buffer! shown)))
      (recording-note!)
      (check-equal! (length (t--rec-lines path)) 2
                    "a buffer switch logs one entry")
      (recording-note!)
      (check-equal! (length (t--rec-lines path)) 2
                    "the repeated arrangement logs nothing")
      (with-frame-windows (lambda () (switch-to-buffer! origin)))
      (recording-note!)
      (check-equal! (length (t--rec-lines path)) 3
                    "the switch back logs one entry")
      (let ((end-path (recording-end!)))
        (check-equal! end-path path "end returns the log path")
        (check-false! (recording-active?) "the recording is closed")
        (check-equal! (length (t--rec-lines path)) 4
                      "end appends the end mark")
        (check-true! (string-suffix? "[]]" (car (reverse (t--rec-lines path))))
                     "the end mark closes with an empty window list"))
      (recording-note!)
      (check-equal! (length (t--rec-lines path)) 4
                    "a closed recording logs nothing")
      (check-false! (recording-end!) "a second end returns #f")
      (buffer-kill! shown))))))

(deftest 'recording-start-twice-keeps-the-first
  "a second start does not replace the running recording"
  (lambda ()
   (t--without-frames (lambda ()
    (let ((path (string-append (compos-home) "/recordings/zz-rec-twice.jsonl")))
      (recording-start! path)
      (check-false! (recording-start! "/tmp/zz-rec-other.jsonl")
                    "a second start returns #f")
      (check-equal! (recording-path) path "the first log file stays")
      (recording-end!))))))

(deftest 'recording-concat-holds-each-frame-until-the-next
  "the ffconcat list gives each frame the time until the next, and the last one twice"
  (lambda ()
    (check-equal! (recording--concat-text '())
                  "ffconcat version 1.0\n"
                  "no frames make an empty list")
    (check-equal! (recording--concat-text (list (list 0 "/r/000000.jpg") (list 150 "/r/000001.jpg") (list 400 "/r/000002.jpg")))
                  (string-append "ffconcat version 1.0\n"
                                 "file '/r/000000.jpg'\nduration 0.15\n"
                                 "file '/r/000001.jpg'\nduration 0.25\n"
                                 "file '/r/000002.jpg'\nduration 0.25\n"
                                 "file '/r/000002.jpg'\n")
                  "each frame lasts until the next; the last repeats the gap before it and stands again")
    (check-equal! (recording--frames-dir "/r/12.jsonl") "/r/12-frames" "frames sit beside the log")
    (check-equal! (recording--video-path "/r/12.jsonl") "/r/12.mp4" "the video sits beside the log")
    (check-equal! (recording--pad 7) "000007" "frame names sort as numbers")))
