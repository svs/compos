;;; events-demo.scm --- a live scene on the event bus: producers, three workflows, one local model, every step observed.
;;;
;;; M-x events-demo opens the scene. A producer publishes made-up messages
;;; from four people on "demo:wa:PERSON" and "demo:mail:PERSON". Three
;;; workflows consume them, each feeding the next:
;;;
;;;   triage    asks a local model what kind of message each one is, and
;;;             writes "demo:triaged:PERSON"             -- inference
;;;   todos     files a todo for an ask and closes a person's todos on a
;;;             thanks, on "demo:todo:PERSON"             -- code
;;;   escalate  raises an alert when a person has more than two open
;;;             todos, on "demo:alert:PERSON"             -- code
;;;
;;; Every derived event names its cause and its trace, every workflow run is
;;; an event on obs:workflow:NAME, and every model call is one on obs:llm.
;;; The scene is a view over those events and nothing else, so what it
;;; shows is what happened. RET on a row shows the whole trace.
;;;
;;; The model is qwen3 on marilyn: free, fast, and not very good. The demo
;;; is about cost, speed and seeing everything; the answers may be wrong.
;;; It files no real todos and sends nothing.

(domain! 'system)
(effects! '(write))
(category! 'system)

(define *events-demo-buffer* "*events-demo*")

(define events-demo-models
  '((host "ssh:marilyn" model "qwen3:0.6b")
    (host "ssh:marilyn" model "qwen3:1.7b")
    (host "ssh:marilyn:8089/v1" model "qwen3-4b")))

;; the scene's switches; they survive a reload
(define events-demo-model (if (boundp 'events-demo-model) events-demo-model (car events-demo-models)))
(define events-demo-failing (if (boundp 'events-demo-failing) events-demo-failing #f))

(define demo-message-kinds
  '((ask    "asks the reader to do something")
    (info   "only tells the reader something")
    (thanks "thanks the reader, or says that what was asked is done")))

;;; --- the workflows -----------------------------------------------------
;;;
;;; The part an application writes. Inference answers questions; code acts
;;; on the answers; every action is once! or an event, so a replay repeats
;;; nothing.

(define (demo-triage person messages)
  (for-each (lambda (m)
              (emit! (demo-topic "demo:triaged" person) 'triaged
                     (list 'text (event-text m) 'label (or (demo-kind-of m) 'info))
                     m))
            messages))

(define (demo-kind-of m)
  (pick "What kind of message is this?" demo-message-kinds m 'model events-demo-model))

(define (demo-keep-todos person triaged)
  (when events-demo-failing (error "the todos workflow is switched to fail"))
  (for-each (lambda (t)
              (cond ((demo-label? t 'ask)    (demo-file-todo! person t))
                    ((demo-label? t 'thanks) (demo-close-todos! person t))))
            triaged))

(define (demo-escalate person changes)
  (let ((open (length (demo-open-todos person))))
    (when (> open 2)
      (once! (string-append "demo-alert:" person ":" (number->string open))
             (lambda ()
               (emit! (demo-topic "demo:alert" person) 'alert
                      (list 'text (string-append person " has " (number->string open) " open todos")
                            'open open)
                      (car (reverse changes))))))))

(define (demo-file-todo! person t)
  (once! (string-append "demo-file:" (number->string (plist-get t 'seq)))
         (lambda () (emit! (demo-topic "demo:todo" person) 'filed (list 'text (event-text t)) t))))

(define (demo-close-todos! person t)
  (for-each (lambda (todo)
              (once! (string-append "demo-close:" (number->string (plist-get todo 'seq)))
                     (lambda ()
                       (emit! (demo-topic "demo:todo" person) 'closed
                              (list 'text (string-append "closed: " (event-text todo))
                                    'todo (plist-get todo 'seq))
                              t))))
            (demo-open-todos person)))

(define (events-demo-start!)
  (define-workflow! "demo-triage"   'listen '("demo:wa:*" "demo:mail:*") 'group-by 'demo-person
                                    'quiet 300 'handle 'demo-triage)
  (define-workflow! "demo-todos"    'listen '("demo:triaged:*") 'group-by 'demo-person
                                    'quiet 200 'handle 'demo-keep-todos)
  (define-workflow! "demo-escalate" 'listen '("demo:todo:*") 'group-by 'demo-person
                                    'quiet 200 'handle 'demo-escalate))

;;; --- what the workflows read -------------------------------------------

(effects! '(pure))

(define (demo-topic prefix person) (string-append prefix ":" person))

(define (demo-person e)
  (car (reverse (string-split (plist-get e 'topic) ":"))))

(define (demo-label? e label) (equal? (plist-get (plist-get e 'data) 'label) label))

(effects! '(read))

;; the newest N events of PATTERN, oldest first
(define (demo-log pattern n) (reverse (event-log-newest pattern n)))

;; the todos filed for PERSON that no closed event names
(define (demo-open-todos person)
  (let* ((all (demo-log (demo-topic "demo:todo" person) 500))
         (closed (map (lambda (e) (plist-get (plist-get e 'data) 'todo))
                      (filter (lambda (e) (equal? (plist-get e 'kind) 'closed)) all))))
    (filter (lambda (e) (and (equal? (plist-get e 'kind) 'filed)
                             (not (member (plist-get e 'seq) closed))))
            all)))

;;; --- the producer ------------------------------------------------------
;;;
;;; A tick publishes one message, or now and then a burst from one person,
;;; and schedules the next tick. Nothing waits: the next tick is a timer.

(effects! '(write))

(define events-demo-people '("alice" "bob" "carol" "dan"))

(define events-demo-lines
  '("can you send me the invoice?" "could you book a call for tomorrow?"
    "please review the offer letter" "can you share the JD with the team?"
    "fyi the build is green" "the candidate joined today" "meeting moved to 4pm"
    "we closed the round" "thanks, got it" "thank you, all done" "thanks for the intro!"))

(define events-demo-producing (if (boundp 'events-demo-producing) events-demo-producing #f))
(define events-demo-interval (if (boundp 'events-demo-interval) events-demo-interval 2000))

(define (demo-any xs) (list-ref xs (random (length xs))))

(define (events-demo-say! person)
  (event-publish! (string-append (if (= (random 3) 0) "demo:mail:" "demo:wa:") person)
                  'message (list 'text (demo-any events-demo-lines))))

(define (events-demo-burst! person)
  (events-demo-say! person) (events-demo-say! person) (events-demo-say! person))

(define (events-demo--tick _)
  (when events-demo-producing
    (if (= (random 6) 0)
        (events-demo-burst! (demo-any events-demo-people))
        (events-demo-say! (demo-any events-demo-people)))
    (debounce! 'events-demo-producer events-demo-interval events-demo--tick #f)))

(define (events-demo-produce! on?)
  (set! events-demo-producing on?)
  (when on? (debounce! 'events-demo-producer 10 events-demo--tick #f)))

;;; --- the scene: a view over the log ------------------------------------

(effects! '(pure))

(define (demo-pad s n)
  (let loop ((s (list-fit (or s "") n 'end)))
    (if (< (string-length s) n) (loop (string-append s " ")) s)))

(define (demo-num n) (if (number? n) (number->string n) "-"))

;; the P-th percentile of the numbers XS, or #f
(define (demo-percentile xs p)
  (if (null? xs) #f
      (let ((sorted (sort xs)))
        (list-ref sorted (quotient (* p (- (length sorted) 1)) 100)))))

;; dollars from micro-dollars, to four places
(define (demo-dollars micro)
  (let ((frac (number->string (+ 10000 (quotient (remainder micro 1000000) 100)))))
    (string-append "$" (number->string (quotient micro 1000000)) "." (substring frac 1 5))))

(define (demo-data e k) (plist-get (plist-get e 'data) k))

(effects! '(read))

(define (demo-last-minute events)
  (let ((since (- (current-time) 60)))
    (filter (lambda (e) (>= (plist-get e 'at) since)) events)))

(define (demo-model-line)
  (let* ((calls (event-log-newest "obs:llm" 1000))
         (ms (map (lambda (e) (demo-data e 'ms)) calls))
         (in (apply + (map (lambda (e) (or (demo-data e 'in) 0)) calls)))
         (out (apply + (map (lambda (e) (or (demo-data e 'out) 0)) calls))))
    (string-append "MODEL     " (plist-get events-demo-model 'model) " @ " (plist-get events-demo-model 'host)
                   "  ·  " (number->string (length calls)) " calls, "
                   (number->string (length (demo-last-minute calls))) "/min"
                   "  ·  p50 " (demo-num (demo-percentile ms 50)) "ms  p95 " (demo-num (demo-percentile ms 95)) "ms"
                   "  ·  " (number->string in) " tok in, " (number->string out) " out"
                   "  ·  cost $0 (on Haiku: " (demo-dollars (+ (* in (car workflow-haiku-price)) (* out (cadr workflow-haiku-price)))) ")")))

(define (demo-workflow-line name)
  (let* ((s (workflow-status name))
         (ms (map (lambda (e) (demo-data e 'ms)) (event-log-newest (string-append "obs:workflow:" name) 300))))
    (if (not s)
        (string-append "  " (demo-pad name 15) "stopped")
        (string-append "  " (demo-pad name 15)
                       (demo-pad (demo-num (plist-get s 'position)) 8)
                       (demo-pad (demo-num (plist-get s 'behind)) 8)
                       (demo-pad (symbol->string (plist-get s 'status)) 9)
                       (demo-pad (demo-num (plist-get s 'runs)) 7)
                       (demo-pad (demo-num (demo-percentile ms 50)) 8)
                       (demo-pad (demo-num (demo-percentile ms 95)) 8)
                       (demo-pad (demo-num (plist-get s 'attempts)) 7)
                       (demo-pad (demo-num (plist-get s 'parked)) 7)
                       (or (plist-get s 'last-error) "")))))

(define (demo-producer-line)
  (let ((sent (append (event-log-newest "demo:wa:*" 1000) (event-log-newest "demo:mail:*" 1000))))
    (string-append "PRODUCER  " (if events-demo-producing "running" "stopped")
                   "  ·  one tick every " (number->string events-demo-interval) "ms"
                   "  ·  " (number->string (length sent)) " messages, "
                   (number->string (length (demo-last-minute sent))) " in the last minute")))

(define (demo-todos-line)
  (let ((open (apply + (map (lambda (p) (length (demo-open-todos p))) events-demo-people)))
        (all (event-log-newest "demo:todo:*" 1000)))
    (string-append "TODOS     " (number->string open) " open  ·  "
                   (number->string (length (filter (lambda (e) (equal? (plist-get e 'kind) 'filed)) all))) " filed  ·  "
                   (number->string (length (filter (lambda (e) (equal? (plist-get e 'kind) 'closed)) all))) " closed  ·  "
                   (number->string (length (event-log-newest "demo:alert:*" 1000))) " alerts"
                   (if events-demo-failing "  ·  the todos workflow is FAILING on purpose" ""))))

(define (events-demo--header buf)
  (string-join
   (list (demo-producer-line)
         (demo-model-line)
         (string-append "WORKFLOWS " "log head " (number->string (event-log-seq)))
         (string-append "  " (demo-pad "name" 15) (demo-pad "at" 8) (demo-pad "behind" 8) (demo-pad "running" 9)
                        (demo-pad "runs" 7) (demo-pad "p50ms" 8) (demo-pad "p95ms" 8) (demo-pad "fails" 7)
                        (demo-pad "parked" 7) "last error")
         (demo-workflow-line "demo-triage")
         (demo-workflow-line "demo-todos")
         (demo-workflow-line "demo-escalate")
         (demo-todos-line)
         "")
   "\n"))

;; the newest events of the scene and its observations, newest first
(define (events-demo--rows buf)
  (let* ((xs (append (event-log-newest "demo:*" 80) (event-log-newest "obs:*" 80)))
         (table (map (lambda (e) (cons (plist-get e 'seq) e)) xs)))
    (reverse (map (lambda (seq) (cdr (assoc seq table))) (sort (map car table))))))

(define (demo-what e)
  (let ((kind (plist-get e 'kind)))
    (cond ((equal? kind 'failed)
           (string-append (demo-data e 'workflow) ": attempt " (demo-num (demo-data e 'attempt)) " FAILED, "
                          (or (demo-data e 'error) "")))
          ((equal? kind 'parked)
           (string-append "PARKED " (demo-num (demo-data e 'from)) ".." (demo-num (demo-data e 'upto)) ": "
                          (or (demo-data e 'error) "")))
          ((equal? kind 'call)
           (string-append (demo-data e 'model) " " (demo-num (demo-data e 'ms)) "ms "
                          (demo-num (demo-data e 'in)) "/" (demo-num (demo-data e 'out)) " tok -> "
                          (or (demo-data e 'answer) "")))
          ((equal? kind 'run)
           (string-append (demo-data e 'workflow) ": " (demo-num (demo-data e 'events)) " events, "
                          (demo-num (demo-data e 'ms)) "ms, "
                          (if (demo-data e 'ok) "committed" (string-append "FAILED " (or (demo-data e 'error) "")))))
          ((equal? kind 'triaged)
           (string-append (workflow--label (demo-data e 'label)) " <- " (or (demo-data e 'text) "")))
          (else (event-text e)))))

(define (events-demo--cells buf e)
  (list (number->string (plist-get e 'seq))
        (string-append (number->string (- (current-time) (plist-get e 'at))) "s")
        (demo-num (event-trace e))
        (plist-get e 'topic)
        (symbol->string (plist-get e 'kind))
        (demo-what e)))

;; every event of TRACE the log still holds near the head, oldest first
(define (events-demo-trace trace)
  (filter (lambda (e) (equal? (event-trace e) trace))
          (reverse (append (event-log-newest "demo:*" 1000) (event-log-newest "obs:llm" 1000)))))

;;; --- keeping the scene current -----------------------------------------

(effects! '(write))



(define-list-mode! "events-demo-mode"
  (list
    'doc (string-append
           "A live scene on the event bus. The head shows the producer, the local model and the three workflows: "
           "where each stands in the log, how far behind it is, its run times, failures and parked batches. "
           "The rows are the newest events, the scene's and the observations of it, newest first. "
           "`s` starts and stops the producer, `+` and `-` change its pace, and `b` sends a burst. "
           "`m` switches the model. `F` makes the todos workflow fail, or heals it. "
           "`R` rewinds the todos workflow 30 events and replays them: once! files nothing twice. "
           "`RET` shows the whole trace of the row. `g` redraws, and `q` quits.")
    'buffer *events-demo-buffer*
    'transient #f
    'rows (lambda (buf) (or (demo-snap 'rows) '()))
    'key (lambda (buf e) (number->string (plist-get e 'seq)))
    'panel (lambda (buf) (or (demo-snap 'panel) ""))
    'follow-head #t
    'columns (lambda (buf)
               (list (list "seq" 6) (list "age" 5) (list "trace" 6) (list "topic" 21)
                     (list "kind" 8) (list "what" #f)))
    'cells (lambda (buf e) (car (demo-snap-cells e)))
    'title (lambda (buf) "Event bus scene")
    'total (lambda (buf) (length (list-entries buf)))
    'noun "event"
    'footer (lambda (buf)
              '(("s" "producer") ("+/-" "pace") ("b" "burst") ("m" "model") ("F" "fail")
                ("R" "replay") ("RET" "trace") ("q" "quit")))
    'keys '(("s" "events-demo-producer") ("+" "events-demo-faster") ("-" "events-demo-slower")
            ("b" "events-demo-burst") ("m" "events-demo-next-model") ("F" "events-demo-toggle-failure")
            ("R" "events-demo-replay") ("RET" "events-demo-trace-at-point")
            ("g" "events-demo-refresh") ("q" "quit-window"))))

;;; --- the commands ------------------------------------------------------

(define (events-demo-open!)
  (events-demo-start!)
  (event-subscribe! "events-demo-scene:demo" "demo:*" 'events-demo--saw)
  (event-subscribe! "events-demo-scene:obs" "obs:*" 'events-demo--saw)
  (buffer-create *events-demo-buffer*)
  (unless (buffer-local *events-demo-buffer* 'group)
    (buffer-set-local! *events-demo-buffer* 'group (frame-group)))
  (with-current-buffer *events-demo-buffer* (lambda () (set-mode! "events-demo-mode")))
  (events-demo-refresh!)
  *events-demo-buffer*)

(define-command "events-demo" "Open the event bus scene: a producer, three workflows and a local model, all observed"
  (lambda ()
    (events-demo-open!)
    (events-demo-produce! #t)
    (list-mode-show! "events-demo-mode")))

(define-command "events-demo-producer" "Start or stop the scene's producer"
  (lambda ()
    (events-demo-produce! (not events-demo-producing))
    (events-demo-refresh!)
    (message (if events-demo-producing "the producer runs" "the producer stopped"))))

(define-command "events-demo-faster" "Make the producer tick twice as often"
  (lambda ()
    (set! events-demo-interval (max 125 (quotient events-demo-interval 2)))
    (events-demo-refresh!)
    (message (string-append "one tick every " (number->string events-demo-interval) "ms"))))

(define-command "events-demo-slower" "Make the producer tick half as often"
  (lambda ()
    (set! events-demo-interval (min 16000 (* events-demo-interval 2)))
    (events-demo-refresh!)
    (message (string-append "one tick every " (number->string events-demo-interval) "ms"))))

(define-command "events-demo-burst" "Send three messages from one person at once"
  (lambda ()
    (let ((person (demo-any events-demo-people)))
      (events-demo-burst! person)
      (message (string-append person " sent a burst: triage takes it in one run")))))

(define-command "events-demo-next-model" "Switch triage to the next local model"
  (lambda ()
    (let ((rest (cdr (or (member events-demo-model events-demo-models) (list #f)))))
      (set! events-demo-model (if (pair? rest) (car rest) (car events-demo-models)))
      (events-demo-refresh!)
      (message (string-append "triage now asks " (plist-get events-demo-model 'model))))))

(define-command "events-demo-toggle-failure" "Make the todos workflow fail, or heal it"
  (lambda ()
    (set! events-demo-failing (not events-demo-failing))
    (events-demo-refresh!)
    (message (if events-demo-failing
                 "todos now fails: its position stays, and a batch parks after three failures"
                 "todos works again: the next run takes what waited"))))

(define-command "events-demo-replay" "Rewind the todos workflow 30 events and take them again"
  (lambda ()
    (let ((at (or (plist-get (workflow-status "demo-todos") 'position) 0)))
      (workflow-rewind! "demo-todos" (max 0 (- at 30)))
      (message "todos replays its last 30 events: once! files nothing twice"))))

(define-command "events-demo-refresh" "Redraw the scene"
  (lambda () (events-demo-refresh!)))

(effects! '(read display))

(define-command "events-demo-trace-at-point" "Show the whole trace of the event at point beside the scene"
  (lambda ()
    (let* ((e (list-current *events-demo-buffer*))
           (trace (and e (event-trace e))))
      (when trace
        (let ((buf (string-append "*events-demo:trace " (number->string trace) "*")))
          (buffer-create buf)
          (buffer-set-text! buf
                            (string-join
                             (map (lambda (x)
                                    (string-append (demo-pad (number->string (plist-get x 'seq)) 7)
                                                   (demo-pad (demo-num (demo-data x 'cause)) 7)
                                                   (demo-pad (plist-get x 'topic) 22)
                                                   (demo-pad (symbol->string (plist-get x 'kind)) 9)
                                                   (demo-what x)))
                                  (events-demo-trace trace))
                             "\n")
                            #t)
          (buffer-set-local! buf 'group (buffer-local *events-demo-buffer* 'group))
          (display-buffer-detail! buf *events-demo-buffer*))))))

;;; --- the catalog -------------------------------------------------------

(domain! 'system)
(effects! '(write))
(public! 'events-demo-start! "(events-demo-start!) — define the scene's three workflows: triage, todos, escalate")
(public! 'events-demo-produce! "(events-demo-produce! ON?) — start or stop the scene's producer")
(effects! '(read))
(public! 'events-demo-trace "(events-demo-trace TRACE) — every scene event of TRACE, oldest first")

;;; --- the flow: the scene as a picture, forward and back ----------------
;;;
;;; *events-demo:flow* draws the scene as an SVG: the two producers, the
;;; three workflows, and the model beside triage. Each of the newest events
;;; is a pulsing arrow on the edge it travelled; a workflow whose last run
;;; failed pulses red. The picture is drawn as of a cursor, a seq of the
;;; log. Live, the cursor is the head. <left> and <right> step it one event,
;;; [ and ] ten, SPC plays the log forward from there, and l goes live
;;; again. The log is the timeline, so rewinding shows what was.

(effects! '(write))

(define *events-demo-flow* "*events-demo:flow*")

;; #f is live; a seq is a moment of the log
(define events-demo-cursor (if (boundp 'events-demo-cursor) events-demo-cursor #f))
(define events-demo-playing (if (boundp 'events-demo-playing) events-demo-playing #f))

(effects! '(pure))

;; (NAME X Y LABEL)
(define demo-nodes
  '((wa 110 130 "WhatsApp") (mail 110 290 "Mail") (model 370 60 "qwen3")
    (triage 370 210 "triage") (todos 620 210 "todos") (escalate 870 210 "escalate")))

(define (demo-node name) (assoc name demo-nodes))

;; the edge an event travelled, (FROM TO), or #f
(define (demo-edge e)
  (let ((t (plist-get e 'topic)))
    (cond ((string-prefix? "demo:wa:" t) '(wa triage))
          ((string-prefix? "demo:mail:" t) '(mail triage))
          ((equal? t "obs:llm") '(triage model))
          ((string-prefix? "demo:triaged:" t) '(triage todos))
          ((string-prefix? "demo:todo:" t) '(todos escalate))
          (else #f))))

(define (demo-edge-color e)
  (let ((t (plist-get e 'topic)))
    (cond ((equal? t "obs:llm") "#c792ea")
          ((string-prefix? "demo:triaged:" t)
           (cond ((demo-label? e 'ask) "#ffcb6b") ((demo-label? e 'thanks) "#c3e88d") (else "#89ddff")))
          ((string-prefix? "demo:todo:" t) (if (equal? (plist-get e 'kind) 'closed) "#c3e88d" "#ffcb6b"))
          (else "#82aaff"))))

(effects! '(read))

;; the scene's events and runs, oldest first: the timeline the flow walks
(define (demo-timeline)
  (let* ((xs (append (event-log-newest "demo:*" 300) (event-log-newest "obs:*" 300)))
         (table (map (lambda (e) (cons (plist-get e 'seq) e)) xs)))
    (map (lambda (seq) (cdr (assoc seq table))) (sort (map car table)))))

(define (demo-cursor timeline)
  (or events-demo-cursor (if (null? timeline) 0 (plist-get (car (reverse timeline)) 'seq))))

(define (demo-upto timeline cursor)
  (filter (lambda (e) (<= (plist-get e 'seq) cursor)) timeline))

(define (demo-last xs n) (reverse (workflow--first-n (reverse xs) n)))

;; the last run of workflow NAME at or before the cursor, or #f
(define (demo-last-run seen name)
  (let ((runs (filter (lambda (e) (equal? (plist-get e 'topic) (string-append "obs:workflow:" name))) seen)))
    (and (pair? runs) (car (reverse runs)))))

(define (demo-count seen pred) (length (filter pred seen)))

(effects! '(pure))

(define (demo-escape s)
  (let* ((s (string-join (string-split (or s "") "&") "&amp;"))
         (s (string-join (string-split s "<") "&lt;")))
    (string-join (string-split s ">") "&gt;")))

(define (n->s n) (if (number? n) (number->string n) "-"))

;; the path between two nodes, from the edge of one box to the edge of the other
(define (demo-path from to)
  (let* ((a (demo-node from)) (b (demo-node to))
         (ax (nth 1 a)) (ay (nth 2 a)) (bx (nth 1 b)) (by (nth 2 b))
         (vertical (equal? ax bx)))
    (if vertical
        (string-append "M " (n->s ax) " " (n->s (- ay 36)) " L " (n->s bx) " " (n->s (+ by 36)))
        (string-append "M " (n->s (+ ax 72)) " " (n->s ay) " L " (n->s (- bx 72)) " " (n->s by)))))

(define (demo-svg-edge edge)
  (string-append "<path d='" (demo-path (car edge) (cadr edge))
                 "' stroke='#3b4252' stroke-width='2' fill='none' marker-end='url(#head)'/>"))

;; one pulsing arrow per event: the newest brightest, each a little behind the one before
(define (demo-svg-arrow e i)
  (let ((edge (demo-edge e)))
    (string-append
     "<g opacity='" (n->s (max 20 (- 100 (* i 9)))) "%'>"
     "<circle r='5' fill='" (demo-edge-color e) "'>"
     "<animateMotion dur='1.6s' repeatCount='indefinite' begin='-" (n->s (* i 170)) "ms' path='"
     (demo-path (car edge) (cadr edge)) "'/>"
     "<animate attributeName='r' values='3;8;3' dur='0.8s' repeatCount='indefinite'/>"
     "</circle></g>")))

(define (demo-svg-node name lines failing?)
  (let* ((n (demo-node name)) (x (nth 1 n)) (y (nth 2 n)))
    (string-append
     "<g class='node" (if failing? " failing" "") "'>"
     "<rect x='" (n->s (- x 72)) "' y='" (n->s (- y 36)) "' width='144' height='72' rx='10'>"
     (if failing? "<animate attributeName='fill-opacity' values='1;0.35;1' dur='0.9s' repeatCount='indefinite'/>" "")
     "</rect>"
     "<text class='name' x='" (n->s x) "' y='" (n->s (- y 12)) "'>" (demo-escape (nth 3 n)) "</text>"
     (let loop ((ls lines) (dy 8) (out ""))
       (if (null? ls) out
           (loop (cdr ls) (+ dy 15)
                 (string-append out "<text class='stat' x='" (n->s x) "' y='" (n->s (+ y dy)) "'>"
                                (demo-escape (car ls)) "</text>"))))
     "</g>")))

(define (demo-x seq first last)
  (+ 60 (quotient (* 880 (- seq first)) (max 1 (- last first)))))

(effects! '(read))

(define (demo-run-lines seen name)
  (let ((run (demo-last-run seen name)))
    (list (string-append (n->s (demo-count seen (lambda (e) (equal? (plist-get e 'topic) (string-append "obs:workflow:" name)))))
                         " runs · " (if run (n->s (demo-data run 'ms)) "-") "ms")
          (string-append (if run (n->s (demo-data run 'events)) "0") " events last run"))))

(define (demo-failing? seen name)
  (let ((run (demo-last-run seen name))) (and run (not (demo-data run 'ok)))))

(define (demo-open-at seen)
  (let ((todos (filter (lambda (e) (string-prefix? "demo:todo:" (plist-get e 'topic))) seen)))
    (- (demo-count todos (lambda (e) (equal? (plist-get e 'kind) 'filed)))
       (demo-count todos (lambda (e) (equal? (plist-get e 'kind) 'closed))))))

(define (demo-flow-html)
  (let* ((timeline (demo-timeline))
         (cursor (demo-cursor timeline))
         (seen (demo-upto timeline cursor))
         (moving (demo-last (filter demo-edge seen) 12))
         (calls (filter (lambda (e) (equal? (plist-get e 'topic) "obs:llm")) seen))
         (call (and (pair? calls) (car (reverse calls))))
         (now (and (pair? seen) (car (reverse seen))))
         (first (if (pair? timeline) (plist-get (car timeline) 'seq) 0))
         (last (if (pair? timeline) (plist-get (car (reverse timeline)) 'seq) 1))
         (behind (length (filter (lambda (e) (> (plist-get e 'seq) cursor)) timeline))))
    (string-append
     "<html><head><style>"
     "html{font-size:1.4vw}body{margin:0;background:#11141c;color:#c8d3f5;font-family:ui-monospace,Menlo,monospace}"
     ".bar{padding:.6rem 1rem;font-size:.9rem}.live{color:#c3e88d}.rew{color:#ffcb6b}.now{padding:0 1rem;font-size:.8rem;color:#828bb8}"
     "svg{width:100%;height:auto}.node rect{fill:#1e2230;stroke:#444a73;stroke-width:1.5}"
     ".node.failing rect{fill:#5c1f2a;stroke:#ff757f}.name{fill:#c8d3f5;font-size:15px;text-anchor:middle;font-weight:600}"
     ".stat{fill:#828bb8;font-size:11px;text-anchor:middle}.tick{stroke-width:2}"
     "</style></head><body>"
     "<div class='bar'>"
     (if events-demo-cursor
         (string-append "<span class='rew'>REWOUND</span> to seq " (n->s cursor) ", " (n->s behind) " events behind the head")
         (string-append "<span class='live'>LIVE</span> at seq " (n->s cursor)))
     (if events-demo-playing " · PLAYING" "")
     " · model " (demo-escape (plist-get events-demo-model 'model))
     " · &lt;left&gt;/&lt;right&gt; step, [ ] ten, SPC play, l live</div>"
     "<div class='now'>" (if now (demo-escape (string-append (n->s (plist-get now 'seq)) "  " (plist-get now 'topic) "  " (demo-what now))) "") "</div>"
     "<svg viewBox='0 0 1000 440' xmlns='http://www.w3.org/2000/svg'>"
     "<defs><marker id='head' viewBox='0 0 10 10' refX='9' refY='5' markerWidth='7' markerHeight='7' orient='auto'>"
     "<path d='M0 0 L10 5 L0 10 z' fill='#444a73'/></marker></defs>"
     (apply string-append (map demo-svg-edge '((wa triage) (mail triage) (triage model) (triage todos) (todos escalate))))
     (demo-svg-node 'wa (list (string-append (n->s (demo-count seen (lambda (e) (string-prefix? "demo:wa:" (plist-get e 'topic))))) " sent")) #f)
     (demo-svg-node 'mail (list (string-append (n->s (demo-count seen (lambda (e) (string-prefix? "demo:mail:" (plist-get e 'topic))))) " sent")) #f)
     (demo-svg-node 'model (list (string-append (n->s (length calls)) " calls · " (if call (n->s (demo-data call 'ms)) "-") "ms")
                                 (string-append "said: " (if call (or (demo-data call 'answer) "") "-"))) #f)
     (demo-svg-node 'triage (demo-run-lines seen "demo-triage") (demo-failing? seen "demo-triage"))
     (demo-svg-node 'todos (cons (string-append (n->s (demo-open-at seen)) " open") (demo-run-lines seen "demo-todos"))
                    (demo-failing? seen "demo-todos"))
     (demo-svg-node 'escalate (list (string-append (n->s (demo-count seen (lambda (e) (string-prefix? "demo:alert:" (plist-get e 'topic))))) " alerts")) #f)
     (let loop ((ms moving) (i (- (length moving) 1)) (out ""))
       (if (null? ms) out (loop (cdr ms) (- i 1) (string-append out (demo-svg-arrow (car ms) i)))))
     "<line x1='60' y1='400' x2='940' y2='400' stroke='#2f334d' stroke-width='14' stroke-linecap='round'/>"
     (apply string-append
            (map (lambda (e) (let ((x (n->s (demo-x (plist-get e 'seq) first last))))
                               (string-append "<line class='tick' x1='" x "' y1='394' x2='" x "' y2='406' stroke='"
                                              (if (demo-edge e) (demo-edge-color e) "#444a73") "'/>")))
                 timeline))
     (let ((x (n->s (demo-x cursor first last))))
       (string-append "<line x1='" x "' y1='384' x2='" x "' y2='416' stroke='#ff966c' stroke-width='3'/>"))
     "</svg></body></html>")))

(effects! '(write display))

(define (events-demo-flow-render!)
  (let ((buf *events-demo-flow*))
    (unless (buffer-exists? buf) (buffer-create buf))
    (buffer-set-read-only! buf #f)
    (buffer-set-text! buf (demo-flow-html))
    (unless (buffer-derived-mode? buf "events-demo-flow-mode")
      (with-current-buffer buf (lambda () (set-mode! "events-demo-flow-mode"))))
    (buffer-set-local! buf 'preview-renderer "html")
    (enable-minor-mode! buf "preview-mode")
    (preview-heal! buf)
    (buffer-set-read-only! buf #t)
    buf))

(define (events-demo--step! n)
  (let* ((seqs (map (lambda (e) (plist-get e 'seq)) (demo-timeline)))
         (at (demo-cursor (demo-timeline)))
         (later (filter (lambda (s) (> s at)) seqs))
         (earlier (reverse (filter (lambda (s) (< s at)) seqs))))
    (set! events-demo-cursor
          (cond ((> n 0) (if (> (length later) (- n 1)) (list-ref later (- n 1)) #f))
                ((pair? earlier) (list-ref earlier (min (- (length earlier) 1) (- (- n) 1))))
                (else at)))
    (events-demo-flow-render!)))

;; play: one event forward per tick, until the head, where it goes live
(define (events-demo--play-tick _)
  (when (and events-demo-playing events-demo-cursor)
    (events-demo--step! 1)
    (if events-demo-cursor
        (debounce! 'events-demo-play 350 events-demo--play-tick #f)
        (set! events-demo-playing #f))))

(define-mode "events-demo-flow-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-parent! "events-demo-flow-mode" "special-mode")
(mode-doc! "events-demo-flow-mode"
  "The event bus scene as a picture. Each of the newest events is a pulsing arrow on the edge it travelled, and a workflow whose last run failed pulses red. <left> and <right> step one event back and forth, [ and ] ten, SPC plays forward from there, l goes live, and q buries the picture.")
(mode-keys! "events-demo-flow-mode"
  (list (list "<left>" "events-demo-back") (list "<right>" "events-demo-forward")
        (list "[" "events-demo-back-ten") (list "]" "events-demo-forward-ten")
        (list "SPC" "events-demo-play") (list "l" "events-demo-live") (list "q" "bury-buffer")))

(define-command "events-demo-back" "Step the flow one event back" (lambda () (events-demo--step! -1)))
(define-command "events-demo-forward" "Step the flow one event forward" (lambda () (events-demo--step! 1)))
(define-command "events-demo-back-ten" "Step the flow ten events back" (lambda () (events-demo--step! -10)))
(define-command "events-demo-forward-ten" "Step the flow ten events forward" (lambda () (events-demo--step! 10)))

(define-command "events-demo-live" "Follow the head of the log again"
  (lambda () (set! events-demo-cursor #f) (set! events-demo-playing #f) (events-demo-flow-render!)))

(define-command "events-demo-play" "Play the log forward from the cursor, or pause"
  (lambda ()
    (set! events-demo-playing (and events-demo-cursor (not events-demo-playing)))
    (events-demo-flow-render!)
    (when events-demo-playing (debounce! 'events-demo-play 350 events-demo--play-tick #f))))

(define-command "events-demo-flow" "Show the event bus scene as a picture beside the list"
  (lambda ()
    (events-demo-open!)
    (display-buffer-detail! (events-demo-flow-render!) *events-demo-buffer*)))

;;; --- the scene drawn with components -----------------------------------
;;;
;;; The text above is what the list navigates; these blocks are what the
;;; window shows: stat tiles and a table of the workflows over the rows,
;;; each row coloured by what it is. A block's 'lines ties it to the text
;;; lines it stands for, so point, selection and scrolling still work.

(effects! '(read))

(define (demo-ms-stats topic n)
  (let ((ms (map (lambda (e) (demo-data e 'ms)) (event-log-newest topic n))))
    (list (demo-percentile ms 50) (demo-percentile ms 95))))

(define (demo-stat-tiles)
  (let* ((sent (append (event-log-newest "demo:wa:*" 1000) (event-log-newest "demo:mail:*" 1000)))
         (calls (event-log-newest "obs:llm" 1000))
         (ms (demo-ms-stats "obs:llm" 300))
         (in (apply + (map (lambda (e) (or (demo-data e 'in) 0)) calls)))
         (out (apply + (map (lambda (e) (or (demo-data e 'out) 0)) calls)))
         (open (apply + (map (lambda (p) (length (demo-open-todos p))) events-demo-people)))
         (alerts (length (event-log-newest "demo:alert:*" 1000))))
    (list (list 'label "messages / min" 'value (n->s (length (demo-last-minute sent)))
                'sub (string-append (n->s (length sent)) " total · " (if events-demo-producing "producing" "paused"))
                'class (if events-demo-producing "good" "warn"))
          (list 'label "model p50" 'value (string-append (n->s (car ms)) "ms")
                'sub (string-append "p95 " (n->s (cadr ms)) "ms · " (plist-get events-demo-model 'model))
                'class (if (and (car ms) (< (car ms) 400)) "good" "warn"))
          (list 'label "model calls" 'value (n->s (length calls))
                'sub (string-append (n->s in) " tok in · " (n->s out) " out"))
          (list 'label "cost" 'value "$0"
                'sub (string-append "on Haiku " (demo-dollars (+ (* in (car workflow-haiku-price)) (* out (cadr workflow-haiku-price))))))
          (list 'label "open todos" 'value (n->s open)
                'sub (string-append (n->s (length (filter (lambda (e) (equal? (plist-get e 'kind) 'filed)) (event-log-newest "demo:todo:*" 1000)))) " filed"))
          (list 'label "alerts" 'value (n->s alerts) 'class (if (> alerts 0) "warn" "")))))

(define (demo-workflow-row name)
  (let ((s (workflow-status name)) (ms (demo-ms-stats (string-append "obs:workflow:" name) 300)))
    (if (not s)
        (list name "" "" (list "stopped" "warn") "" "" "" "" "" "")
        (list name
              (n->s (plist-get s 'position))
              (let ((w (plist-get s 'behind))) (list (n->s w) (if (> w 5) "warn" "")))
              (let ((st (plist-get s 'status)))
                (list (symbol->string st)
                      (cond ((equal? st 'running) "good") ((member st '(backoff paused stepping)) "warn") (else ""))))
              (n->s (plist-get s 'runs))
              (n->s (car ms)) (n->s (cadr ms))
              (let ((f (plist-get s 'attempts))) (list (n->s f) (if (> f 0) "bad" "")))
              (let ((k (plist-get s 'parked))) (list (n->s k) (if (> k 0) "bad" "")))
              (list (or (plist-get s 'last-error) "") "bad")))))

(define (demo-row-class e)
  (let ((t (plist-get e 'topic)) (kind (plist-get e 'kind)))
    (cond ((string-prefix? "demo:wa:" t) "ev-wa")
          ((string-prefix? "demo:mail:" t) "ev-mail")
          ((string-prefix? "demo:triaged:" t)
           (cond ((demo-label? e 'ask) "ev-ask") ((demo-label? e 'thanks) "ev-thanks") (else "ev-info")))
          ((string-prefix? "demo:todo:" t) (if (equal? kind 'closed) "ev-thanks" "ev-ask"))
          ((string-prefix? "demo:alert:" t) "ev-alert")
          ((equal? t "obs:llm") "ev-llm")
          ((member kind '(failed parked)) "ev-fail")
          (else "ev-obs"))))

(define demo-row-widths '(7 6 7 22 9))

;; the cells as segments: padded to the columns, the first three dim
(define (demo-row-segs cells class)
  (let loop ((cs cells) (ws demo-row-widths) (i 0) (out '()))
    (cond ((null? cs) (reverse out))
          ((null? ws) (loop (cdr cs) ws (+ i 1) (cons (list class (car cs)) out)))
          (else (loop (cdr cs) (cdr ws) (+ i 1)
                      (cons (list (if (< i 3) "c-dim" class) (demo-pad (car cs) (car ws))) out))))))

(define (demo-panel-block head)
  (list 'tag "div" 'class "events-demo-panel" 'lines (list 1 (max 1 (- head 1)))
        'children (list (list 'tag "div" 'class "events-demo-title" 'text "Event bus scene")
                        (component 'ui/stats (list 'stats (or (demo-snap 'tiles) '())))
                        (component 'ui/table
                          (list 'columns '(("workflow") ("at" right) ("behind" right) ("state") ("runs" right)
                                           ("p50 ms" right) ("p95 ms" right) ("fails" right) ("parked" right)
                                           ("last error"))
                                'rows (or (demo-snap 'workflows) '()))))))

(define (events-demo--blocks buf)
  (let* ((head (list-header-lines buf))
         (rows (workflow--first-n (list-entries buf) (list-shown-count buf))))
    (append
     (list (demo-panel-block head)
           (component 'ui/row (list 'segs (demo-row-segs '("seq" "age" "trace" "topic" "kind" "what") "c-dim")
                                    'class "events-demo-row events-demo-head" 'lines (list head head))))
     (let loop ((es rows) (i 0) (out '()))
       (if (null? es) (reverse out)
           (loop (cdr es) (+ i 1)
                 (cons (component 'ui/row
                         (list 'segs (let ((c (demo-snap-cells (car es)))) (demo-row-segs (car c) (cadr c)))
                               'class "events-demo-row"
                               'lines (list (+ head 1 i) (+ head 1 i)) 'mark "current"))
                       out)))))))

(effects! '(write))

(define (events-demo--draw-blocks! buf)
  (desktop-skip! buf 'render-blocks)
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks (events-demo--blocks buf)))

(define-style! 'events-demo "
.events-demo-panel { padding: 4px 10px 0; }
.events-demo-title { font-family: var(--font-mono); font-size: 13px; font-weight: 600; padding: 6px 0 2px; }
.events-demo-row { white-space: pre; font-size: 11px; padding: 1px 10px; }
.events-demo-head { border-bottom: 1px solid var(--border-bg); padding-top: 8px; }
.ev-wa { color: #3b82f6; } .ev-mail { color: #0891b2; } .ev-ask { color: #b45309; }
.ev-thanks { color: #15803d; } .ev-info { color: #64748b; } .ev-llm { color: #7c3aed; }
.ev-alert { color: #dc2626; font-weight: 600; } .ev-fail { color: #dc2626; } .ev-obs { color: var(--dim-fg); }
")

;;; --- drawing off the lane ----------------------------------------------
;;;
;;; A draw reads a few thousand events and formats the rows, which is too
;;; much for the lane every keystroke also waits on. So the whole draw runs
;;; in a task: it reads the log into a snapshot (rows, cells, panel, tiles,
;;; the flow's html) and writes the two buffers, which serialize their own
;;; writes. The lane only schedules it. At most one draw a second, one at a
;;; time, and only while a window shows the scene.

(effects! '(write))

(define events-demo-draw-ms 1000)
(define events-demo-rows-shown 60)
(define *events-demo-snapshot* (if (boundp '*events-demo-snapshot*) *events-demo-snapshot* '()))
(define *events-demo-drawing* #f)

(define (demo-shown? buf)
  (pair? (filter (lambda (w) (equal? (nth 1 w) buf)) (window-list-all))))

(effects! '(read))

;; everything a draw shows, read in one pass; runs in a task
(define (events-demo--snapshot flow?)
  (let* ((rows (workflow--first-n (events-demo--rows #f) events-demo-rows-shown)))
    (list 'rows rows
          'cells (map (lambda (e) (cons (plist-get e 'seq)
                                        (list (events-demo--cells #f e) (demo-row-class e))))
                      rows)
          'panel (events-demo--header #f)
          'tiles (demo-stat-tiles)
          'workflows (map demo-workflow-row '("demo-triage" "demo-todos" "demo-escalate"))
          'flow (and flow? (demo-flow-html)))))

(define (demo-snap key) (plist-get *events-demo-snapshot* key))

(define (demo-snap-cells e)
  (let ((hit (assoc (plist-get e 'seq) (or (demo-snap 'cells) '()))))
    (if hit (cdr hit) (list (events-demo--cells #f e) (demo-row-class e)))))

(effects! '(write))

;; ask for a draw: one is pending at most, and it waits out the interval
(define (events-demo--saw e)
  (unless *events-demo-drawing*
    (set! *events-demo-drawing* #t)
    (debounce! 'events-demo-draw events-demo-draw-ms (lambda (_) (events-demo--draw!)) #f)))

(define (events-demo--draw!)
  (let ((list? (demo-shown? *events-demo-buffer*))
        (flow? (and (not events-demo-cursor) (demo-shown? *events-demo-flow*))))
    (if (not (or list? flow?))
        (set! *events-demo-drawing* #f)
        ;; the whole draw runs in the task: the buffers serialize their own
        ;; writes, and one draw at a time is the only writer of the snapshot
        (task-run! (lambda ()
                     (let ((snap (events-demo--snapshot flow?)))
                       (set! *events-demo-snapshot* snap)
                       (when list? (events-demo-apply!))
                       (when flow? (events-demo-flow-apply! (plist-get snap 'flow)))
                       #t))
                   (lambda (ok? _) (set! *events-demo-drawing* #f))
                   20000))))

(define (events-demo-apply!)
  (when (buffer-exists? *events-demo-buffer*)
    (list-refresh! *events-demo-buffer*)
    (events-demo--draw-blocks! *events-demo-buffer*)))

(define (events-demo-flow-apply! html)
  (when (and html (buffer-exists? *events-demo-flow*))
    (buffer-set-read-only! *events-demo-flow* #f)
    (buffer-set-text! *events-demo-flow* html)
    (buffer-set-read-only! *events-demo-flow* #t)))

;; g, and every command that changes what the scene shows
(define (events-demo-refresh!) (events-demo--saw #f))
