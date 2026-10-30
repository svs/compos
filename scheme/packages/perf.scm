;;; perf.scm --- the system monitor: lane contention, live, in one buffer.
;;;
;;; The *perf* buffer draws two panels. The first holds every lane the telemetry stamped a
;;; job on in the last *perf-lane-window-ms*, the lane that waited longest
;;; first. Wait is the time a job sat queued behind the lane's earlier
;;; jobs, so a lane with wait is a lane with contention. The second is
;;; the host memory in use and the apps that hold the most of it.
;;;
;;; The buffer text is a plain table of the same numbers, for a reader
;;; without the blocks view.
;;;
;;; The tick is one debounce that re-arms itself. A hidden buffer ticks
;;; five times slower and samples nothing; a shown buffer samples every
;;; perf-tick-ms. A killed buffer ends the chain.

(require 'format)

(domain! 'diagnostics)
(effects! '(read))

(define *perf-buffer* "*perf*")

(defcustom 'perf-tick-ms 2000
  "Milliseconds between two samples of a shown *perf* buffer. Every sample is one patch to the browser."
  'group 'perf 'type 'number)

(define *perf-lane-window-ms* 30000)

;;; --- small helpers ------------------------------------------------------------

;; plist-get that answers FALLBACK for a missing key or a #f plist
(define (perf--get pl key &optional fallback)
  (let loop ((xs (if (pair? pl) pl '())))
    (cond ((null? xs) fallback)
          ((null? (cdr xs)) fallback)
          ((equal? (car xs) key) (cadr xs))
          (else (loop (cdr (cdr xs)))))))

;; bytes in the binary units the VM counts in; a tenth only above a
;; gibibyte, where a whole unit is too coarse
(define (perf--bytes b)
  (format-bytes b 'iec (if (>= b 1073741824) 1 0)))

(define (perf--clip s n)
  (if (> (string-length s) n) (substring s 0 n) s))

(define (perf--line-count text)
  (length (string-split text "\n")))

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

;; the face a wait wears: red past a quarter second, amber past 50 ms
(define (perf--wait-class ms)
  (cond ((>= ms 250) "perf-hot")
        ((>= ms 50) "perf-warm")
        ((> ms 0) "perf-strong")
        (else "perf-dim")))

;;; --- the lanes --------------------------------------------------------------------

(define (perf--newest-time events)
  (fold (lambda (m r) (max m (plist-get r 'time-ms))) 0 events))

(define (perf--lane-name owner)
  (cond ((equal? owner ":ui") "ui")
        ((string-prefix? "{:rpc" owner) "rpc")
        (else (let ((parts (string-split owner "\"")))
                (if (>= (length parts) 2) (cadr parts) owner)))))

;; (NAME JOBS BUSY WAIT-MAX WAIT-SUM BACKLOG-MAX SLOWEST SLOWEST-LABEL) per
;; lane, the most wait first, then the most busy
(define (perf--lanes events)
  (let* ((now (perf--newest-time events))
         (fresh (filter (lambda (r) (and (equal? (plist-get r 'kind) "lane")
                                         (> (plist-get r 'time-ms) (- now *perf-lane-window-ms*))))
                        events))
         (acc (fold (lambda (acc r)
                      (let* ((name (perf--lane-name (or (plist-get r 'owner) "")))
                             (old (or (alist-get acc name) '(0 0 0 0 0 0 "")))
                             (ms (or (plist-get r 'duration-ms) 0))
                             (q (or (plist-get r 'queue-ms) 0)))
                        (alist-put acc name
                          (list (+ 1 (list-ref old 0)) (+ ms (list-ref old 1))
                                (max q (list-ref old 2)) (+ q (list-ref old 3))
                                (max (or (plist-get r 'backlog) 0) (list-ref old 4))
                                (max ms (list-ref old 5))
                                (if (> ms (list-ref old 5)) (or (plist-get r 'label) "") (list-ref old 6))))))
                    '() fresh)))
    (map cdr (sort (map (lambda (e) (cons (list (- (list-ref (cadr e) 3)) (- (list-ref (cadr e) 1)))
                                          (cons (car e) (cadr e))))
                        acc)))))

(define (perf--sample! buf)
  (let* ((s (vm-sample))
         (os (perf--get s 'os '())))
    (buffer-set-locals! buf
      (list 'perf-lanes (perf--lanes (telemetry-events 1000))
            'perf-mem (list (perf--get os 'mem-total 0) (perf--get os 'mem-free 0)
                            (perf--get (perf--get s 'memory '()) 'total 0))
            'perf-tick (+ 1 (or (buffer-local buf 'perf-tick) 0))))))

;;; --- the apps ----------------------------------------------------------------------
;;; ps lists every host process with its resident memory; the processes of
;;; one .app bundle, its helpers included, count as one app.

(define *perf-app-rows* 12)

(define (perf--app-name comm)
  (let* ((outer (car (string-split comm ".app/")))
         (parts (string-split outer "/")))
    (car (reverse parts))))

;; (NAME KIB PROCESSES) for the apps holding the most memory, most first
(define (perf--apps ps-out)
  (let ((acc (fold (lambda (acc line)
                     (let* ((words (string-split (string-trim line) " "))
                            (kib (and (pair? words) (string->number (car words)))))
                       (if (and kib (pair? (cdr words)))
                           (let* ((name (perf--app-name (string-join (cdr words) " ")))
                                  (old (or (alist-get acc name) '(0 0))))
                             (alist-put acc name (list (+ kib (car old)) (+ 1 (cadr old)))))
                           acc)))
                   '() (string-split ps-out "\n"))))
    (let ((rows (map cdr (sort (map (lambda (e) (cons (- (car (cadr e))) (cons (car e) (cadr e)))) acc)))))
      (if (> (length rows) *perf-app-rows*) (list-head rows *perf-app-rows*) rows))))

;; ps runs off the lane; its answer lands in the buffer and redraws it.
;; One run at a time: a tick that finds one in flight skips its own.
(define (perf--sample-apps! buf)
  (unless (buffer-local buf 'perf-ps-busy)
    (buffer-set-local! buf 'perf-ps-busy #t)
    (shell-command->string "ps -axo rss=,comm=" "/"
      (lambda (out)
        (when (buffer-exists? buf)
          (buffer-set-locals! buf (list 'perf-apps (perf--apps out) 'perf-ps-busy #f))
          (perf--render! buf))))))

;;; --- the text ----------------------------------------------------------------------

(define (perf--lane-text r)
  (string-append
    (string-pad-right (perf--clip (list-ref r 0) 38) 40)
    (string-pad-left (number->string (list-ref r 1)) 6)
    (string-pad-left (number->string (list-ref r 2)) 8)
    (string-pad-left (number->string (list-ref r 3)) 10)
    (string-pad-left (number->string (list-ref r 4)) 10)
    (string-pad-left (number->string (list-ref r 5)) 9)
    "  " (number->string (list-ref r 6)) " ms " (list-ref r 7) "\n"))

(define (perf--text buf)
  (string-append
    "*perf*  lanes, last " (number->string (quotient *perf-lane-window-ms* 1000)) " s"
    "  tick " (number->string (or (buffer-local buf 'perf-tick) 0))
    (if (buffer-local buf 'perf-paused) "  paused" "") "\n"
    "\n"
    (string-pad-right "LANE" 40) (string-pad-left "JOBS" 6) (string-pad-left "BUSY" 8)
    (string-pad-left "WAIT MAX" 10) (string-pad-left "WAIT SUM" 10) (string-pad-left "BACKLOG" 9)
    "  SLOWEST\n"
    (apply string-append (map perf--lane-text (or (buffer-local buf 'perf-lanes) '())))
    "\n" (perf--mem-summary buf) "\n\n"
    (string-pad-right "APP" 40) (string-pad-left "PROCS" 6) (string-pad-left "MEMORY" 12) "\n"
    (apply string-append
           (map (lambda (r) (string-append (string-pad-right (perf--clip (car r) 38) 40)
                                           (string-pad-left (number->string (caddr r)) 6)
                                           (string-pad-left (perf--bytes (* 1024 (cadr r))) 12) "\n"))
                (or (buffer-local buf 'perf-apps) '())))))

;; "used 20 GiB of 24 GiB · 84% · compos 697 MiB"
(define (perf--mem-summary buf)
  (let* ((m (or (buffer-local buf 'perf-mem) '(0 0 0)))
         (total (car m))
         (used (max 0 (- total (cadr m)))))
    (string-append "memory used " (perf--bytes used) " of " (perf--bytes total)
                   " · " (format-percent used (max 1 total))
                   " · compos " (perf--bytes (caddr m)))))

;; rewrite the text in one change; point stays on its line. The write is
;; programmatic: buffer-replace-range! bypasses read-only, so the flag does
;; not flip off and on (two more patches, and a caret the client took).
(define (perf--replace-text! buf text)
  (let* ((line (car (buffer-line-at-point buf)))
         (last (perf--line-count text))
         (want (max 1 (min line last))))
    (buffer-replace-range! buf 0 (buffer-size buf) text)
    (unless (= (car (buffer-line-at-point buf)) want)
      (with-current-buffer buf
        (lambda () (goto-char! (line-start-position want)))))))

;;; --- the panel ---------------------------------------------------------------------

(define (perf--lane-row r)
  (let ((busy (list-ref r 2)) (wait-max (list-ref r 3)) (wait-sum (list-ref r 4)))
    (perf--div "perf-lrow"
      (perf--txt "perf-name" (list-ref r 0))
      (perf--txt "perf-num" (number->string (list-ref r 1)))
      (perf--txt "perf-num perf-strong" (number->string busy))
      (perf--txt "perf-num" (number->string (quotient (* 100 busy) *perf-lane-window-ms*)))
      (perf--txt (string-append "perf-num " (perf--wait-class wait-max)) (number->string wait-max))
      (perf--txt (string-append "perf-num " (perf--wait-class wait-sum)) (number->string wait-sum))
      (perf--txt "perf-num" (number->string (list-ref r 5)))
      (perf--txt "perf-dim" (string-append (number->string (list-ref r 6)) " ms · " (list-ref r 7))))))

(define (perf--lanes-panel lanes)
  (perf--div "perf-panel"
    (perf--div "perf-head"
      (perf--txt "perf-strong" "Lanes · contention")
      (perf--txt "perf-spacer" "")
      (perf--txt "" (string-append "ms · last " (number->string (quotient *perf-lane-window-ms* 1000)) " s")))
    (perf--div "perf-lrow perf-phead"
      (perf--txt "" "lane") (perf--txt "perf-num" "jobs") (perf--txt "perf-num" "busy")
      (perf--txt "perf-num" "busy %") (perf--txt "perf-num" "wait max") (perf--txt "perf-num" "wait sum")
      (perf--txt "perf-num" "backlog") (perf--txt "" "slowest job"))
    (perf--div "perf-list"
      (if (null? lanes)
          (list (component 'ui/empty '(text "no lane jobs in the window")))
          (map perf--lane-row lanes)))))

(define (perf--pct part whole)
  (if (> whole 0) (min 100 (quotient (* 100 part) whole)) 0))

(define (perf--meter pct class)
  (perf--div "perf-meter"
    (list 'tag "div" 'class (string-append "perf-meter-fill " class)
          'attrs (list (list "style" (string-append "width:" (number->string pct) "%"))))))

(define (perf--app-row r total-kib)
  (let ((pct (perf--pct (cadr r) total-kib)))
    (perf--div "perf-arow"
      (perf--txt "perf-name" (car r))
      (perf--txt "perf-num perf-dim" (number->string (caddr r)))
      (perf--txt "perf-num perf-strong" (perf--bytes (* 1024 (cadr r))))
      (perf--meter pct (cond ((>= pct 20) "perf-hot") ((>= pct 8) "perf-warm") (else ""))))))

(define (perf--memory-panel buf)
  (let* ((m (or (buffer-local buf 'perf-mem) '(0 0 0)))
         (total (car m))
         (pct (perf--pct (max 0 (- total (cadr m))) total))
         (apps (or (buffer-local buf 'perf-apps) '())))
    (perf--div "perf-panel"
      (perf--div "perf-head"
        (perf--txt "perf-strong" "Memory · apps")
        (perf--txt "perf-spacer" "")
        (perf--txt "" (perf--mem-summary buf)))
      (perf--meter pct (cond ((>= pct 90) "perf-hot") ((>= pct 75) "perf-warm") (else "")))
      (perf--div "perf-arow perf-phead"
        (perf--txt "" "app") (perf--txt "perf-num" "procs") (perf--txt "perf-num" "memory")
        (perf--txt "" "share of ram"))
      (perf--div "perf-list"
        (if (null? apps)
            (list (component 'ui/empty '(text "reading ps")))
            (map (lambda (r) (perf--app-row r (quotient total 1024))) apps))))))

(define (perf--footer buf)
  (perf--div "perf-bar"
    (perf--txt "perf-strong" *perf-buffer*)
    (perf--txt "" "g refresh") (perf--txt "" "SPC pause") (perf--txt "" "q quit")
    (perf--txt "perf-spacer" "")
    (perf--txt (if (buffer-local buf 'perf-paused) "perf-warm" "perf-dim")
               (if (buffer-local buf 'perf-paused) "paused" (string-append "tick " (number->string (or (buffer-local buf 'perf-tick) 0)))))))

(define (perf--blocks buf)
  (list (perf--div "perf-root"
          (perf--lanes-panel (or (buffer-local buf 'perf-lanes) '()))
          (perf--memory-panel buf)
          (perf--footer buf))))

;;; --- the tick ---------------------------------------------------------------------

;; a render is two changes: the text, then the blocks
(define (perf--render! buf)
  (perf--replace-text! buf (perf--text buf))
  (buffer-set-locals! buf (list 'render-blocks (perf--blocks buf))))

(define (perf--refresh! buf)
  (perf--sample! buf)
  (perf--render! buf)
  (perf--sample-apps! buf))

(define (perf--arm! buf ms)
  (debounce! (string-append "perf-tick:" buf) ms perf--tick buf))

;; the interval is the custom perf-tick-ms, read on every arm, so a
;; customize takes effect on the next tick
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
             (buffer-derived-mode? *perf-buffer* "perf-mode"))
    (perf--arm! *perf-buffer* 0)))

(add-hook! 'window-configuration-change-hook 'perf--shown-hook!)

;;; --- the mode ------------------------------------------------------------------------

(define *perf-runtime-locals* '(render-blocks perf-lanes perf-mem perf-apps perf-ps-busy perf-tick))

(define (perf--setup! buf)
  (buffer-set-read-only! buf #t)
  (buffer-set-local! buf 'render-mode "blocks")
  (for-each (lambda (k) (desktop-skip! buf k)) *perf-runtime-locals*)
  (perf--refresh! buf)
  (perf--arm! buf perf-tick-ms))

(mode-icon! "perf-mode" "")

(define-mode "perf-mode"
  (lambda () (perf--setup! (current-buffer))))

(mode-keys! "perf-mode"
  '(("g" "perf-refresh")
    ("SPC" "perf-pause")
    ("n" "next-line")
    ("p" "previous-line")
    ("q" "quit-window")))

(mode-doc! "perf-mode"
  "Lane contention, sampled every perf-tick-ms. One row per lane that ran a job in the last 30 seconds, the lane that waited longest first: its jobs, the time they took, its share of the window, the longest and the total time a job sat queued behind earlier jobs on the lane, the deepest the queue got, and its slowest job. Below it, the host memory in use and the apps holding the most of it, every process of one .app counted as one app. g samples now, SPC pauses, q quits.")

(register-context-provider! "perf-mode"
  (lambda (buf)
    (string-append "The system monitor " buf
                   " is open. Its text is a table of lane contention over the last 30 s; "
                   "read the buffer for the numbers.")))

(effects! '(read display))

(define-command "perf" "Show lane contention: the wait and the work of every lane"
  (lambda ()
    (buffer-create *perf-buffer*)
    (switch-to-buffer! *perf-buffer*)
    (unless (buffer-derived-mode? *perf-buffer* "perf-mode")
      (set-mode! "perf-mode"))))

(define-command "perf-refresh" "Sample the lanes now"
  (lambda () (perf--refresh! (current-buffer))))

(define-command "perf-pause" "Pause or resume the samples"
  (lambda ()
    (let* ((buf (current-buffer))
           (paused (not (buffer-local buf 'perf-paused))))
      (buffer-set-local! buf 'perf-paused paused)
      (if paused
          (perf--render! buf)
          (perf--arm! buf 0))
      (message (if paused "perf paused" "perf resumed")))))

(effects! '(read))

;;; --- the memory in the frame modeline ---------------------------------------------------
;;; display-memory-mode, after display-time-mode: one segment in the
;;; global-mode-string, refreshed every display-memory-interval seconds.
;;; The format names what the segment says.

(defcustom 'display-memory-mode #t
  "Show the VM memory at the right of the frame modeline."
  'group 'perf 'type 'boolean)

(defcustom 'display-memory-interval 5
  "Seconds between two memory readings in the frame modeline."
  'group 'perf 'type 'number)

;; The memory segment. %t total VM memory, %p processes, %b binaries, %e ets, %n process count, %h host memory in use as a percent, %c host cpu percent.
(define display-memory-format "%t vm · %h host")

;; the format with every token replaced from SAMPLE
(define (display-memory-text format sample)
  (let* ((mem (perf--get sample 'memory '()))
         (os (perf--get sample 'os '()))
         (host-total (perf--get os 'mem-total 0))
         (host-used (max 0 (- host-total (perf--get os 'mem-free 0))))
         (pairs (list (list "%t" (perf--bytes (perf--get mem 'total 0)))
                      (list "%p" (perf--bytes (perf--get mem 'processes 0)))
                      (list "%b" (perf--bytes (perf--get mem 'binary 0)))
                      (list "%e" (perf--bytes (perf--get mem 'ets 0)))
                      (list "%n" (number->string (perf--get sample 'process-count 0)))
                      (list "%h" (format-percent host-used (max 1 host-total)))
                      (list "%c" (string-append (number->string (perf--get os 'cpu-util 0)) "%")))))
    (fold (lambda (text pair) (string-join (string-split text (car pair)) (cadr pair)))
          format pairs)))

(define (display-memory--arm! ms)
  (debounce! "display-memory" ms display-memory--tick #f))

(define (display-memory--tick _)
  (if display-memory-mode
      (begin
        (global-mode-string-set! 'display-memory
          (display-memory-text display-memory-format (vm-sample)))
        (display-memory--arm! (* 1000 (max 1 display-memory-interval))))
      (global-mode-string-remove! 'display-memory)))

(define-command "display-memory-mode" "Toggle the VM memory in the frame modeline"
  (lambda ()
    (customize-set! 'display-memory-mode (not display-memory-mode))
    (display-memory--tick #f)
    (message (if display-memory-mode "display-memory-mode on" "display-memory-mode off"))))

;; the first reading waits a moment: at boot the frame is not up yet
(display-memory--arm! 1000)

;;; --- the look ---------------------------------------------------------------------------
;;; The palette is four faces a theme can rename. Every colour in the CSS
;;; reads a face variable with a fallback, so a theme that says nothing
;;; still gets a readable chart.

;; The four hues are the theme's own accents, stepped toward the dim ink:
;; a monitor is read all day, and a saturated field shouts. Nominal is not
;; a colour at all: only warm and hot carry one.
(defface! 'perf-indigo 'fg "color-mix(in srgb, var(--accent-fg) 55%, var(--dim-fg))")
(defface! 'perf-amber 'fg "color-mix(in srgb, var(--warn-fg) 60%, var(--dim-fg))")
(defface! 'perf-red 'fg "color-mix(in srgb, var(--alert-fg) 65%, var(--dim-fg))")
(defface! 'perf-green 'fg "var(--modeline-fg)")

(define-style! 'perf "
.perf-root { font-family: var(--font-mono); font-size: 12.5px; color: var(--default-fg); -webkit-font-smoothing: antialiased; height: 100%; min-height: 0; display: flex; flex-direction: column; }
.perf-panel { flex: 1; min-height: 0; display: flex; flex-direction: column; border: 1px solid var(--border-bg); }
.perf-head, .perf-bar { display: flex; align-items: baseline; gap: 16px; padding: 6px 12px; font-size: 11px; letter-spacing: .14em; text-transform: uppercase; color: var(--dim-fg); white-space: nowrap; overflow: hidden; }
.perf-head { border-bottom: 1px solid var(--border-bg); }
.perf-spacer { flex: 1; }
.perf-strong { color: var(--default-fg); font-weight: 600; }
.perf-dim { color: var(--dim-fg); }
span.perf-hot { color: var(--perf-red-fg, #c24a3a); }
span.perf-warm { color: var(--perf-amber-fg, #b07a2a); }
.perf-list { flex: 1; min-height: 0; overflow-y: auto; }
.perf-lrow { display: grid; grid-template-columns: minmax(0, 1.2fr) 48px 64px 56px 72px 72px 64px minmax(0, 2fr); gap: 10px; align-items: center; padding: 4px 12px; border-bottom: 1px dotted var(--border-bg); font-size: 12px; }
.perf-lrow > span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.perf-phead { font-size: 10px; letter-spacing: .12em; text-transform: uppercase; color: var(--dim-fg); border-bottom: 1px solid var(--border-bg); }
.perf-name { color: var(--default-fg); }
.perf-arow { display: grid; grid-template-columns: minmax(0, 1.4fr) 56px 88px minmax(0, 2fr); gap: 10px; align-items: center; padding: 4px 12px; border-bottom: 1px dotted var(--border-bg); font-size: 12px; }
.perf-arow > span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.perf-meter { height: 8px; margin: 6px 12px; border: 1px solid var(--border-bg); background: var(--hl-line-bg); }
.perf-arow .perf-meter { margin: 0; }
.perf-meter-fill { height: 100%; background: var(--dim-fg); }
.perf-meter-fill.perf-warm { background: var(--perf-amber-fg, #b07a2a); }
.perf-meter-fill.perf-hot { background: var(--perf-red-fg, #c24a3a); }
.perf-num { text-align: right; }
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
