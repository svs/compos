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
      (check-equal! (nth 1 cells) "scheme" "a row with no layer is a scheme row")
      (check-equal! (nth 2 cells) ":ui" "the table shows the logical owner")
      (check-equal! (nth 3 cells) "eval apropos" "the table shows the complete job")
      (check-equal! (car (nth 4 cells)) "300" "slow duration receives a face")
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
      (check-equal! (nth 1 cells) "browser" "the table shows the layer")
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
