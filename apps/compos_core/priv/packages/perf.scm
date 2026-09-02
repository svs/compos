;;; perf.scm --- the system monitor: the VM and the host, live, in one buffer.
;;;
;;; The *perf* buffer draws nine panels from two sources per tick: the VM
;;; counters that vm-sample and vm-processes return, and the telemetry
;;; stream. Elixir supplies the counters. This package decides the series,
;;; the scale, the colours, the table, and the keys.
;;;
;;; The buffer text is a plain table of the same numbers. A reader without
;;; the blocks view still sees the state, and point rests on a process row:
;;; the table rows carry the line they stand for, so the current row
;;; follows point and RET, k act on the row at point.
;;;
;;; The tick is one debounce that re-arms itself. A hidden buffer ticks
;;; five times slower and samples nothing; a shown buffer samples every
;;; perf-tick-ms. A killed buffer ends the chain.

(package! 'perf)
(domain! 'diagnostics)
(effects! '(read))

(define *perf-buffer* "*perf*")

(defcustom 'perf-tick-ms 1000
  "Milliseconds between two samples of the *perf* buffer."
  'group 'perf 'type 'number)

(defcustom 'perf-history 60
  "How many samples each chart keeps."
  'group 'perf 'type 'number)

(defcustom 'perf-process-rows 15
  "How many process rows the table shows."
  'group 'perf 'type 'number)

(define *perf-sorts* '("reds" "memory" "queue" "name"))
(define *perf-heat-layers* '("scheme" "live" "browser"))
(define *perf-heat-width* 30)
(define *perf-core-width* 24)
(define *perf-spark-width* 16)
(define *perf-log-rows* 10)

;; the buffer text: line 1 is the summary, line 2 the filter, line 3 blank,
;; line 4 the table head, and the rows start on line 5
(define perf--first-row-line 5)

;;; --- small helpers ------------------------------------------------------------

;; plist-get that answers FALLBACK for a missing key or a #f plist
(define (perf--get pl key &optional fallback)
  (let loop ((xs (if (pair? pl) pl '())))
    (cond ((null? xs) fallback)
          ((null? (cdr xs)) fallback)
          ((equal? (car xs) key) (cadr xs))
          (else (loop (cdr (cdr xs)))))))

(define (perf--push xs v n)
  (last-n (append xs (list v)) n))

(define (perf--add a b)
  (let loop ((a a) (b b) (acc '()))
    (if (or (null? a) (null? b))
        (reverse acc)
        (loop (cdr a) (cdr b) (cons (+ (car a) (car b)) acc)))))

(define (perf--max xs)
  (fold (lambda (acc v) (max acc v)) 0 xs))

(define (perf--last xs)
  (if (null? xs) 0 (car (reverse xs))))

(define (perf--clamp v)
  (max 0 (min 100 v)))

;; PART as a whole percent of WHOLE, 0 when WHOLE is 0
(define (perf--pct part whole)
  (if (> whole 0) (quotient (* 100 part) whole) 0))

;; every value as a percent of the largest, so a chart fills its height
(define (perf--scale xs)
  (let ((top (max 1 (perf--max xs))))
    (map (lambda (v) (perf--pct v top)) xs)))

;; N tenths as "12.3"
(define (perf--tenths n)
  (string-append (number->string (quotient n 10)) "." (number->string (modulo n 10))))

(define (perf--bytes b)
  (cond ((>= b 1073741824) (string-append (perf--tenths (quotient (* 10 b) 1073741824)) " GiB"))
        ((>= b 1048576) (string-append (number->string (quotient b 1048576)) " MiB"))
        ((>= b 1024) (string-append (number->string (quotient b 1024)) " KiB"))
        (else (string-append (number->string b) " B"))))

;; 1234567 -> "1.2M", 12345 -> "12.3k", 999 -> "999"
(define (perf--count n)
  (cond ((>= n 1000000) (string-append (perf--tenths (quotient n 100000)) "M"))
        ((>= n 1000) (string-append (perf--tenths (quotient n 100)) "k"))
        (else (number->string n))))

(define (perf--uptime ms)
  (let* ((s (quotient ms 1000))
         (h (quotient s 3600))
         (m (quotient (modulo s 3600) 60)))
    (string-append (number->string h) "h " (if (< m 10) "0" "") (number->string m) "m")))

(define (perf--clip s n)
  (if (> (string-length s) n) (substring s 0 n) s))

(define (perf--line-count text)
  (length (string-split text "\n")))

;;; --- SVG paths -------------------------------------------------------------------
;;; Every chart is a viewBox 0 0 W 100 with one point per ten units of x and
;;; y as a percent from the top. Integer arithmetic only.

(define (perf--x i) (number->string (* i 10)))
(define (perf--y v) (number->string (- 100 (perf--clamp v))))

(define (perf--view-box n)
  (string-append "0 0 " (number->string (* 10 (max 1 (- n 1)))) " 100"))

(define (perf--path-line vs)
  (let loop ((xs vs) (i 0) (acc '()))
    (if (null? xs)
        (string-join (reverse acc) " ")
        (loop (cdr xs) (+ i 1)
              (cons (string-append (if (= i 0) "M" "L") (perf--x i) "," (perf--y (car xs)))
                    acc)))))

;; the area between TOP and BOTTOM; BOTTOM #f is the floor
(define (perf--path-area top bottom)
  (let* ((n (length top))
         (back (let loop ((i (- n 1)) (acc '()))
                 (if (< i 0)
                     (reverse acc)
                     (loop (- i 1)
                           (cons (string-append "L" (perf--x i) ","
                                                (perf--y (if bottom (nth i bottom) 0)))
                                 acc))))))
    (if (= n 0)
        ""
        (string-append (perf--path-line top) " " (string-join back " ") " Z"))))

;; a mirrored area: UP? draws above the midline, else below
(define (perf--path-mirror vs up?)
  (let* ((n (length vs))
         (pts (let loop ((xs vs) (i 0) (acc '()))
                (if (null? xs)
                    (reverse acc)
                    (loop (cdr xs) (+ i 1)
                          (cons (string-append (if (= i 0) "M" "L") (perf--x i) ","
                                               (number->string
                                                 (if up?
                                                     (- 50 (quotient (* (perf--clamp (car xs)) 48) 100))
                                                     (+ 50 (quotient (* (perf--clamp (car xs)) 48) 100)))))
                                acc))))))
    (if (= n 0)
        ""
        (string-append (string-join pts " ")
                       " L" (perf--x (- n 1)) ",50 L0,50 Z"))))

;;; --- blocks -----------------------------------------------------------------------

;; children arrive as blocks or as lists of blocks; a list splices in
(define (perf--kids items)
  (fold (lambda (acc x)
          (cond ((null? x) acc)
                ((and (pair? x) (pair? (car x))) (append acc x))
                (else (append acc (list x)))))
        '() items))

(define (perf--div class &rest children)
  (list 'tag "div" 'class class 'children (perf--kids children)))

(define (perf--txt class text)
  (list 'tag "span" 'class class 'text text))

(define (perf--svg n class &rest children)
  (list 'tag "svg" 'class (string-append "perf-svg " class)
        'attrs (list (list "viewBox" (perf--view-box n))
                     (list "preserveAspectRatio" "none"))
        'children (perf--kids children)))

(define (perf--path d class)
  (list 'tag "path" 'class class 'attrs (list (list "d" d))))

(define (perf--hline y)
  (list 'tag "line" 'class "perf-rule"
        'attrs (list (list "x1" "0") (list "y1" (number->string y))
                     (list "x2" "10000") (list "y2" (number->string y)))))

(define (perf--panel span fig title right &rest body)
  (list 'tag "div" 'class (string-append "perf-panel perf-c" (number->string span))
        'children
        (cons (perf--div "perf-head"
                (perf--txt "perf-fig" fig)
                (perf--txt "" title)
                (perf--txt "perf-spacer" "")
                (perf--div "perf-head-right" right))
              (perf--kids body))))

(define (perf--stat k v class)
  (perf--div "perf-stat"
    (perf--txt "perf-stat-k" k)
    (perf--txt (string-append "perf-stat-v " class) v)))

(define (perf--legend class label)
  (perf--div "perf-legend" (perf--txt (string-append "perf-swatch " class) "") (perf--txt "" label)))

;; the face a load wears: red past 70, amber past 40, indigo past 15
(define (perf--load-class v)
  (cond ((> v 70) "perf-hot")
        ((> v 40) "perf-warm")
        ((> v 15) "perf-cool")
        (else "perf-idle")))

(define (perf--heat-class ms)
  (cond ((= ms 0) "perf-h0")
        ((< ms 4) "perf-h1")
        ((< ms 16) "perf-h2")
        ((< ms 50) "perf-h3")
        ((< ms 250) "perf-h4")
        (else "perf-h5")))

(define (perf--level-class level)
  (cond ((equal? level "error") "perf-hot")
        ((equal? level "warn") "perf-warm")
        (else "perf-cool")))

;;; --- the samples -----------------------------------------------------------------

(define (perf--sort-name buf)
  (or (buffer-local buf 'perf-sort) "reds"))

(define (perf--advance-cores old now)
  (let loop ((i 0) (now now) (acc '()))
    (if (null? now)
        (reverse acc)
        (loop (+ i 1) (cdr now)
              (cons (perf--push (if (< i (length old)) (nth i old) '())
                                (car now) *perf-core-width*)
                    acc)))))

(define (perf--advance ser s)
  (let ((os (perf--get s 'os '()))
        (n perf-history))
    (list 'sched (perf--push (perf--get ser 'sched '()) (perf--get s 'sched-util 0) n)
          'dcpu (perf--push (perf--get ser 'dcpu '()) (perf--get s 'dirty-cpu-util 0) n)
          'dio (perf--push (perf--get ser 'dio '()) (perf--get s 'dirty-io-util 0) n)
          'host (perf--push (perf--get ser 'host '()) (perf--get os 'cpu-util 0) n)
          'in (perf--push (perf--get ser 'in '()) (perf--get s 'io-in-rate 0) n)
          'out (perf--push (perf--get ser 'out '()) (perf--get s 'io-out-rate 0) n)
          'cores (perf--advance-cores (perf--get ser 'cores '())
                                      (append (perf--get s 'schedulers '())
                                              (perf--get s 'dirty-cpu '()))))))

;; one heat cell per layer per tick: the slowest event that arrived since
;; the previous tick
(define (perf--advance-heat old since events)
  (let ((fresh (filter (lambda (r) (> (plist-get r 'time-ms) since)) events)))
    (let loop ((layers *perf-heat-layers*) (i 0) (acc '()))
      (if (null? layers)
          (reverse acc)
          (let ((ms (fold (lambda (m r)
                            (if (equal? (telemetry--layer r) (car layers))
                                (max m (telemetry--ms r))
                                m))
                          0 fresh)))
            (loop (cdr layers) (+ i 1)
                  (cons (perf--push (if (< i (length old)) (nth i old) '()) ms *perf-heat-width*)
                        acc)))))))

;; the reductions history of every shown process; a process that leaves
;; the table leaves the history
(define (perf--advance-sparks old rows)
  (map (lambda (r)
         (let* ((pid (plist-get r 'pid))
                (hit (assoc pid (or old '())))
                (hist (if hit (cadr hit) '())))
           (list pid (perf--push hist (plist-get r 'reds) *perf-spark-width*))))
       rows))

(define (perf--render-durations events)
  (sort (map telemetry--ms
             (filter (lambda (r)
                       (and (equal? (telemetry--layer r) "live")
                            (string-prefix? "render" (or (plist-get r 'label) ""))))
                     events))))

(define (perf--newest-time events)
  (fold (lambda (m r) (max m (plist-get r 'time-ms))) 0 events))

(define (perf--sample! buf)
  (let* ((s (vm-sample))
         (procs (vm-processes perf-process-rows (perf--sort-name buf)
                              (or (buffer-local buf 'perf-filter) "")))
         (events (telemetry-events 400))
         (since (or (buffer-local buf 'perf-heat-since) 0)))
    (buffer-set-local! buf 'perf-sample s)
    (buffer-set-local! buf 'perf-procs procs)
    (buffer-set-local! buf 'perf-series
      (perf--advance (or (buffer-local buf 'perf-series) '()) s))
    (buffer-set-local! buf 'perf-heat
      (perf--advance-heat (or (buffer-local buf 'perf-heat) '()) since events))
    (buffer-set-local! buf 'perf-heat-since (max since (perf--newest-time events)))
    (buffer-set-local! buf 'perf-sparks
      (perf--advance-sparks (buffer-local buf 'perf-sparks) (perf--get procs 'rows '())))
    (buffer-set-local! buf 'perf-render-ms (perf--render-durations events))
    (buffer-set-local! buf 'perf-tick (+ 1 (or (buffer-local buf 'perf-tick) 0)))))

;;; --- the text ----------------------------------------------------------------------

(define (perf--row-text r)
  (string-append
    (string-pad-right (plist-get r 'pid) 12)
    (string-pad-right (perf--clip (plist-get r 'name) 38) 40)
    (string-pad-left (perf--count (plist-get r 'reds)) 10)
    (string-pad-left (perf--bytes (plist-get r 'memory)) 10)
    (string-pad-left (number->string (plist-get r 'queue)) 6)
    "  " (plist-get r 'status) "\n"))

(define (perf--text buf)
  (let* ((s (or (buffer-local buf 'perf-sample) '()))
         (os (perf--get s 'os '()))
         (mem (perf--get s 'memory '()))
         (procs (or (buffer-local buf 'perf-procs) '()))
         (rows (perf--get procs 'rows '())))
    (string-append
      "*perf*  " (perf--get s 'host "")
      "  schedulers " (number->string (perf--get s 'sched-util 0)) "%"
      "  host cpu " (number->string (perf--get os 'cpu-util 0)) "%"
      "  memory " (perf--bytes (perf--get mem 'total 0))
      "  processes " (number->string (perf--get s 'process-count 0))
      "  run queue " (number->string (perf--get s 'run-queue 0))
      "  tick " (number->string (or (buffer-local buf 'perf-tick) 0)) "\n"
      "filter: " (or (buffer-local buf 'perf-filter) "")
      "  sort: " (perf--sort-name buf)
      "  " (number->string (perf--get procs 'matched 0)) "/" (number->string (perf--get procs 'count 0))
      (if (buffer-local buf 'perf-paused) "  paused" "") "\n"
      "\n"
      (string-pad-right "PID" 12) (string-pad-right "NAME" 40)
      (string-pad-left "REDS/S" 10) (string-pad-left "MEMORY" 10) (string-pad-left "MQ" 6)
      "  STATUS\n"
      (apply string-append (map perf--row-text rows)))))

;; (LINE PID NAME) for every table row
(define (perf--rows buf)
  (let loop ((rows (perf--get (or (buffer-local buf 'perf-procs) '()) 'rows '()))
             (line perf--first-row-line)
             (acc '()))
    (if (null? rows)
        (reverse acc)
        (loop (cdr rows) (+ line 1)
              (cons (list line (plist-get (car rows) 'pid) (plist-get (car rows) 'name)) acc)))))

(define (perf--row-at-point buf)
  (let ((line (car (buffer-line-at-point buf))))
    (assoc line (or (buffer-local buf 'perf-rows) '()))))

;; rewrite the text; point stays on its line
(define (perf--replace-text! buf text)
  (let ((line (car (buffer-line-at-point buf)))
        (last (perf--line-count text)))
    (buffer-set-read-only! buf #f)
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf text)
    (buffer-set-read-only! buf #t)
    (with-current-buffer buf
      (lambda ()
        (goto-char! (line-start-position (max 1 (min line last))))))))

;;; --- the panels ----------------------------------------------------------------------

(define (perf--cpu-panel s ser)
  (let* ((sched (perf--get ser 'sched '()))
         (dcpu (perf--get ser 'dcpu '()))
         (dio (perf--get ser 'dio '()))
         (host (perf--get ser 'host '()))
         (stack1 (perf--add sched dcpu))
         (stack2 (perf--add stack1 dio))
         (os (perf--get s 'os '()))
         (now (perf--last sched))
         (n (length sched)))
    (perf--panel 5 "Fig. 1" "Schedulers · aggregate"
      (list (perf--legend "perf-sw-user" "normal")
            (perf--legend "perf-sw-sys" "dirty cpu")
            (perf--legend "perf-sw-io" "dirty io")
            (perf--legend "perf-sw-line" "host"))
      (perf--div "perf-body-row"
        (perf--div "perf-chart"
          (perf--svg n ""
            (perf--hline 20) (perf--hline 40) (perf--hline 60) (perf--hline 80)
            (perf--path (perf--path-area stack2 stack1) "perf-io")
            (perf--path (perf--path-area stack1 sched) "perf-sys")
            (perf--path (perf--path-area sched #f) "perf-user")
            (perf--path (perf--path-line host) "perf-line"))
          (perf--txt "perf-corner perf-corner-tl" "100%")
          (perf--txt "perf-corner perf-corner-bl" (string-append "−" (number->string n) " s")))
        (perf--div "perf-side"
          (perf--div "perf-big" (perf--txt "" (number->string now)) (perf--txt "perf-unit" "%"))
          (perf--stat "normal" (string-append (number->string now) "%") "perf-cool")
          (perf--stat "dirty cpu" (string-append (number->string (perf--last dcpu)) "%") "perf-warm")
          (perf--stat "dirty io" (string-append (number->string (perf--last dio)) "%") "perf-hot")
          (perf--stat "host cpu" (string-append (number->string (perf--get os 'cpu-util 0)) "%") "")
          (perf--stat "run queue" (number->string (perf--get s 'run-queue 0)) "")
          (perf--stat "reds/s" (perf--count (perf--get s 'reductions-rate 0)) "")
          (perf--stat "ctx sw/s" (perf--count (perf--get s 'context-switch-rate 0)) "")
          (perf--stat "gc/s" (perf--count (perf--get s 'gc-rate 0)) ""))))))

(define (perf--ring label pct sub class)
  (perf--div "perf-ring"
    (perf--div "perf-ring-box"
      (list 'tag "svg" 'class "perf-ring-svg"
            'attrs (list (list "viewBox" "0 0 40 40"))
            'children
            (list (list 'tag "circle" 'class "perf-ring-track"
                        'attrs (list (list "cx" "20") (list "cy" "20") (list "r" "16")))
                  (list 'tag "circle" 'class (string-append "perf-ring-arc " class)
                        'attrs (list (list "cx" "20") (list "cy" "20") (list "r" "16")
                                     (list "stroke-dasharray"
                                           (string-append (number->string pct) " 100.5"))))))
      (perf--txt "perf-ring-pct" (string-append (number->string pct) "%")))
    (perf--txt "perf-ring-label" label)
    (perf--txt "perf-ring-sub" sub)))

(define (perf--segment label bytes total class)
  (list label bytes (perf--pct bytes total) class))

(define (perf--memory-panel s)
  (let* ((mem (perf--get s 'memory '()))
         (os (perf--get s 'os '()))
         (total (max 1 (perf--get mem 'total 0)))
         (procs (perf--get mem 'processes 0))
         (bin (perf--get mem 'binary 0))
         (ets (perf--get mem 'ets 0))
         (code (perf--get mem 'code 0))
         (atom (perf--get mem 'atom 0))
         (other (max 0 (- total procs bin ets code atom)))
         (host-total (perf--get os 'mem-total 0))
         (host-used (max 0 (- host-total (perf--get os 'mem-free 0))))
         (segs (list (perf--segment "processes" procs total "perf-sw-user")
                     (perf--segment "binaries" bin total "perf-sw-soft")
                     (perf--segment "ets" ets total "perf-sw-sand")
                     (perf--segment "code" code total "perf-sw-sys")
                     (perf--segment "atoms" atom total "perf-sw-io")
                     (perf--segment "other" other total "perf-sw-dim"))))
    (perf--panel 3 "Fig. 2" "Memory"
      (list (perf--txt "" (perf--bytes total)))
      (perf--div "perf-rings"
        (perf--ring "processes" (perf--pct procs total) (perf--bytes procs) "perf-user")
        (perf--ring "binaries" (perf--pct bin total) (perf--bytes bin) "perf-sys")
        (perf--ring "host" (perf--pct host-used (max 1 host-total)) (perf--bytes host-used)
                    (if (> (perf--pct host-used (max 1 host-total)) 90) "perf-io" "perf-ok")))
      (perf--div "perf-segbar"
        (map (lambda (seg)
               (list 'tag "div" 'class (string-append "perf-seg " (nth 3 seg))
                     'attrs (list (list "style" (string-append "width:" (number->string (nth 2 seg)) "%")))))
             segs))
      (perf--div "perf-seglist"
        (map (lambda (seg)
               (perf--div "perf-segrow"
                 (perf--txt (string-append "perf-swatch " (nth 3 seg)) "")
                 (perf--txt "perf-stat-k perf-spacer" (car seg))
                 (perf--txt "" (perf--bytes (cadr seg)))))
             segs)))))

(define (perf--io-panel s ser)
  (let* ((in (perf--get ser 'in '()))
         (out (perf--get ser 'out '()))
         (top (max 1 (perf--max in) (perf--max out)))
         (n (length in)))
    (perf--panel 4 "Fig. 3" "Port IO · bytes"
      (list (perf--txt "perf-ok" (string-append "in " (perf--bytes (perf--last in)) "/s"))
            (perf--txt "perf-cool" (string-append "out " (perf--bytes (perf--last out)) "/s")))
      (perf--div "perf-chart"
        (perf--svg n ""
          (perf--hline 50)
          (perf--path (perf--path-mirror (map (lambda (v) (perf--pct v top)) in) #t) "perf-in")
          (perf--path (perf--path-mirror (map (lambda (v) (perf--pct v top)) out) #f) "perf-out"))
        (perf--txt "perf-corner perf-corner-tr" (string-append "±" (perf--bytes top) "/s")))
      (perf--div "perf-stats4"
        (perf--stat "ports" (number->string (perf--get s 'port-count 0)) "")
        (perf--stat "ets tables" (number->string (perf--get s 'ets-count 0)) "")
        (perf--stat "gc words/s" (perf--count (perf--get s 'gc-words-rate 0)) "")
        (perf--stat "atoms" (perf--count (perf--get s 'atom-count 0)) "")))))

(define (perf--core-name i normal)
  (if (< i normal)
      (string-append "s" (string-pad-left (number->string (+ i 1)) 2))
      (string-append "dc" (number->string (+ 1 (- i normal))))))

(define (perf--cores-panel s ser)
  (let* ((cores (perf--get ser 'cores '()))
         (normal (length (perf--get s 'schedulers '())))
         (hot (let loop ((cs cores) (i 0) (best 0) (bi 0))
                (if (null? cs)
                    (list bi best)
                    (let ((v (perf--last (car cs))))
                      (if (> v best) (loop (cdr cs) (+ i 1) v i) (loop (cdr cs) (+ i 1) best bi)))))))
    (perf--panel 5 "Fig. 4"
      (string-append "Per-scheduler utilisation · " (number->string normal) " normal")
      (list (perf--txt "" (string-append "hottest " (perf--core-name (car hot) normal)
                                         " · " (number->string (cadr hot)) "%")))
      (perf--div "perf-cores"
        (let loop ((cs cores) (i 0) (acc '()))
          (if (null? cs)
              (reverse acc)
              (let* ((hist (car cs))
                     (v (perf--last hist))
                     (class (perf--load-class v)))
                (loop (cdr cs) (+ i 1)
                      (cons (perf--div "perf-core"
                              (perf--svg (length hist) ""
                                (perf--path (perf--path-area hist #f) (string-append "perf-fill " class))
                                (perf--path (perf--path-line hist) (string-append "perf-stroke " class)))
                              (perf--div "perf-core-label"
                                (perf--txt "perf-stat-k" (perf--core-name i normal))
                                (perf--txt (string-append "perf-strong " class) (number->string v))))
                            acc)))))))))

;; render durations in ten bins: up to 2, 4, 8, 12, 16, 24, 33, 50, 100 ms, and past
(define *perf-bins* '(2 4 8 12 16 24 33 50 100))

(define (perf--histogram sorted)
  (let loop ((edges *perf-bins*) (xs sorted) (acc '()))
    (if (null? edges)
        (reverse (cons (length xs) acc))
        (let ((in (filter (lambda (v) (< v (car edges))) xs)))
          (loop (cdr edges)
                (filter (lambda (v) (>= v (car edges))) xs)
                (cons (length in) acc))))))

(define (perf--frame-panel sorted)
  (let* ((counts (perf--histogram sorted))
         (heights (perf--scale counts))
         (now (perf--last sorted))
         (p50 (telemetry--percentile sorted 50))
         (p95 (telemetry--percentile sorted 95))
         (p99 (telemetry--percentile sorted 99)))
    (perf--panel 3 "Fig. 5" "Render time"
      (list (perf--txt (if (> now 16) "perf-hot" "perf-ok")
                       (string-append (number->string now) " ms")))
      (perf--div "perf-histo"
        (let loop ((hs heights) (i 0) (acc '()))
          (if (null? hs)
              (reverse acc)
              (loop (cdr hs) (+ i 1)
                    (cons (list 'tag "div"
                                'class (string-append "perf-hbar "
                                                      (cond ((> i 7) "perf-fill perf-hot")
                                                            ((> i 4) "perf-fill perf-warm")
                                                            (else "perf-fill perf-cool")))
                                'attrs (list (list "style" (string-append "height:" (number->string (max 2 (car hs))) "%"))))
                          acc)))))
      (perf--div "perf-axis"
        (perf--txt "" "2 ms") (perf--txt "" "16") (perf--txt "" "33") (perf--txt "" "100+"))
      (perf--div "perf-stats3"
        (perf--stat "p50" (number->string p50) "")
        (perf--stat "p95" (number->string p95) (if (> p95 16) "perf-hot" ""))
        (perf--stat "p99" (number->string p99) (if (> p99 16) "perf-hot" ""))))))

(define (perf--heat-panel heat)
  (perf--panel 4 "Fig. 6" "Event latency · per layer"
    (list (perf--txt "" (string-append "ms · " (number->string *perf-heat-width*) " ticks")))
    (perf--div "perf-heat"
      (let loop ((layers *perf-heat-layers*) (rows heat) (acc '()))
        (if (or (null? layers) (null? rows))
            (reverse acc)
            (loop (cdr layers) (cdr rows)
                  (cons (perf--div "perf-heat-row"
                          (perf--txt "perf-heat-label" (car layers))
                          (perf--div "perf-heat-cells"
                            (map (lambda (ms) (perf--div (string-append "perf-cell " (perf--heat-class ms))))
                                 (car rows)))
                          (perf--txt "perf-heat-val" (number->string (perf--last (car rows)))))
                        acc)))))))

(define (perf--spark pid sparks)
  (let* ((hit (assoc pid (or sparks '())))
         (hist (perf--scale (if hit (cadr hit) '()))))
    (perf--svg (length hist) "perf-spark-svg"
      (perf--path (perf--path-line hist) "perf-spark"))))

(define (perf--process-row r line sparks)
  (let* ((reds (plist-get r 'reds))
         (class (perf--load-class (min 100 (quotient reds 20000)))))
    (list 'tag "div" 'class "perf-prow"
          'lines (list line line) 'mark "current"
          'click (string-append "perf:row:" (number->string line))
          'children
          (list (perf--txt "perf-dim" (plist-get r 'pid))
                (perf--txt "perf-name" (plist-get r 'name))
                (perf--txt (string-append "perf-num perf-strong " class) (perf--count reds))
                (perf--txt "perf-num" (perf--bytes (plist-get r 'memory)))
                (perf--txt (string-append "perf-num " (if (> (plist-get r 'queue) 0) "perf-warm" "perf-dim"))
                           (number->string (plist-get r 'queue)))
                (perf--txt "perf-dim" (plist-get r 'status))
                (perf--txt "perf-dim perf-current-fn" (plist-get r 'current))
                (perf--div (string-append "perf-spark-box " class) (perf--spark (plist-get r 'pid) sparks))))))

(define (perf--process-panel buf)
  (let* ((procs (or (buffer-local buf 'perf-procs) '()))
         (rows (perf--get procs 'rows '()))
         (sparks (buffer-local buf 'perf-sparks))
         (filter-text (or (buffer-local buf 'perf-filter) "")))
    (perf--panel 7 "Fig. 7"
      (string-append "Processes · sorted by " (perf--sort-name buf))
      (list (perf--txt "" (string-append (number->string (perf--get procs 'matched 0)) " of "
                                         (number->string (perf--get procs 'count 0)) " processes"))
            (perf--txt (if (equal? filter-text "") "perf-dim" "perf-strong")
                       (if (equal? filter-text "") "no filter" (string-append "filter " filter-text))))
      (perf--div "perf-prow perf-phead"
        (perf--txt "" "pid") (perf--txt "" "name") (perf--txt "perf-num" "reds/s")
        (perf--txt "perf-num" "mem") (perf--txt "perf-num" "mq") (perf--txt "" "status")
        (perf--txt "" "current") (perf--txt "" "trend"))
      (perf--div "perf-plist"
        (if (null? rows)
            (list (component 'ui/empty '(text "no process matches the filter")))
            (let loop ((rs rows) (line perf--first-row-line) (acc '()))
              (if (null? rs)
                  (reverse acc)
                  (loop (cdr rs) (+ line 1) (cons (perf--process-row (car rs) line sparks) acc)))))))))

(define (perf--disk-row d)
  (let ((pct (perf--get d 'pct 0)))
    (perf--div "perf-disk"
      (perf--txt "" (perf--clip (perf--get d 'id "") 22))
      (perf--div "perf-diskbar"
        (list 'tag "div" 'class (string-append "perf-diskfill " (perf--load-class pct))
              'attrs (list (list "style" (string-append "width:" (number->string pct) "%")))))
      (perf--txt "perf-num" (perf--bytes (* 1024 (perf--get d 'kbytes 0))))
      (perf--txt (string-append "perf-num " (perf--load-class pct)) (string-append (number->string pct) "%")))))

(define (perf--log-row row first?)
  (let ((level (or (plist-get row 'level) "info")))
    (perf--div (string-append "perf-log" (if first? " perf-log-new" ""))
      (perf--txt "perf-dim" (format-time (quotient (plist-get row 'time-ms) 1000) "%H:%M:%S"))
      (perf--txt (string-append "perf-lvl " (perf--level-class level)) level)
      (perf--txt "perf-log-msg" (plist-get row 'text)))))

(define (perf--count-level rows level)
  (length (filter (lambda (r) (equal? (plist-get r 'level) level)) rows)))

(define (perf--storage-panel s)
  (let* ((disks (perf--get (perf--get s 'os '()) 'disks '()))
         (logs (last-n (messages-events) *perf-log-rows*))
         (newest (reverse logs)))
    (perf--panel 5 "Fig. 8" "Storage & messages"
      (list (perf--txt "" (string-append (number->string (length disks)) " volumes")))
      (perf--div "perf-disks"
        (if (null? disks)
            (list (component 'ui/empty '(text "os_mon reports no volumes")))
            (map perf--disk-row disks)))
      (perf--div "perf-head perf-head-inner"
        (perf--txt "perf-fig" "Fig. 9") (perf--txt "" "Messages") (perf--txt "perf-spacer" "")
        (perf--txt "perf-hot" (string-append (number->string (perf--count-level logs "error")) " err"))
        (perf--txt "perf-warm" (string-append (number->string (perf--count-level logs "warn")) " warn")))
      (perf--div "perf-logs"
        (let loop ((ls newest) (first? #t) (acc '()))
          (if (null? ls)
              (reverse acc)
              (loop (cdr ls) #f (cons (perf--log-row (car ls) first?) acc))))))))

(define (perf--state-class util)
  (cond ((> util 80) (list "degraded" "perf-hot"))
        ((> util 50) (list "under load" "perf-warm"))
        (else (list "nominal" "perf-ok"))))

(define (perf--header buf s)
  (let* ((os (perf--get s 'os '()))
         (state (perf--state-class (perf--get s 'sched-util 0))))
    (perf--div "perf-bar perf-top"
      (perf--txt "perf-strong perf-brand" "Compos")
      (perf--txt "" (string-append "system monitor · buffer " *perf-buffer*))
      (perf--txt "perf-dim"
                 (string-append "host " (perf--get s 'host "") " · "
                                (number->string (length (perf--get s 'schedulers '()))) " schedulers · "
                                (number->string (perf--get s 'logical-processors 0)) " cpus · "
                                (perf--bytes (perf--get (perf--get s 'memory '()) 'total 0)) " vm"))
      (perf--txt "perf-spacer" "")
      (perf--txt "" (string-append "up " (perf--uptime (perf--get s 'uptime-ms 0))))
      (perf--div "" (perf--txt "" "load ")
                    (perf--txt "perf-strong" (perf--get os 'load1 "0.00"))
                    (perf--txt "" (string-append " " (perf--get os 'load5 "0.00") " " (perf--get os 'load15 "0.00"))))
      (perf--txt (string-append "perf-state " (cadr state)) (car state))
      (perf--txt "perf-dim" (format-time (current-time) "%H:%M:%S")))))

(define (perf--count-blocks blocks)
  (fold (lambda (acc b) (+ acc 1 (perf--count-blocks (perf--get b 'children '()))))
        0 blocks))

(define (perf--footer buf s render-ms cells)
  (perf--div "perf-bar perf-bottom"
    (perf--txt "perf-strong" *perf-buffer*)
    (perf--txt "" "g refresh") (perf--txt "" "/ filter") (perf--txt "" "s sort")
    (perf--txt "" "RET info") (perf--txt "" "k kill") (perf--txt "" "SPC pause") (perf--txt "" "t text")
    (perf--txt "perf-spacer" "")
    (perf--txt (if (buffer-local buf 'perf-paused) "perf-warm" "perf-dim")
               (if (buffer-local buf 'perf-paused) "paused" (string-append "tick " (number->string (or (buffer-local buf 'perf-tick) 0)))))
    (perf--txt "" (string-append "render " (number->string render-ms) " ms"))
    (perf--txt "" (string-append (number->string cells) " live cells"))
    (perf--txt "" (string-append "otp " (perf--get s 'otp "")))))

(define (perf--blocks buf)
  (let* ((s (or (buffer-local buf 'perf-sample) '()))
         (ser (or (buffer-local buf 'perf-series) '()))
         (sorted (or (buffer-local buf 'perf-render-ms) '()))
         (render-ms (if (null? sorted) 0 (car (reverse sorted))))
         (panels (list (perf--cpu-panel s ser)
                       (perf--memory-panel s)
                       (perf--io-panel s ser)
                       (perf--cores-panel s ser)
                       (perf--frame-panel sorted)
                       (perf--heat-panel (or (buffer-local buf 'perf-heat) '()))
                       (perf--process-panel buf)
                       (perf--storage-panel s))))
    (list (perf--div "perf-root"
            (perf--header buf s)
            (perf--div "perf-grid" panels)
            (perf--footer buf s render-ms (perf--count-blocks panels))))))

;;; --- the tick ---------------------------------------------------------------------

(define (perf--render! buf)
  (perf--replace-text! buf (perf--text buf))
  (buffer-set-local! buf 'perf-rows (perf--rows buf))
  (buffer-set-local! buf 'render-blocks (perf--blocks buf)))

(define (perf--refresh! buf)
  (perf--sample! buf)
  (perf--render! buf))

(define (perf--arm! buf ms)
  (debounce! (string-append "perf-tick:" buf) ms perf--tick buf))

(define (perf--tick buf)
  (when (buffer-exists? buf)
    (if (and (window-showing buf) (not (buffer-local buf 'perf-paused)))
        (begin
          (perf--refresh! buf)
          (perf--arm! buf perf-tick-ms))
        (perf--arm! buf (* 5 perf-tick-ms)))))

;; a window that starts to show the buffer gets a sample now, not after
;; the slow hidden interval
(define (perf--shown-hook!)
  (when (and (buffer-exists? *perf-buffer*)
             (window-showing *perf-buffer*)
             (not (buffer-local *perf-buffer* 'perf-paused))
             (buffer-mode-is? *perf-buffer* "perf-mode"))
    (perf--arm! *perf-buffer* 0)))

(add-hook! 'window-configuration-change-hook 'perf--shown-hook!)

;;; --- the mode ------------------------------------------------------------------------

(define *perf-runtime-locals*
  '(render-blocks perf-sample perf-procs perf-series perf-heat perf-heat-since
    perf-sparks perf-render-ms perf-tick perf-rows))

(define (perf--setup! buf)
  (buffer-set-read-only! buf #t)
  (buffer-set-local! buf 'render-mode "blocks")
  (for-each (lambda (k) (desktop-skip! buf k)) *perf-runtime-locals*)
  (unless (buffer-local buf 'perf-sort)
    (buffer-set-local! buf 'perf-sort "reds"))
  (perf--refresh! buf)
  (perf--arm! buf perf-tick-ms))

(mode-icon! "perf-mode" "")

(define-mode "perf-mode"
  (lambda () (perf--setup! (current-buffer))))

(mode-keys! "perf-mode"
  '(("g" "perf-refresh")
    ("/" "perf-filter")
    ("s" "perf-sort")
    ("RET" "perf-process-info")
    ("k" "perf-process-kill")
    ("SPC" "perf-pause")
    ("t" "perf-toggle-text")
    ("n" "next-line")
    ("p" "previous-line")
    ("q" "quit-window")))

(mode-doc! "perf-mode"
  "The system monitor. Schedulers, memory, port IO, render time, event latency, the process table, volumes, and messages, sampled every perf-tick-ms. `/` filters the table, `s` cycles the sort, RET shows a process, `k` kills it after confirmation, SPC pauses.")

(on-block-click! 'perf
  (lambda (buf id)
    (and (buffer-mode-is? buf "perf-mode")
         (string-prefix? "perf:row:" id)
         (let ((line (string->number (substring id 9 (string-length id)))))
           (when (number? line)
             (with-current-buffer buf
               (lambda () (goto-char! (line-start-position line)))))
           #t))))

(register-context-provider! "perf-mode"
  (lambda (buf)
    (string-append "The system monitor " buf
                   " is open. Its text is a table of the busiest processes; "
                   "read the buffer for the numbers.")))

;;; --- commands -------------------------------------------------------------------------

(effects! '(read display))

(define-command "perf" "Show the system monitor: schedulers, memory, IO, processes, telemetry"
  (lambda ()
    (buffer-create *perf-buffer*)
    (switch-to-buffer! *perf-buffer*)
    (unless (buffer-mode-is? *perf-buffer* "perf-mode")
      (set-mode! "perf-mode"))))

(define-command "perf-refresh" "Sample the VM now"
  (lambda () (perf--refresh! (current-buffer))))

(define-command "perf-filter" "Show only the processes whose name or pid contains a string"
  (lambda ()
    (let ((buf (current-buffer)))
      (read-string "Filter processes: "
        (lambda (text)
          (buffer-set-local! buf 'perf-filter (string-trim text))
          (perf--refresh! buf))))))

(define (perf--sort-next current)
  (let loop ((xs *perf-sorts*))
    (cond ((null? xs) (car *perf-sorts*))
          ((equal? (car xs) current)
           (if (null? (cdr xs)) (car *perf-sorts*) (cadr xs)))
          (else (loop (cdr xs))))))

(define-command "perf-sort" "Cycle the process sort: reductions, memory, queue, name"
  (lambda ()
    (let* ((buf (current-buffer))
           (next (perf--sort-next (perf--sort-name buf))))
      (buffer-set-local! buf 'perf-sort next)
      (perf--refresh! buf)
      (message (string-append "sorted by " next)))))

(define-command "perf-toggle-text" "Show the monitor as its plain text table, or as the panels again"
  (lambda ()
    (let* ((buf (current-buffer))
           (text? (equal? (buffer-local buf 'render-mode) "text")))
      (buffer-set-local! buf 'render-mode (if text? "blocks" "text"))
      (message (if text? "perf panels" "perf text")))))

(define-command "perf-pause" "Pause or resume the samples"
  (lambda ()
    (let* ((buf (current-buffer))
           (paused (not (buffer-local buf 'perf-paused))))
      (buffer-set-local! buf 'perf-paused paused)
      (if paused
          (perf--render! buf)
          (perf--arm! buf 0))
      (message (if paused "perf paused" "perf resumed")))))

;;; --- one process ------------------------------------------------------------------------

(define (perf--info-buffer pid)
  (string-append "*perf: " pid "*"))

(define (perf--info-text info)
  (let ((row (lambda (k v) (string-append (string-pad-right k 16) v "\n"))))
    (string-append
      (row "pid" (perf--get info 'pid ""))
      (row "name" (perf--get info 'name ""))
      (row "registered" (perf--get info 'registered ""))
      (row "initial call" (perf--get info 'initial-call ""))
      (row "current" (perf--get info 'current ""))
      (row "status" (perf--get info 'status ""))
      (row "priority" (perf--get info 'priority ""))
      (row "trap exit" (if (perf--get info 'trap-exit #f) "yes" "no"))
      (row "reductions" (number->string (perf--get info 'reductions 0)))
      (row "memory" (perf--bytes (perf--get info 'memory 0)))
      (row "heap words" (number->string (perf--get info 'heap-words 0)))
      (row "total heap" (number->string (perf--get info 'total-heap-words 0)))
      (row "stack words" (number->string (perf--get info 'stack-words 0)))
      (row "minor gcs" (number->string (perf--get info 'minor-gcs 0)))
      (row "links" (number->string (perf--get info 'links 0)))
      (row "monitors" (number->string (perf--get info 'monitors 0)))
      (row "monitored by" (number->string (perf--get info 'monitored-by 0)))
      (row "group leader" (perf--get info 'group-leader ""))
      (row "ancestors" (string-join (perf--get info 'ancestors '()) " < "))
      (row "queue" (number->string (perf--get info 'queue 0)))
      "\nfirst messages\n"
      (apply string-append
             (map (lambda (m) (string-append "  " m "\n")) (perf--get info 'messages '()))))))

(define (perf--show-info! pid)
  (let ((info (vm-process-info pid))
        (buf (perf--info-buffer pid)))
    (if (not info)
        (message (string-append "process " pid " is gone"))
        (begin
          (buffer-create buf)
          (buffer-set-read-only! buf #f)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf (perf--info-text info))
          (buffer-set-read-only! buf #t)
          (with-current-buffer buf (lambda () (set-mode! "perf-info-mode")))
          (display-buffer-other-window! buf)))))

(define-mode "perf-info-mode"
  (lambda () (buffer-set-read-only! (current-buffer) #t)))

(mode-keys! "perf-info-mode" '(("q" "quit-window")))

(mode-doc! "perf-info-mode" "One process, every field Process.info reports.")

(define-command "perf-process-info" "Show the process on this row"
  (lambda ()
    (let ((row (perf--row-at-point (current-buffer))))
      (if row
          (perf--show-info! (cadr row))
          (message "no process on this line")))))

(effects! '(destroy))

(define-command "perf-process-kill" "Kill the process on this row after confirmation"
  (lambda ()
    (let* ((buf (current-buffer))
           (row (perf--row-at-point buf)))
      (if (not row)
          (message "no process on this line")
          (y-or-n-p (string-append "Kill " (nth 2 row) " " (cadr row) "? ")
            (lambda (yes?)
              (when yes?
                (if (vm-process-kill! (cadr row))
                    (message (string-append "killed " (cadr row)))
                    (message (string-append (cadr row) " was already gone")))
                (perf--refresh! buf))))))))

(effects! '(read))

;;; --- the look ---------------------------------------------------------------------------
;;; The palette is four faces a theme can rename. Every colour in the CSS
;;; reads a face variable with a fallback, so a theme that says nothing
;;; still gets a readable chart.

(defface! 'perf-indigo 'fg "#3b5bb5")
(defface! 'perf-amber 'fg "#b07a2a")
(defface! 'perf-red 'fg "#c24a3a")
(defface! 'perf-green 'fg "#3a8a58")

(define-style! 'perf "
.perf-root { font-family: var(--font-mono); font-size: 11px; color: var(--default-fg); -webkit-font-smoothing: antialiased; }
.perf-bar { display: flex; align-items: center; gap: 16px; padding: 5px 10px; font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: var(--dim-fg); white-space: nowrap; overflow: hidden; }
.perf-top { border-bottom: 1px solid var(--border-bg); }
.perf-bottom { border-top: 1px solid var(--border-bg); }
.perf-brand { letter-spacing: .2em; }
.perf-spacer { flex: 1; }
.perf-strong { color: var(--default-fg); font-weight: 600; }
.perf-dim { color: var(--dim-fg); }
.perf-state { padding: 2px 8px; border: 1px solid var(--border-bg); font-weight: 600; }
.perf-grid { display: grid; grid-template-columns: repeat(12, minmax(0, 1fr)); grid-auto-rows: minmax(200px, auto); gap: 1px; background: var(--border-bg); border: 1px solid var(--border-bg); }
.perf-panel { background: var(--default-bg, transparent); display: flex; flex-direction: column; min-width: 0; overflow: hidden; }
.perf-c3 { grid-column: span 3; } .perf-c4 { grid-column: span 4; } .perf-c5 { grid-column: span 5; } .perf-c7 { grid-column: span 7; }
.perf-head { display: flex; align-items: baseline; gap: 10px; padding: 5px 10px; border-bottom: 1px solid var(--border-bg); font-size: 9.5px; letter-spacing: .16em; text-transform: uppercase; color: var(--dim-fg); white-space: nowrap; }
.perf-head-inner { border-top: 1px solid var(--border-bg); }
.perf-head-right { display: flex; gap: 10px; }
.perf-fig { color: var(--default-fg); font-weight: 600; }
.perf-legend { display: flex; align-items: center; gap: 4px; }
.perf-swatch { width: 7px; height: 7px; display: inline-block; flex: none; }
.perf-sw-user { background: var(--perf-indigo-fg, #3b5bb5); }
.perf-sw-sys { background: var(--perf-amber-fg, #b07a2a); }
.perf-sw-io { background: var(--perf-red-fg, #c24a3a); }
.perf-sw-line { background: var(--default-fg); }
.perf-sw-soft { background: color-mix(in srgb, var(--perf-indigo-fg, #3b5bb5) 55%, transparent); }
.perf-sw-sand { background: color-mix(in srgb, var(--perf-amber-fg, #b07a2a) 40%, transparent); }
.perf-sw-dim { background: var(--hl-line-bg); }
.perf-body-row { flex: 1; display: flex; min-height: 0; }
.perf-chart { flex: 1; position: relative; min-width: 0; min-height: 110px; }
.perf-svg { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
.perf-rule { stroke: var(--border-bg); stroke-width: 1; vector-effect: non-scaling-stroke; }
.perf-user { fill: var(--perf-indigo-fg, #3b5bb5); fill-opacity: .85; }
.perf-sys { fill: var(--perf-amber-fg, #b07a2a); fill-opacity: .85; }
.perf-io { fill: var(--perf-red-fg, #c24a3a); fill-opacity: .85; }
.perf-in { fill: var(--perf-green-fg, #3a8a58); fill-opacity: .7; }
.perf-out { fill: var(--perf-indigo-fg, #3b5bb5); fill-opacity: .7; }
.perf-line { fill: none; stroke: var(--default-fg); stroke-width: 1; vector-effect: non-scaling-stroke; }
.perf-fill.perf-hot { fill: var(--perf-red-fg, #c24a3a); fill-opacity: .5; }
.perf-fill.perf-warm { fill: var(--perf-amber-fg, #b07a2a); fill-opacity: .5; }
.perf-fill.perf-cool { fill: var(--perf-indigo-fg, #3b5bb5); fill-opacity: .5; }
.perf-fill.perf-idle { fill: var(--dim-fg); fill-opacity: .35; }
.perf-stroke { fill: none; stroke-width: 1; vector-effect: non-scaling-stroke; }
.perf-stroke.perf-hot { stroke: var(--perf-red-fg, #c24a3a); }
.perf-stroke.perf-warm { stroke: var(--perf-amber-fg, #b07a2a); }
.perf-stroke.perf-cool { stroke: var(--perf-indigo-fg, #3b5bb5); }
.perf-stroke.perf-idle { stroke: var(--dim-fg); }
span.perf-hot { color: var(--perf-red-fg, #c24a3a); }
span.perf-warm { color: var(--perf-amber-fg, #b07a2a); }
span.perf-cool { color: var(--perf-indigo-fg, #3b5bb5); }
span.perf-ok { color: var(--perf-green-fg, #3a8a58); }
span.perf-idle { color: var(--dim-fg); }
.perf-corner { position: absolute; font-size: 9px; color: var(--dim-fg); }
.perf-corner-tl { left: 6px; top: 4px; } .perf-corner-bl { left: 6px; bottom: 3px; } .perf-corner-tr { right: 6px; top: 3px; }
.perf-side { flex: 0 0 150px; padding: 6px 10px; display: flex; flex-direction: column; gap: 3px; border-left: 1px solid var(--border-bg); overflow: hidden; }
.perf-big { font-family: var(--font-serif); font-size: 30px; line-height: .9; letter-spacing: -1.5px; font-weight: 300; margin-bottom: 4px; }
.perf-unit { font-size: 16px; color: var(--dim-fg); }
.perf-stat { display: flex; align-items: baseline; gap: 8px; font-size: 10px; border-bottom: 1px dotted var(--border-bg); padding-bottom: 2px; }
.perf-stat-k { color: var(--dim-fg); flex: 1; letter-spacing: .08em; text-transform: uppercase; font-size: 9px; }
.perf-stat-v { font-weight: 500; }
.perf-stats3, .perf-stats4 { display: grid; border-top: 1px solid var(--border-bg); }
.perf-stats3 { grid-template-columns: repeat(3, minmax(0, 1fr)); } .perf-stats4 { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.perf-stats3 .perf-stat, .perf-stats4 .perf-stat { flex-direction: column; gap: 0; padding: 4px 9px; border-bottom: 0; border-right: 1px solid var(--border-bg); }
.perf-stats3 .perf-stat-v, .perf-stats4 .perf-stat-v { font-size: 13px; }
.perf-rings { display: flex; justify-content: space-around; padding: 8px 10px 4px; }
.perf-ring { display: flex; flex-direction: column; align-items: center; gap: 3px; }
.perf-ring-box { position: relative; width: 62px; height: 62px; }
.perf-ring-svg { width: 62px; height: 62px; display: block; transform: rotate(-90deg); }
.perf-ring-track { fill: none; stroke: var(--hl-line-bg); stroke-width: 5; }
.perf-ring-arc { fill: none; stroke-width: 5; }
.perf-ring-arc.perf-user { stroke: var(--perf-indigo-fg, #3b5bb5); } .perf-ring-arc.perf-sys { stroke: var(--perf-amber-fg, #b07a2a); }
.perf-ring-arc.perf-io { stroke: var(--perf-red-fg, #c24a3a); } .perf-ring-arc.perf-ok { stroke: var(--perf-green-fg, #3a8a58); }
.perf-ring-pct { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: 600; }
.perf-ring-label { font-size: 9px; letter-spacing: .12em; text-transform: uppercase; color: var(--dim-fg); }
.perf-ring-sub { font-size: 9.5px; color: var(--dim-fg); }
.perf-segbar { display: flex; height: 12px; margin: 2px 10px; border: 1px solid var(--border-bg); overflow: hidden; }
.perf-seg { height: 100%; }
.perf-seglist { padding: 0 10px 6px; display: flex; flex-direction: column; gap: 3px; font-size: 10px; }
.perf-segrow { display: flex; align-items: center; gap: 7px; }
.perf-cores { flex: 1; min-height: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); grid-auto-rows: minmax(44px, 1fr); }
.perf-core { position: relative; border-right: 1px solid var(--border-bg); border-bottom: 1px solid var(--border-bg); padding: 2px 4px; min-width: 0; overflow: hidden; }
.perf-core-label { position: relative; display: flex; justify-content: space-between; font-size: 9px; }
.perf-histo { flex: 1; min-height: 90px; display: flex; align-items: flex-end; gap: 1px; padding: 8px 10px 4px; }
.perf-hbar { flex: 1; min-width: 0; }
.perf-hbar.perf-fill.perf-hot { background: var(--perf-red-fg, #c24a3a); } .perf-hbar.perf-fill.perf-warm { background: var(--perf-amber-fg, #b07a2a); } .perf-hbar.perf-fill.perf-cool { background: var(--perf-indigo-fg, #3b5bb5); }
.perf-axis { display: flex; justify-content: space-between; padding: 0 10px 4px; font-size: 9px; color: var(--dim-fg); }
.perf-heat { flex: 1; min-height: 0; display: flex; flex-direction: column; padding: 6px 10px; gap: 3px; }
.perf-heat-row { flex: 1; display: flex; align-items: center; gap: 6px; min-height: 18px; }
.perf-heat-label { flex: 0 0 54px; font-size: 9px; color: var(--dim-fg); text-align: right; }
.perf-heat-cells { flex: 1; display: flex; gap: 1px; height: 100%; min-width: 0; }
.perf-cell { flex: 1; min-width: 0; }
.perf-h0 { background: var(--hl-line-bg); }
.perf-h1 { background: color-mix(in srgb, var(--perf-indigo-fg, #3b5bb5) 25%, transparent); }
.perf-h2 { background: color-mix(in srgb, var(--perf-indigo-fg, #3b5bb5) 50%, transparent); }
.perf-h3 { background: color-mix(in srgb, var(--perf-amber-fg, #b07a2a) 60%, transparent); }
.perf-h4 { background: color-mix(in srgb, var(--perf-red-fg, #c24a3a) 65%, transparent); }
.perf-h5 { background: var(--perf-red-fg, #c24a3a); }
.perf-heat-val { flex: 0 0 32px; font-size: 9px; text-align: right; }
.perf-plist { flex: 1; min-height: 0; overflow-y: auto; }
.perf-prow { display: grid; grid-template-columns: 78px minmax(0, 1.4fr) 62px 66px 34px 56px minmax(0, 1fr) 80px; gap: 8px; align-items: center; padding: 2px 10px; border-bottom: 1px dotted var(--border-bg); font-size: 10.5px; cursor: pointer; }
.perf-prow > span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.perf-prow.current { background: var(--hl-line-bg); }
.perf-phead { font-size: 9px; letter-spacing: .12em; text-transform: uppercase; color: var(--dim-fg); border-bottom: 1px solid var(--border-bg); cursor: default; }
.perf-name { color: var(--default-fg); }
.perf-num { text-align: right; }
.perf-current-fn { font-size: 9.5px; }
.perf-spark-box { height: 14px; }
.perf-spark-svg { position: static; width: 100%; height: 14px; }
.perf-spark { fill: none; stroke-width: 1; vector-effect: non-scaling-stroke; stroke: var(--dim-fg); }
.perf-spark-box.perf-hot .perf-spark { stroke: var(--perf-red-fg, #c24a3a); } .perf-spark-box.perf-warm .perf-spark { stroke: var(--perf-amber-fg, #b07a2a); } .perf-spark-box.perf-cool .perf-spark { stroke: var(--perf-indigo-fg, #3b5bb5); }
.perf-disks { flex: none; }
.perf-disk { display: grid; grid-template-columns: 150px 1fr 70px 44px; gap: 8px; align-items: center; padding: 3px 10px; border-bottom: 1px dotted var(--border-bg); font-size: 10px; }
.perf-diskbar { height: 8px; border: 1px solid var(--border-bg); background: var(--hl-line-bg); }
.perf-diskfill { height: 100%; }
.perf-diskfill.perf-hot { background: var(--perf-red-fg, #c24a3a); } .perf-diskfill.perf-warm { background: var(--perf-amber-fg, #b07a2a); } .perf-diskfill.perf-cool { background: var(--perf-indigo-fg, #3b5bb5); } .perf-diskfill.perf-idle { background: var(--perf-green-fg, #3a8a58); }
.perf-logs { flex: 1; min-height: 0; overflow-y: auto; padding: 2px 0; }
.perf-log { display: flex; gap: 8px; padding: 1.5px 10px; font-size: 10px; }
.perf-log-new { background: var(--hl-line-bg); }
.perf-lvl { flex: none; width: 38px; font-size: 9px; letter-spacing: .1em; text-transform: uppercase; font-weight: 600; }
.perf-log-msg { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
")

(define (perf-refresh! buf) (perf--refresh! buf))

;;; --- the public API -------------------------------------------------------------------
;;; The vm-* primitives come from Elixir; this is where the catalog learns
;;; their domain and effects. public! takes the domain from the category.

(category! 'diagnostics)
(effects! '(read))
(public! 'vm-sample
  "(vm-sample) — one plist of VM and host counters: scheduler utilization, memory, rates since the previous sample, os_mon load, memory and disks")
(public! 'vm-processes
  "(vm-processes LIMIT SORT FILTER) — plist (rows count matched): at most LIMIT process rows whose name or pid contains FILTER, sorted by \"reds\", \"memory\", \"queue\" or \"name\"")
(public! 'vm-process-info
  "(vm-process-info PID) — a plist of one process's state, or #f when the pid is gone")
(public! 'perf-refresh!
  "(perf-refresh! BUF) — sample the VM and redraw the monitor in BUF")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'diagnostics 'effects '(read)))
  '("vm-sample" "vm-processes" "vm-process-info" "perf-refresh!"))

(effects! '(destroy))
(public! 'vm-process-kill!
  "(vm-process-kill! PID) — exit the process with reason kill; #t when it was alive")
(catalog-meta! 'function "vm-process-kill!" 'domain 'diagnostics 'effects '(destroy))
(effects! '(read))
