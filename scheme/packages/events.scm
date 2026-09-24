;;; events.scm --- the event log: topics, subscribers that keep a position, views.
;;;
;;; Machine work reports here: an agent's status moved, or its turn ended.
;;; A publisher writes an event to a TOPIC. A chat's topic is its stable
;;; id, "chat:...". The log numbers every event with a seq and keeps the
;;; newest events-log-limit of them.
;;;
;;; A subscriber has a NAME, a topic PATTERN ("chat:*" matches a prefix)
;;; and a FN that gets each event. The log keeps the subscriber's position:
;;; the seq of the last event it took. The log and the positions go to
;;; events-file, so a subscriber that comes back after a restart first
;;; takes the events it missed, oldest first.
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

(defcustom 'events-log-limit 2000
  "How many events the log keeps. A subscriber that is further behind than that misses the older ones.")

(defcustom 'events-file "~/.compos/events"
  "Where the event log and the subscriber positions are saved. Not a .scm name: the hot reloader evaluates every .scm file in the config home.")

;; the state survives a reload of this file
(define *events* (if (boundp '*events*) *events* '()))
(define *events-count* (if (boundp '*events-count*) *events-count* 0))
(define *events-seq* (if (boundp '*events-seq*) *events-seq* 0))
(define *event-subs* (if (boundp '*event-subs*) *event-subs* '()))
(define *event-positions* (if (boundp '*event-positions*) *event-positions* '()))
(define *event-views* (if (boundp '*event-views*) *event-views* '()))
(define *event-view-states* (if (boundp '*event-view-states*) *event-view-states* '()))

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
  "(event-log [PATTERN] [LIMIT]) — the events whose topic PATTERN matches, newest first"
  (let ((es (if pattern
                (filter (lambda (e) (event-topic-match? pattern (plist-get e 'topic))) *events*)
                *events*)))
    (if (and limit (> (length es) limit)) (list-head es limit) es)))

(define (event-position name)
  "(event-position NAME) — the seq of the last event the subscriber NAME took, or #f"
  (alist-get *event-positions* name))

(define (events--sub name)
  (let ((hit (filter (lambda (s) (equal? (car s) name)) *event-subs*)))
    (and (pair? hit) (car hit))))

(define (events-since name)
  "(events-since NAME) — the events after NAME's position that its pattern matches, oldest first"
  (let ((sub (events--sub name))
        (pos (or (event-position name) 0)))
    (if (not sub)
        '()
        (reverse (filter (lambda (e) (and (> (plist-get e 'seq) pos)
                                          (event-topic-match? (cadr sub) (plist-get e 'topic))))
                         *events*)))))

(define (event-view name)
  "(event-view NAME) — the current state of the view NAME"
  (alist-get *event-view-states* name))

(define (event-view-get name key)
  "(event-view-get NAME KEY) — KEY's entry in a view whose state is an alist, or #f"
  (alist-get (or (event-view name) '()) key))

(effects! '(write))

(define (events--path) (expand-path events-file))

(define (events--save! _)
  (write-file! (events--path)
               (value->string (list 'seq *events-seq* 'positions *event-positions* 'events *events*))))

(define (events--save-soon!) (debounce! 'events-save 1000 events--save! #f))

(define (events--restore!)
  (let* ((path (events--path))
         (text (and (file-exists? path) (read-file path)))
         (forms (and text (scheme-read text)))
         (saved (and (pair? forms) (car forms))))
    (when (and (pair? saved) (null? *events*))
      (set! *events-seq* (or (plist-get saved 'seq) 0))
      (set! *event-positions* (or (plist-get saved 'positions) '()))
      (set! *events* (or (plist-get saved 'events) '()))
      (set! *events-count* (length *events*)))))

(define (events--deliver! sub e)
  (let ((name (car sub)) (seq (plist-get e 'seq)))
    (when (> seq (or (event-position name) 0))
      ;; one bad subscriber must not stall itself or the ones behind it:
      ;; its position moves on, and the failure is said
      (unless (ignore-errors (lambda () ((events--fn (caddr sub)) e) #t))
        (message (string-append "event subscriber " (events--name name)
                                " failed on " (plist-get e 'topic))))
      (set! *event-positions* (alist-put *event-positions* name seq)))))

(define (events--step-view! v e)
  (when (event-topic-match? (cadr v) (plist-get e 'topic))
    (let ((next (ignore-errors
                  (lambda () (list ((events--fn (caddr v)) (event-view (car v)) e))))))
      (when next
        (set! *event-view-states* (alist-put *event-view-states* (car v) (car next)))))))

(define (event-publish! topic kind &optional data)
  "(event-publish! TOPIC KIND [DATA]) — append an event to the log, fold it into the views and hand it to every subscriber whose pattern matches TOPIC; return its seq"
  (set! *events-seq* (+ *events-seq* 1))
  (let ((e (list 'seq *events-seq* 'topic topic 'kind kind 'data data 'at (current-time))))
    (set! *events* (cons e *events*))
    (set! *events-count* (+ *events-count* 1))
    (when (> *events-count* events-log-limit)
      (set! *events* (list-head *events* events-log-limit))
      (set! *events-count* events-log-limit))
    (for-each (lambda (v) (events--step-view! v e)) *event-views*)
    (for-each (lambda (s) (when (event-topic-match? (cadr s) topic) (events--deliver! s e)))
              *event-subs*)
    (events--save-soon!)
    *events-seq*))

(define (event-subscribe! name pattern fn)
  "(event-subscribe! NAME PATTERN FN) — call (FN EVENT) for each new event whose topic PATTERN matches. NAME keeps its position across reloads and restarts, so a NAME that comes back first takes what it missed. Give FN as a quoted function name, so a reload changes what runs"
  (set! *event-subs* (append (events--without name *event-subs*) (list (list name pattern fn))))
  (if (event-position name)
      (for-each (lambda (e) (events--deliver! (events--sub name) e)) (events-since name))
      (set! *event-positions* (alist-put *event-positions* name *events-seq*)))
  name)

(define (event-unsubscribe! name)
  "(event-unsubscribe! NAME) — drop the subscriber NAME and forget its position"
  (set! *event-subs* (events--without name *event-subs*))
  (set! *event-positions* (events--without name *event-positions*))
  (events--save-soon!)
  name)

(define (event-define-view! name pattern step &optional init)
  "(event-define-view! NAME PATTERN STEP [INIT]) — a read model: fold (STEP STATE EVENT) over the events PATTERN matches, from INIT, which is the empty list when omitted; the log builds it now and keeps it current"
  (let ((v (list name pattern step)))
    (set! *event-views* (append (events--without name *event-views*) (list v)))
    (set! *event-view-states* (alist-put *event-view-states* name (or init '())))
    (for-each (lambda (e) (events--step-view! v e)) (reverse *events*)))
  name)

(events--restore!)

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
