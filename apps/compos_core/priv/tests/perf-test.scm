;;; perf-test.scm --- the system monitor's policy.

(domain! 'testing)
(effects! '(read write))

(define (perf-test--buffer)
  (string-append "*perf-test-" (number->string (current-time)) "*"))

(deftest 'perf-paths-use-integer-percent-coordinates
  "a series draws ten units per point, y as a percent from the top"
  (lambda ()
    (check-equal! (perf--path-line '(0 50 100)) "M0,100 L10,50 L20,0" "the line path")
    (check-equal! (perf--path-area '(50 50) #f) "M0,50 L10,50 L10,100 L0,100 Z" "an area closes on the floor")
    (check-equal! (perf--path-area '(80 80) '(20 20)) "M0,20 L10,20 L10,80 L0,80 Z" "a stacked area closes on the series below")
    (check-equal! (perf--view-box 7) "0 0 60 100" "the view box is ten units per gap")
    (check-equal! (perf--path-line '()) "" "no points, no path")))

(deftest 'perf-formats-numbers-without-floats
  "bytes and counts read as short strings from integer arithmetic"
  (lambda ()
    (check-equal! (perf--bytes 512) "512 B" "bytes")
    (check-equal! (perf--bytes 2048) "2 KiB" "kibibytes")
    (check-equal! (perf--bytes (* 3 1048576)) "3 MiB" "mebibytes")
    (check-equal! (perf--bytes 1610612736) "1.5 GiB" "gibibytes with one decimal")
    (check-equal! (perf--count 999) "999" "small counts")
    (check-equal! (perf--count 12345) "12.3k" "thousands")
    (check-equal! (perf--count 1234567) "1.2M" "millions")
    (check-equal! (perf--uptime 3723000) "1h 02m" "uptime")))

(deftest 'perf-histogram-bins-render-durations
  "ten bins: nine edges and one for everything past 100 ms"
  (lambda ()
    (check-equal! (perf--histogram '(1 1 3 9 20 200 500))
                  '(2 1 0 1 0 1 0 0 0 2)
                  "each duration lands in one bin")
    (check-equal! (length (perf--histogram '())) 10 "an empty stream still has ten bins")))

(deftest 'perf-heat-keeps-one-cell-per-layer-per-tick
  "a tick records the slowest fresh event of each layer and keeps thirty"
  (lambda ()
    (let* ((events (list (list 'layer "live" 'time-ms 200 'duration-ms 12)
                         (list 'layer "live" 'time-ms 150 'duration-ms 40)
                         (list 'layer "browser" 'time-ms 180 'duration-ms 5)
                         (list 'layer "scheme" 'time-ms 50 'duration-ms 999)))
           (heat (perf--advance-heat '() 100 events)))
      (check-equal! heat '((0) (40) (5)) "old scheme event is out; the slowest live event counts")
      (let loop ((h heat) (i 0))
        (if (< i 40)
            (loop (perf--advance-heat h 1000 '()) (+ i 1))
            (check-equal! (length (car h)) *perf-heat-width* "the row is bounded"))))))

(deftest 'perf-sort-cycles-and-wraps
  "s moves reds -> memory -> queue -> name -> reds"
  (lambda ()
    (check-equal! (perf--sort-next "reds") "memory" "first step")
    (check-equal! (perf--sort-next "name") "reds" "wraps")
    (check-equal! (perf--sort-next "bogus") "reds" "an unknown key starts over")))

(deftest 'perf-mode-draws-blocks-and-a-text-table
  "the buffer text is a table, the blocks carry the same rows, point keeps its line"
  (lambda ()
    (let ((buf (perf-test--buffer)))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "perf-mode")))
      (check-true! (buffer-mode-is? buf "perf-mode") "the mode is on")
      (check-equal! (buffer-local buf 'render-mode) "blocks" "the buffer renders blocks")
      (check-true! (pair? (buffer-local buf 'render-blocks)) "the blocks exist")
      (check-true! (string-prefix? "*perf*" (buffer-text buf)) "the text starts with the summary")
      (check-true! (pair? (buffer-local buf 'perf-rows)) "the table has rows")
      (check-true! (member 'render-blocks (buffer-local buf 'desktop-skip-locals))
                   "the blocks are runtime state the desktop skips")
      (check-true! (member 'perf-series (buffer-local buf 'desktop-skip-locals))
                   "the series are runtime state the desktop skips")
      ;; point on the second row stays on the second row across a refresh
      (with-current-buffer buf
        (lambda () (goto-char! (line-start-position (+ perf--first-row-line 1)))))
      (perf--refresh! buf)
      (check-equal! (car (buffer-line-at-point buf)) (+ perf--first-row-line 1)
                    "a refresh keeps point on its line")
      (let ((row (perf--row-at-point buf)))
        (check-true! (and row (string? (cadr row))) "the row at point names a pid"))
      (buffer-kill! buf))))

(deftest 'perf-filter-narrows-the-table
  "a filter keeps only the processes whose name contains it"
  (lambda ()
    (let ((buf (perf-test--buffer)))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "perf-mode")))
      (buffer-set-local! buf 'perf-filter "Compos.Core.Session")
      (perf--refresh! buf)
      (let ((rows (perf--get (buffer-local buf 'perf-procs) 'rows '())))
        (check-true! (pair? rows) "the session process matches")
        (check-true! (fold (lambda (ok r) (and ok (string-contains? (plist-get r 'name) "Compos.Core.Session")))
                           #t rows)
                     "every row matches the filter"))
      (buffer-set-local! buf 'perf-filter "no-such-process-name-xyz")
      (perf--refresh! buf)
      (check-equal! (perf--get (buffer-local buf 'perf-procs) 'rows '()) '() "nothing matches")
      (check-true! (pair? (buffer-local buf 'render-blocks)) "the empty table still draws")
      (buffer-kill! buf))))

(deftest 'perf-series-grow-and-stay-bounded
  "every sample pushes one point; the charts keep perf-history points"
  (lambda ()
    (let* ((s (list 'sched-util 10 'dirty-cpu-util 1 'dirty-io-util 2
                    'io-in-rate 5 'io-out-rate 6 'schedulers '(10 20) 'dirty-cpu '(3)
                    'os (list 'cpu-util 7)))
           (ser (let loop ((ser '()) (i 0))
                  (if (< i (+ perf-history 5)) (loop (perf--advance ser s) (+ i 1)) ser))))
      (check-equal! (length (perf--get ser 'sched '())) perf-history "the scheduler series is bounded")
      (check-equal! (perf--last (perf--get ser 'host '())) 7 "the host series reads os cpu")
      (check-equal! (length (perf--get ser 'cores '())) 3 "one core series per scheduler, dirty cpu included")
      (check-equal! (length (car (perf--get ser 'cores '()))) *perf-core-width* "a core series is bounded"))))

(deftest 'display-memory-text-expands-every-token
  "the format names the numbers; unknown text stays"
  (lambda ()
    (let ((sample (list 'process-count 42
                        'memory (list 'total 3221225472 'processes 1073741824 'binary 2048 'ets 1024)
                        'os (list 'mem-total 1000 'mem-free 250 'cpu-util 7))))
      (check-equal! (display-memory-text "%t vm · %h host" sample) "3.0 GiB vm · 75% host" "the default format")
      (check-equal! (display-memory-text "%p %b %e %n %c" sample) "1.0 GiB 2 KiB 1 KiB 42 7%" "every token")
      (check-equal! (display-memory-text "plain" sample) "plain" "no token, no change"))))

(deftest 'global-mode-string-composes-segments-by-key
  "a package owns one segment; strings, pairs, and thunks compose; #f removes"
  (lambda ()
    (let ((saved *global-mode-string*))
      (set! *global-mode-string* '())
      (global-mode-string-set! 'test-a "alpha")
      (global-mode-string-set! 'test-b (list "ml-attention" "! beta"))
      (global-mode-string-set! 'test-c (lambda () "gamma"))
      (global-mode-string-set! 'test-d "")
      (check-equal! (global-mode-string-segments)
                    '(("ml-segment" "alpha") ("ml-attention" "! beta") ("ml-segment" "gamma"))
                    "three segments in insertion order, the empty one dropped")
      (global-mode-string-set! 'test-a "alpha 2")
      (check-equal! (car (reverse (global-mode-string-segments))) '("ml-segment" "alpha 2")
                    "a reset segment moves to the end with its new text")
      (global-mode-string-remove! 'test-b)
      (check-equal! (length (global-mode-string-segments)) 2 "a removed segment is gone")
      (set! *global-mode-string* saved)
      (global-mode-string-refresh!))))

(deftest 'display-memory-mode-owns-one-segment
  "on, the mode keeps a display-memory segment; off, it drops it"
  (lambda ()
    (let ((was display-memory-mode))
      (customize-set! 'display-memory-mode #t)
      (display-memory--tick #f)
      (check-true! (assoc 'display-memory *global-mode-string*) "the segment exists while on")
      (customize-set! 'display-memory-mode #f)
      (display-memory--tick #f)
      (check-equal! (assoc 'display-memory *global-mode-string*) #f "the segment is gone when off")
      (customize-set! 'display-memory-mode was)
      (display-memory--tick #f))))
