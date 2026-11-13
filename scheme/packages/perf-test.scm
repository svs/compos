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
      (check-equal! (buffer-local-value 'render-mode buf) "blocks" "the buffer renders blocks")
      (check-true! (pair? (buffer-local-value 'render-blocks buf)) "the blocks exist")
      (check-true! (string-prefix? "*perf*" (buffer-text buf)) "the text starts with the summary")
      (check-true! (member 'render-blocks (buffer-local-value 'desktop-skip-locals buf))
                   "the blocks are runtime state the desktop skips")
      (buffer-kill! buf))))

;; every text in a block tree, in draw order
(define (perf-test--texts b)
  (if (pair? b)
      (fold (lambda (acc kid) (append acc (perf-test--texts kid)))
            (let ((t (perf--get b 'text #f))) (if (string? t) (list t) '()))
            (let ((kids (perf--get b 'children '()))) (if (pair? kids) kids '())))
      '()))

(deftest 'perf-tabs-keep-the-compos-memory-apart
  "the system tab holds the lanes and the apps, the compos tab holds the daemon's memory"
  (lambda ()
    (let ((buf (perf-test--buffer)))
      (buffer-create buf)
      (with-current-buffer buf (lambda () (set-mode! "perf-mode")))
      (let ((system (perf-test--texts (car (buffer-local-value 'render-blocks buf)))))
        (check-true! (member "Lanes · contention" system) "the system tab holds the lanes")
        (check-true! (not (member "Memory · compos" system)) "the system tab holds no daemon memory"))
      (with-current-buffer buf (lambda () (run-command "perf-tab-compos")))
      (let ((compos (perf-test--texts (car (buffer-local-value 'render-blocks buf)))))
        (check-true! (member "Memory · compos" compos) "the compos tab holds the daemon memory")
        (check-true! (not (member "Lanes · contention" compos)) "the compos tab holds no lanes"))
      (buffer-kill! buf))))

(deftest 'perf-vm-panel-shows-the-split-and-the-largest-processes
  "the VM panel shows the memory split, then the processes, the most memory first"
  (lambda ()
    (let* ((mem (list 'total 1073741824 'processes 536870912 'ets 268435456
                      'binary 134217728 'code 67108864 'atom 1024))
           (rows (list (list 'name "Compos.Core.Desktop" 'pid "<0.933.0>" 'memory 14680064)
                       (list 'name "Compos.Core.Session" 'pid "<0.900.0>" 'memory 267386880)
                       (list 'name "Compos.Core.Buffer.init/1" 'pid "<0.956.0>" 'memory 1048576)))
           (texts (perf-test--texts (perf--vm-panel mem rows))))
      (check-true! (member "total 1.0 GiB = processes 512 MiB + ets 256 MiB + binary 128 MiB + code 64 MiB + other 64 MiB" texts)
                   "the head holds the split, and the parts sum to the total")
      (check-equal! (filter (lambda (t) (string-prefix? "Compos." t)) texts)
                    '("Compos.Core.Session" "Compos.Core.Desktop" "Compos.Core.Buffer.init/1")
                    "the process names, the most memory first")
      (check-true! (member "255 MiB" texts) "the row holds the memory")
      (check-true! (member "<0.900.0>" texts) "the row holds the pid"))))

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
      (let ((tick (or (buffer-local-value 'perf-tick buf) 0)))
        (perf--refresh! buf)
        (check-equal! (buffer-local-value 'perf-tick buf) (+ tick 1) "the sample landed")
        (check-true! (pair? (buffer-local-value 'render-blocks buf)) "the blocks landed")
        (check-true! (string-prefix? "*perf*" (buffer-text buf)) "the text was rewritten")
        (check-true! (buffer-read-only? buf) "the buffer stays read-only through the write"))
      (buffer-kill! buf))))

(deftest 'fd-pressure-passes-at-the-ratio
  "the descriptor check reports at fd-warn-ratio of the limit and not below it"
  (lambda ()
    (let ((saved fd-warn-ratio))
      (set! fd-warn-ratio 0.5)
      (check-true! (fd-pressure? 50 100) "half the limit is pressure")
      (check-false! (fd-pressure? 49 100) "below half is not")
      (check-false! (fd-pressure? 10 0) "an unknown limit is never pressure")
      (set! fd-warn-ratio saved))))

(deftest 'fd-check-publishes-the-port-groups
  "past the ratio the check publishes the count, the limit, and the port groups"
  (lambda ()
    (let ((saved-ratio fd-warn-ratio)
          (saved-last *fd-last-warn*))
      (set! fd-warn-ratio 0)
      (set! *fd-last-warn* #f)
      (let* ((before (event-log-seq))
             (fl (fd-check!))
             (es (event-log-read before "compos:fds" 10)))
        (check-true! (> (car fl) 0) "the daemon holds descriptors")
        (check-true! (> (cadr fl) (car fl)) "the limit is above the count")
        (check-equal! (length es) 1 "one report")
        (let ((d (plist-get (car es) 'data)))
          (check-equal! (plist-get d 'limit) (cadr fl) "the report carries the limit")
          (check-true! (pair? (plist-get d 'ports)) "the report names the port groups"))
        (check-equal! (length (begin (fd-check!) (event-log-read before "compos:fds" 10))) 1
                      "a second check inside fd-warn-every-ms publishes nothing"))
      (set! fd-warn-ratio saved-ratio)
      (set! *fd-last-warn* saved-last))))

(deftest 'vm-collect-answers-a-count-and-the-bytes
  "the collection of idle processes answers a count and the bytes, and the roots list their kinds"
  (lambda ()
    (let ((r (vm-collect! 0)))
      (check-true! (> (car r) 0) "the collection reaches idle processes")
      (check-true! (>= (cadr r) 0) "the bytes are not negative")
      (check-true! (pair? (assoc "recent" (vm-roots))) "the roots list the recent results"))))
