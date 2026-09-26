;;; events.scm --- the event log: topics, subscribers that keep a position, views.
;;;
;;; Machine work reports here: an agent's status moved, a turn ended, a
;;; mail or a WhatsApp message came in. A publisher writes an event to a
;;; TOPIC. A chat's topic is its stable id, "chat:...".
;;;
;;; The log itself is in the core (Compos.Core.Events.Log): one SQLite
;;; file, every event numbered with a seq, kept a year. An Elixir
;;; publisher (a webhook, a file watch) writes there with
;;; Compos.Core.Events.publish/3; Scheme writes with event-publish!.
;;; Either way the event reaches the subscribers and views here.
;;;
;;; A subscriber has a NAME, a topic PATTERN ("chat:*" matches a prefix)
;;; and a FN that gets each event. The core keeps the subscriber's
;;; position, the seq of the last event it took, so a subscriber that
;;; comes back after a restart first takes the events it missed, oldest
;;; first.
;;;
;;; A view is a read model: a fold over the events of a pattern, where
;;; (STEP STATE EVENT) gives the next state. Views are not saved; the log
;;; builds them again at load.
;;;
;;; Hooks stay the synchronous seams of the editor. The log is for work
;;; that someone reads later, or somewhere else. The todo list is not in
;;; the log: a todo card only reads the chat-status view.
;;;
;;; Event data must print and read back: strings, numbers, symbols, lists.

