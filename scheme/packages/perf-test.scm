;;; perf-test.scm --- the system monitor's policy.

(domain! 'testing)
(effects! '(read write))

(define (perf-test--buffer)
  (string-append "*perf-test-" (number->string (current-time)) "*"))

(deftest 'perf-lanes-sum-each-lane-in-the-window
  "one row per lane in the window, the lane that waited longest first"
  (lambda ()
    (let* ((ev (lambda (t owner ms q backlog label)
                 (list 'kind "lane" 'time-ms t 'owner owner 'duration-ms ms
                       'queue-ms q 'backlog backlog 'label label)))
           (events (list (ev 100000 ":ui" 10 200 3 "a")
                         (ev 99000 ":ui" 40 50 1 "b")
                         (ev 99500 "{:rpc, #PID<0.1.0>}" 500 0 0 "c")
                         (ev 99600 "{:buffer, \"chat\"}" 5 0 0 "d")
                         (ev 1000 ":ui" 999 999 9 "old")
                         (list 'kind "render" 'time-ms 100000 'duration-ms 70))))
      (check-equal! (perf--lanes events)
                    '(("ui" 2 50 200 250 3 40 "b")
                      ("rpc" 1 500 0 0 0 500 "c")
                      ("chat" 1 5 0 0 0 5 "d"))
                    "the old job and the render are out; wait first, then busy"))))

(deftest 'perf-mode-draws-blocks-and-a-text-table
  "the buffer text is a table, the blocks carry the lanes panel"
  (lambda ()
    (let ((buf (perf-test--buffer)))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "perf-mode")))
      (check-true! (buffer-derived-mode? buf "perf-mode") "the mode is on")
      (check-equal! (buffer-local buf 'render-mode) "blocks" "the buffer renders blocks")
      (check-true! (pair? (buffer-local buf 'render-blocks)) "the blocks exist")
      (check-true! (string-prefix? "*perf*" (buffer-text buf)) "the text starts with the summary")
      (check-true! (member 'render-blocks (buffer-local buf 'desktop-skip-locals))
                   "the blocks are runtime state the desktop skips")
      (buffer-kill! buf))))

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
    (with-stub '*global-mode-string* '()
      (lambda ()
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
        (check-equal! (length (global-mode-string-segments)) 2 "a removed segment is gone")))
    (global-mode-string-refresh!)))

(deftest 'display-memory-mode-owns-one-segment
  "on, the mode keeps a display-memory segment; off, it drops it"
  (lambda ()
    (with-custom 'display-memory-mode #t
      (lambda ()
        (display-memory--tick #f)
        (check-true! (assoc 'display-memory *global-mode-string*) "the segment exists while on")
        (customize-set! 'display-memory-mode #f)
        (display-memory--tick #f)
        (check-equal! (assoc 'display-memory *global-mode-string*) #f "the segment is gone when off")))
    (display-memory--tick #f)))

(deftest 'perf-refresh-writes-through-read-only
  "a refresh rewrites the text of the read-only buffer without a flip: the flag stays on, the sample and the blocks land"
  (lambda ()
    (let ((buf (perf-test--buffer)))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "perf-mode")))
      (let ((tick (or (buffer-local buf 'perf-tick) 0)))
        (perf--refresh! buf)
        (check-equal! (buffer-local buf 'perf-tick) (+ tick 1) "the sample landed")
        (check-true! (pair? (buffer-local buf 'render-blocks)) "the blocks landed")
        (check-true! (string-prefix? "*perf*" (buffer-text buf)) "the text was rewritten")
        (check-true! (buffer-read-only? buf) "the buffer stays read-only through the write"))
      (buffer-kill! buf))))
