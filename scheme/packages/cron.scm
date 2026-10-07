;;; cron.scm --- jobs on a clock: cron times, run by a workflow.
;;;
;;; (cron-define! NAME SPEC ACTION) makes a job. SPEC is a cron time
;;; ("0 9 * * 1-5"), a nickname ("@daily", "@hourly"), or a period
;;; ("@every 15m", "@every 2h"). ACTION is one of
;;;
;;;   'command NAME            run the M-x command NAME
;;;   'call FN                 call (FN EVENT); give FN as a quoted name
;;;   'emit (TOPIC KIND DATA)  write an event that the run caused
;;;   'agent (CHAT PROMPT)     send PROMPT to the chat CHAT. That spends, so
;;;                            it runs only when cron-agent-jobs is on
;;;
;;; or nothing, when a workflow that listens to cron:NAME does the work.
;;; 'zone gives a time zone other than the local one. 'save #f keeps the
;;; job out of cron-file, for a package that defines it as it loads.
;;;
;;; The core (Compos.Core.Cron, on Quantum) holds the timer. A due job
;;; appends `fired` to cron:NAME in the event log, and the workflow "cron"
;;; runs the action, one event at a time, off the keystroke lane. An action
;;; that raises is retried and then parked, as any workflow batch is.
;;;
;;; The log is the record. Its newest event on cron:NAME is the last run,
;;; or the definition when the job never ran. When a job comes up with the
;;; daemon and its last due time is later than that, the daemon was down
;;; when the job was due. The job then runs once, late, however many runs
;;; it missed.
;;;
;;; M-x cron-list lists the jobs: r runs one now, k removes it.

