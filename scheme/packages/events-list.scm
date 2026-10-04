;;; events-list.scm --- M-x events: the event log as a list.
;;;
;;; The rows are the newest events of the log, every topic, newest first.
;;; t keeps one topic family (whatsapp, mail, chat ...), and / narrows the
;;; rows drawn. Moving the point shows the whole event beside the list.
;;; While the list is on screen it follows the head of the log.

(domain! 'system)
(effects! '(write))
(category! 'system)

(define *events-buffer* "*events*")

(defcustom 'events-list-limit 500
  "How many of the newest events M-x events shows.")

(defcustom 'events-list-draw-ms 1000
  "The least time between two redraws of the event list while events arrive.")

;; the topic pattern the list shows, #f for every topic; survives a reload
(define events-list-topic (if (boundp 'events-list-topic) events-list-topic #f))
(define *events-list-drawing* #f)

(effects! '(pure))

(define (events-list--data e k) (plist-get (plist-get e 'data) k))

(define (events-list--family topic)
  "the topic up to its first colon: whatsapp:9183... is whatsapp"
  (car (string-split topic ":")))

(define (events-list--what e)
  "one line that says what the event is: who and what was said, else the data printed"
  (let* ((text (events-list--data e 'text))
         (subject (events-list--data e 'subject))
         (who (or (events-list--data e 'chat-name) (events-list--data e 'from)
                  (events-list--data e 'sender))))
    (first-line
     (cond ((and (string? text) (string? who)) (string-append who ": " text))
           ((and (string? subject) (string? who)) (string-append who ": " subject))
           (else (event-text e))))))

(define (events-list--detail-text e)
  (let ((d (plist-get e 'data)))
    (string-append
     "seq    " (number->string (plist-get e 'seq)) "\n"
     "topic  " (plist-get e 'topic) "\n"
     "kind   " (symbol->string (plist-get e 'kind)) "\n"
     "age    " (ibuffer-age-label (- (current-time) (plist-get e 'at))) "\n\n"
     (if (pair? d)
         (let loop ((d d) (acc '()))
           (if (or (null? d) (null? (cdr d)))
               (string-join (reverse acc) "\n")
               (loop (cddr d)
                     (cons (string-append (symbol->string (car d)) ": " (workflow--text (cadr d))) acc))))
         (workflow--text d))
     "\n")))

(effects! '(read))

(define (events-list--rows buf)
  (event-log-newest events-list-topic events-list-limit))

(define (events-list--cells buf e)
  (list (number->string (plist-get e 'seq))
        (ibuffer-age-label (- (current-time) (plist-get e 'at)))
        (plist-get e 'topic)
        (symbol->string (plist-get e 'kind))
        (events-list--what e)))

(define (events-list--shown?)
  (pair? (filter (lambda (w) (equal? (nth 1 w) *events-buffer*)) (window-list-all))))

(effects! '(write display))

(define (events-list-show-detail! e)
  "show the whole event E in its own buffer, beside the list"
  (when e
    (let ((buf (string-append "*events:" (number->string (plist-get e 'seq)) "*")))
      (buffer-create buf)
      (buffer-set-text! buf (events-list--detail-text e) #t)
      (buffer-set-local! buf 'group (buffer-local *events-buffer* 'group))
      (display-buffer-detail! buf *events-buffer*))))

(effects! '(write))

(define (events-list--draw!)
  (set! *events-list-drawing* #f)
  (when (and (buffer-exists? *events-buffer*) (events-list--shown?))
    (list-refresh! *events-buffer*)))

(define (events-list--saw e)
  "an event arrived: one redraw is pending at most"
  (unless *events-list-drawing*
    (set! *events-list-drawing* #t)
    (debounce! 'events-list-draw events-list-draw-ms (lambda (_) (events-list--draw!)) #f)))

(define-list-mode! "events-mode"
  (list
    'doc (string-append
           "The event log: the newest events of every topic, newest first. "
           "Moving the point shows the whole event beside the list, and RET shows it too. "
           "t keeps one topic family, such as whatsapp or mail, and T shows every topic again. "
           "/ narrows the rows drawn. The list follows the log while it is on screen. "
           "g redraws, and q quits.")
    'buffer *events-buffer*
    'transient #f
    'rows events-list--rows
    'key (lambda (buf e) (number->string (plist-get e 'seq)))
    'follow-head #t
    'local-filter #t
    'no-marks #t
    'columns (lambda (buf)
               (list (list "seq" 7) (list "age" 5) (list "topic" 28) (list "kind" 10) (list "what" #f)))
    'cells events-list--cells
    'preview (lambda (buf e) (events-list-show-detail! e))
    'title (lambda (buf) (if events-list-topic (string-append "Events: " events-list-topic) "Events"))
    'total (lambda (buf) (length (list-entries buf)))
    'noun "event"
    'footer (lambda (buf)
              '(("RET" "show") ("t" "topic") ("T" "all topics") ("/" "filter") ("g" "redraw") ("q" "quit")))
    'keys '(("RET" "events-show") ("t" "events-topic") ("T" "events-all-topics")
            ("g" "events-refresh") ("q" "quit-window"))))

(define (events-list-open!)
  (event-subscribe! "events-list" "*" 'events-list--saw)
  (buffer-create *events-buffer*)
  (unless (buffer-local *events-buffer* 'group)
    (buffer-set-local! *events-buffer* 'group (frame-group)))
  *events-buffer*)

(define (events-list-set-topic! pattern)
  "show only the events PATTERN matches, #f for every topic"
  (set! events-list-topic pattern)
  (when (buffer-exists? *events-buffer*) (list-refresh! *events-buffer*))
  pattern)

(define events-list-known-families '("whatsapp" "mail" "chat" "demo" "obs"))

(define (events-list--families)
  "the topic families of the newest events and the known ones the log holds, sorted"
  (let loop ((es (event-log-newest #f 2000))
             (seen (filter (lambda (f) (pair? (event-log-newest (string-append f ":*") 1)))
                           events-list-known-families)))
    (if (null? es)
        (sort seen)
        (let ((f (events-list--family (plist-get (car es) 'topic))))
          (loop (cdr es) (if (member f seen) seen (cons f seen)))))))

(define-command "events" "Open the event log: the newest events of every topic"
  (lambda ()
    (events-list-open!)
    (list-mode-show! "events-mode")))

(define-command "events-refresh" "Redraw the event log"
  (lambda () (events-list--draw!)))

(define-command "events-topic" "Show only one topic family of the event log"
  (lambda ()
    (completing-read "Topic: " (events-list--families)
                     (lambda (choice)
                       (when (and (string? choice) (> (string-length choice) 0))
                         (events-list-set-topic!
                          (if (string-suffix? "*" choice) choice (string-append choice ":*"))))))))

(define-command "events-all-topics" "Show every topic of the event log again"
  (lambda () (events-list-set-topic! #f)))

(effects! '(read display))

(define-command "events-show" "Show the whole event at point beside the list"
  (lambda () (events-list-show-detail! (list-current *events-buffer*))))

(domain! 'system)
(effects! '(write))
(public! 'events-list-set-topic! "(events-list-set-topic! PATTERN) -- show only the events PATTERN matches in M-x events, #f for every topic")
(effects! '(write display))
(public! 'events-list-show-detail! "(events-list-show-detail! EVENT) -- show the whole EVENT beside the event list")
