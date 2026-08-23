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
      (check-equal! (nth 1 cells) ":ui" "the table shows the logical owner")
      (check-equal! (nth 2 cells) "eval apropos" "the table shows the complete job")
      (check-equal! (car (nth 3 cells)) "300" "slow duration receives a face"))))

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
      (check-equal! (length (telemetry--detail-blocks row)) 2
                    "detail has a heading and structured card"))))

(deftest 'telemetry-command-opens-the-scheme-owned-list
  "the normal command loads the package and builds its list mode"
  (lambda ()
    (run-command "telemetry")
    (check-true! (buffer-exists? *telemetry-buffer*) "the command creates its buffer")
    (check-equal! (buffer-local *telemetry-buffer* 'mode-name)
                  "telemetry-mode" "the buffer records its mode")
    (check-true! (string-contains? (buffer-text *telemetry-buffer*) "Scheme Telemetry")
                 "the list renders its title")))
