;;; perf.scm --- the system monitor: lane contention, live, in one buffer.
;;;
;;; The *perf* buffer draws three panels. The first holds every lane the telemetry stamped a
;;; job on in the last *perf-lane-window-ms*, the lane that waited longest
;;; first. Wait is the time a job sat queued behind the lane's earlier
;;; jobs, so a lane with wait is a lane with contention. The second is
;;; the host memory in use and the apps that hold the most of it. The
;;; third is the VM memory split and the BEAM processes that hold the most.
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

(defcustom 'perf-vm-process-rows 15
  "The number of BEAM processes the compos memory tab of *perf* shows, the process that holds the most memory first."
  'group 'perf 'type 'number)

(defcustom 'perf-vm-ets-rows 15
  "The number of ETS tables the compos memory tab of *perf* shows, the table that holds the most memory first."
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

;; (NAME OWNER ROWS BYTES) per ETS table, the most memory first; '() until
;; the daemon has the vm-ets primitive
(define (perf--ets-tables)
  (if (boundp 'vm-ets) (vm-ets perf-vm-ets-rows) '()))

(define (perf--sample! buf)
  (let* ((s (vm-sample))
         (os (perf--get s 'os '())))
    (buffer-set-locals! buf
      (list 'perf-lanes (perf--lanes (telemetry-events 1000))
            'perf-mem (list (perf--get os 'mem-total 0) (perf--get os 'mem-free 0)
                            (perf--get (perf--get s 'memory '()) 'total 0))
            'perf-vm (perf--get s 'memory '())
            'perf-procs (perf--get (vm-processes perf-vm-process-rows "memory" "") 'rows '())
            'perf-ets (perf--ets-tables)
            'perf-history (if (equal? (perf--tab buf) "history")
                              (perf-history-rows perf-history-hours)
                              (buffer-local-value 'perf-history buf))
            'perf-tick (+ 1 (or (buffer-local-value 'perf-tick buf) 0))))))

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
  (unless (buffer-local-value 'perf-ps-busy buf)
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
    "  tick " (number->string (or (buffer-local-value 'perf-tick buf) 0))
    (if (buffer-local-value 'perf-paused buf) "  paused" "") "\n"
    "\n"
    (string-pad-right "LANE" 40) (string-pad-left "JOBS" 6) (string-pad-left "BUSY" 8)
    (string-pad-left "WAIT MAX" 10) (string-pad-left "WAIT SUM" 10) (string-pad-left "BACKLOG" 9)
    "  SLOWEST\n"
    (apply string-append (map perf--lane-text (or (buffer-local-value 'perf-lanes buf) '())))
    "\n" (perf--mem-summary buf) "\n\n"
    (string-pad-right "APP" 40) (string-pad-left "PROCS" 6) (string-pad-left "MEMORY" 12) "\n"
    (apply string-append
           (map (lambda (r) (string-append (string-pad-right (perf--clip (car r) 38) 40)
                                           (string-pad-left (number->string (caddr r)) 6)
                                           (string-pad-left (perf--bytes (* 1024 (cadr r))) 12) "\n"))
                (or (buffer-local-value 'perf-apps buf) '())))
    "\n" (perf--vm-summary (or (buffer-local-value 'perf-vm buf) '())) "\n\n"
    (string-pad-right "PROCESS" 40) (string-pad-left "PID" 16) (string-pad-left "MEMORY" 12) "\n"
    (apply string-append
           (map (lambda (r) (string-append (string-pad-right (perf--clip (perf--process-name r) 38) 40)
                                           (string-pad-left (perf--get r 'pid "") 16)
                                           (string-pad-left (perf--bytes (perf--get r 'memory 0)) 12) "\n"))
                (perf--by-memory (or (buffer-local-value 'perf-procs buf) '()))))
    "\n" (string-pad-right "ETS TABLE" 40) (string-pad-left "ROWS" 16) (string-pad-left "MEMORY" 12) "\n"
    (apply string-append
           (map (lambda (r) (string-append (string-pad-right (perf--clip (string-append (car r) "  " (cadr r)) 38) 40)
                                           (string-pad-left (number->string (caddr r)) 16)
                                           (string-pad-left (perf--bytes (list-ref r 3)) 12) "\n"))
                (or (buffer-local-value 'perf-ets buf) '())))))

;; "total 314 MiB = processes 73 MiB + ets 134 MiB + binary 25 MiB + code 28 MiB + other 54 MiB"
;; The total is all the memory the BEAM allocated for this daemon. The
;; four named parts do not reach it: other is the rest, the atoms and the
;; VM's own structures.
(define (perf--vm-summary mem)
  (let* ((total (perf--get mem 'total 0))
         (part (lambda (k) (perf--get mem k 0)))
         (other (max 0 (- total (+ (part 'processes) (part 'ets) (part 'binary) (part 'code))))))
    (string-append "total " (perf--bytes total)
                   " = processes " (perf--bytes (part 'processes))
                   " + ets " (perf--bytes (part 'ets))
                   " + binary " (perf--bytes (part 'binary))
                   " + code " (perf--bytes (part 'code))
                   " + other " (perf--bytes other))))

;; the registered name, else the pid
(define (perf--process-name r)
  (or (perf--get r 'name #f) (perf--get r 'pid "")))

;; the process rows, the most memory first
(define (perf--by-memory rows)
  (map cdr (sort (map (lambda (r) (cons (- (perf--get r 'memory 0)) r)) rows))))

;; "used 20 GiB of 24 GiB · 84% · compos 697 MiB"
(define (perf--mem-summary buf)
  (let* ((m (or (buffer-local-value 'perf-mem buf) '(0 0 0)))
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
  (let* ((m (or (buffer-local-value 'perf-mem buf) '(0 0 0)))
         (total (car m))
         (pct (perf--pct (max 0 (- total (cadr m))) total))
         (apps (or (buffer-local-value 'perf-apps buf) '())))
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

;; --- browsers: the memory of every Chrome tab, profile by profile -----------
;; One extension call per connected profile; each answers its tabs with the
;; JS heap of the tab's renderer and its DOM size. Tabs of one site can share
;; a renderer, so their heaps can be the same number.





;; one row of tabs over every perf view: system, compos memory, then the
;; browsers list as all browsers and one tab per Chrome profile. ON is
;; system, compos, All or a profile's name
(define (perf--tab-keys) '("system" "compos" "browsers" "history"))

;; one row of tabs over every perf view; the Chrome profiles are imenu's
;; tabs in the browsers list, not the header's. ON is system, compos or browsers
(define (perf--tabs-on on)
  (component 'ui/tabs
    (list 'class "perf-tabs"
          'leader "SPC"
          'tabs (list (list "perf-tab-system" "system" (equal? on "system") "s")
                      (list "perf-tab-compos" "compos memory" (equal? on "compos") "c")
                      (list "perf-tab-browsers" "browsers" (equal? on "browsers") "b")
                      (list "perf-tab-history" "history" (equal? on "history") "h")))))

(define (perf--tabs buf) (perf--tabs-on (perf--tab buf)))

;; the tabs live in the header line, over every perf tab alike
(define *perf-tab-order* '("system" "compos" "browsers" "history"))

(define (perf--header-sync! buf tab)
  (desktop-skip! buf 'header-line-blocks)
  (perf--which-key-labels! buf '())
  (let ((blocks (list (perf--tabs-on tab))))
    (unless (equal? blocks (buffer-local-value 'header-line-blocks buf))
      (buffer-set-local! buf 'header-line-blocks blocks)
      (when (boundp 'dashboard--sync!) (dashboard--sync! buf)))))

;; which-key names what each SPC key takes: the tab, or the profile, not the
;; command that takes it. EXTRA is ((KEY LABEL) ...) after perf's own three
(define (perf--which-key-labels! buf extra)
  (let ((labels (map (lambda (p) (list (string-append "SPC " (car p)) (cadr p)))
                     (append '(("s" "system") ("c" "compos memory") ("b" "browsers")) extra))))
    (unless (equal? labels (buffer-local-value 'which-key-labels buf))
      (buffer-set-local! buf 'which-key-labels labels))))





;; PROFILES is (LABEL TABS ERROR) per profile, in the order browser-profiles gives
;; The extension before tab-memory: the tab list, then one eval per web tab.
;; Only http(s) pages that are not this machine's: an editor tab refuses
;; string eval, and the eval op would then attach the debugger.
(define *perf-tab-probe*
  "(()=>{const m=performance.memory||{};return [m.usedJSHeapSize||0,m.totalJSHeapSize||0,document.getElementsByTagName('*').length,document.getElementsByTagName('iframe').length]})()")

(define (perf--probe-tab? t)
  (let ((url (perf--get t 'url "")))
    (and (or (string-prefix? "http://" url) (string-prefix? "https://" url))
         (not (string-contains? url "://localhost"))
         (not (string-contains? url "://127.0.0.1")))))

(define *perf-probe-cap-ms* 4000)

;; a tab that never answers (a frozen or sleeping one) must not hold the
;; sample: after *perf-probe-cap-ms* K gets every tab, the silent ones
;; without a heap
(define (perf--tab-memory-by-eval profile k)
  (browser-call "tabs" (list 'profile profile)
    (lambda (r)
      (let* ((tabs (or (perf--get r 'tabs '()) '()))
             (left (length tabs))
             (got '())
             (sent #f)
             (finish (lambda ()
                       (unless sent
                         (set! sent #t)
                         (k (list 'ok #t 'tabs
                                  (map (lambda (t) (cdr (or (assoc (perf--get t 'id 0) got) (cons (perf--get t 'id 0) t))))
                                       tabs))))))
             (done (lambda (row)
                     (set! got (cons (cons (perf--get row 'id 0) row) got))
                     (set! left (- left 1))
                     (when (= left 0) (finish)))))
        (if (null? tabs)
            (k r)
            (begin
              (debounce! (string-append "perf-probe:" (or profile "")) *perf-probe-cap-ms* (lambda (_) (finish)) #f)
              (for-each
                (lambda (t)
                  (if (perf--probe-tab? t)
                      (browser-call "eval" (list 'profile profile 'tab (perf--get t 'id 0) 'code *perf-tab-probe*)
                        (lambda (e)
                          (let ((v (perf--get e 'value #f)))
                            (done (if (and (list? v) (= (length v) 4))
                                      (append t (list 'heap (car v) 'total (cadr v) 'nodes (caddr v) 'iframes (cadddr v)))
                                      t)))))
                      (done t)))
                tabs)))))))

;; K gets the tab-memory reply; an extension without the op answers by eval
(define (perf--tab-memory profile k)
  (let ((sent #f))
    ;; an extension whose tab-memory waits on a frozen tab answers late or
    ;; never; past the cap the eval path, which caps each tab, answers
    (debounce! (string-append "perf-tm:" (or profile "")) (* 2 *perf-probe-cap-ms*)
      (lambda (_) (unless sent (set! sent #t) (perf--tab-memory-by-eval profile k))) #f)
    (browser-call "tab-memory" (list 'profile profile)
      (lambda (r)
        (unless sent
          (set! sent #t)
          (if (or (perf--get r 'error #f) (not (perf--get r 'ok #t)))
              (perf--tab-memory-by-eval profile k)
              (k r)))))))

;; the public name: M-x browsers and a reaper read the tabs through it
(define (browser-tab-memory profile k) (perf--tab-memory profile k))

;; --- closing tabs and windows -----------------------------------------------
;; What a reaper on a schedule calls, and k in the browsers lists.

(define (browser-tab-close! profile tab &optional k)
  (browser-call "close" (list 'profile profile 'tab tab) (or k (lambda (r) r))))

;; closing every tab closes the window; no extension op is needed
(define (browser-window-close! profile window &optional k)
  (browser-call "tabs" (list 'profile profile)
    (lambda (r)
      (let ((ids (map (lambda (t) (plist-get t 'id))
                      (filter (lambda (t) (equal? (plist-get t 'window) window))
                              (or (plist-get r 'tabs) '())))))
        (for-each (lambda (id) (browser-call "close" (list 'profile profile 'tab id) (lambda (_) #t))) ids)
        (when k (k (length ids)))))))

(define (perf--process-row r total)
  (let* ((bytes (perf--get r 'memory 0))
         (pct (perf--pct bytes total)))
    (perf--div "perf-arow perf-vrow"
      (perf--txt "perf-name" (perf--process-name r))
      (perf--txt "perf-num perf-dim" (perf--get r 'pid ""))
      (perf--txt "perf-num perf-strong" (perf--bytes bytes))
      (perf--meter pct (cond ((>= pct 20) "perf-hot") ((>= pct 8) "perf-warm") (else ""))))))

(define (perf--ets-row r total)
  (let* ((bytes (list-ref r 3))
         (pct (perf--pct bytes total)))
    (perf--div "perf-arow perf-vrow"
      (perf--txt "perf-name" (string-append (car r) "  " (cadr r)))
      (perf--txt "perf-num perf-dim" (number->string (caddr r)))
      (perf--txt "perf-num perf-strong" (perf--bytes bytes))
      (perf--meter pct (cond ((>= pct 20) "perf-hot") ((>= pct 8) "perf-warm") (else ""))))))

;; MEM is the memory plist of (vm-sample); ETS the rows of (vm-ets)
(define (perf--ets-section mem ets)
  (let ((total (perf--get mem 'total 0)))
    (list
      (perf--div "perf-arow perf-vrow perf-phead"
        (perf--txt "" "ets table  owner") (perf--txt "perf-num" "rows") (perf--txt "perf-num" "memory")
        (perf--txt "" "share of total"))
      (perf--div "perf-list"
        (if (null? ets)
            (list (component 'ui/empty (list 'text (if (boundp 'vm-ets)
                                                         "no ets tables"
                                                         "vm-ets is not loaded: the daemon has not compiled it yet"))))
            (map (lambda (r) (perf--ets-row r total)) ets))))))

;; MEM is the memory plist of (vm-sample); ROWS are the rows of (vm-processes)
(define (perf--vm-panel mem rows ets)
  (let ((total (perf--get mem 'total 0)))
    (perf--div "perf-panel"
      (perf--div "perf-head"
        (perf--txt "perf-strong" "Memory · compos")
        (perf--txt "perf-spacer" "")
        (perf--txt "" (perf--vm-summary mem)))
      (perf--div "perf-arow perf-vrow perf-phead"
        (perf--txt "" "process") (perf--txt "perf-num" "pid") (perf--txt "perf-num" "memory")
        (perf--txt "" "share of total"))
      (perf--div "perf-list"
        (if (null? rows)
            (list (component 'ui/empty '(text "no processes")))
            (map (lambda (r) (perf--process-row r total)) (perf--by-memory rows))))
      (perf--ets-section mem ets))))

(define (perf--footer buf)
  (perf--div "perf-bar"
    (perf--txt "perf-strong" *perf-buffer*)
    (perf--txt "" "←→ tabs")
    (perf--txt "" "g refresh") (perf--txt "" "SPC 1-4 tabs") (perf--txt "" "P pause") (perf--txt "" "q quit")
    (perf--txt "perf-spacer" "")
    (perf--txt (if (buffer-local-value 'perf-paused buf) "perf-warm" "perf-dim")
               (if (buffer-local-value 'perf-paused buf) "paused" (string-append "tick " (number->string (or (buffer-local-value 'perf-tick buf) 0)))))))

;; the tab the buffer shows: "system", the lanes and the host memory, or
;; "compos", the memory of this daemon
(define (perf--tab buf)
  (let ((t (buffer-local-value 'perf-tab buf)))
    (if (member t '("compos" "history")) t "system")))



(define (perf--blocks buf)
  (list (apply perf--div "perf-root"
          (append
            (cond
              ((equal? (perf--tab buf) "compos")
                (list (perf--vm-panel (or (buffer-local-value 'perf-vm buf) '())
                                      (or (buffer-local-value 'perf-procs buf) '())
                                      (or (buffer-local-value 'perf-ets buf) '()))))
              ((equal? (perf--tab buf) "history")
                (list (perf--history-panel (or (buffer-local-value 'perf-history buf) '()))))
              (else
                (list (perf--lanes-panel (or (buffer-local-value 'perf-lanes buf) '()))
                      (perf--memory-panel buf))))
            (list (perf--footer buf))))))

;;; --- the tick ---------------------------------------------------------------------

;; a render is two changes: the text, then the blocks
(define (perf--render! buf)
  (perf--header-sync! buf (perf--tab buf))
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
    (if (and (window-showing buf) (not (buffer-local-value 'perf-paused buf)))
        (begin
          (perf--refresh! buf)
          (perf--arm! buf perf-tick-ms))
        (perf--arm! buf (* 5 perf-tick-ms)))))

;; a window that starts to show the buffer gets a sample now, not after
;; the slow hidden interval
(define (perf--shown-hook!)
  (when (and (buffer-exists? *perf-buffer*)
             (window-showing *perf-buffer*)
             (not (buffer-local-value 'perf-paused *perf-buffer*))
             (buffer-derived-mode? *perf-buffer* "perf-mode"))
    (perf--arm! *perf-buffer* 0)))

(add-hook! 'window-configuration-change-hook 'perf--shown-hook!)

;;; --- the mode ------------------------------------------------------------------------

(define *perf-runtime-locals* '(render-blocks perf-lanes perf-mem perf-vm perf-procs perf-ets perf-apps perf-ps-busy perf-tick perf-history))

; the monitor takes no text: a key perf does not bind, which would type,
; delete or yank into it, names perf's keys instead of "read-only"
(define *perf-typing-commands*
  '("self-insert-command" "preview-newline" "newline" "delete-backward-char"
    "delete-char" "indent-for-tab" "yank" "yank-pop" "kill-line" "kill-word"
    "backward-kill-word" "kill-region" "quoted-insert"))

(define (perf--setup! buf)
  (buffer-set-read-only! buf #t)
  (for-each (lambda (c) (local-remap*! buf c "perf-key-hint")) *perf-typing-commands*)
  (buffer-set-local! buf 'render-mode "blocks")
  (for-each (lambda (k) (desktop-skip! buf k)) *perf-runtime-locals*)
  (perf--refresh! buf)
  (perf--arm! buf perf-tick-ms))

(mode-icon! "perf-mode" "")

(define-mode "perf-mode"
  (lambda () (perf--setup! (current-buffer))))

; a tab's marked letter takes it, with SPC or without, and so does its
; place in the row, as ui/tabs keys a row in the page: 1 2 3
(mode-keys! "perf-mode"
  '(("<right>" "perf-tab-next")
    ("<left>" "perf-tab-prev")
    ("s" "perf-tab-system")
    ("c" "perf-tab-compos")
    ("b" "perf-tab-browsers")
    ("h" "perf-tab-history")
    ("1" "perf-tab-system")
    ("2" "perf-tab-compos")
    ("3" "perf-tab-browsers")
    ("4" "perf-tab-history")
    ("g" "perf-refresh")
    ("P" "perf-pause")
    ("n" "next-line")
    ("p" "previous-line")
    ("q" "quit-window")))

;; SPC leads perf's tabs: s, c and b, the letters marked in their names.
;; A keymap of its own, so SPC is a prefix wherever point is and which-key
;; shows what follows it
(define-keymap! "perf-leader-map")
(for-each (lambda (p) (define-key "perf-leader-map" (car p) (cadr p)))
  '(("s" "perf-tab-system") ("c" "perf-tab-compos") ("b" "perf-tab-browsers") ("h" "perf-tab-history")))
(bind-prefix! "perf-mode-map" "SPC" "perf-leader-map")

(mode-doc! "perf-mode"
  "Lane contention, sampled every perf-tick-ms. One row per lane that ran a job in the last 30 seconds, the lane that waited longest first: its jobs, the time they took, its share of the window, the longest and the total time a job sat queued behind earlier jobs on the lane, the deepest the queue got, and its slowest job. Below it, the host memory in use and the apps holding the most of it, every process of one .app counted as one app. The compos memory tab shows the memory the BEAM allocated for this daemon, split into processes, ets, binary, code and other, the perf-vm-process-rows BEAM processes that hold the most memory, and the perf-vm-ets-rows ETS tables that hold the most, each with its owner and row count. The browsers tab is the list of every Chrome window and tab with its memory. The history tab charts the daemon memory and the leak suspects (reactor roots, agent lanes, buffers) over the last perf-history-hours, from the SQLite history perf-history-record! fills every perf-history-ms. The tabs sit in the header line: <left> and <right> step them; s, c, b and h (or SPC s, SPC c, SPC b, SPC h), the letter marked in its name, take one, and so do 1, 2, 3 and 4. A key perf does not bind names perf's keys. g samples now, P pauses, q quits.")

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
  (lambda () (perf--refresh! (current-buffer)))
  'modes '(perf-mode))

(define-command "perf-key-hint" "Name the keys perf answers, in place of typing into the monitor"
  (lambda ()
    (message (string-append (string-join (last-keys) " ")
                            " is not a perf key · s c b or 1 2 3 take a tab · <left> <right> step · g samples · P pauses · q quits")))
  'modes '(perf-mode))

(define (perf--show-tab! tab)
  ;; from the browsers list, the other tabs bring *perf* back into this window
  (if (equal? (current-buffer) *perf-browsers-buffer*)
      (begin
        (buffer-set-local! *perf-buffer* 'perf-tab tab)
        (switch-to-buffer-here! *perf-buffer*)
        (perf--render! *perf-buffer*))
      (let ((buf (current-buffer)))
        (buffer-set-local! buf 'perf-tab tab)
        (perf--render! buf))))

(define-command "perf-tab-system" "Show the lanes and the host memory"
  (lambda () (perf--show-tab! "system"))
  'modes '(perf-mode perf-browsers-mode))

(define-command "perf-tab-compos" "Show the memory of this daemon and the processes that hold it"
  (lambda () (perf--show-tab! "compos"))
  'modes '(perf-mode perf-browsers-mode))

(define *perf-browsers-buffer* "*perf:browsers*")

;; perf's tab 3 is the M-x browsers list itself, in a list mode of its own:
;; the same rows, columns and folds, perf's tabs over it, perf's keys on it.
;; The options are browsers-mode's, read when the tab is first taken, since
;; web.scm may load after this file.
;; Chrome as a whole: every process of Google Chrome.app, all profiles
;; together, read from ps off the lane. RSS counts shared pages in each
;; process, so the sum is the upper bound Activity Monitor's figure sits under.
(define *perf-chrome-every-ms* 5000)

(define (perf--chrome-total ps-out)
  (fold (lambda (acc line)
          (let* ((words (string-split (string-trim line) " "))
                 (kib (and (pair? words) (string->number (car words)))))
            (if (and kib (string-contains? line "Google Chrome"))
                (list (+ (car acc) kib) (+ (cadr acc) 1))
                acc)))
        '(0 0) (string-split ps-out "\n")))

(define (perf--sample-chrome! buf)
  (let ((at (buffer-local-value 'perf-chrome-at buf)))
    (unless (or (buffer-local-value 'perf-chrome-busy buf)
                (and at (< (- (monotonic-ms) at) *perf-chrome-every-ms*)))
      (buffer-set-local! buf 'perf-chrome-busy #t)
      (shell-command->string "ps -axo rss=,comm=" "/"
        (lambda (out)
          (when (buffer-exists? buf)
            (buffer-set-locals! buf (list 'perf-chrome (perf--chrome-total out)
                                          'perf-chrome-at (monotonic-ms)
                                          'perf-chrome-busy #f))
            (list-refresh! buf)))))))

(define (perf--chrome-meta buf)
  ;; the totals, on the list's meta line under its title
  (let* ((own (buffer-local-value 'perf-chrome buf))
         (app (let ((a (buffer-local-value 'perf-apps *perf-buffer*))) (and a (assoc "Google Chrome" a))))
         ;; ps from here, else the apps panel's last reading of the same ps
         (c (cond ((and own (> (cadr own) 0)) own)
                  (app (list (cadr app) (caddr app)))
                  (else #f)))
         (tabs (if (boundp 'web--browsers-tabs) web--browsers-tabs '()))
         (wins (if (boundp 'web--browsers-windows) (length (web--browsers-windows)) 0))
         (heap (if (boundp 'web--browsers-heap)
                   (fold (lambda (a t) (+ a (or (web--browsers-heap (plist-get t 'id)) 0))) 0 tabs)
                   0))
         (ram (let ((m (buffer-local-value 'perf-mem *perf-buffer*))) (and m (car m)))))
    (string-join
      (filter (lambda (s) s)
        (list (if c (string-append "Chrome " (perf--bytes (* 1024 (car c))) " resident") "Chrome …")
              (and c ram (> ram 0) (string-append (number->string (perf--pct (* 1024 (car c)) ram)) "% of RAM"))
              (and c (string-append (number->string (cadr c)) " processes"))
              (string-append "tab heap " (perf--bytes heap))
              (string-append (number->string (length tabs)) " tabs in " (number->string wins) " windows")))
      " · ")))

(define (perf--browsers-head buf)
  (perf--sample-chrome! buf)
  (let ((keys (perf--profile-keys (perf--profile-tab-names))))
    (perf--which-key-labels! buf (map (lambda (nk) (list (cadr nk) (car nk))) keys))
    ;; SPC leads only to the profiles there are: which-key lists no number
    ;; that takes nothing
    (for-each (lambda (d)
                (if (find (lambda (nk) (equal? (cadr nk) d)) keys)
                    (unless (keymap-lookup "perf-browsers-leader-map" d)
                      (define-key "perf-browsers-leader-map" d "perf-profile-key"))
                    (when (keymap-lookup "perf-browsers-leader-map" d)
                      (keymap-unset! "perf-browsers-leader-map" d))))
              *perf-profile-digits*))
  (list (perf--tabs-on "browsers")))

;; the Chrome profiles are tabs inside the buffer, over the list's own head:
;; the list draws as list-mode's grid so its head can hold a block
(define (perf--browsers-body-head buf head)
  (cons (perf--profile-tabs buf) (list-grid-head buf head)))

;; the Chrome profiles are the list's own tab row, in the body over its head: All, then
;; each profile. imenu is their selector: it lists the tab rows; [ and ] step.
(define (perf--profile-tab-names)
  (cons "All" (if (boundp 'web--browsers-profile-names) (web--browsers-profile-names) '())))







;; imenu holds the tab rows and nothing else, in two tabs of its own: Tabs,
;; perf's row in the header, and Profiles, the row in the buffer. Each row
;; takes its tab; point stays on the row it was on.
(define (perf--browsers-imenu buf)
  (buffer-set-local! buf 'imenu-snapshot 'perf--browsers-imenu-snapshot)
  (let ((line (car (buffer-line-at-point buf))))
    (apply append
      (map (lambda (bar)
             (let ((kind (if (find (lambda (t) (string-prefix? "perf-profile:" (car t))) (cadr bar)) "Profiles" "Tabs")))
               (map (lambda (t)
                      (list line kind (cadr t) "" (lambda () (tab-bars-take! buf t)) ""
                            (and (> (length t) 3) (nth 3 t)) (and (> (length t) 2) (nth 2 t))))
                    (cadr bar))))
           (tab-bars-all buf)))))

;; leaving imenu without a pick takes back the tabs that were on
(define (perf--browsers-imenu-snapshot buf)
  (let ((on (filter (lambda (t) (and (> (length t) 2) (nth 2 t))) (apply append (map cadr (tab-bars-all buf))))))
    (lambda () (for-each (lambda (t) (tab-bars-take! buf t)) on))))

(define *perf-profile-digits* '("1" "2" "3" "4" "5" "6" "7" "8" "9"))

;; each profile's key is its place in the row: All 1, then 2, 3 ...; perf's
;; own row takes letters, so the two rows never share a key
(define (perf--profile-keys names)
  (let loop ((ns names) (ds *perf-profile-digits*) (out '()))
    (if (or (null? ns) (null? ds)) (reverse out)
        (loop (cdr ns) (cdr ds) (cons (list (car ns) (car ds)) out)))))

(define (perf--profile-tabs buf)
  (let ((on (web--browsers-on buf)))
    (component 'ui/tabs
      (list 'class "perf-profile-tabs"
            'leader "SPC"
            'tabs (map (lambda (nk) (list (string-append "perf-profile:" (car nk)) (car nk) (equal? (car nk) on) (cadr nk)))
                       (perf--profile-keys (perf--profile-tab-names)))))))

;; SPC and a profile's number take that profile
(define-command "perf-profile-key" "Show the Chrome profile whose number follows SPC"
  (lambda ()
    (let* ((keys (last-keys))
           (k (if (string? keys) (car (reverse (string-split keys " "))) (and (pair? keys) (car (reverse keys)))))
           (hit (find (lambda (nk) (equal? (cadr nk) k)) (perf--profile-keys (perf--profile-tab-names))))
           (buf (current-buffer)))
      (if hit
          (web--browsers-show-profile! buf (car hit))
          (message (string-append "perf: no profile on SPC " (or k "?")))))))

(define (perf--browsers-mode!)
  (let ((base (alist-get *list-modes* "browsers-mode")))
    (and base
         (begin
           (define-list-mode! "perf-browsers-mode"
             (append
               (list 'doc (string-append
                            "The browsers tab of *perf*: every Chrome window and its tabs, the heap of each, the compos frame a tab holds. "
                            "<left> and <right> step the perf tabs; SPC s, SPC c and SPC b take one. s-i (imenu) has a tab for all browsers and one per Chrome profile; SPC and a profile's number (SPC 1 is All), or [ and ], narrow the list to one profile. TAB folds the window at point and S-TAB every window. "
                            "k closes the tab, or on a window row the whole window. RET brings a tab to the front. "
                            "/ narrows, g reads the tabs again, q quits.")
                     'buffer *perf-browsers-buffer*
                     'head-blocks perf--browsers-head
                     'plain #f
                     'composml-head perf--browsers-body-head
                     'meta perf--chrome-meta
                     'preview #f
                     'title (lambda (buf) "Browsers")
                     'no-marks #t
                     'footer (lambda (buf) '(("SPC s c b" "tabs") ("←→" "tabs") ("s-i" "profiles") ("SPC 1-9" "profile") ("[ ]" "profile") ("TAB" "fold") ("S-TAB" "fold all")
                                             ("k" "close") ("RET" "front") ("g" "refresh") ("q" "quit")))
                     'keys '(("TAB" "list-toggle-children") ("S-TAB" "list-toggle-all-children")
                             ("k" "browsers-close") ("RET" "browsers-activate")
                             ("<right>" "perf-tab-next") ("<left>" "perf-tab-prev")
                             ("]" "browsers-profile-next") ("[" "browsers-profile-prev")
                             ("g" "browsers-refresh") ("q" "quit-window")))
               base))
           ;; a browsers list: the browsers commands take it as their own
           (mode-parent! "perf-browsers-mode" "browsers-mode")
           ;; SPC leads both rows here: perf's letters, then the profiles'
           ;; numbers. Its own map: the list's SPC (mark) must not answer first
           (define-keymap! "perf-browsers-leader-map" "perf-leader-map")
           (bind-prefix! (mode-keymap "perf-browsers-mode") "SPC" "perf-browsers-leader-map")
           #t))))

(define (perf--browsers-buffer!)
  (let ((buf *perf-browsers-buffer*))
    (unless (buffer-known? buf)
      (buffer-create buf)
      (let ((g (and (buffer-known? *perf-buffer*) (buffer-group *perf-buffer*))))
        (when g (buffer-move-to-group! buf g)))
      (with-current-buffer buf (lambda () (set-mode! "perf-browsers-mode"))))
    (buffer-set-local! buf 'browsers-list buf)
    (buffer-set-local! buf 'imenu-index-function 'perf--browsers-imenu)
    buf))

(add-hook! (list 'block-click 'perf-browsers-tabs)
  (lambda (buf id)
    (and (member buf (list *perf-buffer* *perf-browsers-buffer*)) (string? id)
         (cond ((string-prefix? "perf-profile:" id)
                (web--browsers-show-profile! buf (substring id 13 (string-length id)))
                #t)
               ((string-prefix? "perf-tab-" id)
                (with-current-buffer buf (lambda () (run-command id)))
                #t)
               (else #f)))))

(define-command "perf-tab-browsers" "Show every browser tab and its memory, as the browsers list"
  (lambda () (perf--take-tab! "browsers"))
  'modes '(perf-mode perf-browsers-mode))

(define (perf--current-tab)
  (if (equal? (current-buffer) *perf-browsers-buffer*) "browsers" (perf--tab (current-buffer))))

;; take one tab of the row
(define (perf--take-tab! key)
  (cond ((equal? key "system") (run-command "perf-tab-system"))
        ((equal? key "compos") (run-command "perf-tab-compos"))
        ((equal? key "history") (run-command "perf-tab-history"))
        ((not (perf--browsers-mode!)) (message "The browsers list is not loaded (web package)"))
        (else
          (let ((buf (perf--browsers-buffer!)))
            (unless (equal? (current-buffer) buf) (switch-to-buffer-here! buf))
            (web--browsers-refresh! buf)))))

;; take one tab of the row: a perf tab, or the browsers list on a profile
(define (perf--take-tab! key)
  (cond ((equal? key "system") (run-command "perf-tab-system"))
        ((equal? key "compos") (run-command "perf-tab-compos"))
        ((equal? key "history") (run-command "perf-tab-history"))
        ((not (perf--browsers-mode!)) (message "The browsers list is not loaded (web package)"))
        (else
          (let* ((buf (perf--browsers-buffer!))
                 (fresh (null? web--browsers-tabs)))
            (unless (equal? (current-buffer) buf) (switch-to-buffer-here! buf))
            (buffer-set-local! buf 'browsers-profile key)
            (if fresh (web--browsers-refresh! buf) (list-refresh! buf))))))

(define (perf--step-tab! d)
  (let* ((keys (perf--tab-keys))
         (n (length keys))
         (i (let loop ((ts keys) (k 0))
              (cond ((null? ts) 0) ((equal? (car ts) (perf--current-tab)) k) (else (loop (cdr ts) (+ k 1))))))
         (next (list-ref keys (modulo (+ i d n) n))))
    (perf--take-tab! next)))

(define-command "perf-tab-next" "Show the next perf tab"
  (lambda () (perf--step-tab! 1))
  'modes '(perf-mode perf-browsers-mode))

(define-command "perf-tab-prev" "Show the previous perf tab"
  (lambda () (perf--step-tab! -1))
  'modes '(perf-mode perf-browsers-mode))

(define-command "perf-pause" "Pause or resume the samples"
  (lambda ()
    (let* ((buf (current-buffer))
           (paused (not (buffer-local-value 'perf-paused buf))))
      (buffer-set-local! buf 'perf-paused paused)
      (if paused
          (perf--render! buf)
          (perf--arm! buf 0))
      (message (if paused "perf paused" "perf resumed"))))
  'modes '(perf-mode))

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
.perf-arow.perf-brow { grid-template-columns: minmax(0, 2fr) minmax(0, 1fr) 56px 80px minmax(0, 1.2fr) 64px; }
.perf-whead { text-transform: none; letter-spacing: 0; font-size: 11px; padding: 4px 12px; background: var(--hl-line-bg); }
.perf-kill { justify-content: flex-end; }
.perf-arow.perf-vrow { grid-template-columns: minmax(0, 1.4fr) 104px 88px minmax(0, 2fr); }
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
(public! 'vm-roots
  "(vm-roots) — the Scheme values that Elixir holds as GC roots, grouped by kind, largest first: a list of (KIND COUNT BYTES LARGEST-KEY)")
(public! 'vm-ets
  "(vm-ets [LIMIT]) — the ETS tables that hold the most memory, largest first: a list of (NAME OWNER ROWS BYTES)")
(public! 'vm-scheme-env
  "(vm-scheme-env [LIMIT]) — what the Scheme environment table holds: (FRAMES VARS GLOBAL-VARS ROWS); ROWS are the binding names that hold the most memory over every frame, as (NAME COUNT GLOBAL-COUNT BYTES). Copies every row: a diagnostic, not a sampler")
(public! 'perf-refresh!
  "(perf-refresh! BUF) — sample the VM and redraw the monitor in BUF")
(for-each
  (lambda (name) (catalog-meta! 'function name 'domain 'diagnostics 'effects '(read)))
  '("vm-sample" "vm-processes" "vm-process-info" "vm-roots" "vm-ets" "vm-scheme-env" "perf-refresh!"))

(effects! '(destroy))
(public! 'vm-process-kill!
  "(vm-process-kill! PID) — exit the process with reason kill; #t when it was alive")
(catalog-meta! 'function "vm-process-kill!" 'domain 'diagnostics 'effects '(destroy))
(public! 'browser-tab-close!
  "(browser-tab-close! PROFILE TAB [K]) — close Chrome tab TAB in the profile with id PROFILE (see browser-profiles); K gets the reply")
(catalog-meta! 'function "browser-tab-close!" 'domain 'chrome 'effects '(destroy external))
(public! 'browser-window-close!
  "(browser-window-close! PROFILE WINDOW [K]) — close every tab of Chrome window WINDOW in profile PROFILE; K gets how many")
(catalog-meta! 'function "browser-window-close!" 'domain 'chrome 'effects '(destroy external))
(effects! '(read))
(public! 'browser-tab-memory
  "(browser-tab-memory PROFILE K) — K gets (ok #t tabs ROWS): every tab of Chrome profile PROFILE as plists of id, title, url, window, discarded, heap, total, nodes, iframes; a tab that would not answer has no heap")
(catalog-meta! 'function "browser-tab-memory" 'domain 'chrome 'effects '(read external))
(effects! '(read))

;;; --- descriptors ---------------------------------------------------------------
;;; Every external program, socket, and watcher holds descriptors. At the
;;; limit no port opens: no shell, no git, no agent, and the code loader
;;; logs `emfile` for each module it cannot read. One check a minute
;;; compares the count with the limit. Past fd-warn-ratio it publishes
;;; one event on compos:fds with the port groups that hold the most, at
;;; most once per fd-warn-every-ms, so the log names the leak after the
;;; daemon is gone.

(domain! 'diagnostics)
(effects! '(pure))

(defcustom 'fd-check-ms 60000
  "Milliseconds between two checks of the daemon's open descriptors. 0 stops the check."
  'group 'perf 'type 'number)

(defcustom 'fd-warn-ratio 0.5
  "The share of the descriptor limit at which the check reports the ports that hold the most."
  'group 'perf 'type 'number)

(defcustom 'fd-warn-every-ms 600000
  "The shortest time between two descriptor reports."
  'group 'perf 'type 'number)

(defcustom 'fd-min-limit 4096
  "A descriptor limit below this gets a warning at boot. The macOS default of 256 holds only a few agents."
  'group 'perf 'type 'number)

(define *fd-last-warn* #f)

(define (fd-pressure? count limit)
  "(fd-pressure? COUNT LIMIT) — #t when COUNT descriptors pass fd-warn-ratio of LIMIT"
  (and (number? limit) (> limit 0) (>= count (* fd-warn-ratio limit))))

(effects! '(write))

(define (fd-check!)
  "(fd-check!) — compare the open descriptors with the limit; past fd-warn-ratio, publish the port groups on compos:fds. Answer (COUNT LIMIT)"
  (let* ((fl (vm-fds))
         (count (car fl))
         (limit (cadr fl))
         (now (monotonic-ms)))
    (when (and (fd-pressure? count limit)
               (or (not *fd-last-warn*) (>= (- now *fd-last-warn*) fd-warn-every-ms)))
      (set! *fd-last-warn* now)
      (let ((ports (vm-ports 10)))
        (event-publish! "compos:fds" 'high
                        (list 'count count 'limit limit 'ports ports))
        (message (string-append "descriptors: " (number->string count) " of "
                                (number->string limit) " open; most: "
                                (car (car ports)) " x" (number->string (cadr (car ports)))))))
    fl))

(define (fd--tick arg)
  (when (> fd-check-ms 0)
    (run-on-lane! 'fd-check
      (lambda ()
        (fd-check!)
        (debounce! 'fd-check fd-check-ms fd--tick #f)))))

(debounce! 'fd-check fd-check-ms fd--tick #f)

;; An idle process keeps its garbage until its next collection, and a
;; process that gets few messages has none for hours: 120 MB on a dev
;; daemon. The check collects the idle processes above a size.
(effects! '(pure))

(defcustom 'vm-collect-ms 60000
  "Milliseconds between two collections of the idle processes. 0 stops the collection."
  'group 'perf 'type 'number)

(defcustom 'vm-collect-min-bytes 1048576
  "The collection skips a process that holds less than this."
  'group 'perf 'type 'number)

(effects! '(write))

(define (vm-collect--tick arg)
  (when (> vm-collect-ms 0)
    (run-on-lane! 'vm-collect
      (lambda ()
        (vm-collect! vm-collect-min-bytes)
        (debounce! 'vm-collect vm-collect-ms vm-collect--tick #f)))))

(debounce! 'vm-collect vm-collect-ms vm-collect--tick #f)

;; The VM sizes its descriptor table when it starts, so only the launch
;; can raise the limit: `ulimit -n 65536` in the shell, or
;; M-x restart-daemon, which raises it before the relaunch.
(define (fd-limit-check! arg)
  (let ((limit (cadr (vm-fds))))
    (when (and (> limit 0) (< limit fd-min-limit))
      (event-publish! "compos:fds" 'low-limit (list 'limit limit 'min fd-min-limit))
      (message (string-append "descriptors: the limit is " (number->string limit)
                              ", and a few agents use it all. Run M-x restart-daemon,"
                              " or start the daemon after ulimit -n 65536")))))

(debounce! 'fd-limit-check 10000 fd-limit-check! #f)

;; --- memory history ----------------------------------------------------------
;; One reading a minute goes into SQLite, so a slow leak shows as a line that
;; keeps climbing across hours, days and restarts. The history tab of *perf*
;; draws it. A reading costs about 8 ms: vm-sample, vm-ets and vm-roots.

(domain! 'diagnostics)
(effects! '(pure))

(defcustom 'perf-history-ms 60000
  "Milliseconds between two memory readings the history keeps. 0 stops the sampler."
  'group 'perf 'type 'number)

(defcustom 'perf-history-keep-days 30
  "Days of memory readings the history keeps; older rows are deleted."
  'group 'perf 'type 'number)

(defcustom 'perf-history-hours 24
  "Hours of memory history the history tab of *perf* draws."
  'group 'perf 'type 'number)

;; the columns of the samples table, in order; t is unix seconds
(define *perf-history-columns*
  '(t total processes ets binary code process_count
    scheme_env_bytes scheme_env_rows buffer_view_bytes buffer_view_rows
    reactor_roots agent_lanes buffers client_heap_mb))

(define (perf--ets-of ets name)
  (let loop ((rs ets))
    (cond ((null? rs) '(0 0))
          ((equal? (car (car rs)) name) (list (caddr (car rs)) (list-ref (car rs) 3)))
          (else (loop (cdr rs))))))

(define (perf--root-count roots kind)
  (let loop ((rs roots))
    (cond ((null? rs) 0)
          ((equal? (car (car rs)) kind) (cadr (car rs)))
          (else (loop (cdr rs))))))

(define (perf--mb n) (quotient (or n 0) 1048576))

(define (perf--rate rows key hours)
  "the change of KEY per hour from the first row to the last"
  (if (or (< (length rows) 2) (<= hours 0))
      0
      (/ (- (perf--get (car (reverse rows)) key 0) (perf--get (car rows) key 0)) hours)))

(define (perf--signed n)
  (let ((r (round n)))
    (string-append (if (> r 0) "+" "") (number->string r))))

(define (perf--history-span rows)
  "hours between the first and the last row"
  (if (< (length rows) 2)
      0
      (/ (- (perf--get (car (reverse rows)) 't 0) (perf--get (car rows) 't 0)) 3600.0)))

(define (perf--history-panel rows)
  (let* ((n (length rows))
         (span (perf--history-span rows))
         (last (if (null? rows) '() (car (reverse rows))))
         (labels (map (lambda (r) (format-time-string "%H:%M" (perf--get r 't 0))) rows))
         (mb (lambda (key) (map (lambda (r) (perf--mb (perf--get r key 0))) rows)))
         (raw (lambda (key) (map (lambda (r) (perf--get r key 0)) rows)))
         (rate-mb (lambda (key) (perf--signed (/ (perf--rate rows key span) 1048576))))
         (rate (lambda (key) (perf--signed (perf--rate rows key span)))))
    (perf--div "perf-panel"
      (perf--div "perf-head"
        (perf--txt "perf-strong" "Memory · history")
        (perf--txt "perf-spacer" "")
        (perf--txt "" (string-append (number->string n) " points over "
                                     (number->string (/ (round (* 10 span)) 10)) " h · "
                                     (perf-history-file))))
      (if (< n 2)
          (component 'ui/empty '(text "collecting: a reading lands every perf-history-ms, the chart starts at the second"))
          (list
            (component 'ui/stats
              (list 'stats
                (list (list 'label "total" 'value (string-append (number->string (perf--mb (perf--get last 'total 0))) " MB")
                            'sub (string-append (rate-mb 'total) " MB/h"))
                      (list 'label "scheme env" 'value (string-append (number->string (perf--mb (perf--get last 'scheme_env_bytes 0))) " MB")
                            'sub (string-append (rate 'scheme_env_rows) " rows/h"))
                      (list 'label "reactor roots" 'value (number->string (perf--get last 'reactor_roots 0))
                            'sub (string-append (rate 'reactor_roots) "/h"))
                      (list 'label "agent lanes" 'value (number->string (perf--get last 'agent_lanes 0))
                            'sub (string-append (rate 'agent_lanes) "/h"))
                      (list 'label "buffers" 'value (number->string (perf--get last 'buffers 0))
                            'sub (string-append (rate 'buffers) "/h")))))
            (component 'ui/chart
              (list 'title "Daemon memory" 'y-label "MB" 'y-zero #t 'categories labels
                    'series (list (list "total" (mb 'total))
                                  (list "processes" (mb 'processes))
                                  (list "ets" (mb 'ets))
                                  (list "scheme env" (mb 'scheme_env_bytes))
                                  (list "binary" (mb 'binary)))))
            (component 'ui/chart
              (list 'title "Leak suspects" 'y-label "count" 'y-zero #t 'categories labels
                    'series (list (list "reactor roots" (raw 'reactor_roots))
                                  (list "buffers" (raw 'buffers))
                                  (list "agent lanes" (raw 'agent_lanes))))))))))

(effects! '(read))

(define (perf-history-file)
  "(perf-history-file) — the SQLite file the memory history lives in"
  (string-append (compos-state-dir) "/perf/memory.db"))

(define (perf-history-sample)
  "(perf-history-sample) — one memory reading as a plist of the history's columns"
  (let* ((s (vm-sample))
         (mem (perf--get s 'memory '()))
         (ets (vm-ets 30))
         (roots (vm-roots))
         (env (perf--ets-of ets ":compos_scheme_env"))
         (bv (perf--ets-of ets ":compos_buffer_view"))
         (cs (client-memory-samples))
         (client (if (null? cs) '() (car (reverse cs)))))
    (list 't (current-time)
          'total (perf--get mem 'total 0) 'processes (perf--get mem 'processes 0)
          'ets (perf--get mem 'ets 0) 'binary (perf--get mem 'binary 0) 'code (perf--get mem 'code 0)
          'process_count (perf--get s 'process-count 0)
          'scheme_env_bytes (cadr env) 'scheme_env_rows (car env)
          'buffer_view_bytes (cadr bv) 'buffer_view_rows (car bv)
          'reactor_roots (perf--root-count roots "reactor")
          'agent_lanes (perf--root-count roots "agent_lane")
          'buffers (length (buffer-list))
          'client_heap_mb (perf--get client 'heap-mb 0))))

(effects! '(write))

(define *perf-history-db* #f)

(define (perf--history-db)
  (or *perf-history-db*
      (begin
        (make-directory! (string-append (compos-state-dir) "/perf"))
        (let ((db (sqlite-open! (perf-history-file))))
          (db-query db (string-append "create table if not exists samples (t integer primary key, "
                                      (string-join (map (lambda (c) (string-append (symbol->string c) " integer"))
                                                        (cdr *perf-history-columns*))
                                                   ", ")
                                      ")"))
          (set! *perf-history-db* db)
          db))))

(define (perf-history-record!)
  "(perf-history-record!) — take one memory reading, add it to the history, and delete the rows older than perf-history-keep-days. Answer the reading"
  (let* ((s (perf-history-sample))
         (db (perf--history-db)))
    (db-query db (string-append "insert or replace into samples ("
                                (string-join (map symbol->string *perf-history-columns*) ", ")
                                ") values ("
                                (string-join (map (lambda (c) "?") *perf-history-columns*) ", ")
                                ")")
              (map (lambda (c) (perf--get s c 0)) *perf-history-columns*))
    (db-query db "delete from samples where t < ?"
              (list (- (perf--get s 't 0) (* 86400 perf-history-keep-days))))
    s))

(define (perf-history-rows hours &optional points)
  "(perf-history-rows HOURS [POINTS]) — the history of the last HOURS, oldest first, averaged into at most POINTS buckets (default 240): plists of the history's columns"
  (let* ((db (perf--history-db))
         (points (or points 240))
         (bucket (max 1 (quotient (* hours 3600) points)))
         (since (- (current-time) (* hours 3600)))
         (cols (cdr *perf-history-columns*))
         (r (db-query db (string-append "select (t / ?) * ? as t, "
                                        (string-join (map (lambda (c) (let ((n (symbol->string c)))
                                                                        (string-append "cast(avg(" n ") as integer) as " n)))
                                                          cols)
                                                     ", ")
                                        " from samples where t >= ? group by t / ? order by 1")
                      (list bucket bucket since bucket))))
    (map (lambda (row)
           (let loop ((cs *perf-history-columns*) (vs row) (acc '()))
             (if (null? cs) (reverse acc) (loop (cdr cs) (cdr vs) (cons (car vs) (cons (car cs) acc))))))
         (db-rows r))))

(define (perf-history--tick arg)
  (when (> perf-history-ms 0)
    (run-on-lane! 'perf-history
      (lambda ()
        ;; arm first: a failed reading must not stop the sampler
        (debounce! 'perf-history perf-history-ms perf-history--tick #f)
        (perf-history-record!)))))

(debounce! 'perf-history 5000 perf-history--tick #f)

(effects! '(read display))

(define-command "perf-tab-history" "Show the daemon memory over the last hours, from the history the sampler keeps"
  (lambda () (perf--show-tab! "history"))
  'modes '(perf-mode perf-browsers-mode))