(domain! 'system)
(effects! '(write))

(defcustom 'events-file "~/.compos/events"
  "The event log before it moved into the core. Read once, into an empty core log.")

;; the state survives a reload of this file
(define *event-subs* (if (boundp '*event-subs*) *event-subs* '()))
(define *event-views* (if (boundp '*event-views*) *event-views* '()))
(define *event-view-states* (if (boundp '*event-view-states*) *event-view-states* '()))
;; the seq of the last event this session handed to its views and subscribers
(define *events-pumped* (if (boundp '*events-pumped*) *events-pumped* #f))
(define *events-pumping* #f)

(effects! '(pure))

(define (event-topic-match? pattern topic)
  "(event-topic-match? PATTERN TOPIC) — #t when PATTERN names TOPIC; a PATTERN that ends in * matches every topic that starts with the rest"
  (if (string-suffix? "*" pattern)
      (string-prefix? (substring pattern 0 (- (string-length pattern) 1)) topic)
      (equal? pattern topic)))

(define (events--name n) (if (symbol? n) (symbol->string n) n))
(define (events--fn f) (if (symbol? f) (symbol-value f) f))
(define (events--without name xs) (filter (lambda (x) (not (equal? (car x) name))) xs))

(effects! '(read))

(define (event-log &optional pattern limit)
  "(event-log [PATTERN] [LIMIT]) — the events whose topic PATTERN matches, newest first; LIMIT defaults to 200"
  (event-log-newest (or pattern #f) (or limit 200)))

(define (event-position name)
  "(event-position NAME) — the seq of the last event the subscriber NAME took, or #f"
  (event-log-position name))

(define (events--sub name)
  (let ((hit (filter (lambda (s) (equal? (car s) name)) *event-subs*)))
    (and (pair? hit) (car hit))))

;; every event after AFTER that PATTERN matches, up to UPTO when given, oldest first
(define (events--read-all after pattern &optional upto)
  (let loop ((after after) (acc '()))
    (let* ((batch (event-log-read after pattern 1000))
           (keep (if upto (filter (lambda (e) (<= (plist-get e 'seq) upto)) batch) batch))
           (acc (append acc keep)))
      (if (and (= (length batch) 1000) (= (length keep) 1000))
          (loop (plist-get (list-ref batch 999) 'seq) acc)
          acc))))

(define (events-since name)
  "(events-since NAME) — the events after NAME's position that its pattern matches, oldest first"
  (let ((sub (events--sub name)))
    (if (not sub)
        '()
        (events--read-all (or (event-position name) 0) (cadr sub)))))

(define (event-view name)
  "(event-view NAME) — the current state of the view NAME"
  (alist-get *event-view-states* name))

(define (event-view-get name key)
  "(event-view-get NAME KEY) — KEY's entry in a view whose state is an alist, or #f"
  (alist-get (or (event-view name) '()) key))

(effects! '(write))

(define (events--deliver! sub e)
  (let ((name (car sub)) (seq (plist-get e 'seq)))
    (when (> seq (or (event-position name) 0))
      ;; one bad subscriber must not stall itself or the ones behind it:
      ;; its position moves on, and the failure is said
      (unless (ignore-errors (lambda () ((events--fn (caddr sub)) e) #t))
        (message (string-append "event subscriber " (events--name name)
                                " failed on " (plist-get e 'topic))))
      (event-log-position-set! name seq))))

(define (events--step-view! v e)
  (when (event-topic-match? (cadr v) (plist-get e 'topic))
    (let ((next (ignore-errors
                  (lambda () (list ((events--fn (caddr v)) (event-view (car v)) e))))))
      (when next
        (set! *event-view-states* (alist-put *event-view-states* (car v) (car next)))))))

;; hand every event after *events-pumped* to the views and subscribers. A
;; subscriber that publishes lands its event in a later batch of the same
;; pump, never in a nested one.
(define (events--pump!)
  (unless *events-pumping*
    (set! *events-pumping* #t)
    (ignore-errors
      (lambda ()
        (let loop ()
          (let ((batch (event-log-read *events-pumped* #f 500)))
            (when (pair? batch)
              (for-each
               (lambda (e)
                 (for-each (lambda (v) (events--step-view! v e)) *event-views*)
                 (for-each (lambda (s) (when (event-topic-match? (cadr s) (plist-get e 'topic))
                                         (events--deliver! s e)))
                           *event-subs*)
                 (set! *events-pumped* (plist-get e 'seq)))
               batch)
              (loop))))))
    (set! *events-pumping* #f)))

(define (events-arrived!)
  "(events-arrived!) — the core log's notice that events arrived: hand them to the views and subscribers"
  (events--pump!))

(define (event-publish! topic kind &optional data)
  "(event-publish! TOPIC KIND [DATA]) — append an event to the log, fold it into the views and hand it to every subscriber whose pattern matches TOPIC; return its seq"
  (let ((seq (event-log-append! topic kind data)))
    (events--pump!)
    seq))

(define (event-subscribe! name pattern fn)
  "(event-subscribe! NAME PATTERN FN) — call (FN EVENT) for each new event whose topic PATTERN matches. NAME keeps its position across reloads and restarts, so a NAME that comes back first takes what it missed. Give FN as a quoted function name, so a reload changes what runs"
  (set! *event-subs* (append (events--without name *event-subs*) (list (list name pattern fn))))
  (if (event-position name)
      (for-each (lambda (e) (events--deliver! (events--sub name) e)) (events-since name))
      (event-log-position-set! name *events-pumped*))
  name)

(define (event-unsubscribe! name)
  "(event-unsubscribe! NAME) — drop the subscriber NAME and forget its position"
  (set! *event-subs* (events--without name *event-subs*))
  (event-log-forget! name)
  name)

(define (event-define-view! name pattern step &optional init)
  "(event-define-view! NAME PATTERN STEP [INIT]) — a read model: fold (STEP STATE EVENT) over the events PATTERN matches, from INIT, which is the empty list when omitted; the log builds it now and keeps it current"
  (let ((v (list name pattern step)))
    (set! *event-views* (append (events--without name *event-views*) (list v)))
    (set! *event-view-states* (alist-put *event-view-states* name (or init '())))
    (for-each (lambda (e) (events--step-view! v e)) (events--read-all 0 pattern *events-pumped*)))
  name)

;; the log that events.scm kept in events-file goes into an empty core
;; log once. Positions stay behind: a subscriber starts at the present.
(define (events--import!)
  (let ((path (expand-path events-file)))
    (when (and (= (event-log-seq) 0) (file-exists? path))
      (let* ((forms (scheme-read (read-file path)))
             (saved (and (pair? forms) (car forms))))
        (when (pair? saved)
          (event-log-import! (reverse (or (plist-get saved 'events) '())) '()))))))

(ignore-errors events--import!)
(unless *events-pumped* (set! *events-pumped* (event-log-seq)))

;;; The agents report here. agent-fleet runs agent-status-hook when a
;;; chat's runtime status moves, and agent.scm runs agent-turn-end when a
;;; turn ends. Both publish on the chat's topic.

(domain! 'chat)
(effects! '(write))

(define (events--chat-topic slug)
  (let ((b (agent-buf slug)))
    (and b (buffer-exists? b) (chat-stable-id! b))))

(define (events--agent-status slug)
  (let ((topic (events--chat-topic slug)))
    (when topic
      (event-publish! topic 'status (list 'status (agent-status slug) 'slug slug)))))

(define (events--agent-turn-end slug stop-reason ok?)
  (let ((topic (events--chat-topic slug)))
    (when topic
      (event-publish! topic 'turn-end (list 'stop-reason stop-reason 'ok ok? 'slug slug)))))

(add-hook! 'agent-status-hook 'events--agent-status)
(add-hook! (list 'agent-turn-end "events") 'events--agent-turn-end)

;; one row per chat: its last status, the stop reason of its last turn,
;; how many turns ended and the time of its last event
(define (events--chat-status-step state e)
  (let* ((topic (plist-get e 'topic))
         (d (plist-get e 'data))
         (row (or (alist-get state topic) '()))
         (row (cond ((equal? (plist-get e 'kind) 'status)
                     (plist-put row 'status (plist-get d 'status)))
                    ((equal? (plist-get e 'kind) 'turn-end)
                     (plist-put (plist-put row 'turns (+ 1 (or (plist-get row 'turns) 0)))
                                'stop-reason (plist-get d 'stop-reason)))
                    (else row))))
    (alist-put state topic (plist-put row 'at (plist-get e 'at)))))

(event-define-view! 'chat-status "chat:*" 'events--chat-status-step)
