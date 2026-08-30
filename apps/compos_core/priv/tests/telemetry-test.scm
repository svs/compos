;;; telemetry-test.scm --- Scheme telemetry policy.

(domain! 'testing)
(effects! '(read write execute))

(deftest 'scheme-telemetry-reads-shared-task-events
  "the Scheme package reads normalized scheduler measurements"
  (lambda ()
    (telemetry-clear!)
    (let ((task (task-spawn (lambda () 42))))
      (task-await task)
      (task-cancel! task))
    (check-true!
      (wait-until (lambda () (pair? (telemetry-events 10))) 500 5)
      "the collector receives the task event")
    (let ((row (car (telemetry-events 10))))
      (check-equal! (plist-get row 'kind) "task" "the row names its event kind")
      (check-equal! (plist-get row 'status) "ok" "the row includes task status")
      (check-true! (number? (plist-get row 'duration-ms)) "the row includes duration"))
    (telemetry-clear!)))

(deftest 'scheme-telemetry-formats-list-cells
  "the Scheme package owns the visible table policy"
  (lambda ()
    (let ((cells
            (telemetry--cells "*unused*"
              (list 'kind "lane" 'time-ms 1000 'duration-ms 300
                    'queue-ms 12 'backlog 4 'owner ":ui"
                    'label "eval apropos" 'status "ok"))))
      (check-equal! (car (nth 1 cells)) "scheme" "a row with no layer is a scheme row")
      (check-equal! (cadr (nth 1 cells)) "telemetry-scheme" "the layer wears its face")
      (check-equal! (nth 2 cells) ":ui" "the table shows the logical owner")
      (check-equal! (nth 3 cells) "eval apropos" "the table shows the complete job")
      (check-equal! (nth 4 cells) (list "▇▇▇▇▇▇" "warn") "a slow bar is full and warns")
      (check-equal! (car (nth 5 cells)) "300" "slow duration receives a face")
      (check-equal! (car (nth 7 cells)) "" "a row with no trace shows none"))))

(deftest 'scheme-telemetry-shows-every-layer-with-its-trace
  "a browser or live row shows its layer, its detail, and its trace id"
  (lambda ()
    (let ((cells
            (telemetry--cells "*unused*"
              (list 'kind "push" 'layer "browser" 'time-ms 1000 'duration-ms 80
                    'queue-ms 30 'backlog 0 'owner "frame f-1"
                    'label "intent insertText" 'status "ok"
                    'tid "ab12:7" 'detail "patch 50ms 2048b"))))
      (check-equal! (nth 1 cells) (list "browser" "telemetry-browser") "the table shows the layer")
      (check-equal! (nth 4 cells) (list "▇▇" "telemetry-bar") "a quick bar is short and quiet")
      (check-equal! (nth 3 cells) "intent insertText  patch 50ms 2048b"
                    "the job cell carries the layer's detail")
      (check-equal! (car (nth 7 cells)) "ab12:7" "the table shows the trace id"))))

(deftest 'scheme-telemetry-snapshot-rows-name-their-layer
  "every row the collector returns carries a layer, a trace, and a detail"
  (lambda ()
    (telemetry-clear!)
    (let ((task (task-spawn (lambda () 1))))
      (task-await task)
      (task-cancel! task))
    (check-true!
      (wait-until (lambda () (pair? (telemetry-events 10))) 500 5)
      "the collector receives the task event")
    (let ((row (car (telemetry-events 10))))
      (check-equal! (plist-get row 'layer) "scheme" "a task is a scheme row")
      (check-equal! (plist-get row 'tid) #f "a task has no trace")
      (check-equal! (plist-get row 'detail) "" "a task has no detail"))
    (telemetry-clear!)))

(deftest 'scheme-telemetry-builds-complete-event-details
  "the detail projection retains fields omitted from the compact table"
  (lambda ()
    (let* ((row (list 'kind "lane" 'time-ms 1000 'duration-ms 300
                      'queue-ms 12 'backlog 4 'owner "{:buffer, \"other\"}"
                      'label "command other-window" 'status "ok"))
           (text (telemetry--detail-text row)))
      (check-true! (string-contains? text "command other-window")
                   "detail includes the full job label")
      (check-true! (string-contains? text "{:buffer, \"other\"}")
                   "detail includes the logical owner")
      (check-true! (string-contains? text "Layer: scheme")
                   "detail names the layer")
      (check-equal! (length (telemetry--detail-blocks row)) 2
                    "detail has a heading and structured card"))))

(deftest 'telemetry-command-opens-the-scheme-owned-list
  "the normal command loads the package and builds its list mode"
  (lambda ()
    (run-command "telemetry")
    (check-true! (buffer-exists? *telemetry-buffer*) "the command creates its buffer")
    (check-equal! (buffer-local *telemetry-buffer* 'mode-name)
                  "telemetry-mode" "the buffer records its mode")
    (check-true! (string-contains? (buffer-text *telemetry-buffer*) "Telemetry")
                 "the list renders its title")))

(deftest 'telemetry-draws-bars-sparklines-and-percentiles
  "the look is arithmetic the package owns: one scale for the bars, one block per keystroke"
  (lambda ()
    (check-equal! (telemetry--bar 0) "" "no work draws no bar")
    (check-equal! (telemetry--bar 4) "▇" "a little work draws one block")
    (check-equal! (telemetry--bar telemetry-slow-ms) "▇▇▇▇▇▇" "the threshold fills the bar")
    (check-equal! (telemetry--bar (* 10 telemetry-slow-ms)) "▇▇▇▇▇▇" "the bar has no more room")
    (check-equal! (telemetry--sparkline (list 10 20 40 80)) "▁▂▄█" "the tallest block is the largest value")
    (check-equal! (telemetry--sparkline (list 0 0)) "▁▁" "all zeros draw the floor")
    (check-equal! (telemetry--sparkline '()) "" "no keys draw nothing")
    (check-equal! (telemetry--percentile (list 1 2 3 4 5 6 7 8 9 10) 50) 6 "p50")
    (check-equal! (telemetry--percentile (list 1 2 3 4 5 6 7 8 9 10) 95) 10 "p95")
    (check-equal! (telemetry--percentile '() 95) 0 "no rows is zero")))

(deftest 'telemetry-meta-carries-the-newest-keystrokes
  "the sparkline reads the browser's key rows, oldest on the left, and names the last one"
  (lambda ()
    (let ((rows (list (list 'layer "browser" 'label "key b" 'duration-ms 80 'kind "push")
                      (list 'layer "scheme" 'label "command x" 'duration-ms 2 'kind "lane")
                      (list 'layer "browser" 'label "key a" 'duration-ms 10 'kind "push"))))
      (check-equal! (map (lambda (r) (plist-get r 'label)) (telemetry--newest-keys rows 5))
                    (list "key a" "key b") "oldest first")
      (check-equal! (length (telemetry--newest-keys rows 1)) 1 "the limit holds")
      (buffer-create "*zz-telemetry-meta*")
      (buffer-set-local! "*zz-telemetry-meta*" 'list-entries rows)
      (let ((meta (telemetry--meta "*zz-telemetry-meta*")))
        (check-true! (string-contains? meta "3 events") "the count")
        (check-true! (string-contains? meta "keys ▁█  key b 80ms") "the sparkline and the last key"))
      (buffer-kill! "*zz-telemetry-meta*"))))

(deftest 'telemetry-narrows-to-a-trace-the-keys-or-the-slow-rows
  "the mode's own filter kinds read the row; the same key again widens"
  (lambda ()
    (let ((traced (list 'layer "live" 'label "event key a" 'duration-ms 2 'tid "ab:1"))
          (quiet (list 'layer "scheme" 'label "task" 'duration-ms 1))
          (slow (list 'layer "scheme" 'label "eval" 'duration-ms (+ telemetry-slow-ms 1))))
      (check-true! (telemetry--filter #f traced (list "trace" "ab:1")) "the trace matches")
      (check-true! (not (telemetry--filter #f quiet (list "trace" "ab:1"))) "another row does not")
      (check-true! (telemetry--filter #f traced (list "keys" "traced")) "a traced row is a key row")
      (check-true! (not (telemetry--filter #f quiet (list "keys" "traced"))) "an untraced row is not")
      (check-true! (telemetry--filter #f slow (list "slow" "")) "a slow row is slow")
      (check-true! (not (telemetry--filter #f quiet (list "slow" ""))) "a quick row is not"))
    (run-command "telemetry")
    (list-filter-clear! *telemetry-buffer*)
    (with-current-buffer *telemetry-buffer*
      (lambda ()
        (run-command "telemetry-slow")
        (check-equal! (car (car (list-filters *telemetry-buffer*))) "slow" "s narrows to the slow rows")
        (run-command "telemetry-slow")
        (check-equal! (list-filters *telemetry-buffer*) '() "s again widens")))))

(deftest 'telemetry-toggle-opens-the-popup-and-closes-it
  "one command shows the list as a bottom popup and takes it away again"
  (lambda ()
    (when (telemetry-popup-open?) (popup-close!))
    (run-command "telemetry-toggle")
    (check-true! (telemetry-popup-open?) "the popup shows the telemetry list")
    (check-equal! (buffer-local *telemetry-buffer* 'window-class) "popup popup-bottom"
                  "the list floats along the bottom edge")
    (run-command "telemetry-toggle")
    (check-true! (not (telemetry-popup-open?)) "the same command closes it")))