(domain! 'system)
(effects! '(pure))

(defcustom 'cron-file (string-append (compos-home) "/cron.scm")
  "The file that keeps the jobs cron-define! makes, one cron-define! form each.")

(defcustom 'cron-catch-up #t
  "Run a job once when the daemon was down at its last due time.")

(defcustom 'cron-agent-jobs #f
  "Let a job send a prompt to an agent chat. Off, such a job does nothing and says so.")

;; NAME -> (name NAME spec SPEC cron CRON zone ZONE opts OPTS save BOOL);
;; SPEC is what the user wrote, CRON the cron time the core reads
(defvar '*cron-jobs* '())

(define *cron-loading* #f)
(define *cron-buffer* "*cron*")

(define (cron--topic name) (string-append "cron:" name))

;; "@every 15m" -> "*/15 * * * *": a cron time repeats inside an hour or
;; a day, so the period must divide it
(define (cron--every spec)
  (let* ((s (string-trim (substring spec 6 (string-length spec))))
         (k (string-length s))
         (n (and (> k 1) (string->number (substring s 0 (- k 1)))))
         (unit (if (> k 0) (substring s (- k 1) k) "")))
    (cond ((not (and n (integer? n) (> n 0)))
           (error "cron: not a period:" spec))
          ((and (equal? unit "m") (< n 60) (= 0 (modulo 60 n)))
           (string-append "*/" (number->string n) " * * * *"))
          ((and (equal? unit "h") (< n 24) (= 0 (modulo 24 n)))
           (string-append "0 */" (number->string n) " * * *"))
          ((and (equal? unit "d") (= n 1)) "0 0 * * *")
          (else (error "cron: @every takes minutes that divide an hour, hours that divide a day, or 1d:" spec)))))

(define (cron-spec spec)
  "(cron-spec SPEC) — the cron time the core reads for SPEC: an @every period becomes a cron time, the rest stays"
  (if (string-prefix? "@every" spec) (cron--every spec) spec))

(define (cron--zone job) (or (plist-get job 'zone) ""))

(define (cron--opt opts key default)
  (let ((m (member key opts)))
    (if (and m (pair? (cdr m))) (cadr m) default)))

;; the opts that say what the job does, as cron-file writes them back
(define (cron--action-opts opts)
  (let loop ((o opts) (acc '()))
    (cond ((or (null? o) (null? (cdr o))) (reverse acc))
          ((equal? (car o) 'save) (loop (cddr o) acc))
          (else (loop (cddr o) (cons (cadr o) (cons (car o) acc)))))))

(define (cron--action-text job)
  (let ((opts (plist-get job 'opts)))
    (cond ((plist-get opts 'command) (string-append "M-x " (plist-get opts 'command)))
          ((plist-get opts 'call) (format "~s" (plist-get opts 'call)))
          ((plist-get opts 'emit) (string-append "emit " (format "~s" (car (plist-get opts 'emit)))))
          ((plist-get opts 'agent) (string-append "prompt " (car (plist-get opts 'agent))))
          (else (string-append "event on " (cron--topic (plist-get job 'name)))))))

;;; --- the file ---------------------------------------------------------------

(define (cron--literal v)
  (if (or (pair? v) (symbol? v)) (string-append "'" (format "~s" v)) (format "~s" v)))

(define (cron--form name job)
  (string-append "(cron-define! " (format "~s" name) " " (format "~s" (plist-get job 'spec))
                 (apply string-append
                        (map (lambda (v) (string-append " " (cron--literal v)))
                             (plist-get job 'opts)))
                 ")"))

(define (cron--save!)
  (write-file! cron-file
    (string-append ";; cron jobs: cron-define! keeps this file. One form per job." "\n"
                   (apply string-append
                          (map (lambda (e) (string-append (cron--form (car e) (cadr e)) "\n"))
                               (filter (lambda (e) (plist-get (cadr e) 'save))
                                       (reverse *cron-jobs*)))))))

;; each form on its own, so one bad job does not keep the rest from loading
(define (cron--load!)
  (when (file-exists? cron-file)
    (set! *cron-loading* #t)
    (for-each (lambda (form)
                (let ((r (eval-string-safe (format "~s" form))))
                  (when (equal? (car r) 'error)
                    (message (string-append "cron: " cron-file ": " (format "~a" (cadr r)))))))
              (or (scheme-read (read-file cron-file)) '()))
    (set! *cron-loading* #f)))

;;; --- the log ----------------------------------------------------------------

(effects! '(read))

(define (cron-last name)
  "(cron-last NAME) — the newest event on cron:NAME: the last run, or the definition; #f when there is none"
  (let ((es (event-log-newest (cron--topic name) 1)))
    (if (pair? es) (car es) #f)))

(define (cron-next-run name)
  "(cron-next-run NAME) — the next time the job NAME is due, in unix seconds; #f when no scheduler runs"
  (let ((job (alist-get *cron-jobs* name)))
    (and job (cron-running?)
         (ignore-errors (lambda () (cron-next (plist-get job 'cron) (cron--zone job)))))))

(define (cron-jobs)
  "(cron-jobs) — every job as a plist: name spec cron zone action next last"
  (map (lambda (e)
         (let ((job (cadr e)) (last (cron-last (car e))))
           (list 'name (car e) 'spec (plist-get job 'spec) 'cron (plist-get job 'cron)
                 'zone (plist-get job 'zone) 'action (cron--action-text job)
                 'next (cron-next-run (car e))
                 'last (and last (equal? (plist-get last 'kind) 'fired) (plist-get last 'at)))))
       (reverse *cron-jobs*)))

;;; --- define, remove, run ----------------------------------------------------

(effects! '(write execute))

;; the job came up with the daemon: a run it missed runs once now. A new or
;; changed time starts a fresh record, so a changed time does not read as
;; a missed run
(define (cron--catch-up! name job new?)
  (let ((last (cron-last name))
        (cron (plist-get job 'cron)))
    (cond ((or (not last) (not (equal? (plist-get (plist-get last 'data) 'spec) cron)))
           (event-log-append! (cron--topic name) 'defined (list 'name name 'spec cron)))
          ((and new? cron-catch-up
                (< (plist-get last 'at) (cron-previous cron (cron--zone job))))
           (event-log-append! (cron--topic name) 'fired (list 'name name 'spec cron 'late #t))))))

(define (cron-define! name spec &rest opts)
  "(cron-define! NAME SPEC ['command NAME | 'call FN | 'emit (TOPIC KIND DATA) | 'agent (CHAT PROMPT)] ['zone ZONE] ['save BOOL]) — run the job NAME at the cron time SPEC; a later define replaces it. Answer the next run in unix seconds, or #f when no scheduler runs"
  (let* ((cron (cron-spec spec))
         (new? (not (alist-get *cron-jobs* name)))
         (job (list 'name name 'spec spec 'cron cron 'zone (cron--opt opts 'zone #f)
                    'opts (cron--action-opts opts) 'save (cron--opt opts 'save #t))))
    (when (cron-running?) (cron-next cron (cron--zone job)))
    (set! *cron-jobs* (alist-put *cron-jobs* name job))
    (when (and (plist-get job 'save) (not *cron-loading*)) (cron--save!))
    (if (cron-running?)
        (begin
          (cron--catch-up! name job new?)
          (cron-schedule! name cron (cron--zone job)))
        (begin
          (message "cron: the scheduler is not running; the job runs after a daemon restart")
          #f))))

(define (cron-remove! name)
  "(cron-remove! NAME) — stop the job NAME and drop it from cron-file"
  (when (cron-running?) (cron-unschedule! name))
  (let ((saved? (plist-get (or (alist-get *cron-jobs* name) '()) 'save)))
    (set! *cron-jobs* (alist-delete *cron-jobs* name))
    (when saved? (cron--save!)))
  name)

(define (cron-run-now! name)
  "(cron-run-now! NAME) — run the job NAME now, as if it were due; answer the event's seq"
  (let ((job (alist-get *cron-jobs* name)))
    (unless job (error "cron: no job named" name))
    (event-log-append! (cron--topic name) 'fired
                       (list 'name name 'spec (plist-get job 'cron) 'manual #t))))

;;; --- the run ----------------------------------------------------------------

(effects! '(write execute spend))

(define (cron--agent! name target)
  (if cron-agent-jobs
      (agent-continue! (car target) (cadr target))
      (message (string-append "cron: " name
                              " sends a prompt to an agent; turn on cron-agent-jobs to let it"))))

(define (cron--run! event)
  (when (equal? (plist-get event 'kind) 'fired)
    (let* ((name (plist-get (plist-get event 'data) 'name))
           (job (alist-get *cron-jobs* name))
           (opts (if job (plist-get job 'opts) '())))
      (cond ((plist-get opts 'command) (run-command (plist-get opts 'command)))
            ((plist-get opts 'call) ((workflow--fn (plist-get opts 'call)) event))
            ((plist-get opts 'emit)
             (let ((e (plist-get opts 'emit))) (emit! (car e) (cadr e) (caddr e) event)))
            ((plist-get opts 'agent) (cron--agent! name (plist-get opts 'agent)))))))

(define (cron--handle key events) (for-each cron--run! events))

;; one event a batch: a batch that fails runs again, and only its own job
;; runs again with it
(define-workflow! "cron" 'listen '("cron:*") 'handle 'cron--handle 'batch 1)

;;; --- the list ---------------------------------------------------------------

(effects! '(write))

(defface! 'cron-name 'fg "#26356b" 'weight "600")
(defface! 'cron-spec 'fg "#7a5a1a")

(define (cron--time secs) (if secs (format-time secs "%a %d %b %H:%M") "-"))

(define (cron--row name)
  (let ((rows (filter (lambda (r) (equal? (plist-get r 'name) name)) (cron-jobs))))
    (if (pair? rows) (car rows) #f)))

(define (cron--cells buf name)
  (let ((r (cron--row name)))
    (if (not r)
        (list (list name "cron-name") (list "" "faint") (list "" "faint")
              (list "" "faint") (list "" "faint"))
        (list (list name "cron-name")
              (list (plist-get r 'spec) "cron-spec")
              (list (cron--time (plist-get r 'next)) "default")
              (list (cron--time (plist-get r 'last)) "dim")
              (list (plist-get r 'action) "faint")))))

(define (cron--meta buf)
  (let ((st (workflow-status "cron")))
    (string-append (number->string (length *cron-jobs*)) " jobs · "
                   (if (cron-running?) (cron-zone) "scheduler not running")
                   (if (and st (plist-get st 'last-error))
                       (string-append " · last error: " (format "~a" (plist-get st 'last-error)))
                       ""))))

(define (cron-refresh!) (when (buffer-exists? *cron-buffer*) (list-refresh! *cron-buffer*)))

(define (cron--on-current fn)
  (let ((name (list-current *cron-buffer*)))
    (if name (fn name) (message "no job on this line"))))

(define-command "cron-run-now" "Run the job on this line now"
  (lambda ()
    (cron--on-current
      (lambda (name) (cron-run-now! name) (message (string-append "cron: ran " name))))))

(define-command "cron-remove" "Stop the job on this line and forget it"
  (lambda ()
    (cron--on-current
      (lambda (name) (cron-remove! name) (cron-refresh!)
        (message (string-append "cron: removed " name))))))

(define-command "cron-refresh" "Redraw the job list"
  (lambda () (cron-refresh!)))

(define-list-mode! "cron-mode"
  (list
    'doc (string-append
           "The cron jobs: their time, when each is due next, when it last ran, "
           "and what it does. `r` runs the job now, `k` removes it, `g` redraws, "
           "`/` narrows, and `q` quits.")
    'buffer *cron-buffer*
    'transient #f
    'rows (lambda (buf) (map car (reverse *cron-jobs*)))
    'columns (lambda (buf)
               (list (list "job" 20) (list "when" 16) (list "next" 17)
                     (list "last" 17) (list "does" #f)))
    'cells cron--cells
    'title (lambda (buf) "Cron")
    'meta cron--meta
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("r" "run now") ("k" "remove") ("/" "filter") ("g" "refresh") ("q" "quit")))
    'keys '(("r" "cron-run-now") ("k" "cron-remove") ("g" "cron-refresh")
            ("q" "quit-window"))))

(define-command "cron-list" "List the cron jobs"
  (lambda () (list-mode-show! "cron-mode")))

;;; --- boot -------------------------------------------------------------------

(cron--load!)

(domain! 'system)
(effects! '(pure))
(public! 'cron-spec "(cron-spec SPEC) — the cron time the core reads for SPEC; an @every period becomes a cron time")
(effects! '(read))
(public! 'cron-jobs "(cron-jobs) — every job as a plist: name spec cron zone action next last")
(public! 'cron-last "(cron-last NAME) — the newest event on cron:NAME, the last run or the definition, or #f")
(public! 'cron-next-run "(cron-next-run NAME) — the next time the job NAME is due, in unix seconds, or #f")
(effects! '(write execute spend))
(public! 'cron-define! "(cron-define! NAME SPEC ['command NAME | 'call FN | 'emit (TOPIC KIND DATA) | 'agent (CHAT PROMPT)] ['zone ZONE] ['save BOOL]) — run the job NAME at the cron time SPEC, as an event on cron:NAME")
(effects! '(write execute))
(public! 'cron-remove! "(cron-remove! NAME) — stop the job NAME and drop it from cron-file")
(public! 'cron-run-now! "(cron-run-now! NAME) — run the job NAME now, as if it were due")
