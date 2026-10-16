;;; profile-test.scm --- the one-command profiler's policy.

(domain! 'testing)
(effects! '(read write))

;; a profile of a command that never ran: at-ms is far in the future, so
;; no telemetry row belongs to it and the rows are the same every run
(define (profile-test--report)
  (list 'command "next-line"
        'buffer "*scratch*"
        'wall-us 20000
        'at-ms 99999999999999
        'calls 1500
        'modules 3
        'functions-seen 2
        'functions (list (list 'module "Compos.Core.Buffer" 'function "text/1" 'calls 400)
                         (list 'module "Compos.Core.Rope" 'function "line/2" 'calls 1100))
        'processes (list (list 'name "Compos.Core.Session" 'pid "<0.1.0>" 'reductions 900000 'memory 131072)
                         (list 'name "Compos.Ui.EditorLive" 'pid "<0.2.0>" 'reductions 100000 'memory -2048))
        'reductions 1000000
        'gcs 12
        'gc-words 40000
        'memory 262144
        'memory-processes 131072
        'memory-binary -2048))

(define (profile-test--buffer)
  (string-append "*profile-test-" (number->string (current-time)) "*"))

(deftest 'profile-formats-numbers-without-floats
  "milliseconds and counts read as short strings from integer arithmetic"
  (lambda ()
    (check-equal! (profile--ms 20000) "20.0" "microseconds become milliseconds")
    (check-equal! (profile--ms 12345) "12.3" "one decimal, rounded")
    (check-equal! (profile--ms 40) "0.0" "under a tenth of a millisecond")
    (check-equal! (profile--count 999) "999" "small counts stay whole")
    (check-equal! (profile--count 12345) "12.3 k" "thousands")
    (check-equal! (profile--count 1000000) "1.0 M" "millions")))

(deftest 'profile-shares-and-bars-are-bounded
  "a share is a percent of the traced wall clock; the bar never overflows"
  (lambda ()
    (check-equal! (profile--share 10000 20000) 50 "half the time")
    (check-equal! (profile--share 30000 20000) 100 "a share never passes a hundred")
    (check-equal! (profile--share 1 0) 0 "nothing measured, no share")
    (check-equal! (string-length (profile--bar 0)) *profile-bar-width* "an empty bar is full width")
    (check-equal! (string-length (profile--bar 100)) *profile-bar-width* "a full bar is full width")))

(deftest 'profile-ignores-the-prompt-that-armed-it
  "the commands a closing prompt runs are not the command the reader meant"
  (lambda ()
    (check-true! (profile--ignored? "profile") "arming itself")
    (check-true! (profile--ignored? "execute-extended-command") "the M-x that ran it")
    (check-true! (not (profile--ignored? "next-line")) "a real command is measured")
    (check-true! (not (profile--ignored? "self-insert-command")) "typing is measured too")))

(deftest 'profile-rows-are-four-sections-with-their-own-units
  "functions, processes, layers and the vm; each section heading says its unit"
  (lambda ()
    (let ((buf (profile-test--buffer)))
      (buffer-create buf)
      (buffer-set-local! buf 'profile-report (profile-test--report))
      (let* ((rows (profile--rows buf))
             (seps (filter (lambda (e) (profile--separator? buf e)) rows))
             (kinds (map (lambda (e) (plist-get e 'kind)) rows)))
        (check-equal! (length seps) 3 "three headings: no telemetry row belongs to this profile")
        (check-true! (string-contains? (plist-get (car seps) 'what) "calls")
                     "the function heading names its unit")
        (check-true! (string-contains? (plist-get (cadr seps) 'what) "reductions")
                     "the process heading names its unit")
        (check-equal! (length (filter (lambda (k) (equal? k "fn")) kinds)) 2 "both functions")
        (check-equal! (length (filter (lambda (k) (equal? k "proc")) kinds)) 2 "both processes")
        (check-equal! (length (filter (lambda (k) (equal? k "layer")) kinds)) 0 "no layer rows")
        (check-true! (> (length (filter (lambda (k) (equal? k "vm")) kinds)) 0) "the vm section"))
      (check-equal! (profile--rows (string-append buf "-empty")) '() "no report, no rows")
      (buffer-kill! buf))))

(deftest 'profile-cells-put-the-shares-beside-the-numbers
  "a function row carries its call count and its share of every call"
  (lambda ()
    (let* ((buf (profile-test--buffer))
           (hot (list 'kind "fn" 'what "Compos.Core.Buffer.text/1"
                      'count 400 'value "" 'share 50))
           (sep (profile--sep "what ran")))
      (buffer-create buf)
      (let ((cells (profile--cells buf hot)))
        (check-equal! (length cells) 4 "one cell per column")
        (check-equal! (car cells) "Compos.Core.Buffer.text/1" "the function names itself")
        (check-equal! (car (cadr cells)) "400" "the call count")
        (check-equal! (nth 2 cells) "" "no third number: the count is the measure")
        (check-equal! (string-length (car (nth 3 cells))) *profile-bar-width* "the share is a bar"))
      (let ((cells (profile--cells buf sep)))
        (check-true! (string-contains? (car (car cells)) "what ran") "a heading reads as one")
        (check-equal! (cadr cells) "" "a heading fills no other column"))
      (buffer-kill! buf))))

(deftest 'profile-mode-draws-the-report-it-was-given
  "the buffer wears profile-mode, the meta line summarises, the rows are there"
  (lambda ()
    (buffer-create *profile-buffer*)
    (let ((was (buffer-local *profile-buffer* 'profile-report)))
      (buffer-set-local! *profile-buffer* 'profile-report (profile-test--report))
      (with-current-buffer *profile-buffer* (lambda () (set-mode! "profile-mode")))
      (check-true! (buffer-derived-mode? *profile-buffer* "profile-mode") "the mode is on")
      (let ((meta (profile--meta *profile-buffer*)))
        (check-true! (string-contains? meta "next-line") "the meta names the command")
        (check-true! (string-contains? meta "20.0 ms") "and its wall clock")
        (check-true! (string-contains? meta "1.0 M reductions") "and what the VM paid"))
      (let ((text (buffer-text *profile-buffer*)))
        (check-true! (string-contains? text "Compos.Core.Buffer.text/1") "the hottest function is drawn")
        (check-true! (string-contains? text "what ran") "under its heading"))
      (check-true! (member 'profile-report (buffer-local *profile-buffer* 'desktop-skip-locals))
                   "a report is runtime state the desktop skips")
      (buffer-set-local! *profile-buffer* 'profile-report was))))

(deftest 'profile-arms-and-disarms-by-name
  "M-x profile waits for one command; M-x profile-cancel stops waiting"
  (lambda ()
    (let ((was *profile-armed*))
      (run-command "profile")
      (check-true! (profile-armed?) "armed")
      (run-command "profile-cancel")
      (check-true! (not (profile-armed?)) "disarmed")
      (set! *profile-armed* was))))

(deftest 'profile-site-counters-do-not-count-themselves
  "an armed fold or remove counts its call site once and returns the builtin's value"
  (lambda ()
    (profile--sites-on!)
    (let ((sum (fold (lambda (acc item) (+ acc item)) 0 '(1 2 3 4 5)))
          (kept (remove (lambda (x) (= x 2)) '(1 2 3))))
      (let ((sites (profile--sites-report)))
        (profile--sites-off!)
        (check-equal! sum 15 "the wrapped fold returns the builtin's value")
        (check-equal! kept '(1 3) "the wrapped remove returns the builtin's value")
        (check-equal! (length sites) 2 "one row per call site, none for the bookkeeping")
        (check-equal! (fold (lambda (n s) (+ n (plist-get s 'calls))) 0 sites) 2
                      "each call counts once")))
    (check-true! (not *profile-site-busy*) "off clears the busy flag")))
