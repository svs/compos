;;; profile.scm --- one command, measured.
;;;
;;; `M-x profile` arms the editor and waits. The next command you run is
;;; counted: the BEAM's call counters over the editor's own modules, the
;;; reductions and the garbage every process made, and the telemetry rows
;;; the same command left in the scheme, live and browser layers. The
;;; report lands in *Profile*.
;;;
;;; The window is wide on purpose. It opens on pre-command-hook, before
;;; the command, and closes on post-command-hook, after the dashboard
;;; sync, the list redraws and every other package's hook. All of that is
;;; the cost of pressing the key, so all of it is in the profile.
;;;
;;; Counting is cheap, so the wall clock in the report is the real one:
;;; the command runs at its own speed. A call counter is VM-wide, so
;;; anything else the editor did in the same window is counted with it,
;;; and the process section is what says who did the work. Elixir owns
;;; the counters in Compos.Core.Profiler; this package owns when to arm,
;;; what the report says, and where it shows.

(domain! 'diagnostics)
(effects! '(read))

(define *profile-buffer* "*Profile*")

;; How many function rows one profile shows.
(define profile-function-rows 30)

;; How many Scheme call-site rows one profile shows.
(define profile-site-rows 15)

;; How many process rows one profile shows.
(define profile-process-rows 8)

;; How many telemetry rows one profile shows.
(define profile-layer-rows 14)

;;; --- arming -----------------------------------------------------------------
;;; The prompt that armed the profile is still closing when the profile
;;; is armed: the commands it runs on its way out are not what the reader
;;; meant to measure. A sample of one of those is dropped and the
;;; profiler arms again.

(define *profile-ignored*
  '("profile" "profile-cancel" "execute-extended-command" "keyboard-quit"
    "minibuffer-complete" "minibuffer-exit" "minibuffer-quit"))

(define *profile-armed* #f)
(define *profile-open* #f)

(define (profile--ignored? cmd) (and (member cmd *profile-ignored*) #t))

(define (profile--command)
  (let ((c (this-command)))
    (if (or (not c) (equal? c "")) "self-insert-command" c)))

;;; --- the call sites ---------------------------------------------------------
;;;
;;; An Elixir profile names the Elixir function that ran, so every list
;;; walk in a command arrives as one anonymous `-all/0-fun-82-` with no way
;;; back to the Scheme that ran it. The builtin knows the lambda it was
;;; handed, and a lambda's parameters name its call site: `fold (out
;;; bucket)` is one place in the source and nothing else.
;;;
;;; The count lives here and not in the interpreter on purpose. A check in
;;; the evaluator's builtin path costs a lookup on every builtin call --
;;; measured at 40ms for one C-x b, paid by every command forever, to
;;; serve a tool that is off. Instead the profiler swaps these builtins
;;; for counting wrappers while it is armed and puts them back after, so
;;; nothing is added to the path a command normally takes.

(define *profile-site-builtins* '(map filter fold for-each remove))
(define *profile-site-saved* '())
(define *profile-site-counts* '())
;; #t while a wrapper does its own bookkeeping. The bookkeeping calls
;; fold and remove, which are wrappers too, so without this flag a fold
;; counts itself until the recursion bound stops it.
(define *profile-site-busy* #f)

(define (profile--site-bump! name sig n)
  (let* ((key (list name sig))
         (cell (assoc key *profile-site-counts*)))
    (set! *profile-site-counts*
          (cons (list key (+ 1 (if cell (nth 1 cell) 0)) (+ n (if cell (nth 2 cell) 0)))
                (if cell
                    (remove (lambda (c) (equal? (car c) key)) *profile-site-counts*)
                    *profile-site-counts*)))))

;; the longest list the builtin was given is what it had to walk
(define (profile--site-elements args)
  (fold (lambda (n a) (if (pair? a) (max n (length a)) n)) 0 args))

;; the lambda's own source, clipped: enough to find the one place in the
;; source that wrote it, short enough to be a row
(define (profile--site-of f)
  (let ((src (if (procedure? f) (function-source f) "")))
    (if (string? src)
        (let ((one (string-trim (car (string-split src "\n")))))
          (if (> (string-length one) 58) (string-append (substring one 0 58) "…") one))
        "")))

(define (profile--sites-on!)
  (set! *profile-site-busy* #f)
  (set! *profile-site-counts* '())
  (set! *profile-site-saved*
    (map (lambda (name) (list name (symbol-value name))) *profile-site-builtins*))
  (for-each
    (lambda (saved)
      (let ((name (car saved)) (orig (nth 1 saved)))
        (set-symbol-value! name
          (lambda (f &rest rest)
            (unless *profile-site-busy*
              (set! *profile-site-busy* #t)
              (profile--site-bump! (symbol->string name) (profile--site-of f)
                                   (profile--site-elements rest))
              (set! *profile-site-busy* #f))
            (apply orig (cons f rest))))))
    *profile-site-saved*))

(define (profile--sites-off!)
  (for-each (lambda (saved) (set-symbol-value! (car saved) (nth 1 saved)))
            *profile-site-saved*)
  (set! *profile-site-saved* '())
  (set! *profile-site-busy* #f))

(define (profile--sites-report)
  (map (lambda (c)
         (list 'name (car (car c)) 'site (nth 1 (car c))
               'calls (nth 1 c) 'elements (nth 2 c)))
       *profile-site-counts*))

;; first on pre-command-hook: the trace must be running before the
;; command, and everything after this point is the command's own cost
(define (profile--pre!)
  (when *profile-armed*
    (set! *profile-armed* #f)
    (set! *profile-open* (list 'buffer (current-buffer)))
    (profile--sites-on!)
    (profile-start!)))

;; last on post-command-hook
(define (profile--post!)
  (when *profile-open*
    (let ((open *profile-open*)
          (cmd (profile--command)))
      (set! *profile-open* #f)
      (if (profile--ignored? cmd)
          (begin (profile--sites-off!) (profile-cancel!) (set! *profile-armed* #t))
          (let ((data (profile-stop))
                (sites (begin (profile--sites-off!) (profile--sites-report))))
            (when data
              (profile--show!
                (append (list 'command cmd 'buffer (plist-get open 'buffer)
                              'sites sites)
                        data))))))))

(add-hook! 'pre-command-hook 'profile--pre!)
(add-hook! 'post-command-hook 'profile--post! #t)

;;; --- numbers ----------------------------------------------------------------

;; a value already counted in tenths, as "12.3"
(define (profile--tenths n)
  (string-append (number->string (quotient n 10)) "." (number->string (remainder n 10))))

;; microseconds as milliseconds, one decimal
(define (profile--ms us)
  (profile--tenths (quotient (+ us 50) 100)))

(define (profile--count n)
  (cond ((>= n 1000000) (string-append (profile--tenths (quotient (* n 10) 1000000)) " M"))
        ((>= n 1000) (string-append (profile--tenths (quotient (* n 10) 1000)) " k"))
        (else (number->string n))))

;; a delta: the sign is the point of it
(define (profile--bytes n)
  (let* ((down (< n 0))
         (a (if down (- 0 n) n))
         (s (cond ((>= a 1048576) (string-append (profile--tenths (quotient (* a 10) 1048576)) " MB"))
                  ((>= a 1024) (string-append (profile--tenths (quotient (* a 10) 1024)) " KB"))
                  (else (string-append (number->string a) " B")))))
    (string-append (if down "-" "+") s)))

(define (profile--share part whole)
  (if (<= whole 0) 0 (min 100 (quotient (* part 100) whole))))

(define *profile-bar-width* 8)

(define (profile--bar share)
  (let ((n (min *profile-bar-width*
                (quotient (+ (* share *profile-bar-width*) 99) 100))))
    (string-append (string-repeat "█" n)
                   (string-repeat "·" (- *profile-bar-width* n)))))

;;; --- the rows ---------------------------------------------------------------
;;; One table, four sections. Each section says its own unit in its
;;; heading, because own milliseconds, reductions and bytes do not share
;;; a column.

(define (profile--sep label) (list 'kind "sep" 'what label))

(define (profile--report buf) (buffer-local buf 'profile-report))

(define (profile--function-rows r)
  (let ((total (plist-get r 'calls))
        (fns (take (plist-get r 'functions) profile-function-rows)))
    (if (null? fns)
        '()
        (cons (profile--sep
                (string-append "what ran · calls, "
                               (number->string (plist-get r 'functions-seen))
                               " functions of the editor's own code"))
              (map (lambda (f)
                     (list 'kind "fn"
                           'what (string-append (plist-get f 'module) "." (plist-get f 'function))
                           'count (plist-get f 'calls)
                           'value ""
                           'share (profile--share (plist-get f 'calls) total)))
                   fns)))))

;; A builtin call counts itself against the lambda it was handed, so the
;; list work of a command reads as the Scheme that ran it. An Elixir
;; profile can only say `-all/0-fun-82-`; this says `fold (out bucket)`,
;; which names one call site in the source. ELEMENTS is what the builtin
;; walked, and it is the number that matters: a thousand folds over four
;; things is nothing, one fold over a thousand is the command.
(define (profile--site-rows r)
  ;; most elements walked first: sort pairs the count in front, because
  ;; sort orders lists by their own head
  (let* ((all (or (plist-get r 'sites) '()))
         (ranked (map (lambda (p) (nth 1 p))
                      (sort (map (lambda (s) (list (- 0 (plist-get s 'elements)) s)) all))))
         (sites (take ranked profile-site-rows)))
    (if (null? sites)
        '()
        (let ((total (fold (lambda (n s) (+ n (plist-get s 'elements))) 0 sites)))
          (cons (profile--sep "what the lists walked · elements, by call site")
                (map (lambda (s)
                       (let ((site (plist-get s 'site)))
                         (list 'kind "site"
                               'what (string-append (plist-get s 'name)
                                                    (if (equal? site "") "" (string-append "  " site)))
                               'count (plist-get s 'elements)
                               'value (string-append (profile--count (plist-get s 'calls)) " calls")
                               'share (profile--share (plist-get s 'elements) total))))
                     sites))))))

(define (profile--process-rows r)
  (let ((total (plist-get r 'reductions))
        (ps (take (plist-get r 'processes) profile-process-rows)))
    (if (null? ps)
        '()
        (cons (profile--sep "who did the work · reductions")
              (map (lambda (p)
                     (list 'kind "proc"
                           'what (string-append (plist-get p 'name) "  " (plist-get p 'pid))
                           'count (plist-get p 'reductions)
                           'value (profile--bytes (plist-get p 'memory))
                           'share (profile--share (plist-get p 'reductions) total)))
                   ps)))))

;; the live layer renders and the browser paints after the command
;; returns, so their rows reach the collector after the profile does. The
;; first draw shows what had landed; `g` reads the stream again.
(define (profile--layer-rows r)
  (let* ((at (plist-get r 'at-ms))
         (rows (filter (lambda (e) (>= (plist-get e 'time-ms) at)) (telemetry-events 200)))
         (rows (take (reverse rows) profile-layer-rows)))
    (if (null? rows)
        '()
        (cons (profile--sep "the layers · ms, oldest first")
              (map (lambda (e)
                     (let ((detail (or (plist-get e 'detail) "")))
                       (list 'kind "layer"
                             'what (string-append (plist-get e 'layer) "  " (plist-get e 'label)
                                                  (if (equal? detail "") "" (string-append "  " detail)))
                             'value (number->string (plist-get e 'duration-ms)))))
                   rows)))))

(define (profile--vm-rows r)
  (list (profile--sep "what the vm paid")
        (list 'kind "vm" 'what "reductions" 'value (profile--count (plist-get r 'reductions)))
        (list 'kind "vm" 'what "garbage collections" 'value (number->string (plist-get r 'gcs)))
        (list 'kind "vm" 'what "words collected" 'value (profile--count (plist-get r 'gc-words)))
        (list 'kind "vm" 'what "memory" 'value (profile--bytes (plist-get r 'memory)))
        (list 'kind "vm" 'what "process memory" 'value (profile--bytes (plist-get r 'memory-processes)))
        (list 'kind "vm" 'what "binary memory" 'value (profile--bytes (plist-get r 'memory-binary)))
        (list 'kind "vm" 'what "modules traced" 'value (number->string (plist-get r 'modules)))))

(define (profile--rows buf)
  (let ((r (profile--report buf)))
    (if (not r)
        '()
        (append (profile--site-rows r)
                (profile--function-rows r)
                (profile--process-rows r)
                (profile--layer-rows r)
                (profile--vm-rows r)))))

;;; --- the look ---------------------------------------------------------------

(define (profile--separator? buf e) (equal? (plist-get e 'kind) "sep"))

(define (profile--columns buf)
  (list (list "what" #f)
        (list "count" 11 'right)
        (list "value" 10 'right)
        (list "share" *profile-bar-width*)))

(define (profile--cells buf e)
  (let ((kind (plist-get e 'kind))
        (what (plist-get e 'what)))
    (cond
      ((equal? kind "sep")
       (list (list (string-append "── " what " ") "accent") "" "" ""))
      ((equal? kind "fn")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (plist-get e 'value)
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "site")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (list (plist-get e 'value) "faint")
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "proc")
       (list what
             (list (profile--count (plist-get e 'count)) "dim")
             (list (plist-get e 'value) "faint")
             (list (profile--bar (plist-get e 'share)) "faint")))
      ((equal? kind "layer")
       (list (list what "faint") "" (plist-get e 'value) ""))
      (else
       (list what "" (plist-get e 'value) "")))))

(define (profile--meta buf)
  (let ((r (profile--report buf)))
    (if (not r)
        "nothing profiled yet · M-x profile arms the next command"
        (string-append (plist-get r 'command)
                       " in " (plist-get r 'buffer)
                       " · " (profile--ms (plist-get r 'wall-us)) " ms"
                       " · " (profile--count (plist-get r 'calls)) " calls"
                       " · " (profile--count (plist-get r 'reductions)) " reductions"
                       " · " (profile--bytes (plist-get r 'memory))))))

(mode-icon! "profile-mode" "")

(define-list-mode! "profile-mode"
  (list
    'doc (string-append
           "One command, measured. The first section is what ran: one row "
           "per function of the editor's own code that was called, how "
           "many times, and its share of every call in the window. The "
           "counters are VM-wide, so work the editor did beside the "
           "command is in them too. The second section is which BEAM "
           "processes did the work, in reductions, with the memory each "
           "one gained; that one is per process and says who. The third "
           "is the telemetry the same command left in the scheme, live "
           "and browser layers, oldest first. The last is what the VM "
           "paid. g reads the layers again once the browser has "
           "reported, F draws the Scheme call stacks as a flamegraph, / "
           "narrows, p arms the next command, q quits.")
    'buffer *profile-buffer*
    'rows profile--rows
    'columns profile--columns
    'cells profile--cells
    'key (lambda (buf e) (plist-get e 'what))
    'title (lambda (buf) "Profile")
    'meta profile--meta
    'separator? profile--separator?
    'section? profile--separator?
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("g" "refresh") ("F" "flamegraph") ("p" "profile again") ("/" "filter") ("q" "quit")))
    'keys '(("g" "list-revert")
            ("F" "profile-flamegraph")
            ("p" "profile")
            ("q" "quit-window"))))

;; a report is one command's measurement: it means nothing after a
;; restart, so the desktop never carries it. Registered after
;; define-list-mode!, so this setup wins and still runs the list init.
(define-mode "profile-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (desktop-skip! buf 'profile-report)
      (list-mode-init! buf "profile-mode"))))

;;; --- the commands -----------------------------------------------------------

(effects! '(read write display))

;; the flamegraph: the Scheme call stacks the evaluator folded while the
;; profile was armed, (PATH SELF-US CALLS) with PATH "outer;inner;leaf".
;; One sort and one sweep lay them out, as flamegraph.pl does: a frame
;; opens where a stack first holds it and closes where the next stack
;; stops sharing it, so a bar's width is the time spent under it.

(define *profile-flame-buffer* "*Flamegraph*")
(define *profile-flame-width* 1200)
(define *profile-flame-row* 17)

(define (profile--flame-frames stacks)
  ;; (DEPTH NAME START END) in microseconds from the left edge, and the total.
  ;; OPEN is the frames of the previous stack, deepest first, so the ones a
  ;; new stack stops sharing come off its head
  (let sweep ((ss (sort (map (lambda (s) (list (string-split (car s) ";") (cadr s))) stacks)))
              (prev '()) (open '()) (x 0) (out '()))
    (if (null? ss)
        (list (fold (lambda (out o) (cons (list (car o) (cadr o) (caddr o) x) out)) out open) x)
        (let* ((frames (car (car ss)))
               (common (let count ((a prev) (b frames) (n 0))
                         (if (and (pair? a) (pair? b) (equal? (car a) (car b)))
                             (count (cdr a) (cdr b) (+ n 1))
                             n))))
          (let close ((open open) (out out))
            (if (and (pair? open) (>= (car (car open)) common))
                (close (cdr open) (cons (list (car (car open)) (cadr (car open)) (caddr (car open)) x) out))
                (let push ((fs (list-tail frames common)) (d common) (open open))
                  (if (pair? fs)
                      (push (cdr fs) (+ d 1) (cons (list d (car fs) x) open))
                      (sweep (cdr ss) frames open (+ x (max 0 (cadr (car ss)))) out)))))))))

(define (profile--flame-escape s) (html-escape s))

(define (profile--flame-color name)
  ;; warm, and the same name keeps its colour from one profile to the next
  (let ((h (let hash ((i 0) (acc 7))
             (let ((byte (string-byte name i)))
               (if byte (hash (+ i 1) (modulo (+ (* acc 31) byte) 9973)) acc)))))
    (string-append "rgb(" (number->string (+ 205 (modulo h 50))) ","
                   (number->string (+ 80 (modulo (quotient h 50) 130))) ","
                   (number->string (+ 30 (modulo (quotient h 7) 50))) ")")))

(define (profile-flamegraph-html stacks title)
  "(profile-flamegraph-html STACKS TITLE) -- an HTML page with the SVG flamegraph of folded STACKS, root at the top"
  (let* ((laid (profile--flame-frames stacks))
         (frames (car laid))
         (total (max 1 (cadr laid)))
         (w *profile-flame-width*)
         (row *profile-flame-row*)
         (depth (+ 1 (fold (lambda (m f) (max m (car f))) 0 frames)))
         (px (lambda (us) (quotient (* us w) total)))
         (bars (filter (lambda (f) (>= (- (px (cadddr* f)) (px (caddr f))) 1)) frames)))
    (string-append
      "<html><head><style>"
      "body{margin:0;background:#fff;font-family:ui-monospace,Menlo,monospace}"
      ".head{padding:.5rem .8rem;font-size:13px;color:#333}"
      "svg{width:100%;height:auto}text{font-size:11px;fill:#000;pointer-events:none}"
      "rect{stroke:#fff;stroke-width:.5}rect:hover{stroke:#000;stroke-width:1}"
      "</style></head><body>"
      "<div class='head'>" (profile--flame-escape title) " · " (profile--ms total) " ms of Scheme · "
      (number->string (length frames)) " frames · hover a bar for its time</div>"
      "<svg viewBox='0 0 " (number->string w) " " (number->string (* depth row)) "' xmlns='http://www.w3.org/2000/svg'>"
      (apply string-append
        (map (lambda (f)
               (let* ((x0 (px (caddr f))) (x1 (px (cadddr* f))) (bw (- x1 x0))
                      (y (* (car f) row)) (us (- (cadddr* f) (caddr f)))
                      (name (profile--flame-escape (cadr f))))
                 (string-append
                   "<g><title>" name " — " (profile--ms us) " ms, "
                   (number->string (profile--share us total)) "%</title>"
                   "<rect x='" (number->string x0) "' y='" (number->string y)
                   "' width='" (number->string bw) "' height='" (number->string (- row 1))
                   "' fill='" (profile--flame-color (cadr f)) "'/>"
                   ;; a name fits at about 7 pixels a character
                   (if (> bw 24)
                       (let ((room (quotient (- bw 6) 7)))
                         (string-append "<text x='" (number->string (+ x0 3)) "' y='" (number->string (+ y row -5)) "'>"
                                        (if (> (string-length (cadr f)) room)
                                            (profile--flame-escape (string-append (substring (cadr f) 0 (max 0 (- room 1))) "…"))
                                            name)
                                        "</text>"))
                       "")
                   "</g>")))
             bars))
      "</svg></body></html>")))

(define (cadddr* l) (car (cdr (cdr (cdr l)))))

(define (profile-flamegraph! report)
  "(profile-flamegraph! REPORT) -- draw REPORT's Scheme stacks into *Flamegraph*, and answer the buffer"
  (let ((buf *profile-flame-buffer*))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-read-only! buf #f)
    (buffer-set-text! buf (profile-flamegraph-html (or (plist-get report 'stacks) '())
                                                   (string-append "Profile of " (or (plist-get report 'command) "a call"))))
    (buffer-set-local! buf 'preview-renderer "html")
    (enable-minor-mode! buf "preview-mode")
    (preview-heal! buf)
    (buffer-set-read-only! buf #t)
    buf))

(define (profile--show! report)
  (unless (buffer-exists? *profile-buffer*) (buffer-create *profile-buffer*))
  (buffer-set-local! *profile-buffer* 'profile-report report)
  (list-mode-show! "profile-mode"))

(define-command "profile-flamegraph" "Show the last profile's Scheme call stacks as a flamegraph"
  (lambda ()
    (let ((report (and (buffer-exists? *profile-buffer*)
                       (buffer-local *profile-buffer* 'profile-report))))
      (if (not report)
          (message "No profile yet: M-x profile, then run a command.")
          (display-buffer-other-window! (profile-flamegraph! report))))))

(define-command "profile" "Profile the next command and show where its time went"
  (lambda ()
    (set! *profile-armed* #t)
    (message "Profile: run one command.")))

(define-command "profile-cancel" "Disarm the profiler and drop any running trace"
  (lambda ()
    (set! *profile-armed* #f)
    (set! *profile-open* #f)
    (profile-cancel!)
    (message "Profile off.")))

(effects! '(read))

(public! 'profile-armed?
  "(profile-armed?) — #t while the profiler waits for a command")

(define (profile-armed?) (and *profile-armed* #t))
